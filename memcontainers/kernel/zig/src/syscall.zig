//! syscall.zig — fulfillment of generated `Pending` syscalls against kernel state
//! (ZIG_KERNEL §2.7, §5.1, §4.1).
//!
//! Owns: the policy half of the guest syscall ABI — a decoded generated `Pending`
//!   is fulfilled against the real VFS, task fd table, pipes, scheduler, and the
//!   declared terminal bridge. Would-block results are returned to guest.zig as a
//!   scheduler block/yield outcome; this file never starts or stops the engine.
//! Invariants: guest pointers are range-checked against the supplied linear memory before
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
const servedfs = @import("fs/servedfs.zig");
const registry = @import("service/registry.zig");

const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const Fd = task_mod.Fd;
const BlockReason = task_mod.BlockReason;
const Capabilities = task_mod.Capabilities;
const Tier = task_mod.Tier;

const STAT_RECORD_LEN: usize = @intCast(constants.STAT_REC_LEN);
const PERSIST_ROOT = "/var/persist";
const DEFAULT_PATH = "/bin:/usr/bin";

/// Narrow guest-runtime view used by syscall fulfillment. guest.zig owns the
/// concrete runtime; this interface keeps syscall.zig out of the WAMR driver.
pub const Guest = struct {
    ptr: *anyopaque,
    task_id: *const fn (*anyopaque) TaskId,
    /// Instantiate a runtime for an already-created child task (spawn). Lives in
    /// guest.zig — which imports this file, so the call crosses the layer as a callback
    /// (the same pattern as `task_id`), never a circular import. Returns false if the
    /// child's program could not be parsed/compiled/linked.
    create_child: *const fn (child_id: TaskId, bytes: []const u8, cwd: []const u8) bool,

    pub fn taskId(self: *const Guest) TaskId {
        return self.task_id(self.ptr);
    }

    /// Instantiate the child guest for `child_id` (its Task must already exist).
    pub fn createChild(self: *const Guest, child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
        return self.create_child(child_id, bytes, cwd);
    }
};

pub const Fulfillment = union(enum) {
    Resume: i32,
    Block: BlockReason,
    Pending,
    Exit: i32,
};

pub const SpawnResult = union(enum) {
    pid: TaskId,
    errno: i32,
};

fn finish(code: i32) Fulfillment {
    return .{ .Resume = code };
}

pub fn neg(errno: i32) i32 {
    // Historical Zig scaffolding named this helper after the host-side trap
    // convention, but the mc syscall ABI returns positive WASI errno values:
    // 0 on success, nonzero errno on failure. Keep the helper name so the
    // broad call-site surface stays stable while matching the oracle ABI.
    return errno;
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

pub const GuestMemory = struct {
    base: [*]u8,
    len: usize,

    pub fn from(base_any: ?*anyopaque, len: usize) ?GuestMemory {
        const base: [*]u8 = @ptrCast(base_any orelse return null);
        return .{ .base = base, .len = len };
    }

    pub fn range(self: GuestMemory, ptr: u32, len: u32) ?[]u8 {
        const start: usize = @intCast(ptr);
        const n: usize = @intCast(len);
        const end = std.math.add(usize, start, n) catch return null;
        if (end > self.len) return null;
        return self.base[start..end];
    }
};

fn guestRange(memory: GuestMemory, ptr: u32, len: u32) ?[]u8 {
    return memory.range(ptr, len);
}

fn writeGuestBytes(memory: GuestMemory, ptr: u32, bytes: []const u8) bool {
    if (bytes.len > std.math.maxInt(u32)) return false;
    const out = guestRange(memory, ptr, @intCast(bytes.len)) orelse return false;
    if (bytes.len != 0) @memcpy(out, bytes);
    return true;
}

fn writeGuestU32(memory: GuestMemory, ptr: u32, value: u32) bool {
    const out = guestRange(memory, ptr, 4) orelse return false;
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
    out[3] = @truncate(value >> 24);
    return true;
}

fn writeGuestI64(memory: GuestMemory, ptr: u32, value: i64) bool {
    const out = guestRange(memory, ptr, 8) orelse return false;
    const raw: u64 = @bitCast(value);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[i] = @truncate(raw >> @as(u6, @intCast(i * 8)));
    }
    return true;
}

