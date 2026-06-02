# SourceSpool design

**Date:** 2026-06-02
**Status:** Draft (revised after second review round)

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

1. **Overlap** — libvips begins decoding while the body is still downloading. **Loader-dependent:**
   a loader that streams via `read`/`seek` (JPEG, PNG, progressive paths) overlaps; a loader that
   calls `vips_source_map()` pulls the *entire* declared length into memory before pixel decode, so
   download overlaps the map but decode does not. Whether HEIF/AVIF/TIFF map or stream must be
   measured per format (see Testing) — the headline win is real only for streaming loaders.
2. **Reopen** — multiple independent decodes (e.g. a cheap dimension probe, then a shrink-on-load
   pass) read the *same* in-flight buffer without re-fetching.

## Non-goals

- A general-purpose Elixir-controllable `VipsSourceCustom` (the rejected `vips-connection`
  approach — requires libvips to call back into the BEAM from its decode threads).
- Unknown-length concurrent seekable input. A seekable source must report a stable length
  (see "Why `content_length` is required"). Unknown-length inputs use the existing pipe path
  (sequential, non-seekable) or buffer fully first.
- Backpressure / bounded streaming. The spool holds up to `content_length` in RAM; it is not a
  flow-controlled stream. Inputs too large for RAM are out of scope (use the pipe path).
- A timeout on a stalled producer. A live-but-non-progressing writer parks readers indefinitely;
  cancellation is the caller's job via `abort/1` or a watchdog (see "Liveness and timeouts").

## Why the boundary is safe (push, not pull)

The `vips-connection` branch had libvips **pull** from Elixir: the C read callback called *into*
the BEAM to request the next chunk, which means a non-BEAM thread driving an Elixir process —
the coordination the maintainer rejected.

This design **pushes**: Elixir writes chunks into a C-owned buffer via a NIF; libvips reads from
that buffer on its own decode threads. The C read/seek callbacks never call Elixir, never send a
message, never touch a BEAM process or an `ErlNifEnv`. All coordination is C↔C via the buffer's
mutex/condvar, which are valid on any thread, not just BEAM schedulers.

## Why `content_length` is required

libvips treats a *seekable* `VipsSource` as a file with a **stable length**. When a source reports
it can seek, libvips probes its length early: `vips_source_test_features` calls `vips_source_length`
(which does `SEEK_CUR`, `SEEK_END`, then restores position) and **caches** the result in
`source->length`; later `vips_source_seek` rejects any position past that cached length. (Confirmed
against libvips source by two independent reviewers.)

If `SEEK_END` returned the current *write frontier*, libvips would cache a too-small length and
later reject valid seeks into bytes that arrive afterward. So the concurrent seekable path
**requires the final byte length up front**: `SEEK_END` returns the declared `content_length`
immediately; reads to not-yet-arrived offsets block at the frontier. A growing plain file via
`new_from_file` cannot solve this — `fstat` reports the truthful current size — which is exactly
why a custom source whose seek callback returns the known length is the only correct shape. A
regression test pins this behavior (see Testing).

## Why one source needs only one reader, but a service needs many

libvips cannot clone a `VipsSourceCustom` — the source *is* the object holding our callbacks, so
within one load pipeline there is exactly one read position. The sniff→load handoff
(`find_load_source` reads the header, the loader rewinds to 0) and shrink-on-load
(`vips_thumbnail_source` reads the header, rewinds, re-decodes with a shrink factor) are
**sequential reuse of one source**, rewinding to 0 between passes — requiring seek-to-0 and
retention of all bytes from offset 0 (the buffer never evicts), but not simultaneous readers.

Multiple readers arise one level up: an imgproxy-style service that decodes the *same download*
more than once while it is still arriving. That is `SourceSpool.source/1` minting several
`VipsSourceCustom`s over one shared buffer, each with its own cursor.

## Architecture

### Native objects (`c_src/spool.c`)

One shared, refcounted, **pre-allocated** buffer; many lightweight reader cursors.

