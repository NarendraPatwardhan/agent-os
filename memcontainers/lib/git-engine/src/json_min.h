#ifndef JSON_MIN_H_
#define JSON_MIN_H_

#include <stddef.h>
#include <stdint.h>

int jmin_get_string(const char *json, const char *key, char *out, size_t out_cap);
/* Heap-allocate decoded string. max_bytes is the decoded-byte cap (not JSON span).
 * On success: returns 0, *out is malloc'd (caller free()s), *out_len is set if non-NULL.
 * On miss/invalid: -1 and *out = NULL.
 * On oversize: -2 and *out = NULL (fail closed, never truncate).
 * On OOM: -3 and *out = NULL. */
int jmin_get_string_alloc(const char *json, const char *key, char **out, size_t *out_len,
                          size_t max_bytes);
int jmin_get_bool(const char *json, const char *key, int *out);
int jmin_get_int64(const char *json, const char *key, int64_t *out);
const char *jmin_args_object(const char *json);

/* Bounded array walk (no full JSON library).
 * jmin_get_array: value start of key if it is '[' , else NULL.
 * jmin_array_next_object: walk objects inside an array; *cursor is in/out
 *   (init to array '[' or first element). Returns 0 and sets *obj to '{' of
 *   next object; -1 when exhausted or non-object element.
 * jmin_obj_get_string: like jmin_get_string but only top-level keys of one
 *   object starting at '{' (does not leak into following siblings). */
const char *jmin_get_array(const char *json, const char *key);
int jmin_array_next_object(const char **cursor, const char **obj);
int jmin_obj_get_string(const char *obj, const char *key, char *out, size_t out_cap);

char *jmin_escape(const char *s);
char *jmin_response(int ok, int code, const char *stdout_s, const char *stderr_s,
                    const char *result_json);

#endif
