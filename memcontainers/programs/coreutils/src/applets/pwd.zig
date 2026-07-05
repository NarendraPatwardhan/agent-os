//! `pwd` -- docs/analysis/applets-g-r.md: `sys.getcwd` + `/env/PWD` + `fsutil.canonicalize`.
//! `-L/--logical`, `-P/--physical` (default; `-P` wins if both given). `-L` accepts
//! `/env/PWD` only if it's absolute, has no `.`/`..` component, and
//! `canonicalize(pwd, .all) == physical cwd`; otherwise falls back to physical. No
//! positional operands.

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const envfs = @import("../core/envfs.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "pwd",
    .flags = &.{
        cli.flagOpt('L', "logical", "print the value of $PWD if it names the current directory"),
        cli.flagOpt('P', "physical", "print the physical directory, without symlinks (default)"),
    },
    .positionals = .{ .name = "", .min = 0, .max = 0 },
    .help = .{
        .summary = "print the name of the current/working directory",
        .synopsis = &.{"pwd [OPTION]..."},
        .description =
        \\Prints the absolute path of the current working directory, followed by
        \\a newline. -P (the default, and the winner if both are given) prints
        \\the physical path read straight from the kernel, with no symbolic
        \\links. -L instead honors $PWD from the environment, but only if it is
        \\an absolute path with no "." or ".." component and it canonicalizes to
        \\the same directory as the physical cwd; otherwise it silently falls
        \\back to -P.
        ,
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "the current directory could not be determined" },
            .{ .code = 2, .when = "usage error: an operand was given (pwd takes none)" },
        },
        .examples = &.{
            .{ .cmd = "pwd", .note = "the physical current directory" },
            .{ .cmd = "pwd -L", .note = "honors $PWD when it agrees with the physical cwd" },
        },
        .see_also = "cd (shell builtin), realpath.",
    },
};

/// No component of `path` may be `.` or `..` (used to sanity-check `/env/PWD`).
fn hasDotComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return true;
    }
    return false;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var cwd_buf: [4096]u8 = undefined;
    const n = sys.getcwd(&cwd_buf) catch |e| {
        ctx.errPrint("pwd: {s}\n", .{sys.strerror(sys.toErrno(e))});
        return 1;
    };
    var physical = cwd_buf[0..n];
    if (physical.len > 0 and physical[physical.len - 1] == 0) physical = physical[0 .. physical.len - 1];

    const logical = m.has("logical") and !m.has("physical");
    var out_path: []const u8 = physical;

    if (logical) {
        if (envfs.get(ctx.gpa, "PWD")) |pwd_val| {
            if (pwd_val.len > 0 and pwd_val[0] == '/' and !hasDotComponent(pwd_val)) {
                if (fsutil.canonicalize(ctx.gpa, pwd_val, .all)) |canon| {
                    if (std.mem.eql(u8, canon, physical)) out_path = pwd_val;
                }
            }
        }
    }

    ctx.outPrint("{s}\n", .{out_path});
    return 0;
}
