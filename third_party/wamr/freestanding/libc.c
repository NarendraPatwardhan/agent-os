#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct FILE FILE;

int errno;
FILE *stdin = 0;
FILE *stdout = 0;
FILE *stderr = 0;

extern unsigned char __heap_base;

typedef struct AllocBlock {
    size_t size;
    struct AllocBlock *next;
    bool free;
} AllocBlock;

static unsigned char *heap_cursor;
static AllocBlock *alloc_head;
static AllocBlock *alloc_tail;

static size_t align_up(size_t value, size_t align) {
    return (value + align - 1U) & ~(align - 1U);
}

static size_t alloc_header_size(void) {
    return align_up(sizeof(AllocBlock), 8U);
}

static unsigned char *alloc_payload(AllocBlock *block) {
    return (unsigned char *)block + alloc_header_size();
}

static AllocBlock *alloc_block_from_payload(void *ptr) {
    return (AllocBlock *)((unsigned char *)ptr - alloc_header_size());
}

static unsigned char *heap_end(void) {
    return (unsigned char *)(uintptr_t)(__builtin_wasm_memory_size(0) * 65536U);
}

static bool grow_heap_to(unsigned char *needed) {
    unsigned char *current_end = heap_end();
    if (needed <= current_end) return true;

    size_t missing = (size_t)(needed - current_end);
    size_t pages = (missing + 65535U) / 65536U;
    return __builtin_wasm_memory_grow(0, pages) != SIZE_MAX;
}

static void split_block(AllocBlock *block, size_t size) {
    size_t header_size = alloc_header_size();
    if (block->size < size + header_size + 8U) return;

    AllocBlock *next = (AllocBlock *)(alloc_payload(block) + size);
    next->size = block->size - size - header_size;
    next->next = block->next;
    next->free = true;
    block->size = size;
    block->next = next;
    if (alloc_tail == block) alloc_tail = next;
}

static void coalesce_blocks(void) {
    for (AllocBlock *block = alloc_head; block && block->next;) {
        unsigned char *block_end = alloc_payload(block) + block->size;
        if (block->free && block->next->free && block_end == (unsigned char *)block->next) {
            block->size += alloc_header_size() + block->next->size;
            block->next = block->next->next;
            if (!block->next) alloc_tail = block;
        } else {
            block = block->next;
        }
    }
}

void abort(void) {
    __builtin_trap();
    for (;;) {}
}

void exit(int status) {
    (void)status;
    abort();
}

void *malloc(size_t size) {
    if (size == 0) size = 1;
    size = align_up(size, 8U);

    for (AllocBlock *block = alloc_head; block; block = block->next) {
        if (block->free && block->size >= size) {
            split_block(block, size);
            block->free = false;
            return alloc_payload(block);
        }
    }

    size_t header_size = alloc_header_size();
    if (!heap_cursor) heap_cursor = (unsigned char *)align_up((uintptr_t)&__heap_base, 8U);

    unsigned char *block_addr = heap_cursor;
    unsigned char *next_cursor = block_addr + header_size + size;
    if (!grow_heap_to(next_cursor)) {
        errno = ENOMEM;
        return 0;
    }

    AllocBlock *block = (AllocBlock *)block_addr;
    block->size = size;
    block->next = 0;
    block->free = false;

    if (alloc_tail) {
        alloc_tail->next = block;
    } else {
        alloc_head = block;
    }
    alloc_tail = block;
    heap_cursor = next_cursor;
    return alloc_payload(block);
}

void free(void *ptr) {
    if (!ptr) return;
    AllocBlock *block = alloc_block_from_payload(ptr);
    block->free = true;
    coalesce_blocks();
}

void *realloc(void *ptr, size_t size) {
    if (!ptr) return malloc(size);
    if (size == 0) {
        free(ptr);
        return 0;
    }

    AllocBlock *block = alloc_block_from_payload(ptr);
    if (block->size >= size) {
        split_block(block, align_up(size, 8U));
        return ptr;
    }

    void *new_ptr = malloc(size);
    if (!new_ptr) return 0;
    size_t copy_size = block->size < size ? block->size : size;
    unsigned char *dest = (unsigned char *)new_ptr;
    unsigned char *src = (unsigned char *)ptr;
    for (size_t i = 0; i < copy_size; i += 1) dest[i] = src[i];
    free(ptr);
    return new_ptr;
}

