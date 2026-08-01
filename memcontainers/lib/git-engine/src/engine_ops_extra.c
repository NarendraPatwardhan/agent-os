/* Extra Run ops shared by ge_run_json (local porcelain, host apply helpers,
 * sparse cone, submodule list). Engine never dials the network. */
#include "git_engine.h"
#include "ge_engine_priv.h"
#include "json_min.h"

#include "git2.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* ── Local porcelain ──────────────────────────────────────────────────────── */

int op_rm(ge_engine *e, const char *args) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char path[1024];
  if (jmin_get_string(args, "path", path, sizeof(path)) != 0 || !ge_safe_relpath(path)) {
    ge_set_err(e, "rm: bad path");
    return -1;
  }
  git_index *index = NULL;
  if (git_repository_index(&index, e->repo) != 0) {
    ge_set_err_git(e, "rm: index");
    return -1;
  }
  if (git_index_remove_bypath(index, path) != 0) {
    git_index_free(index);
    ge_set_err_git(e, "rm");
    return -1;
  }
  git_index_write(index);
  git_index_free(index);
  char full[4096];
  ge_join_path(full, sizeof(full), e->root, path);
  unlink(full); /* ignore missing worktree file */
  return 0;
}

/* op_diff — product surface: full unified patch (GIT_DIFF_FORMAT_PATCH).
 *
 * stdout is the complete patch text (*out_owned malloc'd; caller frees).
 * Not name-status / --stat.
 *
 * Args:
 *   path          — single worktree-relative pathspec
 *   paths         — JSON string array of pathspecs (max 16); wins over path
 *   cached|staged — bool; true → HEAD tree vs index (git diff --cached);
 *                   false/omit → index vs workdir (default unstaged)
 *
 * Unborn HEAD + cached: empty patch (NULL tree). Bad pathspecs fail closed.
 */
int op_diff(ge_engine *e, const char *args, char **out_owned) {
  if (out_owned)
    *out_owned = NULL;
  if (ge_ensure_repo(e) != 0)
    return -1;

  enum { DIFF_PATHSPEC_MAX = 16 };
  char path_store[DIFF_PATHSPEC_MAX][1024];
  char *pathspec_strs[DIFF_PATHSPEC_MAX];
  size_t nspec = 0;

  if (args) {
    const char *parr = jmin_get_array(args, "paths");
    if (parr) {
      const char *cur = parr;
      char item[1024];
      while (jmin_array_next_string(&cur, item, sizeof(item)) == 0) {
        if (!item[0])
          continue;
        if (!ge_safe_relpath(item)) {
          ge_set_err(e, "diff: bad path");
          return -1;
        }
        if (nspec >= DIFF_PATHSPEC_MAX) {
          ge_set_err(e, "diff: too many paths");
          return -1;
        }
        size_t il = strlen(item);
        if (il >= sizeof(path_store[0])) {
          ge_set_err(e, "diff: path too long");
          return -1;
        }
        memcpy(path_store[nspec], item, il + 1);
        pathspec_strs[nspec] = path_store[nspec];
        nspec++;
      }
    } else {
      char path[1024] = "";
      if (jmin_get_string(args, "path", path, sizeof(path)) == 0 && path[0]) {
        if (!ge_safe_relpath(path)) {
          ge_set_err(e, "diff: bad path");
          return -1;
        }
        memcpy(path_store[0], path, strlen(path) + 1);
        pathspec_strs[0] = path_store[0];
        nspec = 1;
      }
    }
  }

  git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
  if (nspec > 0) {
    opts.pathspec.strings = pathspec_strs;
    opts.pathspec.count = (size_t)nspec;
  }

  int cached = 0;
  if (args) {
    int v = 0;
    if (jmin_get_bool(args, "cached", &v) == 0 && v)
      cached = 1;
    if (jmin_get_bool(args, "staged", &v) == 0 && v)
      cached = 1;
  }

  git_diff *diff = NULL;
  if (cached) {
    /* HEAD tree → index (staged). Unborn HEAD → empty patch (NULL tree). */
    git_object *obj = NULL;
    git_tree *tree = NULL;
    if (git_revparse_single(&obj, e->repo, "HEAD") == 0) {
      git_object *peeled = NULL;
      if (git_object_peel(&peeled, obj, GIT_OBJECT_TREE) != 0) {
        git_object_free(obj);
        ge_set_err_git(e, "diff: peel HEAD");
        return -1;
      }
      git_object_free(obj);
      tree = (git_tree *)peeled;
    }
    if (git_diff_tree_to_index(&diff, e->repo, tree, NULL, &opts) != 0) {
      if (tree)
        git_tree_free(tree);
      ge_set_err_git(e, "diff");
      return -1;
    }
    if (tree)
      git_tree_free(tree);
  } else {
    if (git_diff_index_to_workdir(&diff, e->repo, NULL, &opts) != 0) {
      ge_set_err_git(e, "diff");
      return -1;
    }
  }

  git_buf buf = {0};
  if (git_diff_to_buf(&buf, diff, GIT_DIFF_FORMAT_PATCH) != 0) {
    git_diff_free(diff);
    ge_set_err_git(e, "diff: to_buf");
    return -1;
  }
  size_t n = buf.ptr ? buf.size : 0;
  char *out = (char *)malloc(n + 1);
  if (!out) {
    git_buf_dispose(&buf);
    git_diff_free(diff);
    ge_set_err(e, "diff: out of memory");
    return -1;
  }
  if (n > 0)
    memcpy(out, buf.ptr, n);
  out[n] = '\0';
  git_buf_dispose(&buf);
  git_diff_free(diff);
  *out_owned = out;
  return 0;
}

