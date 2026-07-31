/* PR7c — dual-runner ABI: native ge_run_json executes the same golden local ops
 * as abi_fixture_test / emcc smoke. Wasm side is covered by git_engine_test (JS).
 * This target keeps native fixtures wired for CI drift detection.
 */

#include "git_engine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int expect_ok(ge_engine *e, const char *req) {
  char *r = ge_run_json(e, req);
  if (!r) {
    fprintf(stderr, "null response for %s\n", req);
    return -1;
  }
  int bad = strstr(r, "\"ok\":false") != NULL || strstr(r, "\"ok\": false") != NULL;
  if (bad)
    fprintf(stderr, "FAIL %s → %s\n", req, r);
  ge_free(r);
  return bad ? -1 : 0;
}

int main(void) {
  char tmpl[] = "/tmp/ge-dual-XXXXXX";
  char *root = mkdtemp(tmpl);
  if (!root)
    return 1;
  ge_engine *e = ge_open(root);
  if (!e)
    return 1;

  if (expect_ok(e, "{\"op\":\"init\"}") != 0)
    return 1;
  if (expect_ok(e, "{\"op\":\"write\",\"args\":{\"path\":\"d.txt\",\"content\":\"dual\\n\"}}") !=
      0)
    return 1;
  if (expect_ok(e, "{\"op\":\"add\",\"args\":{\"path\":\"d.txt\"}}") != 0)
    return 1;
  if (expect_ok(e,
                "{\"op\":\"commit\",\"args\":{\"message\":\"dual\",\"name\":\"D\",\"email\":"
                "\"d@d\",\"when_unix\":1700000001}}") != 0)
    return 1;
  if (expect_ok(e, "{\"op\":\"log\",\"args\":{\"max_count\":5}}") != 0)
    return 1;

  /* Dial refuse must stay fail-closed at Run face (type-1); C orch is type-5 only. */
  char *dial = ge_run_json(e, "{\"op\":\"clone\",\"args\":{\"url\":\"https://example.com/r.git\"}}");
  if (!dial) {
    fprintf(stderr, "null dial\n");
    return 1;
  }
  int refused = strstr(dial, "\"ok\":false") != NULL || strstr(dial, "\"ok\": false") != NULL;
  ge_free(dial);
  if (!refused) {
    fprintf(stderr, "expected dial refuse on ge_run_json clone\n");
    return 1;
  }

  ge_close(e);
  printf("abi_dual_test SUCCESS (native runner)\n");
  return 0;
}
