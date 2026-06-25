/*
** close_shim.c — route wasi-libc's close() through the mc wasi-adapter.
**
** Zig's bundled libc (lib/c.zig) provides close() as part of the Zig compilation unit, importing
** `wasi_snapshot_preview1.fd_close` DIRECTLY — bypassing the `__imported_wasi_snapshot_preview1_*` hook
** the mc adapter overrides. So close() is the ONE libc fd op the adapter can't intercept, leaving a
** lone stray wasi import that mc-attest (§9.3: a guest imports only `mc`) rejects. (Every other fd op
** already routes through `__imported_*`.) sqlite's unix-dotfile VFS xClose → close().
**
** Why this is C and not Zig: c.zig exports close as a WEAK symbol, overridable at LINK time — but a
** second Zig `export fn close` collides at COMPILE time (Zig's @export check rejects duplicate names
** before weak/strong resolution). A C shim is a separate clang object, so it skips that check and
** overrides the weak c.zig close at link. (memcontainers' wasi_compat.c does the same in its pure
** `zig cc` build, where there is no c.zig at all.)
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
