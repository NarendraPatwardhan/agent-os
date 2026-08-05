/* Port frame acceptance: Run init→commit + mount ctl + kill-closed (product Port path). */

#define _POSIX_C_SOURCE 200809L

#include "ge_port.h"
#include "git_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int write_run(FILE *out, const char *json) {
    return ge_frame_write(out, GE_FRAME_RUN, json, strlen(json));
}

static char *read_run_json(FILE *in) {
    uint8_t type = 0;
    uint8_t *payload = NULL;
    size_t len = 0;
    if (ge_frame_read(in, &type, &payload, &len) != 0 || type != GE_FRAME_RUN)
        return NULL;
    char *s = (char *)malloc(len + 1);
    if (!s) {
        free(payload);
        return NULL;
    }
    if (len)
        memcpy(s, payload, len);
    s[len] = 0;
    free(payload);
    return s;
}

/* Encode MOUNT_OP_WRITE body for path + data. */
static uint8_t *enc_write(const char *path, const char *data, size_t *out_len) {
    size_t plen = strlen(path);
    size_t dlen = strlen(data);
    size_t n = 8 + plen + 4 + 0 + dlen;
    uint8_t *b = (uint8_t *)malloc(n);
    if (!b)
        return NULL;
    /* op = WRITE = 6 */
    b[0] = 6;
    b[1] = b[2] = b[3] = 0;
    b[4] = (uint8_t)(plen & 0xff);
    b[5] = (uint8_t)((plen >> 8) & 0xff);
    b[6] = b[7] = 0;
    memcpy(b + 8, path, plen);
    size_t arg_off = 8 + plen;
    b[arg_off] = b[arg_off + 1] = b[arg_off + 2] = b[arg_off + 3] = 0;
    memcpy(b + arg_off + 4, data, dlen);
    *out_len = n;
    return b;
}

static uint8_t *enc_open(const char *path, size_t *out_len) {
    size_t plen = strlen(path);
    size_t n = 8 + plen + 4;
    uint8_t *b = (uint8_t *)malloc(n);
    if (!b)
        return NULL;
    b[0] = b[1] = b[2] = b[3] = 0; /* OPEN */
    b[4] = (uint8_t)(plen & 0xff);
    b[5] = (uint8_t)((plen >> 8) & 0xff);
    b[6] = b[7] = 0;
    memcpy(b + 8, path, plen);
    size_t arg_off = 8 + plen;
    b[arg_off] = b[arg_off + 1] = b[arg_off + 2] = b[arg_off + 3] = 0;
    *out_len = n;
    return b;
}

/* MOUNT_OP_STAT = 5 */
static uint8_t *enc_stat(const char *path, size_t *out_len) {
    size_t plen = strlen(path);
    size_t n = 8 + plen + 4;
    uint8_t *b = (uint8_t *)malloc(n);
    if (!b)
        return NULL;
    b[0] = 5;
    b[1] = b[2] = b[3] = 0;
    b[4] = (uint8_t)(plen & 0xff);
    b[5] = (uint8_t)((plen >> 8) & 0xff);
    b[6] = b[7] = 0;
    memcpy(b + 8, path, plen);
    size_t arg_off = 8 + plen;
    b[arg_off] = b[arg_off + 1] = b[arg_off + 2] = b[arg_off + 3] = 0;
    *out_len = n;
    return b;
}

/* MOUNT_OP_READDIR = 1 */
static uint8_t *enc_readdir(const char *path, size_t *out_len) {
    size_t plen = strlen(path);
    size_t n = 8 + plen + 4;
    uint8_t *b = (uint8_t *)malloc(n);
    if (!b)
        return NULL;
    b[0] = 1;
    b[1] = b[2] = b[3] = 0;
    b[4] = (uint8_t)(plen & 0xff);
    b[5] = (uint8_t)((plen >> 8) & 0xff);
    b[6] = b[7] = 0;
    memcpy(b + 8, path, plen);
    size_t arg_off = 8 + plen;
    b[arg_off] = b[arg_off + 1] = b[arg_off + 2] = b[arg_off + 3] = 0;
    *out_len = n;
    return b;
}

static void put_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)((v >> 8) & 0xff);
    p[2] = (uint8_t)((v >> 16) & 0xff);
    p[3] = (uint8_t)((v >> 24) & 0xff);
}