fn readGuestI64(memory: GuestMemory, ptr: u32) ?i64 {
    const in = guestRange(memory, ptr, 8) orelse return null;
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

pub fn cloneFd(fd: Fd) ?Fd {
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
        .net => |src| Fd{ .net = src.retain() },
        .ws => |src| Fd{ .ws = src.retain() },
        .host_call => |src| Fd{ .host_call = src.retain() },
        .serve, .svc_serve, .svc_conn, .svc_call => null,
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
    memory: GuestMemory,
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
    const raw = guestRange(memory, ptr, len) orelse {
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

pub fn openFlags(raw: i32) ?vfs.OpenFlags {
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

fn fulfillArgs(guest: *const Guest, memory: GuestMemory, args: mc.ArgsArgs) i32 {
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
    if (guestRange(memory, args.ret_len, 4) == null or guestRange(memory, args.ptr, @intCast(n)) == null) {
        return neg(constants.EINVAL);
    }
    if (n != 0 and !writeGuestBytes(memory, args.ptr, blob.items[0..n])) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, args.ret_len, @intCast(blob.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn termEmit(bytes: []const u8, stderr: bool) void {
    if (bytes.len == 0) return;
    if (stderr) {
        bridge.mc_stderr_write(bytes.ptr, bytes.len);
    } else {
        bridge.mc_stdout_write(bytes.ptr, bytes.len);
    }
}

/// Terminal ONLCR: guest output writes plain LF internally; the interactive
/// terminal bridge sees CRLF. Pipes, files, and control-channel captures do not
/// pass through this path, so they stay raw LF.
pub fn termWrite(bytes: []const u8, stderr: bool) void {
    var start: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (byte == '\n') {
            termEmit(bytes[start..i], stderr);
            termEmit("\r\n", stderr);
            start = i + 1;
        }
    }
    termEmit(bytes[start..], stderr);
}

fn fulfillWrite(guest: *const Guest, memory: GuestMemory, args: mc.WriteArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const bytes = guestRange(memory, args.ptr, args.len) orelse return finish(neg(constants.EINVAL));
    if (guestRange(memory, args.ret_n, 4) == null) return finish(neg(constants.EINVAL));

    const idx = fdIndex(args.fd) orelse return finish(neg(constants.EBADF));
    switch (t.getFd(idx)) {
        .none => {
            if (args.fd == 1) {
                termWrite(bytes, false);
                if (!writeGuestU32(memory, args.ret_n, @intCast(bytes.len))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            }
            if (args.fd == 2) {
                termWrite(bytes, true);
                if (!writeGuestU32(memory, args.ret_n, @intCast(bytes.len))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            }
            return finish(neg(constants.EBADF));
        },
        .file => |fh| {
            const n = fh.write(bytes) catch |e| return finish(fsErr(e));
            if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .pipe_write => |p| {
            if (p.isReadClosed()) return finish(neg(constants.EPIPE));
            const n = p.write(bytes);
            if (n == 0 and bytes.len != 0) return .{ .Block = .{ .pipe_write = p } };
            state.kernel().sched.checkUnblocked();
            if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .ws => |ws| {
            switch (ws.send(bytes)) {
                .sent => |n| {
                    if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
                    return finish(constants.ESUCCESS);
                },
                .pending => return .Pending,
                .message_too_big => return finish(neg(constants.EMSGSIZE)),
                .closed => return finish(neg(constants.EPIPE)),
            }
        },
        .pipe_read => return finish(neg(constants.EBADF)),
        .net => return finish(neg(constants.EBADF)),
        .host_call => return finish(neg(constants.EBADF)),
        .serve => return finish(neg(constants.EBADF)),
        .svc_serve => return finish(neg(constants.EBADF)),
        .svc_conn => return finish(neg(constants.EBADF)),
        .svc_call => return finish(neg(constants.EBADF)),
    }
}

fn fulfillRead(guest: *const Guest, memory: GuestMemory, args: mc.ReadArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const out = guestRange(memory, args.ptr, args.len) orelse return finish(neg(constants.EINVAL));
    if (guestRange(memory, args.ret_n, 4) == null) return finish(neg(constants.EINVAL));

    const idx = fdIndex(args.fd) orelse return finish(neg(constants.EBADF));
    switch (t.getFd(idx)) {
        .none => {
            if (args.fd != 0) return finish(neg(constants.EBADF));
            const n = bridge.mc_stdin_read(out.ptr, out.len);
            if (n == 0 and out.len != 0) return .Pending;
            if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .file => |fh| {
            const n = fh.read(out) catch |e| {
                if (e == vfs.FsError.WouldBlock) return .Pending;
                return finish(fsErr(e));
            };
            if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .pipe_read => |p| {
            const n = p.read(out);
            if (n == 0 and !p.isWriteClosed() and out.len != 0) return .{ .Block = .{ .pipe_read = p } };
            state.kernel().sched.checkUnblocked();
            if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .net => |src| switch (src.readInto(out)) {
            .pending => return .Pending,
            .got => |n| {
                if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
            .eof => {
                if (!writeGuestU32(memory, args.ret_n, 0)) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
            .failed => return finish(neg(constants.EIO)),
        },
        .ws => |ws| switch (ws.readInto(out)) {
            .pending => return .Pending,
            .got => |n| {
                if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
            .eof => {
                if (!writeGuestU32(memory, args.ret_n, 0)) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
        },
        .host_call => |src| switch (src.readInto(out)) {
            .pending => return .Pending,
            .got => |n| {
                if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
            .eof => {
                if (!writeGuestU32(memory, args.ret_n, 0)) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
            .failed => return finish(neg(constants.EIO)),
        },
        .svc_call => |src| switch (src.readInto(out)) {
            .pending => return .Pending,
            .got => |n| {
                state.kernel().sched.checkUnblocked();
                if (!writeGuestU32(memory, args.ret_n, @intCast(n))) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
            .eof => {
                if (!writeGuestU32(memory, args.ret_n, 0)) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            },
            .closed => return finish(neg(constants.EIO)),
            .failed => |errno| return finish(neg(errno)),
        },
        .pipe_write => return finish(neg(constants.EBADF)),
        .serve => return finish(neg(constants.EBADF)),
        .svc_serve => return finish(neg(constants.EBADF)),
        .svc_conn => return finish(neg(constants.EBADF)),
    }
}

fn fulfillOpen(guest: *const Guest, memory: GuestMemory, args: mc.OpenArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_fd, 4) orelse return finish(neg(constants.EINVAL));
    var flags = openFlags(args.flags) orelse return finish(neg(constants.EINVAL));

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var errno: i32 = 0;
    const need_write = flags.write or flags.create or flags.truncate or flags.append;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, need_write, true, &errno) orelse return finish(neg(errno));
    if ((flags.read or !need_write) and !t.caps.has(constants.CAP_FS_READ)) return finish(neg(constants.EPERM));
    flags.noatime = !t.caps.has(constants.CAP_AMBIENT);

    const h = state.kernel().ns.openAs(arena, t.id, path, flags) catch |e| {
        if (e == vfs.FsError.WouldBlock) return .Pending;
        return finish(fsErr(e));
    };
    const wrapped = SharedFile.wrap(state.kernel().gpa, h, flags.read or !need_write, flags.write);
    const fd = t.allocFd(state.kernel().gpa, .{ .file = wrapped });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return finish(neg(constants.EINVAL));
    }
    return finish(constants.ESUCCESS);
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

fn fulfillPipe(guest: *const Guest, memory: GuestMemory, args: mc.PipeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_r, 4) orelse return neg(constants.EINVAL);
    _ = guestRange(memory, args.ret_w, 4) orelse return neg(constants.EINVAL);
    const p = state.kernel().sched.allocPipe();
    p.addReader();
    const rfd = t.allocFd(state.kernel().gpa, .{ .pipe_read = p });
    p.addWriter();
    const wfd = t.allocFd(state.kernel().gpa, .{ .pipe_write = p });
    if (!writeGuestU32(memory, args.ret_r, @intCast(rfd))) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, args.ret_w, @intCast(wfd))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillDup(guest: *const Guest, memory: GuestMemory, args: mc.DupArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    const idx = fdIndex(args.fd) orelse return neg(constants.EBADF);
    const cloned = cloneFd(t.getFd(idx)) orelse return neg(constants.EBADF);
    const fd = t.allocFd(state.kernel().gpa, cloned);
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
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

fn fulfillGetpid(guest: *const Guest, memory: GuestMemory, args: mc.GetpidArgs) i32 {
    if (!writeGuestU32(memory, args.ret, guest.taskId())) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillGetppid(guest: *const Guest, memory: GuestMemory, args: mc.GetppidArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const ppid: u32 = t.parent_id orelse 0;
    if (!writeGuestU32(memory, args.ret, ppid)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn statKind(nt: vfs.NodeType) u32 {
    return switch (nt) {
        .file => 0,
        .dir => 1,
        .symlink => 2,
    };
}

fn writeStat(memory: GuestMemory, ret_stat: u32, metadata: vfs.Metadata) i32 {
    var record = [_]u8{0} ** STAT_RECORD_LEN;
    writeLeU64(&record, constants.STAT_REC_SIZE_OFF, metadata.size);
    writeLeU32(&record, constants.STAT_REC_NODE_TYPE_OFF, statKind(metadata.node_type));
    writeLeU32(&record, constants.STAT_REC_NLINK_OFF, metadata.nlink);
    writeLeU32(&record, constants.STAT_REC_MODE_OFF, metadata.mode);
    writeLeI64(&record, constants.STAT_REC_MTIME_OFF, metadata.mtime);
    writeLeI64(&record, constants.STAT_REC_ATIME_OFF, metadata.atime);
    writeLeI64(&record, constants.STAT_REC_CTIME_OFF, metadata.ctime);
    return if (writeGuestBytes(memory, ret_stat, &record)) constants.ESUCCESS else neg(constants.EINVAL);
}

fn fulfillStatLike(guest: *const Guest, memory: GuestMemory, path_ptr: u32, path_len: u32, ret_stat: u32, follow: bool) i32 {
    _ = guestRange(memory, ret_stat, @intCast(STAT_RECORD_LEN)) orelse return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, path_ptr, path_len, false, follow, &errno) orelse return neg(errno);
    const md = state.kernel().ns.statPath(arena, path) catch |e| return fsErr(e);
    return writeStat(memory, ret_stat, md);
}

fn fulfillReadlink(guest: *const Guest, memory: GuestMemory, args: mc.ReadlinkArgs) i32 {
    _ = guestRange(memory, args.ret_len, 4) orelse return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, false, false, &errno) orelse return neg(errno);
    var target: std.ArrayList(u8) = .empty;
    state.kernel().ns.readlink(arena, path, &target) catch |e| return fsErr(e);
    const n = @min(target.items.len, @as(usize, @intCast(args.buf_len)));
    if (guestRange(memory, args.buf, @intCast(n)) == null) return neg(constants.EINVAL);
    if (n != 0 and !writeGuestBytes(memory, args.buf, target.items[0..n])) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, args.ret_len, @intCast(target.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillReaddir(guest: *const Guest, memory: GuestMemory, args: mc.ReaddirArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_len, 4) orelse return finish(neg(constants.EINVAL));
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, false, true, &errno) orelse return finish(neg(errno));

    var entries: std.ArrayList(vfs.DirEntry) = .empty;
    state.kernel().ns.readdir(arena, t.id, path, &entries) catch |e| {
        if (e == vfs.FsError.WouldBlock) return .Pending;
        return finish(fsErr(e));
    };
    var blob: std.ArrayList(u8) = .empty;
    for (entries.items) |entry| {
        blob.appendSlice(arena, entry.name) catch @panic("OOM");
        blob.append(arena, 0) catch @panic("OOM");
    }
    const n = @min(blob.items.len, @as(usize, @intCast(args.buf_len)));
    if (guestRange(memory, args.buf, @intCast(n)) == null) return finish(neg(constants.EINVAL));
    if (n != 0 and !writeGuestBytes(memory, args.buf, blob.items[0..n])) return finish(neg(constants.EINVAL));
    if (!writeGuestU32(memory, args.ret_len, @intCast(blob.items.len))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

fn fulfillMkdir(guest: *const Guest, memory: GuestMemory, args: mc.MkdirArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.mkdir(arena, t.id, path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillUnlink(guest: *const Guest, memory: GuestMemory, args: mc.UnlinkArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.unlink(arena, t.id, path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillRename(guest: *const Guest, memory: GuestMemory, args: mc.RenameArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const from = resolveGuestPath(guest, memory, arena, args.from_ptr, args.from_len, true, false, &errno) orelse return neg(errno);
    const to = resolveGuestPath(guest, memory, arena, args.to_ptr, args.to_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.rename(arena, t.id, from, to) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillSymlink(guest: *const Guest, memory: GuestMemory, args: mc.SymlinkArgs) i32 {
    const target = guestRange(memory, args.target_ptr, args.target_len) orelse return neg(constants.EINVAL);
    if (std.mem.indexOfScalar(u8, target, 0) != null) return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const link = resolveGuestPath(guest, memory, arena, args.link_ptr, args.link_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.symlink(arena, target, link) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillLink(guest: *const Guest, memory: GuestMemory, args: mc.LinkArgs) i32 {
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const existing = resolveGuestPath(guest, memory, arena, args.old_ptr, args.old_len, false, false, &errno) orelse return neg(errno);
    const new = resolveGuestPath(guest, memory, arena, args.new_ptr, args.new_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.link(arena, existing, new) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillChmod(guest: *const Guest, memory: GuestMemory, args: mc.ChmodArgs) i32 {
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.setMode(arena, path, @intCast(args.mode & 0o7777)) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillUtimes(guest: *const Guest, memory: GuestMemory, args: mc.UtimesArgs) i32 {
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    var atime: i64 = undefined;
    var mtime: i64 = undefined;
    if (args.times_ptr == 0) {
        const now = vfs.wallNowMs();
        atime = now;
        mtime = now;
    } else {
        const mtime_ptr = std.math.add(u32, args.times_ptr, 8) catch return neg(constants.EINVAL);
        atime = readGuestI64(memory, args.times_ptr) orelse return neg(constants.EINVAL);
        mtime = readGuestI64(memory, mtime_ptr) orelse return neg(constants.EINVAL);
    }
    state.kernel().ns.setTimes(arena, path, atime, mtime) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillGetcwd(guest: *const Guest, memory: GuestMemory, args: mc.GetcwdArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (t.cwd.len > std.math.maxInt(u32)) return neg(constants.EINVAL);
    _ = guestRange(memory, args.ret_len, 4) orelse return neg(constants.EINVAL);
    if (t.cwd.len > @as(usize, @intCast(args.buf_len))) return neg(constants.EINVAL);
    if (guestRange(memory, args.buf, @intCast(t.cwd.len)) == null) return neg(constants.EINVAL);
    if (t.cwd.len != 0 and !writeGuestBytes(memory, args.buf, t.cwd)) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, args.ret_len, @intCast(t.cwd.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillChdir(guest: *const Guest, memory: GuestMemory, args: mc.ChdirArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, false, true, &errno) orelse return neg(errno);
    const md = state.kernel().ns.statPath(arena, path) catch |e| return fsErr(e);
    if (md.node_type != .dir) return neg(constants.ENOTDIR);
    if (!md.ownerExecutable()) return neg(constants.EACCES);
    t.setCwd(state.kernel().gpa, path);
    return constants.ESUCCESS;
}

fn fulfillLseek(guest: *const Guest, memory: GuestMemory, args: mc.LseekArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const idx = fdIndex(args.fd) orelse return neg(constants.EINVAL);
    const off = readGuestI64(memory, args.off_ptr) orelse return neg(constants.EINVAL);
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
    if (!writeGuestI64(memory, args.off_ptr, @intCast(next))) return neg(constants.EINVAL);
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
        .net => |src| {
            if (want_in and src.pollReadable()) result |= constants.POLLIN;
        },
        .host_call => |src| {
            if (want_in and src.pollReadable()) result |= constants.POLLIN;
        },
        .svc_call => |src| {
            if (want_in and src.pollReadable()) result |= constants.POLLIN;
        },
        .ws => |ws| {
            if (want_in and ws.pollReadable()) result |= constants.POLLIN;
            if (want_out and ws.pollWritable()) result |= constants.POLLOUT;
            if (ws.pollHup()) result |= constants.POLLHUP;
        },
        .serve, .svc_serve, .svc_conn => {},
    }
    return @intCast(result);
}

fn fulfillPoll(guest: *const Guest, memory: GuestMemory, args: mc.PollArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const total = std.math.mul(usize, @intCast(args.nfds), 8) catch return finish(neg(constants.EINVAL));
    if (total > std.math.maxInt(u32)) return finish(neg(constants.EINVAL));
    const fds = guestRange(memory, args.fds_ptr, @intCast(total)) orelse return finish(neg(constants.EINVAL));
    _ = guestRange(memory, args.ret_ready, 4) orelse return finish(neg(constants.EINVAL));

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
    if (!writeGuestU32(memory, args.ret_ready, ready)) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

fn fulfillIsatty(guest: *const Guest, memory: GuestMemory, args: mc.IsattyArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const tty: u32 = if (args.fd >= 0 and args.fd <= 2 and t.getFd(@intCast(args.fd)) == .none) 1 else 0;
    if (!writeGuestU32(memory, args.ret, tty)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillAbiVersion(memory: GuestMemory, args: mc.AbiVersionArgs) i32 {
    if (!writeGuestU32(memory, args.ret, @intCast(constants.abi_version()))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillTimeMonotonic(guest: *const Guest, memory: GuestMemory, args: mc.TimeMonotonicArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_AMBIENT)) return neg(constants.EPERM);
    if (!writeGuestI64(memory, args.ret, bridge.mc_time_monotonic())) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillTimeRealtime(guest: *const Guest, memory: GuestMemory, args: mc.TimeRealtimeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_AMBIENT)) return neg(constants.EPERM);
    const now = bridge.mc_time_now();
    vfs.wall_ms = now;
    if (!writeGuestI64(memory, args.ret, now)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn fulfillRandom(guest: *const Guest, memory: GuestMemory, args: mc.RandomArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_AMBIENT)) return neg(constants.EPERM);
    const out = guestRange(memory, args.ptr, args.len) orelse return neg(constants.EINVAL);
    if (out.len != 0) bridge.mc_random(out.ptr, out.len);
    return constants.ESUCCESS;
}

pub fn releaseFdValue(fd: Fd) void {
    switch (fd) {
        .pipe_read => |p| p.closeRead(),
        .pipe_write => |p| p.closeWrite(),
        .file => |fh| fh.close(),
        .net => |src| src.release(),
        .ws => |src| src.release(),
        .host_call => |src| src.release(),
        .serve => |owner| owner.release(),
        .svc_serve => |owner| owner.release(),
        .svc_conn => |conn| conn.release(),
        .svc_call => |src| src.release(),
        .none => {},
    }
}

fn duplicateReadableFd(parent: *const Task, fd: i32) ?Fd {
    if (fd < 0) return null;
    if (fd < 3 and fd != 0) return null;
    const idx: usize = @intCast(fd);
    return switch (parent.getFd(idx)) {
        .none => if (fd == 0) Fd.none else null,
        .pipe_read => |p| blk: {
            p.addReader();
            break :blk Fd{ .pipe_read = p };
        },
        .file => |fh| blk: {
            // TODO(Phase 6, fd/file redirection): non-SharedFile handles need a
            // vfs-level retain/clone operation before they can be inherited.
            if (!SharedFile.readableHandle(fh)) break :blk null;
            const retained = SharedFile.retain(fh) orelse break :blk null;
            break :blk Fd{ .file = retained };
        },
        .net => |src| Fd{ .net = src.retain() },
        .pipe_write => null,
        .ws => null,
        .host_call => null,
        .serve => null,
        .svc_serve => null,
        .svc_conn => null,
        .svc_call => null,
    };
}

fn duplicateWritableFd(parent: *const Task, fd: i32) ?Fd {
    if (fd < 0) return null;
    if (fd < 3 and fd != 1 and fd != 2) return null;
    const idx: usize = @intCast(fd);
    return switch (parent.getFd(idx)) {
        .none => if (fd == 1 or fd == 2) Fd.none else null,
        .pipe_write => |p| blk: {
            p.addWriter();
            break :blk Fd{ .pipe_write = p };
        },
        .file => |fh| blk: {
            // TODO(Phase 6, fd/file redirection): non-SharedFile handles need a
            // vfs-level retain/clone operation before they can be inherited.
            if (!SharedFile.writableHandle(fh)) break :blk null;
            const retained = SharedFile.retain(fh) orelse break :blk null;
            break :blk Fd{ .file = retained };
        },
        .pipe_read => null,
        .net => null,
        .ws => null,
        .host_call => null,
        .serve => null,
        .svc_serve => null,
        .svc_conn => null,
        .svc_call => null,
    };
}

fn lessTaskId(_: void, a: TaskId, b: TaskId) bool {
    return a < b;
}

fn sortedTaskIds(arena: std.mem.Allocator) []TaskId {
    const ids = state.kernel().sched.taskIds(arena);
    std.mem.sort(TaskId, ids, {}, lessTaskId);
    return ids;
}

fn readUleb(bytes: []const u8, at: usize) ?struct { value: u32, adv: usize } {
    var result: u32 = 0;
    var shift: u32 = 0;
    var n: usize = 0;
    while (true) {
        if (at + n >= bytes.len) return null;
        if (shift >= 32) return null;
        const byte = bytes[at + n];
        n += 1;
        const low = @as(u32, byte & 0x7f);
        if (shift == 28 and low > 0x0f) return null;
        result |= low << @as(u5, @intCast(shift));
        if ((byte & 0x80) == 0) return .{ .value = result, .adv = n };
        shift += 7;
    }
}

fn uniqueCustom(bytes: []const u8, name: []const u8) ?[]const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) return null;
    var found: ?[]const u8 = null;
    var i: usize = 8;
    while (i < bytes.len) {
        const id = bytes[i];
        i += 1;
        const size_info = readUleb(bytes, i) orelse return null;
        i += size_info.adv;
        const body_start = i;
        const body_end = std.math.add(usize, body_start, @intCast(size_info.value)) catch return null;
        if (body_end > bytes.len) return null;
        if (id == 0) {
            const name_info = readUleb(bytes, body_start) orelse return null;
            const name_start = body_start + name_info.adv;
            const name_end = std.math.add(usize, name_start, @intCast(name_info.value)) catch return null;
            if (name_end <= body_end and std.mem.eql(u8, bytes[name_start..name_end], name)) {
                if (found != null) return null;
                found = bytes[name_end..body_end];
            }
        }
        i = body_end;
    }
    return found;
}

fn declaredTier(bytes: []const u8) ?Tier {
    const payload = uniqueCustom(bytes, "mc_tier") orelse return null;
    if (!std.unicode.utf8ValidateSlice(payload)) return null;
    return Tier.parse(payload);
}

const ExecPolicy = struct {
    caps: Capabilities,
    root: ?[]const u8,
};

pub const ChildFactory = struct {
    ptr: *const anyopaque,
    create_child: *const fn (*const anyopaque, TaskId, []const u8, []const u8) bool,

    fn createChild(self: ChildFactory, child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
        return self.create_child(self.ptr, child_id, bytes, cwd);
    }
};

fn execPolicy(parent_caps: Capabilities, parent_root: ?[]const u8, binary: ?Tier, requested: ?Tier, cwd: []const u8) ExecPolicy {
    var caps = parent_caps;
    if (binary) |t| caps = caps.intersect(t.caps());
    if (requested) |t| caps = caps.intersect(t.caps());
    const confines = (binary != null and binary.?.confines()) or (requested != null and requested.?.confines());
    return .{
        .caps = caps,
        .root = if (confines) cwd else parent_root,
    };
}

fn appendProgramCandidate(arena: std.mem.Allocator, candidates: *std.ArrayList([]const u8), cwd: []const u8, raw: []const u8) void {
    const absolute = absolutize(arena, cwd, raw);
    candidates.append(arena, absolute) catch @panic("OOM");
}

fn resolveProgram(arena: std.mem.Allocator, owner: TaskId, cwd: []const u8, cmd: []const u8, path: []const u8) ?[]u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        appendProgramCandidate(arena, &candidates, cwd, cmd);
    } else {
        var dirs = std.mem.splitScalar(u8, path, ':');
        while (dirs.next()) |dir| {
            if (dir.len == 0) continue;
            const joined = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, cmd }) catch @panic("OOM");
            appendProgramCandidate(arena, &candidates, cwd, joined);
        }
    }

    for (candidates.items) |candidate| {
        // TODO(Phase 6, namespace/services group): served-fs `WouldBlock`
        // should re-arm spawn and retry; Zig has no served fs yet, so this
        // path is treated as NotFound by continuing the lookup.
        const real = state.kernel().ns.canonicalize(arena, candidate, true) catch continue;
        const md = state.kernel().ns.statPath(arena, real) catch continue;
        if (!md.ownerExecutable()) continue;
        var h = state.kernel().ns.openAs(arena, owner, real, vfs.OpenFlags.READ) catch continue;
        defer h.close();
        var out: std.ArrayList(u8) = .empty;
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = h.read(&tmp) catch {
                out.deinit(state.kernel().gpa);
                break;
            };
            if (n == 0) {
                if (out.items.len == 0) {
                    out.deinit(state.kernel().gpa);
                    break;
                }
                return out.toOwnedSlice(state.kernel().gpa) catch @panic("OOM");
            }
            out.appendSlice(state.kernel().gpa, tmp[0..n]) catch @panic("OOM");
        }
    }
    return null;
}

pub fn wrapFileHandle(gpa: std.mem.Allocator, inner: vfs.FileHandle, readable: bool, writable: bool) vfs.FileHandle {
    return SharedFile.wrap(gpa, inner, readable, writable);
}

fn takeEintr(t: *Task) bool {
    var hit = false;
    for ([_]i32{ constants.SIGINT, constants.SIGTERM, constants.SIGHUP, constants.SIGTSTP }) |sig| {
        if (t.signalPending(sig) and t.signalIgnored(sig)) {
            t.clearSignal(sig);
            hit = true;
        }
    }
    return hit;
}

fn fulfillSleepMs(guest: *const Guest, args: mc.SleepMsArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (!t.caps.has(constants.CAP_AMBIENT)) {
        t.timed_deadline = null;
        return finish(neg(constants.EPERM));
    }
    if (args.ms <= 0) {
        t.timed_deadline = null;
        return finish(constants.ESUCCESS);
    }

    const now = bridge.mc_time_monotonic();
    const deadline = t.timed_deadline orelse blk: {
        const d = std.math.add(i64, now, @as(i64, args.ms)) catch std.math.maxInt(i64);
        t.timed_deadline = d;
        break :blk d;
    };
    if (now >= deadline) {
        t.timed_deadline = null;
        return finish(constants.ESUCCESS);
    }
    if (takeEintr(t)) {
        t.timed_deadline = null;
        return finish(neg(constants.EINTR));
    }
    return .{ .Block = .{ .timer = deadline } };
}

fn isChildOf(parent: TaskId, child_id: TaskId) bool {
    const child = state.kernel().sched.getTask(child_id) orelse return false;
    return child.parent_id != null and child.parent_id.? == parent;
}

fn findZombieChild(arena: std.mem.Allocator, parent: TaskId, pid: i32) ?TaskId {
    if (pid > 0) {
        const id: TaskId = @intCast(pid);
        const child = state.kernel().sched.getTask(id) orelse return null;
        return if (child.parent_id != null and child.parent_id.? == parent and child.state == .zombie) id else null;
    }
    for (sortedTaskIds(arena)) |id| {
        const child = state.kernel().sched.getTask(id) orelse continue;
        if (child.parent_id != null and child.parent_id.? == parent and child.state == .zombie) return id;
    }
    return null;
}

fn findStoppedChild(arena: std.mem.Allocator, parent: TaskId, pid: i32) ?TaskId {
    if (pid > 0) {
        const id: TaskId = @intCast(pid);
        const child = state.kernel().sched.getTask(id) orelse return null;
        return if (child.parent_id != null and child.parent_id.? == parent and child.sig_stopped) id else null;
    }
    for (sortedTaskIds(arena)) |id| {
        const child = state.kernel().sched.getTask(id) orelse continue;
        if (child.parent_id != null and child.parent_id.? == parent and child.sig_stopped) return id;
    }
    return null;
}

fn hasWaitTarget(arena: std.mem.Allocator, parent: TaskId, pid: i32) bool {
    if (pid > 0) return isChildOf(parent, @intCast(pid));
    for (sortedTaskIds(arena)) |id| {
        if (isChildOf(parent, id)) return true;
    }
    return false;
}

pub fn spawnNative(parent_id: TaskId, argv: []const []const u8, in_fd: i32, out_fd: i32, err_fd: i32, tier: i32, factory: ChildFactory) SpawnResult {
    const parent = state.kernel().sched.getTask(parent_id) orelse return .{ .errno = constants.EIO };
    if (!parent.caps.has(constants.CAP_SPAWN)) return .{ .errno = constants.EPERM };
    if (argv.len == 0) return .{ .errno = constants.EINVAL };

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prog_name = argv[0];
    const child_args = argv[1..];
    const cwd = parent.cwd;
    const live_path = parent.env.get("PATH") orelse DEFAULT_PATH;
    const bytes = resolveProgram(arena, parent.id, cwd, prog_name, live_path) orelse return .{ .errno = constants.ENOENT };
    defer state.kernel().gpa.free(bytes);

    const policy = execPolicy(parent.caps, parent.confine_root, declaredTier(bytes), Tier.fromArg(tier), cwd);

    var stdin = duplicateReadableFd(parent, in_fd) orelse return .{ .errno = constants.EBADF };
    var stdout = duplicateWritableFd(parent, out_fd) orelse {
        releaseFdValue(stdin);
        return .{ .errno = constants.EBADF };
    };
    var stderr = duplicateWritableFd(parent, err_fd) orelse {
        releaseFdValue(stdin);
        releaseFdValue(stdout);
        return .{ .errno = constants.EBADF };
    };

    const child_pid = state.kernel().sched.spawn(parent.id, prog_name, prog_name, child_args, cwd);
    state.kernel().sched.setTaskPolicy(child_pid, policy.caps, policy.root);
    if (state.kernel().sched.getTask(child_pid)) |child| {
        child.setFd(state.kernel().gpa, 0, stdin);
        child.setFd(state.kernel().gpa, 1, stdout);
        child.setFd(state.kernel().gpa, 2, stderr);
        stdin = .none;
        stdout = .none;
        stderr = .none;
        // TODO(Phase 6, namespace/services group): fork the parent's namespace
        // for child_pid and install a private `/scratch` mount according to
        // CAP_SCRATCH. Zig vfs currently has one root namespace, not per-task
        // namespace ownership.
    }

    if (!factory.createChild(child_pid, bytes, cwd)) {
        state.kernel().sched.exitTask(child_pid, neg(constants.EINVAL));
        state.kernel().sched.reapZombie(child_pid);
        state.kernel().sched.dropDeadPipes();
        return .{ .errno = constants.EINVAL };
    }

    return .{ .pid = child_pid };
}

fn spawnGuestChild(ptr: *const anyopaque, child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
    const g: *const Guest = @ptrCast(@alignCast(ptr));
    return g.createChild(child_id, bytes, cwd);
}

fn fulfillSpawn(guest: *const Guest, memory: GuestMemory, args: mc.SpawnArgs) Fulfillment {
    _ = guestRange(memory, args.ret_pid, 4) orelse return finish(neg(constants.EINVAL));

    const blob = guestRange(memory, args.argv_ptr, args.argv_len) orelse return finish(neg(constants.EINVAL));
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(part)) continue;
        argv.append(arena, arena.dupe(u8, part) catch @panic("OOM")) catch @panic("OOM");
    }

    const child_pid = switch (spawnNative(guest.taskId(), argv.items, args.in_fd, args.out_fd, args.err_fd, args.tier, .{
        .ptr = @ptrCast(guest),
        .create_child = spawnGuestChild,
    })) {
        .pid => |pid| pid,
        .errno => |errno| return finish(neg(errno)),
    };
    if (!writeGuestU32(memory, args.ret_pid, @intCast(child_pid))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

fn fulfillWaitpid(guest: *const Guest, memory: GuestMemory, args: mc.WaitpidArgs) Fulfillment {
    const me_task = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_status, 4) orelse return finish(neg(constants.EINVAL));
    _ = guestRange(memory, args.ret_pid, 4) orelse return finish(neg(constants.EINVAL));

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (findZombieChild(arena, me_task.id, args.pid)) |zpid| {
        const code = state.kernel().sched.getExitCode(zpid) orelse 0;
        state.kernel().sched.reapZombie(zpid);
        state.kernel().sched.dropDeadPipes();
        if (!writeGuestU32(memory, args.ret_status, @bitCast(code))) return finish(neg(constants.EINVAL));
        if (!writeGuestU32(memory, args.ret_pid, zpid)) return finish(neg(constants.EINVAL));
        return finish(constants.ESUCCESS);
    }

    if ((args.opts & constants.WNOHANG) == 0) {
        if (findStoppedChild(arena, me_task.id, args.pid)) |spid| {
            const report = if (state.kernel().sched.getTask(spid)) |child| child.takeStopReport() else false;
            if (report) {
                const status: u32 = @intCast(constants.STOPPED_STATUS_BASE + constants.SIGTSTP);
                if (!writeGuestU32(memory, args.ret_status, status)) return finish(neg(constants.EINVAL));
                if (!writeGuestU32(memory, args.ret_pid, spid)) return finish(neg(constants.EINVAL));
                return finish(constants.ESUCCESS);
            }
        }
    }

    if (!hasWaitTarget(arena, me_task.id, args.pid)) return finish(neg(constants.ECHILD));
    if ((args.opts & constants.WNOHANG) != 0) {
        if (!writeGuestU32(memory, args.ret_pid, 0)) return finish(neg(constants.EINVAL));
        return finish(constants.ESUCCESS);
    }
    if (takeEintr(me_task)) return finish(neg(constants.EINTR));
    if (args.pid > 0) return .{ .Block = .{ .wait_child = @intCast(args.pid) } };
    return .Pending;
}

fn fulfillKill(guest: *const Guest, args: mc.KillArgs) Fulfillment {
    const me_task = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (args.sig < 0 or args.sig >= 32) return finish(neg(constants.EINVAL));
    if (!me_task.caps.has(constants.CAP_SPAWN)) return finish(neg(constants.EPERM));
    const me = me_task.id;

    if (args.pid > 0) {
        const target: TaskId = @intCast(args.pid);
        if (state.kernel().sched.getTask(target) == null) return finish(neg(constants.ESRCH));
        if (target != me and !state.kernel().sched.isAncestorOf(me, target)) return finish(neg(constants.EPERM));
        if (args.sig != 0) state.kernel().sched.deliverSignal(target, args.sig);
        return finish(constants.ESUCCESS);
    }

    const pgid: TaskId = if (args.pid == 0) me_task.pgid else blk: {
        const abs_pid = std.math.negate(args.pid) catch return finish(neg(constants.EINVAL));
        break :blk @intCast(abs_pid);
    };

    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var members: std.ArrayList(TaskId) = .empty;
    for (sortedTaskIds(arena)) |id| {
        const t = state.kernel().sched.getTask(id) orelse continue;
        if (t.pgid == pgid and (id == me or state.kernel().sched.isAncestorOf(me, id))) {
            members.append(arena, id) catch @panic("OOM");
        }
    }
    if (members.items.len == 0) return finish(neg(constants.ESRCH));
    if (args.sig != 0) {
        for (members.items) |id| state.kernel().sched.deliverSignal(id, args.sig);
    }
    return finish(constants.ESUCCESS);
}

fn fulfillSigdisp(guest: *const Guest, args: mc.SigdispArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (args.sig < 1 or args.sig >= 32 or args.sig == constants.SIGKILL) return finish(neg(constants.EINVAL));
    t.setSignalIgnored(args.sig, args.disp == constants.SIG_IGN);
    return finish(constants.ESUCCESS);
}

fn fulfillSetpgid(guest: *const Guest, args: mc.SetpgidArgs) Fulfillment {
    const me = guest.taskId();
    if (args.pid < 0) return finish(neg(constants.ESRCH));
    const target: TaskId = if (args.pid == 0) me else @intCast(args.pid);
    if (state.kernel().sched.getTask(target) == null) return finish(neg(constants.ESRCH));
    if (target != me and !state.kernel().sched.isAncestorOf(me, target)) return finish(neg(constants.EPERM));
    const pgid: TaskId = if (args.pgid <= 0) 0 else @intCast(args.pgid);
    state.kernel().sched.setPgid(target, pgid);
    return finish(constants.ESUCCESS);
}

fn fulfillTcsetpgrp(guest: *const Guest, args: mc.TcsetpgrpArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    if (args.pgid <= 0) return finish(neg(constants.EINVAL));
    if (!t.caps.has(constants.CAP_SPAWN)) return finish(neg(constants.EPERM));
    state.kernel().sched.foreground_pgid = @intCast(args.pgid);
    return finish(constants.ESUCCESS);
}

fn fulfillNice(guest: *const Guest, memory: GuestMemory, args: mc.NiceArgs) Fulfillment {
    _ = guestRange(memory, args.ret, 4) orelse return finish(neg(constants.EINVAL));
    const new_nice: i8 = blk: {
        const t = currentTask(guest) orelse break :blk 0;
        const next = std.math.clamp(@as(i32, t.nice) + args.inc, -20, 19);
        t.nice = @intCast(next);
        break :blk t.nice;
    };
    const signed: i32 = new_nice;
    if (!writeGuestU32(memory, args.ret, @bitCast(signed))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

fn netPermitted(guest: *const Guest) bool {
    const t = currentTask(guest) orelse return false;
    return t.caps.has(constants.CAP_NET);
}

fn readGuestUtf8(memory: GuestMemory, ptr: u32, len: u32) ?[]const u8 {
    const bytes = guestRange(memory, ptr, len) orelse return null;
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    return bytes;
}

fn installFd(t: *Task, memory: GuestMemory, ret_fd: u32, fd_value: Fd) i32 {
    const fd = t.allocFd(state.kernel().gpa, fd_value);
    if (!writeGuestU32(memory, ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

fn fulfillHttpGet(guest: *const Guest, memory: GuestMemory, args: mc.HttpGetArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const url = readGuestUtf8(memory, args.url_ptr, args.url_len) orelse return neg(constants.EINVAL);
    if (url.len == 0) return neg(constants.EINVAL);

    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(state.kernel().gpa);
    blob.appendSlice(state.kernel().gpa, "GET ") catch @panic("OOM");
    blob.appendSlice(state.kernel().gpa, url) catch @panic("OOM");
    blob.appendSlice(state.kernel().gpa, "\n\n") catch @panic("OOM");

    const src = state.kernel().net.startHttp(blob.items) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .net = src });
}

fn fulfillHttpRequest(guest: *const Guest, memory: GuestMemory, args: mc.HttpRequestArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const blob = guestRange(memory, args.req_ptr, args.req_len) orelse return neg(constants.EINVAL);
    if (blob.len == 0) return neg(constants.EINVAL);
    const src = state.kernel().net.startHttp(blob) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .net = src });
}

fn fulfillHttpStatus(guest: *const Guest, memory: GuestMemory, args: mc.HttpStatusArgs) Fulfillment {
    _ = guestRange(memory, args.ret_status, 4) orelse return finish(neg(constants.EINVAL));
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    const idx = fdIndex(args.fd) orelse return finish(neg(constants.EBADF));
    const src = switch (t.getFd(idx)) {
        .net => |s| s,
        else => return finish(neg(constants.EBADF)),
    };
    switch (src.driveStatus()) {
        .pending => return .Pending,
        .ready => |status| {
            if (!writeGuestU32(memory, args.ret_status, status)) return finish(neg(constants.EINVAL));
            return finish(constants.ESUCCESS);
        },
        .failed => return finish(neg(constants.EIO)),
    }
}

fn fulfillWsOpen(guest: *const Guest, memory: GuestMemory, args: mc.WsOpenArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const url = readGuestUtf8(memory, args.url_ptr, args.url_len) orelse return neg(constants.EINVAL);
    if (url.len == 0) return neg(constants.EINVAL);
    const src = state.kernel().net.connectWs(url) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .ws = src });
}

fn fulfillHostCall(guest: *const Guest, memory: GuestMemory, args: mc.HostCallArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!netPermitted(guest)) return neg(constants.EPERM);
    const blob = guestRange(memory, args.req_ptr, args.req_len) orelse return neg(constants.EINVAL);
    if (blob.len == 0) return neg(constants.EINVAL);
    const src = state.kernel().host_call.start(blob) catch return neg(constants.EPERM);
    return installFd(t, memory, args.ret_fd, .{ .host_call = src });
}

fn fulfillBind(guest: *const Guest, memory: GuestMemory, args: mc.BindArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_MOUNT)) return neg(constants.EPERM);
    const old_raw = readGuestUtf8(memory, args.old_ptr, args.old_len) orelse return neg(constants.EINVAL);
    const new_raw = readGuestUtf8(memory, args.new_ptr, args.new_len) orelse return neg(constants.EINVAL);
    if (std.mem.indexOfScalar(u8, old_raw, 0) != null or std.mem.indexOfScalar(u8, new_raw, 0) != null) return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old_path = absolutize(arena, t.cwd, old_raw);
    const new_path = absolutize(arena, t.cwd, new_raw);
    if (!pathWithin(t.confine_root, old_path) or !pathWithin(t.confine_root, new_path)) return neg(constants.EPERM);
    state.kernel().ns.bind(arena, old_path, new_path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn fulfillUnmount(guest: *const Guest, memory: GuestMemory, args: mc.UnmountArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_MOUNT)) return neg(constants.EPERM);
    const raw = readGuestUtf8(memory, args.path_ptr, args.path_len) orelse return neg(constants.EINVAL);
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = absolutize(arena, t.cwd, raw);
    if (!pathWithin(t.confine_root, path)) return neg(constants.EPERM);
    state.kernel().ns.unmount(path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

fn serveChannel(t: *const Task, fd: i32) ?*servedfs.ServeChannel {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .serve => |owner| owner.channel,
        else => null,
    };
}

fn fulfillServe(guest: *const Guest, memory: GuestMemory, args: mc.ServeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    if (!t.caps.has(constants.CAP_MOUNT)) return neg(constants.EPERM);
    const raw = readGuestUtf8(memory, args.path_ptr, args.path_len) orelse return neg(constants.EINVAL);
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null) return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = absolutize(arena, t.cwd, raw);
    if (!pathWithin(t.confine_root, path)) return neg(constants.EPERM);

    const channel = servedfs.ServeChannel.create(state.kernel().gpa);
    const fs = servedfs.ServedFs.create(state.kernel().gpa, channel);
    state.kernel().ns.mountLabeled(path, fs.fileSystem(), "served", false);
    const owner = servedfs.ServeOwner.create(state.kernel().gpa, channel);
    const fd = t.allocFd(state.kernel().gpa, .{ .serve = owner });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

fn appendU32(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u32) void {
    out.append(a, @truncate(value)) catch @panic("OOM");
    out.append(a, @truncate(value >> 8)) catch @panic("OOM");
    out.append(a, @truncate(value >> 16)) catch @panic("OOM");
    out.append(a, @truncate(value >> 24)) catch @panic("OOM");
}

fn fulfillServeRecv(guest: *const Guest, memory: GuestMemory, args: mc.ServeRecvArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_len, 4) orelse return finish(neg(constants.EINVAL));
    const channel = serveChannel(t, args.fd) orelse return finish(neg(constants.EBADF));
    const req = channel.peekRequest() orelse return .Pending;
    const total = 20 + req.path.len + req.arg.len;
    if (total > @as(usize, @intCast(args.buf_len)) or guestRange(memory, args.buf, @intCast(total)) == null) {
        return finish(neg(constants.EINVAL));
    }
    var taken = channel.takeRequest() orelse return .Pending;
    defer taken.deinit(state.kernel().gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(state.kernel().gpa);
    appendU32(&out, state.kernel().gpa, taken.id);
    appendU32(&out, state.kernel().gpa, taken.caller);
    appendU32(&out, state.kernel().gpa, taken.op);
    appendU32(&out, state.kernel().gpa, @intCast(taken.path.len));
    out.appendSlice(state.kernel().gpa, taken.path) catch @panic("OOM");
    appendU32(&out, state.kernel().gpa, @intCast(taken.arg.len));
    out.appendSlice(state.kernel().gpa, taken.arg) catch @panic("OOM");
    if (!writeGuestBytes(memory, args.buf, out.items)) return finish(neg(constants.EINVAL));
    if (!writeGuestU32(memory, args.ret_len, @intCast(out.items.len))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

fn fulfillServeRespond(guest: *const Guest, memory: GuestMemory, args: mc.ServeRespondArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const channel = serveChannel(t, args.fd) orelse return neg(constants.EBADF);
    const data = guestRange(memory, args.data_ptr, args.data_len) orelse return neg(constants.EINVAL);
    return if (channel.respond(args.req_id, args.status, data)) constants.ESUCCESS else neg(constants.EINVAL);
}

fn svcChannel(t: *const Task, fd: i32) ?*registry.ServiceChannel {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .svc_serve => |owner| owner.channel,
        else => null,
    };
}

fn svcConn(t: *const Task, fd: i32) ?struct { channel: *registry.ServiceChannel, session: u32 } {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .svc_conn => |conn| .{ .channel = conn.channel, .session = conn.session },
        else => null,
    };
}

const ServiceConnectPoll = union(enum) {
    ready: *registry.ServiceChannel,
    pending,
    errno: i32,
};

fn serviceChannelForConnect(name: []const u8) ServiceConnectPoll {
    const k = state.kernel();
    if (k.services.lookupService(name)) |channel| return .{ .ready = channel };
    if (k.services.serviceState(name)) |s| {
        switch (s) {
            .activating => |a| {
                const alive = if (k.sched.getTask(a.pid)) |t| t.state != .zombie else false;
                if (alive) {
                    if (vfs.wallNowMs() > a.deadline_ms) {
                        k.sched.killTask(a.pid, 124);
                        k.services.markFailed(name, constants.ETIMEDOUT);
                        return .{ .errno = constants.ETIMEDOUT };
                    }
                    return .pending;
                }
                k.services.markFailed(name, constants.EIO);
                return .{ .errno = constants.EIO };
            },
            .failed => |f| {
                if (vfs.wallNowMs() < f.until_ms) return .{ .errno = f.last_errno };
            },
        }
    }
    if (state.activateServiceLazily(k, name)) return .pending;
    return .{ .errno = constants.ENOENT };
}

fn fulfillSvcServe(guest: *const Guest, memory: GuestMemory, args: mc.SvcServeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    const name = readGuestUtf8(memory, args.name_ptr, args.name_len) orelse return neg(constants.EINVAL);
    if (!registry.validServiceName(name)) return neg(constants.EINVAL);
    if (state.kernel().services.grantHolder(name) != t.id) return neg(constants.EPERM);
    if (state.kernel().services.serviceRegistered(name)) return neg(constants.EEXIST);
    const channel = registry.ServiceChannel.create(state.kernel().gpa);
    if (!state.kernel().services.registerService(name, channel)) return neg(constants.EEXIST);
    state.kernel().services.clearActivation(name);
    const owner = registry.SvcServeOwner.create(state.kernel().gpa, &state.kernel().services, name, channel);
    const fd = t.allocFd(state.kernel().gpa, .{ .svc_serve = owner });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

fn callerAlive(ctx: *anyopaque, caller: vfs.CallerId) bool {
    if (caller == vfs.SYSTEM_CALLER) return true;
    const k: *state.Kernel = @ptrCast(@alignCast(ctx));
    const t = k.sched.getTask(caller) orelse return false;
    return t.state != .zombie;
}

fn writeSvcEnvelope(
    memory: GuestMemory,
    buf: u32,
    ret_len: u32,
    hbuf: u32,
    kind: u8,
    session: u32,
    req_id: u32,
    caller: u32,
    caller_caps: u32,
    blob: []const u8,
    handle_bytes: []const u8,
) i32 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(state.kernel().gpa);
    out.append(state.kernel().gpa, kind) catch @panic("OOM");
    out.append(state.kernel().gpa, @intCast(handle_bytes.len / 4)) catch @panic("OOM");
    appendU32(&out, state.kernel().gpa, session);
    appendU32(&out, state.kernel().gpa, req_id);
    appendU32(&out, state.kernel().gpa, caller);
    appendU32(&out, state.kernel().gpa, caller_caps);
    appendU32(&out, state.kernel().gpa, @intCast(blob.len));
    out.appendSlice(state.kernel().gpa, blob) catch @panic("OOM");
    if (!writeGuestBytes(memory, buf, out.items)) return neg(constants.EINVAL);
    if (handle_bytes.len != 0 and !writeGuestBytes(memory, hbuf, handle_bytes)) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, ret_len, @intCast(out.items.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

fn installDelegated(t: *Task, dh: registry.DelegatedHandle) i32 {
    const fd = switch (dh) {
        .file => |fh| t.allocFd(state.kernel().gpa, .{ .file = fh }),
        .pipe_read => |p| t.allocFd(state.kernel().gpa, .{ .pipe_read = p }),
        .pipe_write => |p| t.allocFd(state.kernel().gpa, .{ .pipe_write = p }),
    };
    return @intCast(fd);
}

fn fulfillSvcRecv(guest: *const Guest, memory: GuestMemory, args: mc.SvcRecvArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_len, 4) orelse return finish(neg(constants.EINVAL));
    const channel = svcChannel(t, args.fd) orelse return finish(neg(constants.EBADF));
    channel.evictDeadSessions(@ptrCast(state.kernel()), callerAlive);
    channel.failOverdue();
    while (true) {
        var inbound = channel.takeRequest() orelse {
            if (channel.nextDrainReady()) |key| {
                if (registry.SVC_ENVELOPE_HEADER <= @as(usize, @intCast(args.buf_len)) and guestRange(memory, args.buf, @intCast(registry.SVC_ENVELOPE_HEADER)) != null) {
                    return finish(writeSvcEnvelope(memory, args.buf, args.ret_len, args.hbuf, registry.SVC_KIND_DRAIN_READY, key.session, key.req_id, vfs.SYSTEM_CALLER, 0, "", ""));
                }
            }
            return .{ .Block = .{ .svc_recv = channel } };
        };
        switch (inbound) {
            .session_closed => |session| {
                if (registry.SVC_ENVELOPE_HEADER > @as(usize, @intCast(args.buf_len)) or guestRange(memory, args.buf, @intCast(registry.SVC_ENVELOPE_HEADER)) == null) continue;
                return finish(writeSvcEnvelope(memory, args.buf, args.ret_len, args.hbuf, registry.SVC_KIND_SESSION_CLOSED, session, 0, vfs.SYSTEM_CALLER, 0, "", ""));
            },
            .call => |*req| {
                const nh = req.handles.len;
                const total = registry.SVC_ENVELOPE_HEADER + req.blob.len;
                if (total > @as(usize, @intCast(args.buf_len)) or
                    nh * 4 > @as(usize, @intCast(args.hbuf_len)) or
                    guestRange(memory, args.buf, @intCast(total)) == null or
                    (nh != 0 and guestRange(memory, args.hbuf, @intCast(nh * 4)) == null))
                {
                    _ = channel.respond(req.session, req.req_id, constants.EMSGSIZE, "", true);
                    req.deinit(state.kernel().gpa, true);
                    continue;
                }
                var handle_bytes: std.ArrayList(u8) = .empty;
                defer handle_bytes.deinit(state.kernel().gpa);
                for (req.handles) |dh| appendU32(&handle_bytes, state.kernel().gpa, @bitCast(installDelegated(t, dh)));
                channel.markDelivered(req.session, req.req_id);
                const code = writeSvcEnvelope(memory, args.buf, args.ret_len, args.hbuf, registry.SVC_KIND_CALL, req.session, req.req_id, req.caller, req.caller_caps, req.blob, handle_bytes.items);
                req.deinit(state.kernel().gpa, false);
                return finish(code);
            },
        }
    }
}

fn fulfillSvcRespond(guest: *const Guest, memory: GuestMemory, args: mc.SvcRespondArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const channel = svcChannel(t, args.fd) orelse return neg(constants.EBADF);
    const is_last = args.last != 0;
    if (channel.responseBuffered(args.session, args.req_id) >= registry.SVC_RESPONSE_HIGH_WATER) return neg(constants.EAGAIN);
    const data = guestRange(memory, args.data_ptr, args.data_len) orelse return neg(constants.EINVAL);
    const ok = if (is_last) channel.markAnswered(args.session, args.req_id) else channel.isInflight(args.session, args.req_id);
    if (!ok) return neg(constants.EINVAL);
    return switch (channel.respond(args.session, args.req_id, args.status, data, is_last)) {
        .session_gone => constants.ESUCCESS,
        .overflow => blk: {
            if (!is_last) _ = channel.markAnswered(args.session, args.req_id);
            break :blk neg(constants.EMSGSIZE);
        },
        .ok => constants.ESUCCESS,
    };
}

fn fulfillSvcConnect(guest: *const Guest, memory: GuestMemory, args: mc.SvcConnectArgs) Fulfillment {
    const t = currentTask(guest) orelse return finish(neg(constants.EIO));
    _ = guestRange(memory, args.ret_fd, 4) orelse return finish(neg(constants.EINVAL));
    const name = readGuestUtf8(memory, args.name_ptr, args.name_len) orelse return finish(neg(constants.EINVAL));
    if (!registry.validServiceName(name)) return finish(neg(constants.EINVAL));
    const channel = switch (serviceChannelForConnect(name)) {
        .ready => |ch| ch,
        .pending => return .Pending,
        .errno => |errno| return finish(neg(errno)),
    };
    const session = channel.openSession(t.id);
    const conn = registry.SvcConnHandle.create(state.kernel().gpa, channel, session);
    const fd = t.allocFd(state.kernel().gpa, .{ .svc_conn = conn });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return finish(neg(constants.EINVAL));
    }
    return finish(constants.ESUCCESS);
}

fn readHandleFdList(memory: GuestMemory, ptr: u32, nhandles: u32) ?[]const u8 {
    if (nhandles == 0) return &[_]u8{};
    return guestRange(memory, ptr, nhandles * 4);
}

fn delegateFd(t: *Task, fd: i32) ?registry.DelegatedHandle {
    const idx = fdIndex(fd) orelse return null;
    return switch (t.getFd(idx)) {
        .file => |fh| blk: {
            const retained = SharedFile.retain(fh) orelse break :blk null;
            break :blk .{ .file = retained };
        },
        .pipe_read => |p| blk: {
            p.addReader();
            break :blk .{ .pipe_read = p };
        },
        .pipe_write => |p| blk: {
            p.addWriter();
            break :blk .{ .pipe_write = p };
        },
        else => null,
    };
}

fn releaseDelegatedList(handles: []registry.DelegatedHandle) void {
    for (handles) |h| h.release();
}

fn fulfillSvcCall(guest: *const Guest, memory: GuestMemory, args: mc.SvcCallArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    _ = guestRange(memory, args.ret_fd, 4) orelse return neg(constants.EINVAL);
    const conn = svcConn(t, args.fd) orelse return neg(constants.EBADF);
    if (@as(usize, @intCast(args.req_len)) > registry.MAX_SVC_REQUEST_BYTES or @as(usize, @intCast(args.nhandles)) > registry.MAX_DELEGATED_HANDLES) return neg(constants.EINVAL);
    const blob = guestRange(memory, args.req_ptr, args.req_len) orelse return neg(constants.EINVAL);
    const raw_handles = readHandleFdList(memory, args.handles_ptr, args.nhandles) orelse return neg(constants.EINVAL);
    var handles: std.ArrayListUnmanaged(registry.DelegatedHandle) = .empty;
    defer handles.deinit(state.kernel().gpa);
    var i: usize = 0;
    while (i < @as(usize, @intCast(args.nhandles))) : (i += 1) {
        const hfd = readLeI32(raw_handles, i * 4);
        const dh = delegateFd(t, hfd) orelse {
            releaseDelegatedList(handles.items);
            return neg(constants.EINVAL);
        };
        handles.append(state.kernel().gpa, dh) catch @panic("OOM");
    }
    const req_id = conn.channel.enqueue(conn.session, t.id, t.caps.bits, blob, handles.items) orelse {
        releaseDelegatedList(handles.items);
        return neg(constants.EIO);
    };
    state.kernel().sched.checkUnblocked();
    const src = registry.SvcCallSource.create(state.kernel().gpa, conn.channel, conn.session, req_id);
    const fd = t.allocFd(state.kernel().gpa, .{ .svc_call = src });
    if (!writeGuestU32(memory, args.ret_fd, @intCast(fd))) {
        t.closeFd(fd);
        return neg(constants.EINVAL);
    }
    return constants.ESUCCESS;
}

pub fn fulfillOutcome(memory: GuestMemory, guest: *const Guest, pending: mc.Pending) Fulfillment {
    return switch (pending) {
        .Args => |args| finish(fulfillArgs(guest, memory, args)),
        .Write => |args| fulfillWrite(guest, memory, args),
        .Read => |args| fulfillRead(guest, memory, args),
        .Open => |args| fulfillOpen(guest, memory, args),
        .Close => |args| finish(fulfillClose(guest, args)),
        .Stat => |args| finish(fulfillStatLike(guest, memory, args.path_ptr, args.path_len, args.ret_stat, true)),
        .Readdir => |args| fulfillReaddir(guest, memory, args),
        .Mkdir => |args| finish(fulfillMkdir(guest, memory, args)),
        .Unlink => |args| finish(fulfillUnlink(guest, memory, args)),
        // TODO(Phase 6): namespace mutation and richer metadata operations.
        .Rename => |args| finish(fulfillRename(guest, memory, args)),
        .Symlink => |args| finish(fulfillSymlink(guest, memory, args)),
        .Link => |args| finish(fulfillLink(guest, memory, args)),
        .Readlink => |args| finish(fulfillReadlink(guest, memory, args)),
        .Lstat => |args| finish(fulfillStatLike(guest, memory, args.path_ptr, args.path_len, args.ret_stat, false)),
        .Chmod => |args| finish(fulfillChmod(guest, memory, args)),
        .Utimes => |args| finish(fulfillUtimes(guest, memory, args)),
        .Getcwd => |args| finish(fulfillGetcwd(guest, memory, args)),
        .Chdir => |args| finish(fulfillChdir(guest, memory, args)),
        .Lseek => |args| finish(fulfillLseek(guest, memory, args)),
        .Ftruncate => |args| finish(fulfillFtruncate(guest, args)),
        .Poll => |args| fulfillPoll(guest, memory, args),
        .Bind => |args| finish(fulfillBind(guest, memory, args)),
        .Unmount => |args| finish(fulfillUnmount(guest, memory, args)),
        .Serve => |args| finish(fulfillServe(guest, memory, args)),
        .ServeRecv => |args| fulfillServeRecv(guest, memory, args),
        .ServeRespond => |args| finish(fulfillServeRespond(guest, memory, args)),
        .SvcServe => |args| finish(fulfillSvcServe(guest, memory, args)),
        .SvcRecv => |args| fulfillSvcRecv(guest, memory, args),
        .SvcRespond => |args| finish(fulfillSvcRespond(guest, memory, args)),
        .SvcConnect => |args| fulfillSvcConnect(guest, memory, args),
        .SvcCall => |args| finish(fulfillSvcCall(guest, memory, args)),
        .Pipe => |args| finish(fulfillPipe(guest, memory, args)),
        .Dup => |args| finish(fulfillDup(guest, memory, args)),
        .Dup2 => |args| finish(fulfillDup2(guest, args)),
        .Isatty => |args| finish(fulfillIsatty(guest, memory, args)),
        .Getpid => |args| finish(fulfillGetpid(guest, memory, args)),
        .Getppid => |args| finish(fulfillGetppid(guest, memory, args)),
        .Spawn => |args| fulfillSpawn(guest, memory, args),
        .Waitpid => |args| fulfillWaitpid(guest, memory, args),
        .Nice => |args| fulfillNice(guest, memory, args),
        .Kill => |args| fulfillKill(guest, args),
        .Sigdisp => |args| fulfillSigdisp(guest, args),
        .Setpgid => |args| fulfillSetpgid(guest, args),
        .Tcsetpgrp => |args| fulfillTcsetpgrp(guest, args),
        .HttpGet => |args| finish(fulfillHttpGet(guest, memory, args)),
        .HttpRequest => |args| finish(fulfillHttpRequest(guest, memory, args)),
        .HttpStatus => |args| fulfillHttpStatus(guest, memory, args),
        .WsOpen => |args| finish(fulfillWsOpen(guest, memory, args)),
        .HostCall => |args| finish(fulfillHostCall(guest, memory, args)),
        .TimeMonotonic => |args| finish(fulfillTimeMonotonic(guest, memory, args)),
        .TimeRealtime => |args| finish(fulfillTimeRealtime(guest, memory, args)),
        .SleepMs => |args| fulfillSleepMs(guest, args),
        .Random => |args| finish(fulfillRandom(guest, memory, args)),
        .AbiVersion => |args| finish(fulfillAbiVersion(memory, args)),
        .Exit => |args| .{ .Exit = args.code },
        // Pcall/SetThrow are intercepted in the WAMR native bridge (guest.zig rawPcall/rawSetThrow),
        // which runs the nested call and records the throw before a Pending is ever built — so these
        // arms are unreachable in practice. They remain for switch exhaustiveness (mc.Pending has no
        // `else`), failing closed with ENOSYS should the interception ever be bypassed.
        .Pcall, .SetThrow => finish(neg(constants.ENOSYS)),
    };
}

pub fn fulfill(memory: GuestMemory, guest: *const Guest, pending: mc.Pending) i32 {
    return switch (fulfillOutcome(memory, guest, pending)) {
        .Resume => |code| code,
        .Exit => |code| code,
        .Block, .Pending => neg(constants.EAGAIN),
    };
}