```c
typedef enum { SPOOL_OPEN, SPOOL_DONE, SPOOL_ABORTED } SpoolState;

typedef struct {
    gatomicrefcount refcnt;   // GLib refcount (GLib is already a libvips dep)

    ErlNifMutex *lock;
    ErlNifCond  *cond;        // broadcast on: bytes published, state change

    guint8 *data;             // enif_alloc(content_length) ONCE; never realloc'd, never moves
    gint64  size;             // bytes published so far (the write frontier), 0..content_length
    gint64  content_length;   // declared final size; also the allocation size (immutable)

    SpoolState state;
    int        err_errno;     // set when state == SPOOL_ABORTED
} SpoolBuf;

typedef struct {              // one per VipsSourceCustom; owns one SpoolBuf ref
    SpoolBuf *buf;
    gint64    read_pos;       // this reader's cursor
} SpoolReader;
```

**Pre-allocation.** `content_length` is mandatory and is the buffer's exact size, so the buffer is
allocated once at `new` and **never reallocated**. Consequences that dissolve several review
findings: `data` never moves (no moving-pointer use-after-free), there is no mid-stream allocation
failure (allocation can only fail at `new`, which fails cleanly), there is no 2× realloc peak, and
the write path never copies the whole buffer under the lock. Lazy page-commit means declaring N
bytes does not touch N bytes of RAM until they are written.

`SpoolBuf` is refcounted, not owned by either world directly. References:
- the **write handle** BEAM resource (`SPOOL_WRITE_RT`) held by the writer process — 1 ref;
- each `VipsSourceCustom` via its `SpoolReader` — 1 ref apiece.

The buffer, `data`, mutex, and condvar are freed only when the last ref drops (`spool_unref` → 0).

### The write handle and the monitored process

`SPOOL_WRITE_RT` wraps `{SpoolBuf *buf; ErlNifPid writer; ErlNifMonitor mon;}`. The resource type is
opened with both a destructor and a **down callback**.

