#ifndef AGENT_OS_WAMR_CTYPE_H
#define AGENT_OS_WAMR_CTYPE_H

static inline int isspace(int c) {
    return c == ' ' || c == '\f' || c == '\n' || c == '\r' || c == '\t' || c == '\v';
}

static inline int isdigit(int c) {
    return c >= '0' && c <= '9';
}

static inline int isxdigit(int c) {
    return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static inline int isalpha(int c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static inline int isalnum(int c) {
    return isalpha(c) || isdigit(c);
}

static inline int isprint(int c) {
    return c >= 0x20 && c <= 0x7e;
}

static inline int tolower(int c) {
    return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
}

static inline int toupper(int c) {
    return c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c;
}

#endif
