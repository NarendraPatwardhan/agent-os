/* Focused regressions for sparse staging, fresh clones, file modes and rollback. */
#include "git_engine.h"

#include "git2.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int expect_ok(ge_engine *e, const char *req) {
  char *resp = ge_run_json(e, req);
  if (!resp)
    return 1;
  int bad = strstr(resp, "\"ok\":true") == NULL;
  if (bad)
    fprintf(stderr, "expected ok for %s\n%s\n", req, resp);
  ge_free(resp);
  return bad;
}

static int expect_fail(ge_engine *e, const char *req, const char *needle) {
  char *resp = ge_run_json(e, req);
  if (!resp)
    return 1;
  int good = strstr(resp, "\"ok\":false") != NULL &&
             (!needle || strstr(resp, needle) != NULL);
  if (!good)
    fprintf(stderr, "expected fail(%s) for %s\n%s\n", needle ? needle : "", req, resp);
  ge_free(resp);
  return good ? 0 : 1;
}

static char *make_root(const char *prefix) {
  char tmpl[128];
  snprintf(tmpl, sizeof(tmpl), "/tmp/%s-XXXXXX", prefix);
  return mkdtemp(strdup(tmpl));
}

static int raw_write(const char *path, const char *body) {
  FILE *f = fopen(path, "wb");
  if (!f)
    return -1;
  size_t n = strlen(body);
  int ok = fwrite(body, 1, n, f) == n;
  if (fclose(f) != 0)
    ok = 0;
  return ok ? 0 : -1;
}

static int raw_read(const char *path, char *out, size_t cap) {
  FILE *f = fopen(path, "rb");
  if (!f)
    return -1;
  size_t n = fread(out, 1, cap - 1, f);
  int ok = !ferror(f);
  if (fclose(f) != 0)
    ok = 0;
  if (!ok)
    return -1;
  out[n] = '\0';
  return 0;
}

static int commit_file(ge_engine *e, const char *message, int when) {
  char req[512];
  snprintf(req, sizeof(req),
           "{\"op\":\"commit\",\"args\":{\"message\":\"%s\","
           "\"name\":\"Hardening\",\"email\":\"hardening@test\","
           "\"when_unix\":%d}}",
           message, when);
  return expect_ok(e, req);
}

/* Return 1 when an index path exists, 0 when absent, -1 on inspection error. */
static int index_info(const char *root, const char *path, uint32_t *mode,
                      uint16_t *flags_extended) {
  git_repository *repo = NULL;
  git_index *index = NULL;
  int result = -1;
  if (git_repository_open_ext(&repo, root, GIT_REPOSITORY_OPEN_NO_SEARCH, NULL) != 0)
    goto done;
  if (git_repository_index(&index, repo) != 0)
    goto done;
  const git_index_entry *entry = git_index_get_bypath(index, path, 0);
  if (!entry) {
    result = 0;
    goto done;
  }
  if (mode)
    *mode = entry->mode;
  if (flags_extended)
    *flags_extended = entry->flags_extended;
  result = 1;
done:
  if (index)
    git_index_free(index);
  if (repo)
    git_repository_free(repo);
  return result;
}

static int set_index_skip(const char *root, const char *path, int enabled) {
  git_repository *repo = NULL;
  git_index *index = NULL;
  int result = -1;
  if (git_repository_open_ext(&repo, root, GIT_REPOSITORY_OPEN_NO_SEARCH, NULL) != 0)
    goto done;
  if (git_repository_index(&index, repo) != 0)
    goto done;
  const git_index_entry *entry = git_index_get_bypath(index, path, 0);
  if (!entry)
    goto done;
  git_index_entry copy = *entry;
  if (enabled) {
    copy.flags_extended |= GIT_INDEX_ENTRY_SKIP_WORKTREE;
    copy.flags |= GIT_INDEX_ENTRY_VALID;
  } else {
    copy.flags_extended &= (uint16_t)~GIT_INDEX_ENTRY_SKIP_WORKTREE;
    copy.flags &= (uint16_t)~GIT_INDEX_ENTRY_VALID;
  }
  if (git_index_add(index, &copy) != 0 || git_index_write(index) != 0)
    goto done;
  result = 0;
done:
  if (index)
    git_index_free(index);
  if (repo)
    git_repository_free(repo);
  return result;
}

