# SourceSpool design

**Date:** 2026-06-02
**Status:** Draft (revised after external review)

## Problem

Vix's only streaming-input primitive is a non-seekable OS pipe. `nif_source_new()` calls
`vips_source_new_from_descriptor` on the read end of a `pipe()` fd ([c_src/pipe.c:88](../../../c_src/pipe.c))
— read-once, sequential, no `lseek`. Decoders for seek-heavy formats (HEIF, AVIF, multi-page
TIFF) issue backward seeks during header parsing and decode. On a pipe those seeks fail,
degrading or breaking the decode.

The existing workarounds — `new_from_buffer/2` (whole body in memory, no overlap) or
`new_from_file/2` (caller manages a complete file) — do not let a decoder seek over an input
that is *still arriving* as an Elixir `Enumerable`.

## Goal

A native, seekable, concurrent source primitive — `Vix.SourceSpool` — that mirrors the two
wins imgproxy v4 gets from its async buffer:

1. **Overlap** — libvips begins decoding while the body is still downloading.
2. **Reopen** — multiple independent decodes (e.g. a cheap dimension probe, then a shrink-on-load
   pass) read the *same* in-flight buffer without re-fetching.

## Non-goals

- A general-purpose Elixir-controllable `VipsSourceCustom` (the rejected `vips-connection`
  approach — requires libvips to call back into the BEAM from its decode threads).
- Unknown-length concurrent seekable input. A seekable source must report a stable length
  (see "Why `content_length` is required"). Unknown-length inputs use the existing pipe path
  (sequential, non-seekable) or buffer fully first.
- Backpressure / bounded streaming. The spool buffers up to `content_length` in RAM; it is not
  a flow-controlled stream. Inputs too large for RAM are out of scope (use the pipe path).

## Why the boundary is safe (push, not pull)

The `vips-connection` branch had libvips **pull** from Elixir: the C read callback called *into*
the BEAM to request the next chunk, which means a non-BEAM thread driving an Elixir process —
the coordination the maintainer rejected.

This design **pushes**: Elixir writes chunks into a C-owned buffer via a NIF; libvips reads from
that buffer on its own decode threads. The C read/seek callbacks never call Elixir, never send a
message, never touch a BEAM process. All coordination is C↔C via `enif_mutex`/`enif_cond`, which
are valid on any thread, not just BEAM schedulers.

## Why `content_length` is required

libvips treats a *seekable* `VipsSource` as a file with a **stable length**. When a source
reports that it can seek, libvips probes its length early via `vips_source_length()` (which does
`SEEK_END`) and **caches** the result; later `vips_source_seek()` rejects seeks beyond that
cached length.

If `SEEK_END` returned the current *write frontier* (bytes arrived so far), libvips would cache a
too-small length and later reject valid seeks into bytes that arrived afterward. Therefore the
concurrent seekable path **requires the final byte length up front**. `SEEK_END` returns that
declared `content_length` immediately; reads to not-yet-arrived offsets block at the frontier.

A growing plain file via `new_from_file` cannot solve this: libvips `fstat`s the fd and gets the
truthful current size — you cannot make `fstat` report the eventual length. Only a custom source
with a seek callback that returns the known length is correct. The in-memory `VipsSourceCustom`
is the minimal form of that; a file-backed version would be the same model plus temp-file
lifecycle.

## Why a single source needs only one reader, but the service needs many

libvips cannot clone a `VipsSourceCustom` — the source *is* the object holding our callbacks, so
within one load pipeline there is exactly one read position. The sniff→load handoff
(`find_load_source` reads the header, then the loader rewinds to 0) and shrink-on-load
(`vips_thumbnail_source` reads the header, rewinds, re-decodes with a shrink factor) are both
**sequential reuse of one source**, rewinding to 0 between passes. This requires seek-to-0 and
**retaining all bytes from offset 0** (no eviction) — which a growing buffer provides — but not
multiple simultaneous readers.

Multiple readers are needed one level up: an imgproxy-style service that decodes the *same
download* more than once (probe then process, or animated re-processing) while it is still
arriving. That is `SourceSpool.source/1` minting several `VipsSourceCustom`s over one shared
buffer, each with its own cursor.

## Architecture

### Native objects (`c_src/spool.c`)

One shared, refcounted buffer; many lightweight reader cursors.

