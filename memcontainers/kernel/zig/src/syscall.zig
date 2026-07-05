//! syscall.zig — fulfillment of generated `Pending` syscalls against kernel state
//! (ZIG_KERNEL §2.7, §5.1, §4.1).
//!
//! Owns: the policy half of the guest syscall ABI — a decoded generated `Pending`
//!   is fulfilled against the real VFS, task fd table, pipes, scheduler, and the
//!   declared terminal bridge. Would-block results are returned to guest.zig as a
//!   scheduler block/yield outcome; this file never starts or stops Asyncify.
//! Invariants: guest pointers are range-checked against wasm3 linear memory before
//!   every read/write (bad guest memory returns an errno, never a host trap), and
//!   every syscall variant has an explicit dispatch arm. Phase-6 surfaces are wired
//!   but return `-ENOSYS` until their backing subsystem lands here.

const std = @import("std");
const bridge = @import("bridge.zig");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("state.zig");
const task_mod = @import("task.zig");
const vfs = @import("vfs.zig");
const wasm3 = @import("wasm3/bindings.zig");

const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const Fd = task_mod.Fd;
const BlockReason = task_mod.BlockReason;

const STAT_RECORD_LEN: usize = @intCast(constants.STAT_REC_LEN);
const PERSIST_ROOT = "/var/persist";

/// Narrow guest-runtime view used by syscall fulfillment. guest.zig owns the
/// concrete runtime; this interface keeps syscall.zig out of the Asyncify driver.
pub const Guest = struct {
    ptr: *anyopaque,
    task_id: *const fn (*anyopaque) TaskId,

    pub fn taskId(self: *const Guest) TaskId {
        return self.task_id(self.ptr);
    }
};

pub const Fulfillment = union(enum) {
    Resume: i32,
    Block: BlockReason,
    Pending,
    Exit: i32,
};

fn finish(code: i32) Fulfillment {
    return .{ .Resume = code };
}

pub fn neg(errno: i32) i32 {
    return -errno;
}

pub fn errnoFromFs(e: vfs.FsError) i32 {
    return switch (e) {
        vfs.FsError.NotFound => constants.ENOENT,
        vfs.FsError.AlreadyExists => constants.EEXIST,
        vfs.FsError.NotDir => constants.ENOTDIR,
        vfs.FsError.IsDir => constants.EISDIR,
        vfs.FsError.PermissionDenied => constants.EPERM,
        vfs.FsError.AccessDenied => constants.EACCES,
        vfs.FsError.InvalidPath => constants.EINVAL,
        vfs.FsError.NotEmpty => constants.ENOTEMPTY,
        vfs.FsError.IoError => constants.EIO,
        vfs.FsError.BadFileDescriptor => constants.EBADF,
        vfs.FsError.NotImplemented => constants.ENOSYS,
        vfs.FsError.CrossDevice => constants.EXDEV,
        vfs.FsError.WouldBlock => constants.EAGAIN,
        vfs.FsError.MessageTooBig => constants.EMSGSIZE,
        vfs.FsError.Loop => constants.ELOOP,
    };
}

fn guestMemory(runtime: ?*wasm3.Runtime, mem: ?*anyopaque) ?[]u8 {
    const base_any = mem orelse blk: {
        var size: u32 = 0;
        break :blk wasm3.m3_GetMemory(runtime, &size, 0) orelse return null;
    };
    const len: usize = @intCast(wasm3.m3_GetMemorySize(runtime));
    const base: [*]u8 = @ptrCast(base_any);
    return base[0..len];
}

fn guestRange(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, ptr: u32, len: u32) ?[]u8 {
    const memory = guestMemory(runtime, mem) orelse return null;
    const start: usize = @intCast(ptr);
    const n: usize = @intCast(len);
    const end = std.math.add(usize, start, n) catch return null;
    if (end > memory.len) return null;
    return memory[start..end];
}

fn writeGuestBytes(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, ptr: u32, bytes: []const u8) bool {
    if (bytes.len > std.math.maxInt(u32)) return false;
    const out = guestRange(runtime, mem, ptr, @intCast(bytes.len)) orelse return false;
    if (bytes.len != 0) @memcpy(out, bytes);
    return true;
}

