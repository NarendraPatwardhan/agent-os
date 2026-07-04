#ifndef AGENT_OS_WASM3_STDLIB_H
#define AGENT_OS_WASM3_STDLIB_H

#include <stddef.h>

#ifndef NULL
#define NULL ((void *)0)
#endif

void abort(void) __attribute__((noreturn));
void *calloc(size_t count, size_t size);
void free(void *ptr);
void *realloc(void *ptr, size_t size);
unsigned long strtoul(const char *nptr, char **endptr, int base);
unsigned long long strtoull(const char *nptr, char **endptr, int base);
double strtod(const char *nptr, char **endptr);

#endif
