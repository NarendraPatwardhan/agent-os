/* Binary MOUNT_OP dispatch for gitfs (GIT.md K30 / PR7b).
 * Request body (after host_call name\0 split): same as dispatchMount /
 * kernel MountFs encode_request:
 *   [u32 op][u32 path_len][path][u32 arg_len][arg][data…]
 * Response: [i32 status][payload]
 */

#include "ge_port.h"
#include "ge_engine_priv.h"
#include "git_engine.h"
#include "json_min.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* AgentOS contract errnos (contracts/constants.kdl → gen). */
enum {
  GE_EACCES = 2,
  GE_EEXIST = 20,
  GE_EINVAL = 28,
  GE_EIO = 29,
  GE_EISDIR = 31,
  GE_ENOENT = 44,
  GE_ENOTDIR = 54,
  GE_ENOTEMPTY = 55,
  GE_EPERM = 63,
};

enum {
  MOUNT_OP_OPEN = 0,
  MOUNT_OP_READDIR = 1,
  MOUNT_OP_MKDIR = 2,
  MOUNT_OP_UNLINK = 3,
  MOUNT_OP_RENAME = 4,
  MOUNT_OP_STAT = 5,
  MOUNT_OP_WRITE = 6,
};

enum {
  SERVE_DIRENT_FILE = 0,
  SERVE_DIRENT_DIR = 1,
  STAT_NODE_FILE = 0,
  STAT_NODE_DIR = 1,
  STAT_REC_LEN = 44,
};

/* Session ctl state (one engine = one mount). */
static char g_last_response[65536] =
    "{\"ok\":true,\"code\":0,\"stdout\":\"\",\"stderr\":\"\"}";
static uint64_t g_generation = 0;

static uint32_t rd_u32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static void wr_i32(uint8_t *p, int32_t v) {
  uint32_t u = (uint32_t)v;
  p[0] = (uint8_t)(u & 0xff);
  p[1] = (uint8_t)((u >> 8) & 0xff);
  p[2] = (uint8_t)((u >> 16) & 0xff);
  p[3] = (uint8_t)((u >> 24) & 0xff);
}

static void wr_u32(uint8_t *p, uint32_t u) {
  p[0] = (uint8_t)(u & 0xff);
  p[1] = (uint8_t)((u >> 8) & 0xff);
  p[2] = (uint8_t)((u >> 16) & 0xff);
  p[3] = (uint8_t)((u >> 24) & 0xff);
}

static void wr_u64(uint8_t *p, uint64_t u) {
  for (int i = 0; i < 8; i++)
    p[i] = (uint8_t)((u >> (8 * i)) & 0xff);
}

static int is_git_meta(const char *rel) {
  return strcmp(rel, ".git") == 0 || strncmp(rel, ".git/", 5) == 0;
}

static void join_root(char *out, size_t cap, const char *root, const char *rel) {
  if (!rel || !rel[0] || strcmp(rel, ".") == 0 || strcmp(rel, "/") == 0)
    snprintf(out, cap, "%s", root);
  else if (rel[0] == '/')
    snprintf(out, cap, "%s%s", root, rel);
  else
    snprintf(out, cap, "%s/%s", root, rel);
}

static int normalize_rel(const char *path, char *out, size_t cap) {
  if (!path)
    return -1;
  while (*path == '/')
    path++;
  /* Segment-based: allow "foo..bar", reject ".." / "../x" / "a/../b". */
  if (!ge_safe_relpath(path))
    return -1;
  if (strlen(path) >= cap)
    return -1;
  snprintf(out, cap, "%s", path);
  return 0;
}

static uint8_t *fail_status(int32_t errno_v, size_t *out_len) {
  uint8_t *o = (uint8_t *)malloc(4);
  if (!o)
    return NULL;
  wr_i32(o, errno_v);
  *out_len = 4;
  return o;
}