fn writeGuestU32(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, ptr: u32, value: u32) bool {
    const out = guestRange(runtime, mem, ptr, 4) orelse return false;
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
    out[3] = @truncate(value >> 24);
    return true;
}

fn writeGuestI64(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, ptr: u32, value: i64) bool {
    const out = guestRange(runtime, mem, ptr, 8) orelse return false;
    const raw: u64 = @bitCast(value);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[i] = @truncate(raw >> @as(u6, @intCast(i * 8)));
    }
    return true;
}

fn readGuestI64(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, ptr: u32) ?i64 {
    const in = guestRange(runtime, mem, ptr, 8) orelse return null;
    var raw: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        raw |= @as(u64, in[i]) << @as(u6, @intCast(i * 8));
    }
    return @bitCast(raw);
}

fn readLeI32(bytes: []const u8, off: usize) i32 {
    const raw = @as(u32, bytes[off]) |
        (@as(u32, bytes[off + 1]) << 8) |
        (@as(u32, bytes[off + 2]) << 16) |
        (@as(u32, bytes[off + 3]) << 24);
    return @bitCast(raw);
}

fn readLeI16(bytes: []const u8, off: usize) i16 {
    const raw = @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
    return @bitCast(raw);
}

fn writeLeI16(bytes: []u8, off: usize, value: i16) void {
    const raw: u16 = @bitCast(value);
    bytes[off] = @truncate(raw);
    bytes[off + 1] = @truncate(raw >> 8);
}

fn writeLeU32(bytes: []u8, off: i32, value: u32) void {
    const i: usize = @intCast(off);
    bytes[i] = @truncate(value);
    bytes[i + 1] = @truncate(value >> 8);
    bytes[i + 2] = @truncate(value >> 16);
    bytes[i + 3] = @truncate(value >> 24);
}

fn writeLeU64(bytes: []u8, off: i32, value: u64) void {
    const start: usize = @intCast(off);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        bytes[start + i] = @truncate(value >> @as(u6, @intCast(i * 8)));
    }
}

fn writeLeI64(bytes: []u8, off: i32, value: i64) void {
    writeLeU64(bytes, off, @bitCast(value));
}

fn currentTask(guest: *const Guest) ?*Task {
    return state.kernel().sched.getTask(guest.taskId());
}

fn fdIndex(fd: i32) ?usize {
    if (fd < 0) return null;
    return @intCast(fd);
}

fn fsErr(e: vfs.FsError) i32 {
    return neg(errnoFromFs(e));
}

const SharedFile = struct {
    gpa: std.mem.Allocator,
    inner: vfs.FileHandle,
    refs: usize = 1,
    readable: bool,
    writable: bool,

    fn wrap(gpa: std.mem.Allocator, inner: vfs.FileHandle, readable: bool, writable: bool) vfs.FileHandle {
        const self = gpa.create(SharedFile) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .inner = inner, .readable = readable, .writable = writable };
        return .{ .ptr = self, .vtable = &handle_vtable };
    }

    fn retain(handle: vfs.FileHandle) ?vfs.FileHandle {
        if (handle.vtable != &handle_vtable) return null;
        const self: *SharedFile = @ptrCast(@alignCast(handle.ptr));
        self.refs += 1;
        return handle;
    }

    fn readableHandle(handle: vfs.FileHandle) bool {
        if (handle.vtable != &handle_vtable) return true;
        const self: *SharedFile = @ptrCast(@alignCast(handle.ptr));
        return self.readable;
    }

    fn writableHandle(handle: vfs.FileHandle) bool {
        if (handle.vtable != &handle_vtable) return true;
        const self: *SharedFile = @ptrCast(@alignCast(handle.ptr));
        return self.writable;
    }

    fn read(self: *SharedFile, buf: []u8) vfs.FsError!usize {
        if (!self.readable) return vfs.FsError.BadFileDescriptor;
        return self.inner.read(buf);
    }

    fn write(self: *SharedFile, buf: []const u8) vfs.FsError!usize {
        if (!self.writable) return vfs.FsError.BadFileDescriptor;
        return self.inner.write(buf);
    }

    fn seek(self: *SharedFile, pos: vfs.SeekFrom) vfs.FsError!u64 {
        return self.inner.seek(pos);
    }

    fn stat(self: *SharedFile) vfs.FsError!vfs.Metadata {
        return self.inner.stat();
    }

    fn truncate(self: *SharedFile, size: u64) vfs.FsError!void {
        if (!self.writable) return vfs.FsError.BadFileDescriptor;
        return self.inner.truncate(size);
    }

    fn close(self: *SharedFile) void {
        self.refs -|= 1;
        if (self.refs != 0) return;
        const gpa = self.gpa;
        self.inner.close();
        gpa.destroy(self);
    }

    const handle_vtable = vfs.FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
        .close = hClose,
    };
    fn hRead(p: *anyopaque, buf: []u8) vfs.FsError!usize {
        return self_(p).read(buf);
    }
    fn hWrite(p: *anyopaque, buf: []const u8) vfs.FsError!usize {
        return self_(p).write(buf);
    }
    fn hSeek(p: *anyopaque, pos: vfs.SeekFrom) vfs.FsError!u64 {
        return self_(p).seek(pos);
    }
    fn hStat(p: *anyopaque) vfs.FsError!vfs.Metadata {
        return self_(p).stat();
    }
    fn hTruncate(p: *anyopaque, size: u64) vfs.FsError!void {
        return self_(p).truncate(size);
    }
    fn hClose(p: *anyopaque) void {
        self_(p).close();
    }
    fn self_(p: *anyopaque) *SharedFile {
        return @ptrCast(@alignCast(p));
    }
};

