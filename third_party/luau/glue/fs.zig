//! fs.zig — file IO over the mc syscalls, shared by entry.zig (the script/stdin runner), stdlib.zig
//! (the require loader), and sys.zig (sys.fs). One reader, one fd namespace.
//!
//! DESIGN (the fd-namespace boundary): the guest's EXPLICIT file IO goes straight to the kernel via
//! mc_sys_open/read/close — never wasi-libc. wasi-libc is reserved for what the C++ Luau VM core does
//! on its own (print → fwrite → stdout, args), which only ever touches fd 0/1/2; those map to the same
//! kernel streams whether reached via libc or raw mc, so there is no namespace fork for files. This
//! replaces the earlier half-and-half state (entry/sys on raw mc, the loader on libc fopen/fread).

const std = @import("std");
const mc = @import("mc.zig");

const alloc = std.heap.c_allocator;
const O_READ: i32 = 1; // contracts/constants.kdl
const EIO: i32 = 29;

/// Read a whole file by path. Caller owns the returned buffer; null on failure, with the mc errno
/// written to `err` when provided — so sys.fs.read can surface the errno NAME (the value/err idiom)
/// while entry.zig / the require loader, which only need bytes-or-nothing, pass null.
pub fn slurp(path: [*:0]const u8, err: ?*i32) ?[]u8 {
    var fd: u32 = 0;
    const oe = mc.mc_sys_open(mc.addr(path), @intCast(std.mem.span(path).len), O_READ, mc.addr(&fd));
    if (oe != 0) {
        if (err) |p| p.* = oe;
        return null;
    }
    defer _ = mc.mc_sys_close(@intCast(fd));
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        const re = mc.mc_sys_read(@intCast(fd), mc.addr(&buf), buf.len, mc.addr(&n));
        if (re != 0) {
            if (err) |p| p.* = re;
            list.deinit(alloc);
            return null;
        }
        if (n == 0) break;
        list.appendSlice(alloc, buf[0..n]) catch {
            if (err) |p| p.* = EIO;
            list.deinit(alloc);
            return null;
        };
    }
    return list.toOwnedSlice(alloc) catch {
        if (err) |p| p.* = EIO;
        return null;
    };
}

/// Write all of `bytes` to `fd` via mc_sys_write (draining short writes). Used for the glue's own
/// diagnostics to stdout/stderr — the C++ core's print() stays on libc fwrite, but fd 0/1/2 are the
/// same kernel streams either way, so this never forks a namespace.
pub fn writeAll(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        var n: u32 = 0;
        if (mc.mc_sys_write(fd, mc.addr(bytes.ptr + off), @intCast(bytes.len - off), mc.addr(&n)) != 0) return;
        if (n == 0) return;
        off += n;
    }
}
