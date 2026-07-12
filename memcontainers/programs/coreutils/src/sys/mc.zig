//! The mc kernel backend (the coreutils architecture). This is the file that maps the
//! applet-facing `sys` API to the generated `mc` kernel ABI. The errno numbers, stat
//! layout, open flags, and constants (signals, poll events, seek whence, tiers) are
//! projected from the frozen mc contract (`memcontainers/contracts/syscalls.kdl` +
//! `constants.kdl`). Stat records are decoded through generated lengths, offsets, and node kinds.
//!
//! Calling convention: every arg is a wasm `i32` on the wire. The raw ABI is imported from
//! //memcontainers/sysroot/zig:sys, whose `mc` module is generated from contracts/syscalls.kdl.
//! This file keeps nutils' applet-facing `sys` API, but no longer owns hand-written externs.

const std = @import("std");
const types = @import("types.zig");
const Fd = types.Fd;
const Pid = types.Pid;
const Error = types.Error;
const Whence = types.Whence;
const Stat = types.Stat;
const O = types.O;
const Times = types.Times;
const Sig = types.Sig;
const Disp = types.Disp;
const PollFd = types.PollFd;

const agent_sys = @import("sys");
const raw = agent_sys.mc;
const constants = agent_sys.constants;
const STAT_REC_LEN: usize = @intCast(constants.STAT_REC_LEN);
const STAT_REC_SIZE_OFF: usize = @intCast(constants.STAT_REC_SIZE_OFF);
const STAT_REC_NODE_TYPE_OFF: usize = @intCast(constants.STAT_REC_NODE_TYPE_OFF);
const STAT_REC_NLINK_OFF: usize = @intCast(constants.STAT_REC_NLINK_OFF);
const STAT_REC_MODE_OFF: usize = @intCast(constants.STAT_REC_MODE_OFF);
const STAT_REC_MTIME_OFF: usize = @intCast(constants.STAT_REC_MTIME_OFF);
const STAT_REC_ATIME_OFF: usize = @intCast(constants.STAT_REC_ATIME_OFF);
const STAT_REC_CTIME_OFF: usize = @intCast(constants.STAT_REC_CTIME_OFF);
const STAT_NODE_DIR: u32 = @intCast(constants.STAT_NODE_DIR);
const STAT_NODE_SYMLINK: u32 = @intCast(constants.STAT_NODE_SYMLINK);

