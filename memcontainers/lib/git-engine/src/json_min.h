#ifndef JSON_MIN_H_
#define JSON_MIN_H_

#include <stddef.h>
#include <stdint.h>

int jmin_get_string(const char *json, const char *key, char *out, size_t out_cap);
int jmin_get_bool(const char *json, const char *key, int *out);
int jmin_get_int64(const char *json, const char *key, int64_t *out);
const char *jmin_args_object(const char *json);
char *jmin_escape(const char *s);
char *jmin_response(int ok, int code, const char *stdout_s, const char *stderr_s,
                    const char *result_json);

#endif
