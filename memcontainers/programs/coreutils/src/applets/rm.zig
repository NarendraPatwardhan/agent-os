//! `rm` -- docs/analysis/applets-g-r.md: `fsutil.removeRecursive`/`exists`/`isDir` +
//! `sys.unlink`. `-r/-R/--recursive`, `-d/--dir`, `-f/--force` (ignore missing, never
//! prompt, overrides `-i`), `-i` (prompt each), `-v/--verbose` (`removed FILE`).

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "rm",
    .flags = &.{
        cli.flagOpt('r', null, "remove directories and their contents recursively"),
        cli.flagOpt('R', "recursive", "remove directories and their contents recursively"),
        cli.flagOpt('d', "dir", "remove empty directories"),
        cli.flagOpt('f', "force", "ignore nonexistent files, never prompt"),
        cli.flagOpt('i', null, "prompt before every removal"),
        cli.flagOpt('v', "verbose", "explain what is being done"),
    },
    .help = .{
        .summary = "remove files or directories",
        .synopsis = &.{"rm [OPTION]... [FILE]..."},
        .description =
        \\Removes each FILE. A directory is removed only with -r/-R (recursively,
        \\contents before the directory itself) or -d (only if already empty);
        \\otherwise it is an "is a directory" error. -f ignores nonexistent files,
        \\suppresses all prompts, overrides -i, and makes "no operands given" a silent
        \\success instead of an error. -i prompts before every removal (on stderr,
        \\y/N; EOF or any non-y answer skips it).
        ,
        .operands = "FILE...  the paths to remove. With no FILE and without -f, this is a \"missing operand\" error.",
        .exit = &.{
            .{ .code = 0, .when = "success (including -f with no operands)" },
            .{ .code = 1, .when = "missing operand (without -f), a FILE does not exist (without -f), a directory without -r/-R/-d, or a removal error" },
            .{ .code = 2, .when = "usage error (unrecognized option)" },
        },
        .deviations = &.{
            "No -I (single confirmation for 3+ files or recursive removal), --one-file-system, or --preserve-root.",
        },
        .examples = &.{
            .{ .cmd = "rm -f maybe_missing.txt", .note = "never errors, even if the file does not exist" },
            .{ .cmd = "rm -r build/", .note = "recursive removal, contents before the directory" },
            .{ .cmd = "rm -i important.txt", .note = "prompts \"rm: remove important.txt? \" on stderr" },
        },
        .see_also = "rmdir (empty directories only), mkdir.",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const force = m.has("force");
    const recursive = m.has("r") or m.has("recursive");
    const dir_flag = m.has("dir");
    const interactive = m.has("i") and !force;
    const verbose = m.has("verbose");
    const files = m.positionalSlice();

    if (files.len == 0) {
        if (force) return 0;
        ctx.errPrint("rm: missing operand\n", .{});
        return 1;
    }

    var rc: u8 = 0;
    for (files) |path| {
        if (!fsutil.exists(path)) {
            if (force) continue;
            ctx.errPrint("rm: {s}: {s}\n", .{ path, sys.strerror(.ENOENT) });
            rc = 1;
            continue;
        }
        const is_dir = fsutil.isDir(path);
        if (is_dir and !recursive and !dir_flag) {
            ctx.errPrint("rm: {s}: is a directory\n", .{path});
            rc = 1;
            continue;
        }
        if (interactive) {
            if (!cli.confirm(ctx, "rm: remove {s}? ", .{path})) continue;
        }
        const remove_err: ?sys.Error = blk: {
            if (is_dir and recursive) {
                fsutil.removeRecursive(ctx.gpa, path) catch |e| break :blk e;
            } else {
                sys.unlink(path) catch |e| break :blk e;
            }
            break :blk null;
        };
        if (remove_err) |e| {
            ctx.errPrint("rm: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        }
        if (verbose) ctx.outPrint("removed {s}\n", .{path});
    }
    return rc;
}