/* *out_owned is malloc'd on success; caller frees. Full commit message (no fixed-buffer cut). */
int op_show(ge_engine *e, const char *args, char **out_owned) {
  if (out_owned)
    *out_owned = NULL;
  if (ge_ensure_repo(e) != 0)
    return -1;
  char rev[256] = "HEAD";
  (void)jmin_get_string(args, "rev", rev, sizeof(rev));
  git_object *obj = NULL;
  if (git_revparse_single(&obj, e->repo, rev) != 0) {
    ge_set_err_git(e, "show");
    return -1;
  }
  if (git_object_type(obj) != GIT_OBJECT_COMMIT) {
    git_object_free(obj);
    ge_set_err(e, "show: not a commit");
    return -1;
  }
  git_commit *c = (git_commit *)obj;
  char hex[GIT_OID_HEXSZ + 1];
  git_oid_tostr(hex, sizeof(hex), git_commit_id(c));
  const git_signature *a = git_commit_author(c);
  const char *msg = git_commit_message(c);
  const char *an = a ? a->name : "?";
  const char *ae = a ? a->email : "?";
  const char *m = msg ? msg : "";
  /* Exact size: avoid fixed-buffer truncation of large commit messages. */
  int need = snprintf(NULL, 0, "commit %s\nAuthor: %s <%s>\n\n%s\n", hex, an, ae, m);
  if (need < 0) {
    git_object_free(obj);
    ge_set_err(e, "show: format");
    return -1;
  }
  char *out = (char *)malloc((size_t)need + 1);
  if (!out) {
    git_object_free(obj);
    ge_set_err(e, "show: out of memory");
    return -1;
  }
  snprintf(out, (size_t)need + 1, "commit %s\nAuthor: %s <%s>\n\n%s\n", hex, an, ae, m);
  git_object_free(obj);
  *out_owned = out;
  return 0;
}

int op_reset(ge_engine *e, const char *args) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char rev[256] = "HEAD";
  char mode[32] = "mixed";
  (void)jmin_get_string(args, "rev", rev, sizeof(rev));
  (void)jmin_get_string(args, "mode", mode, sizeof(mode));
  git_object *target = NULL;
  if (git_revparse_single(&target, e->repo, rev) != 0) {
    ge_set_err_git(e, "reset: rev");
    return -1;
  }
  git_reset_t t = GIT_RESET_MIXED;
  int ff_only = 0;
  if (strcmp(mode, "soft") == 0)
    t = GIT_RESET_SOFT;
  else if (strcmp(mode, "hard") == 0)
    t = GIT_RESET_HARD;
  else if (strcmp(mode, "ff-only") == 0 || strcmp(mode, "ff_only") == 0) {
    /* Pull v1: hard reset only when target is a fast-forward of HEAD. */
    t = GIT_RESET_HARD;
    ff_only = 1;
  }
  if (ff_only) {
    git_oid head_oid;
    const git_oid *target_oid = git_object_id(target);
    if (git_reference_name_to_id(&head_oid, e->repo, "HEAD") == 0) {
      if (!git_oid_equal(&head_oid, target_oid)) {
        /* FF iff target is a descendant of HEAD (HEAD is ancestor of target). */
        int desc = git_graph_descendant_of(e->repo, target_oid, &head_oid);
        if (desc != 1) {
          git_object_free(target);
          ge_set_err(e, "git: not fast-forward");
          return -1;
        }
      }
    }
    /* unborn HEAD: allow hard reset to target */
  }
  int rc = git_reset(e->repo, target, t, NULL);
  git_object_free(target);
  if (rc != 0) {
    ge_set_err_git(e, "reset");
    return -1;
  }
  return 0;
}