static uint8_t *enc_mount(uint32_t op, const char *path, const char *arg, const uint8_t *data,
                          size_t data_len, size_t *out_len) {
    size_t plen = strlen(path);
    size_t alen = arg ? strlen(arg) : 0;
    size_t n = 8 + plen + 4 + alen + data_len;
    uint8_t *b = (uint8_t *)malloc(n);
    if (!b)
        return NULL;
    put_u32(b, op);
    put_u32(b + 4, (uint32_t)plen);
    memcpy(b + 8, path, plen);
    size_t arg_off = 8 + plen;
    put_u32(b + arg_off, (uint32_t)alen);
    if (alen)
        memcpy(b + arg_off + 4, arg, alen);
    if (data_len)
        memcpy(b + arg_off + 4 + alen, data, data_len);
    *out_len = n;
    return b;
}

static int32_t rd_i32(const uint8_t *p) {
    return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
                     ((uint32_t)p[3] << 24));
}

/* AgentOS contract errno values (constants.kdl → gen). */
enum { GE_TEST_EACCES = 2, GE_TEST_EINVAL = 28, GE_TEST_ENOENT = 44 };

static int expect_mount_status(ge_engine *e, uint8_t *body, size_t body_len, int32_t want,
                               const char *label) {
    if (!body) {
        fprintf(stderr, "%s: request allocation failed\n", label);
        return 1;
    }
    uint8_t *out = NULL;
    size_t out_len = 0;
    int rc = ge_mount_dispatch(e, body, body_len, &out, &out_len);
    free(body);
    if (rc != 0 || !out || out_len < 4) {
        fprintf(stderr, "%s: dispatch failed\n", label);
        free(out);
        return 1;
    }
    int32_t got = rd_i32(out);
    free(out);
    if (got != want) {
        fprintf(stderr, "%s: status %d, want %d\n", label, (int)got, (int)want);
        return 1;
    }
    return 0;
}