static int tree_info(const char *root, const char *path, uint32_t *mode) {
  git_repository *repo = NULL;
  git_object *obj = NULL;
  git_commit *commit = NULL;
  git_tree *tree = NULL;
  int result = -1;
  if (git_repository_open_ext(&repo, root, GIT_REPOSITORY_OPEN_NO_SEARCH, NULL) != 0)
    goto done;
  if (git_revparse_single(&obj, repo, "HEAD") != 0)
    goto done;
  if (git_commit_lookup(&commit, repo, git_object_id(obj)) != 0)
    goto done;
  if (git_commit_tree(&tree, commit) != 0)
    goto done;
  const git_tree_entry *entry = NULL;
  if (git_tree_entry_bypath(&entry, tree, path) != 0) {
    result = 0;
    goto done;
  }
  if (mode)
    *mode = (uint32_t)git_tree_entry_filemode(entry);
  result = 1;
done:
  if (tree)
    git_tree_free(tree);
  if (commit)
    git_commit_free(commit);
  if (obj)
    git_object_free(obj);
  if (repo)
    git_repository_free(repo);
  return result;
}

static int config_bool_info(const char *root, const char *key, int *present, int *value) {
  git_repository *repo = NULL;
  git_config *config = NULL;
  int result = -1;
  if (git_repository_open_ext(&repo, root, GIT_REPOSITORY_OPEN_NO_SEARCH, NULL) != 0 ||
      git_repository_config(&config, repo) != 0)
    goto done;
  int rc = git_config_get_bool(value, config, key);
  if (rc == GIT_ENOTFOUND) {
    *present = 0;
    result = 0;
  } else if (rc == 0) {
    *present = 1;
    result = 0;
  }
done:
  if (config)
    git_config_free(config);
  if (repo)
    git_repository_free(repo);
  return result;
}

static int test_clone_preflight(void) {
  char *fresh_root = make_root("ge-clone-fresh");
  char *repo_root = make_root("ge-clone-repo");
  char *file_root = make_root("ge-clone-file");
  if (!fresh_root || !repo_root || !file_root)
    return 1;

  ge_engine *fresh = ge_open(fresh_root);
  ge_engine *fresh_competitor = ge_open(fresh_root);
  ge_engine *repo = ge_open(repo_root);
  ge_engine *file = ge_open(file_root);
  if (!fresh || !fresh_competitor || !repo || !file)
    return 1;
  if (expect_ok(fresh, "{\"op\":\"clone.preflight\"}"))
    return 1;
  if (expect_ok(fresh, "{\"op\":\"clone.begin\"}") ||
      expect_fail(fresh_competitor, "{\"op\":\"clone.begin\"}", "reserved") ||
      expect_ok(fresh, "{\"op\":\"clone.end\"}") ||
      expect_ok(fresh_competitor, "{\"op\":\"clone.preflight\"}"))
    return 1;
  /* init retires the physical control file. A remote worktree path with the
   * same name must therefore survive the balanced clone.end call. */
  if (expect_ok(fresh, "{\"op\":\"clone.begin\"}") ||
      expect_ok(fresh, "{\"op\":\"init\"}") ||
      expect_ok(fresh, "{\"op\":\"write\",\"args\":{\"path\":\".agentos-clone.lock\","
                       "\"content\":\"tracked name\\n\"}}") ||
      expect_ok(fresh, "{\"op\":\"clone.end\"}"))
    return 1;
  char collision[4096];
  snprintf(collision, sizeof(collision), "%s/.agentos-clone.lock", fresh_root);
  if (access(collision, F_OK) != 0)
    return 1;

  char marker[4096];
  snprintf(marker, sizeof(marker), "%s/existing.txt", file_root);
  if (raw_write(marker, "existing\n") != 0)
    return 1;
  /* A non-repository root is rejected solely because it is non-empty. */
  ge_close(file);
  file = ge_open(file_root);
  if (!file || expect_fail(file, "{\"op\":\"clone.preflight\"}", "fresh"))
    return 1;

  if (expect_ok(repo, "{\"op\":\"init\"}"))
    return 1;
  if (expect_ok(repo, "{\"op\":\"write\",\"args\":{\"path\":\"tracked.txt\","
                   "\"content\":\"tracked\\n\"}}"))
    return 1;
  if (expect_ok(repo, "{\"op\":\"add\",\"args\":{\"path\":\"tracked.txt\"}}"))
    return 1;
  if (commit_file(repo, "existing repository", 1700001000))
    return 1;
  /* Existing repository/index/worktree content is rejected before any clone op. */
  if (expect_fail(repo, "{\"op\":\"clone.preflight\"}", "repository"))
    return 1;

  ge_close(fresh);
  ge_close(fresh_competitor);
  ge_close(repo);
  ge_close(file);
  return 0;
}