```c
typedef enum { SPOOL_OPEN, SPOOL_DONE, SPOOL_ABORTED } SpoolState;

typedef struct {
    _Atomic unsigned refcnt;

    ErlNifMutex *lock;
    ErlNifCond  *cond;        // broadcast on: data appended, state change

    uint8_t *data;            // enif_alloc / enif_realloc / enif_free
    gint64   size;            // bytes written so far  (the write frontier)
    gint64   capacity;        // allocated
    gint64   content_length;  // declared final size (required, stable)
    gint64   max_bytes;       // caller/operator policy cap; content_length must be <= this

    SpoolState state;
    int        err_errno;     // set when state == SPOOL_ABORTED due to a write error
} SpoolBuf;

typedef struct {             // one per VipsSourceCustom; owns one SpoolBuf ref
    SpoolBuf *buf;
    gint64    read_pos;      // this reader's cursor
} SpoolReader;
```

`SpoolBuf` is **not owned by either world directly**; it is refcounted. References:

- the **write handle** BEAM resource (held by the writer process, and shared to the parent) — 1 ref;
- each `VipsSourceCustom` via its `SpoolReader` — 1 ref apiece.

The buffer, its `data`, mutex, and condvar are freed only when the last ref drops
(`spool_unref` → 0). This removes the double-free and use-after-free classes the review flagged:
the buffer outlives whichever of {writer handle, any source} disappears first.

### NIFs and resources

`SPOOL_WRITE_RT` resource wraps `{SpoolBuf *buf; ErlNifMonitor mon;}`.

`nif_source_spool_new(content_length, max_bytes)` — regular scheduler:
- validate `0 <= content_length <= max_bytes` (`max_bytes` is the caller's policy cap, e.g. set
  from service config when `content_length` comes from an untrusted `Content-Length` header)
- allocate `SpoolBuf` (refcnt = 1), mutex, condvar; initial capacity small (e.g. 64 KB), grows
- allocate `SPOOL_WRITE_RT` handle holding the buf ref
- `enif_self` + `enif_monitor_process(env, handle, &writer_pid, &mon)` — monitors the **writer**
  (this NIF is called from inside the writer process)
- returns `{:ok, write_handle}`

`nif_source_spool_write(handle, binary)` — `ERL_NIF_DIRTY_JOB_CPU_BOUND` (memcpy/realloc;
matches the existing `nif_write` at [c_src/vix.c:172](../../../c_src/vix.c)):
- lock; if `state != OPEN` → unlock, `{:error, :closed}`
- if `chunk > content_length - size` → `state = ABORTED`, broadcast, unlock, `{:error, :overflow}`
- `ensure_capacity` (overflow-safe doubling; `enif_realloc`, keep old pointer until the new one
  is known non-NULL); EINTR is N/A (no syscall) — pure memory copy
- `memcpy`, `size += chunk`, `cond_broadcast`, unlock, `:ok`

`nif_source_spool_finalize(handle)` — regular; idempotent:
- lock; if `state == OPEN`: `state = (size == content_length) ? DONE : ABORTED`
- `cond_broadcast`, unlock; returns `:ok` (or `{:error, :short}` if it had to abort)

`nif_source_spool_abort(handle)` — regular; idempotent:
- lock; if `state == OPEN` → `state = ABORTED`; `cond_broadcast`, unlock, `:ok`
- the parent calls this to stop a still-running writer (see Elixir flow)

`nif_source_spool_source(handle)` — regular:
- `spool_reader_new(buf)` → `spool_ref(buf)`, `read_pos = 0`
- `sc = vips_source_custom_new()`
- `g_object_set_data_full(sc, "vix-spool-reader", reader, spool_reader_free)` — the **single**
  owning destroy notify (`spool_reader_free` does `spool_unref(buf)` then frees the reader)
- `g_signal_connect(sc, "read", read_cb, reader)` and `..."seek", seek_cb, reader` — **non-owning**
  (no per-signal `GClosureNotify`; this is what avoids the double-free from attaching a free
  callback to both signals)
- returns `{:ok, %Vix.Vips.Source{ref: ...}}` via the existing `g_object_to_erl_term`

**Write-handle resource destructor:** if `state == OPEN`, set `ABORTED` + broadcast (backstop);
then `spool_unref(buf)`. The `VipsSourceCustom` GObject unref goes through the existing Janitor
path like every other GObject in Vix.

**Monitor down callback (writer died):** lock; if `state == OPEN` → `ABORTED`; `cond_broadcast`;
unlock. This is the **primary liveness mechanism** — see below.

### Read callback (per reader `r`)

