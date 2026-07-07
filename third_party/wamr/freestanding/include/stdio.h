#ifndef AGENT_OS_WAMR_STDIO_H
#define AGENT_OS_WAMR_STDIO_H

#include <stdarg.h>
#include <stddef.h>

typedef struct FILE FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

int printf(const char *format, ...);
int vprintf(const char *format, va_list ap);
int fprintf(FILE *stream, const char *format, ...);
int vfprintf(FILE *stream, const char *format, va_list ap);
int snprintf(char *buffer, size_t size, const char *format, ...);
int vsnprintf(char *buffer, size_t size, const char *format, va_list ap);
int sprintf(char *buffer, const char *format, ...);
int puts(const char *s);

#endif
