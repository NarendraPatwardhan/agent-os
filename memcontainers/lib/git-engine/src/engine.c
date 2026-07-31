/* Host git engine: Run ABI over libgit2 (AgentOS spike substrate). */

#include "git_engine.h"
#include "json_min.h"

#include "git2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#define GE_VERSION "agentos-git-engine/0.1.0+libgit2-1.9.2"

struct ge_engine {
  char root[4096];
  git_repository *repo;
  char err[512];
  /* Streaming pack indexer (network-free apply path). */
  git_indexer *indexer;
  git_odb *odb;
  git_indexer_progress progress;
};

void ge_set_err(ge_engine *e, const char *msg) {
  if (!e)
    return;
  snprintf(e->err, sizeof(e->err), "%s", msg ? msg : "error");
}

void ge_set_err_git(ge_engine *e, const char *prefix) {
  const git_error *ge = git_error_last();
  if (ge && ge->message)
    snprintf(e->err, sizeof(e->err), "%s: %s", prefix, ge->message);
  else
    ge_set_err(e, prefix);
}

int ge_safe_relpath(const char *path) {
  if (!path || !*path)
    return 0;
  if (path[0] == '/')
    return 0;
  if (strstr(path, "..") != NULL)
    return 0;
  return 1;
}

void ge_join_path(char *out, size_t cap, const char *root, const char *rel) {
  snprintf(out, cap, "%s/%s", root, rel);
}

#define set_err ge_set_err
#define set_err_git ge_set_err_git
#define safe_relpath ge_safe_relpath
#define join_path ge_join_path

static char *resp_ok(const char *stdout_s, const char *result_json) {
  return jmin_response(1, 0, stdout_s, "", result_json);
}

static char *resp_err(int code, const char *stderr_s) {
  return jmin_response(0, code, "", stderr_s, NULL);
}

static char *resp_usage(const char *msg) {
  return resp_err(2, msg);
}

const char *ge_version(void) { return GE_VERSION; }

const char *ge_worktree_root(const ge_engine *e) {
  return e ? e->root : NULL;
}

const char *ge_last_error(const ge_engine *e) {
  return e ? e->err : "null engine";
}

void ge_free(void *p) {
  free(p);
}

ge_engine *ge_open(const char *worktree_root) {
  if (!worktree_root || !*worktree_root)
    return NULL;
  /* Product contract (GIT.md): absolute path to an existing directory. */
  if (worktree_root[0] != '/')
    return NULL;
  {
    struct stat st;
    if (stat(worktree_root, &st) != 0 || !S_ISDIR(st.st_mode))
      return NULL;
  }
  ge_engine *e = (ge_engine *)calloc(1, sizeof(*e));
  if (!e)
    return NULL;
  snprintf(e->root, sizeof(e->root), "%s", worktree_root);
  /* Drop trailing slash */
  size_t n = strlen(e->root);
  while (n > 1 && e->root[n - 1] == '/') {
    e->root[--n] = '\0';
  }
  git_libgit2_init();
  /* Open existing repo if present. */
  if (git_repository_open_ext(&e->repo, e->root, 0, NULL) != 0)
    e->repo = NULL;
  return e;
}

void ge_close(ge_engine *e) {
  if (!e)
    return;
  if (e->indexer) {
    git_indexer_free(e->indexer);
    e->indexer = NULL;
  }
  if (e->odb) {
    git_odb_free(e->odb);
    e->odb = NULL;
  }
  if (e->repo) {
    git_repository_free(e->repo);
    e->repo = NULL;
  }
  /* Do not git_libgit2_shutdown here — process-global; multi-session hosts
   * may open/close engines. Process exit tears down. */
  free(e);
}

int ge_ensure_repo(ge_engine *e) {
  if (e->repo)
    return 0;
  set_err(e, "no repository (run op init first)");
  return -1;
}

#define ensure_repo ge_ensure_repo

