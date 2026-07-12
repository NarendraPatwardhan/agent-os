//! `printenv` -- DESIGN.md §1: the `/env/<name>` file-backed environment
//! model. No operands -> `envfs.list` (sorted), print `NAME=value` lines. With operands
//! -> each set var's trimmed value on its own line; an unset var sets rc=1 with NO
//! message. No `-0`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const envfs = @import("../core/envfs.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "printenv",
    .flags = &.{},
    .help = .{
        .summary = "print environment variables",
        .synopsis = &.{"printenv [VARIABLE]..."},
        .description =
        \\With no VARIABLE, prints every currently-set environment variable as a
        \\`NAME=value` line, one per variable, sorted by name. With one or more
        \\VARIABLE operands, prints each variable's value alone on its own line, in the
        \\order given; an unset VARIABLE is skipped (no line is printed for it, and no
        \\diagnostic is issued), but it makes the exit status 1.
        \\
        \\nutils models the environment as one file per variable, so a value's
        \\trailing newline (if any) is trimmed before printing.
        ,
        .operands = "VARIABLE...   name(s) of variables to print; with none, every set variable is listed.",
        .exit = &.{
            .{ .code = 0, .when = "no VARIABLE was unset (or none was given)" },
            .{ .code = 1, .when = "at least one VARIABLE was not set" },
        },
        .deviations_from = "GNU coreutils printenv",
        .deviations = &.{
            "With no operand, variables are listed in sorted order; GNU printenv preserves the process's own environment order.",
            "No -0/--null.",
        },
        .examples = &.{
            .{ .cmd = "printenv PATH", .note = "PATH's value alone" },
            .{ .cmd = "printenv HOME PATH", .note = "two lines, in that order" },
            .{ .cmd = "printenv", .note = "every set variable, NAME=value, sorted" },
        },
        .see_also = "which (uses PATH), env.",
    },
    .positionals = .{ .name = "VARIABLE", .min = 0, .max = null },
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const ops = m.positionalSlice();

    if (ops.len == 0) {
        const names = envfs.list(ctx.gpa) catch @panic("OOM");
        for (names) |name| {
            const val = envfs.get(ctx.gpa, name) orelse "";
            ctx.outPrint("{s}={s}\n", .{ name, val });
        }
        return 0;
    }

    var rc: u8 = 0;
    for (ops) |name| {
        if (envfs.get(ctx.gpa, name)) |v| {
            ctx.outPrint("{s}\n", .{v});
        } else {
            rc = 1;
        }
    }
    return rc;
}
