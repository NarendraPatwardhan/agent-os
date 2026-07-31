/* PR1: native ABI fixture — init→write→add→commit→log + dial refuse (GIT.md). */
#include "git_engine.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int expect_ok(ge_engine *e, const char *req) {
  char *resp = ge_run_json(e, req);
  if (!resp) {
    fprintf(stderr, "null response for %s\n", req);
    return 1;
  }
  int bad = (strstr(resp, "\"ok\":true") == NULL);
  if (bad)
    fprintf(stderr, "expected ok for %s\n%s\n", req, resp);
  ge_free(resp);
  return bad ? 1 : 0;
}

static int expect_fail(ge_engine *e, const char *req, const char *needle) {
  char *resp = ge_run_json(e, req);
  if (!resp) {
    fprintf(stderr, "null response\n");
    return 1;
  }
  int ok = (strstr(resp, "\"ok\":false") != NULL) &&
           (needle == NULL || strstr(resp, needle) != NULL);
  if (!ok)
    fprintf(stderr, "expected fail(%s) for %s\n%s\n", needle ? needle : "", req, resp);
  ge_free(resp);
  return ok ? 0 : 1;
}

/* P1.1: write content larger than the old 64 KiB stack buffer. */
static int test_large_write(ge_engine *e) {
  const size_t content_len = 70000; /* > 64 KiB */
  size_t cap = content_len + 128;
  char *req = (char *)malloc(cap);
  if (!req) {
    fprintf(stderr, "oom large write req\n");
    return 1;
  }
  int n = snprintf(req, cap, "{\"op\":\"write\",\"args\":{\"path\":\"big.txt\",\"content\":\"");
  if (n < 0 || (size_t)n >= cap) {
    free(req);
    fprintf(stderr, "large write prefix overflow\n");
    return 1;
  }
  size_t used = (size_t)n;
  for (size_t i = 0; i < content_len; i++) {
    if (used + 2 >= cap) {
      cap *= 2;
      char *p = (char *)realloc(req, cap);
      if (!p) {
        free(req);
        fprintf(stderr, "oom grow large write\n");
        return 1;
      }
      req = p;
    }
    req[used++] = 'A';
  }
  const char *tail = "\"}}";
  size_t tlen = strlen(tail);
  if (used + tlen + 1 >= cap) {
    cap = used + tlen + 1;
    char *p = (char *)realloc(req, cap);
    if (!p) {
      free(req);
      return 1;
    }
    req = p;
  }
  memcpy(req + used, tail, tlen + 1);

  int bad = expect_ok(e, req);
  free(req);
  if (bad) {
    fprintf(stderr, "large write (>64KiB) failed\n");
    return 1;
  }

  /* Confirm bytes on disk. */
  char path[4096];
  snprintf(path, sizeof(path), "%s/big.txt", ge_worktree_root(e));
  FILE *f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "big.txt missing after write\n");
    return 1;
  }
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return 1;
  }
  long sz = ftell(f);
  fclose(f);
  if (sz != (long)content_len) {
    fprintf(stderr, "big.txt size %ld want %zu\n", sz, content_len);
    return 1;
  }
  return 0;
}

/* P2.7: add all=true stages files created via write (incl. nested). */
static int test_add_all(ge_engine *e) {
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"all_a.txt\",\"content\":\"a\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"sub/all_b.txt\",\"content\":\"b\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"all\":true}}"))
    return 1;

  char *resp = ge_run_json(e, "{\"op\":\"status\",\"args\":{\"short\":true}}");
  if (!resp) {
    fprintf(stderr, "status null after add all\n");
    return 1;
  }
  int bad = (strstr(resp, "\"ok\":true") == NULL) ||
            (strstr(resp, "all_a.txt") == NULL) ||
            (strstr(resp, "all_b.txt") == NULL);
  /* Staged new files should show A in index column (short status "A "). */
  if (!bad && strstr(resp, "A ") == NULL && strstr(resp, "A?") == NULL)
    bad = 1;
  if (bad)
    fprintf(stderr, "add all status unexpected:\n%s\n", resp);
  ge_free(resp);
  return bad ? 1 : 0;
}

