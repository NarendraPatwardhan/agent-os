//! `nohup` -- DESIGN.md §1: no flags of its own (`--help`/`-h` first
//! arg only); `COMMAND [ARG]...` passed verbatim. `sys.sigdisp(SIGHUP, ignore)` first.
//! If `isatty(stdout)`: open/create/append `nohup.out` in the cwd, print
//! `nohup: ignoring input and appending output to 'nohup.out'` to STDERR, and route the
//! child's stdout there; if `isatty(stderr)`, stderr follows stdout's destination
//! (whatever that now is). Spawn NUL blob + EINTR-retried waitpid. Exit: COMMAND's
//! status; 125 own failures (missing operand, nohup.out open failure, sigdisp/wait
//! failure -- the clap-usage exit is also 125); 127 command not runnable
//! (`nohup: {cmd}: <strerror>`). The isatty(stdout) branch is unit-test-only territory
//! under the parity runner (stdio is always pipes there), per DESIGN.md §1.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const proc = @import("../core/proc.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "run a command immune to hangups, redirecting output if it's a terminal",
    .synopsis = &.{"nohup COMMAND [ARG]..."},
    .description =
    \\Runs COMMAND with SIGHUP ignored, so it keeps running after the invoking
    \\terminal session ends. If standard output is a terminal, output is
    \\instead appended to "nohup.out" in the current directory (created if
    \\needed), and a notice is printed to standard error; if standard error is
    \\also a terminal, it follows standard output to the same destination.
    \\Otherwise stdout/stderr are left exactly as given (e.g. already piped or
    \\redirected).
    ,
    .options_note = "nohup takes no options of its own; --help/-h and --version are honored only as the first argument.",
    .operands = "COMMAND [ARG]... the program to run; required.",
    .exit = &.{
        .{ .code = 0, .when = "COMMAND ran and exited 0" },
        .{ .code = 125, .when = "own failure: no COMMAND given, SIGHUP could not be ignored, nohup.out could not be opened, or waiting on COMMAND failed" },
        .{ .code = 127, .when = "COMMAND could not be run (not found, or any other spawn failure)" },
    },
    .deviations_from = "GNU coreutils nohup",
    .deviations = &.{
        "Any spawn failure (not just \"command not found\") is reported as exit 127; GNU nohup distinguishes 126 (found but not executable) from 127 (not found).",
    },
    .examples = &.{
        .{ .cmd = "nohup ./long_job.sh &", .note = "keep running after the shell exits" },
        .{ .cmd = "nohup make > build.log 2>&1 &", .note = "output already redirected, so nohup.out is never created" },
    },
    .see_also = "nice, timeout.",
};

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "nohup", "0.1.0", help_doc)) return 0;
    const args = ctx.args[1..];
    if (args.len == 0) {
        ctx.errPrint("nohup: missing operand\n", .{});
        return 125;
    }

    sys.sigdisp(.hup, .ignore) catch return 125;

    var out_fd = ctx.stdout;
    if (sys.isatty(ctx.stdout)) {
        const fd = sys.open("nohup.out", .{ .write = true, .create = true, .append = true }) catch |e| {
            ctx.errPrint("nohup: nohup.out: {s}\n", .{sys.strerror(sys.toErrno(e))});
            return 125;
        };
        ctx.errPrint("nohup: ignoring input and appending output to 'nohup.out'\n", .{});
        out_fd = fd;
    }
    var err_fd = ctx.stderr;
    if (sys.isatty(ctx.stderr)) err_fd = out_fd;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    for (args) |a| argv.append(ctx.gpa, a) catch @panic("OOM");
    const blob = proc.argvBlob(ctx.gpa, argv.items) catch @panic("OOM");
    switch (proc.spawnWait(blob, ctx.stdin, out_fd, err_fd)) {
        .status => |st| return proc.statusToExit(st),
        .spawn_err => |e| {
            ctx.errPrint("nohup: {s}: {s}\n", .{ args[0], sys.strerror(sys.toErrno(e)) });
            return 127;
        },
        .wait_err => return 125,
    }
}