/* From engine_ops_extra.c */
int op_rm(ge_engine *e, const char *args);
int op_diff(ge_engine *e, char *out, size_t out_cap);
int op_show(ge_engine *e, const char *args, char *out, size_t out_cap);
int op_reset(ge_engine *e, const char *args);
int op_tag(ge_engine *e, const char *args);
int op_config(ge_engine *e, const char *args, char *out, size_t out_cap);
int op_remote(ge_engine *e, const char *args, char *out, size_t out_cap);
int op_branch_delete(ge_engine *e, const char *name);
int op_tips(ge_engine *e, char *result_json, size_t cap);
int op_push_prepare(ge_engine *e, char *result_json, size_t cap);
int op_push_complete(ge_engine *e, const char *args);
int op_sparse_set(ge_engine *e, const char *args);
int op_sparse_disable(ge_engine *e, const char *args);

static int op_init(ge_engine *e) {
  if (e->repo) {
    set_err(e, "repository already open");
    return -1;
  }
  if (git_repository_init(&e->repo, e->root, 0) != 0) {
    set_err_git(e, "init");
    return -1;
  }
  return 0;
}

static int op_write(ge_engine *e, const char *args) {
  char path[1024];
  char content[65536];
  if (jmin_get_string(args, "path", path, sizeof(path)) != 0 || !safe_relpath(path)) {
    set_err(e, "write: bad path");
    return -1;
  }
  if (jmin_get_string(args, "content", content, sizeof(content)) != 0) {
    set_err(e, "write: missing content");
    return -1;
  }
  char full[4096];
  join_path(full, sizeof(full), e->root, path);
  /* mkdir -p parent (one level only for spike; multi-level loop) */
  char *slash = strrchr(full, '/');
  if (slash && slash != full) {
    *slash = '\0';
    /* create nested dirs roughly */
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s", full);
    for (char *p = tmp + 1; *p; p++) {
      if (*p == '/') {
        *p = '\0';
        mkdir(tmp, 0755);
        *p = '/';
      }
    }
    mkdir(tmp, 0755);
    *slash = '/';
  }
  FILE *f = fopen(full, "wb");
  if (!f) {
    set_err(e, "write: open failed");
    return -1;
  }
  size_t n = strlen(content);
  if (fwrite(content, 1, n, f) != n) {
    fclose(f);
    set_err(e, "write: short write");
    return -1;
  }
  fclose(f);
  return 0;
}

/* Stage one worktree file without git_index_add_bypath (avoids ignore/PCRE
 * paths that crash under some Wasm builds). */
static int index_add_file(ge_engine *e, git_index *index, const char *rel) {
  if (!safe_relpath(rel)) {
    set_err(e, "add: bad path");
    return -1;
  }
  char full[4096];
  join_path(full, sizeof(full), e->root, rel);
  FILE *f = fopen(full, "rb");
  if (!f) {
    set_err(e, "add: cannot open file");
    return -1;
  }
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    set_err(e, "add: seek");
    return -1;
  }
  long sz = ftell(f);
  if (sz < 0) {
    fclose(f);
    set_err(e, "add: tell");
    return -1;
  }
  rewind(f);
  char *buf = (char *)malloc((size_t)sz + 1);
  if (!buf) {
    fclose(f);
    set_err(e, "add: oom");
    return -1;
  }
  if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
    free(buf);
    fclose(f);
    set_err(e, "add: read");
    return -1;
  }
  fclose(f);

  git_index_entry entry;
  memset(&entry, 0, sizeof(entry));
  entry.path = rel;
  entry.mode = GIT_FILEMODE_BLOB;
  int rc = git_index_add_from_buffer(index, &entry, buf, (size_t)sz);
  free(buf);
  if (rc != 0) {
    set_err_git(e, "add: from_buffer");
    return -1;
  }
  return 0;
}

