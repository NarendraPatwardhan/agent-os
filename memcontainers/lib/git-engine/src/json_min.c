/* Bounded JSON parser for the Run ABI (no third-party dependency).
 *
 * This is deliberately small, but it is a parser rather than a substring
 * scanner: member lookup is scoped to one object, strings and numbers follow
 * JSON grammar, duplicate members are rejected during validation, and the Run
 * request has one exact top-level schema. */

#include "json_min.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define JMIN_MAX_DEPTH 64
#define JMIN_MAX_MEMBERS 256
#define JMIN_MAX_KEY_BYTES 255
#define JMIN_MAX_NODES 4096

typedef struct {
    unsigned depth;
    unsigned nodes;
} parse_ctx;

static const char *skip_ws(const char *p) {
    while (p && *p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r'))
        p++;
    return p;
}

static int hex_nibble(unsigned char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

static int read_hex4(const char *p, uint32_t *out) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        if (p[i] == '\0')
            return -1;
        int h = hex_nibble((unsigned char)p[i]);
        if (h < 0)
            return -1;
        v = (v << 4) | (uint32_t)h;
    }
    *out = v;
    return 0;
}

/* Validate one raw UTF-8 sequence. p points immediately after lead. */
static int utf8_tail_bytes(unsigned char lead, const char *p) {
    unsigned char b0 = (unsigned char)p[0];
    if (lead >= 0xc2 && lead <= 0xdf)
        return b0 >= 0x80 && b0 <= 0xbf ? 1 : -1;

    if (b0 == 0 || b0 < 0x80 || b0 > 0xbf)
        return -1;
    unsigned char b1 = (unsigned char)p[1];
    if (lead >= 0xe0 && lead <= 0xef) {
        if (b1 < 0x80 || b1 > 0xbf)
            return -1;
        if (lead == 0xe0 && b0 < 0xa0)
            return -1; /* overlong */
        if (lead == 0xed && b0 > 0x9f)
            return -1; /* surrogate */
        return 2;
    }

    if (lead < 0xf0 || lead > 0xf4 || b1 < 0x80 || b1 > 0xbf)
        return -1;
    unsigned char b2 = (unsigned char)p[2];
    if (b2 < 0x80 || b2 > 0xbf)
        return -1;
    if (lead == 0xf0 && b0 < 0x90)
        return -1; /* overlong */
    if (lead == 0xf4 && b0 > 0x8f)
        return -1; /* above U+10FFFF */
    return 3;
}

static int put_utf8(uint32_t cp, char *out, size_t cap, size_t *used) {
    unsigned char bytes[4];
    size_t n;
    if (cp == 0 || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))
        return -1; /* C-string ABI cannot represent U+0000. */
    if (cp <= 0x7f) {
        bytes[0] = (unsigned char)cp;
        n = 1;
    } else if (cp <= 0x7ff) {
        bytes[0] = (unsigned char)(0xc0 | (cp >> 6));
        bytes[1] = (unsigned char)(0x80 | (cp & 0x3f));
        n = 2;
    } else if (cp <= 0xffff) {
        bytes[0] = (unsigned char)(0xe0 | (cp >> 12));
        bytes[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
        bytes[2] = (unsigned char)(0x80 | (cp & 0x3f));
        n = 3;
    } else {
        bytes[0] = (unsigned char)(0xf0 | (cp >> 18));
        bytes[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3f));
        bytes[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
        bytes[3] = (unsigned char)(0x80 | (cp & 0x3f));
        n = 4;
    }
    if (out) {
        if (*used + n >= cap)
            return -2;
        memcpy(out + *used, bytes, n);
    }
    *used += n;
    return 0;
}

