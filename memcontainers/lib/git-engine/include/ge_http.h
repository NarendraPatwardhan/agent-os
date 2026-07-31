#ifndef GE_HTTP_H_
#define GE_HTTP_H_

#include <stddef.h>
#include <stdint.h>

/* Test double / policy stubs for host smart-HTTP (GIT.md PR9). */
void ge_http_fixture_clear(void);
int ge_http_fixture_add(const char *url, const char *refs_json, const uint8_t *pack,
                        size_t pack_len);

/* ListRefs — returns heap JSON array of {name,hash}; caller free(). NULL on fail. */
char *ge_http_list_refs(const char *url);

/* FetchPacks — shallow-capable. Returns 0 and malloc pack on success. */
int ge_http_fetch_packs(const char *url, const char *const *want, size_t nwant,
                        const char *const *have, size_t nhave, int depth,
                        uint8_t **pack_out, size_t *pack_len);

#endif