int main(void) {
    char tmpl[] = "/tmp/ge-port-XXXXXX";
    char *root = mkdtemp(tmpl);
    if (!root) {
        perror("mkdtemp");
        return 1;
    }

    ge_engine *e = ge_open(root);
    if (!e) {
        fprintf(stderr, "ge_open failed\n");
        return 1;
    }

    /* In-memory frame loop via tmpfile duplex */
    FILE *pipe_ab = tmpfile();
    FILE *pipe_ba = tmpfile();
    if (!pipe_ab || !pipe_ba) {
        fprintf(stderr, "tmpfile failed\n");
        return 1;
    }

    /* Simulate BEAM write request → engine handle → response */
#define RUN(json)                                                                                  \
    do {                                                                                           \
        rewind(pipe_ab);                                                                           \
        ftruncate(fileno(pipe_ab), 0);                                                             \
        rewind(pipe_ba);                                                                           \
        ftruncate(fileno(pipe_ba), 0);                                                             \
        if (write_run(pipe_ab, (json)) != 0)                                                       \
            return 1;                                                                              \
        rewind(pipe_ab);                                                                           \
        uint8_t t = 0;                                                                             \
        uint8_t *p = NULL;                                                                         \
        size_t pl = 0;                                                                             \
        if (ge_frame_read(pipe_ab, &t, &p, &pl) != 0)                                              \
            return 1;                                                                              \
        if (ge_port_handle(e, t, p, pl, pipe_ba) != 0)                                             \
            return 1;                                                                              \
        free(p);                                                                                   \
        rewind(pipe_ba);                                                                           \
        char *resp = read_run_json(pipe_ba);                                                       \
        if (!resp || strstr(resp, "\"ok\":false") || strstr(resp, "\"ok\": false")) {              \
            fprintf(stderr, "FAIL run %s → %s\n", (json), resp ? resp : "(null)");                 \
            free(resp);                                                                            \
            return 1;                                                                              \
        }                                                                                          \
        free(resp);                                                                                \
    } while (0)

    RUN("{\"op\":\"init\"}");
    RUN("{\"op\":\"write\",\"args\":{\"path\":\"a.txt\",\"content\":\"hi\\n\"}}");
    RUN("{\"op\":\"add\",\"args\":{\"path\":\"a.txt\"}}");
    RUN("{\"op\":\"commit\",\"args\":{\"message\":\"c\",\"name\":\"T\",\"email\":\"t@t\",\"when_"
        "unix\":1700000000}}");

    /* Type-4 mount: ctl status */
    {
        const char *req =
            "{\"op\":\"status\",\"args\":{\"short\":true,\"client_token\":\"status-one\"}}";
        size_t blen = 0;
        uint8_t *body = enc_write(".git/mc/ctl", req, &blen);
        if (!body)
            return 1;
        uint8_t *mout = NULL;
        size_t mlen = 0;
        if (ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout) {
            fprintf(stderr, "mount write ctl failed\n");
            return 1;
        }
        free(body);
        free(mout);

        blen = 0;
        body = enc_open(".git/mc/responses/status-one", &blen);
        if (ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4) {
            fprintf(stderr, "mount open token response failed\n");
            return 1;
        }
        free(body);
        /* status 0 */
        if (mout[0] | mout[1] | mout[2] | mout[3]) {
            fprintf(stderr, "mount token response status non-zero\n");
            return 1;
        }
        if (!strstr((char *)mout + 4, "\"ok\"")) {
            fprintf(stderr, "token response missing ok: %.*s\n", (int)(mlen - 4), (char *)mout + 4);
            return 1;
        }
        free(mout);
    }

    /* K17: no `.git/objects` façade — open/stat ENOENT; readdir .git omits objects. */

    /* Two writers interleave, then each reads its own token slot. */
    {
        const char *req_a = "{\"op\":\"status\",\"args\":{\"client_token\":\"client-a\"}}";
        const char *req_b = "{\"op\":\"status\",\"args\":{\"client_token\":\"client-b\"}}";
        const char *tokens[] = {"client-a", "client-b"};
        const char *requests[] = {req_a, req_b};
        for (int i = 0; i < 2; i++) {
            size_t blen = 0, mlen = 0;
            uint8_t *body = enc_write(".git/mc/ctl", requests[i], &blen);
            uint8_t *mout = NULL;
            if (!body || ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout ||
                rd_i32(mout) != 0)
                return 1;
            free(body);
            free(mout);
        }
        for (int i = 0; i < 2; i++) {
            char path[256];
            snprintf(path, sizeof(path), ".git/mc/responses/%s", tokens[i]);
            size_t blen = 0, mlen = 0;
            uint8_t *body = enc_open(path, &blen);
            uint8_t *mout = NULL;
            if (!body || ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4 ||
                rd_i32(mout) != 0 || !strstr((char *)mout + 4, tokens[i])) {
                fprintf(stderr, "token response mismatch for %s\n", tokens[i]);
                free(body);
                free(mout);
                return 1;
            }
            free(body);
            free(mout);
        }

        /* A reused process token replaces its prior response; lookup must not
         * return the older matching slot after PID reuse. */
        const char *replacement = "{\"op\":\"version\",\"args\":{\"client_token\":\"client-a\"}}";
        size_t blen = 0, mlen = 0;
        uint8_t *body = enc_write(".git/mc/ctl", replacement, &blen);
        uint8_t *mout = NULL;
        if (!body || ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout ||
            rd_i32(mout) != 0)
            return 1;
        free(body);
        free(mout);

        body = enc_open(".git/mc/responses/client-a", &blen);
        mout = NULL;
        if (!body || ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4 ||
            rd_i32(mout) != 0 || !strstr((char *)mout + 4, "agentos-git-engine")) {
            fprintf(stderr, "reused token returned stale response\n");
            free(body);
            free(mout);
            return 1;
        }
        free(body);
        free(mout);

        /* Response-slot eviction must also delete the evicted token's stream
         * file so bounded metadata cannot leave unbounded disk artifacts. */
        char mc_dir[4096], out_dir[4096], stale_stream[4096];
        snprintf(mc_dir, sizeof(mc_dir), "%s/.git/mc", root);
        mkdir(mc_dir, 0755);
        snprintf(out_dir, sizeof(out_dir), "%s/.git/mc/out", root);
        mkdir(out_dir, 0755);
        snprintf(stale_stream, sizeof(stale_stream), "%s/status-one", out_dir);
        FILE *stale = fopen(stale_stream, "wb");
        if (!stale || fwrite("stale", 1, 5, stale) != 5 || fclose(stale) != 0)
            return 1;
        size_t hidden_len = 0;
        uint8_t *hidden_body = enc_open(".git/mc/out/status-one", &hidden_len);
        if (expect_mount_status(e, hidden_body, hidden_len, GE_TEST_ENOENT,
                                "non-stream response physical artifact"))
            return 1;
        for (int i = 0; i < 32; i++) {
            char request[160];
            snprintf(request, sizeof(request),
                     "{\"op\":\"status\",\"args\":{\"client_token\":\"evict-%d\"}}", i);
            size_t evict_len = 0, response_len = 0;
            uint8_t *evict_body = enc_write(".git/mc/ctl", request, &evict_len);
            uint8_t *evict_out = NULL;
            if (!evict_body ||
                ge_mount_dispatch(e, evict_body, evict_len, &evict_out, &response_len) != 0 ||
                !evict_out || rd_i32(evict_out) != 0) {
                free(evict_body);
                free(evict_out);
                return 1;
            }
            free(evict_body);
            free(evict_out);
        }
        if (access(stale_stream, F_OK) == 0) {
            fprintf(stderr, "evicted ctl response left its stream file behind\n");
            return 1;
        }
    }

    {
        size_t blen = 0;
        uint8_t *body = NULL;
        uint8_t *mout = NULL;
        size_t mlen = 0;

        body = enc_stat(".git/objects", &blen);
        if (!body)
            return 1;
        if (ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4) {
            fprintf(stderr, "mount stat .git/objects failed\n");
            return 1;
        }
        free(body);
        if (rd_i32(mout) != GE_TEST_ENOENT) {
            fprintf(stderr, "K17: stat .git/objects expected ENOENT(%d), got %d\n", GE_TEST_ENOENT,
                    (int)rd_i32(mout));
            free(mout);
            return 1;
        }
        free(mout);

        blen = 0;
        body = enc_open(".git/objects", &blen);
        if (!body)
            return 1;
        if (ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4) {
            fprintf(stderr, "mount open .git/objects failed\n");
            return 1;
        }
        free(body);
        if (rd_i32(mout) != GE_TEST_ENOENT) {
            fprintf(stderr, "K17: open .git/objects expected ENOENT(%d), got %d\n", GE_TEST_ENOENT,
                    (int)rd_i32(mout));
            free(mout);
            return 1;
        }
        free(mout);

        blen = 0;
        body = enc_open(".git/objects/pack", &blen);
        if (!body)
            return 1;
        if (ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4) {
            fprintf(stderr, "mount open .git/objects/pack failed\n");
            return 1;
        }
        free(body);
        if (rd_i32(mout) != GE_TEST_ENOENT) {
            fprintf(stderr, "K17: open .git/objects/pack expected ENOENT(%d), got %d\n",
                    GE_TEST_ENOENT, (int)rd_i32(mout));
            free(mout);
            return 1;
        }
        free(mout);

        blen = 0;
        body = enc_readdir(".git", &blen);
        if (!body)
            return 1;
        if (ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4) {
            fprintf(stderr, "mount readdir .git failed\n");
            return 1;
        }
        free(body);
        if (rd_i32(mout) != 0) {
            fprintf(stderr, "K17: readdir .git status non-zero: %d\n", (int)rd_i32(mout));
            free(mout);
            return 1;
        }
        /* Payload is dirent stream; names must not include "objects". */
        if (mlen > 4) {
            /* crude scan for the name "objects" as a path component token */
            for (size_t i = 4; i + 7 <= mlen; i++) {
                if (mout[i] == 'o' && i + 7 <= mlen && memcmp(mout + i, "objects", 7) == 0) {
                    /* require word boundary-ish: preceded by len field likely, but reject any hit
                     */
                    fprintf(stderr, "K17: readdir .git must not list objects\n");
                    free(mout);
                    return 1;
                }
            }
        }
        free(mout);
    }

    /* Positive allowlist: direct open/stat of physical `.git/**` paths
     * (config, index, logs, packed-refs, loose refs) must not fall through. */
    {
        const char *forbidden[] = {
            ".git/config",
            ".git/index",
            ".git/packed-refs",
            ".git/logs/HEAD",
            ".git/refs/heads/master",
            ".git/info/exclude",
            ".git/description",
            ".git/mc/unknown",
            ".git/mc/out/other",
            NULL,
        };
        for (int i = 0; forbidden[i]; i++) {
            size_t blen = 0;
            uint8_t *body = enc_open(forbidden[i], &blen);
            if (expect_mount_status(e, body, blen, GE_TEST_ENOENT, "synthetic git open"))
                return 1;
            blen = 0;
            body = enc_stat(forbidden[i], &blen);
            if (expect_mount_status(e, body, blen, GE_TEST_ENOENT, "synthetic git stat"))
                return 1;
        }
        /* Allowlisted synthetic paths still succeed. */
        {
            size_t blen = 0;
            uint8_t *body = enc_open(".git/HEAD", &blen);
            uint8_t *mout = NULL;
            size_t mlen = 0;
            if (!body || ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4 ||
                rd_i32(mout) != 0) {
                fprintf(stderr, "open .git/HEAD must succeed\n");
                free(body);
                free(mout);
                return 1;
            }
            free(body);
            free(mout);
        }
        {
            size_t blen = 0;
            uint8_t *body = enc_stat(".git/mc/ctl", &blen);
            uint8_t *mout = NULL;
            size_t mlen = 0;
            if (!body || ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4 ||
                rd_i32(mout) != 0) {
                fprintf(stderr, "stat .git/mc/ctl must succeed\n");
                free(body);
                free(mout);
                return 1;
            }
            free(body);
            free(mout);
        }
    }

    /* Every real worktree operation fails closed when any path
     * component is a symlink. The outside sentinel must remain untouched. */
    {
        char outside_tmpl[] = "/tmp/ge-port-outside-XXXXXX";
        char *outside = mkdtemp(outside_tmpl);
        if (!outside) {
            perror("mkdtemp outside");
            return 1;
        }
        char sentinel[4096], link_path[4096], escaped[4096];
        snprintf(sentinel, sizeof(sentinel), "%s/sentinel.txt", outside);
        snprintf(link_path, sizeof(link_path), "%s/escape", root);
        snprintf(escaped, sizeof(escaped), "%s/pwn.txt", outside);
        FILE *sf = fopen(sentinel, "wb");
        if (!sf || fwrite("safe\n", 1, 5, sf) != 5 || fclose(sf) != 0) {
            fprintf(stderr, "cannot create outside sentinel\n");
            return 1;
        }
        if (symlink(outside, link_path) != 0) {
            perror("symlink outside");
            return 1;
        }

        size_t blen = 0;
#define EXPECT_EACCES(request_expr, label)                                                         \
    do {                                                                                           \
        blen = 0;                                                                                  \
        uint8_t *request_body = (request_expr);                                                    \
        if (expect_mount_status(e, request_body, blen, GE_TEST_EACCES, (label)))                   \
            return 1;                                                                              \
    } while (0)

        EXPECT_EACCES(enc_open("escape/sentinel.txt", &blen), "symlink open");
        EXPECT_EACCES(enc_stat("escape/sentinel.txt", &blen), "symlink stat");
        EXPECT_EACCES(enc_readdir("escape", &blen), "symlink readdir");
        EXPECT_EACCES(enc_mount(6, "escape/pwn.txt", "", (const uint8_t *)"owned", 5, &blen),
                      "symlink write");
        EXPECT_EACCES(enc_mount(2, "escape/newdir", "", NULL, 0, &blen), "symlink mkdir");
        EXPECT_EACCES(enc_mount(3, "escape/sentinel.txt", "", NULL, 0, &blen), "symlink unlink");
        EXPECT_EACCES(enc_mount(4, "a.txt", "escape/moved", NULL, 0, &blen),
                      "symlink rename destination");
        EXPECT_EACCES(enc_mount(4, "escape/sentinel.txt", "moved", NULL, 0, &blen),
                      "symlink rename source");
#undef EXPECT_EACCES

        if (access(sentinel, F_OK) != 0 || access(escaped, F_OK) == 0) {
            fprintf(stderr, "symlink containment changed outside files\n");
            return 1;
        }
        char outside_dir[4096];
        snprintf(outside_dir, sizeof(outside_dir), "%s/newdir", outside);
        if (access(outside_dir, F_OK) == 0) {
            fprintf(stderr, "symlink mkdir escaped worktree\n");
            return 1;
        }

        unlink(link_path);
        unlink(sentinel);
        rmdir(outside);
    }

    /* A large file open is rejected without poisoning the engine. */
    {
        char large[4096];
        snprintf(large, sizeof(large), "%s/large.bin", root);
        FILE *f = fopen(large, "wb");
        if (!f || ftruncate(fileno(f), 16 * 1024 * 1024 + 1) != 0 || fclose(f) != 0)
            return 1;
        size_t blen = 0;
        uint8_t *body = enc_open("large.bin", &blen);
        if (expect_mount_status(e, body, blen, GE_TEST_EINVAL, "large open"))
            return 1;
        RUN("{\"op\":\"status\"}");
        unlink(large);
    }

    ge_close(e);
    /* Subsequent Run after close fails closed */
    if (ge_run_json(NULL, "{\"op\":\"status\"}") == NULL) {
        /* null engine returns usage JSON, not NULL — check */
    }
    char *dead = ge_run_json(NULL, "{\"op\":\"status\"}");
    if (!dead || !strstr(dead, "null engine")) {
        fprintf(stderr, "expected null engine fail-closed, got %s\n", dead ? dead : "(null)");
        return 1;
    }
    ge_free(dead);

    fclose(pipe_ab);
    fclose(pipe_ba);
    fprintf(stdout, "port_frame_test SUCCESS\n");
    return 0;
}
