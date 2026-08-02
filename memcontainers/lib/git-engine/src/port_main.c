/* git-engine — BEAM-owned Port process (SYSTEMS.md §11b).
 *
 * stdin/stdout: length-prefixed frames (see ge_port.h).
 * argv: git-engine [--root DIR]
 * Default root: $TMPDIR/agentos-git-XXXXXX or /tmp/agentos-git-XXXXXX
 */

#include "ge_port.h"
#include "git_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int ensure_dir(const char *path) {
  struct stat st;
  if (stat(path, &st) == 0)
    return S_ISDIR(st.st_mode) ? 0 : -1;
  if (mkdir(path, 0755) != 0)
    return -1;
  return 0;
}

static char *make_temp_root(void) {
  const char *base = getenv("TMPDIR");
  if (!base || !base[0])
    base = "/tmp";
  char tmpl[512];
  snprintf(tmpl, sizeof(tmpl), "%s/agentos-git-XXXXXX", base);
  char *path = strdup(tmpl);
  if (!path)
    return NULL;
  if (!mkdtemp(path)) {
    free(path);
    return NULL;
  }
  return path;
}

int main(int argc, char **argv) {
  const char *root_arg = NULL;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--root") == 0 && i + 1 < argc) {
      root_arg = argv[++i];
    } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      fprintf(stderr, "usage: git-engine [--root DIR]\n");
      return 0;
    }
  }

  char *owned = NULL;
  const char *root = root_arg;
  if (!root) {
    owned = make_temp_root();
    if (!owned) {
      fprintf(stderr, "git-engine: cannot create temp worktree\n");
      return 1;
    }
    root = owned;
  } else if (ensure_dir(root) != 0) {
    fprintf(stderr, "git-engine: root must be an existing directory: %s\n", root);
    free(owned);
    return 1;
  }

  ge_engine *e = ge_open(root);
  if (!e) {
    fprintf(stderr, "git-engine: ge_open failed for %s\n", root);
    free(owned);
    return 1;
  }

  /* Ready banner on stderr for the Port owner (ops / diagnostics). */
  fprintf(stderr, "git-engine ready root=%s version=%s\n", root, ge_version());
  fflush(stderr);

  for (;;) {
    uint8_t type = 0;
    uint8_t *payload = NULL;
    size_t plen = 0;
    int rr = ge_frame_read(stdin, &type, &payload, &plen);
    if (rr == 1)
      break; /* EOF */
    if (rr != 0) {
      fprintf(stderr, "git-engine: frame read error\n");
      free(payload);
      break;
    }
    if (ge_port_handle(e, type, payload, plen, stdout) != 0) {
      fprintf(stderr, "git-engine: handle/write error\n");
      free(payload);
      break;
    }
    free(payload);
  }

  ge_close(e);
  free(owned);
  return 0;
}
