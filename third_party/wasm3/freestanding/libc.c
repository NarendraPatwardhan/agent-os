#include <stdarg.h>
#include <stddef.h>

typedef struct FILE FILE;

FILE *stderr = 0;

void abort(void) {
    __builtin_trap();
    for (;;) {}
}

void *calloc(size_t count, size_t size) {
    (void)count;
    (void)size;
    return 0;
}

void free(void *ptr) {
    (void)ptr;
}

void *realloc(void *ptr, size_t size) {
    (void)ptr;
    (void)size;
    return 0;
}

static int digit_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return -1;
}

unsigned long long strtoull(const char *nptr, char **endptr, int base) {
    const char *p = nptr;
    unsigned long long out = 0;
    int actual_base = base == 0 ? 10 : base;

    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p += 1;

    for (;;) {
        int digit = digit_value(*p);
        if (digit < 0 || digit >= actual_base) break;
        out = out * (unsigned long long)actual_base + (unsigned long long)digit;
        p += 1;
    }

    if (endptr) *endptr = (char *)p;
    return out;
}

unsigned long strtoul(const char *nptr, char **endptr, int base) {
    return (unsigned long)strtoull(nptr, endptr, base);
}

double strtod(const char *nptr, char **endptr) {
    const char *p = nptr;
    double sign = 1.0;
    double out = 0.0;

    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p += 1;
    if (*p == '-') {
        sign = -1.0;
        p += 1;
    } else if (*p == '+') {
        p += 1;
    }

    while (*p >= '0' && *p <= '9') {
        out = out * 10.0 + (double)(*p - '0');
        p += 1;
    }

    if (*p == '.') {
        double scale = 0.1;
        p += 1;
        while (*p >= '0' && *p <= '9') {
            out += (double)(*p - '0') * scale;
            scale *= 0.1;
            p += 1;
        }
    }

    if (endptr) *endptr = (char *)p;
    return sign * out;
}

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i += 1) d[i] = s[i];
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        for (size_t i = 0; i < n; i += 1) d[i] = s[i];
    } else if (d > s) {
        for (size_t i = n; i > 0; i -= 1) d[i - 1] = s[i - 1];
    }
    return dest;
}

void *memset(void *s, int c, size_t n) {
    unsigned char *p = (unsigned char *)s;
    for (size_t i = 0; i < n; i += 1) p[i] = (unsigned char)c;
    return s;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *pa = (const unsigned char *)a;
    const unsigned char *pb = (const unsigned char *)b;
    for (size_t i = 0; i < n; i += 1) {
        if (pa[i] != pb[i]) return (int)pa[i] - (int)pb[i];
    }
    return 0;
}

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n] != 0) n += 1;
    return n;
}

int strcmp(const char *a, const char *b) {
    while (*a != 0 && *a == *b) {
        a += 1;
        b += 1;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i += 1) {
        unsigned char ca = (unsigned char)a[i];
        unsigned char cb = (unsigned char)b[i];
        if (ca != cb || ca == 0) return (int)ca - (int)cb;
    }
    return 0;
}

char *strcpy(char *dest, const char *src) {
    char *out = dest;
    while ((*dest++ = *src++) != 0) {}
    return out;
}

char *strstr(const char *haystack, const char *needle) {
    if (*needle == 0) return (char *)haystack;
    for (; *haystack != 0; haystack += 1) {
        const char *h = haystack;
        const char *n = needle;
        while (*h != 0 && *n != 0 && *h == *n) {
            h += 1;
            n += 1;
        }
        if (*n == 0) return (char *)haystack;
    }
    return 0;
}

static int write_empty(char *buffer, size_t size) {
    if (buffer && size > 0) buffer[0] = 0;
    return 0;
}

int printf(const char *format, ...) {
    (void)format;
    return 0;
}

int fprintf(FILE *stream, const char *format, ...) {
    (void)stream;
    (void)format;
    return 0;
}

int snprintf(char *buffer, size_t size, const char *format, ...) {
    (void)format;
    return write_empty(buffer, size);
}

int sprintf(char *buffer, const char *format, ...) {
    (void)format;
    return write_empty(buffer, (size_t)1);
}

int puts(const char *s) {
    (void)s;
    return 0;
}
