/* ge_port.h — length-prefixed Port frames for BEAM-owned git-engine (GIT.md PR7+).
 *
 * Wire: u32le length | u8 type | payload
 *   length = 1 + payload_len  (covers type byte + payload)
 *
 * Types:
 *   1  JSON Run request → JSON Response (payload UTF-8). Always ge_run_json;
 *      clone/fetch/pull/push dial-refuse (no C orch on type-1).
 *   2  pack chunk (raw bytes) → response type 2, payload i32le status (0 ok)
 *   3  pack meta (u8 final flag, 1 = finalize) → type 3, i32le status
 *   4  binary MOUNT_OP body (peer of dispatchMount) → [i32 status][payload]
 *   5  remote orch Request JSON (clone/fetch/…) → Response JSON — test-only
 *      C orchestrator (fixtures); product remotes are host/BEAM-mediated.
 */

#ifndef GE_PORT_H_
#define GE_PORT_H_

#include "git_engine.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

enum {
  GE_FRAME_RUN = 1,
  GE_FRAME_PACK = 2,
  GE_FRAME_PACK_META = 3,
  GE_FRAME_MOUNT = 4,
  GE_FRAME_REMOTE = 5,
};

/* Read one frame from in. On success *type and *payload (*payload_len) are set;
 * caller must free(*payload). Returns 0 on success, 1 on EOF, -1 on error. */
int ge_frame_read(FILE *in, uint8_t *type, uint8_t **payload, size_t *payload_len);

/* Write one frame to out. Returns 0 on success. */
int ge_frame_write(FILE *out, uint8_t type, const void *payload, size_t payload_len);

/* Serve one request frame; writes a response frame. Returns 0, or -1 on IO error. */
int ge_port_handle(ge_engine *e, uint8_t type, const uint8_t *payload, size_t len,
                   FILE *out);

/* Synthetic gitfs mount over real FS worktree (server). */
int ge_mount_dispatch(ge_engine *e, const uint8_t *body, size_t body_len, uint8_t **out,
                      size_t *out_len);

/* Host smart-HTTP + C orchestrator (PR9–PR10). Test/fixture path only (type-5);
 * product remotes use BEAM orch + pack/refs/*.apply on type-1. */
int ge_remote_orchestrate(ge_engine *e, const char *request_json, char **response_json);

#endif /* GE_PORT_H_ */
