//! Zig guest sysroot runtime over the generated `mc` syscall ABI.
//!
//! `mc` is intentionally raw/generated: every syscall import plus `addr`.
//! This module is the reusable guest-facing layer, equivalent in role to
//! //memcontainers/sysroot/rust/src/sys.rs. It preserves raw errno values from
//! the generated constants instead of collapsing them into a lossy Zig error set.

const std = @import("std");
pub const mc = @import("mc");
pub const constants = @import("constants_zig");

pub const Fd = i32;
pub const Pid = u32;
pub const Errno = i32;

pub const STDIN: Fd = 0;
pub const STDOUT: Fd = 1;
pub const STDERR: Fd = 2;

pub const ESUCCESS = constants.ESUCCESS;
pub const EACCES = constants.EACCES;
pub const EAGAIN = constants.EAGAIN;
pub const EBADF = constants.EBADF;
pub const ECHILD = constants.ECHILD;
pub const EEXIST = constants.EEXIST;
pub const EINTR = constants.EINTR;
pub const EINVAL = constants.EINVAL;
pub const EIO = constants.EIO;
pub const EISDIR = constants.EISDIR;
pub const ELOOP = constants.ELOOP;
pub const EMFILE = constants.EMFILE;
pub const ENOENT = constants.ENOENT;
pub const ENOSYS = constants.ENOSYS;
pub const EMSGSIZE = constants.EMSGSIZE;
pub const ENOTDIR = constants.ENOTDIR;
pub const ENOTEMPTY = constants.ENOTEMPTY;
pub const EPERM = constants.EPERM;
pub const EPIPE = constants.EPIPE;
pub const ESRCH = constants.ESRCH;
pub const ETIMEDOUT = constants.ETIMEDOUT;
pub const EXDEV = constants.EXDEV;

pub const TIER_INHERIT = constants.TIER_INHERIT;
pub const TIER_FULL = constants.TIER_FULL;
pub const TIER_READ_WRITE = constants.TIER_READ_WRITE;
pub const TIER_READ_ONLY = constants.TIER_READ_ONLY;
pub const TIER_ISOLATED = constants.TIER_ISOLATED;

pub const O_READ = constants.O_READ;
pub const O_WRITE = constants.O_WRITE;
pub const O_CREATE = constants.O_CREATE;
pub const O_TRUNC = constants.O_TRUNC;
pub const O_APPEND = constants.O_APPEND;

pub const WNOHANG = constants.WNOHANG;

pub const SIGHUP = constants.SIGHUP;
pub const SIGINT = constants.SIGINT;
pub const SIGKILL = constants.SIGKILL;
pub const SIGTERM = constants.SIGTERM;
pub const SIGCHLD = constants.SIGCHLD;
pub const SIGCONT = constants.SIGCONT;
pub const SIGTSTP = constants.SIGTSTP;
pub const SIG_DFL = constants.SIG_DFL;
pub const SIG_IGN = constants.SIG_IGN;
pub const STOPPED_STATUS = constants.STOPPED_STATUS_BASE;

pub const wasm_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &std.heap.WasmAllocator.vtable,
};

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Errno,
    };
}

pub const Status = union(enum) {
    ok,
    err: Errno,
};

pub const Stat = struct {
    size: u64,
    is_dir: bool,
    is_symlink: bool,
    nlink: u32,
    mode: u16,
    mtime: i64,
    atime: i64,
    ctime: i64,

    pub fn readable(self: Stat) bool {
        return self.mode & 0o400 != 0;
    }

    pub fn writable(self: Stat) bool {
        return self.mode & 0o200 != 0;
    }

    pub fn executable(self: Stat) bool {
        return self.mode & 0o100 != 0;
    }
};

pub const WaitStatus = struct {
    status: i32,
    pid: Pid,
};

fn status(errno: Errno) Status {
    return if (errno == ESUCCESS) .ok else .{ .err = errno };
}

fn result(comptime T: type, errno: Errno, value: T) Result(T) {
    return if (errno == ESUCCESS) .{ .ok = value } else .{ .err = errno };
}

fn allocErr() Result([]const u8) {
    return .{ .err = EIO };
}