/* Parse a JSON string, optionally decoding it. end points after closing quote. */
static int parse_string(const char *p, const char **end, char *out, size_t cap,
                        size_t *decoded_len) {
    if (!p || *p != '"')
        return -1;
    p++;
    size_t used = 0;
    while (*p && *p != '"') {
        unsigned char c = (unsigned char)*p++;
        if (c < 0x20)
            return -1;
        if (c != '\\') {
            int tail = c < 0x80 ? 0 : utf8_tail_bytes(c, p);
            if (tail < 0)
                return -1;
            if (out) {
                if (used + 1 + (size_t)tail >= cap)
                    return -2;
                out[used] = (char)c;
                if (tail)
                    memcpy(out + used + 1, p, (size_t)tail);
            }
            used += 1 + (size_t)tail;
            p += tail;
            continue;
        }
        unsigned char esc = (unsigned char)*p++;
        if (!esc)
            return -1;
        uint32_t cp = 0;
        switch (esc) {
        case '"':
            cp = '"';
            break;
        case '\\':
            cp = '\\';
            break;
        case '/':
            cp = '/';
            break;
        case 'b':
            cp = '\b';
            break;
        case 'f':
            cp = '\f';
            break;
        case 'n':
            cp = '\n';
            break;
        case 'r':
            cp = '\r';
            break;
        case 't':
            cp = '\t';
            break;
        case 'u': {
            if (read_hex4(p, &cp) != 0)
                return -1;
            p += 4;
            if (cp >= 0xd800 && cp <= 0xdbff) {
                uint32_t low = 0;
                if (p[0] != '\\' || p[1] != 'u' || read_hex4(p + 2, &low) != 0 || low < 0xdc00 ||
                    low > 0xdfff)
                    return -1;
                p += 6;
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
            } else if (cp >= 0xdc00 && cp <= 0xdfff) {
                return -1;
            }
            break;
        }
        default:
            return -1;
        }
        if (put_utf8(cp, out, cap, &used) != 0)
            return -2;
    }
    if (*p != '"')
        return -1;
    if (out) {
        if (used >= cap)
            return -2;
        out[used] = '\0';
    }
    if (decoded_len)
        *decoded_len = used;
    if (end)
        *end = p + 1;
    return 0;
}

static const char *parse_value(const char *p, parse_ctx *ctx);

static int key_seen_before(const char *obj_start, const char *current, const char *key) {
    const char *p = skip_ws(obj_start + 1);
    while (p && p < current) {
        char prior[JMIN_MAX_KEY_BYTES + 1];
        const char *after_key = NULL;
        if (parse_string(p, &after_key, prior, sizeof(prior), NULL) != 0)
            return 1;
        if (strcmp(prior, key) == 0)
            return 1;
        p = skip_ws(after_key);
        if (*p++ != ':')
            return 1;
        parse_ctx scan = {0, 0};
        p = parse_value(skip_ws(p), &scan);
        if (!p)
            return 1;
        p = skip_ws(p);
        if (*p == ',')
            p = skip_ws(p + 1);
    }
    return 0;
}

static const char *parse_object(const char *p, parse_ctx *ctx) {
    if (!p || *p != '{' || ctx->depth >= JMIN_MAX_DEPTH)
        return NULL;
    const char *start = p++;
    ctx->depth++;
    unsigned members = 0;
    p = skip_ws(p);
    if (*p == '}') {
        ctx->depth--;
        return p + 1;
    }
    for (;;) {
        if (++members > JMIN_MAX_MEMBERS || ++ctx->nodes > JMIN_MAX_NODES)
            return NULL;
        const char *key_at = p;
        char key[JMIN_MAX_KEY_BYTES + 1];
        const char *after_key = NULL;
        if (parse_string(p, &after_key, key, sizeof(key), NULL) != 0 ||
            key_seen_before(start, key_at, key))
            return NULL;
        p = skip_ws(after_key);
        if (*p != ':')
            return NULL;
        p = parse_value(skip_ws(p + 1), ctx);
        if (!p)
            return NULL;
        p = skip_ws(p);
        if (*p == '}') {
            ctx->depth--;
            return p + 1;
        }
        if (*p != ',')
            return NULL;
        p = skip_ws(p + 1);
    }
}

static const char *parse_array(const char *p, parse_ctx *ctx) {
    if (!p || *p != '[' || ctx->depth >= JMIN_MAX_DEPTH)
        return NULL;
    p = skip_ws(p + 1);
    ctx->depth++;
    if (*p == ']') {
        ctx->depth--;
        return p + 1;
    }
    for (;;) {
        if (++ctx->nodes > JMIN_MAX_NODES)
            return NULL;
        p = parse_value(p, ctx);
        if (!p)
            return NULL;
        p = skip_ws(p);
        if (*p == ']') {
            ctx->depth--;
            return p + 1;
        }
        if (*p != ',')
            return NULL;
        p = skip_ws(p + 1);
    }
}

static const char *parse_number(const char *p) {
    if (*p == '-')
        p++;
    if (*p == '0') {
        p++;
        if (isdigit((unsigned char)*p))
            return NULL;
    } else if (*p >= '1' && *p <= '9') {
        do {
            p++;
        } while (isdigit((unsigned char)*p));
    } else {
        return NULL;
    }
    if (*p == '.') {
        p++;
        if (!isdigit((unsigned char)*p))
            return NULL;
        do {
            p++;
        } while (isdigit((unsigned char)*p));
    }
    if (*p == 'e' || *p == 'E') {
        p++;
        if (*p == '+' || *p == '-')
            p++;
        if (!isdigit((unsigned char)*p))
            return NULL;
        do {
            p++;
        } while (isdigit((unsigned char)*p));
    }
    return p;
}