static int test_add_ignore_mode_and_empty_commit(void) {
  char *root = make_root("ge-add-hardening");
  if (!root)
    return 1;
  ge_engine *e = ge_open(root);
  if (!e)
    return 1;
  if (expect_ok(e, "{\"op\":\"init\"}"))
    return 1;
  /* Ignoring a path later must not make an already tracked file impossible to
   * update, matching ordinary Git add semantics. */
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"tracked-ignored.txt\","
                   "\"content\":\"tracked before ignore\\n\"}}") ||
      expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"tracked-ignored.txt\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\".gitignore\","
                   "\"content\":\"ignored.txt\\nbuild/\\ntracked-ignored.txt\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\".gitignore\"}}"))
    return 1;
  if (commit_file(e, "ignore rules", 1700001100))
    return 1;

  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"ignored.txt\","
                   "\"content\":\"secret\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"build/out.txt\","
                   "\"content\":\"artifact\\n\"}}"))
    return 1;
  if (expect_fail(e, "{\"op\":\"add\",\"args\":{\"path\":\"ignored.txt\"}}",
                  "ignored"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"all\":true}}"))
    return 1;
  if (index_info(root, "ignored.txt", NULL, NULL) != 0 ||
      index_info(root, "build/out.txt", NULL, NULL) != 0) {
    fprintf(stderr, "bulk add staged ignored untracked path\n");
    return 1;
  }
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"tracked-ignored.txt\","
                   "\"content\":\"tracked after ignore\\n\"}}") ||
      expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"tracked-ignored.txt\"}}"))
    return 1;

  char exec_path[4096];
  snprintf(exec_path, sizeof(exec_path), "%s/run.sh", root);
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"run.sh\","
                   "\"content\":\"#!/bin/sh\\nexit 0\\n\"}}"))
    return 1;
  if (chmod(exec_path, 0755) != 0)
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"run.sh\"}}"))
    return 1;
  uint32_t mode = 0;
  if (index_info(root, "run.sh", &mode, NULL) != 1 || mode != GIT_FILEMODE_BLOB_EXECUTABLE) {
    fprintf(stderr, "executable index mode was %o\n", mode);
    return 1;
  }
  if (commit_file(e, "executable", 1700001101))
    return 1;
  if (chmod(exec_path, 0644) != 0)
    return 1;
  if (expect_ok(e, "{\"op\":\"reset\",\"args\":{\"rev\":\"HEAD\",\"mode\":\"hard\"}}"))
    return 1;
  struct stat st;
  if (stat(exec_path, &st) != 0 || (st.st_mode & 0777) != 0755) {
    fprintf(stderr, "executable checkout mode was %o\n", (unsigned)(st.st_mode & 0777));
    return 1;
  }
  if (expect_fail(e,
                  "{\"op\":\"commit\",\"args\":{\"message\":\"unchanged\","
                  "\"name\":\"Hardening\",\"email\":\"hardening@test\"}}",
                  "nothing to commit"))
    return 1;
  ge_close(e);
  return 0;
}

