#ifndef AGENT_OS_WAMR_PLATFORM_INTERNAL_H
#define AGENT_OS_WAMR_PLATFORM_INTERNAL_H

#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef BH_PLATFORM_AGENT_OS_WASM32
#define BH_PLATFORM_AGENT_OS_WASM32
#endif

typedef uintptr_t korp_tid;
typedef struct {
    uint32_t unused;
} korp_mutex;
typedef korp_mutex korp_cond;
typedef korp_mutex korp_rwlock;
typedef korp_mutex korp_sem;
typedef korp_tid korp_thread;

typedef int os_file_handle;
typedef int os_raw_file_handle;
typedef void *os_dir_stream;

#define OS_THREAD_MUTEX_INITIALIZER \
    { 0 }

#define BH_APPLET_PRESERVED_STACK_SIZE (2 * BH_KB)
#define BH_THREAD_DEFAULT_PRIORITY 0
#define BH_HAS_DLFCN 0
#define BUILTIN_LIBC_BUFFERED_PRINTF 0

#define os_getpagesize() 65536U
#define os_atomic_thread_fence(order) ((void)(order))
#define os_memory_order_acquire 0
#define os_memory_order_release 0
#define os_memory_order_seq_cst 0

static inline os_file_handle
os_get_invalid_handle(void)
{
    return -1;
}

static inline os_raw_file_handle
os_invalid_raw_handle(void)
{
    return -1;
}

#ifdef __cplusplus
}
#endif

#endif
