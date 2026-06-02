#include <errno.h>
#include <stdint.h>
#include <stdio.h>  /* SEEK_SET / SEEK_CUR / SEEK_END */
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

/* Forward decl: write/2 (added in Task 2, after `new`) calls is_writer, which is
   defined further down. Declare it here so insertion order can't break -Werror.
   wr->buf is immutable from `new` until the write-handle dtor, and the resource is
   alive for the duration of any NIF call / down callback that reads it. */
static int is_writer(ErlNifEnv *env, SpoolWriteHandle *wr);

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
    /* Do NOT enif_demonitor_process here: OTP automatically removes the monitor
       just before this destructor runs, and demonitoring an already-fired /
       auto-removed monitor faults inside the dtor on OTP 27+ (observed:
       ethr_mutex_lock EINVAL on the very next lock). pipe.c's dtor likewise
       never demonitors. */
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
  if (!buf)
    return make_error_term(env, make_atom(env, "enomem"));
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
  if (!wr) {
    enif_release_resource(buf);
    return make_error_term(env, make_atom(env, "enomem"));
  }
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

/* ---- write ---- */

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

/* ---- finalize ---- */

static int is_writer(ErlNifEnv *env, SpoolWriteHandle *wr) {
  ErlNifPid self;
  enif_self(env, &self);
  return enif_compare_pids(&self, &wr->writer) == 0;
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
  if (!b) /* NULL only after the dtor ran; mirror abort/1's guard */
    return make_error_term(env, make_atom(env, "aborted"));
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
