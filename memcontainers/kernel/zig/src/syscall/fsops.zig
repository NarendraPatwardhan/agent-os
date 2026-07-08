//! fsops.zig - filesystem, metadata, and fd syscall fulfillment.
//!
//! Owns: guest path resolution, open flags, terminal output conversion, file
//!   syscalls, metadata syscalls, and descriptor-number syscalls.
//! Invariants: guest paths are canonicalized and capability-checked before VFS
//!   access, and terminal ONLCR conversion applies only to host terminal writes.
//! Consumes: shared memory codecs, fd ownership wrappers, the bridge terminal,
//!   scheduler state, and the VFS namespace.
//! Not here: process creation, network egress, mount serving, or services.

const std = @import("std");
const bridge = @import("../bridge.zig");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("../state.zig");
const task_mod = @import("../task.zig");
const vfs = @import("../vfs.zig");
const mem = @import("mem.zig");
const fd_mod = @import("fd.zig");

const Task = task_mod.Task;
const Guest = mem.Guest;
const GuestMemory = mem.GuestMemory;
const Fulfillment = mem.Fulfillment;
const finish = mem.finish;
const neg = mem.neg;
const errnoFromFs = mem.errnoFromFs;
const guestRange = mem.guestRange;
const writeGuestBytes = mem.writeGuestBytes;
const writeGuestU32 = mem.writeGuestU32;
const writeGuestI64 = mem.writeGuestI64;
const readGuestI64 = mem.readGuestI64;
const readLeI32 = mem.readLeI32;
const readLeI16 = mem.readLeI16;
const writeLeI16 = mem.writeLeI16;
const writeLeU32 = mem.writeLeU32;
const writeLeU64 = mem.writeLeU64;
const writeLeI64 = mem.writeLeI64;
const currentTask = mem.currentTask;
const fdIndex = mem.fdIndex;
const fsErr = mem.fsErr;
const SharedFile = fd_mod.SharedFile;
const cloneFd = fd_mod.cloneFd;

const STAT_RECORD_LEN: usize = @intCast(constants.STAT_REC_LEN);
const PERSIST_ROOT = "/var/persist";

pub fn pathWithin(root: ?[]const u8, path: []const u8) bool {
    const r = root orelse return true;
    if (std.mem.eql(u8, r, "/")) return true;
    if (std.mem.eql(u8, path, r)) return true;
    return std.mem.startsWith(u8, path, r) and path.len > r.len and path[r.len] == '/';
}

const absolutize = vfs.absolutize;

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