static uint8_t *ok_payload(const uint8_t *pay, size_t pay_len, size_t *out_len) {
  uint8_t *o = (uint8_t *)malloc(4 + pay_len);
  if (!o)
    return NULL;
  wr_i32(o, 0);
  if (pay_len)
    memcpy(o + 4, pay, pay_len);
  *out_len = 4 + pay_len;
  return o;
}

static uint8_t *encode_stat(int is_dir, uint64_t size, size_t *out_len) {
  uint8_t rec[STAT_REC_LEN];
  memset(rec, 0, sizeof(rec));
  wr_u64(rec + 0, size); /* SIZE_OFF */
  wr_u32(rec + 8, is_dir ? STAT_NODE_DIR : STAT_NODE_FILE);
  wr_u32(rec + 12, is_dir ? 2u : 1u);
  wr_u32(rec + 16, is_dir ? 0755u : 0644u);
  return ok_payload(rec, STAT_REC_LEN, out_len);
}

static int handle_ctl_write(ge_engine *e, const uint8_t *data, size_t data_len) {
  char *req = (char *)malloc(data_len + 1);
  if (!req)
    return -1;
  memcpy(req, data, data_len);
  req[data_len] = 0;

  char op[64] = "";
  (void)jmin_get_string(req, "op", op, sizeof(op));
  for (char *p = op; *p; p++) {
    if (*p >= 'A' && *p <= 'Z')
      *p = (char)(*p - 'A' + 'a');
  }

  char *resp = NULL;
  if (strcmp(op, "clone") == 0 || strcmp(op, "fetch") == 0 || strcmp(op, "pull") == 0 ||
      strcmp(op, "push") == 0) {
    resp = jmin_response(0, 1, "", "use host_call git for remotes", NULL);
  } else {
    resp = ge_run_json(e, req);
  }
  free(req);
  if (!resp)
    return -1;
  snprintf(g_last_response, sizeof(g_last_response), "%s", resp);
  ge_free(resp);
  g_generation += 1;
  return 0;
}