int op_tag(ge_engine *e, const char *args) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char name[256];
  char rev[256];
  int del = 0;
  (void)jmin_get_bool(args, "delete", &del);
  if (jmin_get_string(args, "name", name, sizeof(name)) != 0 || !name[0]) {
    ge_set_err(e, "tag: name required");
    return -1;
  }
  /* jmin_get_string clears out on miss — only overwrite default on success. */
  snprintf(rev, sizeof(rev), "HEAD");
  {
    char tmp[256];
    if (jmin_get_string(args, "rev", tmp, sizeof(tmp)) == 0 && tmp[0])
      snprintf(rev, sizeof(rev), "%s", tmp);
  }
  if (del) {
    char ref[320];
    snprintf(ref, sizeof(ref), "refs/tags/%s", name);
    if (git_reference_remove(e->repo, ref) != 0) {
      ge_set_err_git(e, "tag delete");
      return -1;
    }
    return 0;
  }
  git_object *target = NULL;
  if (git_revparse_single(&target, e->repo, rev) != 0) {
    ge_set_err_git(e, "tag: rev");
    return -1;
  }
  git_oid tag_oid;
  int rc = git_tag_create_lightweight(&tag_oid, e->repo, name, target, 0);
  git_object_free(target);
  if (rc != 0) {
    ge_set_err_git(e, "tag create");
    return -1;
  }
  return 0;
}

int op_config(ge_engine *e, const char *args, char *out, size_t out_cap) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char action[32] = "get";
  char key[256] = "";
  char value[512] = "";
  (void)jmin_get_string(args, "action", action, sizeof(action));
  (void)jmin_get_string(args, "key", key, sizeof(key));
  (void)jmin_get_string(args, "value", value, sizeof(value));
  git_config *cfg = NULL;
  if (git_repository_config(&cfg, e->repo) != 0) {
    ge_set_err_git(e, "config");
    return -1;
  }
  int rc = 0;
  if (strcmp(action, "set") == 0) {
    if (!key[0]) {
      ge_set_err(e, "config set: key required");
      rc = -1;
    } else if (git_config_set_string(cfg, key, value) != 0) {
      ge_set_err_git(e, "config set");
      rc = -1;
    }
  } else if (strcmp(action, "get") == 0) {
    /* Live config requires get_string_buf (get_string is snapshot-only). */
    git_buf buf = GIT_BUF_INIT;
    if (!key[0]) {
      ge_set_err(e, "config get: key required");
      rc = -1;
    } else if (git_config_get_string_buf(&buf, cfg, key) != 0) {
      ge_set_err_git(e, "config get");
      rc = -1;
    } else {
      snprintf(out, out_cap, "%s\n", buf.ptr ? buf.ptr : "");
    }
    git_buf_dispose(&buf);
  } else if (strcmp(action, "list") == 0) {
    /* Minimal: not iterating full config — report common keys if set. */
    out[0] = '\0';
    const char *keys[] = {
        "user.name",
        "user.email",
        "core.bare",
        "remote.origin.url",
        "branch.main.remote",
        "branch.main.merge",
        NULL,
    };
    size_t used = 0;
    for (int i = 0; keys[i]; i++) {
      git_buf buf = GIT_BUF_INIT;
      if (git_config_get_string_buf(&buf, cfg, keys[i]) == 0 && buf.ptr)
        used += (size_t)snprintf(out + used, out_cap - used, "%s=%s\n", keys[i], buf.ptr);
      git_buf_dispose(&buf);
    }
  } else {
    ge_set_err(e, "config: action get|set|list");
    rc = -1;
  }
  git_config_free(cfg);
  return rc;
}

int op_remote(ge_engine *e, const char *args, char *out, size_t out_cap) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char action[32] = "list";
  char name[128] = "";
  char url[1024] = "";
  (void)jmin_get_string(args, "action", action, sizeof(action));
  (void)jmin_get_string(args, "name", name, sizeof(name));
  (void)jmin_get_string(args, "url", url, sizeof(url));

  if (strcmp(action, "list") == 0 || !action[0]) {
    git_strarray list = {0};
    if (git_remote_list(&list, e->repo) != 0) {
      ge_set_err_git(e, "remote list");
      return -1;
    }
    out[0] = '\0';
    size_t used = 0;
    for (size_t i = 0; i < list.count; i++) {
      git_remote *r = NULL;
      if (git_remote_lookup(&r, e->repo, list.strings[i]) == 0) {
        const char *u = git_remote_url(r);
        used += (size_t)snprintf(out + used, out_cap - used, "%s\t%s\n", list.strings[i],
                                 u ? u : "");
        git_remote_free(r);
      }
    }
    git_strarray_dispose(&list);
    return 0;
  }
  if (strcmp(action, "add") == 0) {
    if (!name[0] || !url[0]) {
      ge_set_err(e, "remote add: name and url required");
      return -1;
    }
    git_remote *r = NULL;
    if (git_remote_create(&r, e->repo, name, url) != 0) {
      ge_set_err_git(e, "remote add");
      return -1;
    }
    git_remote_free(r);
    return 0;
  }
  if (strcmp(action, "remove") == 0) {
    if (!name[0]) {
      ge_set_err(e, "remote remove: name required");
      return -1;
    }
    if (git_remote_delete(e->repo, name) != 0) {
      ge_set_err_git(e, "remote remove");
      return -1;
    }
    return 0;
  }
  ge_set_err(e, "remote: action list|add|remove");
  return -1;
}

