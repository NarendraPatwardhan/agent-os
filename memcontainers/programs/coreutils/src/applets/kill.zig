//! `kill` -- docs/analysis/applets-g-r.md: hand-parsed (no `cli.zig`). Signal table
//! (kernel subset, EXACT numbers): HUP=1, INT=2, KILL=9, TERM=15, CHLD=17, CONT=18,
//! TSTP=20. `-s/--signal SIG`, bare `-SIGNAL` (`-9`/`-KILL`/`-HUP`, any leading-dash
//! token that resolves to a signal, consumed only before the first PID is seen),
//! `-l/-L/--table` list mode (no SPECs -> print every name space-separated; with SPECs
//! -> number->name, subtracting 128 first if >128, or name->number; unrecognized SPEC ->
//! `kill: <spec>: invalid signal specification`, rc=1). Default signal TERM. PID parse
//! allows a leading `-` (process group). `sys.kill` failure -> `kill: <p>: no such
//! process`, rc=1; non-numeric PID -> `kill: <p>: arguments must be process or job
//! IDs`, rc=1. Exit 0 / 1. No `%jobspec`, no `-q`.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "send a signal to a process, or list signal names",
    .synopsis = &.{
        "kill [-s SIGNAL | -SIGNAL] PID...",
        "kill -l [SPEC...]",
    },
    .description =
    \\Sends SIGNAL (default TERM) to each PID. The signal may be given as
    \\-s/--signal SIGNAL, or as a bare -SIGNAL prefix on the first non-option
    \\token (-9, -KILL, -HUP, ...); SIGNAL is a name (optionally prefixed
    \\"SIG"), case-insensitive, or a number. A PID may itself begin with "-"
    \\to address a process group.
    \\
    \\-l/--list (alias -L/--table) switches to lookup mode instead of sending
    \\anything: with no SPEC, every recognized signal name is printed
    \\space-separated; with SPECs, each is converted the other way (a number
    \\to its name, subtracting 128 first if greater than 128 -- the "exit
    \\status of a job killed by a signal" convention -- or a name to its
    \\number).
    ,
    .options = &.{
        .{ .flags = "-s, --signal=SIGNAL", .desc = "signal to send (name or number; default TERM)" },
        .{ .flags = "-SIGNAL", .desc = "same as -s SIGNAL (e.g. -9, -KILL, -HUP)" },
        .{ .flags = "-l, -L, --list, --table", .desc = "list signal names, or convert the given SPECs" },
    },
    .operands = "PID... process (or, with a leading '-', process group) IDs to signal. SPEC... (with -l) signal names or numbers to convert, in list mode.",
    .exit = &.{
        .{ .code = 0, .when = "every signal/lookup succeeded" },
        .{ .code = 1, .when = "a PID was not numeric, sending the signal failed (e.g. no such process), or (-l) a SPEC did not resolve to a known signal" },
    },
    .deviations_from = "GNU coreutils kill",
    .deviations = &.{
        "Only a small kernel signal subset is known: HUP, INT, KILL, TERM, CHLD, CONT, TSTP. There are no %jobspec arguments and no -q/--queue (sigqueue).",
    },
    .examples = &.{
        .{ .cmd = "kill 1234", .note = "send SIGTERM to PID 1234" },
        .{ .cmd = "kill -9 1234", .note = "send SIGKILL to PID 1234" },
        .{ .cmd = "kill -l 137", .note = "prints KILL (137 - 128 = signal 9)" },
    },
    .see_also = "timeout (send a signal after a deadline), nice.",
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

fn stripSigPrefix(s: []const u8) []const u8 {
    if (s.len > 3 and std.ascii.eqlIgnoreCase(s[0..3], "SIG")) return s[3..];
    return s;
}

fn findByName(name: []const u8) ?SigEntry {
    const n = stripSigPrefix(name);
    for (SIGS) |e| if (std.ascii.eqlIgnoreCase(e.name, n)) return e;
    return null;
}

fn findByNumber(num: i32) ?SigEntry {
    for (SIGS) |e| if (e.num == num) return e;
    return null;
}

/// Resolves a `-s SIG`/bare-dash signal spec: name (with optional `SIG` prefix) first,
/// then a direct (unshifted) number match.
fn resolveSigSpec(s: []const u8) ?SigEntry {
    if (findByName(s)) |e| return e;
    const n = std.fmt.parseInt(i32, s, 10) catch return null;
    return findByNumber(n);
}

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "kill", "0.1.0", help_doc)) return 0;
    const args = ctx.args[1..];

    var mode_list = false;
    var explicit_sig: ?SigEntry = null;
    var pids: std.ArrayListUnmanaged([]const u8) = .empty;
    var list_specs: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!mode_list and (eq(a, "-l") or eq(a, "--list") or eq(a, "-L") or eq(a, "--table"))) {
            mode_list = true;
            continue;
        }
        if (mode_list) {
            list_specs.append(ctx.gpa, a) catch @panic("OOM");
            continue;
        }
        if (eq(a, "-s") or eq(a, "--signal")) {
            i += 1;
            if (i >= args.len) {
                ctx.errPrint("kill: option requires an argument -- 's'\n", .{});
                return 1;
            }
            const spec = args[i];
            explicit_sig = resolveSigSpec(spec) orelse {
                ctx.errPrint("kill: {s}: invalid signal specification\n", .{spec});
                return 1;
            };
            continue;
        }
        if (pids.items.len == 0 and a.len >= 2 and a[0] == '-') {
            if (resolveSigSpec(a[1..])) |e| {
                explicit_sig = e;
                continue;
            }
            // Doesn't resolve as a signal -- fall through, treated as a (process-group) PID.
        }
        pids.append(ctx.gpa, a) catch @panic("OOM");
    }

    if (mode_list) {
        if (list_specs.items.len == 0) {
            var first = true;
            for (SIGS) |e| {
                if (!first) ctx.outPrint(" ", .{});
                ctx.outPrint("{s}", .{e.name});
                first = false;
            }
            ctx.outPrint("\n", .{});
            return 0;
        }
        var rc: u8 = 0;
        for (list_specs.items) |spec| {
            if (std.fmt.parseInt(i32, spec, 10) catch null) |n0| {
                var n = n0;
                if (n > 128) n -= 128;
                if (findByNumber(n)) |e| {
                    ctx.outPrint("{s}\n", .{e.name});
                } else {
                    ctx.errPrint("kill: {s}: invalid signal specification\n", .{spec});
                    rc = 1;
                }
            } else if (findByName(spec)) |e| {
                ctx.outPrint("{d}\n", .{e.num});
            } else {
                ctx.errPrint("kill: {s}: invalid signal specification\n", .{spec});
                rc = 1;
            }
        }
        return rc;
    }

    if (pids.items.len == 0) {
        ctx.errPrint("kill: missing operand\n", .{});
        return 1;
    }

    const sig = explicit_sig orelse findByName("TERM").?;
    var rc: u8 = 0;
    for (pids.items) |pid_str| {
        const pid_val = std.fmt.parseInt(i32, pid_str, 10) catch {
            ctx.errPrint("kill: {s}: arguments must be process or job IDs\n", .{pid_str});
            rc = 1;
            continue;
        };
        sys.kill(pid_val, sig.sig) catch {
            ctx.errPrint("kill: {s}: no such process\n", .{pid_str});
            rc = 1;
            continue;
        };
    }
    return rc;
}