fn mc_sys_open(path: [*]const u8, len: u32, flags: i32, out_fd: *u32) i32 {
    return raw.mc_sys_open(raw.addr(path), len, flags, raw.addr(out_fd));
}
fn mc_sys_close(fd: i32) i32 {
    return raw.mc_sys_close(fd);
}
fn mc_sys_read(fd: i32, buf: [*]u8, cap: u32, out_n: *u32) i32 {
    return raw.mc_sys_read(fd, raw.addr(buf), cap, raw.addr(out_n));
}
fn mc_sys_write(fd: i32, data: [*]const u8, len: u32, out_n: *u32) i32 {
    return raw.mc_sys_write(fd, raw.addr(data), len, raw.addr(out_n));
}
fn mc_sys_lseek(fd: i32, off_ptr: *i64, whence: i32) i32 {
    return raw.mc_sys_lseek(fd, raw.addr(off_ptr), whence);
}
fn mc_sys_ftruncate(fd: i32, size_lo: u32, size_hi: u32) i32 {
    return raw.mc_sys_ftruncate(fd, size_lo, size_hi);
}
fn mc_sys_readdir(path: [*]const u8, len: u32, out_buf: [*]u8, cap: u32, out_used: *u32) i32 {
    return raw.mc_sys_readdir(raw.addr(path), len, raw.addr(out_buf), cap, raw.addr(out_used));
}
fn mc_sys_stat(path: [*]const u8, len: u32, out_stat: *[STAT_REC_LEN]u8) i32 {
    return raw.mc_sys_stat(raw.addr(path), len, raw.addr(out_stat));
}
fn mc_sys_lstat(path: [*]const u8, len: u32, out_stat: *[STAT_REC_LEN]u8) i32 {
    return raw.mc_sys_lstat(raw.addr(path), len, raw.addr(out_stat));
}
fn mc_sys_mkdir(path: [*]const u8, len: u32) i32 {
    return raw.mc_sys_mkdir(raw.addr(path), len);
}
fn mc_sys_unlink(path: [*]const u8, len: u32) i32 {
    return raw.mc_sys_unlink(raw.addr(path), len);
}
fn mc_sys_rename(old: [*]const u8, old_len: u32, new: [*]const u8, new_len: u32) i32 {
    return raw.mc_sys_rename(raw.addr(old), old_len, raw.addr(new), new_len);
}
fn mc_sys_symlink(target: [*]const u8, target_len: u32, link_name: [*]const u8, link_len: u32) i32 {
    return raw.mc_sys_symlink(raw.addr(target), target_len, raw.addr(link_name), link_len);
}
fn mc_sys_link(old: [*]const u8, old_len: u32, new: [*]const u8, new_len: u32) i32 {
    return raw.mc_sys_link(raw.addr(old), old_len, raw.addr(new), new_len);
}
fn mc_sys_readlink(path: [*]const u8, len: u32, out_buf: [*]u8, cap: u32, out_used: *u32) i32 {
    return raw.mc_sys_readlink(raw.addr(path), len, raw.addr(out_buf), cap, raw.addr(out_used));
}
fn mc_sys_chmod(path: [*]const u8, len: u32, mode: i32) i32 {
    return raw.mc_sys_chmod(raw.addr(path), len, @intCast(mode));
}
fn mc_sys_utimes(path: [*]const u8, len: u32, times_ptr: ?*const [2]i64) i32 {
    return raw.mc_sys_utimes(raw.addr(path), len, if (times_ptr) |p| raw.addr(p) else 0);
}
fn mc_sys_getcwd(out_buf: [*]u8, cap: u32, out_used: *u32) i32 {
    return raw.mc_sys_getcwd(raw.addr(out_buf), cap, raw.addr(out_used));
}
fn mc_sys_chdir(path: [*]const u8, len: u32) i32 {
    return raw.mc_sys_chdir(raw.addr(path), len);
}

fn mc_sys_spawn(blob: [*]const u8, blob_len: u32, stdin_fd: i32, stdout_fd: i32, stderr_fd: i32, tier: i32, out_pid: *u32) i32 {
    return raw.mc_sys_spawn(raw.addr(blob), blob_len, stdin_fd, stdout_fd, stderr_fd, tier, raw.addr(out_pid));
}
fn mc_sys_waitpid(pid: i32, opts: i32, out_status: *u32, out_got: *u32) i32 {
    return raw.mc_sys_waitpid(pid, opts, raw.addr(out_status), raw.addr(out_got));
}
fn mc_sys_kill(pid: i32, sig: i32) i32 {
    return raw.mc_sys_kill(pid, sig);
}
fn mc_sys_nice(inc: i32, ret: *i32) i32 {
    return raw.mc_sys_nice(inc, raw.addr(ret));
}
fn mc_sys_sigdisp(sig: i32, disp: i32) i32 {
    return raw.mc_sys_sigdisp(sig, disp);
}
fn mc_sys_pipe(out_rfd: *u32, out_wfd: *u32) i32 {
    return raw.mc_sys_pipe(raw.addr(out_rfd), raw.addr(out_wfd));
}
fn mc_sys_getpid(out_pid: *u32) i32 {
    return raw.mc_sys_getpid(raw.addr(out_pid));
}
fn mc_sys_getppid(out_pid: *u32) i32 {
    return raw.mc_sys_getppid(raw.addr(out_pid));
}
fn mc_sys_exit(code: i32) i32 {
    return raw.mc_sys_exit(code);
}
fn mc_sys_isatty(fd: i32, out_r: *u32) i32 {
    return raw.mc_sys_isatty(fd, raw.addr(out_r));
}