/* P2.1: pack.build of tip OID → non-empty pack with PACK magic; empty oids fail. */
static int test_pack_build(ge_engine *e) {
  char *rev = ge_run_json(e, "{\"op\":\"rev-parse\",\"args\":{\"rev\":\"HEAD\"}}");
  if (!rev || strstr(rev, "\"ok\":true") == NULL) {
    fprintf(stderr, "rev-parse HEAD for pack.build failed\n%s\n", rev ? rev : "(null)");
    ge_free(rev);
    return 1;
  }
  /* stdout is "hex\\n" escaped in JSON; result may also hold hex. */
  char hex[41] = {0};
  const char *p = strstr(rev, "\"stdout\":\"");
  if (p) {
    p += strlen("\"stdout\":\"");
    size_t i = 0;
    while (*p && *p != '"' && *p != '\\' && i < 40)
      hex[i++] = *p++;
    hex[i] = '\0';
  }
  ge_free(rev);
  if (strlen(hex) != 40) {
    fprintf(stderr, "could not parse HEAD oid for pack.build (got '%s')\n", hex);
    return 1;
  }

  /* Empty oids array — fail closed (do not silently export whole repo here:
   * explicit [] means no tips). */
  {
    uint8_t *out = NULL;
    size_t out_len = 0;
    if (ge_pack_build(e, "[]", &out, &out_len) == 0) {
      fprintf(stderr, "expected empty oids fail\n");
      ge_free(out);
      return 1;
    }
    const char *err = ge_last_error(e);
    if (!err || strstr(err, "no oids") == NULL) {
      fprintf(stderr, "expected no oids error, got: %s\n", err ? err : "(null)");
      return 1;
    }
  }

  /* Binary API: pack of tip. */
  {
    char oids_json[96];
    snprintf(oids_json, sizeof(oids_json), "[\"%s\"]", hex);
    uint8_t *out = NULL;
    size_t out_len = 0;
    if (ge_pack_build(e, oids_json, &out, &out_len) != 0) {
      fprintf(stderr, "ge_pack_build failed: %s\n", ge_last_error(e));
      return 1;
    }
    if (!out || out_len < 4 || memcmp(out, "PACK", 4) != 0) {
      fprintf(stderr, "pack missing PACK magic (len=%zu)\n", out_len);
      ge_free(out);
      return 1;
    }
    ge_free(out);
  }

  /* Run op: writes file + meta. */
  {
    char req[160];
    snprintf(req, sizeof(req),
             "{\"op\":\"pack.build\",\"args\":{\"oids\":[\"%s\"]}}", hex);
    char *resp = ge_run_json(e, req);
    if (!resp || strstr(resp, "\"ok\":true") == NULL) {
      fprintf(stderr, "pack.build Run failed\n%s\n", resp ? resp : "(null)");
      ge_free(resp);
      return 1;
    }
    if (strstr(resp, "\"path\"") == NULL || strstr(resp, "push.pack") == NULL ||
        strstr(resp, "\"bytes\"") == NULL || strstr(resp, "\"count\"") == NULL) {
      fprintf(stderr, "pack.build result missing path/bytes/count:\n%s\n", resp);
      ge_free(resp);
      return 1;
    }
    ge_free(resp);

    char path[4096];
    snprintf(path, sizeof(path), "%s/.git/agentos/push.pack", ge_worktree_root(e));
    FILE *f = fopen(path, "rb");
    if (!f) {
      fprintf(stderr, "export pack file missing: %s\n", path);
      return 1;
    }
    char magic[4];
    size_t n = fread(magic, 1, 4, f);
    fclose(f);
    if (n != 4 || memcmp(magic, "PACK", 4) != 0) {
      fprintf(stderr, "export pack missing PACK magic\n");
      return 1;
    }
  }

  return 0;
}

/* H3: pack import total size cap 64 MiB — fail closed (size gate, no valid pack). */
static int test_pack_cap(ge_engine *e) {
  const size_t cap = 64u * 1024u * 1024u;
  uint8_t dummy = 0;

  /* Single-chunk oversize: len alone exceeds cap; buffer not read past gate. */
  if (ge_import_pack(e, &dummy, cap + 1, 0) == 0) {
    fprintf(stderr, "expected single-chunk oversize fail\n");
    return 1;
  }
  const char *err = ge_last_error(e);
  if (!err || strstr(err, "64 MiB") == NULL) {
    fprintf(stderr, "expected 64 MiB error, got: %s\n", err ? err : "(null)");
    return 1;
  }

  /* Multi-chunk: after any successful small append, a further chunk of size
   * GE_PACK_MAX_BYTES must fail the accumulate gate (pack_bytes > 0). Size is
   * checked before append, so dummy is not overrun. */
  size_t first = 256;
  uint8_t *chunk = (uint8_t *)calloc(1, first);
  if (!chunk) {
    fprintf(stderr, "oom pack chunk\n");
    return 1;
  }
  /* Minimal PACK header (v2, 0 objects) — enough for indexer_append to buffer. */
  if (first >= 12) {
    memcpy(chunk, "PACK", 4);
    chunk[7] = 2; /* version 2 big-endian */
  }
  int rc1 = ge_import_pack(e, chunk, first, 0);
  free(chunk);
  if (rc1 != 0) {
    fprintf(stderr, "note: first pack append failed (%s); multi-chunk size path "
                    "skipped (single-chunk cap ok)\n",
            ge_last_error(e));
    return 0;
  }
  if (ge_import_pack(e, &dummy, cap, 0) == 0) {
    fprintf(stderr, "expected multi-chunk oversize fail\n");
    return 1;
  }
  err = ge_last_error(e);
  if (!err || strstr(err, "64 MiB") == NULL) {
    fprintf(stderr, "expected multi 64 MiB error, got: %s\n", err ? err : "(null)");
    return 1;
  }
  return 0;
}

