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
ERL_NIF_TERM nif_source_spool_status(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]);

#endif
