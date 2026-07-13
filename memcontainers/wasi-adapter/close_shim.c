/*
 * Route Zig wasi-libc's weak close() through the mc WASI adapter. Zig's bundled libc otherwise
 * imports wasi_snapshot_preview1.fd_close directly, bypassing the adapter's __imported_* hook and
 * violating the pure-mc guest boundary. This must be C: a second Zig export collides before the
 * linker can apply weak/strong symbol resolution.
 */
#include <errno.h>

extern int __imported_wasi_snapshot_preview1_fd_close(int fd);

int close(int fd) {
    int rc = __imported_wasi_snapshot_preview1_fd_close(fd);
    if (rc != 0) {
        errno = rc;
        return -1;
    }
    return 0;
}