```
lock(buf)
while r->read_pos >= buf->size && buf->state == SPOOL_OPEN:
    enif_cond_wait(buf->cond, buf->lock)         // park at the frontier
if buf->state == SPOOL_ABORTED:
    unlock; errno = buf->err_errno ?: EIO; return -1
if r->read_pos >= buf->size:                     // state == DONE, at/after end
    unlock; return 0                             // true EOF
n = MIN(length, buf->size - r->read_pos)         // safe: read_pos < size
memcpy(out, buf->data + r->read_pos, n)
r->read_pos += n
unlock; return n
```

Returns `0` (EOF) only at a clean `DONE` end; `-1` on abort/error; never computes
`size - read_pos` when `read_pos >= size`.

### Seek callback (per reader `r`)

```
lock(buf)
switch (whence):
  SEEK_SET: base = 0
  SEEK_CUR: base = r->read_pos
  SEEK_END: base = buf->content_length          // stable, declared up front
  default:  unlock; errno = EINVAL; return -1
if add_overflow(base, offset, &new_pos) || new_pos < 0 || new_pos > buf->content_length:
    unlock; errno = EINVAL; return -1
r->read_pos = new_pos
unlock; return new_pos
```

Seeks up to `content_length` are legal even before those bytes arrive — the next read parks at
the frontier until they do. All positions/lengths are `gint64`; binary sizes (`size_t`) are
range-checked before being added.

### The dirty-NIF deadlock, and why the monitor (not the link) is the fix

A process parked in a dirty NIF **cannot receive exit signals or be killed until the NIF
returns.** The decode runs via `nif_vips_operation_call`, registered
`ERL_NIF_DIRTY_JOB_IO_BOUND` ([c_src/vix.c:116](../../../c_src/vix.c)); its read callback parks in
`enif_cond_wait`. If the writer dies, an exit signal to the (linked) parent is **queued, not
delivered**, because the parent is parked in that dirty NIF. Neither `spawn_link` nor
`spawn_monitor` can unpark it. → deadlock.

The pipe path is saved not by its link but by the **OS**: `pipe.c` registers
`enif_monitor_process` on the fd resource ([c_src/pipe.c](../../../c_src/pipe.c) `fd_rt_down`);
on writer death the write-fd is closed and the kernel delivers EOF to the blocked reader. The
spool has no OS equivalent, so it replicates the mechanism in C: the write handle's
`enif_monitor_process` down callback sets `ABORTED` and `cond_broadcast`s, unparking the
dirty-NIF reader. This fires independently of the parked parent. **This monitor is the liveness
guarantee; BEAM-level supervision is only for error reporting.**

### Elixir layer (`lib/vix/source_spool.ex`, `@moduledoc false`)

```elixir
@spec new(keyword) :: {:ok, reference()} | {:error, term()}      # content_length:, max_bytes:
@spec write(reference(), binary()) :: :ok | {:error, :closed | :overflow}
@spec finalize(reference()) :: :ok | {:error, :short}
@spec abort(reference()) :: :ok
@spec source(reference()) :: {:ok, Vix.Vips.Source.t()} | {:error, term()}
```

### Image API (`lib/vix/vips/image.ex`)

`new_from_enum/2` gains `seekable: true`, which **requires** `content_length:` and accepts an
optional `max_bytes:` (defaults to `content_length`):

```elixir
def new_from_enum(enum, opts \\ []) do
  {seekable, opts} = Keyword.pop(opts, :seekable, false)
  if seekable, do: new_from_enum_spool(enum, opts), else: new_from_enum_pipe(enum, opts)
end

defp new_from_enum_spool(enum, opts) do
  case Keyword.pop(opts, :content_length) do
    {nil, _} -> {:error, :content_length_required}
    {len, opts} ->
      {max, opts} = Keyword.pop(opts, :max_bytes, len)   # strip before loader opts
      parent = self()

      writer =
        spawn_link(fn ->
          case SourceSpool.new(content_length: len, max_bytes: max) do
            {:ok, spool} -> send(parent, {self(), {:ok, spool}}); feed_spool(enum, spool)
            {:error, _} = err -> send(parent, {self(), err})
          end
        end)

      receive do
        {^writer, {:ok, spool}} ->
          result =
            with :ok <- validate_options(opts),
                 {:ok, source} <- SourceSpool.source(spool),
                 {:ok, loader} <- Foreign.find_load_source(source),
                 {:ok, {ref, _}} <- Operation.Helper.operation_call(loader, [source], opts) do
              {:ok, wrap_type(ref)}
            end

          # spawn_link does NOT kill the writer on an {:error,_} return; stop it explicitly
          # so it cannot keep draining a large/infinite enum into RAM.
          with {:error, _} <- result, do: SourceSpool.abort(spool)
          result

        {^writer, {:error, _} = err} -> err
      end
  end
end

defp feed_spool(enum, spool) do
  try do
    enum
    |> Enum.reduce_while(:ok, fn iodata, _ ->
      case SourceSpool.write(spool, IO.iodata_to_binary(iodata)) do
        :ok -> {:cont, :ok}
        {:error, _} = e -> {:halt, e}        # aborted by parent / overflow → stop draining
      end
    end)
    |> case do
      :ok -> SourceSpool.finalize(spool)
      {:error, _} -> :ok
    end
  rescue
    _ -> SourceSpool.abort(spool)            # stream raised → surface as a decode error,
  catch                                      # not a propagated crash of the linked caller
    _, _ -> SourceSpool.abort(spool)
  end
end
```

