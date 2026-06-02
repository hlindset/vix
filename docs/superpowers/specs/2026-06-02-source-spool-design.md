# SourceSpool design

**Date:** 2026-06-02
**Status:** Draft (architecture converged after four review rounds; remaining items are
implementation rigor, captured in the Implementation checklist)

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

typedef struct {              // a SPOOL_BUF_RT NIF resource — the VM owns its refcount
    ErlNifMutex *lock;
    ErlNifCond  *cond;        // broadcast on: bytes published, state change

    guint8 *data;             // enif_alloc(content_length) ONCE; never realloc'd, never moves
    gint64  size;             // bytes published so far (the write frontier), 0..content_length
    gint64  content_length;   // declared final size; also the allocation size (immutable)

    SpoolState state;
    int        err_errno;     // set when state == SPOOL_ABORTED
} SpoolBuf;

typedef struct {              // one per VipsSourceCustom; keeps one SPOOL_BUF_RT ref
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

`SpoolBuf` is itself a NIF resource (`SPOOL_BUF_RT`); its refcount is the BEAM's, taken with
`enif_keep_resource` and dropped with `enif_release_resource` — no GLib/C11 atomics, and no
portability question. Holders:
- the **write handle** (`SPOOL_WRITE_RT`) — the creation ref;
- each `VipsSourceCustom` via its `SpoolReader` — one `keep` apiece.

The resource destructor frees `data`, mutex, and condvar when the last ref drops (never call the
releasing `enif_release_resource` while holding `buf->lock` — the destructor would destroy the lock
under you). Making the buffer a resource also **pins the NIF library**: OTP postpones library unload
while any `SPOOL_BUF_RT` exists, so the `read_cb`/`seek_cb`/`spool_reader_free` function pointers held
by a live `VipsSourceCustom` can never dangle — even if the Elixir-side source term is GC'd while
libvips still holds the GObject.

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
- copy in a **lock-per-slice** loop of `SPOOL_MAX_SLICE` (e.g. 256 KB) chunks. Per slice: **lock**;
  if `state == DONE` → unlock, `{:error, :closed}`; if `state == ABORTED` → unlock, `{:error,
  :aborted}`; if `remaining > content_length - size` → `spool_set_terminal_locked(ABORTED, EFBIG)`,
  unlock, `{:error, :overflow}`; else `memcpy` one slice, advance `size`, `cond_broadcast`,
  **unlock**; advance the input pointer. Releasing the lock *between* slices is what actually lets
  `abort`/`finalize`/readers interleave — and it is safe precisely because only the single owner
  process advances `size`, so no concurrent writer can race. A mid-write `abort` is observed at the
  next slice and stops promptly.
- `:ok` when all bytes are copied

`nif_source_spool_finalize(handle)` — regular; idempotent; writer-only (`:not_owner` otherwise):
- lock; on `OPEN` → `spool_set_terminal_locked(size == content_length ? DONE : ABORTED, ENODATA)`
- returns: `OPEN→DONE` ⇒ `:ok`; `OPEN→ABORTED` (short) ⇒ `{:error, :short}`; already `DONE` ⇒ `:ok`;
  already `ABORTED` ⇒ `{:error, :aborted}`

`nif_source_spool_abort(handle)` — regular; idempotent; callable by **any** process:
- lock; `spool_set_terminal_locked(ABORTED, ECANCELED)`; unlock; `:ok`

`nif_source_spool_source(handle)` — regular:
- **lock**; if `state == ABORTED` → unlock, `{:error, :aborted}` (the check is under the same lock
  as the terminal transition; a `DONE` or `OPEN` spool proceeds — `OPEN` is the overlap path).
  `reader = enif_alloc(...)`; `enif_keep_resource(buf)`; `reader->buf = buf`; `reader->read_pos = 0`;
  unlock. (A concurrent `abort` *after* this check still leaves a valid source that fails on first
  read — documented, not a bug.)
- `sc = vips_source_custom_new()`; on fail → `enif_release_resource(buf)`, free reader, `{:error, ...}`
- `g_object_set_data_full(G_OBJECT(sc), "vix-spool-reader", reader, spool_reader_free)` — the
  **single** owning destroy notify (`spool_reader_free` = `enif_release_resource(buf)` then
  `enif_free(reader)`); `reader` ownership is now the GObject's
- `g_signal_connect(sc, "read", G_CALLBACK(spool_read_cb), reader)` and `..."seek", spool_seek_cb,
  reader` — **non-owning** (no per-signal `GClosureNotify`; this is what avoids the double-free)
- `term = g_object_to_erl_term(env, sc)`; if that fails → `g_object_unref(sc)` (runs the destroy
  notify, releasing the reader+ref exactly once) and return error
- creating a source after `DONE` is valid (full buffer available); after `ABORTED`, return
  `{:error, :aborted}` rather than handing back a source that fails on first read

**Write-handle destructor:** `spool_set_terminal` backstop if still `OPEN`, then
`enif_release_resource(buf)` (outside the lock).
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

**Explicit invariant (guards against a future "optimization"):** a read at declared EOF — i.e.
`read_pos == content_length` reached via `SEEK_END` before the writer finalizes — *blocks while
`OPEN`* and returns `0` only after `DONE` (or `-1` after `ABORTED`). It must **never** return `0`
just because `read_pos == content_length`; EOF is only knowable once the writer finalizes, and a
premature `0` would let a loader conclude the stream is complete too early. Note also that `ABORTED`
poisons the *whole* source: a reader at an already-published earlier offset still gets `-1`, by
design (an incomplete declared object is invalid; fail fast).

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
  @opaque t :: %__MODULE__{ref: term()}     # ref is a NIF resource term, NOT an Erlang reference()
  defstruct [:ref]

  # PRIMARY constructor. Spawns a monitored feeder that calls new/1 internally (so the FEEDER is the
  # monitored writer), feeds the enum, and finalizes at exactly content_length. Returns the spool
  # handle for source/1 + abort/1, and the feeder pid for supervision/watchdogs.
  @spec start_feeder(Enumerable.t(), keyword) :: {:ok, t, pid} | {:error, term}

  @spec source(t) :: {:ok, Vix.Vips.Source.t()} | {:error, :aborted | term}
  @spec abort(t) :: :ok                     # callable by any process holding the handle

  # LOW-LEVEL / ADVANCED. The process that calls new/1 becomes the *only* process permitted to
  # write/2 and finalize/1, and is the process the native monitor watches — its death aborts the
  # spool. Calling new/1 in the wrong process is the footgun start_feeder/2 exists to prevent;
  # most callers should never touch these three.
  @spec new(keyword) :: {:ok, t} | {:error, term}          # content_length:, max_bytes:
  @spec write(t, binary) :: :ok | {:error, :closed | :aborted | :overflow | :not_owner}
  @spec finalize(t) :: :ok | {:error, :short | :aborted | :not_owner}
end
```

`new/1` enforces `content_length <= max_bytes` before the NIF. **`max_bytes` defaults to a
library-level policy cap, *not* `content_length`** —
`Application.get_env(:vix, :source_spool_max_bytes, 104_857_600)` (100 MiB) — so an untrusted
`Content-Length` cannot reserve an unbounded buffer; callers raise it explicitly when they trust the
source. Writing the final byte does **not** imply `DONE`; the writer must call `finalize/1`
(`start_feeder/2` does this automatically) — otherwise readers parked at EOF wait until writer death
aborts the spool. Reopen-while-downloading keeps the spool handle alive and calls `source/1` per
decode.

### Image API (`lib/vix/vips/image.ex`)

`new_from_enum/2` gains `seekable: true`, requiring `content_length:` and accepting `max_bytes:`:

```elixir
def new_from_enum(enum, opts \\ []) do
  {seekable, opts} = Keyword.pop(opts, :seekable, false)
  if seekable, do: new_from_enum_spool(enum, opts), else: new_from_enum_pipe(enum, opts)
end

defp new_from_enum_spool(enum, opts) do
  {timeout, opts} = Keyword.pop(opts, :timeout)            # optional watchdog (ms)
  {len, opts}     = Keyword.pop(opts, :content_length)
  {max, opts}     = Keyword.pop(opts, :max_bytes, default_max_bytes())
  with {:ok, len} <- validate_content_length(len, max),    # validate BEFORE spawning/allocating
       :ok        <- validate_options(opts),
       {:ok, spool, _writer} <-
         SourceSpool.start_feeder(enum, content_length: len, max_bytes: max) do
    watchdog = timeout && start_watchdog(spool, timeout)    # sends abort/1 on timeout
    try do
      with {:ok, source} <- SourceSpool.source(spool),
           {:ok, loader} <- Foreign.find_load_source(source),
           {:ok, {ref, _}} <- Operation.Helper.operation_call(loader, [source], opts) do
        {:ok, wrap_type(ref)}
      else
        {:error, _} = err -> SourceSpool.abort(spool); err   # stop the feeder draining RAM
      end
    catch
      kind, reason -> SourceSpool.abort(spool); :erlang.raise(kind, reason, __STACKTRACE__)
    after
      watchdog && send(watchdog, :done)
    end
  end
end
```

`start_feeder/2` and its `feed_spool` finalize **at exactly `content_length`**, not at enum
exhaustion — critical, because a stream that yields exactly `content_length` bytes then blocks would
otherwise leave the reader parked at EOF forever:

`start_feeder/2` uses `spawn_monitor`, **not** `spawn_link` (the earlier choice). The native monitor
already guarantees C-side liveness, so the BEAM link bought nothing but a footgun: an abnormal feeder
death could kill the caller after the dirty NIF returned. With `spawn_monitor`, feeder death always
arrives as a `{:DOWN, ...}` *message* — never an exit signal — so a public image-load call returns
`{:error, _}` instead of sometimes crashing its caller, regardless of `trap_exit`.

```elixir
def start_feeder(enum, opts) do
  parent = self()
  len = Keyword.fetch!(opts, :content_length)

  {writer, mon} =
    spawn_monitor(fn ->
      case new(opts) do
        {:ok, spool} -> send(parent, {self(), {:ok, spool}}); feed_spool(enum, spool, len)
        {:error, _} = err -> send(parent, {self(), err})
      end
    end)

  receive do
    {^writer, {:ok, spool}}    -> Process.demonitor(mon, [:flush]); {:ok, spool, writer}
    {^writer, {:error, _} = e} -> Process.demonitor(mon, [:flush]); e
    {:DOWN, ^mon, :process, ^writer, reason} -> {:error, reason}   # no caller crash, no hang
  end
end

# content_length == 0 must finalize WITHOUT pulling the enum (a non-terminating empty stream
# would otherwise park the feeder before finalize, deadlocking readers at EOF).
defp feed_spool(_enum, spool, 0), do: finalize(spool)

defp feed_spool(enum, spool, len) when len > 0 do
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
   `writer`) are read without it. The refcount is the BEAM resource's (`enif_keep`/`release`). There is one lock — no ordering or
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
6. **Refcount is balanced (BEAM resource refcount).** `enif_keep_resource(buf)` per new holder
   (write handle; each `SpoolReader`), `enif_release_resource(buf)` per release (handle dtor;
   `spool_reader_free`). Freed once, by the release that drops to 0 — which must never be called
   while holding `buf->lock` (the destructor would destroy the lock under you).
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