/// mc's pollfd wire layout (#21; sysroot/rust/src/sys.rs, `#[repr(C)]`): exactly 8 bytes.
const McPollFd = extern struct { fd: i32, events: i16, revents: i16 };
fn mc_sys_poll(fds: [*]McPollFd, nfds: u32, timeout_ms: i32, ret_ready: *u32) i32 {
    return raw.mc_sys_poll(raw.addr(fds), nfds, timeout_ms, raw.addr(ret_ready));
}

fn mc_sys_http_get(url: [*]const u8, len: u32, out_fd: *u32) i32 {
    return raw.mc_sys_http_get(raw.addr(url), len, raw.addr(out_fd));
}
fn mc_sys_http_request(blob: [*]const u8, len: u32, out_fd: *u32) i32 {
    return raw.mc_sys_http_request(raw.addr(blob), len, raw.addr(out_fd));
}
fn mc_sys_http_status(fd: i32, out_status: *u32) i32 {
    return raw.mc_sys_http_status(fd, raw.addr(out_status));
}
fn mc_sys_ws_open(url: [*]const u8, len: u32, out_fd: *u32) i32 {
    return raw.mc_sys_ws_open(raw.addr(url), len, raw.addr(out_fd));
}

fn mc_sys_time_realtime(out_ms: *i64) i32 {
    return raw.mc_sys_time_realtime(raw.addr(out_ms));
}
fn mc_sys_time_monotonic(out_ms: *i64) i32 {
    return raw.mc_sys_time_monotonic(raw.addr(out_ms));
}
fn mc_sys_sleep_ms(ms: i32) i32 {
    return raw.mc_sys_sleep_ms(ms);
}
fn mc_sys_random(buf: [*]u8, len: u32) i32 {
    return raw.mc_sys_random(raw.addr(buf), len);
}
fn mc_sys_args(buf: [*]u8, cap: u32, out_total: *u32) i32 {
    return raw.mc_sys_args(raw.addr(buf), cap, raw.addr(out_total));
}

// ---------------------------------------------------------------- open() flags (contracts/constants.kdl, per the glue)

fn toOpenFlags(flags: O) i32 {
    var f: i32 = 0;
    if (flags.read) f |= constants.O_READ;
    if (flags.write) f |= constants.O_WRITE;
    if (flags.create) f |= constants.O_CREATE;
    if (flags.trunc) f |= constants.O_TRUNC;
    if (flags.append) f |= constants.O_APPEND;
    return f;
}

fn seekWhence(w: Whence) i32 {
    return switch (w) {
        .set => constants.SEEK_SET,
        .cur => constants.SEEK_CUR,
        .end => constants.SEEK_END,
    };
}

// signal numbers + dispositions (constants.kdl §143-157). The kernel accepts sig 0..31;
// every name this adapter exposes is projected from the contract.
fn sigNum(s: Sig) i32 {
    return switch (s) {
        .hup => constants.SIGHUP,
        .int => constants.SIGINT,
        .quit => constants.SIGQUIT,
        .kill => constants.SIGKILL,
        .usr1 => constants.SIGUSR1,
        .usr2 => constants.SIGUSR2,
        .term => constants.SIGTERM,
        .chld => constants.SIGCHLD,
        .cont => constants.SIGCONT,
        .stop => constants.SIGSTOP,
        .tstp => constants.SIGTSTP,
    };
}

// ---------------------------------------------------------------- errno mapping
//
// Map the projected mc errno names into nutils' error set. Anything outside this set maps to
// EUNKNOWN rather than guessing.