pub fn pipe() Result(struct { Fd, Fd }) {
    var r: u32 = 0;
    var w: u32 = 0;
    const errno = mc.mc_sys_pipe(mc.addr(&r), mc.addr(&w));
    return result(struct { Fd, Fd }, errno, .{ @intCast(r), @intCast(w) });
}

pub fn dup(fd: Fd) Result(Fd) {
    var out: u32 = 0;
    const errno = mc.mc_sys_dup(fd, mc.addr(&out));
    return result(Fd, errno, @intCast(out));
}

pub fn dup2(old_fd: Fd, new_fd: Fd) Status {
    return status(mc.mc_sys_dup2(old_fd, new_fd));
}

pub fn close(fd: Fd) void {
    _ = mc.mc_sys_close(fd);
}

pub fn getpid() Pid {
    var pid: u32 = 0;
    _ = mc.mc_sys_getpid(mc.addr(&pid));
    return pid;
}

pub fn getppid() Pid {
    var pid: u32 = 0;
    _ = mc.mc_sys_getppid(mc.addr(&pid));
    return pid;
}

pub fn spawn(argv_blob: []const u8, in_fd: Fd, out_fd: Fd, err_fd: Fd) Result(Pid) {
    return spawnTiered(argv_blob, in_fd, out_fd, err_fd, TIER_INHERIT);
}

pub fn spawnTiered(argv_blob: []const u8, in_fd: Fd, out_fd: Fd, err_fd: Fd, tier: i32) Result(Pid) {
    var pid: u32 = 0;
    const errno = mc.mc_sys_spawn(mc.addr(argv_blob.ptr), @intCast(argv_blob.len), in_fd, out_fd, err_fd, tier, mc.addr(&pid));
    return result(Pid, errno, pid);
}

pub fn waitpid(pid: i32) Result(i32) {
    return switch (waitpidOpts(pid, 0)) {
        .ok => |ws| .{ .ok = ws.status },
        .err => |errno| .{ .err = errno },
    };
}

pub fn waitpidNoHang(pid: i32) Result(?WaitStatus) {
    return switch (waitpidOpts(pid, WNOHANG)) {
        .ok => |ws| if (ws.pid == 0) .{ .ok = null } else .{ .ok = ws },
        .err => |errno| .{ .err = errno },
    };
}

pub fn waitpidOpts(pid: i32, opts: i32) Result(WaitStatus) {
    var st: u32 = 0;
    var got: u32 = 0;
    const errno = mc.mc_sys_waitpid(pid, opts, mc.addr(&st), mc.addr(&got));
    return result(WaitStatus, errno, .{ .status = @bitCast(st), .pid = got });
}

pub fn open(path: []const u8, flags: i32) Result(Fd) {
    var fd: u32 = 0;
    const errno = mc.mc_sys_open(mc.addr(path.ptr), @intCast(path.len), flags, mc.addr(&fd));
    return result(Fd, errno, @intCast(fd));
}

pub fn read(fd: Fd, buf: []u8) Result(usize) {
    if (buf.len == 0) return .{ .ok = 0 };
    var n: u32 = 0;
    const errno = mc.mc_sys_read(fd, mc.addr(buf.ptr), @intCast(buf.len), mc.addr(&n));
    return result(usize, errno, @intCast(n));
}

pub fn write(fd: Fd, bytes: []const u8) Result(usize) {
    if (bytes.len == 0) return .{ .ok = 0 };
    var n: u32 = 0;
    const errno = mc.mc_sys_write(fd, mc.addr(bytes.ptr), @intCast(bytes.len), mc.addr(&n));
    return result(usize, errno, @intCast(n));
}

pub fn writeAll(fd: Fd, bytes: []const u8) Status {
    var off: usize = 0;
    while (off < bytes.len) {
        switch (write(fd, bytes[off..])) {
            .ok => |n| {
                if (n == 0) return .{ .err = EIO };
                off += n;
            },
            .err => |errno| return .{ .err = errno },
        }
    }
    return .ok;
}

pub fn print(bytes: []const u8) void {
    _ = writeAll(STDOUT, bytes);
}

pub fn eprint(bytes: []const u8) void {
    _ = writeAll(STDERR, bytes);
}

