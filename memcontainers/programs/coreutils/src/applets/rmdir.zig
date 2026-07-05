//! `rmdir` -- docs/analysis/applets-g-r.md: `sys.unlink` (kernel removes empty dirs)
//! + `fsutil.isDir`. `-p/--parents` walks up unlinking now-empty ancestors until a
//! non-dir/failure/root/`.`  is hit (silently stopping, not an error).

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "rmdir",
    .flags = &.{cli.flagOpt('p', "parents", "remove DIRECTORY and its ancestors")},
    .help = .{
        .summary = "remove empty directories",
        .synopsis = &.{"rmdir [OPTION]... DIRECTORY..."},
        .description =
        \\Removes each DIRECTORY if it is empty; a non-empty directory is left alone
        \\and reported as an error ("Directory not empty", from the kernel). -p
        \\additionally removes each now-empty ancestor, walking up from DIRECTORY until
        \\it hits a non-empty one, ".", "/", or a failure -- none of which is reported
        \\as an error.
        ,
        .operands = "DIRECTORY...  the (empty) directories to remove.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "missing operand, a DIRECTORY that is not a directory, or a removal error (e.g. not empty)" },
            .{ .code = 2, .when = "usage error (unrecognized option)" },
        },
        .deviations = &.{
            "No --ignore-fail-on-non-empty or -v/--verbose.",
        },
        .examples = &.{
            .{ .cmd = "rmdir empty_dir", .note = "fails with \"Directory not empty\" if it isn't" },
            .{ .cmd = "rmdir -p a/b/c", .note = "also removes a/b and a if they became empty; stops silently at the first non-empty ancestor" },
        },
        .see_also = "rm -r (non-empty directories), mkdir.",
    },
    .positionals = .{ .name = "DIRECTORY", .min = 0, .max = null },
};

fn dirOf(path: []const u8) []const u8 {
    var s = path;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    const idx = std.mem.lastIndexOfScalar(u8, s, '/') orelse return ".";
    var parent = s[0..idx];
    while (parent.len > 1 and parent[parent.len - 1] == '/') parent = parent[0 .. parent.len - 1];
    if (parent.len == 0) return "/";
    return parent;
}

/// Walks up removing now-empty ancestors; stops silently on the first failure, `.`,
/// or `/`.
fn removeParents(dir: []const u8) void {
    var cur = dirOf(dir);
    while (true) {
        if (cur.len == 0 or std.mem.eql(u8, cur, ".") or std.mem.eql(u8, cur, "/")) return;
        sys.unlink(cur) catch return;
        cur = dirOf(cur);
    }
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const dirs = m.positionalSlice();
    if (dirs.len == 0) {
        ctx.errPrint("rmdir: missing operand\n", .{});
        return 1;
    }

    var rc: u8 = 0;
    for (dirs) |dir| {
        if (!fsutil.isDir(dir)) {
            ctx.errPrint("rmdir: {s}: Not a directory\n", .{dir});
            rc = 1;
            continue;
        }
        sys.unlink(dir) catch |e| {
            ctx.errPrint("rmdir: {s}: {s}\n", .{ dir, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        if (m.has("parents")) removeParents(dir);
    }
    return rc;
}