fn mcErr(e: i32) Error {
    return switch (e) {
        constants.EACCES => error.EACCES,
        constants.EAGAIN => error.EAGAIN,
        constants.EBADF => error.EBADF,
        constants.ECHILD => error.ECHILD,
        constants.EEXIST => error.EEXIST,
        constants.EINTR => error.EINTR,
        constants.EINVAL => error.EINVAL,
        constants.EIO => error.EIO,
        constants.EISDIR => error.EISDIR,
        constants.ELOOP => error.ELOOP,
        constants.EMFILE => error.EMFILE,
        constants.ENOENT => error.ENOENT,
        constants.ENOSYS => error.ENOSYS,
        constants.EMSGSIZE => error.EMSGSIZE,
        constants.ENOTDIR => error.ENOTDIR,
        constants.ENOTEMPTY => error.ENOTEMPTY,
        constants.EPERM => error.EPERM,
        constants.EPIPE => error.EPIPE,
        constants.ESRCH => error.ESRCH,
        constants.ETIMEDOUT => error.ETIMEDOUT,
        constants.EXDEV => error.EXDEV,
        else => error.EUNKNOWN,
    };
}

fn check(e: i32) Error!void {
    if (e != 0) return mcErr(e);
}

// ---------------------------------------------------------------- stat translation
//
// Decode the generated stat-record contract. Times are milliseconds since the epoch.
fn statFromBuf(buf: *const [STAT_REC_LEN]u8) Stat {
    const size = std.mem.readInt(u64, buf[STAT_REC_SIZE_OFF .. STAT_REC_SIZE_OFF + @sizeOf(u64)], .little);
    const kind = std.mem.readInt(u32, buf[STAT_REC_NODE_TYPE_OFF .. STAT_REC_NODE_TYPE_OFF + @sizeOf(u32)], .little);
    const nlink = std.mem.readInt(u32, buf[STAT_REC_NLINK_OFF .. STAT_REC_NLINK_OFF + @sizeOf(u32)], .little);
    const mode = std.mem.readInt(u32, buf[STAT_REC_MODE_OFF .. STAT_REC_MODE_OFF + @sizeOf(u32)], .little) & 0o7777;
    const mtime_ms = std.mem.readInt(i64, buf[STAT_REC_MTIME_OFF .. STAT_REC_MTIME_OFF + @sizeOf(i64)], .little);
    const atime_ms = std.mem.readInt(i64, buf[STAT_REC_ATIME_OFF .. STAT_REC_ATIME_OFF + @sizeOf(i64)], .little);
    const ctime_ms = std.mem.readInt(i64, buf[STAT_REC_CTIME_OFF .. STAT_REC_CTIME_OFF + @sizeOf(i64)], .little);
    return .{
        .size = size,
        .mode = mode,
        .nlink = nlink,
        .atime_ms = atime_ms,
        .mtime_ms = mtime_ms,
        .ctime_ms = ctime_ms,
        .is_dir = kind == STAT_NODE_DIR,
        .is_symlink = kind == STAT_NODE_SYMLINK,
    };
}

pub fn init() void {}

// ---------------------------------------------------------------- fs

pub fn open(path: []const u8, flags: O) Error!Fd {
    var out_fd: u32 = 0;
    try check(mc_sys_open(path.ptr, @intCast(path.len), toOpenFlags(flags), &out_fd));
    return @intCast(out_fd);
}

pub fn read(fd: Fd, buf: []u8) Error!usize {
    var n: u32 = 0;
    try check(mc_sys_read(fd, buf.ptr, @intCast(buf.len), &n));
    return n;
}

pub fn writeAll(fd: Fd, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        var n: u32 = 0;
        try check(mc_sys_write(fd, bytes.ptr + off, @intCast(bytes.len - off), &n));
        if (n == 0) return error.EIO; // matches the glue's lFsWrite/lIoWrite short-write handling
        off += n;
    }
}

pub fn close(fd: Fd) void {
    _ = mc_sys_close(fd);
}

