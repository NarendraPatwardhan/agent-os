//! The Zig shell core's only boundary to the outside world.
//!
//! The rescue shell will bind this to kernel internals. A Zig /bin/sh guest will
//! bind it to sysroot/zig mc syscalls. Every operation is synchronous; the
//! kernel remains responsible for turning blocking guest syscalls into
//! cooperative suspension.

const std = @import("std");
const constants = @import("constants_zig");

pub const Fd = i32;
pub const Pid = u32;

pub const ShellError = error{
    AccessDenied,
    BadFileDescriptor,
    InvalidArgument,
    Io,
    NotDir,
    NotFound,
    NotImplemented,
    PermissionDenied,
    TooManyFiles,
    Unsupported,
};

pub const FileStat = struct {
    is_dir: bool,
    size: u64,
    mode: u16,
    mtime: i64,

    pub fn readable(self: FileStat) bool {
        return self.mode & 0o400 != 0;
    }

    pub fn writable(self: FileStat) bool {
        return self.mode & 0o200 != 0;
    }

    pub fn executable(self: FileStat) bool {
        return self.mode & 0o100 != 0;
    }
};

pub const Signal = enum(i32) {
    hup = constants.SIGHUP,
    int = constants.SIGINT,
    kill = constants.SIGKILL,
    term = constants.SIGTERM,
    cont = constants.SIGCONT,
    tstp = constants.SIGTSTP,
    chld = constants.SIGCHLD,
};

pub const SigDisp = enum(i32) {
    default_action = constants.SIG_DFL,
    ignore = constants.SIG_IGN,
};

pub const WaitStatus = struct {
    pid: Pid,
    status: i32,
};

pub const STDIN: Fd = 0;
pub const STDOUT: Fd = 1;
pub const STDERR: Fd = 2;

pub const TIER_INHERIT = constants.TIER_INHERIT;
pub const STOPPED_STATUS = constants.STOPPED_STATUS_BASE;

pub const O_READ = constants.O_READ;
pub const O_WRITE = constants.O_WRITE;
pub const O_CREATE = constants.O_CREATE;
pub const O_TRUNC = constants.O_TRUNC;
pub const O_APPEND = constants.O_APPEND;

