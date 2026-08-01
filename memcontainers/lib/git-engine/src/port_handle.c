/* Port request handler — routes frames to Run / pack / mount only.
 * Remotes are host-mediated (TS/BEAM orch); the Port never dials or orchs. */

#include "ge_port.h"
#include "json_min.h"

#include <stdlib.h>
#include <string.h>

static void wr_i32_le(uint8_t *p, int32_t v) {
  uint32_t u = (uint32_t)v;
  p[0] = (uint8_t)(u & 0xff);
  p[1] = (uint8_t)((u >> 8) & 0xff);
  p[2] = (uint8_t)((u >> 16) & 0xff);
  p[3] = (uint8_t)((u >> 24) & 0xff);
}

int ge_port_handle(ge_engine *e, uint8_t type, const uint8_t *payload, size_t len, FILE *out) {
  /* Type-1 RUN: always ge_run_json — remotes dial-refuse at the engine face. */
  if (type == GE_FRAME_RUN) {
    char *req = (char *)malloc(len + 1);
    if (!req)
      return -1;
    if (len)
      memcpy(req, payload, len);
    req[len] = 0;

    char *resp = ge_run_json(e, req);
    free(req);
    if (!resp)
      return -1;
    int rc = ge_frame_write(out, GE_FRAME_RUN, resp, strlen(resp));
    ge_free(resp);
    return rc;
  }

  if (type == GE_FRAME_PACK) {
    int st = ge_import_pack(e, payload, len, 0);
    uint8_t stbuf[4];
    wr_i32_le(stbuf, st == 0 ? 0 : -1);
    return ge_frame_write(out, GE_FRAME_PACK, stbuf, 4);
  }

  if (type == GE_FRAME_PACK_META) {
    int final = 1;
    if (len >= 1)
      final = payload[0] ? 1 : 0;
    int st = final ? ge_import_pack(e, NULL, 0, 1) : 0;
    uint8_t stbuf[4];
    wr_i32_le(stbuf, st == 0 ? 0 : -1);
    return ge_frame_write(out, GE_FRAME_PACK_META, stbuf, 4);
  }

  if (type == GE_FRAME_MOUNT) {
    uint8_t *mout = NULL;
    size_t mlen = 0;
    if (ge_mount_dispatch(e, payload, len, &mout, &mlen) != 0 || !mout) {
      free(mout);
      uint8_t fail[4];
      wr_i32_le(fail, 29); /* EIO */
      return ge_frame_write(out, GE_FRAME_MOUNT, fail, 4);
    }
    int rc = ge_frame_write(out, GE_FRAME_MOUNT, mout, mlen);
    free(mout);
    return rc;
  }

  const char *unk = "{\"ok\":false,\"code\":2,\"stdout\":\"\",\"stderr\":\"unknown frame type\"}";
  return ge_frame_write(out, GE_FRAME_RUN, unk, strlen(unk));
}
