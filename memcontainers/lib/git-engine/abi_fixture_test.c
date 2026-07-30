/* PR1: native ABI fixture — init→write→add→commit→log + dial refuse (GIT.md). */
#include "git_engine.h"

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

  /* path escape */
  if (expect_fail(e, "{\"op\":\"write\",\"args\":{\"path\":\"../x\",\"content\":\"n\"}}", NULL))
    goto fail;

  ge_close(e);
  printf("abi_fixture_test SUCCESS\n");
  return 0;

fail:
  ge_close(e);
  return 1;
}
