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
the print-spool etymology. Here: Elixir writes chunks to a growing in-memory buffer; libvips
decodes from the same buffer via a `VipsSourceCustom` read handler that blocks at the write
frontier instead of returning EOF. The backing store is RAM, not disk.

All libvips-facing logic is pure C ↔ C (no BEAM re-entry). The `vips-connection` branch
required libvips to **pull** data from Elixir — the C read callback called into the BEAM to
request the next chunk, which means a non-BEAM thread driving an Elixir process. This design
reverses the direction: Elixir **pushes** chunks into a C buffer via the NIF write function.
The C read callback reads from a buffer that BEAM has already filled; it never calls Elixir,
never sends a message, never touches a BEAM process. The mutex/condvar is C ↔ C only —
`enif_mutex`/`enif_cond` work on any thread, not just BEAM threads.

### New files

| File | Purpose |
|---|---|
| `c_src/spool.c` | NIF implementation, VipsSourceCustom callbacks |
| `c_src/spool.h` | Declarations |
| `lib/vix/source_spool.ex` | Thin Elixir wrapper (`@moduledoc false`) |

Changes to existing files: `c_src/vix.c` (NIF registration), `lib/vix/nif.ex` (NIF stubs),
`lib/vix/vips/image.ex` (`new_from_enum` gains a `seekable: true` option).

### C module (`c_src/spool.c`)

**One struct, two owners:**

```c
typedef struct {
    uint8_t  *data;
    size_t    size;      // bytes written so far
    size_t    capacity;  // allocated capacity
    gint64    read_pos;  // current read position
    int       done;      // writer has finalized
    ErlNifMutex *lock;
    ErlNifCond  *cond;
} SpoolBuf;
```

The struct is allocated in `nif_source_spool_new`. Two things hold a reference to it:

1. **The BEAM resource** (`SPOOL_RT`) — the write handle Elixir holds. Its destructor signals
   `done` (in case `finalize` was never called) but does **not** free the struct.
2. **The `VipsSourceCustom` GObject** — via `g_signal_connect_data` with a `GClosureNotify`
   that frees the struct when libvips unrefs the source.

This decouples BEAM resource lifetime (controlled by Elixir/GC) from buffer lifetime
(controlled by libvips refcounting). The buffer lives until libvips is finished with it.

**Three NIFs:**

`nif_source_spool_new()`:
- `enif_alloc` + `enif_mutex_create` + `enif_cond_create`
- Initial buffer capacity (e.g. 64 KB), grows on demand
- `vips_source_custom_new()`
- `g_signal_connect_data` for `"read"` and `"seek"` signals, with `SpoolBuf*` as user_data
  and a `GClosureNotify` to free the struct and its sync primitives
- Returns `{spool_resource, source_term}` (source wrapped via existing `g_object_to_erl_term`)

`nif_source_spool_write(resource, binary)` — marked `ERL_NIF_DIRTY_JOB_IO_BOUND`:
- Lock, grow buffer if needed (`realloc`-style doubling), `memcpy`, `enif_cond_broadcast`, unlock

`nif_source_spool_finalize(resource)`:
- Lock, set `done = 1`, `enif_cond_broadcast`, unlock
- Idempotent: repeated calls are no-ops

**Resource destructor:**
- Calls finalize logic if not already done (handles process-killed cancellation)
- Does not free `SpoolBuf` — owned by `GClosureNotify`

**Read callback** (registered on `"read"` signal):

```
lock
while read_pos >= size && !done:
    enif_cond_wait(cond, lock)
n = min(len, size - read_pos)
memcpy(buf, data + read_pos, n)
read_pos += n
unlock
return n  // 0 only when done && read_pos == size (true EOF)
```

**Seek callback** (registered on `"seek"` signal):

```
lock
new_pos = (SEEK_SET: offset) | (SEEK_CUR: read_pos + offset) | (SEEK_END: size + offset)
read_pos = new_pos
unlock
return new_pos
```

`SEEK_END` before writing is complete returns the current (incomplete) `size`. This is the
same behaviour as a growing file: the subsequent `read()` waits at the frontier via the
condvar loop above. In practice, libvips uses `SEEK_SET` to known offsets when parsing
container formats (HEIF/AVIF); `SEEK_END` before `done` is rare.

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

No GenServer. The write path is a single NIF call (copy + signal), not two operations, so
error propagation and buffer lifecycle are unified in C.

### Image API (`lib/vix/vips/image.ex`)

`new_from_enum/2` gains a `seekable: true` option. When set, it routes to the spool path
instead of the pipe path. Both paths are identical in API contract.

The spool path follows the same `spawn_link` + `send/receive` pattern as the existing pipe path:

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
`try/after` ensures `finalize` is always called — setting `done = 1` and waking the read
callback — even when the stream raises. Since `finalize` is idempotent, the resource
destructor running afterward is harmless.

## Error handling and cancellation

| Failure | What happens |
|---|---|
| Stream error mid-way | `try/after` calls `finalize` → `done = 1`, condvar broadcast → read callback wakes, drains remaining data, returns 0 (EOF) → libvips gets incomplete input → decode error returned |
| Decode error | `spawn_link` kills writer child → resource destructor signals `done` → buffer freed by `GClosureNotify` when libvips unrefs source |
| Process killed | Resource destructor fires (eventually) → same path as decode error |

## Testing

- JPEG/PNG via `seekable: true` — baseline, behaviour identical to pipe path
- HEIF/AVIF — seek-heavy formats decode correctly end-to-end
- Stream error mid-way — `{:error, _}` returned, no memory leaked
- Process killed during decode — buffer freed after libvips unrefs source
- `finalize/1` called twice — no crash, no error
- Explicit `finalize/1` followed by resource destructor — no double-signal crash

## Trade-offs and limitations

- `seekable: false` (default) continues to use the pipe path — no buffer allocation overhead
  for callers that don't need seekability.
- The entire image occupies RAM for the duration of the decode. This is equivalent to
  `new_from_buffer/2` in memory terms. The file-backed alternative (temp file + control pipe)
  would allow the OS to page out cold data, but in practice libvips may seek to any position
  at any time, so pages stay hot regardless. For bounded-size inputs the difference is
  negligible.
- Buffer growth uses doubling (`realloc`-style). Peak allocation is up to 2× the image size
  before the final `realloc` settles. Callers with a known `max_body_bytes` bound can pre-size
  the buffer to avoid any reallocation (a future option, not required now).
- The concurrent decode benefit is only measurable when chunk delivery latency is a significant
  fraction of total decode time. For fast origins, Tier 1 (user-space temp file + `new_from_file`)
  captures equivalent value at zero Vix cost.
