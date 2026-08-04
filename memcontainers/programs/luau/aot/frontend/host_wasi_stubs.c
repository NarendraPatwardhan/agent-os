// Close the libc/libc++ WASI surface for the optional host compiler. These deterministic local
// definitions provide no filesystem, environment, clock, or process authority. They are ordinary
// definitions, not product exports.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum {
    MC_WASI_EBADF = 8,
};

static void write_u32(int32_t pointer, uint32_t value) {
    memcpy((void *)(uintptr_t)(uint32_t)pointer, &value, sizeof(value));
}

static void write_u64(int32_t pointer, uint64_t value) {
    memcpy((void *)(uintptr_t)(uint32_t)pointer, &value, sizeof(value));
}

int __imported_wasi_snapshot_preview1_args_sizes_get(int32_t count, int32_t bytes) {
    write_u32(count, 0);
    write_u32(bytes, 0);
    return 0;
}

int __imported_wasi_snapshot_preview1_args_get(int32_t argv, int32_t bytes) {
    (void)argv;
    (void)bytes;
    return 0;
}

int __imported_wasi_snapshot_preview1_environ_sizes_get(int32_t count, int32_t bytes) {
    write_u32(count, 0);
    write_u32(bytes, 0);
    return 0;
}

int __imported_wasi_snapshot_preview1_environ_get(int32_t environ, int32_t bytes) {
    (void)environ;
    (void)bytes;
    return 0;
}

int __imported_wasi_snapshot_preview1_clock_time_get(int32_t clock_id, int64_t precision,
                                                     int32_t result) {
    (void)clock_id;
    (void)precision;
    write_u64(result, 0);
    return 0;
}

int __imported_wasi_snapshot_preview1_fd_fdstat_get(int32_t fd, int32_t result) {
    (void)fd;
    memset((void *)(uintptr_t)(uint32_t)result, 0, 24);
    return 0;
}

int __imported_wasi_snapshot_preview1_fd_seek(int32_t fd, int64_t offset, int32_t whence,
                                              int32_t result) {
    (void)fd;
    (void)offset;
    (void)whence;
    write_u64(result, 0);
    return 0;
}

int __imported_wasi_snapshot_preview1_fd_write(int32_t fd, int32_t iovecs, int32_t count,
                                               int32_t written) {
    (void)fd;
    uint32_t total = 0;
    for (int32_t index = 0; index < count; ++index) {
        uint32_t length = 0;
        memcpy(&length, (const void *)(uintptr_t)(uint32_t)(iovecs + index * 8 + 4),
               sizeof(length));
        total += length;
    }
    write_u32(written, total);
    return 0;
}

int __imported_wasi_snapshot_preview1_fd_close(int32_t fd) {
    (void)fd;
    return 0;
}

__attribute__((noreturn)) void __imported_wasi_snapshot_preview1_proc_exit(int32_t status) {
    (void)status;
    __builtin_trap();
}

// Some wasm-ld paths retain libc's alternate symbol spelling for indirect fd_close calls.
int frontend_wasi_fd_close_alias(int32_t fd) __asm__("fd_close|wasi_snapshot_preview1");
int frontend_wasi_fd_close_alias(int32_t fd) {
    return __imported_wasi_snapshot_preview1_fd_close(fd);
}
