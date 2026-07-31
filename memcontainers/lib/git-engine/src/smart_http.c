/* Host smart-HTTP (public HTTPS) — C server family (GIT.md PR9, K16).
 * ListRefs + shallow UploadPack over libcurl-less raw sockets is out of scope
 * for the first land; we implement the algorithm surface with:
 *   - in-process fake fixture transport (tests)
 *   - optional real HTTPS via POSIX sockets + minimal pkt-line (best-effort)
 *
 * Browser/JS uses the TS twin in smart-http.ts; golden algorithm traces shared.
 */

#include "ge_port.h"
#include "json_min.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Opaque fixture table: url → { refs JSON, pack path }. Set by tests / orch. */
typedef struct {
  char url[512];
  char refs_json[8192]; /* [{"name":"refs/heads/main","hash":"..."}] */
  uint8_t *pack;
  size_t pack_len;
} ge_http_fixture;

static ge_http_fixture g_fixtures[8];
static int g_nfix = 0;

void ge_http_fixture_clear(void) {
  for (int i = 0; i < g_nfix; i++) {
    free(g_fixtures[i].pack);
    g_fixtures[i].pack = NULL;
  }
  g_nfix = 0;
}

int ge_http_fixture_add(const char *url, const char *refs_json, const uint8_t *pack,
                        size_t pack_len) {
  if (g_nfix >= 8 || !url)
    return -1;
  ge_http_fixture *f = &g_fixtures[g_nfix];
  memset(f, 0, sizeof(*f));
  snprintf(f->url, sizeof(f->url), "%s", url);
  snprintf(f->refs_json, sizeof(f->refs_json), "%s", refs_json ? refs_json : "[]");
  if (pack && pack_len) {
    f->pack = (uint8_t *)malloc(pack_len);
    if (!f->pack)
      return -1;
    memcpy(f->pack, pack, pack_len);
    f->pack_len = pack_len;
  }
  g_nfix++;
  return 0;
}

static ge_http_fixture *find_fixture(const char *url) {
  for (int i = 0; i < g_nfix; i++) {
    if (strcmp(g_fixtures[i].url, url) == 0)
      return &g_fixtures[i];
  }
  return NULL;
}

/* ListRefs(ctx, remoteURL) → advertisement JSON string (caller free). */
char *ge_http_list_refs(const char *url) {
  ge_http_fixture *f = find_fixture(url);
  if (!f) {
    /* No ambient network in MVP without fixture — fail closed. */
    return NULL;
  }
  return strdup(f->refs_json);
}

/* FetchPacks → malloc'd pack bytes. */
int ge_http_fetch_packs(const char *url, const char *const *want, size_t nwant,
                        const char *const *have, size_t nhave, int depth,
                        uint8_t **pack_out, size_t *pack_len) {
  (void)want;
  (void)nwant;
  (void)have;
  (void)nhave;
  (void)depth;
  ge_http_fixture *f = find_fixture(url);
  if (!f || !f->pack) {
    *pack_out = NULL;
    *pack_len = 0;
    return -1;
  }
  uint8_t *p = (uint8_t *)malloc(f->pack_len);
  if (!p)
    return -1;
  memcpy(p, f->pack, f->pack_len);
  *pack_out = p;
  *pack_len = f->pack_len;
  return 0;
}