- **Writer:** the process that calls `new` (inside `start_feeder`); **monitored** by the caller;
  fills to exactly `content_length`, finalizes, exits. Bounded by `content_length`, not enum length.
- **Buffer:** a `SPOOL_BUF_RT` resource; outlives the writer. Once finalized, the complete buffer
  satisfies any later lazy/random read with no writer involvement.
- **Sources:** each `keep`s the buffer resource via its `SpoolReader`; released when libvips unrefs
  the `VipsSourceCustom`. Because the buffer is a NIF resource, a live source also keeps the NIF
  library loaded (function-pointer safety across unload/upgrade).
- **Returned lazy image retains its source (invariant + test).** The wrapper's `source` term goes
  out of scope when `new_from_enum_spool/2` returns, so correctness depends on the load operation
  holding its own ref to the `VipsSourceCustom` for the image's lazy lifetime. This is the same
  dependency the existing pipe-based `new_from_enum` already relies on; it is made an explicit
  invariant here and covered by a GC-the-source-term-then-evaluate-pixels ASan test.
- **Cancellation precedence:** explicit (`abort`/`finalize`) is primary; the writer's `try/rescue`
  handles in-process stream exceptions; the monitor down callback is the backstop for untrappable
  death (`:kill`, supervisor shutdown) — the case `try/rescue` cannot catch and the one that would
  otherwise deadlock a parked reader. The handle destructor is a last-resort backstop.