static int op_add(ge_engine *e, const char *args) {
  if (ensure_repo(e) != 0)
    return -1;
  char path[1024];
  int all = 0;
  (void)jmin_get_bool(args, "all", &all);
  git_index *index = NULL;
  if (git_repository_index(&index, e->repo) != 0) {
    set_err_git(e, "add: index");
    return -1;
  }
  int rc = 0;
  if (all) {
    /* Simple worktree walk is deferred; require explicit paths on Wasm. */
    set_err(e, "add: all=true not supported in this spike (pass path)");
    rc = -1;
  } else if (jmin_get_string(args, "path", path, sizeof(path)) == 0) {
    rc = index_add_file(e, index, path);
  } else {
    set_err(e, "add: provide path");
    rc = -1;
  }
  if (rc == 0 && git_index_write(index) != 0) {
    set_err_git(e, "add: index write");
    rc = -1;
  }
  git_index_free(index);
  return rc;
}

static int op_commit(ge_engine *e, const char *args, char *hash_out, size_t hash_cap) {
  if (ensure_repo(e) != 0)
    return -1;
  char message[4096];
  char name[256] = "Agent";
  char email[256] = "agent@example.com";
  int64_t when_unix = 0;
  if (jmin_get_string(args, "message", message, sizeof(message)) != 0 || !message[0]) {
    set_err(e, "commit: message required");
    return -1;
  }
  (void)jmin_get_string(args, "name", name, sizeof(name));
  (void)jmin_get_string(args, "email", email, sizeof(email));
  (void)jmin_get_int64(args, "when_unix", &when_unix);

  git_index *index = NULL;
  if (git_repository_index(&index, e->repo) != 0) {
    set_err_git(e, "commit: index");
    return -1;
  }
  git_oid tree_oid;
  if (git_index_write_tree(&tree_oid, index) != 0) {
    git_index_free(index);
    set_err_git(e, "commit: write_tree");
    return -1;
  }
  git_index_free(index);

  git_tree *tree = NULL;
  if (git_tree_lookup(&tree, e->repo, &tree_oid) != 0) {
    set_err_git(e, "commit: tree");
    return -1;
  }

  git_signature *sig = NULL;
  if (when_unix > 0) {
    if (git_signature_new(&sig, name, email, (git_time_t)when_unix, 0) != 0) {
      git_tree_free(tree);
      set_err_git(e, "commit: signature");
      return -1;
    }
  } else if (git_signature_now(&sig, name, email) != 0) {
    git_tree_free(tree);
    set_err_git(e, "commit: signature");
    return -1;
  }

  git_oid parent_oid;
  git_commit *parent = NULL;
  int nparents = 0;
  const git_commit *parents[1];
  if (git_reference_name_to_id(&parent_oid, e->repo, "HEAD") == 0) {
    if (git_commit_lookup(&parent, e->repo, &parent_oid) == 0) {
      parents[0] = parent;
      nparents = 1;
    }
  }

  git_oid commit_oid;
  int crc = git_commit_create(&commit_oid, e->repo, "HEAD", sig, sig, NULL, message, tree,
                              nparents, parents);
  git_signature_free(sig);
  git_tree_free(tree);
  if (parent)
    git_commit_free(parent);
  if (crc != 0) {
    set_err_git(e, "commit");
    return -1;
  }
  git_oid_tostr(hash_out, hash_cap, &commit_oid);
  return 0;
}

