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

/* Per-slice copy bound. write/2 holds buf->lock during each slice's memcpy and releases it between
   slices, so this caps how long a reader can wait behind one write copy; read_cb uses it to cap a
   single memcpy. 256 KiB is a throughput/latency compromise — lower it for tighter read latency
   under heavy writes. */
#define SPOOL_MAX_SLICE ((size_t)(256 * 1024))

static ErlNifResourceType *SPOOL_BUF_RT;
static ErlNifResourceType *SPOOL_WRITE_RT;

typedef enum { SPOOL_OPEN, SPOOL_DONE, SPOOL_ABORTED } SpoolState;

/* API-facing abort cause reported by status/1. Kept separate from err_errno because errno values
   collapse on some platforms (ENODATA/ECANCELED are #defined to EIO on macOS), so errno can't
   distinguish the causes. */
typedef enum {
  SPOOL_REASON_NONE,
  SPOOL_REASON_OVERFLOW,
  SPOOL_REASON_SHORT,
  SPOOL_REASON_CANCELLED,
  SPOOL_REASON_WRITER_DOWN,
  SPOOL_REASON_ERROR
} SpoolReason;

typedef struct {
  ErlNifMutex *lock;
  ErlNifCond *cond;

  guint8 *data;          /* enif_alloc(content_length) once; never moves */
  gint64 size;           /* published frontier, 0..content_length */
  gint64 content_length; /* immutable after new */

  SpoolState state;
  SpoolReason reason;    /* API cause when state == SPOOL_ABORTED */
  int err_errno;         /* libvips-facing errno surfaced by read_cb */
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
static void spool_set_terminal_locked(SpoolBuf *b, SpoolState st, SpoolReason reason,
                                      int err) {
  if (b->state == SPOOL_OPEN) {
    b->state = st;
    b->reason = reason;
    if (st == SPOOL_ABORTED)
      b->err_errno = err ? err : EIO;
  }
  enif_cond_broadcast(b->cond);
}

static void spool_set_terminal(SpoolBuf *b, SpoolState st, SpoolReason reason, int err) {
  enif_mutex_lock(b->lock);
  spool_set_terminal_locked(b, st, reason, err);
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
    spool_set_terminal(wr->buf, SPOOL_ABORTED, SPOOL_REASON_WRITER_DOWN, EPIPE); /* backstop if still OPEN */
    enif_release_resource(wr->buf);                    /* outside any lock */
    wr->buf = NULL;
  }
}

/* writer process died: time-critical wakeup happens HERE, freeing is the dtor's job */
static void spool_write_down(ErlNifEnv *env, void *obj, ErlNifPid *pid,
                             ErlNifMonitor *monitor) {
  SpoolWriteHandle *wr = (SpoolWriteHandle *)obj;
  if (wr->buf)
    spool_set_terminal(wr->buf, SPOOL_ABORTED, SPOOL_REASON_WRITER_DOWN, EPIPE);
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
  buf->reason = SPOOL_REASON_NONE;
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
  if (!b) /* mirror finalize/abort guards */
    return make_error_term(env, make_atom(env, "aborted"));
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

    /* would this binary exceed the declared length? `remaining` is >= 0 by invariant
       (size <= content_length), so compare as unsigned and avoid casting a potentially
       huge size_t (bin.size - off) to a signed gint64. */
    gint64 remaining = b->content_length - b->size;
    if ((guint64)(bin.size - off) > (guint64)remaining) {
      spool_set_terminal_locked(b, SPOOL_ABORTED, SPOOL_REASON_OVERFLOW, EFBIG);
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
      spool_set_terminal_locked(b, SPOOL_DONE, SPOOL_REASON_NONE, 0);
      ret = ATOM_OK;
    } else {
      spool_set_terminal_locked(b, SPOOL_ABORTED, SPOOL_REASON_SHORT, ENODATA);
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
    spool_set_terminal(wr->buf, SPOOL_ABORTED, SPOOL_REASON_CANCELLED, ECANCELED);
  return ATOM_OK;
}

/* ---- status (any process) ---- */

static ERL_NIF_TERM reason_atom(ErlNifEnv *env, SpoolReason reason) {
  switch (reason) {
  case SPOOL_REASON_OVERFLOW:
    return make_atom(env, "overflow");
  case SPOOL_REASON_SHORT:
    return make_atom(env, "short");
  case SPOOL_REASON_CANCELLED:
    return make_atom(env, "cancelled");
  case SPOOL_REASON_WRITER_DOWN:
    return make_atom(env, "writer_down");
  default:
    return make_atom(env, "error");
  }
}

ERL_NIF_TERM nif_source_spool_status(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  ASSERT_ARGC(argc, 1);
  SpoolWriteHandle *wr;
  if (!enif_get_resource(env, argv[0], SPOOL_WRITE_RT, (void **)&wr))
    return make_error(env, "invalid spool handle");

  SpoolBuf *b = wr->buf;
  if (!b) /* dtor already ran */
    return enif_make_tuple2(env, make_atom(env, "aborted"),
                            make_atom(env, "writer_down"));

  enif_mutex_lock(b->lock);
  SpoolState st = b->state;
  SpoolReason rs = b->reason;
  enif_mutex_unlock(b->lock);

  switch (st) {
  case SPOOL_DONE:
    return make_atom(env, "done");
  case SPOOL_ABORTED:
    return enif_make_tuple2(env, make_atom(env, "aborted"), reason_atom(env, rs));
  default:
    return make_atom(env, "open");
  }
}

/* ---- source/1 + read/seek callbacks ---- */

/* Owns the SpoolReader; the single GObject destroy notify (no per-signal free). */
static void spool_reader_free(gpointer data) {
  SpoolReader *r = (SpoolReader *)data;
  enif_release_resource(r->buf); /* never under buf->lock */
  enif_free(r);
}

static gint64 spool_read_cb(VipsSourceCustom *source, void *buffer,
                            gint64 length, void *user_data) {
  (void)source;
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
  (void)source;
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
  if (!b) /* mirror new/write/finalize/abort guards */
    return make_error_term(env, make_atom(env, "aborted"));

  /* Multiple sources may be created from one spool — each gets an independent read cursor over the
     shared buffer (this is the reopen / parallel-decode path). Reject only if already aborted; a
     concurrent abort right after this check is fine (the returned source fails on first read). */
  enif_mutex_lock(b->lock);
  int aborted = b->state == SPOOL_ABORTED;
  enif_mutex_unlock(b->lock);
  if (aborted)
    return make_error_term(env, make_atom(env, "aborted"));

  /* b stays alive via wr for the call; this keep gives the reader its own independent ref so the
     buffer outlives wr. No lock needed for the refcount op. */
  enif_keep_resource(b);
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
