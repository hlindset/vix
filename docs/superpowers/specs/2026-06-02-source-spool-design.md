# SourceSpool design

**Date:** 2026-06-02
**Status:** Approved

## Problem

Vix's only streaming-input primitive is a non-seekable OS pipe. `nif_source_new()` calls
`vips_source_new_from_descriptor` on the read end of a `pipe()` fd — read-once, sequential,
no `lseek`. Decoders for seek-heavy formats (HEIF, AVIF, multi-page TIFF) issue backward seeks
during header parsing and decode. On a pipe those seeks fail, causing degraded or broken decodes.

The only existing workarounds — `new_from_buffer/2` (whole body in memory) or `new_from_file/2`
(caller manages the file) — do not work when the input arrives incrementally as an Elixir
`Enumerable`.

## Goal

Add a seekable, concurrent-capable source primitive so that an `Enumerable` of chunks can be
decoded by libvips with full seek support while chunks are still arriving.

## Non-goals

- A general-purpose Elixir-controllable `VipsSourceCustom` (the rejected `vips-connection`
  approach — requires libvips to call back into the BEAM).
- "Tier 1" (write everything to a temp file, then call `new_from_file`) — implementable in
  user space today with no Vix changes.

## Design

### Concept: spooling

A spool writes data to an intermediate buffer while a consumer reads from it concurrently —
the print-spool etymology. Here: Elixir writes chunks to a growing temp file; libvips decodes
from the same file via a `VipsSourceCustom` read handler that blocks at the write frontier
instead of returning EOF.

All libvips-facing logic is pure C ↔ C (no BEAM re-entry). The objection to the `vips-connection`
approach was specifically that libvips calls back into the BEAM from its decode threads; this
design avoids that entirely.

### New files

| File | Purpose |
|---|---|
| `c_src/spool.c` | NIF implementation, VipsSourceCustom callbacks |
| `c_src/spool.h` | Declarations |
| `lib/vix/source_spool.ex` | Thin Elixir wrapper (`@moduledoc false`) |

Changes to existing files: `c_src/vix.c` (NIF registration), `lib/vix/nif.ex` (NIF stubs),
`lib/vix/vips/image.ex` (`new_from_enum` gains a `seekable: true` option).

### C module (`c_src/spool.c`)

**Two structs, separate lifetimes:**

`SpoolResource` — the BEAM-owned NIF resource (`SPOOL_RT`):
- `int write_fd` — write end of the temp data file
- `int ctrl_write_fd` — write end of the control pipe (signal "more data")
- `char tmp_path[PATH_MAX]` — for `unlink` in the destructor

`SpoolCallbackData` — heap-allocated, owned by the `VipsSourceCustom` GObject:
- `int read_fd` — read end of the temp data file (independent file position from `write_fd`)
- `int ctrl_read_fd` — read end of the control pipe (`poll()`-ed by the read callback)
- Freed via `GDestroyNotify` when libvips unrefs the `VipsSourceCustom`

Separating these structs decouples BEAM resource lifetime (controlled by Elixir/GC) from
callback data lifetime (controlled by libvips refcounting). Neither holds a raw pointer to
the other.

**Three NIFs:**

`nif_source_spool_new()`:
- `mkstemp(tmp_path)` — creates temp file atomically, returns `write_fd`
- `open(tmp_path, O_RDONLY)` — `read_fd` for callbacks
- `pipe(ctrl_fds)` — `ctrl_write_fd` (O_CLOEXEC, O_NONBLOCK) and `ctrl_read_fd`
- `vips_source_custom_new()`
- `g_signal_connect_data` for `"read"` and `"seek"` signals, with `SpoolCallbackData` as
  user_data and a `GClosureNotify` to close fds and free the struct when the source is finalized
- Returns `{spool_resource, source_term}` (source wrapped via existing `g_object_to_erl_term`)

`nif_source_spool_write(resource, binary)` — marked `ERL_NIF_DIRTY_JOB_IO_BOUND`:
- EINTR-safe write loop: `write(write_fd, data, len)` until all bytes written
- Write one byte to `ctrl_write_fd` to signal the read callback

`nif_source_spool_finalize(resource)`:
- Closes `ctrl_write_fd` — C sees `POLLHUP`, interprets as end-of-stream
- Closes `write_fd`
- Idempotent: repeated calls are no-ops (fds set to -1 after close)

**Resource destructor:**
- Closes `ctrl_write_fd` and `write_fd` if not already closed (handles process-killed
  cancellation where `finalize` was never called)
- `unlink(tmp_path)` — temp file removed regardless of how the spool ended
- `VipsSourceCustom` unref goes through the existing Janitor path (same as all GObjects in Vix)