static int op_status(ge_engine *e, int short_fmt, char *out, size_t out_cap) {
  if (ensure_repo(e) != 0)
    return -1;
  git_status_list *list = NULL;
  git_status_options opts = GIT_STATUS_OPTIONS_INIT;
  opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
  opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX |
               GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
  if (git_status_list_new(&list, e->repo, &opts) != 0) {
    set_err_git(e, "status");
    return -1;
  }
  size_t n = git_status_list_entrycount(list);
  size_t used = 0;
  out[0] = '\0';
  if (!short_fmt) {
    used += (size_t)snprintf(out + used, out_cap - used, "On branch ");
    const char *branch = NULL;
    git_reference *head = NULL;
    if (git_repository_head(&head, e->repo) == 0) {
      branch = git_reference_shorthand(head);
      used += (size_t)snprintf(out + used, out_cap - used, "%s\n", branch ? branch : "HEAD");
      git_reference_free(head);
    } else {
      used += (size_t)snprintf(out + used, out_cap - used, "(unknown)\n");
    }
  }
  for (size_t i = 0; i < n && used + 8 < out_cap; i++) {
    const git_status_entry *ent = git_status_byindex(list, i);
    const char *path = ent->head_to_index ? ent->head_to_index->new_file.path
                       : ent->index_to_workdir ? ent->index_to_workdir->new_file.path
                                               : "?";
    char xy[3] = {' ', ' ', '\0'};
    if (ent->status & GIT_STATUS_INDEX_NEW)
      xy[0] = 'A';
    else if (ent->status & GIT_STATUS_INDEX_MODIFIED)
      xy[0] = 'M';
    else if (ent->status & GIT_STATUS_INDEX_DELETED)
      xy[0] = 'D';
    if (ent->status & GIT_STATUS_WT_NEW)
      xy[1] = '?';
    else if (ent->status & GIT_STATUS_WT_MODIFIED)
      xy[1] = 'M';
    else if (ent->status & GIT_STATUS_WT_DELETED)
      xy[1] = 'D';
    if (short_fmt)
      used += (size_t)snprintf(out + used, out_cap - used, "%c%c %s\n", xy[0], xy[1], path);
    else
      used += (size_t)snprintf(out + used, out_cap - used, "  %c%c %s\n", xy[0], xy[1], path);
  }
  if (n == 0 && !short_fmt)
    used += (size_t)snprintf(out + used, out_cap - used, "nothing to commit, working tree clean\n");
  git_status_list_free(list);
  (void)used;
  return 0;
}

static int op_log(ge_engine *e, const char *args, char *out, size_t out_cap) {
  if (ensure_repo(e) != 0)
    return -1;
  int64_t max_count = 10;
  (void)jmin_get_int64(args, "max_count", &max_count);
  if (max_count <= 0)
    max_count = 10;

  git_revwalk *walk = NULL;
  if (git_revwalk_new(&walk, e->repo) != 0) {
    set_err_git(e, "log");
    return -1;
  }
  git_revwalk_sorting(walk, GIT_SORT_TIME);
  if (git_revwalk_push_head(walk) != 0) {
    git_revwalk_free(walk);
    set_err_git(e, "log: push_head");
    return -1;
  }
  out[0] = '\0';
  size_t used = 0;
  git_oid oid;
  int64_t count = 0;
  while (count < max_count && git_revwalk_next(&oid, walk) == 0) {
    git_commit *c = NULL;
    if (git_commit_lookup(&c, e->repo, &oid) != 0)
      continue;
    char hex[GIT_OID_HEXSZ + 1];
    git_oid_tostr(hex, sizeof(hex), &oid);
    const char *msg = git_commit_summary(c);
    used += (size_t)snprintf(out + used, out_cap - used, "%s %s\n", hex, msg ? msg : "");
    git_commit_free(c);
    count++;
  }
  git_revwalk_free(walk);
  return 0;
}

static int op_rev_parse(ge_engine *e, const char *args, char *out, size_t out_cap) {
  if (ensure_repo(e) != 0)
    return -1;
  char rev[256] = "HEAD";
  (void)jmin_get_string(args, "rev", rev, sizeof(rev));
  git_object *obj = NULL;
  if (git_revparse_single(&obj, e->repo, rev) != 0) {
    set_err_git(e, "rev-parse");
    return -1;
  }
  git_oid_tostr(out, out_cap, git_object_id(obj));
  git_object_free(obj);
  return 0;
}

static int op_branch_list(ge_engine *e, char *out, size_t out_cap) {
  if (ensure_repo(e) != 0)
    return -1;
  git_branch_iterator *it = NULL;
  if (git_branch_iterator_new(&it, e->repo, GIT_BRANCH_LOCAL) != 0) {
    set_err_git(e, "branch");
    return -1;
  }
  out[0] = '\0';
  size_t used = 0;
  git_reference *ref = NULL;
  git_branch_t t;
  while (git_branch_next(&ref, &t, it) == 0) {
    const char *name = NULL;
    git_branch_name(&name, ref);
    int is_head = git_branch_is_head(ref);
    used += (size_t)snprintf(out + used, out_cap - used, "%s %s\n", is_head ? "*" : " ",
                             name ? name : "?");
    git_reference_free(ref);
  }
  git_branch_iterator_free(it);
  return 0;
}