- **NIF-monitor lifetime (verify + test):** the monitor is registered against the `SPOOL_WRITE_RT`
  object. OTP auto-removes a monitor when its resource is deallocated and never runs the down
  callback on a freed resource, so destructor↔down cannot race on freed memory — but this is the
  single highest-risk C assumption and is pinned by a failure-injection test (writer alive, handle
  GC'd, writer then dies → no use-after-free). `enif_demonitor_process` in the destructor is a
  belt-and-suspenders option if the contract proves subtler on a supported OTP version.

## Error semantics (honest)

| Event | What actually happens |
|---|---|
| Stream raises mid-feed | writer `rescue`s → `abort` (`EIO`, distinct from caller-cancel) → reader sees `ABORTED` → decode returns `{:error, _}`; caller **not** crashed |
| Writer `:kill` / supervisor shutdown | uncatchable by `rescue` → **monitor down** sets `ABORTED` (`EPIPE`) → parked reader returns `-1`; with `spawn_monitor` the caller gets `{:DOWN}` as a *message*, so it returns `{:error, _}` — it is **not** killed |
| Decode returns `{:error, _}` | parent (unparked) calls `abort` (`ECANCELED`) → next `write` returns `{:error, :aborted}` → `feed_spool` halts, writer stops draining |
| Parent raises during decode setup | `catch` → `abort` → re-raise; feeder stopped |
| `finalize` with `size < content_length` | `ABORTED`; `{:error, :short}` |
| `write` after terminal | `DONE` → `{:error, :closed}`; `ABORTED` → `{:error, :aborted}`; never silently appends |
| `write`/`finalize` from non-writer pid | `{:error, :not_owner}` |
| `seekable: true` without `content_length` | `{:error, :content_length_required}` before any work |
| allocation fails at `new` | `{:error, :enomem}`, partials freed (no mid-stream alloc failure exists) |

## Memory and scheduler notes

- **`content_length` is reserved memory capacity, not free.** On many platforms `enif_alloc` is
  lazily committed so unwritten pages cost no RSS, but this is not a portable guarantee — allocator
  metadata, overcommit policy, and cgroup limits all matter, and an overcommitted huge allocation
  can OOM-kill the process during streaming rather than fail cleanly at `new`. Callers must treat
  `content_length` as the maximum resident footprint and rely on `max_bytes`. That is why
  `max_bytes` defaults to a conservative library cap (100 MiB), **not** `content_length`.
- If a loader calls `vips_source_map`, peak RAM can **exceed** `new_from_buffer/2` (spool buffer +
  the libvips `GByteArray` copy). This path trades RAM for the overlap/reopen wins; large/unknown
  inputs use the pipe path.
- The write NIF is `DIRTY_JOB_CPU_BOUND` (memory-bandwidth + lock work, matching `nif_write`); a
  large upload can occupy a dirty-CPU scheduler, so many concurrent large uploads add dirty-CPU
  pressure — acceptable, but worth a stress test. The decode (and its blocking read callback) runs
  on a dirty-IO scheduler via `nif_vips_operation_call`; each concurrently decoding source parks one
  dirty-IO thread while waiting at the frontier (default pool ~10) — the same per-decode
  characteristic as the pipe path, and a reason services should bound concurrent decodes per node.
  `abort`/`finalize`/`source` stay on regular schedulers, kept responsive by the lock-per-slice
  write loop.
- **errno portability.** Callbacks set `errno` on every `-1`; libvips may flatten these into a
  generic decode error, so they are diagnostic, not a contract callers can switch on. `ENODATA` and
  `ECANCELED` are **not** universally available (notably `ENODATA` on macOS, a supported target) —
  guard them (`#ifndef … #define … EIO`) or use `EIO`. `spool_set_terminal_locked` must never record
  errno `0` for `ABORTED`.

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
- Writer `:kill` → caller (via `spawn_monitor`) gets `{:error, _}`, is **not** killed, regardless of
  `trap_exit`; the parked reader wakes with `-1` via the monitor.
- Writer dies before sending the handle → `start_feeder` returns `{:error, _}` via `{:DOWN}`, no hang.
- Decode returns `{:error, _}` on a large/slow enum → feeder aborted, RAM stops growing.
- **Abort responsiveness during a huge write:** start a multi-MB `write/2`, `abort/1` from another
  process, assert the write stops within ~one `SPOOL_MAX_SLICE` of progress (catches any regression
  to lock-held-across-the-whole-loop).
- **`content_length == 0`:** a feeder over a zero-length enum that blocks/raises if pulled →
  `finalize` runs without touching the enum.
- **`timeout:`** option → a stalled-but-alive writer is aborted by the watchdog and the call returns
  an error rather than parking forever.
- **Monitor-ownership regression:** mint via `start_feeder` (correct), kill the feeder while a reader
  is parked → reader wakes with `-1`.

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

## Implementation checklist (carried into the plan)

These are binding C-safety/idiom requirements that belong in the implementation plan as concrete
tasks rather than in the design prose. They do not change the architecture.

Resource & monitor lifetime:
- `SPOOL_BUF_RT` and `SPOOL_WRITE_RT` resource types each opened with the right destructor (and
  `SPOOL_WRITE_RT` with a down callback). Verify the exact `enif_monitor_process` lifetime contract
  on supported OTP; consider `enif_demonitor_process` in the write-handle destructor.
- Never call the releasing `enif_release_resource(buf)` while holding `buf->lock`.
- Monitor-down and destructor must both go through `spool_set_terminal` (idempotent, first wins).

Allocation & integer safety:
- One named helper for `gint64 → size_t` and one for checked `gint64 + gint64`; cast to `size_t`
  only after proving `0 <= n <= SIZE_MAX`. Validate `0 <= content_length <= G_MAXINT64` and
  `<= SIZE_MAX` before `enif_alloc`. Compute `content_length - size` only after asserting
  `0 <= size <= content_length` (debug `assert`).
- Replace the illustrative `MIN3` with explicit typed clamping (no signed/unsigned promotion).
- `SPOOL_MAX_SLICE` a `size_t` constant bounded into both `gint64` and `size_t`.

Locking & callbacks:
- `enif_cond_wait` only ever inside a `while`; broadcast after every published-bytes advance and on
  every terminal transition.
- `read_cb`: `length < 0`/NULL buffer → `-1`/`EINVAL`; `length == 0` → `0`; block at frontier while
  `OPEN`; `0` only after `DONE`; `-1` (with stored `err_errno`, fallback `EIO`) after `ABORTED`.
- `seek_cb`: validate `whence`, overflow, and `0 <= new_pos <= content_length`; `SEEK_END` returns
  `content_length`, never `size`; never waits.
- Callbacks touch only native primitives — no `ErlNifEnv`, term API, message send, or logging.

GObject ownership:
- Exactly one owning destroy notify (`g_object_set_data_full`) for the `SpoolReader`; signal
  handlers non-owning; no per-signal `GClosureNotify`. Every failure path after `enif_keep_resource`
  proves exactly one `enif_release_resource`.

Elixir:
- `validate_content_length/2` (integer, non-negative, `<= max_bytes`) and `validate_options/1` run
  **before** spawning the feeder. `default_max_bytes/0` reads app config (100 MiB default).
- `start_watchdog/2` spawns a process that `abort/1`s on `timeout`, cancelled via `:done`.

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
