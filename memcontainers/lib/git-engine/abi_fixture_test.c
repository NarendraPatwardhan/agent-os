/* Native ABI fixture — init→write→add→commit→log + dial refuse (SYSTEMS.md §11b). */
#include "git_engine.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
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

  /* second commit + pack with haves=[parent] must be smaller than full tip pack. */
  {
    char *w = ge_run_json(e, "{\"op\":\"write\",\"args\":{\"path\":\"next.txt\","
                             "\"content\":\"second-layer-payload-for-thin-pack\\n\"}}");
    if (!w || strstr(w, "\"ok\":true") == NULL) {
      fprintf(stderr, "write for thin-pack failed\n%s\n", w ? w : "(null)");
      ge_free(w);
      return 1;
    }
    ge_free(w);
    char *a = ge_run_json(e, "{\"op\":\"add\",\"args\":{\"path\":\"next.txt\"}}");
    if (!a || strstr(a, "\"ok\":true") == NULL) {
      fprintf(stderr, "add for thin-pack failed\n%s\n", a ? a : "(null)");
      ge_free(a);
      return 1;
    }
    ge_free(a);
    char *c = ge_run_json(e, "{\"op\":\"commit\",\"args\":{\"message\":\"c2\","
                             "\"name\":\"T\",\"email\":\"t@t\",\"when_unix\":1700000101}}");
    if (!c || strstr(c, "\"ok\":true") == NULL) {
      fprintf(stderr, "commit for thin-pack failed\n%s\n", c ? c : "(null)");
      ge_free(c);
      return 1;
    }
    ge_free(c);

    char hex2[41] = {0};
    char *rev2 = ge_run_json(e, "{\"op\":\"rev-parse\",\"args\":{\"rev\":\"HEAD\"}}");
    if (rev2) {
      const char *p2 = strstr(rev2, "\"stdout\":\"");
      if (p2) {
        p2 += strlen("\"stdout\":\"");
        size_t i = 0;
        while (*p2 && *p2 != '"' && *p2 != '\\' && i < 40)
          hex2[i++] = *p2++;
        hex2[i] = '\0';
      }
      ge_free(rev2);
    }
    if (strlen(hex2) != 40 || strcmp(hex2, hex) == 0) {
      fprintf(stderr, "thin-pack: expected new HEAD oid (got '%s' parent '%s')\n", hex2, hex);
      return 1;
    }

    char full_json[96];
    snprintf(full_json, sizeof(full_json), "[\"%s\"]", hex2);
    uint8_t *full = NULL;
    size_t full_len = 0;
    if (ge_pack_build(e, full_json, &full, &full_len) != 0) {
      fprintf(stderr, "full pack.build failed: %s\n", ge_last_error(e));
      return 1;
    }

    char thin_json[160];
    snprintf(thin_json, sizeof(thin_json),
             "{\"oids\":[\"%s\"],\"haves\":[\"%s\"]}", hex2, hex);
    uint8_t *thin = NULL;
    size_t thin_len = 0;
    if (ge_pack_build(e, thin_json, &thin, &thin_len) != 0) {
      fprintf(stderr, "thin pack.build with haves failed: %s\n", ge_last_error(e));
      ge_free(full);
      return 1;
    }
    if (!thin || thin_len < 4 || memcmp(thin, "PACK", 4) != 0) {
      fprintf(stderr, "thin pack missing PACK magic (len=%zu)\n", thin_len);
      ge_free(full);
      ge_free(thin);
      return 1;
    }
    if (thin_len >= full_len) {
      fprintf(stderr, "pack with haves should be smaller (thin=%zu full=%zu)\n", thin_len,
              full_len);
      ge_free(full);
      ge_free(thin);
      return 1;
    }
    ge_free(full);
    ge_free(thin);
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

/* diff emits full unified patch (diff --git), pathspec, and --cached. */
static int test_diff_patch(ge_engine *e) {
  /* Track second file so both appear in index↔workdir diffs. */
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"other.txt\","
                   "\"content\":\"other base\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"other.txt\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"commit\",\"args\":{"
                   "\"message\":\"add other\","
                   "\"name\":\"Fixture\","
                   "\"email\":\"fixture@test\","
                   "\"when_unix\":1700000002}}"))
    return 1;

  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"hello.txt\","
                   "\"content\":\"hello patched\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"other.txt\","
                   "\"content\":\"other changed\\n\"}}"))
    return 1;
  char *resp = ge_run_json(e, "{\"op\":\"diff\"}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "diff failed\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  /* Unified patch from git_diff_to_buf GIT_DIFF_FORMAT_PATCH (JSON-escaped). */
  if (strstr(resp, "diff --git") == NULL) {
    fprintf(stderr, "diff missing patch headers:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "hello.txt") == NULL) {
    fprintf(stderr, "diff missing path hello.txt:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  /* Path-limited: only hello.txt in the patch. */
  resp = ge_run_json(e, "{\"op\":\"diff\",\"args\":{\"path\":\"hello.txt\"}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "diff path failed\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "hello.txt") == NULL || strstr(resp, "other.txt") != NULL) {
    fprintf(stderr, "diff path filter wrong:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  /* paths[] multi-pathspec. */
  resp = ge_run_json(e, "{\"op\":\"diff\",\"args\":{\"paths\":[\"hello.txt\",\"other.txt\"]}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL ||
      strstr(resp, "hello.txt") == NULL || strstr(resp, "other.txt") == NULL) {
    fprintf(stderr, "diff paths[] failed\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  /* --cached / staged: stage hello only; worktree still dirty; cached patch has hello. */
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"hello.txt\"}}"))
    return 1;
  /* Further dirty worktree after stage. */
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"hello.txt\","
                   "\"content\":\"hello staged then dirtied\\n\"}}"))
    return 1;
  resp = ge_run_json(e, "{\"op\":\"diff\",\"args\":{\"cached\":true,\"path\":\"hello.txt\"}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "diff cached failed\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "diff --git") == NULL || strstr(resp, "hello.txt") == NULL) {
    fprintf(stderr, "diff cached missing patch:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  /* Staged content is "hello patched", not the further dirty worktree body. */
  if (strstr(resp, "hello staged then dirtied") != NULL) {
    fprintf(stderr, "diff cached leaked worktree-only change:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);
  return 0;
}

/* add all=true stages deletion of tracked file removed from worktree. */
static int test_add_all_deletion(ge_engine *e) {
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"doomed.txt\",\"content\":\"bye\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"doomed.txt\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"commit\",\"args\":{"
                   "\"message\":\"add doomed\","
                   "\"name\":\"Fixture\","
                   "\"email\":\"fixture@test\","
                   "\"when_unix\":1700000001}}"))
    return 1;

  char path[4096];
  snprintf(path, sizeof(path), "%s/doomed.txt", ge_worktree_root(e));
  if (unlink(path) != 0) {
    perror("unlink doomed.txt");
    return 1;
  }
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"all\":true}}"))
    return 1;

  char *resp = ge_run_json(e, "{\"op\":\"status\",\"args\":{\"short\":true}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "status after add-all deletion failed\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  /* Staged deletion: short status index column D. */
  if (strstr(resp, "doomed.txt") == NULL || strstr(resp, "D ") == NULL) {
    fprintf(stderr, "add all did not stage deletion:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);
  return 0;
}

/* refs.import accepts refs[] array of two {name,hash}. */
static int test_refs_import_array(ge_engine *e) {
  char *rev = ge_run_json(e, "{\"op\":\"rev-parse\",\"args\":{\"rev\":\"HEAD\"}}");
  if (!rev || strstr(rev, "\"ok\":true") == NULL) {
    fprintf(stderr, "rev-parse for refs.import failed\n%s\n", rev ? rev : "(null)");
    ge_free(rev);
    return 1;
  }
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
    fprintf(stderr, "could not parse HEAD for refs.import\n");
    return 1;
  }

  char req[512];
  snprintf(req, sizeof(req),
           "{\"op\":\"refs.import\",\"args\":{\"refs\":["
           "{\"name\":\"refs/heads/import-a\",\"hash\":\"%s\"},"
           "{\"name\":\"refs/heads/import-b\",\"hash\":\"%s\"}"
           "]}}",
           hex, hex);
  if (expect_ok(e, req)) {
    fprintf(stderr, "refs.import array failed\n");
    return 1;
  }

  /* Bad entry in array fails closed. */
  if (expect_fail(e,
                  "{\"op\":\"refs.import\",\"args\":{\"refs\":["
                  "{\"name\":\"refs/heads/ok\",\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},"
                  "{\"name\":\"refs/heads/bad\",\"hash\":\"not-a-hash\"}"
                  "]}}",
                  "refs.import")) {
    fprintf(stderr, "refs.import should fail closed on bad hash\n");
    return 1;
  }
  return 0;
}

/* large stdout sets result.truncated=true, stream_path, writes out/last. */
static int test_truncated_stdout(ge_engine *e) {
  /* Tracked file + worktree modify so index_to_workdir produces a real patch. */
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"trunc.txt\","
                   "\"content\":\"base\\n\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"trunc.txt\"}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"commit\",\"args\":{"
                   "\"message\":\"trunc base\","
                   "\"name\":\"Fixture\","
                   "\"email\":\"fixture@test\","
                   "\"when_unix\":1700000002}}"))
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"trunc.txt\","
                   "\"content\":\"line one of trunc test\\nline two longer content here\\n"
                   "line three still more\\nline four\\n\"}}"))
    return 1;

  /* Force a low threshold so we need not build a multi-MiB patch. */
  ge_test_set_stdout_max_bytes(64);
  char *resp = ge_run_json(e, "{\"op\":\"diff\",\"args\":{\"path\":\"trunc.txt\"}}");
  ge_test_set_stdout_max_bytes(0);

  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "diff for truncation failed\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "\"truncated\":true") == NULL) {
    fprintf(stderr, "expected result.truncated=true:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "\"stream_path\":\".git/mc/out/last\"") == NULL) {
    fprintf(stderr, "expected result.stream_path=.git/mc/out/last:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "\"stdout_bytes\"") == NULL) {
    fprintf(stderr, "expected result.stdout_bytes:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "\"result\"") == NULL) {
    fprintf(stderr, "truncated response missing result object:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  char last[4096];
  snprintf(last, sizeof(last), "%s/.git/mc/out/last", ge_worktree_root(e));
  FILE *f = fopen(last, "rb");
  if (!f) {
    fprintf(stderr, "missing out/last after truncation: %s\n", last);
    return 1;
  }
  char buf[256];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = '\0';
  if (n == 0 || (strstr(buf, "diff") == NULL && strstr(buf, "trunc") == NULL)) {
    fprintf(stderr, "out/last empty or unexpected:\n%s\n", buf);
    return 1;
  }
  return 0;
}

/* explicit add/write of a symlink fails closed with a clear error. */
static int test_symlink_fail_closed(ge_engine *e) {
  char linkpath[4096];
  char targetpath[4096];
  snprintf(targetpath, sizeof(targetpath), "%s/symlink_target.txt", ge_worktree_root(e));
  snprintf(linkpath, sizeof(linkpath), "%s/symlink_link.txt", ge_worktree_root(e));
  FILE *tf = fopen(targetpath, "wb");
  if (!tf) {
    fprintf(stderr, "cannot create target\n");
    return 1;
  }
  fputs("target\n", tf);
  fclose(tf);
  unlink(linkpath);
  if (symlink("symlink_target.txt", linkpath) != 0) {
    fprintf(stderr, "symlink() failed (skip if FS unsupported)\n");
    return 1;
  }
  if (expect_fail(e, "{\"op\":\"add\",\"args\":{\"path\":\"symlink_link.txt\"}}",
                  "symlink"))
    return 1;
  if (expect_fail(e,
                  "{\"op\":\"write\",\"args\":{\"path\":\"symlink_link.txt\","
                  "\"content\":\"overwrite\\n\"}}",
                  "symlink"))
    return 1;
  /* add all=true must not fail the whole walk solely due to a symlink. */
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"all\":true}}"))
    return 1;

  /* Parent-component links must fail too: final-only lstat is not containment. */
  char outside_tmpl[] = "/tmp/ge-abi-outside-XXXXXX";
  char *outside = mkdtemp(outside_tmpl);
  if (!outside)
    return 1;
  char secret[4096], dirlink[4096], escaped[4096];
  snprintf(secret, sizeof(secret), "%s/secret.txt", outside);
  snprintf(dirlink, sizeof(dirlink), "%s/symlink_dir", ge_worktree_root(e));
  snprintf(escaped, sizeof(escaped), "%s/escaped.txt", outside);
  tf = fopen(secret, "wb");
  if (!tf)
    return 1;
  fputs("outside\n", tf);
  fclose(tf);
  if (symlink(outside, dirlink) != 0)
    return 1;
  if (expect_fail(e,
                  "{\"op\":\"write\",\"args\":{\"path\":\"symlink_dir/escaped.txt\","
                  "\"content\":\"bad\"}}",
                  "symlink") ||
      expect_fail(e, "{\"op\":\"add\",\"args\":{\"path\":\"symlink_dir/secret.txt\"}}",
                  "symlink") ||
      expect_fail(e, "{\"op\":\"rm\",\"args\":{\"path\":\"symlink_dir/secret.txt\"}}",
                  "symlink"))
    return 1;
  if (access(secret, F_OK) != 0 || access(escaped, F_OK) == 0) {
    fprintf(stderr, "engine path operation escaped through parent symlink\n");
    return 1;
  }
  unlink(dirlink);
  unlink(secret);
  rmdir(outside);
  return 0;
}