**Read callback** (registered on `"read"` signal):

```
n = read(read_fd, buf, len)
if n > 0: return n
if n < 0: return -1  // real error
// n == 0: at write frontier
poll(ctrl_read_fd, POLLIN | POLLHUP, -1)
  POLLIN:  drain one byte, retry read
  POLLHUP: one final read(), return result (0 = true EOF, >0 = remaining bytes)
```

`poll` with no timeout is safe: `ctrl_write_fd` always has a defined close path (explicit
`finalize` or resource destructor).

**Seek callback** (registered on `"seek"` signal):

```c
return lseek(read_fd, offset, whence);
```

Five lines. `lseek` on a regular file always succeeds regardless of the write frontier;
if the new position is ahead of what has been written, the subsequent `read()` call handles
the wait via the poll loop above.

Registering both `"read"` and `"seek"` signals causes libvips to open the source with
`VIPS_ACCESS_RANDOM` (fully seekable). Without `"seek"`, it falls back to
`VIPS_ACCESS_SEQUENTIAL` — same limitation as the current pipe.

### Elixir module (`lib/vix/source_spool.ex`)

Plain module, `@moduledoc false`. Three functions delegating to NIFs:

```elixir
defmodule Vix.SourceSpool do
  @moduledoc false
  alias Vix.Nif

  def new(), do: Nif.nif_source_spool_new()
  def write(spool, bin), do: Nif.nif_source_spool_write(spool, bin)
  def finalize(spool), do: Nif.nif_source_spool_finalize(spool)
end
```

No GenServer. File writes go through a NIF (not Elixir's `File` module) so that
write + signal is one call, error propagation is unified, and the temp file lifecycle
is entirely owned by C.

### Image API (`lib/vix/vips/image.ex`)

`new_from_enum/2` gains a `seekable: true` option. When set, it routes to the spool
path instead of the pipe path. The two paths are otherwise identical in API contract.

The spool path follows the same `spawn_link` + `send/receive` pattern as the existing
pipe path:

```elixir
def new_from_enum(enum, opts \\ []) do
  {seekable, opts} = Keyword.pop(opts, :seekable, false)
  if seekable, do: new_from_enum_spool(enum, opts), else: new_from_enum_pipe(enum, opts)
end

defp new_from_enum_spool(enum, opts) do
  parent = self()

  pid =
    spawn_link(fn ->
      {:ok, {spool, source}} = SourceSpool.new()
      send(parent, {self(), source})

      try do
        Enum.each(enum, fn iodata ->
          :ok = SourceSpool.write(spool, IO.iodata_to_binary(iodata))
        end)
      after
        SourceSpool.finalize(spool)
      end
    end)

  receive do
    {^pid, source} ->
      with :ok <- validate_options(opts),
           {:ok, loader} <- Foreign.find_load_source(source),
           {:ok, {ref, _}} <- Operation.Helper.operation_call(loader, [source], opts) do
        {:ok, wrap_type(ref)}
      end
  end
end
```

`spawn_link` ensures that a crash in either the writer or the decoder kills the other.
`try/after` ensures `finalize` is called — and `ctrl_write_fd` is closed — even when the
stream raises. Since `finalize` is idempotent, the resource destructor running afterward
is harmless.

## Error handling and cancellation

| Failure | What happens |
|---|---|
| Stream error mid-way | `try/after` calls `finalize` → `ctrl_write_fd` closes → C sees `POLLHUP` → libvips gets incomplete file → decode error returned |
| Decode error | `spawn_link` kills writer child → resource destructor closes fds, unlinks temp file |
| Process killed | Resource destructor fires (eventually) → same cleanup path as decode error |

## Testing

- JPEG/PNG via `seekable: true` — baseline, behaviour identical to pipe path
- HEIF/AVIF — seek-heavy formats decode correctly end-to-end
- Stream error mid-way — `{:error, _}` returned, no temp files left behind
- Process killed during decode — no leaked temp files after GC
- `finalize/1` called twice — no crash, no error
- Explicit `finalize/1` followed by resource destructor — no double-close crash

## Trade-offs and limitations

- `seekable: false` (default) continues to use the pipe path — no temp file overhead for
  callers that don't need it and are not loading HEIF/AVIF.
- The temp file is always written to the OS default temp directory (`mkstemp` uses `$TMPDIR`
  or `/tmp`). On systems where `/tmp` is `tmpfs`, the "disk write" never hits physical storage.
  On systems with a slow `/tmp`, large images may see I/O overhead.
- The concurrent download-and-decode benefit is only measurable when chunk delivery latency
  is a significant fraction of total decode time. For fast origins, Tier 1 (user-space temp
  file + `new_from_file`) captures equivalent value at zero Vix cost.