static int op_branch_create(ge_engine *e, const char *name) {
  if (ensure_repo(e) != 0)
    return -1;
  if (!name || !*name || !safe_relpath(name)) {
    /* branch names aren't paths but reject .. */
    if (!name || !*name || strstr(name, "..")) {
      set_err(e, "branch: bad name");
      return -1;
    }
  }
  git_oid oid;
  if (git_reference_name_to_id(&oid, e->repo, "HEAD") != 0) {
    set_err_git(e, "branch: HEAD");
    return -1;
  }
  git_commit *c = NULL;
  if (git_commit_lookup(&c, e->repo, &oid) != 0) {
    set_err_git(e, "branch: commit");
    return -1;
  }
  git_reference *ref = NULL;
  int rc = git_branch_create(&ref, e->repo, name, c, 0);
  git_commit_free(c);
  if (rc != 0) {
    set_err_git(e, "branch create");
    return -1;
  }
  git_reference_free(ref);
  return 0;
}

static int op_checkout(ge_engine *e, const char *name) {
  if (ensure_repo(e) != 0)
    return -1;
  if (!name || !*name) {
    set_err(e, "checkout: name required");
    return -1;
  }
  git_object *treeish = NULL;
  if (git_revparse_single(&treeish, e->repo, name) != 0) {
    set_err_git(e, "checkout: revparse");
    return -1;
  }
  git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
  opts.checkout_strategy = GIT_CHECKOUT_SAFE;
  if (git_checkout_tree(e->repo, treeish, &opts) != 0) {
    git_object_free(treeish);
    set_err_git(e, "checkout: tree");
    return -1;
  }
  char refname[256];
  snprintf(refname, sizeof(refname), "refs/heads/%s", name);
  if (git_repository_set_head(e->repo, refname) != 0) {
    /* detached ok if name was a commit */
    char hex[GIT_OID_HEXSZ + 1];
    git_oid_tostr(hex, sizeof(hex), git_object_id(treeish));
    git_repository_set_head_detached(e->repo, git_object_id(treeish));
  }
  git_object_free(treeish);
  return 0;
}

/* --- network-free apply path --- */

int ge_import_pack(ge_engine *e, const uint8_t *chunk, size_t len, int final) {
  if (!e) {
    return -1;
  }
  if (ensure_repo(e) != 0)
    return -1;

  if (!e->indexer) {
    if (git_repository_odb(&e->odb, e->repo) != 0) {
      set_err_git(e, "import_pack: odb");
      return -1;
    }
    /* Write into .git/objects via indexer with append_odb */
    char objects[4096];
    snprintf(objects, sizeof(objects), "%s/.git/objects", e->root);
    git_indexer_options iopts = GIT_INDEXER_OPTIONS_INIT;
    if (git_indexer_new(&e->indexer, objects, 0, e->odb, &iopts) != 0) {
      set_err_git(e, "import_pack: indexer");
      return -1;
    }
    memset(&e->progress, 0, sizeof(e->progress));
  }

  if (chunk && len > 0) {
    if (git_indexer_append(e->indexer, chunk, len, &e->progress) != 0) {
      set_err_git(e, "import_pack: append");
      return -1;
    }
  }

  if (final) {
    if (git_indexer_commit(e->indexer, &e->progress) != 0) {
      set_err_git(e, "import_pack: commit");
      return -1;
    }
    git_indexer_free(e->indexer);
    e->indexer = NULL;
  }
  return 0;
}