static const char *parse_value(const char *p, parse_ctx *ctx) {
    p = skip_ws(p);
    if (!p || !*p)
        return NULL;
    if (*p == '"') {
        const char *end = NULL;
        return parse_string(p, &end, NULL, 0, NULL) == 0 ? end : NULL;
    }
    if (*p == '{')
        return parse_object(p, ctx);
    if (*p == '[')
        return parse_array(p, ctx);
    if (strncmp(p, "true", 4) == 0)
        return p + 4;
    if (strncmp(p, "false", 5) == 0)
        return p + 5;
    if (strncmp(p, "null", 4) == 0)
        return p + 4;
    return parse_number(p);
}

static const char *find_member(const char *obj, const char *wanted) {
    if (!obj || *skip_ws(obj) != '{' || !wanted)
        return NULL;
    const char *p = skip_ws(obj);
    p = skip_ws(p + 1);
    while (*p && *p != '}') {
        char key[JMIN_MAX_KEY_BYTES + 1];
        const char *after_key = NULL;
        if (parse_string(p, &after_key, key, sizeof(key), NULL) != 0)
            return NULL;
        p = skip_ws(after_key);
        if (*p != ':')
            return NULL;
        const char *value = skip_ws(p + 1);
        if (strcmp(key, wanted) == 0)
            return value;
        parse_ctx ctx = {0, 0};
        p = parse_value(value, &ctx);
        if (!p)
            return NULL;
        p = skip_ws(p);
        if (*p == ',')
            p = skip_ws(p + 1);
    }
    return NULL;
}

int jmin_validate_request(const char *json, char *op, size_t op_cap, const char **args_out) {
    static const char empty_args[] = "{}";
    if (!json || !op || op_cap == 0 || !args_out)
        return -1;
    op[0] = '\0';
    *args_out = empty_args;
    const char *root = skip_ws(json);
    parse_ctx ctx = {0, 0};
    const char *end = parse_value(root, &ctx);
    if (!end || *skip_ws(end) != '\0' || *root != '{')
        return -1;

    const char *p = skip_ws(root + 1);
    int saw_op = 0, saw_args = 0;
    while (*p != '}') {
        char key[JMIN_MAX_KEY_BYTES + 1];
        const char *after_key = NULL;
        if (parse_string(p, &after_key, key, sizeof(key), NULL) != 0)
            return -1;
        p = skip_ws(after_key);
        if (*p != ':')
            return -1;
        const char *value = skip_ws(p + 1);
        if (strcmp(key, "op") == 0) {
            if (saw_op || parse_string(value, NULL, op, op_cap, NULL) != 0 || !op[0])
                return -1;
            saw_op = 1;
        } else if (strcmp(key, "args") == 0) {
            if (saw_args || *value != '{')
                return -1;
            *args_out = value;
            saw_args = 1;
        } else {
            return -1;
        }
        parse_ctx step = {0, 0};
        p = parse_value(value, &step);
        if (!p)
            return -1;
        p = skip_ws(p);
        if (*p == ',')
            p = skip_ws(p + 1);
        else if (*p != '}')
            return -1;
    }
    return saw_op ? 0 : -1;
}

int jmin_validate_document(const char *json) {
    if (!json)
        return -1;
    parse_ctx ctx = {0, 0};
    const char *end = parse_value(skip_ws(json), &ctx);
    return end && *skip_ws(end) == '\0' ? 0 : -1;
}

int jmin_get_string(const char *json, const char *key, char *out, size_t out_cap) {
    if (!out || out_cap == 0)
        return -1;
    out[0] = '\0';
    const char *v = find_member(skip_ws(json), key);
    return v ? parse_string(v, NULL, out, out_cap, NULL) : -1;
}

int jmin_get_string_alloc(const char *json, const char *key, char **out, size_t *out_len,
                          size_t max_bytes) {
    if (!out)
        return -1;
    *out = NULL;
    if (out_len)
        *out_len = 0;
    const char *v = find_member(skip_ws(json), key);
    size_t n = 0;
    if (!v || parse_string(v, NULL, NULL, 0, &n) != 0)
        return -1;
    if (n > max_bytes)
        return -2;
    char *buf = (char *)malloc(n + 1);
    if (!buf)
        return -3;
    if (parse_string(v, NULL, buf, n + 1, &n) != 0) {
        free(buf);
        return -1;
    }
    *out = buf;
    if (out_len)
        *out_len = n;
    return 0;
}

