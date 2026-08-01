/* Port frame smoke: Run init→commit + mount ctl + kill-closed semantics (GIT.md PR7a/b). */

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

static int32_t rd_i32(const uint8_t *p) {
  return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
                   ((uint32_t)p[3] << 24));
}

/* AgentOS contract ENOENT (constants.kdl → gen). */
enum { GE_TEST_ENOENT = 44 };

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
#define RUN(json)                                                                 \
  do {                                                                            \
    rewind(pipe_ab);                                                              \
    ftruncate(fileno(pipe_ab), 0);                                                \
    rewind(pipe_ba);                                                              \
    ftruncate(fileno(pipe_ba), 0);                                                \
    if (write_run(pipe_ab, (json)) != 0)                                          \
      return 1;                                                                   \
    rewind(pipe_ab);                                                              \
    uint8_t t = 0;                                                                \
    uint8_t *p = NULL;                                                            \
    size_t pl = 0;                                                                \
    if (ge_frame_read(pipe_ab, &t, &p, &pl) != 0)                                 \
      return 1;                                                                   \
    if (ge_port_handle(e, t, p, pl, pipe_ba) != 0)                                \
      return 1;                                                                   \
    free(p);                                                                      \
    rewind(pipe_ba);                                                              \
    char *resp = read_run_json(pipe_ba);                                          \
    if (!resp || strstr(resp, "\"ok\":false") || strstr(resp, "\"ok\": false")) { \
      fprintf(stderr, "FAIL run %s → %s\n", (json), resp ? resp : "(null)");      \
      free(resp);                                                                 \
      return 1;                                                                   \
    }                                                                             \
    free(resp);                                                                   \
  } while (0)

  RUN("{\"op\":\"init\"}");
  RUN("{\"op\":\"write\",\"args\":{\"path\":\"a.txt\",\"content\":\"hi\\n\"}}");
  RUN("{\"op\":\"add\",\"args\":{\"path\":\"a.txt\"}}");
  RUN("{\"op\":\"commit\",\"args\":{\"message\":\"c\",\"name\":\"T\",\"email\":\"t@t\",\"when_unix\":1700000000}}");

  /* Type-4 mount: ctl status */
  {
    const char *req = "{\"op\":\"status\",\"args\":{\"short\":true}}";
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
    body = enc_open(".git/mc/ctl", &blen);
    if (ge_mount_dispatch(e, body, blen, &mout, &mlen) != 0 || !mout || mlen < 4) {
      fprintf(stderr, "mount open ctl failed\n");
      return 1;
    }
    free(body);
    /* status 0 */
    if (mout[0] | mout[1] | mout[2] | mout[3]) {
      fprintf(stderr, "mount open status non-zero\n");
      return 1;
    }
    if (!strstr((char *)mout + 4, "\"ok\"")) {
      fprintf(stderr, "ctl response missing ok: %.*s\n", (int)(mlen - 4), (char *)mout + 4);
      return 1;
    }
    free(mout);
  }

  /* K17: no `.git/objects` façade — open/stat ENOENT; readdir .git omits objects. */
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
          /* require word boundary-ish: preceded by len field likely, but reject any hit */
          fprintf(stderr, "K17: readdir .git must not list objects\n");
          free(mout);
          return 1;
        }
      }
    }
    free(mout);
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
  fprintf(stdout, "port_smoke_test SUCCESS\n");
  return 0;
}
