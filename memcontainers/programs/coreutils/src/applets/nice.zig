//! `nice` -- DESIGN.md §1: hand-parsed option grammar (`-n N`, `-nN`,
//! `--adjustment=N`, `--adjustment N`, legacy bare `-N`; default adjustment +10).
//! `--help`/`-h` honored only as the FIRST argument; option parsing stops at the first
//! operand. No COMMAND -> print current niceness (`sys.nice(0)`), exit 0. Otherwise
//! `sys.nice(adj)` (failure or unparsable adjustment -> `nice: invalid adjustment`,
//! exit 125), then NUL argv blob -> spawn + EINTR-retried waitpid. Exit: COMMAND's
//! status; 1 wait failure; 125 bad adjustment; 126 spawn error; 127 ENOENT
//! (`nice: {cmd}: No such file or directory`).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const proc = @import("../core/proc.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "run a command with adjusted scheduling priority",
    .synopsis = &.{"nice [-n ADJUSTMENT] [COMMAND [ARG]...]"},
    .description =
    \\Runs COMMAND with its niceness adjusted by ADJUSTMENT (default +10, lower
    \\priority) relative to nice's own niceness. The adjustment may be given
    \\as -n ADJUSTMENT, -nADJUSTMENT, --adjustment=ADJUSTMENT, or the legacy
    \\bare form -ADJUSTMENT (e.g. -5 means +5; --5 means -5). Option parsing
    \\stops at the first operand, which starts COMMAND. With no COMMAND,
    \\prints the current niceness and exits.
    ,
    .options = &.{
        .{ .flags = "-n, --adjustment=ADJUSTMENT", .desc = "add ADJUSTMENT to niceness (default 10)" },
    },
    .operands = "COMMAND [ARG]... the program to run at the adjusted niceness; if omitted, the current niceness is printed instead.",
    .exit = &.{
        .{ .code = 0, .when = "no COMMAND: current niceness printed; with COMMAND: its own exit status, here 0" },
        .{ .code = 1, .when = "waiting on COMMAND failed" },
        .{ .code = 125, .when = "ADJUSTMENT could not be parsed, or the niceness call itself failed" },
        .{ .code = 126, .when = "COMMAND was found but could not be executed" },
        .{ .code = 127, .when = "COMMAND could not be found" },
    },
    .examples = &.{
        .{ .cmd = "nice sort bigfile.txt", .note = "run sort at the default +10 adjustment" },
        .{ .cmd = "nice -n 5 gzip data.tar", .note = "run gzip niced by +5" },
        .{ .cmd = "nice", .note = "print the current niceness" },
    },
    .see_also = "renice, timeout, nohup.",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseAdj(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, s, 10) catch null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Legacy `-N` form: `-10` -> +10, `--10` -> -10 (a leading `-` inside N).
fn legacyAdj(a: []const u8) ?i32 {
    if (a.len < 2 or a[0] != '-') return null;
    var body = a[1..];
    if (body[0] == '-') {
        if (body.len < 2 or !isDigit(body[1])) return null;
    } else if (!isDigit(body[0])) {
        return null;
    }
    body = a[1..];
    return parseAdj(body);
}

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "nice", "0.1.0", help_doc)) return 0;
    const args = ctx.args[1..];

    var adj: ?i32 = null;
    var bad_adjustment = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "-n") or eq(a, "--adjustment")) {
            i += 1;
            if (i >= args.len) {
                bad_adjustment = true;
                break;
            }
            adj = parseAdj(args[i]) orelse {
                bad_adjustment = true;
                break;
            };
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-n") and !std.mem.startsWith(u8, a, "--")) {
            adj = parseAdj(a[2..]) orelse {
                bad_adjustment = true;
                break;
            };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--adjustment=")) {
            adj = parseAdj(a["--adjustment=".len..]) orelse {
                bad_adjustment = true;
                break;
            };
            continue;
        }
        if (legacyAdj(a)) |v| {
            adj = v;
            continue;
        }
        break; // first operand -- COMMAND starts here
    }

    if (bad_adjustment) {
        ctx.errPrint("nice: invalid adjustment\n", .{});
        return 125;
    }

    const command = args[i..];
    if (command.len == 0) {
        const cur = sys.nice(0) catch {
            ctx.errPrint("nice: invalid adjustment\n", .{});
            return 125;
        };
        ctx.outPrint("{d}\n", .{cur});
        return 0;
    }

    _ = sys.nice(adj orelse 10) catch {
        ctx.errPrint("nice: invalid adjustment\n", .{});
        return 125;
    };

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    for (command) |a| argv.append(ctx.gpa, a) catch @panic("OOM");
    const blob = proc.argvBlob(ctx.gpa, argv.items) catch @panic("OOM");
    switch (proc.spawnWait(blob, ctx.stdin, ctx.stdout, ctx.stderr)) {
        .status => |st| return proc.statusToExit(st),
        .spawn_err => |e| {
            if (e == error.ENOENT) {
                ctx.errPrint("nice: {s}: No such file or directory\n", .{command[0]});
                return 127;
            }
            ctx.errPrint("nice: {s}: {s}\n", .{ command[0], sys.strerror(sys.toErrno(e)) });
            return 126;
        },
        .wait_err => return 1,
    }
}