fn cloneFd(fd: Fd) ?Fd {
    return switch (fd) {
        .none => null,
        .file => |fh| if (SharedFile.retain(fh)) |retained| Fd{ .file = retained } else null,
        .pipe_read => |p| blk: {
            p.addReader();
            break :blk Fd{ .pipe_read = p };
        },
        .pipe_write => |p| blk: {
            p.addWriter();
            break :blk Fd{ .pipe_write = p };
        },
    };
}

fn pathWithin(root: ?[]const u8, path: []const u8) bool {
    const r = root orelse return true;
    if (std.mem.eql(u8, r, "/")) return true;
    if (std.mem.eql(u8, path, r)) return true;
    return std.mem.startsWith(u8, path, r) and path.len > r.len and path[r.len] == '/';
}

fn absolutize(arena: std.mem.Allocator, cwd: []const u8, raw: []const u8) []const u8 {
    if (raw.len == 0) return arena.dupe(u8, cwd) catch @panic("OOM");
    if (raw[0] == '/') return arena.dupe(u8, raw) catch @panic("OOM");
    if (std.mem.eql(u8, cwd, "/")) return std.fmt.allocPrint(arena, "/{s}", .{raw}) catch @panic("OOM");
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, raw }) catch @panic("OOM");
}

fn resolveGuestPath(
    guest: *const Guest,
    runtime: ?*wasm3.Runtime,
    mem: ?*anyopaque,
    arena: std.mem.Allocator,
    ptr: u32,
    len: u32,
    need_write: bool,
    follow_final: bool,
    errno_out: *i32,
) ?[]const u8 {
    const t = currentTask(guest) orelse {
        errno_out.* = constants.EIO;
        return null;
    };
    const raw = guestRange(runtime, mem, ptr, len) orelse {
        errno_out.* = constants.EINVAL;
        return null;
    };
    if (std.mem.indexOfScalar(u8, raw, 0) != null) {
        errno_out.* = constants.EINVAL;
        return null;
    }
    const absolute = absolutize(arena, t.cwd, raw);
    const path = state.kernel().ns.canonicalize(arena, absolute, follow_final) catch |e| {
        errno_out.* = errnoFromFs(e);
        return null;
    };

    const needed = if (need_write)
        state.kernel().ns.writeCapAt(arena, path)
    else
        constants.CAP_FS_READ;
    if (!t.caps.has(needed) or !pathWithin(t.confine_root, path)) {
        errno_out.* = constants.EPERM;
        return null;
    }
    if (pathWithin(PERSIST_ROOT, path) and !t.caps.has(constants.CAP_PERSIST)) {
        errno_out.* = constants.EPERM;
        return null;
    }
    return path;
}

