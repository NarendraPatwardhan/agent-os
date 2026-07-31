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

/* Prefer refs/heads/main, then master, then first heads/*, then first object. */
static int extract_named(const char *refs_json, const char *want_name, char *name_out,
                         size_t name_cap, char *hash_out, size_t hash_cap) {
  const char *p = refs_json;
  while ((p = strstr(p, "\"name\"")) != NULL) {
    const char *q = strchr(p, ':');
    if (!q)
      break;
    q = strchr(q, '"');
    if (!q)
      break;
    q++;
    const char *q2 = strchr(q, '"');
    if (!q2)
      break;
    size_t nlen = (size_t)(q2 - q);
    char name[256];
    if (nlen >= sizeof(name)) {
      p = q2 + 1;
      continue;
    }
    memcpy(name, q, nlen);
    name[nlen] = 0;
    const char *h = strstr(q2, "\"hash\"");
    if (!h) {
      p = q2 + 1;
      continue;
    }
    const char *hq = strchr(h, ':');
    if (!hq) {
      p = q2 + 1;
      continue;
    }
    hq = strchr(hq, '"');
    if (!hq) {
      p = q2 + 1;
      continue;
    }
    hq++;
    const char *hq2 = strchr(hq, '"');
    if (!hq2 || (size_t)(hq2 - hq) >= hash_cap) {
      p = q2 + 1;
      continue;
    }
    if (want_name && strcmp(name, want_name) != 0) {
      p = q2 + 1;
      continue;
    }
    if (nlen >= name_cap) {
      p = q2 + 1;
      continue;
    }
    memcpy(name_out, name, nlen);
    name_out[nlen] = 0;
    memcpy(hash_out, hq, (size_t)(hq2 - hq));
    hash_out[hq2 - hq] = 0;
    return 0;
  }
  return -1;
}

static int first_ref(const char *refs_json, char *name_out, size_t name_cap, char *hash_out,
                     size_t hash_cap) {
  if (extract_named(refs_json, "refs/heads/main", name_out, name_cap, hash_out, hash_cap) == 0)
    return 0;
  if (extract_named(refs_json, "refs/heads/master", name_out, name_cap, hash_out, hash_cap) == 0)
    return 0;
  /* first heads/* */
  const char *p = refs_json;
  while ((p = strstr(p, "\"name\"")) != NULL) {
    char nbuf[256], hbuf[64];
    if (extract_named(p, NULL, nbuf, sizeof(nbuf), hbuf, sizeof(hbuf)) == 0) {
      if (strncmp(nbuf, "refs/heads/", 11) == 0) {
        snprintf(name_out, name_cap, "%s", nbuf);
        snprintf(hash_out, hash_cap, "%s", hbuf);
        return 0;
      }
    }
    p++;
  }
  return extract_named(refs_json, NULL, name_out, name_cap, hash_out, hash_cap);
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
      return (*response_json = resp_err_s(
                  1, "git: push on C Port requires packbuilder (JS orch has full PR12 path)"))
                 ? 0
                 : -1;
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
    snprintf(req, sizeof(req),
             "{\"op\":\"fetch.apply\",\"args\":{\"name\":\"%s\",\"hash\":\"%s\"}}", name,
             hash);
    char *r2 = ge_run_json(e, req);
    if (!r2 || strstr(r2, "\"ok\":false") || strstr(r2, "\"ok\": false")) {
      ge_free(r2);
      return (*response_json = resp_err_s(1, "fetch.apply failed")) ? 0 : -1;
    }
    ge_free(r2);
  }

  return (*response_json = resp_ok_s("orchestrated")) ? 0 : -1;
}