void *calloc(size_t count, size_t size) {
    if (size != 0 && count > SIZE_MAX / size) {
        errno = ENOMEM;
        return 0;
    }
    size_t total = count * size;
    void *ptr = malloc(total);
    if (!ptr) return 0;
    unsigned char *bytes = (unsigned char *)ptr;
    for (size_t i = 0; i < total; i += 1) bytes[i] = 0;
    return ptr;
}

int abs(int value) {
    return value < 0 ? -value : value;
}

static void swap_bytes(unsigned char *a, unsigned char *b, size_t size) {
    for (size_t i = 0; i < size; i += 1) {
        unsigned char tmp = a[i];
        a[i] = b[i];
        b[i] = tmp;
    }
}

void qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *)) {
    unsigned char *items = (unsigned char *)base;
    if (!items || size == 0 || nmemb < 2) return;

    for (size_t i = 0; i + 1 < nmemb; i += 1) {
        for (size_t j = i + 1; j < nmemb; j += 1) {
            unsigned char *left = items + i * size;
            unsigned char *right = items + j * size;
            if (compar(left, right) > 0) swap_bytes(left, right, size);
        }
    }
}

void *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
              int (*compar)(const void *, const void *)) {
    const unsigned char *items = (const unsigned char *)base;
    size_t low = 0;
    size_t high = nmemb;

    while (low < high) {
        size_t mid = low + (high - low) / 2;
        const void *item = items + mid * size;
        int cmp = compar(key, item);
        if (cmp == 0) return (void *)item;
        if (cmp < 0) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }

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

    while (isspace((unsigned char)*p)) p += 1;

    for (;;) {
        int digit = digit_value(*p);
        if (digit < 0 || digit >= actual_base) break;
        out = out * (unsigned long long)actual_base + (unsigned long long)digit;
        p += 1;
    }

    if (endptr) *endptr = (char *)p;
    return out;
}

long long strtoll(const char *nptr, char **endptr, int base) {
    const char *p = nptr;
    int negative = 0;
    while (isspace((unsigned char)*p)) p += 1;
    if (*p == '-' || *p == '+') {
        negative = *p == '-';
        p += 1;
    }
    unsigned long long value = strtoull(p, endptr, base);
    return negative ? -(long long)value : (long long)value;
}

unsigned long strtoul(const char *nptr, char **endptr, int base) {
    return (unsigned long)strtoull(nptr, endptr, base);
}

long strtol(const char *nptr, char **endptr, int base) {
    return (long)strtoll(nptr, endptr, base);
}

int atoi(const char *nptr) {
    return (int)strtol(nptr, 0, 10);
}