fn openFlags(raw: i32) ?vfs.OpenFlags {
    const flags = if (raw == 0) constants.O_READ else raw;
    var out = vfs.OpenFlags{
        .read = (flags & constants.O_READ) != 0,
        .write = (flags & constants.O_WRITE) != 0,
        .create = (flags & constants.O_CREATE) != 0,
        .truncate = (flags & constants.O_TRUNC) != 0,
        .append = (flags & constants.O_APPEND) != 0,
    };
    if (!out.read and !out.write) out.read = true;
    if ((out.create or out.truncate or out.append) and !out.write) return null;
    return out;
}

fn fulfillArgs(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.ArgsArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(state.kernel().gpa);
    const argv0 = if (t.command.len != 0) t.command else t.name;
    blob.appendSlice(state.kernel().gpa, argv0) catch @panic("OOM");
    blob.append(state.kernel().gpa, 0) catch @panic("OOM");
    for (t.args) |a| {
        blob.appendSlice(state.kernel().gpa, a) catch @panic("OOM");
        blob.append(state.kernel().gpa, 0) catch @panic("OOM");
    }

    const n = @min(blob.items.len, @as(usize, @intCast(args.len)));
    if (blob.items.len > std.math.maxInt(u32)) return neg(constants.EINVAL);
    if (guestRange(runtime, mem, args.ret_len, 4) == null or guestRange(runtime, mem, args.ptr, @intCast(n)) == null) {
        return neg(constants.EINVAL);
    }
    if (n != 0 and !writeGuestBytes(runtime, mem, args.ptr, blob.items[0..n])) return neg(constants.EINVAL);
    if (!writeGuestU32(runtime, mem, args.ret_len, @intCast(blob.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillWrite(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.WriteArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const bytes = guestRange(runtime, mem, args.ptr, args.len) orelse return finish(neg(constants.EINVAL));
    if (guestRange(runtime, mem, args.ret_n, 4) == null) return finish(neg(constants.EINVAL));

    const idx = fdIndex(args.fd) orelse return finish(neg(constants.EBADF));
    switch (t.getFd(idx)) {
        .none => {
            if (args.fd == 1) {
                bridge.mc_stdout_write(bytes.ptr, bytes.len);
                if (!writeGuestU32(runtime, mem, args.ret_n, @intCast(bytes.len))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            }
            if (args.fd == 2) {
                bridge.mc_stderr_write(bytes.ptr, bytes.len);
                if (!writeGuestU32(runtime, mem, args.ret_n, @intCast(bytes.len))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            }
            return finish(neg(constants.EBADF));
        },
        .file => |fh| {
            const n = fh.write(bytes) catch |e| return finish(fsErr(e));
            if (!writeGuestU32(runtime, mem, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .pipe_write => |p| {
            if (p.isReadClosed()) return finish(neg(constants.EPIPE));
            const n = p.write(bytes);
            if (n == 0 and bytes.len != 0) return .{ .Block = .{ .pipe_write = p } };
            state.kernel().sched.checkUnblocked();
            if (!writeGuestU32(runtime, mem, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .pipe_read => return finish(neg(constants.EBADF)),
    }
}

fn fulfillRead(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.ReadArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const out = guestRange(runtime, mem, args.ptr, args.len) orelse return finish(neg(constants.EINVAL));
    if (guestRange(runtime, mem, args.ret_n, 4) == null) return finish(neg(constants.EINVAL));

    const idx = fdIndex(args.fd) orelse return finish(neg(constants.EBADF));
    switch (t.getFd(idx)) {
        .none => {
            if (args.fd != 0) return finish(neg(constants.EBADF));
            const n = bridge.mc_stdin_read(out.ptr, out.len);
            if (n == 0 and out.len != 0) return .Pending;
            if (!writeGuestU32(runtime, mem, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .file => |fh| {
            const n = fh.read(out) catch |e| return finish(fsErr(e));
            if (!writeGuestU32(runtime, mem, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .pipe_read => |p| {
            const n = p.read(out);
            if (n == 0 and !p.isWriteClosed() and out.len != 0) return .{ .Block = .{ .pipe_read = p } };
            state.kernel().sched.checkUnblocked();
            if (!writeGuestU32(runtime, mem, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .pipe_write => return finish(neg(constants.EBADF)),
    }
}

fn fulfillOpen(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.OpenArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(runtime, mem, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    var flags = openFlags(args.flags) orelse return neg(constants.EINVAL);

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var errno: i32 = 0;
    const need_write = flags.write or flags.create or flags.truncate or flags.append;
    const path = resolveGuestPath(guest, runtime, mem, arena, args.path_ptr, args.path_len, need_write, true, &errno) orelse return neg(errno);
    if ((flags.read or !need_write) and !t.caps.has(constants.CAP_FS_READ)) return neg(constants.EPERM);
    flags.noatime = !t.caps.has(constants.CAP_AMBIENT);

    const h = state.kernel().ns.openAs(arena, t.id, path, flags) catch |e| return fsErr(e);
    const wrapped = SharedFile.wrap(state.kernel().gpa, h, flags.read or !need_write, flags.write);
    const fd = t.allocFd(state.kernel().gpa, .{ .file = wrapped });
    if (!writeGuestU32(runtime, mem, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

fn fulfillClose(guest: *const Guest, args: mc.CloseArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const idx = fdIndex(args.fd) orelse return neg(constants.EBADF);
    if (idx >= t.fds.items.len) return neg(constants.EBADF);
    if (idx >= 3 and t.getFd(idx) == .none) return neg(constants.EBADF);
    t.closeFd(idx);
    state.kernel().sched.checkUnblocked();
    return constants.ESUCCESS;
}

fn fulfillPipe(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.PipeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(runtime, mem, args.ret_r, 4) orelse return neg(constants.EINVAL);
    _ = guestRange(runtime, mem, args.ret_w, 4) orelse return neg(constants.EINVAL);
    const p = state.kernel().sched.allocPipe();
    p.addReader();
    const rfd = t.allocFd(state.kernel().gpa, .{ .pipe_read = p });
    p.addWriter();
    const wfd = t.allocFd(state.kernel().gpa, .{ .pipe_write = p });
    if (!writeGuestU32(runtime, mem, args.ret_r, @intCast(rfd))) return neg(constants.EINVAL);
    if (!writeGuestU32(runtime, mem, args.ret_w, @intCast(wfd))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillDup(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.DupArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(runtime, mem, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    const idx = fdIndex(args.fd) orelse return neg(constants.EBADF);
    const cloned = cloneFd(t.getFd(idx)) orelse return neg(constants.EBADF);
    const fd = t.allocFd(state.kernel().gpa, cloned);
    if (!writeGuestU32(runtime, mem, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

fn fulfillDup2(guest: *const Guest, args: mc.Dup2Args) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const old_idx = fdIndex(args.old_fd) orelse return neg(constants.EBADF);
    const new_idx = fdIndex(args.new_fd) orelse return neg(constants.EBADF);
    if (old_idx == new_idx) return if (t.getFd(old_idx) == .none) neg(constants.EBADF) else constants.ESUCCESS;
    const cloned = cloneFd(t.getFd(old_idx)) orelse return neg(constants.EBADF);
    t.closeFd(new_idx);
    t.setFd(state.kernel().gpa, new_idx, cloned);
    state.kernel().sched.checkUnblocked();
    return constants.ESUCCESS;
}

fn fulfillGetpid(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.GetpidArgs) i32 {
    if (!writeGuestU32(runtime, mem, args.ret, guest.taskId())) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillGetppid(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.GetppidArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const ppid: u32 = t.parent_id orelse 0;
    if (!writeGuestU32(runtime, mem, args.ret, ppid)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn statKind(nt: vfs.NodeType) u32 {
    return switch (nt) {
        .file => 0,
        .dir => 1,
        .symlink => 2,
    };
}

fn writeStat(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, ret_stat: u32, metadata: vfs.Metadata) i32 {
    var record = [_]u8{0} ** STAT_RECORD_LEN;
    writeLeU64(&record, constants.STAT_REC_SIZE_OFF, metadata.size);
    writeLeU32(&record, constants.STAT_REC_NODE_TYPE_OFF, statKind(metadata.node_type));
    writeLeU32(&record, constants.STAT_REC_NLINK_OFF, metadata.nlink);
    writeLeU32(&record, constants.STAT_REC_MODE_OFF, metadata.mode);
    writeLeI64(&record, constants.STAT_REC_MTIME_OFF, metadata.mtime);
    writeLeI64(&record, constants.STAT_REC_ATIME_OFF, metadata.atime);
    writeLeI64(&record, constants.STAT_REC_CTIME_OFF, metadata.ctime);
    return if (writeGuestBytes(runtime, mem, ret_stat, &record)) constants.ESUCCESS else neg(constants.EINVAL);
}

fn fulfillStatLike(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, path_ptr: u32, path_len: u32, ret_stat: u32, follow: bool) i32 {
    _ = guestRange(runtime, mem, ret_stat, @intCast(STAT_RECORD_LEN)) orelse return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, runtime, mem, arena, path_ptr, path_len, false, follow, &errno) orelse return neg(errno);
    const md = state.kernel().ns.statPath(arena, path) catch |e| return fsErr(e);
    return writeStat(runtime, mem, ret_stat, md);
}

fn fulfillReadlink(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.ReadlinkArgs) i32 {
    _ = guestRange(runtime, mem, args.ret_len, 4) orelse return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, runtime, mem, arena, args.path_ptr, args.path_len, false, false, &errno) orelse return neg(errno);
    var target: std.ArrayList(u8) = .empty;
    state.kernel().ns.readlink(arena, path, &target) catch |e| return fsErr(e);
    const n = @min(target.items.len, @as(usize, @intCast(args.buf_len)));
    if (guestRange(runtime, mem, args.buf, @intCast(n)) == null) return neg(constants.EINVAL);
    if (n != 0 and !writeGuestBytes(runtime, mem, args.buf, target.items[0..n])) return neg(constants.EINVAL);
    if (!writeGuestU32(runtime, mem, args.ret_len, @intCast(target.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillReaddir(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.ReaddirArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(runtime, mem, args.ret_len, 4) orelse return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, runtime, mem, arena, args.path_ptr, args.path_len, false, true, &errno) orelse return neg(errno);

    var entries: std.ArrayList(vfs.DirEntry) = .empty;
    state.kernel().ns.readdir(arena, t.id, path, &entries) catch |e| return fsErr(e);
    var blob: std.ArrayList(u8) = .empty;
    for (entries.items) |entry| {
        blob.appendSlice(arena, entry.name) catch @panic("OOM");
        blob.append(arena, 0) catch @panic("OOM");
    }
    const n = @min(blob.items.len, @as(usize, @intCast(args.buf_len)));
    if (guestRange(runtime, mem, args.buf, @intCast(n)) == null) return neg(constants.EINVAL);
    if (n != 0 and !writeGuestBytes(runtime, mem, args.buf, blob.items[0..n])) return neg(constants.EINVAL);
    if (!writeGuestU32(runtime, mem, args.ret_len, @intCast(blob.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillMkdir(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.MkdirArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, runtime, mem, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.mkdir(arena, t.id, path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillUnlink(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.UnlinkArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, runtime, mem, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.unlink(arena, t.id, path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillGetcwd(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.GetcwdArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (t.cwd.len > std.math.maxInt(u32)) return neg(constants.EINVAL);
    _ = guestRange(runtime, mem, args.ret_len, 4) orelse return neg(constants.EINVAL);
    if (t.cwd.len > @as(usize, @intCast(args.buf_len))) return neg(constants.EINVAL);
    if (guestRange(runtime, mem, args.buf, @intCast(t.cwd.len)) == null) return neg(constants.EINVAL);
    if (t.cwd.len != 0 and !writeGuestBytes(runtime, mem, args.buf, t.cwd)) return neg(constants.EINVAL);
    if (!writeGuestU32(runtime, mem, args.ret_len, @intCast(t.cwd.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillChdir(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.ChdirArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, runtime, mem, arena, args.path_ptr, args.path_len, false, true, &errno) orelse return neg(errno);
    const md = state.kernel().ns.statPath(arena, path) catch |e| return fsErr(e);
    if (md.node_type != .dir) return neg(constants.ENOTDIR);
    if (!md.ownerExecutable()) return neg(constants.EACCES);
    t.setCwd(state.kernel().gpa, path);
    return constants.ESUCCESS;
}

fn fulfillLseek(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.LseekArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const idx = fdIndex(args.fd) orelse return neg(constants.EINVAL);
    const off = readGuestI64(runtime, mem, args.off_ptr) orelse return neg(constants.EINVAL);
    const fh = switch (t.getFd(idx)) {
        .file => |h| h,
        else => return neg(constants.EINVAL),
    };
    const pos: vfs.SeekFrom = switch (args.whence) {
        constants.SEEK_SET => if (off < 0) return neg(constants.EINVAL) else .{ .start = @intCast(off) },
        constants.SEEK_CUR => .{ .current = off },
        constants.SEEK_END => .{ .end = off },
        else => return neg(constants.EINVAL),
    };
    const next = fh.seek(pos) catch |e| return fsErr(e);
    if (next > @as(u64, @intCast(std.math.maxInt(i64)))) return neg(constants.EINVAL);
    if (!writeGuestI64(runtime, mem, args.off_ptr, @intCast(next))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillFtruncate(guest: *const Guest, args: mc.FtruncateArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const idx = fdIndex(args.fd) orelse return neg(constants.EINVAL);
    const fh = switch (t.getFd(idx)) {
        .file => |h| h,
        else => return neg(constants.EINVAL),
    };
    const size = (@as(u64, args.size_hi) << 32) | @as(u64, args.size_lo);
    fh.truncate(size) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn pollOne(t: *const Task, fd: i32, events: i16) i16 {
    if (fd < 0) return 0;
    const want_in = (@as(i32, @intCast(events)) & constants.POLLIN) != 0;
    const want_out = (@as(i32, @intCast(events)) & constants.POLLOUT) != 0;
    const idx: usize = @intCast(fd);
    var result: i32 = 0;
    switch (t.getFd(idx)) {
        .none => {
            if (fd == 1 or fd == 2) {
                if (want_out) result |= constants.POLLOUT;
            } else if (fd >= 3) {
                result |= constants.POLLERR;
            }
        },
        .file => |fh| {
            if (want_in and SharedFile.readableHandle(fh)) result |= constants.POLLIN;
            if (want_out and SharedFile.writableHandle(fh)) result |= constants.POLLOUT;
        },
        .pipe_read => |p| {
            if (want_in and !p.isEmpty()) result |= constants.POLLIN;
            if (p.isWriteClosed()) result |= constants.POLLHUP;
        },
        .pipe_write => |p| {
            if (want_out and !p.isReadClosed() and !p.isFull()) result |= constants.POLLOUT;
            if (p.isReadClosed()) result |= constants.POLLERR;
        },
    }
    return @intCast(result);
}

fn fulfillPoll(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.PollArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const total = std.math.mul(usize, @intCast(args.nfds), 8) catch return finish(neg(constants.EINVAL));
    if (total > std.math.maxInt(u32)) return finish(neg(constants.EINVAL));
    const fds = guestRange(runtime, mem, args.fds_ptr, @intCast(total)) orelse return finish(neg(constants.EINVAL));
    _ = guestRange(runtime, mem, args.ret_ready, 4) orelse return finish(neg(constants.EINVAL));

    var ready: u32 = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(args.nfds))) : (i += 1) {
        const off = i * 8;
        const fd = readLeI32(fds, off);
        const events = readLeI16(fds, off + 4);
        const revents = pollOne(t, fd, events);
        writeLeI16(fds, off + 6, revents);
        if (revents != 0) ready += 1;
    }
    if (ready == 0 and args.timeout_ms != 0) return .Pending;
    if (!writeGuestU32(runtime, mem, args.ret_ready, ready)) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

fn fulfillIsatty(guest: *const Guest, runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.IsattyArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const tty: u32 = if (args.fd >= 0 and args.fd <= 2 and t.getFd(@intCast(args.fd)) == .none) 1 else 0;
    if (!writeGuestU32(runtime, mem, args.ret, tty)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillAbiVersion(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, args: mc.AbiVersionArgs) i32 {
    if (!writeGuestU32(runtime, mem, args.ret, @intCast(constants.abi_version()))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn todoPhase6() i32 {
    return neg(constants.ENOSYS);
}

pub fn fulfillOutcome(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, guest: *const Guest, pending: mc.Pending) Fulfillment {
    return switch (pending) {
        .Args => |args| finish(fulfillArgs(guest, runtime, mem, args)),
        .Write => |args| fulfillWrite(guest, runtime, mem, args),
        .Read => |args| fulfillRead(guest, runtime, mem, args),
        .Open => |args| finish(fulfillOpen(guest, runtime, mem, args)),
        .Close => |args| finish(fulfillClose(guest, args)),
        .Stat => |args| finish(fulfillStatLike(guest, runtime, mem, args.path_ptr, args.path_len, args.ret_stat, true)),
        .Readdir => |args| finish(fulfillReaddir(guest, runtime, mem, args)),
        .Mkdir => |args| finish(fulfillMkdir(guest, runtime, mem, args)),
        .Unlink => |args| finish(fulfillUnlink(guest, runtime, mem, args)),
        // TODO(Phase 6): namespace mutation and richer metadata operations.
        .Rename => finish(todoPhase6()),
        .Symlink => finish(todoPhase6()),
        .Link => finish(todoPhase6()),
        .Readlink => |args| finish(fulfillReadlink(guest, runtime, mem, args)),
        .Lstat => |args| finish(fulfillStatLike(guest, runtime, mem, args.path_ptr, args.path_len, args.ret_stat, false)),
        .Chmod => finish(todoPhase6()),
        .Utimes => finish(todoPhase6()),
        .Getcwd => |args| finish(fulfillGetcwd(guest, runtime, mem, args)),
        .Chdir => |args| finish(fulfillChdir(guest, runtime, mem, args)),
        .Lseek => |args| finish(fulfillLseek(guest, runtime, mem, args)),
        .Ftruncate => |args| finish(fulfillFtruncate(guest, args)),
        .Poll => |args| fulfillPoll(guest, runtime, mem, args),
        // TODO(Phase 6): per-task namespaces and guest-served filesystems.
        .Bind => finish(todoPhase6()),
        .Unmount => finish(todoPhase6()),
        .Serve => finish(todoPhase6()),
        .ServeRecv => finish(todoPhase6()),
        .ServeRespond => finish(todoPhase6()),
        .SvcServe => finish(todoPhase6()),
        .SvcRecv => finish(todoPhase6()),
        .SvcRespond => finish(todoPhase6()),
        .SvcConnect => finish(todoPhase6()),
        .SvcCall => finish(todoPhase6()),
        .Pipe => |args| finish(fulfillPipe(guest, runtime, mem, args)),
        .Dup => |args| finish(fulfillDup(guest, runtime, mem, args)),
        .Dup2 => |args| finish(fulfillDup2(guest, args)),
        .Isatty => |args| finish(fulfillIsatty(guest, runtime, mem, args)),
        .Getpid => |args| finish(fulfillGetpid(guest, runtime, mem, args)),
        .Getppid => |args| finish(fulfillGetppid(guest, runtime, mem, args)),
        // TODO(Phase 6): process creation/wait/signals/job-control policy.
        .Spawn => finish(todoPhase6()),
        .Waitpid => finish(todoPhase6()),
        .Nice => finish(todoPhase6()),
        .Kill => finish(todoPhase6()),
        .Sigdisp => finish(todoPhase6()),
        .Setpgid => finish(todoPhase6()),
        .Tcsetpgrp => finish(todoPhase6()),
        // TODO(Phase 6): network, host-call, ambient time/entropy, and sleep.
        .HttpGet => finish(todoPhase6()),
        .HttpRequest => finish(todoPhase6()),
        .HttpStatus => finish(todoPhase6()),
        .WsOpen => finish(todoPhase6()),
        .HostCall => finish(todoPhase6()),
        .TimeMonotonic => finish(todoPhase6()),
        .TimeRealtime => finish(todoPhase6()),
        .SleepMs => finish(todoPhase6()),
        .Random => finish(todoPhase6()),
        .AbiVersion => |args| finish(fulfillAbiVersion(runtime, mem, args)),
        .Exit => |args| .{ .Exit = args.code },
        // TODO(Phase 6): C/C++ protected-call support.
        .Pcall => finish(todoPhase6()),
        .SetThrow => finish(todoPhase6()),
    };
}

pub fn fulfill(runtime: ?*wasm3.Runtime, mem: ?*anyopaque, guest: *const Guest, pending: mc.Pending) i32 {
    return switch (fulfillOutcome(runtime, mem, guest, pending)) {
        .Resume => |code| code,
        .Exit => |code| code,
        .Block, .Pending => neg(constants.EAGAIN),
    };
}