pub fn fulfillWrite(guest: *const Guest, memory: GuestMemory, args: mc.WriteArgs) Fulfillment {
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

pub fn fulfillRead(guest: *const Guest, memory: GuestMemory, args: mc.ReadArgs) Fulfillment {
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

pub fn fulfillOpen(guest: *const Guest, memory: GuestMemory, args: mc.OpenArgs) Fulfillment {
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

pub fn fulfillClose(guest: *const Guest, args: mc.CloseArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const idx = fdIndex(args.fd) orelse return neg(constants.EBADF);
    if (idx >= t.fds.items.len) return neg(constants.EBADF);
    if (idx >= 3 and t.getFd(idx) == .none) return neg(constants.EBADF);
    t.closeFd(idx);
    state.kernel().sched.checkUnblocked();
    return constants.ESUCCESS;
}

pub fn fulfillPipe(guest: *const Guest, memory: GuestMemory, args: mc.PipeArgs) i32 {
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

pub fn fulfillDup(guest: *const Guest, memory: GuestMemory, args: mc.DupArgs) i32 {
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

pub fn fulfillDup2(guest: *const Guest, args: mc.Dup2Args) i32 {
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

pub fn fulfillStatLike(guest: *const Guest, memory: GuestMemory, path_ptr: u32, path_len: u32, ret_stat: u32, follow: bool) i32 {
    _ = guestRange(memory, ret_stat, @intCast(STAT_RECORD_LEN)) orelse return neg(constants.EINVAL);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, path_ptr, path_len, false, follow, &errno) orelse return neg(errno);
    const md = state.kernel().ns.statPath(arena, path) catch |e| return fsErr(e);
    return writeStat(memory, ret_stat, md);
}

pub fn fulfillReadlink(guest: *const Guest, memory: GuestMemory, args: mc.ReadlinkArgs) i32 {
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

pub fn fulfillReaddir(guest: *const Guest, memory: GuestMemory, args: mc.ReaddirArgs) Fulfillment {
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
        // Fail closed rather than trapping the VM on heap exhaustion while serialising a
        // (guest-influenced) directory listing (§4.3 — guest fault is an errno, not a host trap).
        blob.appendSlice(arena, entry.name) catch return finish(neg(constants.EMSGSIZE));
        blob.append(arena, 0) catch return finish(neg(constants.EMSGSIZE));
    }
    const n = @min(blob.items.len, @as(usize, @intCast(args.buf_len)));
    if (guestRange(memory, args.buf, @intCast(n)) == null) return finish(neg(constants.EINVAL));
    if (n != 0 and !writeGuestBytes(memory, args.buf, blob.items[0..n])) return finish(neg(constants.EINVAL));
    if (!writeGuestU32(memory, args.ret_len, @intCast(blob.items.len))) return finish(neg(constants.EINVAL));
    return finish(constants.ESUCCESS);
}

pub fn fulfillMkdir(guest: *const Guest, memory: GuestMemory, args: mc.MkdirArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.mkdir(arena, t.id, path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

pub fn fulfillUnlink(guest: *const Guest, memory: GuestMemory, args: mc.UnlinkArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.unlink(arena, t.id, path) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

pub fn fulfillRename(guest: *const Guest, memory: GuestMemory, args: mc.RenameArgs) i32 {
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

pub fn fulfillSymlink(guest: *const Guest, memory: GuestMemory, args: mc.SymlinkArgs) i32 {
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

pub fn fulfillLink(guest: *const Guest, memory: GuestMemory, args: mc.LinkArgs) i32 {
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const existing = resolveGuestPath(guest, memory, arena, args.old_ptr, args.old_len, false, false, &errno) orelse return neg(errno);
    const new = resolveGuestPath(guest, memory, arena, args.new_ptr, args.new_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.link(arena, existing, new) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

pub fn fulfillChmod(guest: *const Guest, memory: GuestMemory, args: mc.ChmodArgs) i32 {
    var arena_state = std.heap.ArenaAllocator.init(state.kernel().gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var errno: i32 = 0;
    const path = resolveGuestPath(guest, memory, arena, args.path_ptr, args.path_len, true, false, &errno) orelse return neg(errno);
    state.kernel().ns.setMode(arena, path, @intCast(args.mode & 0o7777)) catch |e| return fsErr(e);
    return constants.ESUCCESS;
}

pub fn fulfillUtimes(guest: *const Guest, memory: GuestMemory, args: mc.UtimesArgs) i32 {
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

pub fn fulfillGetcwd(guest: *const Guest, memory: GuestMemory, args: mc.GetcwdArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (t.cwd.len > std.math.maxInt(u32)) return neg(constants.EINVAL);
    _ = guestRange(memory, args.ret_len, 4) orelse return neg(constants.EINVAL);
    if (t.cwd.len > @as(usize, @intCast(args.buf_len))) return neg(constants.EINVAL);
    if (guestRange(memory, args.buf, @intCast(t.cwd.len)) == null) return neg(constants.EINVAL);
    if (t.cwd.len != 0 and !writeGuestBytes(memory, args.buf, t.cwd)) return neg(constants.EINVAL);
    if (!writeGuestU32(memory, args.ret_len, @intCast(t.cwd.len))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

pub fn fulfillChdir(guest: *const Guest, memory: GuestMemory, args: mc.ChdirArgs) i32 {
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

pub fn fulfillLseek(guest: *const Guest, memory: GuestMemory, args: mc.LseekArgs) i32 {
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

pub fn fulfillFtruncate(guest: *const Guest, args: mc.FtruncateArgs) i32 {
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

pub fn fulfillPoll(guest: *const Guest, memory: GuestMemory, args: mc.PollArgs) Fulfillment {
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

pub fn fulfillIsatty(guest: *const Guest, memory: GuestMemory, args: mc.IsattyArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    const tty: u32 = if (args.fd >= 0 and args.fd <= 2 and t.getFd(@intCast(args.fd)) == .none) 1 else 0;
    if (!writeGuestU32(memory, args.ret, tty)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}