static int op_refs_import(ge_engine *e, const char *args) {
  if (ensure_repo(e) != 0)
    return -1;
  /* Minimal: { "name": "refs/heads/main", "hash": "..." } single ref.
   * Full array support can be added when fixtures need it. */
  char name[256];
  char hash[64];
  if (jmin_get_string(args, "name", name, sizeof(name)) != 0 ||
      jmin_get_string(args, "hash", hash, sizeof(hash)) != 0) {
    set_err(e, "refs.import: need name and hash");
    return -1;
  }
  git_oid oid;
  if (git_oid_fromstr(&oid, hash) != 0) {
    set_err(e, "refs.import: bad hash");
    return -1;
  }
  git_reference *ref = NULL;
  int rc = git_reference_create(&ref, e->repo, name, &oid, 1, "refs.import");
  if (rc != 0) {
    set_err_git(e, "refs.import");
    return -1;
  }
  git_reference_free(ref);
  return 0;
}

static int op_clone_apply(ge_engine *e, const char *args) {
  if (ensure_repo(e) != 0)
    return -1;
  char head[256] = "refs/heads/main";
  (void)jmin_get_string(args, "head", head, sizeof(head));
  if (git_repository_set_head(e->repo, head) != 0) {
    set_err_git(e, "clone.apply: set_head");
    return -1;
  }
  git_object *treeish = NULL;
  if (git_revparse_single(&treeish, e->repo, "HEAD") != 0) {
    set_err_git(e, "clone.apply: revparse");
    return -1;
  }
  git_checkout_options opts = GIT_CHECKOUT_OPTIONS_INIT;
  opts.checkout_strategy = GIT_CHECKOUT_FORCE;
  int rc = git_checkout_tree(e->repo, treeish, &opts);
  git_object_free(treeish);
  if (rc != 0) {
    set_err_git(e, "clone.apply: checkout");
    return -1;
  }
  return 0;
}

