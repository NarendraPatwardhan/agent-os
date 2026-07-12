//! `timeout` -- DESIGN.md §1: `-s/--signal SIG` (name with optional
//! `SIG` prefix, or number; map HUP/INT/KILL/TERM/CHLD/CONT/TSTP), `-k/--kill-after
//! DURATION`, `--preserve-status`, `--foreground` (accepted no-op), `-v/--verbose`;
//! `DURATION COMMAND [ARG]...` where DURATION uses sleep's grammar (`N[.frac][smhd]`).
//! Spawn (inherit stdio) then poll: `waitpidNohang` -> done; deadline check via
//! `timeMonotonicMs`; `sleepMs(10)` between. On expiry `kill(pid, sig)` (with `-v`:
//! `timeout: sending signal <SIG> to command '<cmd>'` on stderr); with `-k`, a second
//! window then `kill(pid, KILL)`; then a blocking reap. Exit: COMMAND's status if it
//! finished; 124 on timeout (COMMAND's status instead under `--preserve-status`); 125
//! own/usage errors; 126 spawn error; 127 not found; 137 when the final reap fails.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const proc = @import("../core/proc.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "run a command, killing it if it exceeds a time limit",
    .synopsis = &.{"timeout [OPTION]... DURATION COMMAND [ARG]..."},
    .description =
    \\Runs COMMAND, and if it is still running after DURATION, sends it a
    \\signal (-s/--signal, default TERM). DURATION uses sleep's grammar: a
    \\number with an optional fractional part and an optional s/m/h/d unit
    \\(seconds by default).
    \\
    \\With -k/--kill-after DURATION2, if COMMAND is still alive DURATION2
    \\after the first signal, it is sent SIGKILL as well. --preserve-status
    \\reports COMMAND's own exit status (rather than 124) when it does time
    \\out. --foreground is accepted for compatibility but has no effect (there
    \\is no process-group/terminal model to detach from here). -v/--verbose
    \\prints a notice to standard error each time a signal is sent.
    ,
    .options = &.{
        .{ .flags = "-s, --signal=SIG", .desc = "send SIG instead of TERM on timeout" },
        .{ .flags = "-k, --kill-after=DURATION", .desc = "send SIGKILL if still running DURATION after the first signal" },
        .{ .flags = "--preserve-status", .desc = "report COMMAND's own exit status even when it times out" },
        .{ .flags = "--foreground", .desc = "accepted for compatibility; no-op" },
        .{ .flags = "-v, --verbose", .desc = "print a notice to standard error before signaling COMMAND" },
    },
    .operands = "DURATION the time limit before the first signal is sent. COMMAND [ARG]... the program to run.",
    .exit = &.{
        .{ .code = 0, .when = "COMMAND finished before the deadline and exited 0" },
        .{ .code = 124, .when = "COMMAND was signaled after timing out (unless --preserve-status, which reports its own exit status instead)" },
        .{ .code = 125, .when = "usage error (bad DURATION/signal/kill-after, or a missing COMMAND)" },
        .{ .code = 126, .when = "COMMAND was found but could not be executed" },
        .{ .code = 127, .when = "COMMAND could not be found" },
        .{ .code = 137, .when = "the final reap after a -k SIGKILL escalation itself failed (128+SIGKILL)" },
    },
    .deviations_from = "GNU coreutils timeout",
    .deviations = &.{
        "Only a small signal subset is recognized (HUP, INT, KILL, TERM, CHLD, CONT, TSTP by name or number); other signals are rejected as invalid.",
        "--foreground is accepted but is always a no-op.",
    },
    .examples = &.{
        .{ .cmd = "timeout 5 sleep 10", .note = "killed by SIGTERM after 5s, exit 124" },
        .{ .cmd = "timeout -k 2 5 sleep 10", .note = "SIGTERM at 5s, escalates to SIGKILL at 7s if still alive" },
        .{ .cmd = "timeout --preserve-status 5 make", .note = "report make's own exit status even on timeout" },
    },
    .see_also = "kill, nice, time.",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const SigEntry = struct { name: []const u8, num: i32, sig: sys.Sig };

