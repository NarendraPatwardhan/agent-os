/* Private engine layout — single definition for engine.c + engine_ops_extra.c.
 * Not part of the public git_engine.h API. */

#ifndef GE_ENGINE_PRIV_H_
#define GE_ENGINE_PRIV_H_

#include "git_engine.h"
#include "git2.h"

#include <stddef.h>
#include <stdint.h>

/* Product caps (GIT.md). */
#define GE_PACK_MAX_BYTES (64u * 1024u * 1024u)
#define GE_WRITE_MAX_BYTES (16u * 1024u * 1024u)

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
};

void ge_set_err(ge_engine *e, const char *msg);
void ge_set_err_git(ge_engine *e, const char *prefix);
int ge_ensure_repo(ge_engine *e);
int ge_safe_relpath(const char *path);
void ge_join_path(char *out, size_t cap, const char *root, const char *rel);

#endif /* GE_ENGINE_PRIV_H_ */
