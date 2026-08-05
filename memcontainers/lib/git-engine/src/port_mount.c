/* Binary MOUNT_OP dispatch for gitfs (SYSTEMS.md §11b type-4 frames).
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
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
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

static int valid_token(const char *token) {
    if (!token || !token[0] || strlen(token) >= 128)
        return 0;
    for (const unsigned char *p = (const unsigned char *)token; *p; p++) {
        if (!(isalnum(*p) || *p == '_' || *p == '-'))
            return 0;
    }
    return 1;
}

static const char *token_response(ge_engine *e, const char *token) {
    if (!e || !valid_token(token))
        return NULL;
    for (size_t i = 0; i < sizeof(e->ctl_responses) / sizeof(e->ctl_responses[0]); i++) {
        if (e->ctl_responses[i].response && strcmp(e->ctl_responses[i].token, token) == 0)
            return e->ctl_responses[i].response;
    }
    return NULL;
}

static int store_response(ge_engine *e, const char *response) {
    if (!e || !response || !valid_token(e->client_token))
        return -1;
    char *copy = strdup(response);
    if (!copy)
        return -1;
    const size_t count = sizeof(e->ctl_responses) / sizeof(e->ctl_responses[0]);
    size_t slot = count;
    for (size_t i = 0; i < count; i++) {
        if (e->ctl_responses[i].response &&
            strcmp(e->ctl_responses[i].token, e->client_token) == 0) {
            slot = i;
            break;
        }
    }
    if (slot == count)
        slot = e->ctl_response_next++ % count;
    if (e->ctl_responses[slot].response &&
        strcmp(e->ctl_responses[slot].token, e->client_token) != 0)
        ge_remove_token_stream(e, e->ctl_responses[slot].token);
    free(e->ctl_responses[slot].response);
    snprintf(e->ctl_responses[slot].token, sizeof(e->ctl_responses[slot].token), "%s",
             e->client_token);
    e->ctl_responses[slot].response = copy;
    e->ctl_generation += 1;
    return 0;
}

static uint32_t rd_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
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

/* K17: no guest `.git/objects` façade — host ODB is not projected. */
static int is_objects_path(const char *rel) {
    /* ".git/objects/" is 13 chars (not 14). */
    return strcmp(rel, ".git/objects") == 0 || strncmp(rel, ".git/objects/", 13) == 0;
}

static void join_root(char *out, size_t cap, const char *root, const char *rel) {
    if (!out || cap == 0)
        return;
    int n;
    if (!rel || !rel[0] || strcmp(rel, ".") == 0 || strcmp(rel, "/") == 0)
        n = snprintf(out, cap, "%s", root);
    else if (rel[0] == '/')
        n = snprintf(out, cap, "%s%s", root, rel);
    else
        n = snprintf(out, cap, "%s/%s", root, rel);
    if (n < 0 || (size_t)n >= cap)
        out[0] = '\0';
}

static int normalize_rel(const char *path, char *out, size_t cap) {
    if (!path || cap == 0)
        return -1;
    while (*path == '/')
        path++;
    /* Mount root: guest path "/" (or "") after strip — must not hit ge_safe_relpath
     * (empty is rejected there). STAT/OPEN/READDIR of the mount point use this. */
    if (!*path) {
        out[0] = '\0';
        return 0;
    }
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
    const char *args = NULL;
    char token[128] = "";
    if (jmin_validate_request(req, op, sizeof(op), &args) != 0 ||
        jmin_get_string(args, "client_token", token, sizeof(token)) != 0 || !valid_token(token)) {
        free(req);
        return -2;
    }

    ge_remove_token_stream(e, token);
    char *resp = ge_run_json(e, req);
    free(req);
    if (!resp)
        return -1;
    int stored = store_response(e, resp);
    ge_free(resp);
    return stored;
}

static int mount_errno(void) {
    switch (errno) {
    case ENOENT:
        return GE_ENOENT;
    case ENOTDIR:
        return GE_ENOTDIR;
    case EISDIR:
        return GE_EISDIR;
    case EEXIST:
        return GE_EEXIST;
    case ENOTEMPTY:
        return GE_ENOTEMPTY;
    case EACCES:
    case EPERM:
    case ELOOP:
        return GE_EACCES;
    default:
        return GE_EIO;
    }
}

