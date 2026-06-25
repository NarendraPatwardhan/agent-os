//! wasi_shim.zig — forwards residual wasi import symbols that the adapter's __imported_wasi_* defs
//! don't intercept on their own. wasm-ld materialises a fresh `<name>|<module>` import symbol for a
//! wasi call reached through an indirect (table) reference rather than the direct wasi-libc wrapper —
//! here wasi-libc's `__stdio_close` (the atexit FILE* cleanup) closing fds. We define that symbol and
//! forward to the adapter, so the guest stays pure-mc. This is the Zig equivalent of the rust mc_box's
//! trampoline round; the residue + its exact symbol were identified via a names-kept (ReleaseSafe)
//! build + //tools/wasi-trampoline. See third_party/luau/SYSTEM.md.

// The adapter's definition (→ mc_sys_close, with the wasi↔mc fd-table translation).
extern fn __imported_wasi_snapshot_preview1_fd_close(fd: i32) i32;

export fn @"fd_close|wasi_snapshot_preview1"(fd: i32) callconv(.c) i32 {
    return __imported_wasi_snapshot_preview1_fd_close(fd);
}
