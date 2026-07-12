//! `realpath` -- DESIGN.md §1: `fsutil.canonicalize`/`lexicalAbs`.
//! Default existence mode is `.parent`; `-e`/`-m` switch to `.all`/`.none`; `-s/--strip`
//! bypasses symlink resolution entirely (`lexicalAbs`, which never fails). On failure,
//! unless `-q`, re-probes with `lstat` to report `ELOOP` (path exists but couldn't be
//! canonicalized -- a symlink loop) vs. whatever errno `lstat` itself hit.

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "realpath",
    .flags = &.{
        cli.flagOpt('e', "canonicalize-existing", "all components of the path must exist"),
        cli.flagOpt('m', "canonicalize-missing", "no path components need exist"),
        cli.flagOpt('s', "strip", "do not expand symlinks"),
        cli.flagOpt('z', "zero", "end each output line with NUL, not newline"),
        cli.flagOpt('q', "quiet", "suppress most error messages"),
    },
    .positionals = .{ .name = "FILE", .min = 1, .max = null },
    .help = .{
        .summary = "print the resolved absolute file name",
        .synopsis = &.{"realpath [OPTION]... FILE..."},
        .description =
        \\Canonicalizes each FILE: resolves every symbolic link and "." / ".."
        \\component, printing the resulting absolute path. The default existence
        \\mode requires every component but the last to exist; -e requires the
        \\whole path to exist, -m requires none of it to. -s/--strip instead
        \\resolves FILE purely lexically, without touching the filesystem or
        \\ever failing.
        ,
        .operands = "FILE...   one or more paths to resolve.",
        .exit = &.{
            .{ .code = 0, .when = "every FILE was resolved" },
            .{ .code = 1, .when = "one or more FILEs could not be resolved (a diagnostic is printed unless -q)" },
            .{ .code = 2, .when = "usage error: no FILE operand" },
        },
        .deviations = &.{
            "--relative-to=DIR and --relative-base=DIR are not implemented; output is always an absolute path.",
        },
        .examples = &.{
            .{ .cmd = "realpath ./a/../b", .note = "the fully resolved absolute path" },
            .{ .cmd = "realpath -e /no/such/path", .note = "fails (exit 1): -e requires the whole path to exist" },
            .{ .cmd = "realpath -s /a/../b/./c", .note = "prints: /b/c -- lexical only, never touches the filesystem" },
        },
        .see_also = "readlink (one-level or canonicalizing), basename, dirname.",
    },
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const existence: fsutil.Existence = if (m.has("canonicalize-existing"))
        .all
    else if (m.has("canonicalize-missing"))
        .none
    else
        .parent;
    const strip = m.has("strip");
    const sep: []const u8 = if (m.has("zero")) "\x00" else "\n";
    const quiet = m.has("quiet");

    var rc: u8 = 0;
    for (m.positionalSlice()) |file| {
        const resolved: ?[]const u8 = if (strip)
            (fsutil.lexicalAbs(ctx.gpa, file) catch null)
        else
            fsutil.canonicalize(ctx.gpa, file, existence);

        if (resolved) |r| {
            ctx.outWrite(r) catch return rc;
            ctx.outWrite(sep) catch return rc;
            continue;
        }

        rc = 1;
        if (quiet) continue;
        const errno: sys.Errno = blk2: {
            _ = sys.lstat(file) catch |e| break :blk2 sys.toErrno(e);
            break :blk2 .ELOOP;
        };
        ctx.errPrint("realpath: {s}: {s}\n", .{ file, sys.strerror(errno) });
    }
    return rc;
}