double strtod(const char *nptr, char **endptr) {
    const char *p = nptr;
    double sign = 1.0;
    double out = 0.0;

    while (isspace((unsigned char)*p)) p += 1;
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

char *strncpy(char *dest, const char *src, size_t n) {
    size_t i = 0;
    for (; i < n && src[i] != 0; i += 1) dest[i] = src[i];
    for (; i < n; i += 1) dest[i] = 0;
    return dest;
}

char *strcat(char *dest, const char *src) {
    strcpy(dest + strlen(dest), src);
    return dest;
}

char *strchr(const char *s, int c) {
    for (;; s += 1) {
        if (*s == (char)c) return (char *)s;
        if (*s == 0) return 0;
    }
}

char *strrchr(const char *s, int c) {
    const char *last = 0;
    for (;; s += 1) {
        if (*s == (char)c) last = s;
        if (*s == 0) return (char *)last;
    }
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

static void out_ch(char *buffer, size_t size, size_t *pos, char c) {
    if (buffer && size > 0 && *pos + 1 < size) buffer[*pos] = c;
    *pos += 1;
}

static void out_str(char *buffer, size_t size, size_t *pos, const char *s) {
    if (!s) s = "(null)";
    while (*s) {
        out_ch(buffer, size, pos, *s);
        s += 1;
    }
}

static void out_unsigned(char *buffer, size_t size, size_t *pos, unsigned long long value,
                         unsigned base, int uppercase, int width, char pad) {
    char tmp[32];
    size_t n = 0;
    const char *digits = uppercase ? "0123456789ABCDEF" : "0123456789abcdef";

    if (base < 2) base = 10;
    do {
        tmp[n++] = digits[value % base];
        value /= base;
    } while (value && n < sizeof(tmp));

    while ((int)n < width) {
        out_ch(buffer, size, pos, pad);
        width -= 1;
    }
    while (n > 0) out_ch(buffer, size, pos, tmp[--n]);
}

static void out_signed(char *buffer, size_t size, size_t *pos, long long value,
                       int width, char pad) {
    unsigned long long magnitude;
    if (value < 0) {
        out_ch(buffer, size, pos, '-');
        magnitude = (unsigned long long)(-(value + 1)) + 1;
    } else {
        magnitude = (unsigned long long)value;
    }
    out_unsigned(buffer, size, pos, magnitude, 10, 0, width, pad);
}

int vsnprintf(char *buffer, size_t size, const char *format, va_list ap) {
    size_t pos = 0;

    for (const char *p = format; p && *p; p += 1) {
        if (*p != '%') {
            out_ch(buffer, size, &pos, *p);
            continue;
        }

        p += 1;
        if (*p == '%') {
            out_ch(buffer, size, &pos, '%');
            continue;
        }

        char pad = ' ';
        if (*p == '0') {
            pad = '0';
            p += 1;
        }

        int width = 0;
        while (*p >= '0' && *p <= '9') {
            width = width * 10 + (*p - '0');
            p += 1;
        }

        int long_count = 0;
        if (*p == 'l') {
            long_count = 1;
            p += 1;
            if (*p == 'l') {
                long_count = 2;
                p += 1;
            }
        } else if (*p == 'z' || *p == 't' || *p == 'j') {
            long_count = 2;
            p += 1;
        }

        switch (*p) {
            case 's':
                out_str(buffer, size, &pos, va_arg(ap, const char *));
                break;
            case 'c':
                out_ch(buffer, size, &pos, (char)va_arg(ap, int));
                break;
            case 'd':
            case 'i':
                if (long_count >= 2)
                    out_signed(buffer, size, &pos, va_arg(ap, long long), width, pad);
                else if (long_count == 1)
                    out_signed(buffer, size, &pos, va_arg(ap, long), width, pad);
                else
                    out_signed(buffer, size, &pos, va_arg(ap, int), width, pad);
                break;
            case 'u':
                if (long_count >= 2)
                    out_unsigned(buffer, size, &pos, va_arg(ap, unsigned long long), 10, 0, width, pad);
                else if (long_count == 1)
                    out_unsigned(buffer, size, &pos, va_arg(ap, unsigned long), 10, 0, width, pad);
                else
                    out_unsigned(buffer, size, &pos, va_arg(ap, unsigned int), 10, 0, width, pad);
                break;
            case 'x':
            case 'X':
                if (long_count >= 2)
                    out_unsigned(buffer, size, &pos, va_arg(ap, unsigned long long), 16, *p == 'X', width, pad);
                else if (long_count == 1)
                    out_unsigned(buffer, size, &pos, va_arg(ap, unsigned long), 16, *p == 'X', width, pad);
                else
                    out_unsigned(buffer, size, &pos, va_arg(ap, unsigned int), 16, *p == 'X', width, pad);
                break;
            case 'p':
                out_str(buffer, size, &pos, "0x");
                out_unsigned(buffer, size, &pos, (unsigned long long)(uintptr_t)va_arg(ap, void *), 16, 0, width, '0');
                break;
            default:
                out_ch(buffer, size, &pos, '%');
                if (*p) out_ch(buffer, size, &pos, *p);
                break;
        }
    }

    if (buffer && size > 0) {
        if (pos < size)
            buffer[pos] = 0;
        else
            buffer[size - 1] = 0;
    }
    return (int)pos;
}

int snprintf(char *buffer, size_t size, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(buffer, size, format, ap);
    va_end(ap);
    return n;
}

int sprintf(char *buffer, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(buffer, (size_t)-1, format, ap);
    va_end(ap);
    return n;
}

int vprintf(const char *format, va_list ap) {
    char buffer[256];
    return vsnprintf(buffer, sizeof(buffer), format, ap);
}

int printf(const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    int n = vprintf(format, ap);
    va_end(ap);
    return n;
}

int vfprintf(FILE *stream, const char *format, va_list ap) {
    (void)stream;
    return vprintf(format, ap);
}

int fprintf(FILE *stream, const char *format, ...) {
    va_list ap;
    (void)stream;
    va_start(ap, format);
    int n = vprintf(format, ap);
    va_end(ap);
    return n;
}

int puts(const char *s) {
    return printf("%s\n", s);
}
