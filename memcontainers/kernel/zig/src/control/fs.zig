//! fs.zig - host-control VFS operations.
//!
//! Owns: control-plane read, readlink, write, readdir, stat, mkdir, unlink,
//!   chmod, symlink, mount, and unmount operations.
//! Invariants: uninitialized kernels fail closed, host paths are read through
//!   the scratch-buffer helpers, and VFS errors become negated errno values.
//! Consumes: the namespace, mount filesystem adapter, scratch-buffer helpers,
//!   wire encoders, and shared FsError-to-errno mapping.
//! Not here: raw wire primitives, exec-child scheduling, or service sessions.

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("../vfs.zig");
const state = @import("../state.zig");
const MountFs = @import("../fs/mountfs.zig").MountFs;
const buf_mod = @import("buf.zig");
const wire = @import("wire.zig");
const FsError = vfs.FsError;

const ctlBytes = buf_mod.ctlBytes;
const ctlStr = buf_mod.ctlStr;
const replaceBuffer = buf_mod.replaceBuffer;
const encodeDirEntries = wire.encodeDirEntries;
const encodeFileStat = wire.encodeFileStat;

pub inline fn neg(errno: i32) i32 {
    return -errno;
}

/// FsError -> errno, the single map in errno.zig (re-exported so control's call sites keep the
/// bare spelling). Control's local `neg` negates the result for the control-channel sign
/// convention — the map itself is sign-agnostic.
pub const errnoFromFs = @import("../errno.zig").errnoFromFs;

/// Read a file in full. `read` follows the final symlink (POSIX open semantics), so a ctl
/// read of a symlink returns the TARGET's content; stat/readdir stay lstat.
pub fn read(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    const real = k.ns.canonicalize(a, path, true) catch |e| return neg(errnoFromFs(e));
    var h = k.ns.openAs(a, vfs.SYSTEM_CALLER, real, vfs.OpenFlags.READ) catch |e| return neg(errnoFromFs(e));
    defer h.close();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(k.gpa);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = h.read(&tmp) catch |e| return switch (e) {
            FsError.WouldBlock => neg(constants.EAGAIN),
            else => neg(errnoFromFs(e)),
        };
        if (n == 0) break;
        out.appendSlice(k.gpa, tmp[0..n]) catch @panic("OOM");
    }
    replaceBuffer(out.items);
    return @intCast(out.items.len);
}

/// Read a symlink's target text (no following).
pub fn readlink(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(k.gpa);
    k.ns.readlink(a, path, &out) catch |e| return neg(errnoFromFs(e));
    replaceBuffer(out.items);
    return @intCast(out.items.len);
}

/// Write a file, truncating first. The buffer holds the path then the data.
pub fn write(path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    const data = ctlBytes(a, data_ptr, data_len) orelse return neg(constants.EINVAL);
    var h = k.ns.openAs(a, vfs.SYSTEM_CALLER, path, vfs.OpenFlags.TRUNCATE) catch |e| return neg(errnoFromFs(e));
    defer h.close();
    var written: usize = 0;
    while (written < data.len) {
        const n = h.write(data[written..]) catch |e| return neg(errnoFromFs(e));
        if (n == 0) break;
        written += n;
    }
    return @intCast(written);
}

/// List a directory into an encoded CtlDirEntries frame.
pub fn readdir(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    var entries: std.ArrayList(vfs.DirEntry) = .empty;
    k.ns.readdir(a, vfs.SYSTEM_CALLER, path, &entries) catch |e| return neg(errnoFromFs(e));
    const encoded = encodeDirEntries(a, entries.items);
    replaceBuffer(encoded);
    return @intCast(encoded.len);
}

/// Stat a path (lstat — no symlink following) into an encoded CtlFileStat frame.
pub fn stat(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    const md = k.ns.statPath(a, path) catch |e| return switch (e) {
        FsError.WouldBlock => neg(constants.EAGAIN),
        else => neg(errnoFromFs(e)),
    };
    if (md.size > std.math.maxInt(i64)) return neg(constants.EINVAL);
    const encoded = encodeFileStat(a, md);
    replaceBuffer(encoded);
    return @intCast(encoded.len);
}

pub fn mkdir(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.mkdir(a, vfs.SYSTEM_CALLER, path) catch |e| return neg(errnoFromFs(e));
    return 0;
}

pub fn unlink(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.unlink(a, vfs.SYSTEM_CALLER, path) catch |e| return neg(errnoFromFs(e));
    return 0;
}

pub fn chmod(path_ptr: u32, path_len: u32, mode: u32) i32 {
    const k = state.kernel();
    if (mode > 0o7777) return neg(constants.EINVAL);
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.setMode(a, path, @intCast(mode)) catch |e| return neg(errnoFromFs(e));
    return 0;
}

/// Create a symlink at `link` with target text `target` (two-region buffer layout).
pub fn symlink(target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const target = ctlStr(a, target_ptr, target_len) orelse return neg(constants.EINVAL);
    const link = ctlStr(a, link_ptr, link_len) orelse return neg(constants.EINVAL);
    k.ns.symlink(a, target, link) catch |e| return neg(errnoFromFs(e));
    return 0;
}

/// Host-backed mounts need MountFs (the mc_host_call driver) — Phase 6.
pub fn mount(path_ptr: u32, path_len: u32, read_only: i32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    if (path.len == 0 or path[0] != '/') return neg(constants.EINVAL);
    k.ns.mountLabeled(path, MountFs.create(k.gpa, path, &k.host_call, &k.mount_channels).fileSystem(), "mountfs", read_only != 0);
    return 0;
}

pub fn unmount(path_ptr: u32, path_len: u32) i32 {
    const k = state.kernel();
    if (!state.isInitialized()) return neg(constants.EIO);
    var scratch = std.heap.ArenaAllocator.init(k.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const path = ctlStr(a, path_ptr, path_len) orelse return neg(constants.EINVAL);
    k.ns.unmount(path) catch |e| return neg(errnoFromFs(e));
    return 0;
}
