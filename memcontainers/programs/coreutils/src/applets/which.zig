//! `which` -- DESIGN.md §1: `-a/--all`; `NAME...` (1+). A NAME
//! containing `/` is checked literally via `fsutil.exists`; otherwise `/env/PATH` is
//! split on `:` and joined with NAME, first match wins (all matches with `-a`). Match =
//! `exists()` (no exec-bit test). Exit 0 all found / 1 any missing / 2 no operand
//! (handled by `cli.zig`'s positional-minimum check).

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const envfs = @import("../core/envfs.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "which",
    .flags = &.{
        cli.flagOpt('a', "all", "print all matching pathnames of each argument"),
    },
    .help = .{
        .summary = "locate a command in PATH",
        .synopsis = &.{"which [-a] NAME..."},
        .description =
        \\Prints the path nutils would run for each NAME. A NAME containing a `/` is
        \\checked literally (no PATH search); otherwise each directory in the `PATH`
        \\environment variable is tried in order, joined with NAME, and the first
        \\existing path wins. With -a, every matching directory is printed instead of
        \\just the first.
        \\
        \\A "match" is any existing path -- there is no executable-bit check, so a
        \\non-executable regular file named NAME still counts as found.
        ,
        .operands = "NAME...   command name(s) to look up; at least one is required.",
        .exit = &.{
            .{ .code = 0, .when = "every NAME was found" },
            .{ .code = 1, .when = "at least one NAME was not found" },
            .{ .code = 2, .when = "no NAME operand was given" },
        },
        .deviations_from = "GNU which",
        .deviations = &.{
            "A match is any existing path, not necessarily an executable one -- GNU which requires the executable bit.",
            "No --skip-dot/--skip-tilde/--show-dot/--show-tilde/--tty-only, and no alias/shell-function support (--read-alias/--read-functions/--skip-alias/--skip-functions).",
        },
        .examples = &.{
            .{ .cmd = "which sed", .note = "the first PATH match" },
            .{ .cmd = "which -a python3", .note = "every PATH match, not just the first" },
        },
        .see_also = "printenv (inspect PATH).",
    },
    .positionals = .{ .name = "NAME", .min = 1, .max = null },
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const all = m.has("all");

    var rc: u8 = 0;
    for (m.positionalSlice()) |name| {
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            if (fsutil.exists(name)) {
                ctx.outPrint("{s}\n", .{name});
            } else {
                rc = 1;
            }
            continue;
        }

        const path_val = envfs.get(ctx.gpa, "PATH") orelse "";
        const dirs = envfs.pathDirs(ctx.gpa, path_val) catch @panic("OOM");
        var found = false;
        for (dirs) |dir| {
            const candidate = fsutil.join(ctx.gpa, dir, name) catch @panic("OOM");
            if (fsutil.exists(candidate)) {
                ctx.outPrint("{s}\n", .{candidate});
                found = true;
                if (!all) break;
            }
        }
        if (!found) rc = 1;
    }
    return rc;
}
