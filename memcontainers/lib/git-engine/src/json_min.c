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

/* Decode one JSON string char escape at *v (points at char after '\\'). */
static int decode_escape(const char **vp, char *outc) {
  const char *v = *vp;
  if (!*v)
    return -1;
  switch (*v) {
  case 'n':
    *outc = '\n';
    break;
  case 't':
    *outc = '\t';
    break;
  case '"':
  case '\\':
  case '/':
    *outc = *v;
    break;
  default:
    *outc = *v;
    break;
  }
  *vp = v + 1;
  return 0;
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
      char c;
      if (decode_escape(&v, &c) != 0)
        return -1;
      out[i++] = c;
      continue;
    }
    out[i++] = *v++;
  }
  out[i] = '\0';
  /* Fail closed on truncation or unclosed string — never silent truncate. */
  return (*v == '"') ? 0 : -1;
}

int jmin_get_string_alloc(const char *json, const char *key, char **out, size_t *out_len,
                          size_t max_bytes) {
  if (!out)
    return -1;
  *out = NULL;
  if (out_len)
    *out_len = 0;

  const char *v = find_key(json, key);
  if (!v || *v != '"')
    return -1;
  v++;

  /* Pass 1: measure decoded length; reject oversize before allocate. */
  size_t n = 0;
  const char *p = v;
  while (*p && *p != '"') {
    if (*p == '\\' && p[1]) {
      p += 2;
      n++;
    } else {
      p++;
      n++;
    }
    if (n > max_bytes)
      return -2;
  }
  if (*p != '"')
    return -1;

  char *buf = (char *)malloc(n + 1);
  if (!buf)
    return -3;

  /* Pass 2: decode into heap buffer. */
  size_t i = 0;
  p = v;
  while (*p && *p != '"' && i < n) {
    if (*p == '\\' && p[1]) {
      p++;
      char c;
      if (decode_escape(&p, &c) != 0) {
        free(buf);
        return -1;
      }
      buf[i++] = c;
      continue;
    }
    buf[i++] = *p++;
  }
  if (*p != '"') {
    free(buf);
    return -1;
  }
  buf[i] = '\0';
  *out = buf;
  if (out_len)
    *out_len = i;
  return 0;
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

const char *jmin_get_array(const char *json, const char *key) {
  const char *v = find_key(json, key);
  if (!v || *v != '[')
    return NULL;
  return v;
}

/* Skip one JSON value starting at *p (string/number/bool/null/object/array).
 * Returns pointer past the value, or NULL on error. */
static const char *skip_value(const char *p) {
  p = skip_ws(p);
  if (!p || !*p)
    return NULL;
  if (*p == '"') {
    p++;
    while (*p && *p != '"') {
      if (*p == '\\' && p[1])
        p += 2;
      else
        p++;
    }
    return (*p == '"') ? p + 1 : NULL;
  }
  if (*p == '{' || *p == '[') {
    char open = *p;
    char close = (open == '{') ? '}' : ']';
    int depth = 1;
    p++;
    while (*p && depth > 0) {
      if (*p == '"') {
        p++;
        while (*p && *p != '"') {
          if (*p == '\\' && p[1])
            p += 2;
          else
            p++;
        }
        if (*p == '"')
          p++;
        continue;
      }
      if (*p == open)
        depth++;
      else if (*p == close)
        depth--;
      p++;
    }
    return depth == 0 ? p : NULL;
  }
  /* number / true / false / null */
  if (*p == '-' || (*p >= '0' && *p <= '9')) {
    if (*p == '-')
      p++;
    while (*p >= '0' && *p <= '9')
      p++;
    if (*p == '.') {
      p++;
      while (*p >= '0' && *p <= '9')
        p++;
    }
    return p;
  }
  if (strncmp(p, "true", 4) == 0)
    return p + 4;
  if (strncmp(p, "false", 5) == 0)
    return p + 5;
  if (strncmp(p, "null", 4) == 0)
    return p + 4;
  return NULL;
}

int jmin_array_next_object(const char **cursor, const char **obj) {
  if (!cursor || !*cursor || !obj)
    return -1;
  *obj = NULL;
  const char *p = skip_ws(*cursor);
  if (*p == '[')
    p = skip_ws(p + 1);
  else if (*p == ',')
    p = skip_ws(p + 1);
  if (*p == ']' || !*p) {
    *cursor = p;
    return -1;
  }
  if (*p != '{') {
    /* Non-object element: fail closed for object-array walkers. */
    *cursor = p;
    return -1;
  }
  *obj = p;
  const char *after = skip_value(p);
  if (!after)
    return -1;
  *cursor = after;
  return 0;
}

int jmin_array_next_string(const char **cursor, char *out, size_t out_cap) {
  if (!cursor || !*cursor || !out || out_cap == 0)
    return -1;
  out[0] = '\0';
  const char *p = skip_ws(*cursor);
  if (*p == '[')
    p = skip_ws(p + 1);
  else if (*p == ',')
    p = skip_ws(p + 1);
  if (*p == ']' || !*p) {
    *cursor = p;
    return -1;
  }
  if (*p != '"') {
    /* Non-string element: fail closed. */
    *cursor = p;
    return -1;
  }
  p++; /* past opening quote */
  size_t i = 0;
  while (*p && *p != '"' && i + 1 < out_cap) {
    if (*p == '\\' && p[1]) {
      p++;
      char c;
      if (decode_escape(&p, &c) != 0)
        return -1;
      out[i++] = c;
      continue;
    }
    out[i++] = *p++;
  }
  if (*p != '"')
    return -1; /* truncate or unclosed */
  out[i] = '\0';
  *cursor = p + 1;
  return 0;
}

/* Top-level key lookup inside one object `{...}` only (no sibling leak). */
static const char *find_key_in_object(const char *obj, const char *key) {
  if (!obj || *obj != '{' || !key)
    return NULL;
  char pat[128];
  size_t klen = strlen(key);
  if (klen + 3 >= sizeof(pat))
    return NULL;
  pat[0] = '"';
  memcpy(pat + 1, key, klen);
  pat[1 + klen] = '"';
  pat[2 + klen] = '\0';

  const char *p = skip_ws(obj + 1);
  while (*p && *p != '}') {
    if (*p == ',') {
      p = skip_ws(p + 1);
      continue;
    }
    if (*p != '"')
      return NULL; /* malformed member key */
    int match = (strncmp(p, pat, klen + 2) == 0);
    /* Skip key string. */
    p++;
    while (*p && *p != '"') {
      if (*p == '\\' && p[1])
        p += 2;
      else
        p++;
    }
    if (*p != '"')
      return NULL;
    p = skip_ws(p + 1);
    if (*p != ':')
      return NULL;
    p = skip_ws(p + 1);
    if (match)
      return p;
    /* Skip value and continue to next member. */
    p = skip_value(p);
    if (!p)
      return NULL;
    p = skip_ws(p);
  }
  return NULL;
}

int jmin_obj_get_string(const char *obj, const char *key, char *out, size_t out_cap) {
  if (!out || out_cap == 0)
    return -1;
  out[0] = '\0';
  const char *v = find_key_in_object(obj, key);
  if (!v || *v != '"')
    return -1;
  v++;
  size_t i = 0;
  while (*v && *v != '"' && i + 1 < out_cap) {
    if (*v == '\\' && v[1]) {
      v++;
      char c;
      if (decode_escape(&v, &c) != 0)
        return -1;
      out[i++] = c;
      continue;
    }
    out[i++] = *v++;
  }
  out[i] = '\0';
  return (*v == '"') ? 0 : -1;
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