/* Resolve rel's parent one component at a time beneath root_fd. O_NOFOLLOW on
 * every open makes a repository symlink an access error rather than a new path
 * root. When create_parents is true, only missing real directories are added. */
static int open_parent_nofollow(int root_fd, const char *rel, int create_parents, char *leaf,
                                size_t leaf_cap) {
    if (!rel || !rel[0] || !leaf || leaf_cap == 0) {
        errno = EACCES;
        return -1;
    }
    char path[4096];
    if (strlen(rel) >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(path, rel, strlen(rel) + 1);

    char *last = strrchr(path, '/');
    char *parent_path = NULL;
    const char *leaf_src = path;
    if (last) {
        *last = '\0';
        parent_path = path;
        leaf_src = last + 1;
    }
    if (!leaf_src[0] || strlen(leaf_src) >= leaf_cap) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(leaf, leaf_src, strlen(leaf_src) + 1);

    int fd = dup(root_fd);
    if (fd < 0)
        return -1;
    if (!parent_path || !parent_path[0])
        return fd;

    char *save = NULL;
    for (char *segment = strtok_r(parent_path, "/", &save); segment;
         segment = strtok_r(NULL, "/", &save)) {
        int next = openat(fd, segment, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && create_parents && errno == ENOENT) {
            if (mkdirat(fd, segment, 0755) != 0 && errno != EEXIST) {
                close(fd);
                return -1;
            }
            next = openat(fd, segment, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) {
            int saved = errno;
            struct stat st;
            if (fstatat(fd, segment, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode))
                saved = ELOOP;
            close(fd);
            errno = saved;
            return -1;
        }
        close(fd);
        fd = next;
    }
    return fd;
}

static int open_rel_nofollow(int root_fd, const char *rel, int flags, mode_t mode) {
    if (!rel || !rel[0])
        return dup(root_fd);
    char leaf[4096];
    int parent = open_parent_nofollow(root_fd, rel, 0, leaf, sizeof(leaf));
    if (parent < 0)
        return -1;
    int fd = openat(parent, leaf, flags | O_NOFOLLOW | O_CLOEXEC, mode);
    int saved = errno;
    if (fd < 0) {
        struct stat st;
        if (fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode))
            saved = ELOOP;
    }
    close(parent);
    errno = saved;
    return fd;
}

static int stat_rel_nofollow(int root_fd, const char *rel, struct stat *st) {
    if (!rel || !rel[0])
        return fstat(root_fd, st);
    char leaf[4096];
    int parent = open_parent_nofollow(root_fd, rel, 0, leaf, sizeof(leaf));
    if (parent < 0)
        return -1;
    int rc = fstatat(parent, leaf, st, AT_SYMLINK_NOFOLLOW);
    int saved = errno;
    close(parent);
    if (rc == 0 && S_ISLNK(st->st_mode)) {
        errno = ELOOP;
        return -1;
    }
    errno = saved;
    return rc;
}

static uint8_t *dispatch_real_mount(ge_engine *e, const char *wt, uint32_t op, const char *rel,
                                    const char *dest_rel, const uint8_t *data, size_t data_len,
                                    size_t *out_len) {
    int root_fd = open(wt, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root_fd < 0)
        return fail_status(mount_errno(), out_len);

    uint8_t *result = NULL;
    if (op == MOUNT_OP_OPEN) {
        int fd = open_rel_nofollow(root_fd, rel, O_RDONLY, 0);
        if (fd < 0) {
            result = fail_status(mount_errno(), out_len);
            goto done;
        }
        struct stat st;
        if (fstat(fd, &st) != 0) {
            result = fail_status(GE_EIO, out_len);
            close(fd);
            goto done;
        }
        if (!S_ISREG(st.st_mode)) {
            result = fail_status(S_ISDIR(st.st_mode) ? GE_EISDIR : GE_EACCES, out_len);
            close(fd);
            goto done;
        }
        if (st.st_size < 0 || (uint64_t)st.st_size > (uint64_t)SIZE_MAX) {
            result = fail_status(GE_EIO, out_len);
            close(fd);
            goto done;
        }
        if ((uint64_t)st.st_size > (uint64_t)GE_MOUNT_FILE_MAX_BYTES) {
            result = fail_status(GE_EINVAL, out_len);
            close(fd);
            goto done;
        }
        size_t n = (size_t)st.st_size;
        uint8_t *buf = n ? (uint8_t *)malloc(n) : NULL;
        if (n && !buf) {
            result = fail_status(GE_EIO, out_len);
            close(fd);
            goto done;
        }
        size_t got = 0;
        while (got < n) {
            ssize_t nr = read(fd, buf + got, n - got);
            if (nr < 0 && errno == EINTR)
                continue;
            if (nr <= 0) {
                free(buf);
                result = fail_status(GE_EIO, out_len);
                close(fd);
                goto done;
            }
            got += (size_t)nr;
        }
        close(fd);
        result = ok_payload(buf, n, out_len);
        free(buf);
        goto done;
    }

    if (op == MOUNT_OP_STAT) {
        struct stat st;
        if (stat_rel_nofollow(root_fd, rel, &st) != 0)
            result = fail_status(mount_errno(), out_len);
        else if (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))
            result = fail_status(GE_EACCES, out_len);
        else
            result = encode_stat(S_ISDIR(st.st_mode), (uint64_t)st.st_size, out_len);
        goto done;
    }

    if (op == MOUNT_OP_READDIR) {
        int fd = open_rel_nofollow(root_fd, rel, O_RDONLY | O_DIRECTORY, 0);
        if (fd < 0) {
            result = fail_status(mount_errno(), out_len);
            goto done;
        }
        DIR *d = fdopendir(fd);
        if (!d) {
            close(fd);
            result = fail_status(GE_EIO, out_len);
            goto done;
        }
        size_t cap = 4096, used = 0;
        uint8_t *buf = (uint8_t *)malloc(cap);
        if (!buf) {
            closedir(d);
            result = fail_status(GE_EIO, out_len);
            goto done;
        }
        int saw_git = 0;
        struct dirent *de;
        errno = 0;
        while ((de = readdir(d)) != NULL) {
            if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
                continue;
            struct stat st;
            if (fstatat(dirfd(d), de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
                free(buf);
                closedir(d);
                result = fail_status(GE_EIO, out_len);
                goto done;
            }
            if (S_ISLNK(st.st_mode) || (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)))
                continue; /* links and special files are not projected into gitfs */
            if (strcmp(de->d_name, ".git") == 0)
                saw_git = 1;
            size_t nl = strlen(de->d_name);
            size_t need = used + 8 + nl;
            if (need > GE_MOUNT_FILE_MAX_BYTES) {
                free(buf);
                closedir(d);
                result = fail_status(GE_EINVAL, out_len);
                goto done;
            }
            while (need > cap) {
                size_t next_cap = cap * 2;
                if (next_cap > GE_MOUNT_FILE_MAX_BYTES)
                    next_cap = GE_MOUNT_FILE_MAX_BYTES;
                uint8_t *grown = (uint8_t *)realloc(buf, next_cap);
                if (!grown) {
                    free(buf);
                    closedir(d);
                    result = fail_status(GE_EIO, out_len);
                    goto done;
                }
                buf = grown;
                cap = next_cap;
            }
            wr_u32(buf + used, S_ISDIR(st.st_mode) ? SERVE_DIRENT_DIR : SERVE_DIRENT_FILE);
            wr_u32(buf + used + 4, (uint32_t)nl);
            memcpy(buf + used + 8, de->d_name, nl);
            used += 8 + nl;
        }
        if (errno != 0) {
            free(buf);
            closedir(d);
            result = fail_status(GE_EIO, out_len);
            goto done;
        }
        if (closedir(d) != 0) {
            free(buf);
            result = fail_status(GE_EIO, out_len);
            goto done;
        }
        if ((!rel[0] || strcmp(rel, ".") == 0) && !saw_git) {
            const char *name = ".git";
            size_t nl = strlen(name);
            size_t need = used + 8 + nl;
            if (need > GE_MOUNT_FILE_MAX_BYTES) {
                free(buf);
                result = fail_status(GE_EINVAL, out_len);
                goto done;
            }
            if (need > cap) {
                uint8_t *grown = (uint8_t *)realloc(buf, need);
                if (!grown) {
                    free(buf);
                    result = fail_status(GE_EIO, out_len);
                    goto done;
                }
                buf = grown;
                cap = need;
            }
            wr_u32(buf + used, SERVE_DIRENT_DIR);
            wr_u32(buf + used + 4, (uint32_t)nl);
            memcpy(buf + used + 8, name, nl);
            used += 8 + nl;
        }
        result = ok_payload(buf, used, out_len);
        free(buf);
        goto done;
    }

    if (!rel[0]) {
        result = fail_status(GE_EACCES, out_len);
        goto done;
    }

    if (op == MOUNT_OP_WRITE) {
        char leaf[4096];
        int parent = open_parent_nofollow(root_fd, rel, 1, leaf, sizeof(leaf));
        if (parent < 0) {
            result = fail_status(mount_errno(), out_len);
            goto done;
        }
        struct stat prior;
        mode_t mode = 0644;
        if (fstatat(parent, leaf, &prior, AT_SYMLINK_NOFOLLOW) == 0) {
            if (!S_ISREG(prior.st_mode)) {
                close(parent);
                result = fail_status(GE_EACCES, out_len);
                goto done;
            }
            mode = prior.st_mode & 0777;
        } else if (errno != ENOENT) {
            result = fail_status(mount_errno(), out_len);
            close(parent);
            goto done;
        }

        char temporary[128];
        int temporary_n = snprintf(temporary, sizeof(temporary), ".agentos-write-%ld-%llu",
                                   (long)getpid(), (unsigned long long)++e->file_generation);
        if (temporary_n < 0 || (size_t)temporary_n >= sizeof(temporary)) {
            close(parent);
            result = fail_status(GE_EIO, out_len);
            goto done;
        }
        int fd =
            openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode);
        if (fd < 0) {
            result = fail_status(mount_errno(), out_len);
            close(parent);
            goto done;
        }
        if (fchmod(fd, mode) != 0) {
            close(fd);
            unlinkat(parent, temporary, 0);
            close(parent);
            result = fail_status(GE_EIO, out_len);
            goto done;
        }
        size_t wrote = 0;
        while (wrote < data_len) {
            ssize_t nw = write(fd, data + wrote, data_len - wrote);
            if (nw < 0 && errno == EINTR)
                continue;
            if (nw <= 0) {
                close(fd);
                unlinkat(parent, temporary, 0);
                close(parent);
                result = fail_status(GE_EIO, out_len);
                goto done;
            }
            wrote += (size_t)nw;
        }
        if (close(fd) != 0) {
            unlinkat(parent, temporary, 0);
            result = fail_status(GE_EIO, out_len);
        } else if (renameat(parent, temporary, parent, leaf) != 0) {
            unlinkat(parent, temporary, 0);
            result = fail_status(mount_errno(), out_len);
        } else {
            result = ok_payload(NULL, 0, out_len);
        }
        close(parent);
        goto done;
    }

    if (op == MOUNT_OP_MKDIR) {
        char leaf[4096];
        int parent = open_parent_nofollow(root_fd, rel, 0, leaf, sizeof(leaf));
        if (parent < 0) {
            result = fail_status(mount_errno(), out_len);
            goto done;
        }
        if (mkdirat(parent, leaf, 0755) != 0) {
            int saved = errno;
            if (saved != EEXIST) {
                errno = saved;
                result = fail_status(mount_errno(), out_len);
                close(parent);
                goto done;
            }
            struct stat st;
            if (fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0) {
                result = fail_status(mount_errno(), out_len);
                close(parent);
                goto done;
            }
            if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode)) {
                result = fail_status(S_ISLNK(st.st_mode) ? GE_EACCES : GE_EEXIST, out_len);
                close(parent);
                goto done;
            }
        }
        close(parent);
        result = ok_payload(NULL, 0, out_len);
        goto done;
    }

    if (op == MOUNT_OP_UNLINK) {
        char leaf[4096];
        int parent = open_parent_nofollow(root_fd, rel, 0, leaf, sizeof(leaf));
        if (parent < 0) {
            result = fail_status(mount_errno(), out_len);
            goto done;
        }
        struct stat st;
        if (fstatat(parent, leaf, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            result = fail_status(mount_errno(), out_len);
            close(parent);
            goto done;
        }
        if (S_ISLNK(st.st_mode)) {
            result = fail_status(GE_EACCES, out_len);
            close(parent);
            goto done;
        }
        if (unlinkat(parent, leaf, S_ISDIR(st.st_mode) ? AT_REMOVEDIR : 0) != 0)
            result = fail_status(mount_errno(), out_len);
        else
            result = ok_payload(NULL, 0, out_len);
        close(parent);
        goto done;
    }

    if (op == MOUNT_OP_RENAME) {
        char src_leaf[4096], dst_leaf[4096];
        int src_parent = open_parent_nofollow(root_fd, rel, 0, src_leaf, sizeof(src_leaf));
        if (src_parent < 0) {
            result = fail_status(mount_errno(), out_len);
            goto done;
        }
        struct stat st;
        if (fstatat(src_parent, src_leaf, &st, AT_SYMLINK_NOFOLLOW) != 0) {
            result = fail_status(mount_errno(), out_len);
            close(src_parent);
            goto done;
        }
        if (S_ISLNK(st.st_mode)) {
            result = fail_status(GE_EACCES, out_len);
            close(src_parent);
            goto done;
        }
        int dst_parent = open_parent_nofollow(root_fd, dest_rel, 0, dst_leaf, sizeof(dst_leaf));
        if (dst_parent < 0) {
            result = fail_status(mount_errno(), out_len);
            close(src_parent);
            goto done;
        }
        struct stat dst_st;
        if (fstatat(dst_parent, dst_leaf, &dst_st, AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISLNK(dst_st.st_mode)) {
            result = fail_status(GE_EACCES, out_len);
            close(dst_parent);
            close(src_parent);
            goto done;
        }
        if (renameat(src_parent, src_leaf, dst_parent, dst_leaf) != 0)
            result = fail_status(mount_errno(), out_len);
        else
            result = ok_payload(NULL, 0, out_len);
        close(dst_parent);
        close(src_parent);
        goto done;
    }

    result = fail_status(GE_EINVAL, out_len);

done:
    close(root_fd);
    return result;
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
    if (data_len > GE_WRITE_MAX_BYTES)
        return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;

    char rel[4096];
    if (normalize_rel(path, rel, sizeof(rel)) != 0)
        return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;

    const char *wt = ge_worktree_root(e);
    if (!wt)
        return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;

    /* K17: objects path is not projected (ENOENT for all ops; no host ODB leak). */
    if (is_objects_path(rel))
        return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;

    /* Synthetic .git paths */
    if (strcmp(rel, ".git/mc/ctl") == 0) {
        if (op == MOUNT_OP_STAT)
            return (*out = encode_stat(0, 0, out_len)) ? 0 : -1;
        if (op == MOUNT_OP_WRITE) {
            int ctl_rc = handle_ctl_write(e, data, data_len);
            if (ctl_rc != 0)
                return (*out = fail_status(ctl_rc == -2 ? GE_EINVAL : GE_EIO, out_len)) ? 0 : -1;
            return (*out = ok_payload(NULL, 0, out_len)) ? 0 : -1;
        }
        return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    }
    if (strncmp(rel, ".git/mc/responses/", 18) == 0) {
        const char *token = rel + 18;
        const char *response = token_response(e, token);
        if (!response)
            return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
        size_t n = strlen(response);
        if (op == MOUNT_OP_STAT)
            return (*out = encode_stat(0, (uint64_t)n, out_len)) ? 0 : -1;
        if (op == MOUNT_OP_OPEN)
            return (*out = ok_payload((const uint8_t *)response, n, out_len)) ? 0 : -1;
        return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    }
    if (strncmp(rel, ".git/mc/out/", 12) == 0) {
        const char *token = rel + 12;
        const char *response = valid_token(token) ? token_response(e, token) : NULL;
        const char *result_obj = response ? jmin_get_object(response, "result") : NULL;
        char advertised[320] = "";
        if (!result_obj ||
            jmin_get_string(result_obj, "stream_path", advertised, sizeof(advertised)) != 0 ||
            strcmp(advertised, rel) != 0)
            return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
        if (op != MOUNT_OP_OPEN && op != MOUNT_OP_STAT)
            return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
        char disk[4096];
        join_root(disk, sizeof(disk), wt, rel);
        if (!disk[0])
            return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
        int fd = open(disk, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat st;
        if (fd < 0 || fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
            if (fd >= 0)
                close(fd);
            return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
        }
        if (st.st_size < 0 || (uint64_t)st.st_size > GE_OUT_STREAM_MAX_BYTES) {
            close(fd);
            return (*out = fail_status(GE_EINVAL, out_len)) ? 0 : -1;
        }
        if (op == MOUNT_OP_STAT) {
            close(fd);
            return (*out = encode_stat(0, (uint64_t)st.st_size, out_len)) ? 0 : -1;
        }
        size_t n = (size_t)st.st_size;
        uint8_t *buf = n ? (uint8_t *)malloc(n) : NULL;
        if (n && !buf) {
            close(fd);
            return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
        }
        size_t got = 0;
        while (got < n) {
            ssize_t nr = read(fd, buf + got, n - got);
            if (nr < 0 && errno == EINTR)
                continue;
            if (nr <= 0)
                break;
            got += (size_t)nr;
        }
        close(fd);
        if (got != n) {
            free(buf);
            return (*out = fail_status(GE_EIO, out_len)) ? 0 : -1;
        }
        uint8_t *payload = ok_payload(buf, n, out_len);
        free(buf);
        return (*out = payload) ? 0 : -1;
    }
    if (strcmp(rel, ".git/mc/generation") == 0) {
        char gen[32];
        snprintf(gen, sizeof(gen), "%llu\n", (unsigned long long)e->ctl_generation);
        if (op == MOUNT_OP_OPEN)
            return (*out = ok_payload((const uint8_t *)gen, strlen(gen), out_len)) ? 0 : -1;
        if (op == MOUNT_OP_STAT)
            return (*out = encode_stat(0, strlen(gen), out_len)) ? 0 : -1;
        return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    }
    if (strcmp(rel, ".git/HEAD") == 0) {
        /* R23: synthesize HEAD from engine symbolic-ref / detached OID — not hard-coded master. */
        char head[320];
        head[0] = '\0';
        if (e && e->repo) {
            git_reference *href = NULL;
            if (git_reference_lookup(&href, e->repo, "HEAD") == 0) {
                if (git_reference_type(href) == GIT_REFERENCE_SYMBOLIC) {
                    const char *t = git_reference_symbolic_target(href);
                    snprintf(head, sizeof(head), "ref: %s\n", t && t[0] ? t : "refs/heads/master");
                } else {
                    const git_oid *oid = git_reference_target(href);
                    if (oid) {
                        char hex[GIT_OID_HEXSZ + 1];
                        git_oid_tostr(hex, sizeof(hex), oid);
                        snprintf(head, sizeof(head), "%s\n", hex);
                    }
                }
                git_reference_free(href);
            }
        }
        if (!head[0])
            snprintf(head, sizeof(head), "ref: refs/heads/master\n");
        if (op == MOUNT_OP_OPEN)
            return (*out = ok_payload((const uint8_t *)head, strlen(head), out_len)) ? 0 : -1;
        if (op == MOUNT_OP_STAT)
            return (*out = encode_stat(0, strlen(head), out_len)) ? 0 : -1;
        return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    }
    /* Synthetic dirs: HEAD/refs/ctl only — never objects (K17). */
    if (strcmp(rel, ".git") == 0 || strcmp(rel, ".git/mc") == 0 ||
        strcmp(rel, ".git/mc/out") == 0 || strcmp(rel, ".git/mc/responses") == 0 ||
        strcmp(rel, ".git/refs") == 0) {
        if (op == MOUNT_OP_STAT)
            return (*out = encode_stat(1, 0, out_len)) ? 0 : -1;
        if (op == MOUNT_OP_READDIR) {
            /* Minimal synthetic listings (HEAD + mc + refs under .git). */
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
                names[3] = "responses";
                kinds[3] = SERVE_DIRENT_DIR;
                n = 4;
            }
            /* .git/refs → empty listing (synthetic tips optional later) */
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

    /* GIT-016: positive allowlist. Unrecognized `.git/**` never falls through to
     * the physical engine filesystem (config, index, logs, packed-refs, loose refs). */
    if (is_git_meta(rel)) {
        if (op == MOUNT_OP_WRITE || op == MOUNT_OP_MKDIR || op == MOUNT_OP_UNLINK ||
            op == MOUNT_OP_RENAME)
            return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
        return (*out = fail_status(GE_ENOENT, out_len)) ? 0 : -1;
    }

    char dest_rel[4096] = "";
    if (op == MOUNT_OP_RENAME) {
        if (normalize_rel(arg, dest_rel, sizeof(dest_rel)) != 0 || !dest_rel[0] ||
            is_git_meta(dest_rel))
            return (*out = fail_status(GE_EACCES, out_len)) ? 0 : -1;
    }

    *out = dispatch_real_mount(e, wt, op, rel, dest_rel, data, data_len, out_len);
    return *out ? 0 : -1;
}
