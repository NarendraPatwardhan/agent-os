/* git_engine.h — host-side Run ABI (AgentOS git function face).
 *
 * One engine instance ≈ one gitfs mount. worktree_root for ge_open must be an
 * absolute path to an existing directory. Paths in args are worktree-relative
 * (no absolute paths, no "..").
 *
 * Contract:
 *   - Reduced surface — not full git-core.
 *   - Network dial is forbidden: remotes are host-mediated apply ops only
 *     (pack.import / refs.import / clone.apply / fetch.apply / pack.build).
 *   - JSON envelopes:
 *       Request:  { "op": "...", "args": { ... } }
 *       Response: { "ok": bool, "code": 0|1|2, "stdout"?, "stderr"?, "result"? }
 *   - code: 0 ok, 1 operational error, 2 usage / unknown op / bad JSON.
 */

#ifndef GIT_ENGINE_H_
#define GIT_ENGINE_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define GE_API __declspec(dllexport)
#else
#define GE_API __attribute__((visibility("default")))
#endif

typedef struct ge_engine ge_engine;

/* Create engine bound to worktree_root (absolute path; directory must exist).
 * Does not create a repo until op "init". */
GE_API ge_engine *ge_open(const char *worktree_root);

GE_API void ge_close(ge_engine *e);

/* Sole function face. Returns heap JSON string (caller free()s with ge_free).
 * Never returns NULL — on OOM returns a static error JSON. ge_free is always
 * safe (no-op for static fallbacks); ge_response_is_static reports which. */
GE_API char *ge_run_json(ge_engine *e, const char *request_json);

/* Validate the bounded, exact Run envelope without executing it. Returns 0
 * only for exactly {op:string,args?:object} with strict JSON semantics. */
GE_API int ge_validate_request_json(const char *request_json);

/* Binary pack import. Chunks may be streamed; final!=0 finalizes the indexer
 * into the ODB. Returns 0 on success, <0 on error. */
GE_API int ge_import_pack(ge_engine *e, const uint8_t *chunk, size_t len, int final);

/* Abort an incomplete streamed pack import and discard its indexer state.
 * Idempotent; callers must invoke this on every unsuccessful stream. */
GE_API void ge_import_pack_abort(ge_engine *e);

/* Build a pack of objects reachable from tip OIDs (push packbuilder).
 * oids_json: JSON array of 40-hex OIDs, or object with "oids" and/or
 * "commands" (uses non-zero newHash/hash). Optional "haves" array of 40-hex
 * OIDs (remote tips already known) — excluded via revwalk hide so the pack
 * omits objects the remote already has (thin-pack / have negotiation).
 * NULL / empty object → local branch tips. On success: *out is malloc'd pack
 * bytes (caller free()s with ge_free), *out_len is set. Cap GE_PACK_MAX_BYTES
 * (64 MiB). Fail closed on empty tips, empty pack, oversize, or packbuilder
 * errors. Returns 0 / <0. */
GE_API int ge_pack_build(ge_engine *e, const char *oids_json, uint8_t **out, size_t *out_len);

/* Last engine error string (valid until next ge_* call). */
GE_API const char *ge_last_error(const ge_engine *e);

/* Free a string returned by ge_run_json or buffer from ge_pack_build
 * (or no-op for static fallbacks). */
GE_API void ge_free(void *p);

/* Non-zero if p is a static ge_run_json fallback (must not free() directly). */
GE_API int ge_response_is_static(const void *p);

/* Engine identity string (for op "version"). */
GE_API const char *ge_version(void);

/* Absolute worktree root bound at ge_open (valid until ge_close). */
GE_API const char *ge_worktree_root(const ge_engine *e);

/* Test helper: override stdout embed limit for truncation tests.
 * Pass 0 to restore the product default (2 KiB). */
GE_API void ge_test_set_stdout_max_bytes(size_t n);

#ifdef __cplusplus
}
#endif

#endif /* GIT_ENGINE_H_ */