int ge_mount_dispatch(ge_engine *e, const uint8_t *body, size_t body_len, uint8_t **out,
                      size_t *out_len) {
  *out = NULL;
  *out_len = 0;
  if (!e || body_len < 8)
    return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;

  uint32_t op = rd_u32(body);
  uint32_t path_len = rd_u32(body + 4);
  if (8u + path_len > body_len)
    return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
  char path[4096];
  if (path_len >= sizeof(path))
    return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
  memcpy(path, body + 8, path_len);
  path[path_len] = 0;

  size_t arg_off = 8 + path_len;
  if (arg_off + 4 > body_len)
    return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
  uint32_t arg_len = rd_u32(body + arg_off);
  if (arg_off + 4 + arg_len > body_len)
    return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
  char arg[4096];
  if (arg_len >= sizeof(arg))
    return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
  memcpy(arg, body + arg_off + 4, arg_len);
  arg[arg_len] = 0;
  const uint8_t *data = body + arg_off + 4 + arg_len;
  size_t data_len = body_len - (arg_off + 4 + arg_len);

  char rel[4096];
  if (normalize_rel(path, rel, sizeof(rel)) != 0)
    return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;

  const char *wt = ge_worktree_root(e);
  if (!wt)
    return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;

  /* Synthetic .git paths */
  if (strcmp(rel, ".git/mc/ctl") == 0 || strcmp(rel, ".git/mc/out/last") == 0) {
    if (op == MOUNT_OP_OPEN || op == MOUNT_OP_STAT) {
      size_t n = strlen(g_last_response);
      if (op == MOUNT_OP_STAT)
        return (*out = encode_stat(0, (uint64_t)n, out_len)) ? 0 : -1;
      return (*out = ok_payload((const uint8_t *)g_last_response, n, out_len)) ? 0 : -1;
    }
    if (op == MOUNT_OP_WRITE && strcmp(rel, ".git/mc/ctl") == 0) {
      if (handle_ctl_write(e, data, data_len) != 0)
        return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
      return (*out = ok_payload(NULL, 0, out_len)) ? 0 : -1;
    }
    return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
  }
  if (strcmp(rel, ".git/mc/generation") == 0) {
    char gen[32];
    snprintf(gen, sizeof(gen), "%llu\n", (unsigned long long)g_generation);
    if (op == MOUNT_OP_OPEN)
      return (*out = ok_payload((const uint8_t *)gen, strlen(gen), out_len)) ? 0 : -1;
    if (op == MOUNT_OP_STAT)
      return (*out = encode_stat(0, strlen(gen), out_len)) ? 0 : -1;
    return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
  }
  if (strcmp(rel, ".git/HEAD") == 0) {
    const char *head = "ref: refs/heads/master\n";
    if (op == MOUNT_OP_OPEN)
      return (*out = ok_payload((const uint8_t *)head, strlen(head), out_len)) ? 0 : -1;
    if (op == MOUNT_OP_STAT)
      return (*out = encode_stat(0, strlen(head), out_len)) ? 0 : -1;
    return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
  }
  if (strcmp(rel, ".git") == 0 || strcmp(rel, ".git/mc") == 0 || strcmp(rel, ".git/mc/out") == 0 ||
      strcmp(rel, ".git/refs") == 0 || strcmp(rel, ".git/objects") == 0) {
    if (op == MOUNT_OP_STAT)
      return (*out = encode_stat(1, 0, out_len)) ? 0 : -1;
    if (op == MOUNT_OP_READDIR) {
      /* Minimal synthetic listings */
      uint8_t buf[256];
      size_t o = 0;
      const char *names[4];
      int kinds[4];
      int n = 0;
      if (strcmp(rel, ".git") == 0) {
        names[0] = "HEAD";
        kinds[0] = SERVE_DIRENT_FILE;
        names[1] = "mc";
        kinds[1] = SERVE_DIRENT_DIR;
        names[2] = "refs";
        kinds[2] = SERVE_DIRENT_DIR;
        n = 3;
      } else if (strcmp(rel, ".git/mc") == 0) {
        names[0] = "ctl";
        kinds[0] = SERVE_DIRENT_FILE;
        names[1] = "out";
        kinds[1] = SERVE_DIRENT_DIR;
        names[2] = "generation";
        kinds[2] = SERVE_DIRENT_FILE;
        n = 3;
      } else if (strcmp(rel, ".git/mc/out") == 0) {
        names[0] = "last";
        kinds[0] = SERVE_DIRENT_FILE;
        n = 1;
      }
      for (int i = 0; i < n; i++) {
        size_t nl = strlen(names[i]);
        if (o + 8 + nl > sizeof(buf))
          break;
        wr_u32(buf + o, (uint32_t)kinds[i]);
        wr_u32(buf + o + 4, (uint32_t)nl);
        memcpy(buf + o + 8, names[i], nl);
        o += 8 + nl;
      }
      return (*out = ok_payload(buf, o, out_len)) ? 0 : -1;
    }
    if (op == MOUNT_OP_OPEN)
      return (*out = fail_status(GE_EISDIR, out_len)) ? 0 : -1;
    return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
  }

  char abs[4096];
  join_root(abs, sizeof(abs), wt, rel);

  if (op == MOUNT_OP_OPEN) {
    FILE *f = fopen(abs, "rb");
    if (!f)
      return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
    if (fseek(f, 0, SEEK_END) != 0) {
      fclose(f);
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    }
    long sz = ftell(f);
    if (sz < 0) {
      fclose(f);
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    }
    rewind(f);
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) {
      fclose(f);
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    }
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
      free(buf);
      fclose(f);
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    }
    fclose(f);
    uint8_t *resp = ok_payload(buf, (size_t)sz, out_len);
    free(buf);
    *out = resp;
    return resp ? 0 : -1;
  }

  if (op == MOUNT_OP_STAT) {
    struct stat st;
    if (stat(abs, &st) != 0)
      return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
    return (*out = encode_stat(S_ISDIR(st.st_mode), (uint64_t)st.st_size, out_len)) ? 0 : -1;
  }

  if (op == MOUNT_OP_READDIR) {
    DIR *d = opendir(abs);
    if (!d)
      return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
    size_t cap = 4096, o = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) {
      closedir(d);
      return -1;
    }
    struct dirent *de;
    int saw_git = 0;
    while ((de = readdir(d)) != NULL) {
      if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
        continue;
      if (strcmp(de->d_name, ".git") == 0)
        saw_git = 1;
      size_t nl = strlen(de->d_name);
      if (o + 8 + nl > cap) {
        cap *= 2;
        uint8_t *nb = (uint8_t *)realloc(buf, cap);
        if (!nb) {
          free(buf);
          closedir(d);
          return -1;
        }
        buf = nb;
      }
      char child[4096];
      snprintf(child, sizeof(child), "%s/%s", abs, de->d_name);
      struct stat st;
      int is_dir = (stat(child, &st) == 0 && S_ISDIR(st.st_mode));
      wr_u32(buf + o, is_dir ? SERVE_DIRENT_DIR : SERVE_DIRENT_FILE);
      wr_u32(buf + o + 4, (uint32_t)nl);
      memcpy(buf + o + 8, de->d_name, nl);
      o += 8 + nl;
    }
    closedir(d);
    if ((!rel[0] || strcmp(rel, ".") == 0) && !saw_git) {
      const char *name = ".git";
      size_t nl = 4;
      if (o + 8 + nl <= cap) {
        wr_u32(buf + o, SERVE_DIRENT_DIR);
        wr_u32(buf + o + 4, (uint32_t)nl);
        memcpy(buf + o + 8, name, nl);
        o += 8 + nl;
      }
    }
    uint8_t *resp = ok_payload(buf, o, out_len);
    free(buf);
    *out = resp;
    return resp ? 0 : -1;
  }

  if (op == MOUNT_OP_WRITE) {
    if (is_git_meta(rel) && strcmp(rel, ".git/HEAD") != 0)
      return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    /* ensure parent */
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s", abs);
    for (char *p = tmp + strlen(wt) + 1; *p; p++) {
      if (*p == '/') {
        *p = 0;
        mkdir(tmp, 0755);
        *p = '/';
      }
    }
    FILE *f = fopen(abs, "wb");
    if (!f)
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    if (data_len && fwrite(data, 1, data_len, f) != data_len) {
      fclose(f);
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    }
    fclose(f);
    return (*out = ok_payload(NULL, 0, out_len)) ? 0 : -1;
  }

  if (op == MOUNT_OP_MKDIR) {
    if (is_git_meta(rel))
      return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    if (mkdir(abs, 0755) != 0 && errno != EEXIST)
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    return (*out = ok_payload(NULL, 0, out_len)) ? 0 : -1;
  }

  if (op == MOUNT_OP_UNLINK) {
    if (is_git_meta(rel))
      return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    struct stat st;
    if (stat(abs, &st) != 0)
      return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
    if (S_ISDIR(st.st_mode)) {
      if (rmdir(abs) != 0)
        return (*out = fail_status(GE_ENOTEMPTY, out_len)) ? 0 : -1;
    } else if (unlink(abs) != 0) {
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    }
    return (*out = ok_payload(NULL, 0, out_len)) ? 0 : -1;
  }

  if (op == MOUNT_OP_RENAME) {
    if (is_git_meta(rel) || (arg[0] && is_git_meta(arg)))
      return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    char dest[4096], drel[4096];
    if (normalize_rel(arg, drel, sizeof(drel)) != 0)
      return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    join_root(dest, sizeof(dest), wt, drel);
    if (rename(abs, dest) != 0)
      return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
    return (*out = ok_payload(NULL, 0, out_len)) ? 0 : -1;
  }

  return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
}
