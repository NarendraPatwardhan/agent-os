/* Additional Run ops for GIT_DESIGN phase A + apply helpers. */
#include "json_min.h"
#include "git2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Shared with engine.c via external linkage of helpers we re-declare. */
typedef struct ge_engine {
  char root[4096];
  git_repository *repo;
  char err[512];
  git_indexer *indexer;
  git_odb *odb;
  git_indexer_progress progress;
} ge_engine;

void ge_set_err(ge_engine *e, const char *msg);
void ge_set_err_git(ge_engine *e, const char *prefix);
int ge_ensure_repo(ge_engine *e);
int ge_safe_relpath(const char *path);
void ge_join_path(char *out, size_t cap, const char *root, const char *rel);

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

int op_diff(ge_engine *e, char *out, size_t out_cap) {
  if (ge_ensure_repo(e) != 0)
    return -1;
  git_diff *diff = NULL;
  git_diff_options opts = GIT_DIFF_OPTIONS_INIT;
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
  snprintf(out, out_cap, "%s", buf.ptr ? buf.ptr : "");
  git_buf_dispose(&buf);
  git_diff_free(diff);
  return 0;
}

int op_show(ge_engine *e, const char *args, char *out, size_t out_cap) {
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
  snprintf(out, out_cap, "commit %s\nAuthor: %s <%s>\n\n%s\n", hex,
           a ? a->name : "?", a ? a->email : "?", msg ? msg : "");
  git_object_free(obj);
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
  if (strcmp(mode, "soft") == 0)
    t = GIT_RESET_SOFT;
  else if (strcmp(mode, "hard") == 0)
    t = GIT_RESET_HARD;
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
      git_oid_tostr(hex, sizeof(hex), git_reference_target(ref));
      const char *name = git_reference_name(ref);
      used += (size_t)snprintf(result_json + used, cap - used,
                               "%s{\"name\":\"%s\",\"hash\":\"%s\"}", first ? "" : ",",
                               name ? name : "", hex);
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