pub fn mkdir(path: []const u8) Status {
    return status(mc.mc_sys_mkdir(mc.addr(path.ptr), @intCast(path.len)));
}

pub fn unlink(path: []const u8) Status {
    return status(mc.mc_sys_unlink(mc.addr(path.ptr), @intCast(path.len)));
}

pub fn chdir(path: []const u8) Status {
    return status(mc.mc_sys_chdir(mc.addr(path.ptr), @intCast(path.len)));
}

pub fn bind(old: []const u8, new: []const u8) Status {
    return status(mc.mc_sys_bind(mc.addr(old.ptr), @intCast(old.len), mc.addr(new.ptr), @intCast(new.len)));
}

pub fn unmount(path: []const u8) Status {
    return status(mc.mc_sys_unmount(mc.addr(path.ptr), @intCast(path.len)));
}

const STAT_LEN: usize = @intCast(constants.STAT_REC_LEN);
const STAT_SIZE_OFF: usize = @intCast(constants.STAT_REC_SIZE_OFF);
const STAT_NODE_TYPE_OFF: usize = @intCast(constants.STAT_REC_NODE_TYPE_OFF);
const STAT_NLINK_OFF: usize = @intCast(constants.STAT_REC_NLINK_OFF);
const STAT_MODE_OFF: usize = @intCast(constants.STAT_REC_MODE_OFF);
const STAT_MTIME_OFF: usize = @intCast(constants.STAT_REC_MTIME_OFF);
const STAT_ATIME_OFF: usize = @intCast(constants.STAT_REC_ATIME_OFF);
const STAT_CTIME_OFF: usize = @intCast(constants.STAT_REC_CTIME_OFF);
const STAT_NODE_DIR: u32 = @intCast(constants.STAT_NODE_DIR);
const STAT_NODE_SYMLINK: u32 = @intCast(constants.STAT_NODE_SYMLINK);

fn parseStat(buf: *const [STAT_LEN]u8) Stat {
    const kind = std.mem.readInt(u32, buf[STAT_NODE_TYPE_OFF..][0..4], .little);
    return .{
        .size = std.mem.readInt(u64, buf[STAT_SIZE_OFF..][0..8], .little),
        .is_dir = kind == STAT_NODE_DIR,
        .is_symlink = kind == STAT_NODE_SYMLINK,
        .nlink = std.mem.readInt(u32, buf[STAT_NLINK_OFF..][0..4], .little),
        .mode = @intCast(std.mem.readInt(u32, buf[STAT_MODE_OFF..][0..4], .little)),
        .mtime = std.mem.readInt(i64, buf[STAT_MTIME_OFF..][0..8], .little),
        .atime = std.mem.readInt(i64, buf[STAT_ATIME_OFF..][0..8], .little),
        .ctime = std.mem.readInt(i64, buf[STAT_CTIME_OFF..][0..8], .little),
    };
}

pub fn stat(path: []const u8) Result(Stat) {
    var buf: [STAT_LEN]u8 = undefined;
    const errno = mc.mc_sys_stat(mc.addr(path.ptr), @intCast(path.len), mc.addr(&buf));
    return result(Stat, errno, parseStat(&buf));
}

pub fn lstat(path: []const u8) Result(Stat) {
    var buf: [STAT_LEN]u8 = undefined;
    const errno = mc.mc_sys_lstat(mc.addr(path.ptr), @intCast(path.len), mc.addr(&buf));
    return result(Stat, errno, parseStat(&buf));
}

pub fn readdirInto(path: []const u8, buf: []u8) Result(usize) {
    var total: u32 = 0;
    const errno = mc.mc_sys_readdir(mc.addr(path.ptr), @intCast(path.len), mc.addr(buf.ptr), @intCast(buf.len), mc.addr(&total));
    const n: usize = @min(@as(usize, @intCast(total)), buf.len);
    return result(usize, errno, n);
}