**The monitored process is whoever calls `new`, and that process must be the writer.** This is the
single most important contract in the design (four reviewers flagged the earlier "parent calls new,
separate feeder writes" recipe as monitoring the wrong process). The native monitor is what wakes a
reader parked in a dirty NIF when the producer dies; if it watches the wrong process, a feeder death
leaves readers parked forever. The public API encodes this so callers cannot get it wrong (see
`start_feeder/2`).

### NIFs

`nif_source_spool_new(content_length)` — regular scheduler:
- validate `0 <= content_length <= G_MAXINT64` **and** `content_length <= SIZE_MAX` (rejects on
  32-bit builds and absurd declared lengths); `max_bytes` policy is enforced in Elixir before this
  call (see API)
- `data = enif_alloc(content_length)` (for `content_length == 0`, allocate a 1-byte sentinel and
  treat `size`/EOF accordingly); on failure return `{:error, :enomem}` after freeing partials
- create mutex, condvar; `SpoolBuf` refcnt = 1
- allocate `SPOOL_WRITE_RT` `wr`; `wr->buf = buf`; `enif_self(env, &wr->writer)`
- `rc = enif_monitor_process(env, wr, &wr->writer, &wr->mon)` — **second arg is the resource object
  pointer `wr`, not the term**; `rc < 0` is a setup bug (no down callback) → fail; `rc > 0` (caller
  already dead — impossible for `self`) → terminal-abort defensively
- `term = enif_make_resource(env, wr)`; `enif_release_resource(wr)`; return `{:ok, term}`

`nif_source_spool_write(handle, binary)` — `ERL_NIF_DIRTY_JOB_CPU_BOUND` (matches the existing
`nif_write` at [c_src/vix.c:172](../../../c_src/vix.c)):
- if `enif_self != wr->writer` → `{:error, :not_owner}` (single-writer enforcement; no lock needed,
  `writer` is immutable)
- `enif_inspect_binary`; let `n = bin.size`
- lock; if `state != OPEN` → unlock, `{:error, :closed}`
- if `n > content_length - size` → `spool_set_terminal_locked(ABORTED, EFBIG)`; unlock;
  `{:error, :overflow}` (the C check is authoritative even though Elixir also guards)
- copy into `data[size .. size+n)` in **bounded slices** of `SPOOL_MAX_SLICE` (e.g. 256 KB): per
  slice, `memcpy`, advance `size`, `cond_broadcast`, and re-check `state` (so a concurrent `abort`
  stops a large chunk promptly). Lock is held across the loop but released-and-bounded per slice
  keeps the critical section small and lets regular control NIFs interleave.
- unlock; `:ok`

`nif_source_spool_finalize(handle)` — regular; idempotent; writer-only (`:not_owner` otherwise):
- lock; on `OPEN` → `spool_set_terminal_locked(size == content_length ? DONE : ABORTED, ENODATA)`
- returns: `OPEN→DONE` ⇒ `:ok`; `OPEN→ABORTED` (short) ⇒ `{:error, :short}`; already `DONE` ⇒ `:ok`;
  already `ABORTED` ⇒ `{:error, :aborted}`

`nif_source_spool_abort(handle)` — regular; idempotent; callable by **any** process:
- lock; `spool_set_terminal_locked(ABORTED, ECANCELED)`; unlock; `:ok`

`nif_source_spool_source(handle)` — regular:
- `reader = enif_alloc(...)`; on fail → `{:error, :enomem}`
- `spool_ref(buf)`; `reader->buf = buf`; `reader->read_pos = 0`
- `sc = vips_source_custom_new()`; on fail → `spool_unref(buf)`, free reader, `{:error, ...}`
- `g_object_set_data_full(G_OBJECT(sc), "vix-spool-reader", reader, spool_reader_free)` — the
  **single** owning destroy notify (`spool_reader_free` = `spool_unref(buf)` then `enif_free(reader)`);
  `reader` ownership is now the GObject's
- `g_signal_connect(sc, "read", G_CALLBACK(spool_read_cb), reader)` and `..."seek", spool_seek_cb,
  reader` — **non-owning** (no per-signal `GClosureNotify`; this is what avoids the double-free)
- `term = g_object_to_erl_term(env, sc)`; if that fails → `g_object_unref(sc)` (runs the destroy
  notify, releasing the reader+ref exactly once) and return error
- creating a source after `DONE` is valid (full buffer available); after `ABORTED`, return
  `{:error, :aborted}` rather than handing back a source that fails on first read

**Write-handle destructor:** `spool_set_terminal` backstop if still `OPEN`, then `spool_unref(buf)`.
**Monitor down callback (writer died):** `spool_set_terminal(ABORTED, EPIPE)` — the primary liveness
mechanism. **GObject lifetime:** the `VipsSourceCustom` is exposed as a BEAM resource via
`g_object_to_erl_term`, so OTP postpones NIF-library unload while any source exists — keeping the
`read_cb`/`seek_cb`/`spool_reader_free` function pointers valid (the same guarantee the existing
pipe `VipsSource` relies on; verify during implementation).

### Read callback

```c
static gint64 spool_read_cb(VipsSourceCustom *source, void *buffer,
                            gint64 length, void *user_data)
{
    SpoolReader *r = user_data;
    SpoolBuf *b = r->buf;

    if (length < 0 || buffer == NULL) { errno = EINVAL; return -1; }
    if (length == 0) return 0;

    enif_mutex_lock(b->lock);
    while (r->read_pos >= b->size && b->state == SPOOL_OPEN)
        enif_cond_wait(b->cond, b->lock);                 // park at the frontier

    if (b->state == SPOOL_ABORTED) { errno = b->err_errno; enif_mutex_unlock(b->lock); return -1; }
    if (r->read_pos >= b->size)    { enif_mutex_unlock(b->lock); return 0; }   // DONE, true EOF

    gint64 avail = b->size - r->read_pos;                 // > 0, and read_pos < size
    gint64 n = MIN3(length, avail, SPOOL_MAX_SLICE);      // short reads are legal
    memcpy(buffer, b->data + r->read_pos, (size_t) n);    // bounded; data never moves
    r->read_pos += n;
    enif_mutex_unlock(b->lock);
    return n;
}
```

Returns `0` only at a clean `DONE` end; `-1` (with `errno`) on abort; never computes
`size - read_pos` when `read_pos >= size`. `SPOOL_MAX_SLICE` bounds lock-hold even if libvips asks
for a huge `length`.

### Seek callback

```c
static gint64 spool_seek_cb(VipsSourceCustom *source, gint64 offset,
                            int whence, void *user_data)
{
    SpoolReader *r = user_data;
    SpoolBuf *b = r->buf;
    gint64 base, new_pos;

    enif_mutex_lock(b->lock);
    switch (whence) {
        case SEEK_SET: base = 0;             break;
        case SEEK_CUR: base = r->read_pos;   break;
        case SEEK_END: base = b->content_length; break;   // stable, declared up front
        default: enif_mutex_unlock(b->lock); errno = EINVAL; return -1;
    }
    if (add_overflows_gint64(base, offset, &new_pos) ||
        new_pos < 0 || new_pos > b->content_length) {
        enif_mutex_unlock(b->lock); errno = EINVAL; return -1;
    }
    r->read_pos = new_pos;
    enif_mutex_unlock(b->lock);
    return new_pos;
}
```

Seeks up to `content_length` are legal before those bytes arrive — the next read parks at the
frontier. All positions are `gint64`; binary sizes (`size_t`) are range-checked before use.

### The dirty-NIF liveness mechanism

A dirty NIF is **not asynchronously interrupted** when its process is terminating: OTP triggers the
process's links and monitors and marks it terminating, but the native function keeps running until
it returns, and resource deallocation is delayed until it does. (Earlier wording — "cannot receive
exit signals" — overstated this; the corrected version is what matters.)

The consequence: the decode runs via `nif_vips_operation_call`
(`ERL_NIF_DIRTY_JOB_IO_BOUND`, [c_src/vix.c:116](../../../c_src/vix.c)); its read callback parks in
`enif_cond_wait`. A BEAM link or monitor cannot make that callback return. The pipe path is saved by
the OS — `pipe.c`'s `enif_monitor_process` closes the write-fd on writer death and the kernel
delivers EOF. The spool replicates this in C: the **write-handle's monitor down callback** sets
`ABORTED` and broadcasts, unparking the reader. That fires independently of the parked decode
process. **This monitor is the liveness guarantee; BEAM-level supervision is only for error
reporting.**

### Elixir layer — `Vix.SourceSpool` (public, opaque)

Now a documented public module (it is a real API surface given `source/1`), with an opaque handle.

```elixir
defmodule Vix.SourceSpool do
  @opaque t :: %__MODULE__{ref: reference()}
  defstruct [:ref]

  @spec new(keyword) :: {:ok, t} | {:error, term}          # content_length:, max_bytes:
  @spec write(t, binary) :: :ok | {:error, :closed | :overflow | :not_owner}
  @spec finalize(t) :: :ok | {:error, :short | :aborted | :not_owner}
  @spec abort(t) :: :ok
  @spec source(t) :: {:ok, Vix.Vips.Source.t()} | {:error, :aborted | term}

  # Packages the monitor-safe handshake: spawns a linked feeder that calls new/1 (so the FEEDER
  # is the monitored writer), feeds the enum, and finalizes at exactly content_length.
  @spec start_feeder(Enumerable.t(), keyword) :: {:ok, t, pid} | {:error, term}
end
```

`new/1` enforces `content_length <= max_bytes` (default `max_bytes = content_length`) before the
NIF; `max_bytes` is the caller/operator policy cap, meaningful when `content_length` comes from an
untrusted `Content-Length`. Services that want reopen-while-downloading use `start_feeder/2` then
call `source/1` per decode — they never call `new/1` in the wrong process.

### Image API (`lib/vix/vips/image.ex`)

`new_from_enum/2` gains `seekable: true`, requiring `content_length:` and accepting `max_bytes:`:

```elixir
def new_from_enum(enum, opts \\ []) do
  {seekable, opts} = Keyword.pop(opts, :seekable, false)
  if seekable, do: new_from_enum_spool(enum, opts), else: new_from_enum_pipe(enum, opts)
end

defp new_from_enum_spool(enum, opts) do
  {len, opts} = Keyword.pop(opts, :content_length)
  if is_nil(len) do
    {:error, :content_length_required}
  else
    {max, opts} = Keyword.pop(opts, :max_bytes, len)
    case SourceSpool.start_feeder(enum, content_length: len, max_bytes: max) do
      {:error, _} = err -> err
      {:ok, spool, writer} ->
        try do
          with :ok <- validate_options(opts),
               {:ok, source} <- SourceSpool.source(spool),
               {:ok, loader} <- Foreign.find_load_source(source),
               {:ok, {ref, _}} <- Operation.Helper.operation_call(loader, [source], opts) do
            {:ok, wrap_type(ref)}
          else
            {:error, _} = err -> SourceSpool.abort(spool); err   # stop the feeder draining RAM
          end
        catch
          kind, reason -> SourceSpool.abort(spool); :erlang.raise(kind, reason, __STACKTRACE__)
        end
    end
  end
end
```

`start_feeder/2` and its `feed_spool` finalize **at exactly `content_length`**, not at enum
exhaustion — critical, because a stream that yields exactly `content_length` bytes then blocks would
otherwise leave the reader parked at EOF forever:

```elixir
def start_feeder(enum, opts) do
  parent = self()
  len = Keyword.fetch!(opts, :content_length)

  writer =
    spawn_link(fn ->
      case new(opts) do
        {:ok, spool} -> send(parent, {self(), {:ok, spool}}); feed_spool(enum, spool, len)
        {:error, _} = err -> send(parent, {self(), err})
      end
    end)

  receive do
    {^writer, {:ok, spool}}    -> {:ok, spool, writer}
    {^writer, {:error, _} = e} -> e
    {:EXIT, ^writer, reason}   -> {:error, reason}   # only delivered if caller traps exits
  end
end

defp feed_spool(enum, spool, len) do
  try do
    enum
    |> Enum.reduce_while(0, fn iodata, written ->
      bin = IO.iodata_to_binary(iodata)
      case write(spool, bin) do
        :ok ->
          case written + byte_size(bin) do
            ^len = n -> finalize(spool); {:halt, {:filled, n}}   # finalize on exact fill
            n        -> {:cont, n}
          end
        {:error, _} = e -> {:halt, e}                            # aborted/overflow → stop
      end
    end)
    |> case do
      {:filled, _} -> :ok
      {:error, _}  -> :ok
      _short       -> finalize(spool)                            # enum ended early → {:error, :short}
    end
  rescue
    _ -> abort(spool)        # stream raised → surface as a decode error, not a caller crash
  catch
    _, _ -> abort(spool)
  end
end
```

## Concurrency model (invariants)

Binding during implementation; each guards a use-after-free or a permanently parked dirty-scheduler
thread.

1. **One lock guards all mutable state.** `size`, `state`, `err_errno`, and each reader's `read_pos`
   are touched only under `buf->lock`. Immutable-after-`new` fields (`data`, `content_length`,
   `writer`) are read without it. `refcnt` uses GLib atomics. There is one lock — no ordering or
   nesting — and no spool function called under the lock re-takes it (see invariant 4 for the
   reentrancy guard).
2. **Copies happen under the lock, in bounded slices.** Because the buffer is pre-allocated, `data`
   never moves, so this is a *simplicity* choice, not a moving-pointer safety requirement — but it
   is still required as written so that a reader observes a consistent `size`. `SPOOL_MAX_SLICE`
   bounds each `memcpy` (read and write) so the critical section stays small and control NIFs
   (`abort`/`finalize`) are not blocked behind a large copy. (A future lock-free reader using a
   published-index/acquire-release pattern is possible precisely *because* `data` is stable — see
   Deferred; not adopted in v1.)
3. **Condvar waits are `while`-loops woken by broadcast.** Readers re-check
   `read_pos >= size && state == OPEN` after every wake, never an `if`. `enif_cond_broadcast` (not
   signal) so all cursors re-evaluate. `enif_cond_wait` is the only place the lock is released while
   blocked.
4. **All state transitions go through one chokepoint.** `spool_set_terminal_locked(buf, new_state,
   errno)` does `if (state == OPEN) { state = new_state; err_errno = errno; } enif_cond_broadcast`;
   nothing else writes `state`. Callers already holding the lock (`write` overflow) call it
   directly; callers that do not (`finalize`, `abort`, monitor-down, dtor backstop) use the locking
   `spool_set_terminal` wrapper — this is the reentrancy guard for invariant 1. `DONE` is asserted
   only when `size == content_length`. `OPEN` is the only non-terminal state; idempotency and
   first-transition-wins both fall out.
5. **Callbacks use native primitives only.** `read_cb`/`seek_cb` run on libvips threads and touch
   only `enif_mutex_*`/`enif_cond_*`, `memcpy`, `errno`, and immutable fields — never an
   `ErlNifEnv`, a term API, or a BEAM scheduler.
6. **Refcount is balanced (GLib atomics).** `spool_ref` per new holder (write handle; each
   `SpoolReader`), `spool_unref` per release (handle dtor; `spool_reader_free`). Freed once, by the
   `spool_unref` that drops to 0.
7. **Terminal transitions wake all readers; writer *death* always causes one.** A parked reader is
   woken when bytes arrive, on any terminal transition, or by the monitor-down callback on writer
   death. It is **not** woken if the writer is alive but stalled forever (a hung upstream enum) —
   that is the same failure mode as a stalled pipe writer and requires external `abort/1`/timeout
   (see Liveness and timeouts).

## Liveness and timeouts

The monitor guarantees wake-up on writer *death*. A writer that is alive but stalled (hung HTTP
client, blocked upstream) parks readers indefinitely. The caller cannot self-rescue once parked in
`Operation.Helper.operation_call/3` (it is in a dirty NIF). A service must therefore either bound
the upstream enum itself, or run a **watchdog** process that holds the spool handle and calls
`abort/1` on timeout — `abort/1` is callable from any process and wakes all readers. This is
documented as the caller's responsibility, not the primitive's.

## Lifetimes

- **Writer:** the process that calls `new` (inside `start_feeder`); linked to the caller; fills to
  exactly `content_length`, finalizes, exits. Bounded by `content_length`, not enum length.
- **Buffer:** refcounted; outlives the writer. Once finalized, the complete buffer satisfies any
  later lazy/random read with no writer involvement.
- **Sources:** each holds a buffer ref via its `SpoolReader`; released when libvips unrefs the
  `VipsSourceCustom`.
- **Returned lazy image retains its source (invariant + test).** The wrapper's `source` term goes
  out of scope when `new_from_enum_spool/2` returns, so correctness depends on the load operation
  holding its own ref to the `VipsSourceCustom` for the image's lazy lifetime. This is the same
  dependency the existing pipe-based `new_from_enum` already relies on; it is made an explicit
  invariant here and covered by a GC-the-source-term-then-evaluate-pixels ASan test.
- **Cancellation precedence:** explicit (`abort`/`finalize`) is primary; the writer's `try/rescue`
  handles in-process stream exceptions; the monitor down callback is the backstop for untrappable
  death (`:kill`, link-propagated exit) — the case `try/rescue` cannot catch and the one that would
  otherwise deadlock a parked reader. The handle destructor is a last-resort backstop.

## Error semantics (honest)

| Event | What actually happens |
|---|---|
| Stream raises mid-feed | writer `rescue`s → `abort` (`ECANCELED`) → reader sees `ABORTED` → decode returns `{:error, _}`; the linked caller is **not** crashed |
| Writer `:kill` / link-propagated exit | uncatchable by `rescue` → **monitor down** sets `ABORTED` (`EPIPE`) → parked reader returns `-1`. **But** because of `spawn_link`, the queued exit may still kill the caller after the dirty NIF returns, unless it traps exits — so this is *not* a guaranteed `{:error, _}` path |
| Decode returns `{:error, _}` | parent (unparked) calls `abort` → next `write` returns `{:error, :aborted/:closed}` → `feed_spool` halts, writer stops draining |
| Parent raises during decode setup | `catch` → `abort` → re-raise; feeder stopped |
| `finalize` with `size < content_length` | `ABORTED`; `{:error, :short}` |
| `write` after terminal | `{:error, :closed}` (post-DONE) or `{:error, :aborted}`; never silently appends |
| `write`/`finalize` from non-writer pid | `{:error, :not_owner}` |
| `seekable: true` without `content_length` | `{:error, :content_length_required}` before any work |
| allocation fails at `new` | `{:error, :enomem}`, partials freed (no mid-stream alloc failure exists) |

## Memory and scheduler notes

- The buffer holds `content_length` bytes (lazily committed) for the lifetime of its sources. If a
  loader calls `vips_source_map`, peak RAM can **exceed** `new_from_buffer/2` (spool buffer + the
  libvips `GByteArray` copy). This path trades RAM for the overlap/reopen wins; large/unknown inputs
  use the pipe path.
- `content_length` is the buffer size; `max_bytes` (Elixir-side policy cap) rejects a declared
  length above policy at `new`.
- The write NIF is `DIRTY_JOB_CPU_BOUND`; the decode (and its blocking read callback) already runs
  on a dirty IO scheduler via `nif_vips_operation_call`. Each concurrently decoding source parks one
  dirty-IO scheduler thread while waiting at the frontier (default pool ~10) — the same per-decode
  characteristic as the pipe path. `abort`/`finalize`/`source` stay on regular schedulers and are
  kept responsive by `SPOOL_MAX_SLICE`-bounded lock holds.

## Testing

Correctness:
- JPEG/PNG via `seekable: true` — baseline parity with the pipe path.
- HEIF/AVIF/multi-page TIFF — seek-heavy decode end-to-end.
- **Length-caching regression:** `SEEK_END` after only the first chunk arrived returns
  `content_length` (not `size`); then a later seek into a high offset succeeds once bytes arrive —
  pinning the libvips length-cache behavior this design depends on.
- Seek within `content_length` but past the frontier, then feed the bytes → read unblocks correctly.
- **Overlap instrumentation:** for each of HEIF/AVIF/TIFF, log first-write / first-read / last-write
  / op-return timestamps under slow chunked input to record whether the loader streams (decode
  overlaps) or maps (decode waits for full body). This validates or falsifies the headline goal
  per format.

Validation / safety:
- `seekable: true` without `content_length` → `{:error, :content_length_required}`.
- Negative `SEEK_SET`/`SEEK_CUR`, invalid `whence`, seek `> content_length` → `-1`.
- `read_cb` with negative/zero `length` or NULL buffer → `-1`/`0`, no crash (direct signal-emission).
- `write` beyond `content_length` → `{:error, :overflow}`; `finalize` short → `{:error, :short}`.
- `write` after `finalize` → `{:error, :closed}`; `write`/`finalize` from non-writer → `:not_owner`.
- `content_length` exceeding `max_bytes` rejected in `new/1`; `content_length > SIZE_MAX` (32-bit)
  rejected in the NIF; `content_length == 0` → `SEEK_END` 0, `finalize` ok, EOF after `DONE`.
- **Exact-length non-terminating enum:** yields exactly `content_length` then blocks/raises if
  pulled again — the writer must `finalize` without requesting the extra item.

Process semantics:
- Writer `:kill` with a non-trapping caller vs. a trapping caller → behavior matches the honest
  table (caller may exit; or `{:EXIT}` branch returns `{:error, _}`).
- Caller traps exits and the writer dies before sending the handle → `start_feeder` returns
  `{:error, _}`, no hang.
- Decode returns `{:error, _}` on a large/slow enum → feeder aborted, RAM stops growing.
- **Monitor-ownership regression:** mint the spool via `start_feeder` (correct), kill the feeder
  while a reader is parked → reader wakes with `-1`. (And a deliberately-wrong manual `new`-in-parent
  setup demonstrates the footgun the API prevents.)

Lifetime (ASan/valgrind):
- Source GC'd while writer/spool alive; spool handle GC'd while a source is still decoding.
- Both `read` and `seek` handlers destroyed → no double-free (single destroy notify).
- `source/1` failure-injection (`vips_source_custom_new` fail, `g_object_to_erl_term` fail) → no
  leaked `SpoolBuf` ref, exactly one reader free.
- `enif_monitor_process` failure injection / missing down callback → `new` fails, partials freed.
- **Lazy-image lifetime:** return a lazy image, force-GC the local source term, then evaluate pixels
  later under slow input → still safe (proves the load op retains the source).
- Writer killed after writing exactly `content_length` but before `finalize` → `ABORTED`, readers wake.

Multi-reader:
- `source/1` ×N over one spool; concurrent decodes with independent cursors; probe-then-shrink-load
  on a still-arriving body. `source/1` after `DONE` works; after `ABORTED` → `{:error, :aborted}`.

## Deferred (not v1)

- **Lock-free reader copies.** Pre-allocation makes `data` stable, so a published-index
  (acquire/release) pattern could copy outside the lock and remove reader serialization for the
  multi-reader case. Kept under the lock in v1 for simplicity.
- **Decode-owner cancellation.** Monitoring the decode process (not just the writer) would let a
  dead decode owner promptly `abort` instead of completing the decode before its death finalizes.
  A latency optimization, not a liveness requirement (the writer monitor + data flow already prevent
  permanent parking).
- **Forwarding the original stream exception** from `feed_spool` to the caller for a richer error
  reason than the generic libvips decode error.
- **`iodata` write contract.** The wrapper converts via `IO.iodata_to_binary`; the NIF stays
  `binary`. A public `iodata` contract is a nicety if `SourceSpool` sees direct heavy use.