const SIGS = [_]SigEntry{
    .{ .name = "HUP", .num = 1, .sig = .hup },
    .{ .name = "INT", .num = 2, .sig = .int },
    .{ .name = "KILL", .num = 9, .sig = .kill },
    .{ .name = "TERM", .num = 15, .sig = .term },
    .{ .name = "CHLD", .num = 17, .sig = .chld },
    .{ .name = "CONT", .num = 18, .sig = .cont },
    .{ .name = "TSTP", .num = 20, .sig = .tstp },
};

fn resolveSig(spec: []const u8) ?SigEntry {
    var s = spec;
    if (s.len > 3 and std.ascii.eqlIgnoreCase(s[0..3], "SIG")) s = s[3..];
    for (SIGS) |e| if (std.ascii.eqlIgnoreCase(e.name, s)) return e;
    const n = std.fmt.parseInt(i32, spec, 10) catch return null;
    for (SIGS) |e| if (e.num == n) return e;
    return null;
}

/// sleep's DURATION grammar: `[digits][.frac][s|m|h|d]`, default unit seconds,
/// fractional part truncated to milliseconds. `null` on malformed input/overflow.
fn parseDurationMs(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var body = s;
    var unit_ms: u64 = 1000;
    const last = body[body.len - 1];
    if (last == 's' or last == 'm' or last == 'h' or last == 'd') {
        unit_ms = switch (last) {
            's' => 1000,
            'm' => 60_000,
            'h' => 3_600_000,
            'd' => 86_400_000,
            else => unreachable,
        };
        body = body[0 .. body.len - 1];
    }
    if (body.len == 0) return null;
    const dot = std.mem.indexOfScalar(u8, body, '.');
    const int_str = if (dot) |d| body[0..d] else body;
    const frac_str = if (dot) |d| body[d + 1 ..] else "";
    if (int_str.len == 0 and frac_str.len == 0) return null;
    for (int_str) |c| if (c < '0' or c > '9') return null;
    for (frac_str) |c| if (c < '0' or c > '9') return null;
    var int_val: u64 = 0;
    for (int_str) |c| {
        int_val = std.math.mul(u64, int_val, 10) catch return null;
        int_val = std.math.add(u64, int_val, c - '0') catch return null;
    }
    var frac_num: u64 = 0;
    var scale: u64 = 1;
    for (frac_str) |c| {
        frac_num = std.math.mul(u64, frac_num, 10) catch return null;
        frac_num = std.math.add(u64, frac_num, c - '0') catch return null;
        scale = std.math.mul(u64, scale, 10) catch return null;
    }
    const whole_ms = std.math.mul(u64, int_val, unit_ms) catch return null;
    const frac_scaled = std.math.mul(u64, frac_num, unit_ms) catch return null;
    return std.math.add(u64, whole_ms, frac_scaled / scale) catch null;
}

fn usage(ctx: *Ctx) u8 {
    ctx.errPrint("Usage: timeout [-s SIG] [-k DURATION] [--preserve-status] [-v] DURATION COMMAND [ARG]...\n", .{});
    return 125;
}