pub fn readdirAlloc(allocator: std.mem.Allocator, path: []const u8) Result([]const []const u8) {
    var cap: usize = 1024;
    while (true) {
        const buf = allocator.alloc(u8, cap) catch return .{ .err = EIO };
        var total: u32 = 0;
        const errno = mc.mc_sys_readdir(mc.addr(path.ptr), @intCast(path.len), mc.addr(buf.ptr), @intCast(buf.len), mc.addr(&total));
        if (errno != ESUCCESS) {
            allocator.free(buf);
            return .{ .err = errno };
        }
        const needed: usize = @intCast(total);
        if (needed > cap) {
            allocator.free(buf);
            cap = needed;
            continue;
        }
        var out = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, buf[0..needed], 0);
        while (it.next()) |name| {
            if (name.len == 0) continue;
            const owned = allocator.dupe(u8, name) catch {
                freePendingStringList(allocator, &out);
                allocator.free(buf);
                return .{ .err = EIO };
            };
            out.append(allocator, owned) catch {
                allocator.free(owned);
                freePendingStringList(allocator, &out);
                allocator.free(buf);
                return .{ .err = EIO };
            };
        }
        allocator.free(buf);
        return .{ .ok = out.toOwnedSlice(allocator) catch {
            freePendingStringList(allocator, &out);
            return .{ .err = EIO };
        } };
    }
}

pub fn getcwdInto(buf: []u8) Result(usize) {
    var total: u32 = 0;
    const errno = mc.mc_sys_getcwd(mc.addr(buf.ptr), @intCast(buf.len), mc.addr(&total));
    const n: usize = @min(@as(usize, @intCast(total)), buf.len);
    return result(usize, errno, n);
}

pub fn getcwdAlloc(allocator: std.mem.Allocator) Result([]const u8) {
    var cap: usize = 256;
    while (true) {
        const buf = allocator.alloc(u8, cap) catch return allocErr();
        switch (getcwdInto(buf)) {
            .ok => |n| {
                const out = allocator.dupe(u8, buf[0..n]) catch {
                    allocator.free(buf);
                    return allocErr();
                };
                allocator.free(buf);
                return .{ .ok = out };
            },
            .err => |errno| {
                allocator.free(buf);
                if (errno != EINVAL) return .{ .err = errno };
                cap *= 2;
            },
        }
    }
}

pub fn readAllAlloc(allocator: std.mem.Allocator, fd: Fd) Result([]const u8) {
    var out = std.ArrayList(u8).empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        switch (read(fd, &buf)) {
            .ok => |n| {
                if (n == 0) return .{ .ok = out.toOwnedSlice(allocator) catch {
                    out.deinit(allocator);
                    return allocErr();
                } };
                out.appendSlice(allocator, buf[0..n]) catch {
                    out.deinit(allocator);
                    return allocErr();
                };
            },
            .err => |errno| {
                out.deinit(allocator);
                return .{ .err = errno };
            },
        }
    }
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) Result([]const u8) {
    const fd = switch (open(path, O_READ)) {
        .ok => |f| f,
        .err => |errno| return .{ .err = errno },
    };
    defer close(fd);
    return readAllAlloc(allocator, fd);
}

pub fn argsInto(buf: []u8) usize {
    var total: u32 = 0;
    _ = mc.mc_sys_args(mc.addr(buf.ptr), @intCast(buf.len), mc.addr(&total));
    return @min(@as(usize, @intCast(total)), buf.len);
}

pub fn argsAlloc(allocator: std.mem.Allocator) Result([]const []const u8) {
    var cap: usize = 4096;
    while (true) {
        const buf = allocator.alloc(u8, cap) catch return .{ .err = EIO };
        var total: u32 = 0;
        const errno = mc.mc_sys_args(mc.addr(buf.ptr), @intCast(buf.len), mc.addr(&total));
        if (errno != ESUCCESS) {
            allocator.free(buf);
            return .{ .err = errno };
        }
        const needed: usize = @intCast(total);
        if (needed > cap) {
            allocator.free(buf);
            cap = needed;
            continue;
        }
        var out = std.ArrayList([]const u8).empty;
        var start: usize = 0;
        for (buf[0..needed], 0..) |b, i| {
            if (b != 0) continue;
            const owned = allocator.dupe(u8, buf[start..i]) catch {
                freePendingStringList(allocator, &out);
                allocator.free(buf);
                return .{ .err = EIO };
            };
            out.append(allocator, owned) catch {
                allocator.free(owned);
                freePendingStringList(allocator, &out);
                allocator.free(buf);
                return .{ .err = EIO };
            };
            start = i + 1;
        }
        if (start < needed) {
            const owned = allocator.dupe(u8, buf[start..needed]) catch {
                freePendingStringList(allocator, &out);
                allocator.free(buf);
                return .{ .err = EIO };
            };
            out.append(allocator, owned) catch {
                allocator.free(owned);
                freePendingStringList(allocator, &out);
                allocator.free(buf);
                return .{ .err = EIO };
            };
        }
        allocator.free(buf);
        return .{ .ok = out.toOwnedSlice(allocator) catch {
            freePendingStringList(allocator, &out);
            return .{ .err = EIO };
        } };
    }
}