/// `off_ptr` is in/out: passes the offset relative to `whence`, receives the new absolute
/// position (contract #19, kernel wasm/mod.rs:2770-2793).
pub fn lseek(fd: Fd, off: i64, whence: Whence) Error!u64 {
    var pos: i64 = off;
    try check(mc_sys_lseek(fd, &pos, seekWhence(whence)));
    return @intCast(pos);
}

pub fn stat(path: []const u8) Error!Stat {
    var buf: [STAT_REC_LEN]u8 = undefined;
    try check(mc_sys_stat(path.ptr, @intCast(path.len), &buf));
    return statFromBuf(&buf);
}

pub fn lstat(path: []const u8) Error!Stat {
    var buf: [STAT_REC_LEN]u8 = undefined;
    try check(mc_sys_lstat(path.ptr, @intCast(path.len), &buf));
    return statFromBuf(&buf);
}

pub fn readlink(path: []const u8, buf: []u8) Error!usize {
    var used: u32 = 0;
    try check(mc_sys_readlink(path.ptr, @intCast(path.len), buf.ptr, @intCast(buf.len), &used));
    return used;
}

pub fn symlink(target: []const u8, link_path: []const u8) Error!void {
    try check(mc_sys_symlink(target.ptr, @intCast(target.len), link_path.ptr, @intCast(link_path.len)));
}

/// Hard link (contract #12): POSIX arg order is (old=existing target, new=link name),
/// both resolved no-follow.
pub fn link(target: []const u8, link_path: []const u8) Error!void {
    try check(mc_sys_link(target.ptr, @intCast(target.len), link_path.ptr, @intCast(link_path.len)));
}

pub fn unlink(path: []const u8) Error!void {
    // kernel convention: unlink also removes empty directories (the coreutils architecture) -- the
    // glue's `mc_sys_unlink` is used unconditionally for files and directories alike.
    try check(mc_sys_unlink(path.ptr, @intCast(path.len)));
}

pub fn mkdir(path: []const u8) Error!void {
    try check(mc_sys_mkdir(path.ptr, @intCast(path.len)));
}

pub fn readdir(path: []const u8, buf: []u8) Error!usize {
    var used: u32 = 0;
    try check(mc_sys_readdir(path.ptr, @intCast(path.len), buf.ptr, @intCast(buf.len), &used));
    return used;
}

pub fn rename(old: []const u8, new: []const u8) Error!void {
    try check(mc_sys_rename(old.ptr, @intCast(old.len), new.ptr, @intCast(new.len)));
}

pub fn chmod(path: []const u8, mode: u32) Error!void {
    try check(mc_sys_chmod(path.ptr, @intCast(path.len), @intCast(mode & 0o7777)));
}

/// Set atime/mtime (contract #16). The kernel buffer is `{atime_ms, mtime_ms}` (atime
/// first); a null pointer means "set both to now". Path is resolved no-follow.
pub fn utimes(path: []const u8, times: ?Times) Error!void {
    if (times) |t| {
        const pair = [2]i64{ t.atime_ms, t.mtime_ms };
        try check(mc_sys_utimes(path.ptr, @intCast(path.len), &pair));
    } else {
        try check(mc_sys_utimes(path.ptr, @intCast(path.len), null));
    }
}

/// Truncate/extend an open file (contract #20). The 64-bit size is split into two u32
/// halves on the wire (not a pointer).
pub fn ftruncate(fd: Fd, len: u64) Error!void {
    try check(mc_sys_ftruncate(fd, @truncate(len), @truncate(len >> 32)));
}

pub fn chdir(path: []const u8) Error!void {
    // The kernel resolves relative paths against its own notion of cwd.
    try check(mc_sys_chdir(path.ptr, @intCast(path.len)));
}

pub fn getcwd(buf: []u8) Error!usize {
    var used: u32 = 0;
    try check(mc_sys_getcwd(buf.ptr, @intCast(buf.len), &used));
    return used;
}