The convenience wrapper mints one source. Services wanting reopen-while-downloading call the
`SourceSpool` API directly: `new` → spawn a feeder → `source/1` per decode → `abort` when done.

## Concurrency model (invariants)

These hold the design at "moderate, not gnarly." Treat them as binding during implementation;
each is a place where a small deviation becomes a use-after-free or a permanently parked
dirty-scheduler thread.

1. **One lock guards all mutable state.** `data`, `size`, `capacity`, `state`, `err_errno`, and
   every reader's `read_pos` are touched only while holding `buf->lock`. The immutable-after-`new`
   fields (`content_length`, `max_bytes`) may be read without it. `refcnt` is atomic and moved
   without the lock. There is exactly one lock, so there is no lock-ordering or nesting concern —
   and no code path may acquire `buf->lock` while already holding it (no spool function called
   under the lock re-takes it).

2. **Reads copy under the lock.** The read callback's `memcpy` from `buf->data` runs while the
   lock is held, because a concurrent `write` may `realloc` and move `data`. A pointer into
   `buf->data` must never escape the lock. *Do not* move the copy outside the lock to cut
   contention — that is an immediate use-after-free. (If contention ever matters, switch to the
   segmented buffer in "Memory and scheduler notes"; do not weaken this invariant.)

3. **Condvar waits are always `while`-loops, woken by broadcast.** Readers re-check
   `read_pos >= size && state == OPEN` after every wake, never an `if`. `enif_cond_broadcast`
   (not signal) is used so all cursors re-evaluate — required for multiple readers. `enif_cond_wait`
   is the only place the lock is released while "blocked"; no other code holds the lock across a
   blocking call (the `memcpy`/`realloc` in `write` are bounded CPU work, not blocking).

4. **All state transitions go through one chokepoint.** A single
   `spool_set_terminal_locked(buf, new_state, errno)` performs
   `if (state == OPEN) { state = new_state; err_errno = errno; } enif_cond_broadcast(cond)` and
   nothing mutates `state` anywhere else. Callers already holding the lock (the `write` overflow
   path) call it directly; callers that don't (`finalize`, `abort`, the monitor-down callback, the
   handle-dtor backstop) use a thin `spool_set_terminal` wrapper that locks around it — this is the
   reentrancy guard for invariant 1. `finalize` computes `size == content_length ? DONE : ABORTED`
   and passes it. `OPEN` is the only non-terminal state; `DONE`/`ABORTED` are sinks — so
   idempotency and first-transition-wins both fall out, and the five trigger paths collapse to five
   callers of one 6-line function.

5. **Callbacks use native primitives only.** `read_cb`/`seek_cb` run on libvips decode threads,
   not BEAM threads. They touch only `enif_mutex_*`/`enif_cond_*`, `memcpy`, and immutable fields —
   never an `ErlNifEnv`, a term API, or anything requiring a BEAM scheduler. This is what makes the
   C↔C boundary safe.

6. **Refcount is balanced.** `spool_ref` on each new holder (write handle; each `SpoolReader`),
   `spool_unref` on each release (handle dtor; `spool_reader_free`). The `data`, mutex, condvar, and
   struct are freed exactly once, by the `spool_unref` that drops `refcnt` to 0. Every `ref` has
   exactly one matching `unref`.

7. **Every park has a guaranteed wake.** A reader parked at the frontier is always woken by some
   `spool_set_terminal` caller — including the monitor-down callback, which fires even when the
   writer dies untrappably (kill / link-propagated exit). This is the liveness guarantee; without
   it a parked reader would hold a dirty-IO scheduler thread forever.

## Lifetimes