int op_branch_delete(ge_engine *e, const char *name) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  if (!name || !*name) {
    ge_set_err(e, "branch delete: name required");
    return -1;
  }
  git_reference *ref = NULL;
  if (git_branch_lookup(&ref, e->repo, name, GIT_BRANCH_LOCAL) != 0) {
    ge_set_err_git(e, "branch delete: lookup");
    return -1;
  }
  int rc = git_branch_delete(ref);
  git_reference_free(ref);
  if (rc != 0) {
    ge_set_err_git(e, "branch delete");
    return -1;
  }
  return 0;
}

/* ── Host-mediated remotes (tips / push helpers; no network dial) ─────────── */

/* Escape a string into JSON string content (no surrounding quotes). */
static size_t json_escape_into(char *dst, size_t cap, const char *src) {
  size_t o = 0;
  if (!src)
    src = "";
  for (const unsigned char *p = (const unsigned char *)src; *p && o + 2 < cap; p++) {
    if (*p == '"' || *p == '\\') {
      if (o + 3 >= cap)
        break;
      dst[o++] = '\\';
      dst[o++] = (char)*p;
    } else if (*p < 0x20) {
      /* skip control chars in ref names */
      continue;
    } else {
      dst[o++] = (char)*p;
    }
  }
  if (o < cap)
    dst[o] = 0;
  return o;
}

/* List local tips for fetch have[]: result JSON array of {name,hash}. */
int op_tips(ge_engine *e, char *result_json, size_t cap) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  git_reference_iterator *it = NULL;
  if (git_reference_iterator_new(&it, e->repo) != 0) {
    ge_set_err_git(e, "tips");
    return -1;
  }
  size_t used = 0;
  used += (size_t)snprintf(result_json + used, cap - used, "[");
  int first = 1;
  git_reference *ref = NULL;
  while (git_reference_next(&ref, it) == 0) {
    if (git_reference_type(ref) == GIT_REFERENCE_DIRECT) {
      char hex[GIT_OID_HEXSZ + 1];
      char ename[512];
      git_oid_tostr(hex, sizeof(hex), git_reference_target(ref));
      const char *name = git_reference_name(ref);
      json_escape_into(ename, sizeof(ename), name ? name : "");
      used += (size_t)snprintf(result_json + used, cap > used ? cap - used : 0,
                               "%s{\"name\":\"%s\",\"hash\":\"%s\"}", first ? "" : ",",
                               ename, hex);
      first = 0;
    }
    git_reference_free(ref);
  }
  git_reference_iterator_free(it);
  snprintf(result_json + used, cap > used ? cap - used : 0, "]");
  return 0;
}

int op_push_prepare(ge_engine *e, char *result_json, size_t cap) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char tips[8192];
  if (op_tips(e, tips, sizeof(tips)) != 0)
    return -1;
  snprintf(result_json, cap,
           "{\"commands\":%s,\"note\":\"host builds pack from missing objects\"}", tips);
  return 0;
}

int op_push_complete(ge_engine *e, const char *args) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  int ok = 1;
  (void)jmin_get_bool(args, "ok", &ok);
  if (!ok) {
    ge_set_err(e, "push.complete: remote rejected");
    return -1;
  }
  /* Optional: update remote-tracking from args.remote_name + hash */
  char remote[128] = "origin";
  char branch[128] = "master";
  char hash[64] = "";
  (void)jmin_get_string(args, "remote", remote, sizeof(remote));
  (void)jmin_get_string(args, "branch", branch, sizeof(branch));
  (void)jmin_get_string(args, "hash", hash, sizeof(hash));
  if (hash[0]) {
    char ref[320];
    snprintf(ref, sizeof(ref), "refs/remotes/%s/%s", remote, branch);
    git_oid oid;
    /* Skip all-zero (delete-ref push): no remote-tracking update to null. */
    if (git_oid_fromstr(&oid, hash) == 0 && !git_oid_is_zero(&oid)) {
      git_reference *r = NULL;
      git_reference_create(&r, e->repo, ref, &oid, 1, "push.complete");
      if (r)
        git_reference_free(r);
    }
  }
  return 0;
}

