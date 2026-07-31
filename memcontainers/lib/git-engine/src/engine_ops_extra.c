/* Additional Run ops for GIT_DESIGN phase A + apply helpers. */
#include "git_engine.h"
#include "ge_engine_priv.h"
#include "json_min.h"

#include "git2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

/* *out_owned is malloc'd on success; caller frees. Full unified patch via
 * libgit2 (GIT_DIFF_FORMAT_PATCH). Optional args.path filters to one path. */
int op_diff(ge_engine *e, const char *args, char **out_owned) {
  if (out_owned)
    *out_owned = NULL;
  if (ge_ensure_repo(e) != 0)
    return -1;
  git_diff *diff = NULL;
  git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
  char path[1024] = "";
  char *pathspec_strs[1];
  if (args && jmin_get_string(args, "path", path, sizeof(path)) == 0 && path[0]) {
    if (!ge_safe_relpath(path)) {
      ge_set_err(e, "diff: bad path");
      return -1;
    }
    pathspec_strs[0] = path;
    opts.pathspec.strings = pathspec_strs;
    opts.pathspec.count = 1;
  }
  if (git_diff_index_to_workdir(&diff, e->repo, NULL, &opts) != 0) {
    ge_set_err_git(e, "diff");
    return -1;
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

/* *out_owned is malloc'd on success; caller frees. Never truncates. */
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
    const char *v = NULL;
    if (!key[0]) {
      ge_set_err(e, "config get: key required");
      rc = -1;
    } else if (git_config_get_string(&v, cfg, key) != 0) {
      ge_set_err_git(e, "config get");
      rc = -1;
    } else {
      snprintf(out, out_cap, "%s\n", v ? v : "");
    }
  } else if (strcmp(action, "list") == 0) {
    /* Minimal: not iterating full config — report common keys if set. */
    out[0] = '\0';
    const char *keys[] = {"user.name", "user.email", "core.bare", NULL};
    size_t used = 0;
    for (int i = 0; keys[i]; i++) {
      const char *v = NULL;
      if (git_config_get_string(&v, cfg, keys[i]) == 0 && v)
        used += (size_t)snprintf(out + used, out_cap - used, "%s=%s\n", keys[i], v);
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
    if (git_oid_fromstr(&oid, hash) == 0) {
      git_reference *r = NULL;
      git_reference_create(&r, e->repo, ref, &oid, 1, "push.complete");
      if (r)
        git_reference_free(r);
    }
  }
  return 0;
}

/* PR14 / R59: sparse-checkout cone projection.
 * patterns: string (newline-separated), JSON string array, or single path key.
 * Basic negation lines: `!path` → written as !/path/ (still not full git sparse language).
 * Unsafe paths fail closed. */
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
    if (negate)
      fprintf(f, "!/%s/\n!/%s/**\n", p, p);
    else
      fprintf(f, "/%s/\n/%s/**\n", p, p);
  }
  fclose(f);

  git_config *cfg = NULL;
  if (git_repository_config(&cfg, e->repo) != 0) {
    ge_set_err_git(e, "sparse-set: config");
    return -1;
  }
  git_config_set_bool(cfg, "core.sparseCheckout", 1);
  git_config_free(cfg);

  /* Re-checkout HEAD into cone */
  git_object *treeish = NULL;
  if (git_revparse_single(&treeish, e->repo, "HEAD") == 0) {
    git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
    opts.checkout_strategy = GIT_CHECKOUT_FORCE;
    git_checkout_tree(e->repo, treeish, &opts);
    git_object_free(treeish);
  }
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
