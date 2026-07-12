//! `env` -- DESIGN.md §1: file-backed environment (`/env/<NAME>`,
//! DESIGN.md §4.3). `-i`/`--ignore-environment` (clear /env), `-u NAME`/`--unset`
//! (repeatable), `-C DIR`/`--chdir`. Trailing args captured raw (clap
//! `trailing_var_arg`+`allow_hyphen_values` semantics -- hand-parsed here): leading
//! `NAME=VALUE` tokens are assignments written to `/env/<NAME>`, the first token
//! without `=` begins COMMAND (rest passthrough verbatim; an unknown leading dash-opt
//! is taken as COMMAND start -- use `--`). No COMMAND -> sorted `NAME=VALUE` listing,
//! exit 0. `-C` failure -> `env: cannot change directory to {dir}: {strerror}` exit
//! 125. Spawn: NUL blob -> sys.spawn + EINTR-retried waitpid; child status; wait
//! failure -> 1; ENOENT -> `env: {cmd}: No such file or directory` 127; other spawn
//! error -> 126. Usage (missing option value) -> 2, clap convention.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const envfs = @import("../core/envfs.zig");
const fsutil = @import("../core/fsutil.zig");
const proc = @import("../core/proc.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "run a command in a modified environment, or print the environment",
    .synopsis = &.{"env [OPTION]... [NAME=VALUE]... [COMMAND [ARG]...]"},
    .description =
    \\Runs COMMAND with the environment modified by any preceding NAME=VALUE
    \\assignments, -i/--ignore-environment (start from an empty environment),
    \\and -u/--unset NAME (drop one variable, repeatable). With no COMMAND,
    \\prints the resulting environment as sorted NAME=VALUE lines instead of
    \\running anything. -C/--chdir DIR changes the working directory first.
    \\
    \\Argument parsing stops at the first token without an "=": that token and
    \\everything after it becomes COMMAND, passed through verbatim. An
    \\unrecognized dash-leading token is also treated as the start of COMMAND,
    \\so use "--" before a COMMAND name that itself begins with "-".
    ,
    .options = &.{
        .{ .flags = "-i, --ignore-environment", .desc = "start COMMAND with an empty environment" },
        .{ .flags = "-u, --unset=NAME", .desc = "remove NAME from the environment (repeatable)" },
        .{ .flags = "-C, --chdir=DIR", .desc = "change working directory to DIR before running COMMAND" },
    },
    .operands = "NAME=VALUE... leading assignments applied before COMMAND runs. COMMAND [ARG]... the program to run; if omitted, the environment is printed instead.",
    .exit = &.{
        .{ .code = 0, .when = "no COMMAND: environment printed; with COMMAND: its own exit status, here 0" },
        .{ .code = 1, .when = "an assignment failed, or waiting on COMMAND failed" },
        .{ .code = 2, .when = "usage error: a missing -u/-C value" },
        .{ .code = 125, .when = "-C failed to change directory" },
        .{ .code = 126, .when = "COMMAND was found but could not be executed" },
        .{ .code = 127, .when = "COMMAND could not be found" },
    },
    .deviations_from = "GNU coreutils env",
    .deviations = &.{
        "There is no -0/--null (NUL-terminated listing), -S/--split-string, -v/--debug, or signal-blocking options.",
        "An unrecognized leading dash-option is silently treated as the start of COMMAND rather than reported as an error (use -- to disambiguate).",
    },
    .examples = &.{
        .{ .cmd = "env", .note = "print every NAME=VALUE" },
        .{ .cmd = "env FOO=bar printenv FOO", .note = "run printenv with FOO set for just this invocation" },
        .{ .cmd = "env -i PATH=/bin sh -c 'echo $PATH'", .note = "run with a minimal, otherwise-empty environment" },
    },
    .see_also = "nice, nohup, time, timeout (the other command-running applets).",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn run(ctx: *Ctx) u8 {
    const args = ctx.args[1..];

    var clear_env = false;
    var unsets: std.ArrayListUnmanaged([]const u8) = .empty;
    var chdir_to: ?[]const u8 = null;
    var rest: []const [:0]const u8 = &.{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--help")) {
            cli.renderHelp(ctx, "env", help_doc);
            return 0;
        }
        if (eq(a, "--version")) {
            ctx.outPrint("env 0.1.0\n", .{});
            return 0;
        }
        if (eq(a, "-i") or eq(a, "--ignore-environment")) {
            clear_env = true;
            continue;
        }
        if (eq(a, "-u") or eq(a, "--unset")) {
            i += 1;
            if (i >= args.len) {
                ctx.errPrint("env: option '--unset' requires a value\n", .{});
                return 2;
            }
            unsets.append(ctx.gpa, args[i]) catch @panic("OOM");
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-u")) {
            unsets.append(ctx.gpa, a[2..]) catch @panic("OOM");
            continue;
        }
        if (std.mem.startsWith(u8, a, "--unset=")) {
            unsets.append(ctx.gpa, a["--unset=".len..]) catch @panic("OOM");
            continue;
        }
        if (eq(a, "-C") or eq(a, "--chdir")) {
            i += 1;
            if (i >= args.len) {
                ctx.errPrint("env: option '--chdir' requires a value\n", .{});
                return 2;
            }
            chdir_to = args[i];
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-C")) {
            chdir_to = a[2..];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--chdir=")) {
            chdir_to = a["--chdir=".len..];
            continue;
        }
        if (eq(a, "--")) {
            rest = args[i + 1 ..];
            break;
        }
        // First operand (including any unrecognized dash token -- allow_hyphen_values
        // + trailing_var_arg means it starts the trailing ARGS).
        rest = args[i..];
        break;
    }

    if (clear_env) {
        const names = envfs.list(ctx.gpa) catch &.{};
        for (names) |name| envfs.unset(name) catch {};
    }
    for (unsets.items) |name| envfs.unset(name) catch {};

    if (chdir_to) |dir| {
        sys.chdir(dir) catch |e| {
            ctx.errPrint("env: cannot change directory to {s}: {s}\n", .{ dir, sys.strerror(sys.toErrno(e)) });
            return 125;
        };
    }

    // Leading NAME=VALUE assignments; first token without '=' starts COMMAND.
    var ci: usize = 0;
    while (ci < rest.len) : (ci += 1) {
        const tok = rest[ci];
        const eq_idx = std.mem.indexOfScalar(u8, tok, '=') orelse break;
        envfs.set(tok[0..eq_idx], tok[eq_idx + 1 ..]) catch |e| {
            ctx.errPrint("env: {s}: {s}\n", .{ tok[0..eq_idx], sys.strerror(sys.toErrno(e)) });
            return 1;
        };
    }
    const command = rest[ci..];

    if (command.len == 0) {
        // Sorted NAME=VALUE listing of the (post-mutation) environment.
        var out = textio.BufOut.init(ctx.stdout);
        const names = envfs.list(ctx.gpa) catch &.{};
        for (names) |name| {
            const value = envfs.get(ctx.gpa, name) orelse "";
            out.extend(name) catch return 0;
            out.push('=') catch return 0;
            out.line(value) catch return 0;
        }
        out.finish() catch {};
        return 0;
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    for (command) |a| argv.append(ctx.gpa, a) catch @panic("OOM");
    const blob = proc.argvBlob(ctx.gpa, argv.items) catch @panic("OOM");
    switch (proc.spawnWait(blob, ctx.stdin, ctx.stdout, ctx.stderr)) {
        .status => |st| return proc.statusToExit(st),
        .spawn_err => |e| {
            if (e == error.ENOENT) {
                ctx.errPrint("env: {s}: No such file or directory\n", .{command[0]});
                return 127;
            }
            ctx.errPrint("env: {s}: {s}\n", .{ command[0], sys.strerror(sys.toErrno(e)) });
            return 126;
        },
        .wait_err => return 1,
    }
}
