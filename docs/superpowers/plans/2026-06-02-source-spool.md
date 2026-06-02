# SourceSpool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Vix.SourceSpool` — a native, seekable, concurrent libvips source backed by a pre-allocated in-memory buffer that Elixir pushes bytes into while libvips decodes, so seek-heavy formats (HEIF/AVIF/TIFF) decode over a still-arriving `Enumerable`.

**Architecture:** Elixir writes chunks into a C-owned, refcounted, pre-allocated `SpoolBuf` (a NIF resource); each `VipsSourceCustom` reader has its own cursor and blocks at the write frontier via a mutex/condvar — never calling back into the BEAM. A process monitor on the writer wakes parked readers if the writer dies. Full rationale: [the design doc](../specs/2026-06-02-source-spool-design.md).

**Tech Stack:** C (Erlang NIF, libvips `VipsSourceCustom`, GLib/GObject), Elixir (ExUnit), `elixir_make` build.

---

## Prerequisites

- [ ] **(Recommended, not required) Merge `my-fixes` first.** The spool is all-new code and compiles green on plain HEAD — `spool.c` references no pipe symbol and none of `my-fixes`'s changes — so this is *not* a hard gate. But `my-fixes` corrects a real pre-existing bug worth having in the tree: `vix.c` binds `nif_vips_tracked_get_mem_highwater` to the wrong function (`nif_vips_tracked_get_mem`) — the copy-paste registration typo that is the **cautionary tale for Task 6's table edits**. (HEAD already has `pipe.c`'s `fd_rt_stop`/`fd_rt_down`; `my-fixes` only adds a 2-line `pipe.c` tweak + a regression test there — nothing the spool depends on.)

  ```bash
  git merge-base --is-ancestor my-fixes HEAD && echo "present" || echo "not merged — fine to proceed; spool is self-contained"
  ```

## Design invariants this plan must preserve

These come straight from the design's Concurrency model and Implementation checklist. Keep them in view for every C task:

1. **One lock** (`buf->lock`) guards `size`, `state`, `err_errno`, each reader's `read_pos`. Immutable-after-`new` fields (`data`, `content_length`, `writer`) are read lock-free. The refcount is the BEAM resource's.
2. **Reads/writes copy under the lock, in `SPOOL_MAX_SLICE` slices**; release the lock *between* slices.
3. **`enif_cond_wait` only inside a `while`**; broadcast after every published-bytes advance and on every terminal transition.
4. **All terminal transitions go through `spool_set_terminal[_locked]`** — `OPEN` is the only non-terminal state; first transition wins; idempotent.
5. **Callbacks (`read_cb`/`seek_cb`) touch only native primitives** — no `ErlNifEnv`, term API, message send, or logging.
6. **Refcount balanced** with `enif_keep_resource`/`enif_release_resource`; never release while holding `buf->lock`.
7. **Resources use `dtor` (+ `down` on the write handle) only — no `stop` callback.** No `enif_select` is involved.

## File structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `c_src/spool.h` | Create | NIF + init prototypes |
| `c_src/spool.c` | Create | `SpoolBuf`/`SpoolReader`, two resource types, `spool_set_terminal`, the 5 NIFs, `read_cb`/`seek_cb` |
| `c_src/vix.c` | Modify | `#include "spool.h"`, call `nif_source_spool_init` in `on_load`, 5 table entries |
| `lib/vix/nif.ex` | Modify | 5 NIF stubs |
| `lib/vix/source_spool.ex` | Create | Public module: `new/1`, `write/2`, `finalize/1`, `abort/1`, `source/1`, `start_feeder/2` |
| `lib/vix/vips/image.ex` | Modify | `new_from_enum/2` `seekable: true` branch |
| `test/vix/source_spool_test.exs` | Create | Spool unit + concurrency + lifetime tests |
| `test/vix/vips/image_test.exs` | Modify | `new_from_enum` seekable integration tests |

The `c_src/Makefile` needs **no change** — it auto-globs `*.c` ([Makefile:117](../../../c_src/Makefile)).

Build/test commands used throughout:
- Recompile C + Elixir: `mix compile` (the Makefile rebuilds changed `.c`).
- Run one test file: `mix test test/vix/source_spool_test.exs`
- Run one test by line: `mix test test/vix/source_spool_test.exs:42`

---

## Task 1: Resource types and lifecycle NIFs (new / finalize / abort)

Creates the C scaffold so the library still builds and loads, plus the buffer lifecycle with no reading yet. `SPOOL_BUF_RT` (the refcounted buffer) and `SPOOL_WRITE_RT` (the writer handle, monitored).

**Files:**
- Create: `c_src/spool.h`
- Create: `c_src/spool.c`
- Modify: `c_src/vix.c` (include + `on_load` + 3 table entries for now)
- Modify: `lib/vix/nif.ex` (3 stubs for now)
- Create: `lib/vix/source_spool.ex` (new/finalize/abort)
- Test: `test/vix/source_spool_test.exs`

- [ ] **Step 1: Write `c_src/spool.h`**

```c
#ifndef VIX_SPOOL_H
#define VIX_SPOOL_H

#include "erl_nif.h"

int nif_source_spool_init(ErlNifEnv *env);

ERL_NIF_TERM nif_source_spool_new(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_source_spool_write(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_source_spool_finalize(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_source_spool_abort(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]);
ERL_NIF_TERM nif_source_spool_source(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]);

#endif
```

- [ ] **Step 2: Write `c_src/spool.c` (scaffold: structs, resources, helpers, new/finalize/abort)**

```c
#include <errno.h>
#include <stdint.h>
#include <string.h>

#include <glib-object.h>
#include <vips/vips.h>

#include "erl_nif.h"
#include "g_object/g_object.h"
#include "spool.h"
#include "utils.h"

/* errno portability: ENODATA is absent on macOS; ECANCELED guarded for safety. */
#ifndef ENODATA
#define ENODATA EIO
#endif
#ifndef ECANCELED
#define ECANCELED EIO
#endif

#define SPOOL_MAX_SLICE ((size_t)(256 * 1024))

static ErlNifResourceType *SPOOL_BUF_RT;
static ErlNifResourceType *SPOOL_WRITE_RT;

typedef enum { SPOOL_OPEN, SPOOL_DONE, SPOOL_ABORTED } SpoolState;

typedef struct {
  ErlNifMutex *lock;
  ErlNifCond *cond;

  guint8 *data;          /* enif_alloc(content_length) once; never moves */
  gint64 size;           /* published frontier, 0..content_length */
  gint64 content_length; /* immutable after new */

  SpoolState state;
  int err_errno;
} SpoolBuf;

typedef struct {
  SpoolBuf *buf;
  gint64 read_pos;
} SpoolReader;

typedef struct {
  SpoolBuf *buf;
  ErlNifPid writer;
  ErlNifMonitor mon;
} SpoolWriteHandle;

/* ---- terminal-state chokepoint (invariant 4) ---- */

/* caller holds buf->lock */
static void spool_set_terminal_locked(SpoolBuf *b, SpoolState st, int err) {
  if (b->state == SPOOL_OPEN) {
    b->state = st;
    if (st == SPOOL_ABORTED)
      b->err_errno = err ? err : EIO;
  }
  enif_cond_broadcast(b->cond);
}

static void spool_set_terminal(SpoolBuf *b, SpoolState st, int err) {
  enif_mutex_lock(b->lock);
  spool_set_terminal_locked(b, st, err);
  enif_mutex_unlock(b->lock);
}

/* ---- resource callbacks (dtor + down only; no stop — no enif_select) ---- */

static void spool_buf_dtor(ErlNifEnv *env, void *obj) {
  SpoolBuf *b = (SpoolBuf *)obj;
  if (b->data)
    enif_free(b->data);
  if (b->cond)
    enif_cond_destroy(b->cond);
  if (b->lock)
    enif_mutex_destroy(b->lock);
}

static void spool_write_dtor(ErlNifEnv *env, void *obj) {
  SpoolWriteHandle *wr = (SpoolWriteHandle *)obj;
  if (wr->buf) {
    enif_demonitor_process(env, wr, &wr->mon);         /* explicit; harmless if auto-removed */
    spool_set_terminal(wr->buf, SPOOL_ABORTED, EPIPE); /* backstop if still OPEN */
    enif_release_resource(wr->buf);                    /* outside any lock */
    wr->buf = NULL;
  }
}

/* writer process died: time-critical wakeup happens HERE, freeing is the dtor's job */
static void spool_write_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                             ErlNifMonitor *monitor) {
  SpoolWriteHandle *wr = (SpoolWriteHandle *)obj;
  if (wr->buf)
    spool_set_terminal(wr->buf, SPOOL_ABORTED, EPIPE);
}

int nif_source_spool_init(ErlNifEnv *env) {
  ErlNifResourceTypeInit buf_init = {0};
  buf_init.dtor = spool_buf_dtor;

  SPOOL_BUF_RT = enif_open_resource_type_x(
      env, "spool_buf", &buf_init, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
      NULL);
  if (!SPOOL_BUF_RT)
    return 1;

  ErlNifResourceTypeInit wr_init = {0};
  wr_init.dtor = spool_write_dtor;
  wr_init.down = spool_write_down;

  SPOOL_WRITE_RT = enif_open_resource_type_x(
      env, "spool_write", &wr_init, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
      NULL);
  if (!SPOOL_WRITE_RT)
    return 1;

  return 0;
}

/* ---- new ---- */

ERL_NIF_TERM nif_source_spool_new(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);

  ErlNifSInt64 content_length;
  if (!enif_get_int64(env, argv[0], &content_length))
    return make_error(env, "content_length must be an integer");
  if (content_length < 0)
    return make_error_term(env, make_atom(env, "invalid_content_length"));
  /* On 32-bit builds gint64 can exceed SIZE_MAX; on 64-bit the compare is
     tautological, so guard it or clang rejects it under -Wextra -Werror
     (-Wtautological-constant-out-of-range-compare). */
#if SIZE_MAX < INT64_MAX
  if ((guint64)content_length > (guint64)SIZE_MAX)
    return make_error_term(env, make_atom(env, "content_length_too_large"));
#endif

  SpoolBuf *buf = enif_alloc_resource(SPOOL_BUF_RT, sizeof(SpoolBuf));
  buf->lock = NULL;
  buf->cond = NULL;
  buf->data = NULL;
  buf->size = 0;
  buf->content_length = content_length;
  buf->state = SPOOL_OPEN;
  buf->err_errno = 0;

  buf->data = enif_alloc(content_length > 0 ? (size_t)content_length : 1);
  buf->lock = enif_mutex_create("spool_buf_lock");
  buf->cond = enif_cond_create("spool_buf_cond");

  if (!buf->data || !buf->lock || !buf->cond) {
    enif_release_resource(buf); /* dtor frees whatever was allocated */
    return make_error_term(env, make_atom(env, "enomem"));
  }

  SpoolWriteHandle *wr =
      enif_alloc_resource(SPOOL_WRITE_RT, sizeof(SpoolWriteHandle));
  wr->buf = buf; /* wr owns buf's creation ref; dtor will release it */
  enif_self(env, &wr->writer);

  if (enif_monitor_process(env, wr, &wr->writer, &wr->mon) != 0) {
    /* >0: caller already dead (impossible for self); <0: no down callback */
    wr->buf = NULL;
    enif_release_resource(wr);  /* wr dtor would otherwise touch buf */
    enif_release_resource(buf);
    return make_error(env, "failed to monitor writer process");
  }

  ERL_NIF_TERM term = enif_make_resource(env, wr);
  enif_release_resource(wr); /* term holds the wr ref now */
  return make_ok(env, term);
}

/* ---- finalize ---- */

static int is_writer(ErlNifEnv *env, SpoolWriteHandle *wr) {
  ErlNifPid self;
  enif_self(env, &self);
  return enif_is_identical(enif_make_pid(env, &self),
                           enif_make_pid(env, &wr->writer));
}

ERL_NIF_TERM nif_source_spool_finalize(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);
  SpoolWriteHandle *wr;
  if (!enif_get_resource(env, argv[0], SPOOL_WRITE_RT, (void **)&wr))
    return make_error(env, "invalid spool handle");
  if (!is_writer(env, wr))
    return make_error_term(env, make_atom(env, "not_owner"));

  SpoolBuf *b = wr->buf;
  ERL_NIF_TERM ret;
  enif_mutex_lock(b->lock);
  if (b->state == SPOOL_OPEN) {
    if (b->size == b->content_length) {
      spool_set_terminal_locked(b, SPOOL_DONE, 0);
      ret = ATOM_OK;
    } else {
      spool_set_terminal_locked(b, SPOOL_ABORTED, ENODATA);
      ret = make_error_term(env, make_atom(env, "short"));
    }
  } else if (b->state == SPOOL_DONE) {
    ret = ATOM_OK;
  } else {
    ret = make_error_term(env, make_atom(env, "aborted"));
  }
  enif_mutex_unlock(b->lock);
  return ret;
}

/* ---- abort (callable by any process) ---- */

ERL_NIF_TERM nif_source_spool_abort(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);
  SpoolWriteHandle *wr;
  if (!enif_get_resource(env, argv[0], SPOOL_WRITE_RT, (void **)&wr))
    return make_error(env, "invalid spool handle");
  if (wr->buf) /* NULL only after the dtor ran; defensive */
    spool_set_terminal(wr->buf, SPOOL_ABORTED, ECANCELED);
  return ATOM_OK;
}
```

- [ ] **Step 3: Wire into `c_src/vix.c`** — add the include with the other local headers (near [vix.c:11](../../../c_src/vix.c)):

```c
#include "spool.h"
```

In `on_load`, after `if (nif_pipe_init(env)) return 1;` ([vix.c:62](../../../c_src/vix.c)):

```c
  if (nif_source_spool_init(env))
    return 1;
```

In `nif_funcs[]`, after the `nif_target_new` entry (end of the table, [vix.c:175](../../../c_src/vix.c)) — **each row maps a distinct name to its own function; do not copy a row without changing the function pointer (cf. the highwater typo `my-fixes` fixed):**

```c
    /* VipsSourceCustom spool */
    {"nif_source_spool_new", 1, nif_source_spool_new, 0},
    {"nif_source_spool_finalize", 1, nif_source_spool_finalize, 0},
    {"nif_source_spool_abort", 1, nif_source_spool_abort, 0},
```

- [ ] **Step 4: Add stubs to `lib/vix/nif.ex`** — after `nif_target_new` ([nif.ex:276](../../../lib/vix/nif.ex)):

```elixir
  def nif_source_spool_new(_content_length),
    do: :erlang.nif_error(:nif_library_not_loaded)

  def nif_source_spool_finalize(_spool),
    do: :erlang.nif_error(:nif_library_not_loaded)

  def nif_source_spool_abort(_spool),
    do: :erlang.nif_error(:nif_library_not_loaded)
```

- [ ] **Step 5: Create `lib/vix/source_spool.ex` (lifecycle subset)**

```elixir
defmodule Vix.SourceSpool do
  @moduledoc """
  A seekable, concurrent libvips source backed by a pre-allocated in-memory
  buffer fed from Elixir while libvips decodes.

  Prefer `start_feeder/2`. `new/1`, `write/2`, and `finalize/1` are low-level:
  the process that calls `new/1` becomes the only process allowed to `write/2`
  and `finalize/1`, and its death aborts the spool.
  """

  alias Vix.Nif
  alias Vix.Vips.Source
  alias __MODULE__

  @opaque t :: %__MODULE__{ref: term()}
  defstruct [:ref]

  @default_max_bytes 104_857_600

  @spec new(keyword) :: {:ok, t} | {:error, term}
  def new(opts) do
    len = Keyword.get(opts, :content_length)
    max = Keyword.get(opts, :max_bytes, default_max_bytes())

    with :ok <- validate_content_length(len, max),
         {:ok, ref} <- Nif.nif_source_spool_new(len) do
      {:ok, %SourceSpool{ref: ref}}
    end
  end

  @spec finalize(t) :: :ok | {:error, term}
  def finalize(%SourceSpool{ref: ref}), do: Nif.nif_source_spool_finalize(ref)

  @spec abort(t) :: :ok
  def abort(%SourceSpool{ref: ref}), do: Nif.nif_source_spool_abort(ref)

  @doc false
  def default_max_bytes,
    do: Application.get_env(:vix, :source_spool_max_bytes, @default_max_bytes)

  defp validate_content_length(len, _max) when not is_integer(len),
    do: {:error, :content_length_required}

  defp validate_content_length(len, _max) when len < 0,
    do: {:error, :invalid_content_length}

  defp validate_content_length(len, max) when len > max,
    do: {:error, :content_length_too_large}

  defp validate_content_length(_len, _max), do: :ok
end
```

- [ ] **Step 6: Write the failing test `test/vix/source_spool_test.exs`**

```elixir
defmodule Vix.SourceSpoolTest do
  use ExUnit.Case, async: true

  alias Vix.SourceSpool

  test "new/1 requires a non-negative integer content_length within max_bytes" do
    assert {:error, :content_length_required} = SourceSpool.new([])
    assert {:error, :invalid_content_length} = SourceSpool.new(content_length: -1)

    assert {:error, :content_length_too_large} =
             SourceSpool.new(content_length: 10, max_bytes: 5)
  end

  test "new/1 creates a spool and finalize/abort are well-behaved" do
    # In this process so that `self()` is the writer (new/1 monitors its caller).
    assert {:ok, spool} = SourceSpool.new(content_length: 0)
    assert :ok = SourceSpool.finalize(spool)
    # idempotent: already DONE
    assert :ok = SourceSpool.finalize(spool)

    assert {:ok, spool2} = SourceSpool.new(content_length: 5)
    assert :ok = SourceSpool.abort(spool2)
    # finalize after abort reports the terminal cause
    assert {:error, :aborted} = SourceSpool.finalize(spool2)
  end
end
```

- [ ] **Step 7: Run the test, expect failure**

Run: `mix test test/vix/source_spool_test.exs`
Expected: FAIL — `Vix.SourceSpool` undefined / NIFs not yet compiled.

- [ ] **Step 8: Compile and run until green**

Run: `mix compile && mix test test/vix/source_spool_test.exs`
Expected: PASS (C builds; resource types register; lifecycle works).

- [ ] **Step 9: Commit**

```bash
git add c_src/spool.h c_src/spool.c c_src/vix.c lib/vix/nif.ex \
        lib/vix/source_spool.ex test/vix/source_spool_test.exs
git commit -m "feat(spool): resource types + new/finalize/abort lifecycle"
```

---

## Task 2: write/2 (lock-per-slice, single-writer, overflow)

**Files:**
- Modify: `c_src/spool.c` (add `nif_source_spool_write`)
- Modify: `c_src/vix.c` (1 table entry)
- Modify: `lib/vix/nif.ex` (1 stub)
- Modify: `lib/vix/source_spool.ex` (`write/2`)
- Test: `test/vix/source_spool_test.exs`

- [ ] **Step 1: Write the failing test** — append to `test/vix/source_spool_test.exs`:

```elixir
  test "write/2 enforces single-writer, declared length, and terminal state" do
    {:ok, spool} = SourceSpool.new(content_length: 5)

    # not the writer -> :not_owner
    task =
      Task.async(fn -> SourceSpool.write(spool, "x") end)

    assert {:error, :not_owner} = Task.await(task)

    assert :ok = SourceSpool.write(spool, "abc")
    # writing past content_length aborts with :overflow
    assert {:error, :overflow} = SourceSpool.write(spool, "defg")
    # spool is now ABORTED; further writes are rejected
    assert {:error, :aborted} = SourceSpool.write(spool, "h")
  end

  test "write/2 then exact-fill finalize succeeds" do
    {:ok, spool} = SourceSpool.new(content_length: 5)
    assert :ok = SourceSpool.write(spool, "ab")
    assert :ok = SourceSpool.write(spool, "cde")
    assert :ok = SourceSpool.finalize(spool)
    # write after DONE -> :closed
    assert {:error, :closed} = SourceSpool.write(spool, "x")
  end
```

- [ ] **Step 2: Run, expect failure**

Run: `mix test test/vix/source_spool_test.exs`
Expected: FAIL — `SourceSpool.write/2` undefined.

- [ ] **Step 3: Add `nif_source_spool_write` to `c_src/spool.c`** (after `nif_source_spool_new`):

```c
ERL_NIF_TERM nif_source_spool_write(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 2);

  SpoolWriteHandle *wr;
  if (!enif_get_resource(env, argv[0], SPOOL_WRITE_RT, (void **)&wr))
    return make_error(env, "invalid spool handle");
  if (!is_writer(env, wr))
    return make_error_term(env, make_atom(env, "not_owner"));

  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[1], &bin))
    return make_error(env, "failed to get binary");

  SpoolBuf *b = wr->buf;
  size_t off = 0;

  while (off < bin.size) {
    enif_mutex_lock(b->lock);

    if (b->state == SPOOL_DONE) {
      enif_mutex_unlock(b->lock);
      return make_error_term(env, make_atom(env, "closed"));
    }
    if (b->state == SPOOL_ABORTED) {
      enif_mutex_unlock(b->lock);
      return make_error_term(env, make_atom(env, "aborted"));
    }

    /* would this binary exceed the declared length? (size <= content_length) */
    if ((gint64)(bin.size - off) > b->content_length - b->size) {
      spool_set_terminal_locked(b, SPOOL_ABORTED, EFBIG);
      enif_mutex_unlock(b->lock);
      return make_error_term(env, make_atom(env, "overflow"));
    }

    size_t slice = bin.size - off;
    if (slice > SPOOL_MAX_SLICE)
      slice = SPOOL_MAX_SLICE;

    memcpy(b->data + b->size, (const guint8 *)bin.data + off, slice);
    b->size += (gint64)slice;
    enif_cond_broadcast(b->cond);

    enif_mutex_unlock(b->lock); /* release BETWEEN slices (invariant 2) */
    off += slice;
  }

  return ATOM_OK;
}
```

- [ ] **Step 4: Register it** — `c_src/vix.c`, add to the spool block (dirty CPU: it does memcpy):

```c
    {"nif_source_spool_write", 2, nif_source_spool_write,
     ERL_NIF_DIRTY_JOB_CPU_BOUND},
```

`lib/vix/nif.ex`, add the stub:

```elixir
  def nif_source_spool_write(_spool, _bin),
    do: :erlang.nif_error(:nif_library_not_loaded)
```

- [ ] **Step 5: Add `write/2` to `lib/vix/source_spool.ex`** (after `new/1`):

```elixir
  @spec write(t, binary) :: :ok | {:error, :closed | :aborted | :overflow | :not_owner}
  def write(%SourceSpool{ref: ref}, bin) when is_binary(bin),
    do: Nif.nif_source_spool_write(ref, bin)
```

- [ ] **Step 6: Compile and run, expect pass**

Run: `mix compile && mix test test/vix/source_spool_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add c_src/spool.c c_src/vix.c lib/vix/nif.ex lib/vix/source_spool.ex \
        test/vix/source_spool_test.exs
git commit -m "feat(spool): write/2 with lock-per-slice, single-writer, overflow"
```

---

## Task 3: source/1 + read/seek callbacks (synchronous decode)

Adds `VipsSourceCustom` readers and the `read`/`seek` callbacks, then proves them by decoding a **complete** spooled buffer (write-all → finalize → `source/1` → `decode_source/1`). No concurrency yet.

**Files:**
- Modify: `c_src/spool.c` (`spool_read_cb`, `spool_seek_cb`, `spool_reader_free`, `nif_source_spool_source`)
- Modify: `c_src/vix.c` (1 table entry)
- Modify: `lib/vix/nif.ex` (1 stub)
- Modify: `lib/vix/source_spool.ex` (`source/1`)
- Test: `test/vix/source_spool_test.exs`

There is **no public `Image.new_from_source/2`** — Vix decodes a `Vix.Vips.Source` via the internal
`Foreign.find_load_source` + `Operation.Helper.operation_call` path (exactly what `new_from_enum`
does). Add a `decode_source/1` test helper that uses that same path, so the spool tests don't depend
on the Task 6 Image integration.

- [ ] **Step 1: Extend the test module header** — at the top of `test/vix/source_spool_test.exs`, add the alias/import and the helper (after `alias Vix.SourceSpool`):

```elixir
  import Vix.Support.Images
  alias Vix.Vips.Image

  # Decode a Vix.Vips.Source via the same internal path new_from_enum uses.
  defp decode_source(%Vix.Vips.Source{} = source) do
    with {:ok, loader} <- Vix.Vips.Foreign.find_load_source(source),
         {:ok, {ref, _}} <- Vix.Vips.Operation.Helper.operation_call(loader, [source], []) do
      {:ok, %Image{ref: ref}}
    end
  end
```

- [ ] **Step 2: Write the failing test** — append:

```elixir
  test "source/1 over a fully-spooled JPEG decodes to the same shape as the file" do
    bytes = File.read!(img_path("puppies.jpg"))
    {:ok, ref} = Image.new_from_file(img_path("puppies.jpg"))
    expected = {Image.width(ref), Image.height(ref), Image.bands(ref)}

    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    :ok = SourceSpool.write(spool, bytes)
    :ok = SourceSpool.finalize(spool)
    {:ok, source} = SourceSpool.source(spool)

    {:ok, img} = decode_source(source)
    assert {Image.width(img), Image.height(img), Image.bands(img)} == expected
  end
```

- [ ] **Step 3: Run, expect failure**

Run: `mix test test/vix/source_spool_test.exs`
Expected: FAIL — `SourceSpool.source/1` undefined.

- [ ] **Step 4: Add callbacks + `source/1` to `c_src/spool.c`** (after `nif_source_spool_abort`):

> **VERIFY FIRST (the one unverifiable-from-the-plan risk):** `G_CALLBACK` casts away the handler
> prototype, so a mismatch between `spool_read_cb`/`spool_seek_cb` and the actual libvips
> `VipsSourceCustom` `"read"`/`"seek"` signal signatures compiles clean and corrupts the stack at
> decode time. Before trusting the signatures below, open the header you compile against —
> `priv/precompiled_libvips/include/vips/sourcecustom.h` (populated after the first `mix compile`) —
> and confirm `VipsSourceCustomReadSignal` is `gint64 (*)(VipsSourceCustom *, void *buffer, gint64 length, gpointer)`
> and `VipsSourceCustomSeekSignal` is `gint64 (*)(VipsSourceCustom *, gint64 offset, int whence, gpointer)`.
> Match the parameter order/types/return verbatim. The Task 3 JPEG decode is the smoke test: if the
> ABI is wrong it crashes or returns garbage there.

```c
/* Owns the SpoolReader; the single GObject destroy notify (no per-signal free). */
static void spool_reader_free(gpointer data) {
  SpoolReader *r = (SpoolReader *)data;
  enif_release_resource(r->buf); /* never under buf->lock */
  enif_free(r);
}

static gint64 spool_read_cb(VipsSourceCustom *source, void *buffer,
                            gint64 length, void *user_data) {
  SpoolReader *r = (SpoolReader *)user_data;
  SpoolBuf *b = r->buf;

  if (length < 0 || buffer == NULL) {
    errno = EINVAL;
    return -1;
  }
  if (length == 0)
    return 0;

  enif_mutex_lock(b->lock);
  while (r->read_pos >= b->size && b->state == SPOOL_OPEN)
    enif_cond_wait(b->cond, b->lock); /* park at the frontier */

  if (b->state == SPOOL_ABORTED) {
    errno = b->err_errno ? b->err_errno : EIO;
    enif_mutex_unlock(b->lock);
    return -1;
  }
  if (r->read_pos >= b->size) { /* DONE, at/after end -> true EOF */
    enif_mutex_unlock(b->lock);
    return 0;
  }

  gint64 avail = b->size - r->read_pos; /* > 0 */
  gint64 n = length < avail ? length : avail;
  if (n > (gint64)SPOOL_MAX_SLICE)
    n = (gint64)SPOOL_MAX_SLICE;

  memcpy(buffer, b->data + r->read_pos, (size_t)n);
  r->read_pos += n;
  enif_mutex_unlock(b->lock);
  return n;
}

static gint64 spool_seek_cb(VipsSourceCustom *source, gint64 offset, int whence,
                            void *user_data) {
  SpoolReader *r = (SpoolReader *)user_data;
  SpoolBuf *b = r->buf;
  gint64 base, new_pos;

  enif_mutex_lock(b->lock);
  switch (whence) {
  case SEEK_SET:
    base = 0;
    break;
  case SEEK_CUR:
    base = r->read_pos;
    break;
  case SEEK_END:
    base = b->content_length; /* stable, declared up front */
    break;
  default:
    enif_mutex_unlock(b->lock);
    errno = EINVAL;
    return -1;
  }

  /* overflow + range check; positions are gint64 */
  if ((offset > 0 && base > G_MAXINT64 - offset) ||
      (offset < 0 && base < G_MININT64 - offset)) {
    enif_mutex_unlock(b->lock);
    errno = EINVAL;
    return -1;
  }
  new_pos = base + offset;
  if (new_pos < 0 || new_pos > b->content_length) {
    enif_mutex_unlock(b->lock);
    errno = EINVAL;
    return -1;
  }

  r->read_pos = new_pos;
  enif_mutex_unlock(b->lock);
  return new_pos;
}

ERL_NIF_TERM nif_source_spool_source(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);

  SpoolWriteHandle *wr;
  if (!enif_get_resource(env, argv[0], SPOOL_WRITE_RT, (void **)&wr))
    return make_error(env, "invalid spool handle");

  SpoolBuf *b = wr->buf;

  enif_mutex_lock(b->lock);
  if (b->state == SPOOL_ABORTED) {
    enif_mutex_unlock(b->lock);
    return make_error_term(env, make_atom(env, "aborted"));
  }
  enif_keep_resource(b); /* this reader's ref */
  enif_mutex_unlock(b->lock);

  SpoolReader *r = enif_alloc(sizeof(SpoolReader));
  if (!r) {
    enif_release_resource(b);
    return make_error_term(env, make_atom(env, "enomem"));
  }
  r->buf = b;
  r->read_pos = 0;

  VipsSourceCustom *sc = vips_source_custom_new();
  if (!sc) {
    enif_release_resource(b);
    enif_free(r);
    return make_error(env, "failed to create VipsSourceCustom");
  }

  /* single owning destroy notify; signal handlers are non-owning */
  g_object_set_data_full(G_OBJECT(sc), "vix-spool-reader", r, spool_reader_free);
  g_signal_connect(sc, "read", G_CALLBACK(spool_read_cb), r);
  g_signal_connect(sc, "seek", G_CALLBACK(spool_seek_cb), r);

  /* g_object_to_erl_term takes ownership into a BEAM resource (which also pins
     the NIF library while the source lives). */
  return make_ok(env, g_object_to_erl_term(env, (GObject *)sc));
}
```

- [ ] **Step 5: Register + stub + Elixir** — `c_src/vix.c`:

```c
    {"nif_source_spool_source", 1, nif_source_spool_source, 0},
```

`lib/vix/nif.ex`:

```elixir
  def nif_source_spool_source(_spool),
    do: :erlang.nif_error(:nif_library_not_loaded)
```

`lib/vix/source_spool.ex` (after `write/2`):

```elixir
  @spec source(t) :: {:ok, Vix.Vips.Source.t()} | {:error, :aborted | term}
  def source(%SourceSpool{ref: ref}) do
    with {:ok, src_ref} <- Nif.nif_source_spool_source(ref) do
      {:ok, %Source{ref: src_ref}}
    end
  end
```

- [ ] **Step 6: Compile and run, expect pass**

Run: `mix compile && mix test test/vix/source_spool_test.exs`
Expected: PASS — JPEG decodes via the spool source; `read`/`seek` exercised during sniff + load.

- [ ] **Step 7: Commit**

```bash
git add c_src/spool.c c_src/vix.c lib/vix/nif.ex lib/vix/source_spool.ex \
        test/vix/source_spool_test.exs
git commit -m "feat(spool): source/1 + read/seek callbacks (synchronous decode)"
```

---

## Task 4: Concurrency — blocking at the frontier + writer-death liveness

Proves a reader **blocks** until bytes arrive and that killing the writer process **wakes** a parked reader (the monitor-down liveness guarantee), not just a clean finalize.

**Files:**
- Test only: `test/vix/source_spool_test.exs` (the C already implements this)

- [ ] **Step 1: Write the failing/again-green test** — append:

```elixir
  # Liveness tests deadlock the VM if the C monitor/condvar wiring is wrong;
  # bound them so a regression fails fast instead of hanging the suite.
  @tag timeout: 10_000
  test "a reader blocks at the frontier and a concurrent writer unblocks it" do
    bytes = File.read!(img_path("puppies.jpg"))
    half = div(byte_size(bytes), 2)
    <<first::binary-size(half), rest::binary>> = bytes

    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    {:ok, source} = SourceSpool.source(spool)

    # Decode in a separate process; it will block reading past `first`.
    parent = self()
    decoder = spawn_link(fn ->
      {:ok, img} = decode_source(source)
      send(parent, {:decoded, Image.width(img), Image.height(img)})
    end)

    :ok = SourceSpool.write(spool, first)
    refute_received {:decoded, _, _}          # still blocked at the frontier
    :ok = SourceSpool.write(spool, rest)
    :ok = SourceSpool.finalize(spool)

    assert_receive {:decoded, w, h}, 5_000
    assert w > 0 and h > 0
    _ = decoder
  end

  @tag timeout: 10_000
  test "killing the writer wakes a parked reader with an error" do
    bytes = File.read!(img_path("puppies.jpg"))

    parent = self()
    # The writer process owns the spool; it sends the source out, then parks.
    writer = spawn(fn ->
      {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
      {:ok, source} = SourceSpool.source(spool)
      send(parent, {:source, source})
      Process.sleep(:infinity)   # never writes; dies on kill below
    end)

    source = receive do {:source, s} -> s after 1_000 -> flunk("no source") end

    decoder = spawn_link(fn ->
      result = decode_source(source)
      send(parent, {:decode_result, result})
    end)

    Process.sleep(50)            # let the decoder park at the frontier
    Process.exit(writer, :kill)  # monitor-down -> ABORTED -> reader wakes

    assert_receive {:decode_result, {:error, _}}, 5_000
    _ = decoder
  end
```

- [ ] **Step 2: Run, expect pass (C already supports this)**

Run: `mix test test/vix/source_spool_test.exs`
Run: `mix test test/vix/source_spool_test.exs`
Expected: PASS. If the second hangs, the monitor/down wiring from Task 1 is wrong — revisit `spool_write_down` and the `enif_monitor_process` call.

- [ ] **Step 3: Commit**

```bash
git add test/vix/source_spool_test.exs
git commit -m "test(spool): frontier blocking + writer-death liveness"
```

---

## Task 5: Elixir feeder — start_feeder/2, feed_spool, zero-length

Adds the monitor-safe `Enumerable` feeder: `spawn_monitor`, exact-fill finalize, and the `content_length == 0` fast path.

**Files:**
- Modify: `lib/vix/source_spool.ex` (`start_feeder/2`, `feed_spool/3`)
- Test: `test/vix/source_spool_test.exs`

- [ ] **Step 1: Write the failing test** — append:

```elixir
  describe "start_feeder/2" do
    test "feeds an enum and decodes" do
      bytes = File.read!(img_path("puppies.jpg"))
      chunks = for <<c::binary-size(8192) <- bytes>>, do: c
      tail = binary_part(bytes, length(chunks) * 8192, byte_size(bytes) - length(chunks) * 8192)
      enum = chunks ++ [tail]

      {:ok, spool, _writer} =
        SourceSpool.start_feeder(enum, content_length: byte_size(bytes))

      {:ok, source} = SourceSpool.source(spool)
      {:ok, img} = decode_source(source)
      assert Image.width(img) > 0
    end

    @tag timeout: 10_000
    test "finalizes at exactly content_length without pulling an extra (blocking) item" do
      bytes = File.read!(img_path("puppies.jpg"))
      # An enum that yields the whole body, then BLOCKS forever if pulled again.
      enum = Stream.resource(
        fn -> :first end,
        fn
          :first -> {[bytes], :done}
          :done -> Process.sleep(:infinity)  # must never be reached
        end,
        fn _ -> :ok end
      )

      {:ok, spool, _writer} =
        SourceSpool.start_feeder(enum, content_length: byte_size(bytes))

      {:ok, source} = SourceSpool.source(spool)
      assert {:ok, _img} = decode_source(source)
    end

    test "content_length: 0 finalizes without touching the enum" do
      enum = Stream.map([:boom], fn _ -> raise "must not be pulled" end)
      assert {:ok, _spool, _writer} =
               SourceSpool.start_feeder(enum, content_length: 0)
    end
  end
```

- [ ] **Step 2: Run, expect failure**

Run: `mix test test/vix/source_spool_test.exs`
Expected: FAIL — `SourceSpool.start_feeder/2` undefined.

- [ ] **Step 3: Implement in `lib/vix/source_spool.ex`** — add public `start_feeder/2` and private `feed_spool/3`:

```elixir
  @spec start_feeder(Enumerable.t(), keyword) :: {:ok, t, pid} | {:error, term}
  def start_feeder(enum, opts) do
    parent = self()
    len = Keyword.fetch!(opts, :content_length)

    {writer, mon} =
      spawn_monitor(fn ->
        case new(opts) do
          {:ok, spool} ->
            send(parent, {self(), {:ok, spool}})
            feed_spool(enum, spool, len)

          {:error, _} = err ->
            send(parent, {self(), err})
        end
      end)

    receive do
      {^writer, {:ok, spool}} ->
        Process.demonitor(mon, [:flush])
        {:ok, spool, writer}

      {^writer, {:error, _} = err} ->
        Process.demonitor(mon, [:flush])
        err

      {:DOWN, ^mon, :process, ^writer, reason} ->
        {:error, reason}
    end
  end

  # Zero-length: finalize WITHOUT pulling the enum (a blocking empty stream
  # would otherwise deadlock readers at EOF).
  defp feed_spool(_enum, spool, 0), do: finalize(spool)

  defp feed_spool(enum, spool, len) when len > 0 do
    try do
      enum
      |> Enum.reduce_while(0, fn iodata, written ->
        bin = IO.iodata_to_binary(iodata)

        case write(spool, bin) do
          :ok ->
            case written + byte_size(bin) do
              ^len -> finalize(spool); {:halt, :filled}
              n -> {:cont, n}
            end

          {:error, _} ->
            {:halt, :stopped}
        end
      end)
      |> case do
        :filled -> :ok
        :stopped -> :ok
        n when is_integer(n) -> finalize(spool)  # enum ended early -> {:error, :short}
      end
    rescue
      _ -> abort(spool)
    catch
      _, _ -> abort(spool)
    end
  end
```

- [ ] **Step 4: Compile and run, expect pass**

Run: `mix compile && mix test test/vix/source_spool_test.exs`
Expected: PASS — in particular the exact-fill test must finish (proving finalize happens without the extra blocking pull).

- [ ] **Step 5: Commit**

```bash
git add lib/vix/source_spool.ex test/vix/source_spool_test.exs
git commit -m "feat(spool): start_feeder/2 with spawn_monitor, exact-fill, zero-length"
```

---

## Task 6: Image.new_from_enum(seekable: true) integration

Wires the spool into the public image API and proves parity with `new_from_file` across JPEG/PNG/TIFF, plus `content_length_required` and the optional `timeout:` watchdog.

**Files:**
- Modify: `lib/vix/vips/image.ex`
- Test: `test/vix/vips/image_test.exs`

- [ ] **Step 1: Write the failing test** — append to `test/vix/vips/image_test.exs`:

```elixir
  describe "new_from_enum seekable" do
    defp chunked(path, size \\ 8192) do
      bytes = File.read!(path)
      chunks = for <<c::binary-size(size) <- bytes>>, do: c
      used = length(chunks) * size
      tail = binary_part(bytes, used, byte_size(bytes) - used)
      {chunks ++ [tail], byte_size(bytes)}
    end

    for name <- ["puppies.jpg", "gradient.png", "boats.tif"] do
      test "decodes #{name} identically to new_from_file" do
        path = img_path(unquote(name))
        {:ok, ref} = Image.new_from_file(path)
        {enum, len} = chunked(path)

        assert {:ok, img} =
                 Image.new_from_enum(enum, seekable: true, content_length: len)

        assert {Image.width(img), Image.height(img), Image.bands(img)} ==
                 {Image.width(ref), Image.height(ref), Image.bands(ref)}
      end
    end

    test "requires content_length when seekable" do
      {enum, _len} = chunked(img_path("puppies.jpg"))
      assert {:error, :content_length_required} =
               Image.new_from_enum(enum, seekable: true)
    end
  end
```

- [ ] **Step 2: Run, expect failure**

Run: `mix test test/vix/vips/image_test.exs`
Expected: FAIL — `seekable:` not handled (decodes via the pipe path or errors).

- [ ] **Step 3: Modify `lib/vix/vips/image.ex`** — make `new_from_enum/2` dispatch. Rename the existing body to `new_from_enum_pipe/2` and add the seekable branch. At the top of the module ensure the aliases exist (`Vix.SourceSpool`, `Vix.Vips.Foreign`, `Vix.Vips.Operation.Helper` are already used by the pipe path).

Replace the `def new_from_enum(enum, opts \\ []) do … end` head ([image.ex:701](../../../lib/vix/vips/image.ex)) with a dispatcher, and rename its current body:

```elixir
  def new_from_enum(enum, opts \\ []) do
    # opts may be a binary (backward-compat suffix string) — only keyword opts
    # can request seekable, so guard on is_list before touching Keyword.
    if is_list(opts) and Keyword.get(opts, :seekable, false) do
      {_seekable, opts} = Keyword.pop(opts, :seekable)
      new_from_enum_spool(enum, opts)
    else
      new_from_enum_pipe(enum, opts)
    end
  end

  defp new_from_enum_pipe(enum, opts) do
    # ... the ORIGINAL body of new_from_enum/2, unchanged ...
  end

  defp new_from_enum_spool(enum, opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout)
    {len, opts} = Keyword.pop(opts, :content_length)
    {max, opts} = Keyword.pop(opts, :max_bytes, Vix.SourceSpool.default_max_bytes())

    with :ok <- validate_spool_length(len, max),
         :ok <- validate_options(opts),    # parity with the pipe path (validate_options is defp here)
         {:ok, spool, _writer} <-
           Vix.SourceSpool.start_feeder(enum, content_length: len, max_bytes: max) do
      watchdog = timeout && start_spool_watchdog(spool, timeout)

      try do
        with {:ok, source} <- Vix.SourceSpool.source(spool),
             {:ok, loader} <- Vix.Vips.Foreign.find_load_source(source),
             {:ok, {ref, _}} <-
               Vix.Vips.Operation.Helper.operation_call(loader, [source], opts) do
          {:ok, wrap_type(ref)}
        else
          {:error, _} = err ->
            Vix.SourceSpool.abort(spool)
            err
        end
      catch
        kind, reason ->
          Vix.SourceSpool.abort(spool)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        watchdog && send(watchdog, :done)
      end
    end
  end

  defp validate_spool_length(len, _max) when not is_integer(len),
    do: {:error, :content_length_required}

  defp validate_spool_length(len, _max) when len < 0,
    do: {:error, :invalid_content_length}

  defp validate_spool_length(len, max) when len > max,
    do: {:error, :content_length_too_large}

  defp validate_spool_length(_len, _max), do: :ok

  defp start_spool_watchdog(spool, timeout) do
    spawn(fn ->
      receive do
        :done -> :ok
      after
        timeout -> Vix.SourceSpool.abort(spool)
      end
    end)
  end
```

> Note: copy the original `new_from_enum/2` body verbatim into `new_from_enum_pipe/2`. Do not change pipe behavior. Confirm `wrap_type/1`, `validate_options/1`, `Foreign`, and `Operation.Helper` are the same references the original body used. **Keep the `\\ []` default arg ONLY on the public `new_from_enum/2` head** — do not carry it onto the private `new_from_enum_pipe/2` or `new_from_enum_spool/2` clauses.

- [ ] **Step 4: Compile and run, expect pass**

Run: `mix compile && mix test test/vix/vips/image_test.exs`
Expected: PASS — all three formats match `new_from_file`; missing-length errors. Run the full file too: `mix test test/vix/vips/image_test.exs` (the pipe-path tests must still pass).

- [ ] **Step 5: Commit**

```bash
git add lib/vix/vips/image.ex test/vix/vips/image_test.exs
git commit -m "feat(image): new_from_enum seekable: true via SourceSpool"
```

---

## Task 7: Multi-reader + seek-heavy + NIF registration smoke test

Proves `source/1` mints independent cursors over one buffer, that the seek-heavy TIFF path round-trips, and adds a smoke test that every spool NIF is actually registered (guards against the `my-fixes` highwater-style typo).

**Files:**
- Test only: `test/vix/source_spool_test.exs`

- [ ] **Step 1: Write the test** — append:

```elixir
  test "two independent sources over one spool decode the same bytes" do
    bytes = File.read!(img_path("boats.tif"))
    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    :ok = SourceSpool.write(spool, bytes)
    :ok = SourceSpool.finalize(spool)

    {:ok, s1} = SourceSpool.source(spool)
    {:ok, s2} = SourceSpool.source(spool)

    {:ok, i1} = decode_source(s1)
    {:ok, i2} = decode_source(s2)
    assert Image.width(i1) == Image.width(i2)
    assert Image.height(i1) == Image.height(i2)
  end

  test "all spool NIFs are registered (not stub-raising)" do
    # If a vix.c table entry is mis-bound, the NIF stays the .ex stub and raises
    # :nif_library_not_loaded. A successful new/finalize exercises new+finalize;
    # write/source/abort are covered by the tests above. This asserts the load.
    assert {:ok, spool} = SourceSpool.new(content_length: 1)
    assert :ok = SourceSpool.write(spool, "x")
    assert {:ok, _source} = SourceSpool.source(spool)
    assert :ok = SourceSpool.finalize(spool)
    assert :ok = SourceSpool.abort(spool)
  end
```

- [ ] **Step 2: Run, expect pass**

Run: `mix test test/vix/source_spool_test.exs`
Run: `mix test test/vix/source_spool_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/vix/source_spool_test.exs
git commit -m "test(spool): multi-reader, seek-heavy TIFF, NIF registration smoke"
```

---

## Task 8: Lifetime safety — lazy-image source retention + double-free under valgrind

The two release-blocking C assumptions from the design: the returned lazy image must keep its source alive, and the read/seek destroy path must not double-free. These need a memory checker, not just green ExUnit.

**Files:**
- Test: `test/vix/source_spool_test.exs`

- [ ] **Step 1: Write the lazy-lifetime test** — append:

```elixir
  test "image retains its source: buffer survives GC of BOTH the spool handle and the source term" do
    bytes = File.read!(img_path("puppies.jpg"))

    # Create the spool handle AND the source inside the closure, so after it returns the ONLY
    # path keeping the buffer alive is the image retaining the source. If the load op did not
    # retain it, the buffer would be freed and the eval below would use-after-free.
    img =
      (fn ->
         {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
         :ok = SourceSpool.write(spool, bytes)
         :ok = SourceSpool.finalize(spool)
         {:ok, source} = SourceSpool.source(spool)
         {:ok, img} = decode_source(source)
         img
       end).()

    :erlang.garbage_collect()
    # Definitive UAF detection is the valgrind/ASan run in Step 3 (GC + Janitor unref is async,
    # so a clean pass here is necessary-but-not-sufficient).
    assert {:ok, _bin} = Image.write_to_buffer(img, ".png")
  end
```

- [ ] **Step 2: Run, expect pass**

Run: `mix test test/vix/source_spool_test.exs`
Expected: PASS. If it crashes the VM, the load op is not retaining the source — pin it (design "Returned lazy image retains its source"): in `nif_source_spool_source` the GObject resource must outlive the image, which it does only if libvips holds its own ref; if not, attach the source to the image. Investigate before proceeding.

- [ ] **Step 3: Run the full spool + image suites under valgrind (Linux) to catch double-free / leaks**

Run:
```bash
ERL_FLAGS="+S 1" valgrind --leak-check=full --error-exitcode=1 \
  mix test test/vix/source_spool_test.exs test/vix/vips/image_test.exs
```
Expected: no "definitely lost" from spool allocations, no invalid free. (macOS: use `leaks` or an ASan-instrumented build instead; valgrind support is limited.)
This exercises: buffer freed once at refcount 0, single reader destroy notify (no double-free), monitor/dtor interplay.

- [ ] **Step 4: Commit**

```bash
git add test/vix/source_spool_test.exs
git commit -m "test(spool): lazy-image source retention + memory-checker pass"
```

---

## Task 9: Design-mandated safety & liveness tests

The design names several behaviors as must-test (monitor ownership through `start_feeder`, the
`spawn_monitor` payoff, `:short`, the watchdog, abort responsiveness, the SEEK_END length-cache).
The earlier tasks prove the *mechanisms*; these pin the *contracts* the design called out. All
test-only.

**Files:**
- Test: `test/vix/source_spool_test.exs` (tests 1–3, 5, 6)
- Test: `test/vix/vips/image_test.exs` (test 4)

- [ ] **Step 1: Add the contract tests** to `test/vix/source_spool_test.exs`:

```elixir
  # Helper: an enum that yields nothing and blocks forever if pulled.
  defp blocking_enum,
    do: Stream.resource(fn -> :s end, fn :s -> Process.sleep(:infinity) end, fn _ -> :ok end)

  # (1) The design's "single most important contract": start_feeder makes the FEEDER the
  # monitored writer. Killing the feeder (not the test process) must wake a parked reader.
  @tag timeout: 10_000
  test "start_feeder monitors the feeder: killing it wakes a parked reader" do
    {:ok, spool, writer} =
      SourceSpool.start_feeder(blocking_enum(), content_length: 1000)

    {:ok, source} = SourceSpool.source(spool)
    parent = self()
    _decoder = spawn_link(fn -> send(parent, {:res, decode_source(source)}) end)

    Process.sleep(50)            # decoder parks at the frontier (nothing written yet)
    Process.exit(writer, :kill)  # feeder is the monitored writer
    assert_receive {:res, {:error, _}}, 5_000
  end

  # (2) The spawn_monitor payoff: a feeder :kill surfaces as an API error, never crashes the
  # caller — even when the caller traps exits.
  @tag timeout: 10_000
  test "a feeder :kill does not crash the caller; the spool reports :aborted" do
    Process.flag(:trap_exit, true)
    {:ok, spool, writer} = SourceSpool.start_feeder(blocking_enum(), content_length: 1000)
    Process.exit(writer, :kill)
    Process.sleep(50)
    assert {:error, :aborted} = SourceSpool.source(spool)  # caller still alive & usable
  after
    Process.flag(:trap_exit, false)
  end

  # (3) Short stream: finalize before content_length aborts with :short.
  test "finalize before content_length returns :short" do
    {:ok, spool} = SourceSpool.new(content_length: 10)
    :ok = SourceSpool.write(spool, "abc")
    assert {:error, :short} = SourceSpool.finalize(spool)
  end

  # (5) Abort responsiveness: abort concurrent with a large multi-slice write must not deadlock.
  # (The "stops within ~one SPOOL_MAX_SLICE" property is structural — verify by reading the
  # lock-per-slice loop; this test guards against a deadlock regression.)
  @tag timeout: 10_000
  test "abort/1 concurrent with a large write does not deadlock" do
    big = :binary.copy("x", 8 * 1024 * 1024)
    {:ok, spool} = SourceSpool.new(content_length: byte_size(big))
    spawn(fn -> SourceSpool.abort(spool) end)
    assert SourceSpool.write(spool, big) in [:ok, {:error, :aborted}]
  end

  # (6) SEEK_END length-cache pin. A TIFF loader probes source length early (SEEK_END). Feeding a
  # TIFF in two halves and decoding correctly proves SEEK_END returns content_length, NOT the
  # write frontier — the exact bug the content_length requirement defends against. (A truly direct
  # seek-callback unit test isn't possible from Elixir; this end-to-end shape is the real pin.)
  @tag timeout: 10_000
  test "TIFF fed incrementally decodes — SEEK_END returns content_length, not the frontier" do
    bytes = File.read!(img_path("boats.tif"))
    half = div(byte_size(bytes), 2)
    <<first::binary-size(half), rest::binary>> = bytes

    {:ok, spool} = SourceSpool.new(content_length: byte_size(bytes))
    {:ok, source} = SourceSpool.source(spool)
    parent = self()
    _decoder = spawn_link(fn -> send(parent, {:res, decode_source(source)}) end)

    :ok = SourceSpool.write(spool, first)
    :ok = SourceSpool.write(spool, rest)
    :ok = SourceSpool.finalize(spool)
    assert_receive {:res, {:ok, _img}}, 5_000
  end
```

- [ ] **Step 2: Add the watchdog test** to `test/vix/vips/image_test.exs` (inside the `new_from_enum seekable` describe):

```elixir
    # (4) :timeout watchdog — the ONLY liveness mechanism for a live-but-stalled producer (the
    # monitor only fires on death). A stalled feeder must yield {:error,_}, not hang.
    @tag timeout: 10_000
    test "seekable :timeout aborts a stalled feeder instead of hanging" do
      enum = Stream.resource(fn -> :s end, fn :s -> Process.sleep(:infinity) end, fn _ -> :ok end)

      assert {:error, _} =
               Image.new_from_enum(enum, seekable: true, content_length: 1000, timeout: 300)
    end
```

- [ ] **Step 3: Run, expect pass** (the C/Elixir from Tasks 1–6 already implement these behaviors):

Run: `mix test test/vix/source_spool_test.exs test/vix/vips/image_test.exs`
Expected: PASS. A *hang* (not a clean failure) in test 1, 2, or 4 means the monitor/watchdog wiring is wrong — revisit Task 1's `spool_write_down`/`enif_monitor_process` or Task 6's `start_spool_watchdog`.

- [ ] **Step 4: Commit**

```bash
git add test/vix/source_spool_test.exs test/vix/vips/image_test.exs
git commit -m "test(spool): pin monitor-ownership, spawn_monitor, :short, watchdog, SEEK_END"
```

---

## Self-review notes (author)

**Spec coverage check** — every design section maps to a task:
- Push-not-pull boundary, callbacks native-only → Task 3 (`read_cb`/`seek_cb` touch no env/terms).
- `content_length` required + stable `SEEK_END` → Task 3 (`seek_cb` returns `content_length`), Task 6 (`content_length_required`); the length-cache regression is **directly pinned** by Task 9 test 6 (TIFF fed in two halves — SEEK_END must return `content_length`, not the frontier).
- Monitor-ownership through `start_feeder`, the `spawn_monitor` no-caller-crash payoff, `:short`, the `:timeout` watchdog, abort-no-deadlock → Task 9 (the design's named must-test contracts).
- Pre-allocated `SpoolBuf`, refcount via resource → Task 1.
- Lock-per-slice write → Task 2.
- `source/1` cursor split, single destroy notify → Task 3.
- Frontier blocking + monitor-down liveness → Task 4.
- `spawn_monitor`, exact-fill, zero-length → Task 5.
- `seekable: true`, `timeout:`, `max_bytes` default → Task 6.
- Multi-reader, registration discipline → Task 7.
- Lazy-image lifetime, double-free → Task 8.

**Deferred (design "Deferred (not v1)")** — intentionally not tasked: lock-free reads, decode-owner cancellation, forwarding stream exceptions, `iodata` write contract.

**Known coverage gaps** (acknowledged, not blockers):
- **HEIF/AVIF overlap instrumentation** — no HEIF/AVIF fixtures in `test/images`; TIFF stands in for seek-heavy. Since the *headline goal* is seek-heavy HEIF/AVIF overlap, this leaves the primary value proposition measured only by proxy. **Decision needed** (see below) on whether to add fixtures before claiming the goal.
- **NIF-unload / function-pointer safety on hot upgrade** — the design lists this as release-blocking. It is addressed structurally (the `VipsSourceCustom` is a BEAM resource via `g_object_to_erl_term`, which pins the library) but not exercised by a load/purge test; the valgrind run (Task 8 Step 3) is the practical backstop. A true hot-upgrade test needs a harness this project doesn't have.
- **Direct `read_cb`/`seek_cb` defensive-input cases** (NULL buffer, negative length, invalid whence) — not emittable from Elixir without a C test harness; covered by code review + the decode paths that exercise the normal branches.
- **monitor↔dtor failure injection** — hardened with `enif_demonitor_process` in the write dtor (Task 1) + the valgrind run; a deterministic ExUnit test isn't feasible (resource-dtor timing is async).

**Type/name consistency** — NIF names match across `spool.h`, `spool.c`, `vix.c` table, and `nif.ex` stubs: `nif_source_spool_{new,write,finalize,abort,source}`. Elixir surface: `SourceSpool.{new/1,write/2,finalize/1,abort/1,source/1,start_feeder/2}`. Error atoms: `:content_length_required`, `:invalid_content_length`, `:content_length_too_large`, `:not_owner`, `:closed`, `:aborted`, `:overflow`, `:short`, `:enomem`.
