//! `readlink` -- DESIGN.md §1: `sys.lstat`/`sys.readlink` +
//! `fsutil.canonicalize`. Default mode is a one-level `readlink(2)` (`null` if the
//! operand isn't a symlink); `-f/-e/-m` switch to full canonicalization with
//! `Existence.parent/all/none` respectively. Errors are SILENT by default; `-v` prints
//! `readlink: {p}: cannot resolve`. Missing operand is a usage error (exit 2).

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "readlink",
    .flags = &.{
        cli.flagOpt('f', "canonicalize", "canonicalize by following every symlink, all but the last component must exist"),
        cli.flagOpt('e', "canonicalize-existing", "canonicalize, all components must exist"),
        cli.flagOpt('m', "canonicalize-missing", "canonicalize, no path components need exist"),
        cli.flagOpt('n', "no-newline", "do not output the trailing newline"),
        cli.flagOpt('z', "zero", "end each output line with NUL, not newline"),
        cli.flagOpt('q', "quiet", "suppress most error messages (default)"),
        cli.flagOpt('s', "silent", "suppress most error messages (default)"),
        cli.flagOpt('v', "verbose", "report error messages"),
    },
    .positionals = .{ .name = "FILE", .min = 1, .max = null },
    .help = .{
        .summary = "print resolved symbolic links or canonical file names",
        .synopsis = &.{"readlink [OPTION]... FILE..."},
        .description =
        \\By default, performs one-level symlink resolution on each FILE: prints
        \\the immediate link target, or fails if FILE is not a symbolic link.
        \\-f/-e/-m instead fully canonicalize FILE (resolving every symlink and
        \\"." / ".." component), differing only in which path components must
        \\exist: -f requires all but the last to exist, -e requires the whole
        \\path to exist, -m requires none of it to exist.
        ,
        .operands = "FILE...   one or more paths to resolve.",
        .exit = &.{
            .{ .code = 0, .when = "every FILE was resolved" },
            .{ .code = 1, .when = "one or more FILEs could not be resolved (reported only with -v)" },
            .{ .code = 2, .when = "usage error: no FILE operand" },
        },
        .examples = &.{
            .{ .cmd = "readlink /etc/resolv.conf", .note = "the immediate link target, or nothing (exit 1) if not a symlink" },
            .{ .cmd = "readlink -v /etc/hostname", .note = "fails with a diagnostic (-v) if the path isn't a symlink" },
            .{ .cmd = "readlink -f ./a/../b/link", .note = "the fully resolved, symlink-free absolute path" },
        },
        .see_also = "realpath (always canonicalizes), basename, dirname.",
    },
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const existence: ?fsutil.Existence = if (m.has("canonicalize"))
        .parent
    else if (m.has("canonicalize-existing"))
        .all
    else if (m.has("canonicalize-missing"))
        .none
    else
        null;

    const sep: []const u8 = if (m.has("zero")) "\x00" else if (m.has("no-newline")) "" else "\n";
    const verbose = m.has("verbose");

    var rc: u8 = 0;
    for (m.positionalSlice()) |file| {
        const resolved: ?[]const u8 = blk: {
            if (existence) |ex| break :blk fsutil.canonicalize(ctx.gpa, file, ex);
            const st = sys.lstat(file) catch break :blk null;
            if (!st.is_symlink) break :blk null;
            var buf: [4096]u8 = undefined;
            const n = sys.readlink(file, &buf) catch break :blk null;
            break :blk ctx.gpa.dupe(u8, buf[0..n]) catch null;
        };
        if (resolved) |r| {
            ctx.outWrite(r) catch return rc;
            ctx.outWrite(sep) catch return rc;
        } else {
            if (verbose) ctx.errPrint("readlink: {s}: cannot resolve\n", .{file});
            rc = 1;
        }
    }
    return rc;
}
