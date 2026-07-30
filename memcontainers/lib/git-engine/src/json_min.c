/* Minimal JSON helpers for the Run ABI (no third-party dependency).
 * Only supports what the spike needs: extract string/bool/int fields from
 * shallow objects, and build small response objects. */

#include "json_min.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *skip_ws(const char *p) {
  while (p && *p && isspace((unsigned char)*p))
    p++;
  return p;
}

/* Find "key" then : then value start. Returns pointer to value start or NULL. */
static const char *find_key(const char *json, const char *key) {
  if (!json || !key)
    return NULL;
  char pat[128];
  size_t klen = strlen(key);
  if (klen + 3 >= sizeof(pat))
    return NULL;
  pat[0] = '"';
  memcpy(pat + 1, key, klen);
  pat[1 + klen] = '"';
  pat[2 + klen] = '\0';

  const char *p = json;
  while ((p = strstr(p, pat)) != NULL) {
    /* crude: skip if escaped quote before (ignore for spike) */
    p = skip_ws(p + strlen(pat));
    if (*p != ':') {
      p++;
      continue;
    }
    return skip_ws(p + 1);
  }
  return NULL;
}

int jmin_get_string(const char *json, const char *key, char *out, size_t out_cap) {
  if (!out || out_cap == 0)
    return -1;
  out[0] = '\0';
  const char *v = find_key(json, key);
  if (!v || *v != '"')
    return -1;
  v++;
  size_t i = 0;
  while (*v && *v != '"' && i + 1 < out_cap) {
    if (*v == '\\' && v[1]) {
      v++;
      switch (*v) {
      case 'n':
        out[i++] = '\n';
        break;
      case 't':
        out[i++] = '\t';
        break;
      case '"':
      case '\\':
      case '/':
        out[i++] = *v;
        break;
      default:
        out[i++] = *v;
        break;
      }
      v++;
      continue;
    }
    out[i++] = *v++;
  }
  out[i] = '\0';
  return (*v == '"') ? 0 : -1;
}

int jmin_get_bool(const char *json, const char *key, int *out) {
  if (!out)
    return -1;
  const char *v = find_key(json, key);
  if (!v)
    return -1;
  if (strncmp(v, "true", 4) == 0) {
    *out = 1;
    return 0;
  }
  if (strncmp(v, "false", 5) == 0) {
    *out = 0;
    return 0;
  }
  return -1;
}

int jmin_get_int64(const char *json, const char *key, int64_t *out) {
  if (!out)
    return -1;
  const char *v = find_key(json, key);
  if (!v)
    return -1;
  char *end = NULL;
  long long n = strtoll(v, &end, 10);
  if (end == v)
    return -1;
  *out = (int64_t)n;
  return 0;
}

/* Return pointer to args object body after "args" : {  (or NULL). */
const char *jmin_args_object(const char *json) {
  const char *v = find_key(json, "args");
  if (!v)
    return NULL;
  if (*v == '{')
    return v;
  return NULL;
}

char *jmin_escape(const char *s) {
  if (!s)
    s = "";
  size_t n = 0;
  for (const char *p = s; *p; p++) {
    if (*p == '"' || *p == '\\' || *p == '\n' || *p == '\r' || *p == '\t')
      n += 2;
    else
      n++;
  }
  char *o = (char *)malloc(n + 1);
  if (!o)
    return NULL;
  char *w = o;
  for (const char *p = s; *p; p++) {
    switch (*p) {
    case '"':
      *w++ = '\\';
      *w++ = '"';
      break;
    case '\\':
      *w++ = '\\';
      *w++ = '\\';
      break;
    case '\n':
      *w++ = '\\';
      *w++ = 'n';
      break;
    case '\r':
      *w++ = '\\';
      *w++ = 'r';
      break;
    case '\t':
      *w++ = '\\';
      *w++ = 't';
      break;
    default:
      *w++ = *p;
      break;
    }
  }
  *w = '\0';
  return o;
}

char *jmin_response(int ok, int code, const char *stdout_s, const char *stderr_s,
                    const char *result_json) {
  char *esc_out = jmin_escape(stdout_s ? stdout_s : "");
  char *esc_err = jmin_escape(stderr_s ? stderr_s : "");
  if (!esc_out || !esc_err) {
    free(esc_out);
    free(esc_err);
    return NULL;
  }

  size_t cap = strlen(esc_out) + strlen(esc_err) +
               (result_json ? strlen(result_json) : 0) + 128;
  char *buf = (char *)malloc(cap);
  if (!buf) {
    free(esc_out);
    free(esc_err);
    return NULL;
  }

  if (result_json && result_json[0]) {
    snprintf(buf, cap,
             "{\"ok\":%s,\"code\":%d,\"stdout\":\"%s\",\"stderr\":\"%s\","
             "\"result\":%s}",
             ok ? "true" : "false", code, esc_out, esc_err, result_json);
  } else {
    snprintf(buf, cap,
             "{\"ok\":%s,\"code\":%d,\"stdout\":\"%s\",\"stderr\":\"%s\"}",
             ok ? "true" : "false", code, esc_out, esc_err);
  }
  free(esc_out);
  free(esc_err);
  return buf;
}
