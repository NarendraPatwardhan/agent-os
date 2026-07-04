#ifndef AGENT_OS_WASM3_STDIO_H
#define AGENT_OS_WASM3_STDIO_H

#include <stddef.h>

typedef struct FILE FILE;

extern FILE *stderr;

int printf(const char *format, ...);
int fprintf(FILE *stream, const char *format, ...);
int snprintf(char *buffer, size_t size, const char *format, ...);
int sprintf(char *buffer, const char *format, ...);
int puts(const char *s);

#endif