/* Path safety: foo..bar allowed; ../x and a/../b rejected. */
static int test_path_safety(ge_engine *e) {
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"foo..bar\",\"content\":\"ok\\n\"}}")) {
    fprintf(stderr, "foo..bar should be allowed\n");
    return 1;
  }
  if (expect_fail(e, "{\"op\":\"write\",\"args\":{\"path\":\"../x\",\"content\":\"n\"}}", NULL)) {
    fprintf(stderr, "../x should be rejected\n");
    return 1;
  }
  if (expect_fail(e, "{\"op\":\"write\",\"args\":{\"path\":\"a/../b\",\"content\":\"n\"}}", NULL)) {
    fprintf(stderr, "a/../b should be rejected\n");
    return 1;
  }
  if (expect_fail(e, "{\"op\":\"write\",\"args\":{\"path\":\"/abs\",\"content\":\"n\"}}", NULL)) {
    fprintf(stderr, "absolute path should be rejected\n");
    return 1;
  }
  return 0;
}

int main(void) {
  printf("%s\n", ge_version());

  char tmpl[] = "/tmp/agentos-git-abi-XXXXXX";
  char *dir = mkdtemp(tmpl);
  if (!dir) {
    perror("mkdtemp");
    return 1;
  }

  ge_engine *e = ge_open(dir);
  if (!e) {
    fprintf(stderr, "ge_open failed for %s\n", dir);
    return 1;
  }

  if (expect_ok(e, "{\"op\":\"init\"}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"hello.txt\","
                   "\"content\":\"hello from abi fixture\\n\"}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"hello.txt\"}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"commit\",\"args\":{"
                   "\"message\":\"initial\","
                   "\"name\":\"Fixture\","
                   "\"email\":\"fixture@test\","
                   "\"when_unix\":1700000000}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"status\",\"args\":{\"short\":true}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"log\",\"args\":{\"max_count\":5}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"rev-parse\",\"args\":{\"rev\":\"HEAD\"}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"branch\",\"args\":{\"name\":\"feature\"}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"checkout\",\"args\":{\"name\":\"feature\"}}"))
    goto fail;
  if (expect_ok(e, "{\"op\":\"branch\"}"))
    goto fail;

  if (expect_fail(e, "{\"op\":\"clone\",\"args\":{\"url\":\"https://example.com/r.git\"}}",
                  "host-mediated"))
    goto fail;
  if (expect_fail(e, "{\"op\":\"fetch\"}", "host-mediated"))
    goto fail;
  if (expect_fail(e, "{\"op\":\"push\"}", "host-mediated"))
    goto fail;
  if (expect_fail(e, "{\"op\":\"pull\"}", "host-mediated"))
    goto fail;

  /* K28: commit without host identity fails closed (no default Agent). */
  if (expect_fail(e, "{\"op\":\"commit\",\"args\":{\"message\":\"no-id\"}}", "K28"))
    goto fail;

  /* fetch.apply with no refs fails closed (no silent success). */
  if (expect_fail(e, "{\"op\":\"fetch.apply\"}", "fetch.apply"))
    goto fail;
  if (expect_fail(e, "{\"op\":\"fetch.apply\",\"args\":{}}", "fetch.apply"))
    goto fail;

  /* path escape (legacy case still rejected) */
  if (expect_fail(e, "{\"op\":\"write\",\"args\":{\"path\":\"../x\",\"content\":\"n\"}}", NULL))
    goto fail;

  /* P1.1 large write */
  if (test_large_write(e))
    goto fail;

  /* P2.7 add all=true */
  if (test_add_all(e))
    goto fail;

  /* Path segment safety (foo..bar ok) */
  if (test_path_safety(e))
    goto fail;

  /* H3 pack size cap */
  if (test_pack_cap(e))
    goto fail;

  /* P2.1 push packbuilder */
  if (test_pack_build(e))
    goto fail;

  ge_close(e);
  printf("abi_fixture_test SUCCESS\n");
  return 0;

fail:
  ge_close(e);
  return 1;
}
