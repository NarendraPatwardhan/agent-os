/* Private engine layout — single definition for engine.c + engine_ops_extra.c.
 * Not part of the public git_engine.h API. */

#ifndef GE_ENGINE_PRIV_H_
#define GE_ENGINE_PRIV_H_

#include "git_engine.h"
#include "git2.h"

#include <stddef.h>
#include <stdint.h>

/* Product caps (SYSTEMS.md §11b). */
#define GE_PACK_MAX_BYTES (64u * 1024u * 1024u)
#define GE_WRITE_MAX_BYTES (16u * 1024u * 1024u)
/* Max stdout embedded in one Response; overflow → preview + result.truncated. */
#ifndef GE_STDOUT_MAX_BYTES
#define GE_STDOUT_MAX_BYTES (1u * 1024u * 1024u)
#endif
/* Full body on worktree /.git/mc/out/last when stdout is truncated (D15). */
#define GE_OUT_LAST_MAX_BYTES (8u * 1024u * 1024u)
/* Worktree-relative path written when stdout exceeds embed limit (D15). */
#define GE_OUT_STREAM_PATH ".git/mc/out/last"
/* Hard cap for log max_count (D39); higher requests clamp + result.bounded. */
#define GE_LOG_MAX_COUNT 1000
/* Default log max_count when args omit it. */
#define GE_LOG_DEFAULT_COUNT 10
/* Max request JSON size for ge_run_json (fail closed). */
#define GE_REQUEST_MAX_BYTES (1u * 1024u * 1024u)

struct ge_engine {
  char root[4096];
  git_repository *repo;
  char err[512];
  /* Streaming pack indexer (network-free apply path). */
  git_indexer *indexer;
  git_odb *odb;
  git_indexer_progress progress;
  /* Accumulated import_pack chunk bytes (cleared on final/reset). */
  size_t pack_bytes;
  /* Request-local args.client_token (not process-global). */
  char client_token[128];
};

void ge_set_err(ge_engine *e, const char *msg);
void ge_set_err_git(ge_engine *e, const char *prefix);
int ge_ensure_repo(ge_engine *e);
int ge_safe_relpath(const char *path);
void ge_join_path(char *out, size_t cap, const char *root, const char *rel);

/* Effective stdout embed limit (honors ge_test_set_stdout_max_bytes). */
size_t ge_stdout_max_bytes(void);

/* Ok response with large-stdout handling (docs/git.md). If free_stdout!=0,
 * stdout_owned is freed before return. Never silently truncates without
 * result.truncated=true. */
char *ge_resp_ok_stdout(ge_engine *e, char *stdout_owned, int free_stdout,
                        const char *extra_result_json);

#endif /* GE_ENGINE_PRIV_H_ */