char *ge_run_json(ge_engine *e, const char *request_json) {
  static char static_oom[] =
      "{\"ok\":false,\"code\":1,\"stdout\":\"\",\"stderr\":\"out of memory\"}";
  if (!e)
    return resp_usage("null engine");
  if (!request_json)
    return resp_usage("null request");

  char op[64];
  if (jmin_get_string(request_json, "op", op, sizeof(op)) != 0 || !op[0])
    return resp_usage("missing op");

  /* Lowercase op */
  for (char *p = op; *p; p++) {
    if (*p >= 'A' && *p <= 'Z')
      *p = (char)(*p - 'A' + 'a');
  }

  const char *args = jmin_args_object(request_json);
  if (!args)
    args = "{}";

  /* Forbidden product network dials (GIT.md §6 / GIT_DESIGN §3.2). */
  if (strcmp(op, "clone") == 0 || strcmp(op, "fetch") == 0 || strcmp(op, "pull") == 0 ||
      strcmp(op, "push") == 0) {
    return resp_err(1, "git: use host-mediated remotes (pack.import / *.apply); "
                       "engine must not dial");
  }

  if (strcmp(op, "version") == 0 || strcmp(op, "help") == 0) {
    char *r = resp_ok(GE_VERSION "\n", NULL);
    return r ? r : static_oom;
  }

  if (strcmp(op, "init") == 0) {
    if (op_init(e) != 0)
      return resp_err(1, e->err);
    return resp_ok("Initialized empty Git repository\n", NULL);
  }

  if (strcmp(op, "write") == 0) {
    if (op_write(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }

  if (strcmp(op, "add") == 0) {
    if (op_add(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }

  if (strcmp(op, "commit") == 0) {
    char hash[GIT_OID_HEXSZ + 1];
    if (op_commit(e, args, hash, sizeof(hash)) != 0)
      return resp_err(1, e->err);
    char result[128];
    snprintf(result, sizeof(result), "{\"hash\":\"%s\"}", hash);
    char stdout_s[160];
    snprintf(stdout_s, sizeof(stdout_s), "[%.7s] commit\n%s\n", hash, hash);
    char *r = resp_ok(stdout_s, result);
    return r ? r : static_oom;
  }

  if (strcmp(op, "status") == 0) {
    int short_fmt = 0;
    (void)jmin_get_bool(args, "short", &short_fmt);
    char buf[16384];
    if (op_status(e, short_fmt, buf, sizeof(buf)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok(buf, NULL);
    return r ? r : static_oom;
  }

  if (strcmp(op, "log") == 0) {
    char buf[16384];
    if (op_log(e, args, buf, sizeof(buf)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok(buf, NULL);
    return r ? r : static_oom;
  }

  if (strcmp(op, "rev-parse") == 0) {
    char hex[GIT_OID_HEXSZ + 1];
    if (op_rev_parse(e, args, hex, sizeof(hex)) != 0)
      return resp_err(1, e->err);
    char result[80];
    snprintf(result, sizeof(result), "{\"hash\":\"%s\"}", hex);
    char *r = resp_ok(hex, result);
    return r ? r : static_oom;
  }

  if (strcmp(op, "branch") == 0) {
    char name[256] = "";
    int del = 0;
    (void)jmin_get_string(args, "name", name, sizeof(name));
    (void)jmin_get_bool(args, "delete", &del);
    if (del) {
      if (op_branch_delete(e, name) != 0)
        return resp_err(1, e->err);
      return resp_ok("", NULL);
    }
    if (name[0]) {
      if (op_branch_create(e, name) != 0)
        return resp_err(1, e->err);
      return resp_ok("", NULL);
    }
    char buf[4096];
    if (op_branch_list(e, buf, sizeof(buf)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok(buf, NULL);
    return r ? r : static_oom;
  }

  if (strcmp(op, "checkout") == 0 || strcmp(op, "switch") == 0) {
    char name[256];
    if (jmin_get_string(args, "name", name, sizeof(name)) != 0)
      return resp_usage("checkout: name required");
    if (op_checkout(e, name) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }

  if (strcmp(op, "rm") == 0) {
    if (op_rm(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }
  if (strcmp(op, "diff") == 0) {
    char buf[65536];
    if (op_diff(e, buf, sizeof(buf)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok(buf, NULL);
    return r ? r : static_oom;
  }
  if (strcmp(op, "show") == 0) {
    char buf[16384];
    if (op_show(e, args, buf, sizeof(buf)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok(buf, NULL);
    return r ? r : static_oom;
  }
  if (strcmp(op, "reset") == 0) {
    if (op_reset(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }
  if (strcmp(op, "tag") == 0) {
    if (op_tag(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }
  if (strcmp(op, "config") == 0) {
    char buf[4096] = "";
    if (op_config(e, args, buf, sizeof(buf)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok(buf, NULL);
    return r ? r : static_oom;
  }
  if (strcmp(op, "remote") == 0) {
    char buf[8192] = "";
    if (op_remote(e, args, buf, sizeof(buf)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok(buf, NULL);
    return r ? r : static_oom;
  }
  if (strcmp(op, "tips") == 0) {
    char tips[16384];
    if (op_tips(e, tips, sizeof(tips)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok("", tips);
    return r ? r : static_oom;
  }

  if (strcmp(op, "refs.import") == 0) {
    if (op_refs_import(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }

  if (strcmp(op, "pack.import") == 0) {
    int final = 0;
    (void)jmin_get_bool(args, "final", &final);
    if (final) {
      if (ge_import_pack(e, NULL, 0, 1) != 0)
        return resp_err(1, e->err);
    }
    return resp_ok("", NULL);
  }

  if (strcmp(op, "clone.apply") == 0) {
    if (op_clone_apply(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }

  if (strcmp(op, "fetch.apply") == 0) {
    return resp_ok("", NULL);
  }

  if (strcmp(op, "push.prepare") == 0) {
    char result[16384];
    if (op_push_prepare(e, result, sizeof(result)) != 0)
      return resp_err(1, e->err);
    char *r = resp_ok("", result);
    return r ? r : static_oom;
  }
  if (strcmp(op, "push.complete") == 0) {
    if (op_push_complete(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }


  if (strcmp(op, "sparse-set") == 0 || strcmp(op, "sparse.set") == 0) {
    if (op_sparse_set(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }
  if (strcmp(op, "sparse-disable") == 0 || strcmp(op, "sparse.disable") == 0) {
    if (op_sparse_disable(e, args) != 0)
      return resp_err(1, e->err);
    return resp_ok("", NULL);
  }

  return resp_usage("unknown op (fail closed)");
}