// ---------------------------------------------------------------- proc

pub fn spawn(argv_blob: []const u8, stdin: Fd, stdout: Fd, stderr: Fd) Error!Pid {
    // nutils' `sys.spawn` has no tier parameter (the coreutils architecture), so it inherits the caller's tier;
    // the kernel remains the enforcement point for anything stricter.
    var out_pid: u32 = 0;
    try check(mc_sys_spawn(argv_blob.ptr, @intCast(argv_blob.len), stdin, stdout, stderr, constants.TIER_INHERIT, &out_pid));
    return @intCast(out_pid);
}

/// Blocking wait (opts=0). The kernel status is already the exit-code-shaped value
/// applets want, not a raw POSIX wait() encoding.
pub fn waitpid(pid: Pid) Error!i32 {
    var status: u32 = 0;
    var got: u32 = 0;
    try check(mc_sys_waitpid(pid, 0, &status, &got));
    return @bitCast(status);
}

/// Non-blocking wait (opts=1, mc-glue's nohang bit). `got == 0` means "no child ready
/// yet" (the coreutils architecture) rather than an error.
pub fn waitpidNohang(pid: Pid) Error!?i32 {
    var status: u32 = 0;
    var got: u32 = 0;
    try check(mc_sys_waitpid(pid, constants.WNOHANG, &status, &got));
    if (got == 0) return null;
    return @bitCast(status);
}

/// Send a signal (contract #41). Requires CAP_SPAWN and may only target self or a
/// descendant (kernel returns EPERM otherwise), which surfaces to the applet as-is.
pub fn kill(pid: Pid, sig: Sig) Error!void {
    try check(mc_sys_kill(pid, sigNum(sig)));
}

pub fn getpid() Pid {
    var pid: u32 = 0;
    _ = mc_sys_getpid(&pid); // glue discards the errno here too (lProcPid)
    return @intCast(pid);
}

/// Create a pipe (contract #32); returns the read/write fd pair.
pub fn pipe() Error!types.Pipe {
    var rfd: u32 = 0;
    var wfd: u32 = 0;
    try check(mc_sys_pipe(&rfd, &wfd));
    return .{ .r = @intCast(rfd), .w = @intCast(wfd) };
}

/// Adjust niceness (contract #40); returns the new value, clamped to -20..19 by the kernel.
pub fn nice(inc: i32) Error!i32 {
    var ret: i32 = 0;
    try check(mc_sys_nice(inc, &ret));
    return ret;
}

/// Set this task's disposition for `sig` (contract #42). Only SIG_DFL/SIG_IGN dispositions
/// exist (no handler pointers); SIGKILL is rejected with EINVAL by the kernel.
pub fn sigdisp(sig: Sig, disp: Disp) Error!void {
    const d: i32 = switch (disp) {
        .default => constants.SIG_DFL,
        .ignore => constants.SIG_IGN,
    };
    try check(mc_sys_sigdisp(sigNum(sig), d));
}

pub fn isatty(fd: Fd) bool {
    var r: u32 = 0;
    if (mc_sys_isatty(fd, &r) != 0) return false;
    return r != 0;
}

// ---------------------------------------------------------------- clock

pub fn timeRealtimeMs() Error!i64 {
    var ms: i64 = 0;
    try check(mc_sys_time_realtime(&ms));
    return ms;
}

pub fn timeMonotonicMs() Error!i64 {
    var ms: i64 = 0;
    try check(mc_sys_time_monotonic(&ms));
    return ms;
}

pub fn sleepMs(ms: i32) void {
    _ = mc_sys_sleep_ms(ms);
}

/// Fills `buf` via the `mc_sys_random` host import. Used only by shuf's default
/// (unseeded, not byte-parity-tested) random-permutation mode.
pub fn randomBytes(buf: []u8) Error!void {
    try check(mc_sys_random(buf.ptr, @intCast(buf.len)));
}

