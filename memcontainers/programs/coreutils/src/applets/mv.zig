//! `mv` -- docs/analysis/applets-g-r.md: `sys.rename` + `fsutil` EXDEV fallback.
//! `-f/--force` (no prompt, overrides `-i`/`-n`), `-i/--interactive`, `-n/--no-clobber`,
//! `-v/--verbose` (`SOURCE -> DEST`). `SOURCE... DEST`, >= 2 operands; multi-source
//! needs a directory DEST.

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "mv",
    .flags = &.{
        cli.flagOpt('f', "force", "do not prompt before overwriting"),
        cli.flagOpt('i', "interactive", "prompt before overwrite"),
        cli.flagOpt('n', "no-clobber", "do not overwrite an existing file"),
        cli.flagOpt('v', "verbose", "explain what is being done"),
    },
    .help = .{
        .summary = "move (rename) files and directories",
        .synopsis = &.{
            "mv [OPTION]... SOURCE DEST",
            "mv [OPTION]... SOURCE... DIRECTORY",
        },
        .description =
        \\Renames each SOURCE to DEST, or moves it into DIRECTORY when the last operand
        \\is an existing directory (or more than one SOURCE is given). The move is a
        \\single rename(2) when SOURCE and the destination are on the same filesystem;
        \\across filesystems (EXDEV), mv instead recursively copies SOURCE to the
        \\destination, preserving mtime/atime, then removes SOURCE.
        \\
        \\Overwrite behavior follows GNU precedence: -f always overrides -n, and both
        \\override -i. With none of -f/-n/-i, an existing destination is overwritten
        \\unconditionally.
        ,
        .operands = "SOURCE... DEST/DIRECTORY -- one or more sources followed by a final destination operand. If the destination exists and is a directory, each SOURCE is moved into it as DIRECTORY/basename(SOURCE); with more than one SOURCE, the destination must already be a directory.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "missing operand(s), multiple sources into a non-directory dest, or a rename/copy/remove error" },
            .{ .code = 2, .when = "usage error (unrecognized option or missing option value)" },
        },
        .deviations = &.{
            "No --backup/-b, -u/--update, -t/--target-directory, or -T/--no-target-directory.",
            "Across filesystems (EXDEV), the copy+remove fallback dereferences any symlink inside SOURCE (copying its target's contents, not the link) -- unlike the same-filesystem rename(2) path, which moves symlinks intact.",
        },
        .examples = &.{
            .{ .cmd = "mv a.txt b.txt", .note = "rename" },
            .{ .cmd = "mv -i a.txt existing.txt", .note = "prompts \"mv: overwrite existing.txt? \" on stderr" },
            .{ .cmd = "mv /mnt/a /other-fs/b", .note = "falls back to copy+remove across filesystems (EXDEV); symlinks inside are dereferenced (see DEVIATIONS)" },
        },
        .see_also = "cp (copy instead of move), rm.",
    },
    .positionals = .{ .name = "SOURCE", .min = 0, .max = null },
};

fn moveOne(ctx: *Ctx, src: []const u8, dest: []const u8, no_clobber: bool, interactive: bool, verbose: bool) u8 {
    if (fsutil.exists(dest)) {
        if (no_clobber) return 0;
        if (interactive) {
            if (!cli.confirm(ctx, "mv: overwrite {s}? ", .{dest})) return 0;
        }
    }

    sys.rename(src, dest) catch |e| {
        if (e == error.EXDEV) {
            fsutil.copyRecursive(ctx.gpa, src, dest) catch |ce| {
                ctx.errPrint("mv: {s}: {s}\n", .{ src, sys.strerror(sys.toErrno(ce)) });
                return 1;
            };
            fsutil.preserveMeta(ctx.gpa, src, dest, true);
            fsutil.removeRecursive(ctx.gpa, src) catch |re| {
                ctx.errPrint("mv: {s}: {s}\n", .{ src, sys.strerror(sys.toErrno(re)) });
                return 1;
            };
        } else {
            ctx.errPrint("mv: {s}: {s}\n", .{ src, sys.strerror(sys.toErrno(e)) });
            return 1;
        }
    };

    if (verbose) ctx.outPrint("{s} -> {s}\n", .{ src, dest });
    return 0;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const paths = m.positionalSlice();
    if (paths.len == 0) {
        ctx.errPrint("mv: missing operand\n", .{});
        return 1;
    }
    if (paths.len == 1) {
        ctx.errPrint("mv: missing destination file operand after '{s}'\n", .{paths[0]});
        return 1;
    }

    const cm = cli.clobberMode(m);
    const no_clobber = cm.no_clobber;
    const interactive = cm.interactive;
    const verbose = m.has("verbose");

    const sources = paths[0 .. paths.len - 1];
    const dest = paths[paths.len - 1];

    if (sources.len > 1 and !fsutil.isDir(dest)) {
        ctx.errPrint("mv: {s}: not a directory\n", .{dest});
        return 1;
    }

    var rc: u8 = 0;
    for (sources) |src| {
        const eff_dest = fsutil.destIntoDir(ctx.gpa, dest, src) catch dest;
        const r = moveOne(ctx, src, eff_dest, no_clobber, interactive, verbose);
        if (r != 0) rc = r;
    }
    return rc;
}