fn freePendingStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

pub fn freeStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    if (items.len != 0) allocator.free(items);
}

fn envPath(allocator: std.mem.Allocator, name: []const u8) Result([]const u8) {
    return .{ .ok = std.fmt.allocPrint(allocator, "/env/{s}", .{name}) catch return allocErr() };
}

pub fn getenv(allocator: std.mem.Allocator, name: []const u8) Result(?[]const u8) {
    const path = switch (envPath(allocator, name)) {
        .ok => |p| p,
        .err => |errno| return .{ .err = errno },
    };
    defer allocator.free(path);
    return switch (readFileAlloc(allocator, path)) {
        .ok => |value| .{ .ok = value },
        .err => .{ .ok = null },
    };
}

pub fn setenv(allocator: std.mem.Allocator, name: []const u8, value: []const u8) Status {
    const path = switch (envPath(allocator, name)) {
        .ok => |p| p,
        .err => |errno| return .{ .err = errno },
    };
    defer allocator.free(path);
    const fd = switch (open(path, O_WRITE | O_CREATE | O_TRUNC)) {
        .ok => |f| f,
        .err => |errno| return .{ .err = errno },
    };
    defer close(fd);
    return writeAll(fd, value);
}

pub fn unsetenv(allocator: std.mem.Allocator, name: []const u8) Status {
    const path = switch (envPath(allocator, name)) {
        .ok => |p| p,
        .err => |errno| return .{ .err = errno },
    };
    defer allocator.free(path);
    return unlink(path);
}

pub fn environ(allocator: std.mem.Allocator) Result([]const []const u8) {
    return readdirAlloc(allocator, "/env");
}

pub fn kill(pid: i32, sig: i32) Status {
    return status(mc.mc_sys_kill(pid, sig));
}

pub fn sigdisp(sig: i32, disp: i32) Status {
    return status(mc.mc_sys_sigdisp(sig, disp));
}

pub fn setpgid(pid: i32, pgid: i32) Status {
    return status(mc.mc_sys_setpgid(pid, pgid));
}

pub fn tcsetpgrp(pgid: i32) Status {
    return status(mc.mc_sys_tcsetpgrp(pgid));
}

pub fn isatty(fd: Fd) bool {
    var ret: u32 = 0;
    if (mc.mc_sys_isatty(fd, mc.addr(&ret)) != ESUCCESS) return false;
    return ret != 0;
}

pub fn strerror(errno: Errno) []const u8 {
    return switch (errno) {
        ENOENT => "No such file or directory",
        EEXIST => "File exists",
        ENOTDIR => "Not a directory",
        EISDIR => "Is a directory",
        EPERM, EACCES => "Permission denied",
        EINVAL => "Invalid argument",
        ENOTEMPTY => "Directory not empty",
        EIO => "I/O error",
        EBADF => "Bad file descriptor",
        ENOSYS => "Not implemented",
        EMFILE => "Too many open files",
        ELOOP => "Too many levels of symbolic links",
        EINTR => "Interrupted",
        EPIPE => "Broken pipe",
        ESRCH => "No such process",
        ETIMEDOUT => "Timed out",
        EXDEV => "Cross-device link",
        else => "error",
    };
}

pub fn exit(code: i32) noreturn {
    _ = mc.mc_sys_exit(code);
    while (true) {}
}