static int test_sparse_semantics(void) {
  char *root = make_root("ge-sparse-hardening");
  if (!root)
    return 1;
  ge_engine *e = ge_open(root);
  if (!e)
    return 1;
  if (expect_ok(e, "{\"op\":\"init\"}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"in/file.txt\","
                   "\"content\":\"base in\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"out/file.txt\","
                   "\"content\":\"base out\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"all\":true}}"))
    return 1;
  if (commit_file(e, "sparse base", 1700001200))
    return 1;
  if (expect_ok(e, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}"))
    return 1;

  char in_path[4096], out_path[4096], sc_path[4096];
  snprintf(in_path, sizeof(in_path), "%s/in/file.txt", root);
  snprintf(out_path, sizeof(out_path), "%s/out/file.txt", root);
  snprintf(sc_path, sizeof(sc_path), "%s/.git/info/sparse-checkout", root);
  if (access(out_path, F_OK) == 0 || access(in_path, F_OK) != 0) {
    fprintf(stderr, "sparse-set did not materialize the expected cone\n");
    return 1;
  }
  uint16_t flags = 0;
  if (index_info(root, "out/file.txt", NULL, &flags) != 1 ||
      !(flags & GIT_INDEX_ENTRY_SKIP_WORKTREE)) {
    fprintf(stderr, "out-of-cone index entry lacks skip-worktree\n");
    return 1;
  }

  /* A clean sparse repository can retarget without disable. Newly included
   * paths must be restored before the previous cone is pruned. */
  if (expect_ok(e, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"out\"]}}") ||
      access(in_path, F_OK) == 0 || access(out_path, F_OK) != 0)
    return 1;
  if (expect_ok(e, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}") ||
      access(out_path, F_OK) == 0 || access(in_path, F_OK) != 0)
    return 1;

  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"in/file.txt\","
                   "\"content\":\"edited in\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"all\":true}}"))
    return 1;
  if (commit_file(e, "sparse edit", 1700001201))
    return 1;
  uint32_t tree_mode = 0;
  if (tree_info(root, "out/file.txt", &tree_mode) != 1) {
    fprintf(stderr, "sparse add-all dropped the out-of-cone tree entry\n");
    return 1;
  }

  /* Both sparse transitions reject dirty worktree changes before metadata or
   * checkout mutation. */
  char pattern_before[4096];
  if (raw_read(sc_path, pattern_before, sizeof(pattern_before)) != 0)
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"in/file.txt\","
                   "\"content\":\"dirty in\\n\"}}"))
    return 1;
  if (expect_fail(e, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}",
                  "clean"))
    return 1;
  if (expect_fail(e, "{\"op\":\"sparse-disable\"}", "clean"))
    return 1;
  char pattern_after[4096];
  if (raw_read(sc_path, pattern_after, sizeof(pattern_after)) != 0 ||
      strcmp(pattern_before, pattern_after) != 0 || access(out_path, F_OK) == 0) {
    fprintf(stderr, "dirty sparse failure changed metadata or worktree\n");
    return 1;
  }
  if (expect_ok(e, "{\"op\":\"reset\",\"args\":{\"rev\":\"HEAD\",\"mode\":\"hard\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"sparse-disable\"}"))
    return 1;
  if (access(out_path, F_OK) != 0 || access(sc_path, F_OK) == 0)
    return 1;

  ge_close(e);

  /* Inject config, pattern-write, and checkout failures.  Each is rejected
   * before pruning, so the out-of-cone file remains present. */
  char *fail_root = make_root("ge-sparse-failures");
  if (!fail_root)
    return 1;
  ge_engine *fail = ge_open(fail_root);
  if (!fail)
    return 1;
  if (expect_ok(fail, "{\"op\":\"init\"}") ||
      expect_ok(fail, "{\"op\":\"write\",\"args\":{\"path\":\"in/file.txt\","
                         "\"content\":\"in\\n\"}}") ||
      expect_ok(fail, "{\"op\":\"write\",\"args\":{\"path\":\"out/file.txt\","
                         "\"content\":\"out\\n\"}}") ||
      expect_ok(fail, "{\"op\":\"add\",\"args\":{\"all\":true}}") ||
      commit_file(fail, "failure base", 1700001300))
    return 1;
  char info[4096], config[4096], head[4096], in_dir[4096], saved[4096];
  snprintf(info, sizeof(info), "%s/.git/info", fail_root);
  snprintf(config, sizeof(config), "%s/.git/config", fail_root);
  snprintf(head, sizeof(head), "%s/.git/HEAD", fail_root);
  snprintf(in_dir, sizeof(in_dir), "%s/in", fail_root);
  snprintf(saved, sizeof(saved), "%s/.git/config.saved", fail_root);
  char fail_out[4096], in_file[4096];
  snprintf(fail_out, sizeof(fail_out), "%s/out/file.txt", fail_root);
  snprintf(in_file, sizeof(in_file), "%s/in/file.txt", fail_root);

  /* A deterministic prune failure must restore full config, index and
   * materialization rather than leaving a half-applied sparse repository. */
  char out_dir[4096], fail_sc[4096];
  snprintf(out_dir, sizeof(out_dir), "%s/out", fail_root);
  snprintf(fail_sc, sizeof(fail_sc), "%s/.git/info/sparse-checkout", fail_root);
  if (chmod(out_dir, 0555) != 0)
    return 1;
  if (expect_fail(fail, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}",
                  "prune"))
    return 1;
  if (chmod(out_dir, 0755) != 0 || access(fail_out, F_OK) != 0 ||
      access(in_file, F_OK) != 0 || access(fail_sc, F_OK) == 0)
    return 1;
  uint16_t rollback_flags = 0;
  int sparse_present = 0, sparse_value = 0;
  if (index_info(fail_root, "out/file.txt", NULL, &rollback_flags) != 1 ||
      (rollback_flags & GIT_INDEX_ENTRY_SKIP_WORKTREE) ||
      config_bool_info(fail_root, "core.sparseCheckout", &sparse_present,
                       &sparse_value) != 0 ||
      (sparse_present && sparse_value)) {
    fprintf(stderr, "sparse prune rollback left sparse metadata or index state\n");
    return 1;
  }

  if (chmod(info, 0555) != 0)
    return 1;
  if (expect_fail(fail, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}",
                  "write"))
    return 1;
  chmod(info, 0755);
  if (access(fail_out, F_OK) != 0)
    return 1;

  char head_body[4096];
  if (raw_read(head, head_body, sizeof(head_body)) != 0 ||
      rename(config, saved) != 0 || mkdir(config, 0755) != 0)
    return 1;
  if (expect_fail(fail, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}",
                  "config"))
    return 1;
  rmdir(config);
  if (rename(saved, config) != 0 || access(fail_out, F_OK) != 0)
    return 1;
  if (set_index_skip(fail_root, "in/file.txt", 1) != 0 ||
      unlink(in_file) != 0 || chmod(in_dir, 0555) != 0)
    return 1;
  if (expect_fail(fail, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}",
                  "checkout"))
    return 1;
  chmod(in_dir, 0755);
  if (set_index_skip(fail_root, "in/file.txt", 0) != 0 ||
      expect_ok(fail, "{\"op\":\"reset\",\"args\":{\"rev\":\"HEAD\",\"mode\":\"hard\"}}"))
    return 1;
  if (access(fail_out, F_OK) != 0 || raw_write(head, "invalid\n") != 0)
    return 1;
  /* A malformed HEAD is rejected by the clean-status preflight itself; it
   * must still fail before any prune. */
  if (expect_fail(fail, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"in\"]}}",
                  "status preflight"))
    return 1;
  if (raw_write(head, head_body) != 0 || access(fail_out, F_OK) != 0)
    return 1;
  ge_close(fail);
  return 0;
}

int main(void) {
  git_libgit2_init();
  if (test_clone_preflight() || test_add_ignore_mode_and_empty_commit() ||
      test_sparse_semantics()) {
    fprintf(stderr, "git_hardening_test FAILED\n");
    git_libgit2_shutdown();
    return 1;
  }
  git_libgit2_shutdown();
  printf("git_hardening_test SUCCESS\n");
  return 0;
}