pub fn run(ctx: *Ctx) u8 {
    const args = ctx.args[1..];

    var sig: SigEntry = resolveSig("TERM").?;
    var kill_after_ms: ?u64 = null;
    var preserve_status = false;
    var verbose = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--help")) {
            cli.renderHelp(ctx, "timeout", help_doc);
            return 0;
        }
        if (eq(a, "--version")) {
            ctx.outPrint("timeout 0.1.0\n", .{});
            return 0;
        }
        if (eq(a, "--preserve-status")) {
            preserve_status = true;
            continue;
        }
        if (eq(a, "--foreground")) continue; // accepted no-op
        if (eq(a, "-v") or eq(a, "--verbose")) {
            verbose = true;
            continue;
        }
        if (eq(a, "-s") or eq(a, "--signal")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            sig = resolveSig(args[i]) orelse {
                ctx.errPrint("timeout: {s}: invalid signal\n", .{args[i]});
                return 125;
            };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--signal=")) {
            const v = a["--signal=".len..];
            sig = resolveSig(v) orelse {
                ctx.errPrint("timeout: {s}: invalid signal\n", .{v});
                return 125;
            };
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-s")) {
            sig = resolveSig(a[2..]) orelse {
                ctx.errPrint("timeout: {s}: invalid signal\n", .{a[2..]});
                return 125;
            };
            continue;
        }
        if (eq(a, "-k") or eq(a, "--kill-after")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            kill_after_ms = parseDurationMs(args[i]) orelse {
                ctx.errPrint("timeout: invalid time interval '{s}'\n", .{args[i]});
                return 125;
            };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--kill-after=")) {
            const v = a["--kill-after=".len..];
            kill_after_ms = parseDurationMs(v) orelse {
                ctx.errPrint("timeout: invalid time interval '{s}'\n", .{v});
                return 125;
            };
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-k")) {
            kill_after_ms = parseDurationMs(a[2..]) orelse {
                ctx.errPrint("timeout: invalid time interval '{s}'\n", .{a[2..]});
                return 125;
            };
            continue;
        }
        if (eq(a, "--")) {
            i += 1;
            break;
        }
        if (a.len > 1 and a[0] == '-' and !(a[1] >= '0' and a[1] <= '9')) return usage(ctx);
        break;
    }

    if (i >= args.len) return usage(ctx);
    const dur_ms = parseDurationMs(args[i]) orelse {
        ctx.errPrint("timeout: invalid time interval '{s}'\n", .{args[i]});
        return 125;
    };
    i += 1;
    const command = args[i..];
    if (command.len == 0) return usage(ctx);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    for (command) |a| argv.append(ctx.gpa, a) catch @panic("OOM");
    const blob = proc.argvBlob(ctx.gpa, argv.items) catch @panic("OOM");

    const pid = sys.spawn(blob, ctx.stdin, ctx.stdout, ctx.stderr) catch |e| {
        if (e == error.ENOENT) {
            ctx.errPrint("timeout: {s}: No such file or directory\n", .{command[0]});
            return 127;
        }
        ctx.errPrint("timeout: {s}: {s}\n", .{ command[0], sys.strerror(sys.toErrno(e)) });
        return 126;
    };

    const t0 = sys.timeMonotonicMs() catch 0;
    const deadline = t0 + @as(i64, @intCast(@min(dur_ms, std.math.maxInt(i64) / 2)));

    // Phase 1: wait for natural completion until the deadline.
    while (true) {
        if (sys.waitpidNohang(pid) catch null) |st| return proc.statusToExit(st);
        const now = sys.timeMonotonicMs() catch break;
        if (now >= deadline) break;
        sys.sleepMs(10);
    }

    // Timed out: signal, optionally escalate, reap.
    if (verbose) ctx.errPrint("timeout: sending signal {s} to command '{s}'\n", .{ sig.name, command[0] });
    sys.kill(pid, sig.sig) catch {};

    if (kill_after_ms) |kms| {
        const k0 = sys.timeMonotonicMs() catch 0;
        const kdeadline = k0 + @as(i64, @intCast(@min(kms, std.math.maxInt(i64) / 2)));
        var reaped: ?i32 = null;
        while (true) {
            if (sys.waitpidNohang(pid) catch null) |st| {
                reaped = st;
                break;
            }
            const now = sys.timeMonotonicMs() catch break;
            if (now >= kdeadline) break;
            sys.sleepMs(10);
        }
        if (reaped) |st| {
            return if (preserve_status) proc.statusToExit(st) else 124;
        }
        if (verbose) ctx.errPrint("timeout: sending signal KILL to command '{s}'\n", .{command[0]});
        sys.kill(pid, .kill) catch {};
    }

    const st = proc.waitRetry(pid) catch return 137;
    return if (preserve_status) proc.statusToExit(st) else 124;
}