/* ── Sparse cone: worktree prune + sparse-set / sparse-disable ──────────────
 *
 * libgit2 does not fully apply sparse-checkout rules on checkout_tree
 * (out-of-cone paths can remain on disk). After writing sparse-checkout and a
 * force checkout, prune so only cone prefixes (+ root-level files) stay.
 * Cone-only: prefix list + basic !negation at write time — not full git sparse
 * language.
 */

/* Return 1 if relative worktree path should remain under cone prefixes.
 * Root-level files always kept (/*). Intermediate dirs for nested cones kept. */
static int cone_path_kept(const char *rel, int is_dir, char cones[][256], size_t ncones) {
  if (!rel || !*rel)
    return 1;
  /* Root-level files only (not directories): cone template /*. */
  if (!is_dir && strchr(rel, '/') == NULL)
    return 1;
  for (size_t i = 0; i < ncones; i++) {
    const char *c = cones[i];
    size_t cl = strlen(c);
    size_t rl = strlen(rel);
    if (cl == 0)
      continue;
    if (strcmp(rel, c) == 0)
      return 1;
    /* path under cone: cone/… */
    if (rl > cl && rel[cl] == '/' && strncmp(rel, c, cl) == 0)
      return 1;
    /* intermediate directory for nested cone: packages when cone is packages/app */
    if (is_dir && cl > rl && c[rl] == '/' && strncmp(c, rel, rl) == 0)
      return 1;
  }
  return 0;
}

/* Recursive rm -rf for a path under the worktree (best-effort).
 * Use stat (not lstat) for emscripten MEMFS portability. */
