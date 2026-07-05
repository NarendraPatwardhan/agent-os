//! Spawn conventions shared by env, find, nice, nohup, time, timeout, xargs
//! (DESIGN.md §6 table, "proc" row): argv -> NUL-joined blob, `spawnWait` with EINTR
//! retry around the blocking reap, and the exit-code mapping helpers for the
//! 125-usage / 126-spawn-failed / 127-not-found family of conventions the matrices pin
//! per applet:
//!
//!   applet  | usage | chdir | spawn-err | ENOENT | timeout | kill-escalated
//!   --------+-------+-------+-----------+--------+---------+---------------
//!   env     | 2*    | 125   | 126       | 127    | --      | --
//!   nice    | 125   | --    | 126       | 127    | --      | --
//!   nohup   | 125   | --    | 127       | 127    | --      | --   (any spawn failure -> 127)
//!   time    | 125   | --    | 127       | 127    | --      | --
//!   timeout | 125   | --    | 126       | 127    | 124     | 137
//!   xargs   | 2     | --    | 126       | 127    | --      | --  (any child != 0 -> 123)
//!
//!   (*env's clap-usage errors are 2 per the a-f matrix; its -C failure is 125.)
//!
//! `waitpid` failure maps to 1 for env/nice (the "wait fail -> 1" rule in both specs).

const std = @import("std");
const sys = @import("../sys/root.zig");

const Allocator = std.mem.Allocator;

/// NUL-joins `argv` into the `"cmd\0arg1\0arg2"` blob `sys.spawn` takes (DESIGN.md
/// §4.1). No trailing NUL (the sys layer tolerates one but doesn't need it).
pub fn argvBlob(gpa: Allocator, argv: []const []const u8) Allocator.Error![]u8 {
    var total: usize = 0;
    for (argv) |a| total += a.len + 1;
    if (total > 0) total -= 1;
    const blob = try gpa.alloc(u8, total);
    var off: usize = 0;
    for (argv, 0..) |a, i| {
        @memcpy(blob[off..][0..a.len], a);
        off += a.len;
        if (i + 1 < argv.len) {
            blob[off] = 0;
            off += 1;
        }
    }
    return blob;
}

/// Blocking reap with the EINTR retry the matrices require at the call site ("waitpid
/// (EINTR retry)"). Returns the child's mapped status (exit code, or 128+sig).
pub fn waitRetry(pid: sys.Pid) sys.Error!i32 {
    while (true) {
        return sys.waitpid(pid) catch |e| {
            if (e == error.EINTR) continue;
            return e;
        };
    }
}

pub const SpawnError = enum { not_found, other };

pub fn classifySpawnError(e: sys.Error) SpawnError {
    return if (e == error.ENOENT) .not_found else .other;
}

/// spawn + EINTR-retried waitpid, the common "run COMMAND, return its status" path
/// (env/nice/time after their own pre-work). Error cases are surfaced, not mapped --
/// each applet owns its own exit-code table (see module doc).
pub const SpawnWaitResult = union(enum) {
    status: i32,
    spawn_err: sys.Error,
    wait_err: sys.Error,
};

pub fn spawnWait(blob: []const u8, stdin: sys.Fd, stdout: sys.Fd, stderr: sys.Fd) SpawnWaitResult {
    const pid = sys.spawn(blob, stdin, stdout, stderr) catch |e| return .{ .spawn_err = e };
    const status = waitRetry(pid) catch |e| return .{ .wait_err = e };
    return .{ .status = status };
}

/// Clamps a child status (which may be 128+sig, up to 255) into the u8 an applet
/// returns.
pub fn statusToExit(status: i32) u8 {
    if (status < 0) return 1;
    if (status > 255) return @intCast(status & 0xff);
    return @intCast(status);
}