pub const ShellOs = struct {
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    vtable: *const VTable,

    pub const VTable = struct {
        spawn: *const fn (*anyopaque, []const []const u8, Fd, Fd, Fd, i32) ShellError!Pid,
        waitpid: *const fn (*anyopaque, Pid) ShellError!i32,
        try_wait_any: *const fn (*anyopaque) ShellError!?WaitStatus,
        getpid: *const fn (*anyopaque) Pid,
        pipe: *const fn (*anyopaque) ShellError!struct { Fd, Fd },
        dup: *const fn (*anyopaque, Fd) ShellError!Fd,
        dup2: *const fn (*anyopaque, Fd, Fd) ShellError!void,
        close: *const fn (*anyopaque, Fd) void,
        open: *const fn (*anyopaque, []const u8, i32) ShellError!Fd,
        read: *const fn (*anyopaque, Fd, []u8) ShellError!usize,
        write_all: *const fn (*anyopaque, Fd, []const u8) ShellError!void,
        readdir: *const fn (*anyopaque, std.mem.Allocator, []const u8) ShellError![]const []const u8,
        stat: *const fn (*anyopaque, []const u8) ShellError!FileStat,
        mkdir: *const fn (*anyopaque, []const u8) ShellError!void,
        unlink: *const fn (*anyopaque, []const u8) ShellError!void,
        getcwd: *const fn (*anyopaque, std.mem.Allocator) ShellError![]const u8,
        chdir: *const fn (*anyopaque, []const u8) ShellError!void,
        bind: *const fn (*anyopaque, []const u8, []const u8) ShellError!void,
        unmount: *const fn (*anyopaque, []const u8) ShellError!void,
        getenv: *const fn (*anyopaque, std.mem.Allocator, []const u8) ShellError!?[]const u8,
        setenv: *const fn (*anyopaque, []const u8, []const u8) ShellError!void,
        unsetenv: *const fn (*anyopaque, []const u8) ShellError!void,
        environ: *const fn (*anyopaque, std.mem.Allocator) ShellError![]const []const u8,
        kill: *const fn (*anyopaque, i32, Signal) ShellError!void,
        set_sigdisp: *const fn (*anyopaque, Signal, SigDisp) void,
        setpgid: *const fn (*anyopaque, Pid, Pid) ShellError!void,
        set_foreground_pgid: *const fn (*anyopaque, Pid) ShellError!void,
        isatty: *const fn (*anyopaque, Fd) bool,
    };

    pub fn spawn(self: *ShellOs, argv: []const []const u8, in_fd: Fd, out_fd: Fd, err_fd: Fd, tier: i32) ShellError!Pid {
        return self.vtable.spawn(self.ptr, argv, in_fd, out_fd, err_fd, tier);
    }

    pub fn waitpid(self: *ShellOs, pid: Pid) ShellError!i32 {
        return self.vtable.waitpid(self.ptr, pid);
    }

    pub fn tryWaitAny(self: *ShellOs) ShellError!?WaitStatus {
        return self.vtable.try_wait_any(self.ptr);
    }

    pub fn getpid(self: *ShellOs) Pid {
        return self.vtable.getpid(self.ptr);
    }

    pub fn pipe(self: *ShellOs) ShellError!struct { Fd, Fd } {
        return self.vtable.pipe(self.ptr);
    }

    pub fn dup(self: *ShellOs, fd: Fd) ShellError!Fd {
        return self.vtable.dup(self.ptr, fd);
    }

    pub fn dup2(self: *ShellOs, old: Fd, new: Fd) ShellError!void {
        return self.vtable.dup2(self.ptr, old, new);
    }

    pub fn close(self: *ShellOs, fd: Fd) void {
        self.vtable.close(self.ptr, fd);
    }

    pub fn open(self: *ShellOs, path: []const u8, flags: i32) ShellError!Fd {
        return self.vtable.open(self.ptr, path, flags);
    }

    pub fn read(self: *ShellOs, fd: Fd, buf: []u8) ShellError!usize {
        return self.vtable.read(self.ptr, fd, buf);
    }

    pub fn writeAll(self: *ShellOs, fd: Fd, bytes: []const u8) ShellError!void {
        return self.vtable.write_all(self.ptr, fd, bytes);
    }

    pub fn readdir(self: *ShellOs, allocator: std.mem.Allocator, path: []const u8) ShellError![]const []const u8 {
        return self.vtable.readdir(self.ptr, allocator, path);
    }

    pub fn stat(self: *ShellOs, path: []const u8) ShellError!FileStat {
        return self.vtable.stat(self.ptr, path);
    }

    pub fn mkdir(self: *ShellOs, path: []const u8) ShellError!void {
        return self.vtable.mkdir(self.ptr, path);
    }

    pub fn unlink(self: *ShellOs, path: []const u8) ShellError!void {
        return self.vtable.unlink(self.ptr, path);
    }

    pub fn getcwd(self: *ShellOs, allocator: std.mem.Allocator) ShellError![]const u8 {
        return self.vtable.getcwd(self.ptr, allocator);
    }

    pub fn chdir(self: *ShellOs, path: []const u8) ShellError!void {
        return self.vtable.chdir(self.ptr, path);
    }

    pub fn bind(self: *ShellOs, old: []const u8, new: []const u8) ShellError!void {
        return self.vtable.bind(self.ptr, old, new);
    }

    pub fn unmount(self: *ShellOs, path: []const u8) ShellError!void {
        return self.vtable.unmount(self.ptr, path);
    }

    pub fn getenv(self: *ShellOs, allocator: std.mem.Allocator, name: []const u8) ShellError!?[]const u8 {
        return self.vtable.getenv(self.ptr, allocator, name);
    }

    pub fn setenv(self: *ShellOs, name: []const u8, value: []const u8) ShellError!void {
        return self.vtable.setenv(self.ptr, name, value);
    }

    pub fn unsetenv(self: *ShellOs, name: []const u8) ShellError!void {
        return self.vtable.unsetenv(self.ptr, name);
    }

    pub fn environ(self: *ShellOs, allocator: std.mem.Allocator) ShellError![]const []const u8 {
        return self.vtable.environ(self.ptr, allocator);
    }

    pub fn kill(self: *ShellOs, pid: i32, sig: Signal) ShellError!void {
        return self.vtable.kill(self.ptr, pid, sig);
    }

    pub fn setSigdisp(self: *ShellOs, sig: Signal, disp: SigDisp) void {
        self.vtable.set_sigdisp(self.ptr, sig, disp);
    }

    pub fn setpgid(self: *ShellOs, pid: Pid, pgid: Pid) ShellError!void {
        return self.vtable.setpgid(self.ptr, pid, pgid);
    }

    pub fn setForegroundPgid(self: *ShellOs, pgid: Pid) ShellError!void {
        return self.vtable.set_foreground_pgid(self.ptr, pgid);
    }

    pub fn isatty(self: *ShellOs, fd: Fd) bool {
        return self.vtable.isatty(self.ptr, fd);
    }
};