- **Writer:** linked to the caller; fills the buffer to `content_length`, finalizes, exits. Its
  lifetime is bounded by `content_length` (not "until the enum is exhausted" unboundedly).
- **Buffer:** refcounted; outlives the writer. Once finalized, the complete buffer satisfies any
  later lazy/random read with no writer involvement — so a returned lazy image stays valid as
  long as its source (and thus the buffer) is referenced.
- **Sources:** each holds a buffer ref via its `SpoolReader`; released when libvips unrefs the
  `VipsSourceCustom`.
- **Cancellation precedence:** explicit (`abort`/`finalize`) is primary; the writer's `try/rescue`
  handles in-process stream exceptions; the `enif_monitor_process` down callback is the backstop
  for untrappable death (kill, link-propagated exit) — the case `try/rescue` cannot catch and the
  case that would otherwise deadlock a parked reader. The write-handle destructor is a last-resort
  backstop, not relied upon for timing.

## Error semantics (honest table)

| Event | What actually happens |
|---|---|
| Stream raises mid-feed | writer `rescue`s → `abort` → reader sees `ABORTED` → decode returns `{:error, _}`; the linked caller is **not** crashed |
| Writer killed (`:kill`) or link-propagated exit | `try/rescue` cannot catch it → **monitor down callback** sets `ABORTED` + broadcast → parked reader unparks with `-1` |
| Decode returns `{:error, _}` | parent (now unparked) calls `SourceSpool.abort` → next `write/2` returns `{:error, :aborted}` → `reduce_while` halts, writer stops draining |
| `finalize` with `size < content_length` | `ABORTED` (truncated stream ≠ clean EOF); writer gets `{:error, :short}` |
| `write` after `finalize`/abort | `{:error, :closed}` (never silently appends past an exposed EOF) |
| `seekable: true` without `content_length` | `{:error, :content_length_required}` before any work |

## Memory and scheduler notes

- The buffer holds up to `content_length` bytes in RAM for the lifetime of its sources. If a
  loader maps the source (`vips_source_map` copies the whole source into a `GByteArray`), peak
  RAM can **exceed** `new_from_buffer/2` (spool buffer + libvips copy + realloc growth peak). This
  path trades RAM for the overlap/reopen wins and suits bounded inputs; large/unknown inputs
  should use the pipe path.
- `content_length` is the effective buffer cap; `max_bytes` (a caller/operator policy cap,
  defaulting to `content_length`) rejects a declared length above policy at `new`.
- The write NIF is `DIRTY_JOB_CPU_BOUND`; the decode (and thus the blocking read callback) already
  runs on a dirty IO scheduler via `nif_vips_operation_call`. Each concurrently decoding source
  parks one dirty-IO scheduler thread while waiting at the frontier (default pool ~10) — the same
  per-decode characteristic as the pipe path.

## Testing

Correctness:
- JPEG/PNG via `seekable: true` — baseline parity with the pipe path.
- HEIF/AVIF/multi-page TIFF — seek-heavy decode end-to-end.
- `SEEK_END` after only the first chunk arrived → returns `content_length`, not `size`.
- Seek within `content_length` but past the frontier, then feed the bytes → read unblocks with
  correct data.
- Slow, chunked HEIF/AVIF with `content_length` → decode demonstrably overlaps arrival.

Validation / safety:
- `seekable: true` without `content_length` → `{:error, :content_length_required}`.
- Negative `SEEK_SET`, negative `SEEK_CUR`, invalid `whence`, seek `> content_length` → `-1`.
- `write` beyond `content_length` → `{:error, :overflow}`; `finalize` short → `ABORTED`/`{:error, :short}`.
- `write` after `finalize` → `{:error, :closed}`.
- `content_length` exceeding `max_bytes` rejected at `new`.
- Allocation/`realloc`-failure path (fault injection if feasible).

Lifetime (ASan/valgrind):
- Source GC'd while writer/spool alive; spool handle GC'd while a source is still decoding.
- Both `read` and `seek` handlers destroyed → no double-free (single destroy notify).
- Writer killed while a read callback is parked → callback unparks via the monitor.
- Parent killed while writer is mid-`write` → native state released, no leak.

Multi-reader:
- `source/1` N times over one spool; concurrent decodes with independent cursors; the
  probe-then-shrink-on-load pattern on a still-arriving body.

## Open questions

- Whether to enrich the stream-error case by forwarding the original exception from `feed_spool`
  to the parent (so the caller gets the Elixir reason rather than the generic libvips decode
  error). Cheap to add; deferred until we see whether it matters in practice.
