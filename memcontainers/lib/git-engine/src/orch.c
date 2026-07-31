/* GitRemoteOrchestrator algorithm (C) — GIT.md §7 + PR10c.
 * Shared steps with TS remote-orchestrator.ts; golden traces in testdata/orch/.
 *
 * Clone:
 *   1. resolve remote URL
 *   2. ListRefs
 *   3. pick HEAD / default branch tip
 *   4. FetchPacks(want=[tip], have=[], depth?)
 *   5. ge_import_pack(binary) + final
 *   6. refs.import + clone.apply
 * Engine never dials; only this orch / host HTTP does.
 */

#include "ge_http.h"
#include "ge_port.h"
#include "git_engine.h"
#include "json_min.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *resp_ok_s(const char *stdout_s) {
  return jmin_response(1, 0, stdout_s ? stdout_s : "", "", NULL);
}

static char *resp_err_s(int code, const char *stderr_s) {
  return jmin_response(0, code, "", stderr_s ? stderr_s : "error", NULL);
}

/* Minimal extract of first "hash" string in refs advertisement JSON. */
static int first_ref(const char *refs_json, char *name_out, size_t name_cap, char *hash_out,
                     size_t hash_cap) {
  const char *h = strstr(refs_json, "\"hash\"");
  const char *n = strstr(refs_json, "\"name\"");
  if (!h || !n)
    return -1;
  /* name */
  const char *q = strchr(n, ':');
  if (!q)
    return -1;
  q = strchr(q, '"');
  if (!q)
    return -1;
  q++;
  const char *q2 = strchr(q, '"');
  if (!q2 || (size_t)(q2 - q) >= name_cap)
    return -1;
  memcpy(name_out, q, (size_t)(q2 - q));
  name_out[q2 - q] = 0;
  /* hash */
  q = strchr(h, ':');
  if (!q)
    return -1;
  q = strchr(q, '"');
  if (!q)
    return -1;
  q++;
  q2 = strchr(q, '"');
  if (!q2 || (size_t)(q2 - q) >= hash_cap)
    return -1;
  memcpy(hash_out, q, (size_t)(q2 - q));
  hash_out[q2 - q] = 0;
  return 0;
}

int ge_remote_orchestrate(ge_engine *e, const char *request_json, char **response_json) {
  *response_json = NULL;
  if (!e || !request_json)
    return -1;

  char op[64] = "";
  if (jmin_get_string(request_json, "op", op, sizeof(op)) != 0)
    return (*response_json = resp_err_s(2, "missing op")) ? 0 : -1;
  for (char *p = op; *p; p++) {
    if (*p >= 'A' && *p <= 'Z')
      *p = (char)(*p - 'A' + 'a');
  }

  if (strcmp(op, "clone") != 0 && strcmp(op, "fetch") != 0 && strcmp(op, "pull") != 0) {
    if (strcmp(op, "push") == 0)
      return (*response_json = resp_err_s(1, "push requires PR12 / approval path")) ? 0 : -1;
    return (*response_json = resp_err_s(2, "unknown remote op")) ? 0 : -1;
  }

  /* args.url or args.remote as public locator (no credentials). */
  char url[1024] = "";
  const char *args = jmin_args_object(request_json);
  if (!args)
    args = "{}";
  if (jmin_get_string(args, "url", url, sizeof(url)) != 0)
    (void)jmin_get_string(args, "remote", url, sizeof(url));
  if (!url[0])
    return (*response_json = resp_err_s(2, "clone/fetch need args.url")) ? 0 : -1;

  /* Algorithm step 2: ListRefs */
  char *refs = ge_http_list_refs(url);
  if (!refs)
    return (*response_json = resp_err_s(1, "git: list-refs failed")) ? 0 : -1;

  char name[256], hash[64];
  if (first_ref(refs, name, sizeof(name), hash, sizeof(hash)) != 0) {
    free(refs);
    return (*response_json = resp_err_s(1, "git: no refs in advertisement")) ? 0 : -1;
  }
  free(refs);

  /* Algorithm step 4: FetchPacks */
  const char *want[1] = {hash};
  uint8_t *pack = NULL;
  size_t pack_len = 0;
  int64_t depth64 = 0;
  (void)jmin_get_int64(args, "depth", &depth64);
  int depth = (int)depth64;
  if (ge_http_fetch_packs(url, want, 1, NULL, 0, depth, &pack, &pack_len) != 0) {
    return (*response_json = resp_err_s(1, "git: upload-pack failed")) ? 0 : -1;
  }

  /* Ensure repo exists for apply */
  char *init_r = ge_run_json(e, "{\"op\":\"init\"}");
  ge_free(init_r);

  /* Algorithm step 5: binary ImportPack */
  if (pack_len > 0) {
    if (ge_import_pack(e, pack, pack_len, 0) != 0) {
      free(pack);
      return (*response_json = resp_err_s(1, ge_last_error(e))) ? 0 : -1;
    }
  }
  free(pack);
  if (ge_import_pack(e, NULL, 0, 1) != 0)
    return (*response_json = resp_err_s(1, ge_last_error(e))) ? 0 : -1;

  /* refs.import + clone.apply / fetch.apply */
  char req[512];
  snprintf(req, sizeof(req),
           "{\"op\":\"refs.import\",\"args\":{\"name\":\"%s\",\"hash\":\"%s\"}}", name, hash);
  char *r1 = ge_run_json(e, req);
  if (!r1 || strstr(r1, "\"ok\":false") || strstr(r1, "\"ok\": false")) {
    ge_free(r1);
    return (*response_json = resp_err_s(1, "refs.import failed")) ? 0 : -1;
  }
  ge_free(r1);

  if (strcmp(op, "clone") == 0) {
    snprintf(req, sizeof(req), "{\"op\":\"clone.apply\",\"args\":{\"head\":\"%s\"}}", name);
    char *r2 = ge_run_json(e, req);
    if (!r2 || strstr(r2, "\"ok\":false") || strstr(r2, "\"ok\": false")) {
      ge_free(r2);
      return (*response_json = resp_err_s(1, "clone.apply failed")) ? 0 : -1;
    }
    ge_free(r2);
  } else {
    char *r2 = ge_run_json(e, "{\"op\":\"fetch.apply\"}");
    ge_free(r2);
  }

  return (*response_json = resp_ok_s("orchestrated")) ? 0 : -1;
}