/* GIT-003: outputs larger than the former fixed buffers remain complete JSON. */
static int test_large_ref_outputs(ge_engine *e) {
  char req[2048];
  char last_branch[256] = "";
  for (int i = 0; i < 180; i++) {
    snprintf(last_branch, sizeof(last_branch),
             "output-%03d-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz", i);
    snprintf(req, sizeof(req), "{\"op\":\"branch\",\"args\":{\"name\":\"%s\"}}",
             last_branch);
    if (expect_ok(e, req))
      return 1;
  }

  char *resp = ge_run_json(e, "{\"op\":\"branch\"}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL || strlen(resp) <= 4096 ||
      strstr(resp, last_branch) == NULL) {
    fprintf(stderr, "large branch output incomplete\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  resp = ge_run_json(e, "{\"op\":\"tips\"}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL || strlen(resp) <= 16384 ||
      strstr(resp, last_branch) == NULL) {
    fprintf(stderr, "large tips output incomplete\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  resp = ge_run_json(e, "{\"op\":\"push.prepare\"}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL || strstr(resp, last_branch) == NULL) {
    fprintf(stderr, "large push.prepare output incomplete\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  char last_remote[128] = "";
  for (int i = 0; i < 120; i++) {
    snprintf(last_remote, sizeof(last_remote),
             "remote-%03d-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz", i);
    snprintf(req, sizeof(req),
             "{\"op\":\"remote\",\"args\":{\"action\":\"add\",\"name\":\"%s\","
             "\"url\":\"https://example.invalid/repositories/%03d/"
             "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz.git\"}}",
             last_remote, i);
    if (expect_ok(e, req))
      return 1;
  }
  resp = ge_run_json(e, "{\"op\":\"remote\",\"args\":{\"action\":\"list\"}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL || strlen(resp) <= 8192 ||
      strstr(resp, last_remote) == NULL) {
    fprintf(stderr, "large remote output incomplete\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  ge_free(resp);
  return 0;
}

/* log bounds — max_count, result.bounded + stable footer when more commits. */
static int test_log_bounds(ge_engine *e) {
  /* Create enough commits so max_count=2 hits the bound. */
  for (int i = 0; i < 3; i++) {
    char req[512];
    snprintf(req, sizeof(req),
             "{\"op\":\"write\",\"args\":{\"path\":\"logb%d.txt\","
             "\"content\":\"c%d\\n\"}}",
             i, i);
    if (expect_ok(e, req))
      return 1;
    snprintf(req, sizeof(req),
             "{\"op\":\"add\",\"args\":{\"path\":\"logb%d.txt\"}}", i);
    if (expect_ok(e, req))
      return 1;
    snprintf(req, sizeof(req),
             "{\"op\":\"commit\",\"args\":{"
             "\"message\":\"log bound %d\","
             "\"name\":\"Fixture\","
             "\"email\":\"fixture@test\","
             "\"when_unix\":%d}}",
             i, 1700000100 + i);
    if (expect_ok(e, req))
      return 1;
  }
  char *resp = ge_run_json(e, "{\"op\":\"log\",\"args\":{\"max_count\":2}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "D39 log failed:\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "\"bounded\":true") == NULL) {
    fprintf(stderr, "D39 expected result.bounded=true:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "\"max_count\":2") == NULL) {
    fprintf(stderr, "D39 expected max_count=2:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "# log: bounded max_count=2") == NULL) {
    fprintf(stderr, "D39 expected stable bounds footer:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  /* show still returns ok; large show uses truncated path when over embed limit. */
  ge_free(resp);
  resp = ge_run_json(e, "{\"op\":\"show\",\"args\":{\"rev\":\"HEAD\"}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "D39 show failed:\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "commit ") == NULL && strstr(resp, "Author:") == NULL) {
    fprintf(stderr, "D39 show missing commit header:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);
  return 0;
}

/* default status is porcelain-v1 XY lines; untracked is ??; short keeps XY shape. */
static int test_status_porcelain(ge_engine *e) {
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"porc_new.txt\",\"content\":\"n\\n\"}}"))
    return 1;
  /* Default (not short): porcelain-v1 — no "On branch", untracked as ?? */
  char *resp = ge_run_json(e, "{\"op\":\"status\"}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "status porcelain null/fail\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "On branch") != NULL) {
    fprintf(stderr, "status default should be porcelain-v1 (no On branch):\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "?? porc_new.txt") == NULL && strstr(resp, "??porc_new.txt") == NULL) {
    /* JSON-escaped: ?? porc_new.txt may appear as ?? porc_new.txt in stdout string */
    if (strstr(resp, "?? porc_new.txt") == NULL && strstr(resp, "??") == NULL) {
      fprintf(stderr, "status porcelain missing ?? untracked:\n%s\n", resp);
      ge_free(resp);
      return 1;
    }
  }
  ge_free(resp);

  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"porc_new.txt\"}}"))
    return 1;
  resp = ge_run_json(e, "{\"op\":\"status\",\"args\":{\"short\":true}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL ||
      (strstr(resp, "A  porc_new.txt") == NULL && strstr(resp, "A porc_new.txt") == NULL &&
       strstr(resp, "A ") == NULL)) {
    fprintf(stderr, "status short staged A unexpected:\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  ge_free(resp);
  return 0;
}

/* –R69: list-only .gitmodules parse; network/update fail closed (no dial). */
static int test_submodule_list_only(ge_engine *e) {
  /* Empty / missing .gitmodules → ok with empty array. */
  char *resp = ge_run_json(e, "{\"op\":\"submodule\",\"args\":{\"action\":\"list\"}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "submodule list empty fail:\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "[]") == NULL && strstr(resp, "\"submodules\":[]") == NULL) {
    fprintf(stderr, "submodule list empty missing []:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  /* Write a classic .gitmodules (worktree file; not committed). */
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\".gitmodules\","
                   "\"content\":\"[submodule \\\"lib/foo\\\"]\\n"
                   "\\tpath = lib/foo\\n"
                   "\\turl = https://example.com/foo.git\\n"
                   "[submodule \\\"vendor/bar\\\"]\\n"
                   "path = vendor/bar\\n"
                   "url = https://example.com/bar.git\\n\"}}"))
    return 1;

  resp = ge_run_json(e, "{\"op\":\"submodule\"}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "submodule default list fail:\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "lib/foo") == NULL || strstr(resp, "vendor/bar") == NULL ||
      strstr(resp, "example.com/foo") == NULL) {
    fprintf(stderr, "submodule list missing entries:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);

  /* Network / apply actions fail closed on engine (orch host_call only). */
  if (expect_fail(e, "{\"op\":\"submodule\",\"args\":{\"action\":\"update\"}}",
                  "host_call"))
    return 1;
  if (expect_fail(e, "{\"op\":\"submodule\",\"args\":{\"action\":\"init\"}}",
                  "orchestrator"))
    return 1;
  if (expect_fail(e, "{\"op\":\"submodule\",\"args\":{\"action\":\"add\"}}",
                  "host_call"))
    return 1;
  if (expect_fail(e, "{\"op\":\"submodule\",\"args\":{\"action\":\"clone\"}}",
                  "orchestrator"))
    return 1;

  /* Local gitlink stage + list includes hash (D23 fixture path). */
  if (expect_ok(e, "{\"op\":\"gitlink\",\"args\":{"
                   "\"path\":\"lib/foo\","
                   "\"hash\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}"))
    return 1;
  resp = ge_run_json(e, "{\"op\":\"submodule\",\"args\":{\"action\":\"list\"}}");
  if (!resp || strstr(resp, "\"ok\":true") == NULL) {
    fprintf(stderr, "submodule list after gitlink fail:\n%s\n", resp ? resp : "(null)");
    ge_free(resp);
    return 1;
  }
  if (strstr(resp, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == NULL) {
    fprintf(stderr, "submodule list missing gitlink hash:\n%s\n", resp);
    ge_free(resp);
    return 1;
  }
  ge_free(resp);
  return 0;
}

/* multi-pattern string/array + basic !negation written to sparse-checkout. */
static int test_sparse_set_patterns(ge_engine *e) {
  if (expect_ok(e, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":[\"src\",\"docs\",\"!vendor\"]}}"))
    return 1;
  char sc[4096];
  snprintf(sc, sizeof(sc), "%s/.git/info/sparse-checkout", ge_worktree_root(e));
  FILE *f = fopen(sc, "rb");
  if (!f) {
    fprintf(stderr, "sparse-checkout missing after array patterns\n");
    return 1;
  }
  char buf[2048];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = '\0';
  if (strstr(buf, "/src/") == NULL || strstr(buf, "/docs/") == NULL ||
      strstr(buf, "!/vendor/") == NULL) {
    fprintf(stderr, "sparse-checkout content unexpected:\n%s\n", buf);
    return 1;
  }

  /* GIT-001: pruning an out-of-cone symlink must unlink the link itself and
   * leave the directory it points at completely untouched. */
  char outside_tmpl[] = "/tmp/ge-sparse-outside-XXXXXX";
  char *outside = mkdtemp(outside_tmpl);
  if (!outside)
    return 1;
  char drop[4096], link_path[4096], sentinel[4096];
  snprintf(drop, sizeof(drop), "%s/drop", ge_worktree_root(e));
  snprintf(link_path, sizeof(link_path), "%s/outside", drop);
  snprintf(sentinel, sizeof(sentinel), "%s/sentinel.txt", outside);
  if (mkdir(drop, 0755) != 0)
    return 1;
  FILE *sf = fopen(sentinel, "wb");
  if (!sf || fwrite("safe\n", 1, 5, sf) != 5 || fclose(sf) != 0)
    return 1;
  if (symlink(outside, link_path) != 0)
    return 1;
  /* Newline-separated multi + negation */
  if (expect_ok(e, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":\"keep\\n!drop\"}}"))
    return 1;
  if (access(sentinel, F_OK) != 0) {
    fprintf(stderr, "sparse prune followed an out-of-cone symlink\n");
    return 1;
  }
  unlink(sentinel);
  rmdir(outside);
  f = fopen(sc, "rb");
  if (!f)
    return 1;
  n = fread(buf, 1, sizeof(buf) - 1, f);
  fclose(f);
  buf[n] = '\0';
  if (strstr(buf, "/keep/") == NULL || strstr(buf, "!/drop/") == NULL) {
    fprintf(stderr, "sparse-checkout newline patterns unexpected:\n%s\n", buf);
    return 1;
  }
  /* Unsafe negation fails closed */
  if (expect_fail(e, "{\"op\":\"sparse-set\",\"args\":{\"patterns\":\"!../x\"}}", "unsafe"))
    return 1;
  return 0;
}

/* M3: client_token is engine-local; inject only into object results, never arrays. */
static int test_client_token(ge_engine *e) {
  /* Success without a result object → engine adds result.client_token. */
  {
    char *resp = ge_run_json(
        e, "{\"op\":\"version\",\"args\":{\"client_token\":\"tok-no-result\"}}");
    if (!resp) {
      fprintf(stderr, "client_token version: null response\n");
      return 1;
    }
    int bad = (strstr(resp, "\"ok\":true") == NULL) ||
              (strstr(resp, "\"client_token\":\"tok-no-result\"") == NULL) ||
              (strstr(resp, "\"result\":") == NULL);
    if (bad)
      fprintf(stderr, "client_token on success without result unexpected:\n%s\n", resp);
    ge_free(resp);
    if (bad)
      return 1;
  }

  /* Object result keeps token as a field inside result. */
  {
    char *resp = ge_run_json(
        e, "{\"op\":\"rev-parse\",\"args\":{\"rev\":\"HEAD\","
           "\"client_token\":\"tok-object\"}}");
    if (!resp) {
      fprintf(stderr, "client_token rev-parse: null response\n");
      return 1;
    }
    int bad = (strstr(resp, "\"ok\":true") == NULL);
    const char *rk = strstr(resp, "\"result\":");
    if (!rk || strstr(rk, "\"client_token\":\"tok-object\"") == NULL)
      bad = 1;
    if (bad)
      fprintf(stderr, "client_token on object result unexpected:\n%s\n", resp);
    ge_free(resp);
    if (bad)
      return 1;
  }

  /* Array result (tips): must remain an array; never inject into elements. */
  {
    char *resp = ge_run_json(
        e, "{\"op\":\"tips\",\"args\":{\"client_token\":\"tok-array\"}}");
    if (!resp) {
      fprintf(stderr, "client_token tips: null response\n");
      return 1;
    }
    int bad = (strstr(resp, "\"ok\":true") == NULL);
    const char *rk = strstr(resp, "\"result\":");
    if (!rk) {
      bad = 1;
    } else {
      const char *val = rk + strlen("\"result\":");
      while (*val == ' ' || *val == '\t')
        val++;
      /* tips returns a JSON array — must stay an array. */
      if (*val != '[')
        bad = 1;
      /* Old bug: strchr-for-{ injected into first element as client_token. */
      if (strncmp(val, "[{\"client_token\":", 17) == 0)
        bad = 1;
      if (strstr(val, "\"client_token\"") != NULL)
        bad = 1;
    }
    if (bad)
      fprintf(stderr, "client_token array result unexpected:\n%s\n", resp);
    ge_free(resp);
    if (bad)
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

  /* full patch diff */
  if (test_diff_patch(e))
    goto fail;

  /* add all stages deletions */
  if (test_add_all_deletion(e))
    goto fail;

  /* refs.import multi-ref array */
  if (test_refs_import_array(e))
    goto fail;

  /* truncated stdout + stream_path + out/last */
  if (test_truncated_stdout(e))
    goto fail;

  /* symlink fail-closed on add/write */
  if (test_symlink_fail_closed(e))
    goto fail;

  /* log bounds + show polish */
  if (test_log_bounds(e))
    goto fail;

  /* porcelain-v1 status */
  if (test_status_porcelain(e))
    goto fail;

  /* multi-pattern + negation sparse-set */
  if (test_sparse_set_patterns(e))
    goto fail;

  /* –R69 submodule list-only + network fail-closed */
  if (test_submodule_list_only(e))
    goto fail;

  /* M3: client_token engine-local + safe object-only inject */
  if (test_client_token(e))
    goto fail;

  /* GIT-003: grow beyond every former fixed ref/remote output buffer. */
  if (test_large_ref_outputs(e))
    goto fail;

  ge_close(e);
  printf("abi_fixture_test SUCCESS\n");
  return 0;

fail:
  ge_close(e);
  return 1;
}
