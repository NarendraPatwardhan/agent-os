//! control.zig — the `mc_ctl_*` control plane and the host↔kernel scratch-buffer protocol
//! (ZIG_KERNEL §2.1, §4.1).
//!
//! Owns: the scratch buffer (`mc_ctl_buf`) the host writes requests into and reads results
//!   out of, and the VFS control ops (read/write/readdir/stat/mkdir/unlink/chmod/symlink/
//!   readlink/mount/unmount) dispatched into the namespace as SYSTEM_CALLER. An op may
//!   REPLACE the buffer with its result; the host re-queries mc_ctl_buf(0) to read it.
//!   Oracle: kernel/rust/src/lib.rs (mc_ctl_* handlers).
//! Invariants: A9 (denials are errno via the shared FsError→errno map, never traps), §1.3
//!   (the control ABI is control.kdl; never reintroduce mc_prepare_rewind — §15.2).
//! Not here: the exports themselves (main.zig); guest syscall fulfillment (syscall.zig);
//!   the scheduler that runs control-exec children (scheduler.zig). A thin façade over vfs.

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("vfs.zig");
const state = @import("state.zig");
const FsError = vfs.FsError;

// control.kdl scratch-buffer frame ids/versions (the two the VFS ops emit). Little-endian;
// bool = 1 byte; bytes = u32 length + payload; a message list = u32 count + length-prefixed
// frames. The e2e host decodes these via the same contract, so it is the drift oracle.
const FILE_STAT_MSG_ID: u16 = 3;
const FILE_STAT_VERSION: u8 = 1;
const DIR_ENTRY_MSG_ID: u16 = 4;
const DIR_ENTRY_VERSION: u8 = 1;
const DIR_ENTRIES_MSG_ID: u16 = 5;
const DIR_ENTRIES_VERSION: u8 = 1;

fn putU8(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u8) void {
    o.append(a, v) catch @panic("OOM");
}
fn putU16(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, v))) catch @panic("OOM");
}
fn putU32(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, v))) catch @panic("OOM");
}
fn putI64(o: *std.ArrayList(u8), a: std.mem.Allocator, v: i64) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(v)))) catch @panic("OOM");
}
fn putBool(o: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) void {
    putU8(o, a, if (v) 1 else 0);
}
fn putBytes(o: *std.ArrayList(u8), a: std.mem.Allocator, v: []const u8) void {
    putU32(o, a, @intCast(v.len));
    o.appendSlice(a, v) catch @panic("OOM");
}

fn encodeFileStat(a: std.mem.Allocator, md: vfs.Metadata) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, FILE_STAT_MSG_ID);
    putU8(&o, a, FILE_STAT_VERSION);
    putI64(&o, a, @intCast(md.size));
    putBool(&o, a, md.node_type == .dir);
    putBool(&o, a, md.node_type == .symlink);
    putU32(&o, a, md.nlink);
    putU32(&o, a, md.mode);
    return o.items;
}

fn encodeDirEntry(a: std.mem.Allocator, e: vfs.DirEntry) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, DIR_ENTRY_MSG_ID);
    putU8(&o, a, DIR_ENTRY_VERSION);
    putBytes(&o, a, e.name);
    putBool(&o, a, e.node_type == .dir);
    putBool(&o, a, e.node_type == .symlink);
    return o.items;
}

fn encodeDirEntries(a: std.mem.Allocator, entries: []const vfs.DirEntry) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, DIR_ENTRIES_MSG_ID);
    putU8(&o, a, DIR_ENTRIES_VERSION);
    putU32(&o, a, @intCast(entries.len));
    for (entries) |e| putBytes(&o, a, encodeDirEntry(a, e));
    return o.items;
}

inline fn neg(errno: i32) i32 {
    return -errno;
}

/// The shared FsError → errno map (so the control channel and the syscall ABI never drift).
fn errnoFromFs(e: FsError) i32 {
    return switch (e) {
        FsError.NotFound => constants.ENOENT,
        FsError.AlreadyExists => constants.EEXIST,
        FsError.NotDir => constants.ENOTDIR,
        FsError.IsDir => constants.EISDIR,
        FsError.PermissionDenied => constants.EPERM,
        FsError.AccessDenied => constants.EACCES,
        FsError.InvalidPath => constants.EINVAL,
        FsError.NotEmpty => constants.ENOTEMPTY,
        FsError.IoError => constants.EIO,
        FsError.BadFileDescriptor => constants.EBADF,
        FsError.NotImplemented => constants.ENOSYS,
        FsError.CrossDevice => constants.EXDEV,
        FsError.WouldBlock => constants.EAGAIN,
        FsError.MessageTooBig => constants.EMSGSIZE,
        FsError.Loop => constants.ELOOP,
    };
}

/// Copy `len` bytes out of the control buffer at `ptr` (bounds-checked), duped into `a`.
fn ctlBytes(a: std.mem.Allocator, ptr: u32, len: u32) ?[]u8 {
    const k = state.kernel();
    const start: usize = ptr;
    const end = start +% @as(usize, len);
    if (end < start or end > k.ctl_buffer.items.len) return null;
    return a.dupe(u8, k.ctl_buffer.items[start..end]) catch @panic("OOM");
}

/// Read a UTF-8 path/string out of the control buffer.
fn ctlStr(a: std.mem.Allocator, ptr: u32, len: u32) ?[]u8 {
    const b = ctlBytes(a, ptr, len) orelse return null;
    if (!std.unicode.utf8ValidateSlice(b)) return null;
    return b;
}

/// Replace the scratch buffer with `bytes` (an op result the host reads via mc_ctl_buf(0)).
fn replaceBuffer(bytes: []const u8) void {
    const k = state.kernel();
    k.ctl_buffer.clearRetainingCapacity();
    k.ctl_buffer.appendSlice(k.gpa, bytes) catch @panic("OOM");
}

/// Ensure the control buffer is at least `len` bytes and return its address. mc_ctl_buf(0)
/// returns the current pointer for reading a result.
pub fn buf(len: usize) ?[*]u8 {
    const k = state.kernel();
    if (k.ctl_buffer.items.len < len) {
        k.ctl_buffer.resize(k.gpa, len) catch return null;
    }
    return k.ctl_buffer.items.ptr;
}

// ── Control VFS ─────────────────────────────────────────────────────────────────────────

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
    _ = path_ptr;
    _ = path_len;
    _ = read_only;
    return neg(constants.ENOSYS);
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

// ── Control exec jobs (Phase 4) + resident-service calls (Phase 6) ────────────────────────
pub fn execStart(request_len: u32) i32 {
    _ = request_len;
    return neg(constants.ENOSYS);
}
pub fn execPoll(job_id: u32) i32 {
    _ = job_id;
    return neg(constants.ENOSYS);
}
pub fn execPeek(job_id: u32) i32 {
    _ = job_id;
    return neg(constants.ENOSYS);
}
pub fn execClose(job_id: u32) i32 {
    _ = job_id;
    return neg(constants.ENOSYS);
}
pub fn svcCallStart(request_len: u32) i32 {
    _ = request_len;
    return neg(constants.ENOSYS);
}
pub fn svcCallPoll(job_id: u32) i32 {
    _ = job_id;
    return neg(constants.ENOSYS);
}
pub fn svcCallClose(job_id: u32) i32 {
    _ = job_id;
    return neg(constants.ENOSYS);
}