static void cone_rm_rf(const char *abs) {
  struct stat st;
  if (stat(abs, &st) != 0)
    return;
  if (S_ISDIR(st.st_mode)) {
    DIR *d = opendir(abs);
    if (d) {
      struct dirent *de;
      while ((de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
          continue;
        char child[4096];
        size_t n = (size_t)snprintf(child, sizeof(child), "%s/%s", abs, de->d_name);
        if (n >= sizeof(child))
          continue;
        cone_rm_rf(child);
      }
      closedir(d);
    }
    rmdir(abs);
  } else {
    unlink(abs);
  }
}

/* Depth-first prune: remove worktree paths not kept by cone. Never enters .git.
 * Portable across host FS and emscripten MEMFS (stat + dirent). */
static void cone_prune_walk(const char *root, const char *rel, char cones[][256], size_t ncones) {
  char abs[4096];
  if (rel && *rel)
    ge_join_path(abs, sizeof(abs), root, rel);
  else {
    size_t n = (size_t)snprintf(abs, sizeof(abs), "%s", root);
    if (n >= sizeof(abs))
      return;
  }
  DIR *d = opendir(abs);
  if (!d)
    return;
  struct dirent *de;
  while ((de = readdir(d)) != NULL) {
    if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
      continue;
    /* Never touch .git (or anything under it). */
    if ((!rel || !*rel) && strcmp(de->d_name, ".git") == 0)
      continue;
    char child_rel[1024];
    if (rel && *rel)
      snprintf(child_rel, sizeof(child_rel), "%s/%s", rel, de->d_name);
    else
      snprintf(child_rel, sizeof(child_rel), "%s", de->d_name);
    if (!ge_safe_relpath(child_rel))
      continue;
    char child_abs[4096];
    ge_join_path(child_abs, sizeof(child_abs), root, child_rel);
    struct stat st;
    if (stat(child_abs, &st) != 0)
      continue;
    int is_dir = S_ISDIR(st.st_mode);
    if (cone_path_kept(child_rel, is_dir, cones, ncones)) {
      if (is_dir)
        cone_prune_walk(root, child_rel, cones, ncones);
    } else {
      cone_rm_rf(child_abs);
    }
  }
  closedir(d);
}

/* sparse-set: write cone patterns, enable core.sparseCheckout, re-checkout HEAD,
 * then prune out-of-cone worktree paths.
 *
 * Args:
 *   patterns — newline-separated string, or JSON string array
 *   path     — single include prefix (fallback if patterns omitted)
 *
 * Basic negation: `!path` → `!/path/` lines. Unsafe relpaths fail closed.
 * Not full git sparse language.
 */
int op_sparse_set(ge_engine *e, const char *args) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char patterns[4096] = "";
  const char *arr = args ? jmin_get_array(args, "patterns") : NULL;
  if (arr) {
    /* JSON array of pattern strings → newline-joined buffer. */
    const char *cur = arr;
    char item[512];
    size_t used = 0;
    patterns[0] = '\0';
    while (jmin_array_next_string(&cur, item, sizeof(item)) == 0) {
      size_t il = strlen(item);
      if (il == 0)
        continue;
      if (used + il + 2 >= sizeof(patterns)) {
        ge_set_err(e, "sparse-set: patterns too long");
        return -1;
      }
      if (used)
        patterns[used++] = '\n';
      memcpy(patterns + used, item, il);
      used += il;
      patterns[used] = '\0';
    }
    if (!patterns[0]) {
      ge_set_err(e, "sparse-set: need patterns or path");
      return -1;
    }
  } else if (jmin_get_string(args, "patterns", patterns, sizeof(patterns)) != 0 &&
             jmin_get_string(args, "path", patterns, sizeof(patterns)) != 0) {
    ge_set_err(e, "sparse-set: need patterns or path");
    return -1;
  }
  char info[4096], sc[4096];
  snprintf(info, sizeof(info), "%s/.git/info", e->root);
  mkdir(info, 0755);
  snprintf(sc, sizeof(sc), "%s/sparse-checkout", info);
  FILE *f = fopen(sc, "wb");
  if (!f) {
    ge_set_err(e, "sparse-set: cannot write sparse-checkout");
    return -1;
  }
  /* Cone header: include root files, exclude other top-level dirs by default. */
  fprintf(f, "/*\n!/*/\n");
  /* Collect include prefixes for worktree prune; write sparse-checkout lines. */
  char cones[64][256];
  size_t ncones = 0;
  /* patterns: newline-separated; optional leading '!' for negation; safe relpath only. */
  for (char *p = patterns, *n; p && *p; p = n) {
    n = strchr(p, '\n');
    if (n)
      *n++ = 0;
    while (*p == ' ' || *p == '\t')
      p++;
    if (!*p)
      continue;
    int negate = 0;
    if (*p == '!') {
      negate = 1;
      p++;
      while (*p == ' ' || *p == '\t')
        p++;
    }
    while (*p == '/')
      p++;
    /* Strip trailing slash for safety check. */
    size_t plen = strlen(p);
    while (plen > 0 && (p[plen - 1] == '/' || p[plen - 1] == ' ' || p[plen - 1] == '\t')) {
      p[--plen] = '\0';
    }
    if (!*p || !ge_safe_relpath(p)) {
      fclose(f);
      unlink(sc);
      ge_set_err(e, "sparse-set: unsafe pattern");
      return -1;
    }
    if (negate) {
      fprintf(f, "!/%s/\n!/%s/**\n", p, p);
      /* Drop matching include if present (basic !negation after include). */
      for (size_t i = 0; i < ncones; i++) {
        if (strcmp(cones[i], p) == 0) {
          if (i + 1 < ncones)
            memmove(cones[i], cones[i + 1], (ncones - i - 1) * sizeof(cones[0]));
          ncones--;
          break;
        }
      }
    } else {
      fprintf(f, "/%s/\n/%s/**\n", p, p);
      if (ncones < 64 && plen < sizeof(cones[0])) {
        memcpy(cones[ncones], p, plen + 1);
        ncones++;
      }
    }
  }
  fclose(f);

  git_config *cfg = NULL;
  if (git_repository_config(&cfg, e->repo) != 0) {
    ge_set_err_git(e, "sparse-set: config");
    return -1;
  }
  git_config_set_bool(cfg, "core.sparseCheckout", 1);
  /* Best-effort cone flag for future git CLI interop (libgit2 may ignore). */
  git_config_set_bool(cfg, "core.sparseCheckoutCone", 1);
  git_config_free(cfg);

  /* Re-checkout HEAD (restores in-cone; does not remove out-of-cone on libgit2). */
  git_object *treeish = NULL;
  if (git_revparse_single(&treeish, e->repo, "HEAD") == 0) {
    git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
    opts.checkout_strategy = GIT_CHECKOUT_FORCE;
    git_checkout_tree(e->repo, treeish, &opts);
    git_object_free(treeish);
  }

  /* Materialize cone on disk — prune out-of-cone worktree paths. */
  if (ncones > 0)
    cone_prune_walk(e->root, "", cones, ncones);
  return 0;
}

int op_sparse_disable(ge_engine *e, const char *args) {
  (void)args;
  if (ge_ensure_repo(e) != 0)
    return -1;
  git_config *cfg = NULL;
  if (git_repository_config(&cfg, e->repo) == 0) {
    git_config_set_bool(cfg, "core.sparseCheckout", 0);
    git_config_free(cfg);
  }
  char sc[4096];
  snprintf(sc, sizeof(sc), "%s/.git/info/sparse-checkout", e->root);
  unlink(sc);
  git_object *treeish = NULL;
  if (git_revparse_single(&treeish, e->repo, "HEAD") == 0) {
    git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
    opts.checkout_strategy = GIT_CHECKOUT_FORCE;
    git_checkout_tree(e->repo, treeish, &opts);
    git_object_free(treeish);
  }
  return 0;
}

/* ── Submodules: list (.gitmodules) + local gitlink stage ───────────────────
 * List/status only on the engine. Network update/clone is host_call + orch.
 */

