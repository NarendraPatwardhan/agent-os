/* Port frame codec: length-prefixed type + payload. */

#include "ge_port.h"

#include <stdlib.h>
#include <string.h>

int ge_frame_read(FILE *in, uint8_t *type, uint8_t **payload, size_t *payload_len) {
  uint8_t hdr[4];
  size_t n = fread(hdr, 1, 4, in);
  if (n == 0)
    return 1; /* EOF */
  if (n != 4)
    return -1;
  uint32_t len = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8) | ((uint32_t)hdr[2] << 16) |
                 ((uint32_t)hdr[3] << 24);
  if (len < 1 || len > 64u * 1024u * 1024u)
    return -1;
  uint8_t *buf = (uint8_t *)malloc(len);
  if (!buf)
    return -1;
  if (fread(buf, 1, len, in) != len) {
    free(buf);
    return -1;
  }
  *type = buf[0];
  *payload_len = len - 1;
  if (*payload_len == 0) {
    *payload = NULL;
    free(buf);
  } else {
    memmove(buf, buf + 1, *payload_len);
    *payload = buf;
  }
  return 0;
}

int ge_frame_write(FILE *out, uint8_t type, const void *payload, size_t payload_len) {
  if (payload_len > 64u * 1024u * 1024u - 1u)
    return -1;
  uint32_t len = (uint32_t)(1 + payload_len);
  uint8_t hdr[5];
  hdr[0] = (uint8_t)(len & 0xff);
  hdr[1] = (uint8_t)((len >> 8) & 0xff);
  hdr[2] = (uint8_t)((len >> 16) & 0xff);
  hdr[3] = (uint8_t)((len >> 24) & 0xff);
  hdr[4] = type;
  if (fwrite(hdr, 1, 5, out) != 5)
    return -1;
  if (payload_len > 0 && fwrite(payload, 1, payload_len, out) != payload_len)
    return -1;
  if (fflush(out) != 0)
    return -1;
  return 0;
}
