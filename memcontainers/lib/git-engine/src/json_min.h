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
/* Returns 1 when the top-level object contains key, otherwise 0. */
int jmin_has_member(const char *json, const char *key);
const char *jmin_args_object(const char *json);
const char *jmin_get_object(const char *json, const char *key);

/* Validate the complete Run request and extract its two schema fields.
 * Accepted shape is exactly {"op": string, "args"?: object}; duplicate or
 * unknown top-level keys, duplicate keys at any nesting level, invalid escapes,
 * excessive nesting/members, and trailing input are rejected. args_out points
 * into json when present, otherwise to a static empty object. */
int jmin_validate_request(const char *json, char *op, size_t op_cap, const char **args_out);
int jmin_validate_document(const char *json);

/* Bounded array walk (no full JSON library).
 * jmin_get_array: value start of key if it is '[' , else NULL.
 * jmin_array_next_object: walk objects inside an array; *cursor is in/out
 *   (init to array '[' or first element). Returns 0 and sets *obj to '{' of
 *   next object; 1 at the closing bracket; -1 for a non-object element.
 * jmin_array_next_string: walk string elements; *cursor in/out (init to '[').
 *   Returns 0 and fills out; 1 at the closing bracket; -1 for a non-string
 *   element.
 * jmin_obj_get_string: like jmin_get_string but only top-level keys of one
 *   object starting at '{' (does not leak into following siblings). */
const char *jmin_get_array(const char *json, const char *key);
int jmin_array_next_object(const char **cursor, const char **obj);
int jmin_array_next_string(const char **cursor, char *out, size_t out_cap);
int jmin_obj_get_string(const char *obj, const char *key, char *out, size_t out_cap);

char *jmin_escape(const char *s);
char *jmin_response(int ok, int code, const char *stdout_s, const char *stderr_s,
                    const char *result_json);

#endif