/* Minimal JSON string escape for submodule list (no control chars; skip them). */
static void ge_json_escape_str(const char *in, char *out, size_t cap) {
  size_t o = 0;
  if (!in)
    in = "";
  for (const unsigned char *p = (const unsigned char *)in; *p; p++) {
    if (o + 2 >= cap)
      break;
    if (*p == '"' || *p == '\\') {
      if (o + 3 >= cap)
        break;
      out[o++] = '\\';
      out[o++] = (char)*p;
    } else if (*p < 0x20) {
      continue;
    } else {
      out[o++] = (char)*p;
    }
  }
  if (o >= cap)
    o = cap - 1;
  out[o] = '\0';
}

/* Resolve gitlink (mode 160000) OID from the superproject index, if present. */
static void ge_submodule_gitlink_hash(ge_engine *e, const char *path, char *hash_out,
                                      size_t hash_cap) {
  if (hash_out && hash_cap)
    hash_out[0] = '\0';
  if (!e || !e->repo || !path || !path[0] || !hash_out || hash_cap < 41)
    return;
  git_index *index = NULL;
  if (git_repository_index(&index, e->repo) != 0)
    return;
  const git_index_entry *ent = git_index_get_bypath(index, path, 0);
  if (ent && (ent->mode == GIT_FILEMODE_COMMIT || ent->mode == 0160000)) {
    git_oid_tostr(hash_out, hash_cap, &ent->id);
  }
  git_index_free(index);
}

static int ge_submodule_append_entry(char **outp, size_t *usedp, size_t *capp, int *firstp,
                                     const char *name, const char *path, const char *url,
                                     const char *hash) {
  char esc_name[512], esc_path[1024], esc_url[2048];
  ge_json_escape_str(name, esc_name, sizeof(esc_name));
  ge_json_escape_str(path ? path : "", esc_path, sizeof(esc_path));
  ge_json_escape_str(url ? url : "", esc_url, sizeof(esc_url));
  char item[4200];
  int w;
  if (hash && hash[0] && strlen(hash) == 40) {
    w = snprintf(item, sizeof(item),
                 "%s{\"name\":\"%s\",\"path\":\"%s\",\"url\":\"%s\",\"hash\":\"%s\"}",
                 *firstp ? "" : ",", esc_name, esc_path, esc_url, hash);
  } else {
    w = snprintf(item, sizeof(item), "%s{\"name\":\"%s\",\"path\":\"%s\",\"url\":\"%s\"}",
                 *firstp ? "" : ",", esc_name, esc_path, esc_url);
  }
  if (w < 0 || (size_t)w >= sizeof(item))
    return -1;
  if (*usedp + (size_t)w + 2 >= *capp) {
    size_t ncap = *capp * 2;
    while (*usedp + (size_t)w + 2 >= ncap)
      ncap *= 2;
    char *p = (char *)realloc(*outp, ncap);
    if (!p)
      return -1;
    *outp = p;
    *capp = ncap;
  }
  memcpy(*outp + *usedp, item, (size_t)w);
  *usedp += (size_t)w;
  (*outp)[*usedp] = '\0';
  *firstp = 0;
  return 0;
}

/* Parse worktree `.gitmodules` (no network). Includes gitlink hash from the
 * superproject index when present (mode 160000). */