int jmin_get_bool(const char *json, const char *key, int *out) {
    if (!out)
        return -1;
    const char *v = find_member(skip_ws(json), key);
    if (v && strncmp(v, "true", 4) == 0) {
        *out = 1;
        return 0;
    }
    if (v && strncmp(v, "false", 5) == 0) {
        *out = 0;
        return 0;
    }
    return -1;
}

int jmin_get_int64(const char *json, const char *key, int64_t *out) {
    if (!out)
        return -1;
    const char *v = find_member(skip_ws(json), key);
    const char *end = v ? parse_number(v) : NULL;
    if (!end)
        return -1;
    errno = 0;
    char *converted = NULL;
    long long n = strtoll(v, &converted, 10);
    if (errno == ERANGE || converted != end || n < INT64_MIN || n > INT64_MAX)
        return -1;
    *out = (int64_t)n;
    return 0;
}

int jmin_has_member(const char *json, const char *key) {
    return find_member(skip_ws(json), key) ? 1 : 0;
}

const char *jmin_args_object(const char *json) {
    const char *v = find_member(skip_ws(json), "args");
    return v && *v == '{' ? v : NULL;
}

const char *jmin_get_object(const char *json, const char *key) {
    const char *v = find_member(skip_ws(json), key);
    return v && *v == '{' ? v : NULL;
}

const char *jmin_get_array(const char *json, const char *key) {
    const char *v = find_member(skip_ws(json), key);
    return v && *v == '[' ? v : NULL;
}

int jmin_array_next_object(const char **cursor, const char **obj) {
    if (!cursor || !*cursor || !obj)
        return -1;
    const char *p = skip_ws(*cursor);
    if (*p == '[' || *p == ',')
        p = skip_ws(p + 1);
    if (*p == ']') {
        *cursor = p;
        return 1;
    }
    if (*p != '{') {
        *cursor = p;
        return -1;
    }
    parse_ctx ctx = {0, 0};
    const char *end = parse_value(p, &ctx);
    if (!end)
        return -1;
    *obj = p;
    *cursor = end;
    return 0;
}

int jmin_array_next_string(const char **cursor, char *out, size_t out_cap) {
    if (!cursor || !*cursor || !out || out_cap == 0)
        return -1;
    const char *p = skip_ws(*cursor);
    if (*p == '[' || *p == ',')
        p = skip_ws(p + 1);
    if (*p == ']') {
        *cursor = p;
        return 1;
    }
    if (*p != '"') {
        *cursor = p;
        return -1;
    }
    const char *end = NULL;
    if (parse_string(p, &end, out, out_cap, NULL) != 0)
        return -1;
    *cursor = end;
    return 0;
}

int jmin_obj_get_string(const char *obj, const char *key, char *out, size_t out_cap) {
    return jmin_get_string(obj, key, out, out_cap);
}

char *jmin_escape(const char *s) {
    if (!s)
        s = "";
    size_t n = 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        n += (*p == '"' || *p == '\\' || *p == '\b' || *p == '\f' || *p == '\n' || *p == '\r' ||
              *p == '\t')
                 ? 2
                 : (*p < 0x20 ? 6 : 1);
    char *o = (char *)malloc(n + 1);
    if (!o)
        return NULL;
    char *w = o;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        switch (*p) {
        case '"':
            *w++ = '\\';
            *w++ = '"';
            break;
        case '\\':
            *w++ = '\\';
            *w++ = '\\';
            break;
        case '\b':
            *w++ = '\\';
            *w++ = 'b';
            break;
        case '\f':
            *w++ = '\\';
            *w++ = 'f';
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
            if (*p < 0x20) {
                snprintf(w, 7, "\\u%04x", (unsigned)*p);
                w += 6;
            } else {
                *w++ = (char)*p;
            }
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
    size_t cap = strlen(esc_out) + strlen(esc_err) + (result_json ? strlen(result_json) : 0) + 128;
    char *buf = (char *)malloc(cap);
    if (!buf) {
        free(esc_out);
        free(esc_err);
        return NULL;
    }
    if (result_json && result_json[0])
        snprintf(buf, cap,
                 "{\"ok\":%s,\"code\":%d,\"stdout\":\"%s\",\"stderr\":\"%s\",\"result\":%s}",
                 ok ? "true" : "false", code, esc_out, esc_err, result_json);
    else
        snprintf(buf, cap, "{\"ok\":%s,\"code\":%d,\"stdout\":\"%s\",\"stderr\":\"%s\"}",
                 ok ? "true" : "false", code, esc_out, esc_err);
    free(esc_out);
    free(esc_err);
    return buf;
}