// ---------------------------------------------------------------- net (opaque-fd model)

pub fn httpGet(url: []const u8) Error!Fd {
    var out_fd: u32 = 0;
    try check(mc_sys_http_get(url.ptr, @intCast(url.len), &out_fd));
    return @intCast(out_fd);
}

pub fn httpRequest(blob: []const u8) Error!Fd {
    var out_fd: u32 = 0;
    try check(mc_sys_http_request(blob.ptr, @intCast(blob.len), &out_fd));
    return @intCast(out_fd);
}

pub fn httpStatus(fd: Fd) Error!u32 {
    var status: u32 = 0;
    try check(mc_sys_http_status(fd, &status));
    return status;
}

/// Open a duplex WebSocket connection (contract #48); requires CAP_NET.
pub fn wsOpen(url: []const u8) Error!Fd {
    var out_fd: u32 = 0;
    try check(mc_sys_ws_open(url.ptr, @intCast(url.len), &out_fd));
    return @intCast(out_fd);
}

/// Poll a set of fds (contract #21). Translates our `PollFd` to the kernel's 8-byte
/// `McPollFd`, then copies readiness back into the caller's slice. `timeout_ms`: 0 =
/// non-blocking, >0 = deadline, -1 = block forever. Returns the count of ready fds.
pub fn poll(fds: []PollFd, timeout_ms: i32) Error!usize {
    var buf: [64]McPollFd = undefined;
    const n = @min(fds.len, buf.len);
    for (fds[0..n], 0..) |f, i| {
        var events: i16 = 0;
        if (f.want_read) events |= @intCast(constants.POLLIN);
        if (f.want_write) events |= @intCast(constants.POLLOUT);
        buf[i] = .{ .fd = f.fd, .events = events, .revents = 0 };
    }
    var ready: u32 = 0;
    try check(mc_sys_poll(&buf, @intCast(n), timeout_ms, &ready));
    for (fds[0..n], 0..) |*f, i| {
        f.readable = (buf[i].revents & @as(i16, @intCast(constants.POLLIN))) != 0;
        f.writable = (buf[i].revents & @as(i16, @intCast(constants.POLLOUT))) != 0;
    }
    return ready;
}

// ---------------------------------------------------------------- misc

pub fn exit(code: u8) noreturn {
    _ = mc_sys_exit(code);
    // mc_sys_exit terminates the guest; this is unreachable on a correctly-behaving
    // kernel. Loop rather than `unreachable` so a misbehaving/absent import fails safe
    // (a trap) instead of undefined behavior.
    while (true) {}
}

var args_raw: [16384]u8 = undefined; // matches mc-glue entry.zig's lArgs buffer size
var argv_storage: [8192]u8 = undefined;
var argv_slices: [128][:0]const u8 = undefined;

/// NUL-joined blob from `mc_sys_args`, split like the glue's `lArgs` (skip empty
/// pieces), then copied into local storage so each argument is independently
/// NUL-terminated regardless of where the kernel's own NULs land.
pub fn argsAlloc(gpa: anytype) Error![]const [:0]const u8 {
    _ = gpa;
    var total: u32 = 0;
    _ = mc_sys_args(&args_raw, args_raw.len, &total); // glue discards the errno here too (lArgs)
    const n = @min(total, args_raw.len);

    var count: usize = 0;
    var off: usize = 0;
    var it = std.mem.splitScalar(u8, args_raw[0..n], 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        if (count >= argv_slices.len) break;
        if (off + arg.len + 1 > argv_storage.len) break;
        @memcpy(argv_storage[off..][0..arg.len], arg);
        argv_storage[off + arg.len] = 0;
        argv_slices[count] = argv_storage[off .. off + arg.len :0];
        off += arg.len + 1;
        count += 1;
    }
    return argv_slices[0..count];
}