int op_submodule_list(ge_engine *e, char **out_owned) {
  if (out_owned)
    *out_owned = NULL;
  if (ge_ensure_repo(e) != 0)
    return -1;

  char path[4096];
  snprintf(path, sizeof(path), "%s/.gitmodules", e->root);
  FILE *f = fopen(path, "rb");
  if (!f) {
    /* No file → empty list (ok), not an error. */
    char *empty = (char *)malloc(3);
    if (!empty) {
      ge_set_err(e, "submodule: out of memory");
      return -1;
    }
    empty[0] = '[';
    empty[1] = ']';
    empty[2] = '\0';
    if (out_owned)
      *out_owned = empty;
    else
      free(empty);
    return 0;
  }

  /* Bound parse — product repos should not ship multi-MiB .gitmodules. */
  char raw[65536];
  size_t n = fread(raw, 1, sizeof(raw) - 1, f);
  fclose(f);
  if (n >= sizeof(raw) - 1) {
    ge_set_err(e, "submodule: .gitmodules too large");
    return -1;
  }
  raw[n] = '\0';

  size_t cap = 8192;
  char *out = (char *)malloc(cap);
  if (!out) {
    ge_set_err(e, "submodule: out of memory");
    return -1;
  }
  size_t used = 0;
  out[used++] = '[';
  out[used] = '\0';
  int first = 1;

  char cur_name[256] = "";
  char cur_path[512] = "";
  char cur_url[1024] = "";
  int in_sub = 0;

  char *line = raw;
  while (line && *line) {
    char *nl = strchr(line, '\n');
    if (nl)
      *nl = '\0';
    size_t llen = strlen(line);
    if (llen > 0 && line[llen - 1] == '\r')
      line[--llen] = '\0';

    while (*line == ' ' || *line == '\t')
      line++;

    if (line[0] == '#' || line[0] == ';' || line[0] == '\0') {
      /* comment / blank */
    } else if (line[0] == '[') {
      if (in_sub && cur_name[0]) {
        char gl[48] = "";
        if (cur_path[0])
          ge_submodule_gitlink_hash(e, cur_path, gl, sizeof(gl));
        if (ge_submodule_append_entry(&out, &used, &cap, &first, cur_name, cur_path, cur_url,
                                      gl[0] ? gl : NULL) != 0) {
          free(out);
          ge_set_err(e, "submodule: out of memory");
          return -1;
        }
      }
      cur_name[0] = cur_path[0] = cur_url[0] = '\0';
      in_sub = 0;
      if (strncmp(line, "[submodule ", 11) == 0) {
        const char *q1 = strchr(line, '"');
        if (q1) {
          q1++;
          const char *q2 = strchr(q1, '"');
          if (q2 && (size_t)(q2 - q1) < sizeof(cur_name)) {
            memcpy(cur_name, q1, (size_t)(q2 - q1));
            cur_name[q2 - q1] = '\0';
            in_sub = 1;
          }
        }
      }
    } else if (in_sub) {
      char *eq = strchr(line, '=');
      if (eq) {
        *eq = '\0';
        char *key = line;
        char *val = eq + 1;
        size_t kl = strlen(key);
        while (kl > 0 && (key[kl - 1] == ' ' || key[kl - 1] == '\t'))
          key[--kl] = '\0';
        while (*val == ' ' || *val == '\t')
          val++;
        if (strcmp(key, "path") == 0)
          snprintf(cur_path, sizeof(cur_path), "%s", val);
        else if (strcmp(key, "url") == 0)
          snprintf(cur_url, sizeof(cur_url), "%s", val);
      }
    }

    if (!nl)
      break;
    line = nl + 1;
  }

  if (in_sub && cur_name[0]) {
    char gl[48] = "";
    if (cur_path[0])
      ge_submodule_gitlink_hash(e, cur_path, gl, sizeof(gl));
    if (ge_submodule_append_entry(&out, &used, &cap, &first, cur_name, cur_path, cur_url,
                                  gl[0] ? gl : NULL) != 0) {
      free(out);
      ge_set_err(e, "submodule: out of memory");
      return -1;
    }
  }

  if (used + 2 >= cap) {
    char *p = (char *)realloc(out, used + 4);
    if (!p) {
      free(out);
      ge_set_err(e, "submodule: out of memory");
      return -1;
    }
    out = p;
  }
  out[used++] = ']';
  out[used] = '\0';

  if (out_owned)
    *out_owned = out;
  else
    free(out);
  return 0;
}

/* Local-only: stage a gitlink (mode 160000) at path → hash. No network.
 * Used by fixtures / superproject setup; does not clone submodule content. */
int op_gitlink(ge_engine *e, const char *args) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  char path[1024] = "";
  char hash[64] = "";
  if (jmin_get_string(args, "path", path, sizeof(path)) != 0 || !ge_safe_relpath(path)) {
    ge_set_err(e, "gitlink: bad path");
    return -1;
  }
  if (jmin_get_string(args, "hash", hash, sizeof(hash)) != 0 || strlen(hash) != 40) {
    ge_set_err(e, "gitlink: need 40-hex hash");
    return -1;
  }
  for (char *p = hash; *p; p++) {
    if (*p >= 'A' && *p <= 'F')
      *p = (char)(*p - 'A' + 'a');
    else if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f'))) {
      ge_set_err(e, "gitlink: bad hash");
      return -1;
    }
  }
  git_oid oid;
  if (git_oid_fromstr(&oid, hash) != 0) {
    ge_set_err(e, "gitlink: bad hash");
    return -1;
  }
  git_index *index = NULL;
  if (git_repository_index(&index, e->repo) != 0) {
    ge_set_err_git(e, "gitlink: index");
    return -1;
  }
  git_index_entry entry;
  memset(&entry, 0, sizeof(entry));
  entry.path = path;
  entry.mode = GIT_FILEMODE_COMMIT;
  git_oid_cpy(&entry.id, &oid);
  if (git_index_add(index, &entry) != 0) {
    git_index_free(index);
    ge_set_err_git(e, "gitlink: index_add");
    return -1;
  }
  if (git_index_write(index) != 0) {
    git_index_free(index);
    ge_set_err_git(e, "gitlink: index_write");
    return -1;
  }
  git_index_free(index);
  return 0;
}
