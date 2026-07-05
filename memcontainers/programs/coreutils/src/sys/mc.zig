//! The Agent OS kernel backend (DESIGN.md §4.2). This is the file that maps the
//! applet-facing `sys` API to the generated `mc` kernel ABI. The errno numbers, stat
//! layout, open flags, and constants (signals, poll events, seek whence, tiers) are
//! taken from the frozen contract in the Agent OS kernel source
//! (`memcontainers/contracts/syscalls.kdl` + `constants.kdl`, cross-checked against the
//! kernel handlers). The 44-byte stat layout is size@0/kind@8/nlink@12/mode@16/
//! mtime@20/atime@28/ctime@36, all ms.
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
fn mc_sys_stat(path: [*]const u8, len: u32, out_stat: *[44]u8) i32 {
    return raw.mc_sys_stat(raw.addr(path), len, raw.addr(out_stat));
}
fn mc_sys_lstat(path: [*]const u8, len: u32, out_stat: *[44]u8) i32 {
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

const O_READ: i32 = 1;
const O_WRITE: i32 = 2;
const O_CREATE: i32 = 4;
const O_TRUNC: i32 = 8;
const O_APPEND: i32 = 16;

fn toOpenFlags(flags: O) i32 {
    var f: i32 = 0;
    if (flags.read) f |= O_READ;
    if (flags.write) f |= O_WRITE;
    if (flags.create) f |= O_CREATE;
    if (flags.trunc) f |= O_TRUNC;
    if (flags.append) f |= O_APPEND;
    return f;
}

// spawn tier argument (DESIGN.md §14 R1 / mc-glue sys.zig's TIER_* globals). nutils'
// `sys.spawn` has no tier parameter (DESIGN.md §4.1), so we always inherit the caller's
// tier -- the kernel is the enforcement point for anything stricter.
const TIER_INHERIT: i32 = 0;
const TIER_FULL: i32 = 1;
const TIER_READ_WRITE: i32 = 2;
const TIER_READ_ONLY: i32 = 3;
const TIER_ISOLATED: i32 = 4;
comptime {
    _ = TIER_FULL;
    _ = TIER_READ_WRITE;
    _ = TIER_READ_ONLY;
    _ = TIER_ISOLATED;
}

// waitpid `opts` bit (mc-glue sys.zig's lProcWait: `opts |= 1` for a nohang wait).
const WAIT_NOHANG: i32 = 1;

// seek whence (constants.kdl §122-127)
const SEEK_SET: i32 = 0;
const SEEK_CUR: i32 = 1;
const SEEK_END: i32 = 2;
fn seekWhence(w: Whence) i32 {
    return switch (w) {
        .set => SEEK_SET,
        .cur => SEEK_CUR,
        .end => SEEK_END,
    };
}

// poll events (constants.kdl §134-141)
const POLLIN: i16 = 1;
const POLLOUT: i16 = 4;

// signal numbers + dispositions (constants.kdl §143-157). The kernel accepts sig 0..31;
// the names not in its own table (quit/usr1/usr2/stop) use their standard POSIX numbers.
fn sigNum(s: Sig) i32 {
    return switch (s) {
        .hup => 1,
        .int => 2,
        .quit => 3,
        .kill => 9,
        .usr1 => 10,
        .usr2 => 12,
        .term => 15,
        .chld => 17,
        .cont => 18,
        .stop => 19,
        .tstp => 20,
    };
}
const SIG_DFL: i32 = 0;
const SIG_IGN: i32 = 1;

// ---------------------------------------------------------------- errno mapping (DESIGN.md §14 R1)
//
// WASI-standard numbers, taken verbatim from the glue's `errnoName` table
// (reference/mc-glue/sys.zig). Anything the mc kernel returns outside this set maps to
// EUNKNOWN rather than guessing.

fn mcErr(e: i32) Error {
    return switch (e) {
        2 => error.EACCES,
        6 => error.EAGAIN,
        8 => error.EBADF,
        10 => error.ECHILD,
        20 => error.EEXIST,
        27 => error.EINTR,
        28 => error.EINVAL,
        29 => error.EIO,
        31 => error.EISDIR,
        32 => error.ELOOP,
        33 => error.EMFILE,
        44 => error.ENOENT,
        52 => error.ENOSYS,
        54 => error.ENOTDIR,
        55 => error.ENOTEMPTY,
        53 => error.EMSGSIZE,
        63 => error.EPERM,
        64 => error.EPIPE,
        71 => error.ESRCH,
        73 => error.ETIMEDOUT,
        75 => error.EXDEV,
        else => error.EUNKNOWN,
    };
}

fn check(e: i32) Error!void {
    if (e != 0) return mcErr(e);
}

// ---------------------------------------------------------------- stat translation (DESIGN.md §14 R1)
//
// The 44-byte stat record (constants.kdl §198-213; kernel `write_stat_buf`,
// wasm/mod.rs:1606-1629): size u64 LE @0, kind u32 @8 (0=file, 1=dir, 2=symlink),
// nlink u32 @12, mode u32 @16, mtime i64 @20, atime i64 @28, ctime i64 @36 -- all times
// in milliseconds since the epoch. Layout confirmed byte-exact against the frozen contract.
fn statFromBuf(buf: *const [44]u8) Stat {
    const size = std.mem.readInt(u64, buf[0..8], .little);
    const kind = std.mem.readInt(u32, buf[8..12], .little);
    const nlink = std.mem.readInt(u32, buf[12..16], .little);
    const mode = std.mem.readInt(u32, buf[16..20], .little) & 0o7777;
    const mtime_ms = std.mem.readInt(i64, buf[20..28], .little);
    const atime_ms = std.mem.readInt(i64, buf[28..36], .little);
    const ctime_ms = std.mem.readInt(i64, buf[36..44], .little);
    return .{
        .size = size,
        .mode = mode,
        .nlink = nlink,
        .atime_ms = atime_ms,
        .mtime_ms = mtime_ms,
        .ctime_ms = ctime_ms,
        .is_dir = kind == 1,
        .is_symlink = kind == 2,
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
    var buf: [44]u8 = undefined;
    try check(mc_sys_stat(path.ptr, @intCast(path.len), &buf));
    return statFromBuf(&buf);
}

pub fn lstat(path: []const u8) Error!Stat {
    var buf: [44]u8 = undefined;
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
    // kernel convention: unlink also removes empty directories (DESIGN.md §4.1) -- the
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
    var out_pid: u32 = 0;
    try check(mc_sys_spawn(argv_blob.ptr, @intCast(argv_blob.len), stdin, stdout, stderr, TIER_INHERIT, &out_pid));
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
/// yet" (DESIGN.md task spec) rather than an error.
pub fn waitpidNohang(pid: Pid) Error!?i32 {
    var status: u32 = 0;
    var got: u32 = 0;
    try check(mc_sys_waitpid(pid, WAIT_NOHANG, &status, &got));
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
        .default => SIG_DFL,
        .ignore => SIG_IGN,
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
        if (f.want_read) events |= POLLIN;
        if (f.want_write) events |= POLLOUT;
        buf[i] = .{ .fd = f.fd, .events = events, .revents = 0 };
    }
    var ready: u32 = 0;
    try check(mc_sys_poll(&buf, @intCast(n), timeout_ms, &ready));
    for (fds[0..n], 0..) |*f, i| {
        f.readable = (buf[i].revents & POLLIN) != 0;
        f.writable = (buf[i].revents & POLLOUT) != 0;
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
