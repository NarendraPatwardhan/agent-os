//! `cp` -- docs/analysis/applets-a-f.md: copy engine is entirely `core/fsutil.zig`.
//! `-r/-R/--recursive`; `-a/--archive` (= `-R -p` + symlink-recreate); `-p/--preserve`
//! (mtime/atime; mode is always copied via `preserveMeta`); `-n/--no-clobber`;
//! `-i/--interactive`; `-f/--force` (unlink+retry on an undeletable dest); `-v/--verbose`.
//!
//! Flag precedence (must be exact): `-f` overrides `-n`, both override `-i`:
//! `no_clobber = n && !f`, `interactive = i && !no_clobber && !f`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "cp",
    .flags = &.{
        cli.flagOpt('r', null, "copy directories recursively"),
        cli.flagOpt('R', "recursive", "copy directories recursively"),
        cli.flagOpt('a', "archive", "same as -R -p, and recreate symlinks"),
        cli.flagOpt('p', "preserve", "preserve mode, mtime, atime"),
        cli.flagOpt('n', "no-clobber", "do not overwrite an existing file"),
        cli.flagOpt('i', "interactive", "prompt before overwrite"),
        cli.flagOpt('f', "force", "if an existing dest file cannot be opened, remove it and retry"),
        cli.flagOpt('v', "verbose", "explain what is being done"),
    },
    .help = .{
        .summary = "copy files and directories",
        .synopsis = &.{
            "cp [OPTION]... SOURCE DEST",
            "cp [OPTION]... SOURCE... DIRECTORY",
        },
        .description =
        \\Copies each SOURCE to DEST, or into DIRECTORY when the last operand is an
        \\existing directory (or more than one SOURCE is given). Plain files are copied
        \\byte-for-byte; SOURCE directories require -r/-R (or -a) and are copied
        \\recursively. File mode is always copied to the destination; -p additionally
        \\preserves mtime and atime. -a is short for -R -p plus recreating symlinks
        \\instead of following them.
        \\
        \\Overwrite behavior follows GNU precedence: -f always overrides -n, and both
        \\override -i. With none of -f/-n/-i, an existing DEST is overwritten
        \\unconditionally.
        ,
        .operands = "SOURCE... DEST/DIRECTORY -- one or more sources followed by a final destination operand. If the destination exists and is a directory, each SOURCE is copied into it as DIRECTORY/basename(SOURCE); with more than one SOURCE, the destination must already be a directory.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "missing operand(s), a SOURCE does not exist, a SOURCE is a directory without -r/-R/-a, a directory-into-itself, multiple sources into a non-directory dest, or a copy error" },
            .{ .code = 2, .when = "usage error (unrecognized option or missing option value)" },
        },
        .deviations = &.{
            "cp -r/-R (without -a) dereferences symlinks found anywhere in the source tree, copying their targets as regular files/directories; GNU cp recreates them as symlinks by default during a recursive copy (use -a here for that effect).",
            "No --backup/-b, -u/--update, -l/--link, -s/--reflink, --sparse, -t/--target-directory, or -T/--no-target-directory.",
            "Only mode is preserved by default; -p adds mtime/atime. Owner, group, and extended attributes are never preserved.",
        },
        .examples = &.{
            .{ .cmd = "cp -r src/ dst/", .note = "recursive directory copy (errors on a directory SOURCE without -r/-R/-a)" },
            .{ .cmd = "cp -a src/ dst/", .note = "= -R -p, and symlinks are recreated rather than followed" },
            .{ .cmd = "cp -i a.txt b.txt", .note = "prompts \"cp: overwrite b.txt? \" on stderr; EOF or a non-y answer skips the copy" },
        },
        .see_also = "mv (move instead of copy), rm.",
    },
    .positionals = .{ .name = "PATHS", .min = 0, .max = null },
};

const Opts = struct {
    recursive: bool,
    archive: bool,
    preserve: bool,
    no_clobber: bool,
    interactive: bool,
    force: bool,
    verbose: bool,
};

fn copyOne(ctx: *Ctx, src: []const u8, dest: []const u8, o: Opts) u8 {
    if (!fsutil.exists(src)) {
        ctx.errPrint("cp: {s}: {s}\n", .{ src, sys.strerror(.ENOENT) });
        return 1;
    }

    if (fsutil.exists(dest)) {
        if (o.no_clobber) return 0;
        if (o.interactive) {
            if (!cli.confirm(ctx, "cp: overwrite {s}? ", .{dest})) return 0;
        }
    }

    const src_is_dir = fsutil.isDir(src);

    if (src_is_dir and (o.recursive or o.archive)) {
        if (fsutil.sameOrDescendant(ctx.gpa, src, dest)) {
            ctx.errPrint("cp: cannot copy a directory into itself\n", .{});
            return 1;
        }
    }

    if (o.archive) {
        fsutil.copyTree(ctx.gpa, src, dest, false) catch |e| {
            ctx.errPrint("cp: {s}: {s}\n", .{ src, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
    } else if (src_is_dir) {
        if (!o.recursive) {
            ctx.errPrint("cp: {s}: is a directory (use -r)\n", .{src});
            return 1;
        }
        fsutil.copyRecursive(ctx.gpa, src, dest) catch |e| {
            ctx.errPrint("cp: {s}: {s}\n", .{ src, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
    } else {
        var ok = true;
        fsutil.copyFile(src, dest) catch |e1| {
            ok = false;
            if (o.force) {
                sys.unlink(dest) catch {};
                fsutil.copyFile(src, dest) catch |e2| {
                    ctx.errPrint("cp: {s}: {s}\n", .{ src, sys.strerror(sys.toErrno(e2)) });
                    return 1;
                };
                ok = true;
            } else {
                ctx.errPrint("cp: {s}: {s}\n", .{ src, sys.strerror(sys.toErrno(e1)) });
            }
        };
        if (!ok) return 1;
    }

    if (o.verbose) ctx.outPrint("{s} -> {s}\n", .{ src, dest });
    fsutil.preserveMeta(ctx.gpa, src, dest, o.preserve);
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
        ctx.errPrint("cp: missing operand\n", .{});
        return 1;
    }
    if (paths.len == 1) {
        ctx.errPrint("cp: missing destination file operand after '{s}'\n", .{paths[0]});
        return 1;
    }

    const cm = cli.clobberMode(m);
    const force = cm.force;
    const no_clobber = cm.no_clobber;
    const interactive = cm.interactive;
    const archive = m.has("archive");
    const preserve = m.has("preserve") or archive;
    const recursive = m.has("r") or m.has("recursive") or archive;
    const verbose = m.has("verbose");

    const sources = paths[0 .. paths.len - 1];
    const dest = paths[paths.len - 1];

    if (sources.len > 1 and !fsutil.isDir(dest)) {
        ctx.errPrint("cp: {s}: not a directory\n", .{dest});
        return 1;
    }

    const o = Opts{
        .recursive = recursive,
        .archive = archive,
        .preserve = preserve,
        .no_clobber = no_clobber,
        .interactive = interactive,
        .force = force,
        .verbose = verbose,
    };

    var rc: u8 = 0;
    for (sources) |src| {
        const eff_dest = fsutil.destIntoDir(ctx.gpa, dest, src) catch dest;
        const r = copyOne(ctx, src, eff_dest, o);
        if (r != 0) rc = r;
    }
    return rc;
}
