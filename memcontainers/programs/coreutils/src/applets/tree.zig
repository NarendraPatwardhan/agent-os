//! `tree` -- DESIGN.md §1: hand-written recursive directory walk over
//! `fsutil.list`/`join`/`isDir`. `-a` (dotfiles), `-d` (dirs only), `-f` (full path),
//! `-L LEVEL` (`<= 0` disables the depth limit), `--noreport`. UTF-8 connectors
//! `"├── "`/`"└── "`, continuation prefixes `"│   "`/`"    "`. Entries sorted. Each
//! root gets a header line + its subtree + a blank line; a combined
//! `N directories, M files` summary follows (pluralized; dirs-only variant omits the
//! file count) unless `--noreport`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "tree",
    .flags = &.{
        cli.flagOpt('a', null, "list hidden files too"),
        cli.flagOpt('d', null, "list directories only"),
        cli.flagOpt('f', null, "print the full path prefix for each entry"),
        cli.valueOpt('L', null, "descend only LEVEL directories deep"),
        cli.flagOpt(null, "noreport", "omit the file/directory report at the end"),
    },
    .help = .{
        .summary = "list directory contents as an indented tree",
        .synopsis = &.{"tree [OPTION]... [DIR]..."},
        .description =
        \\Recursively lists the contents of each DIR (default: .) as a tree, using
        \\UTF-8 box-drawing connectors ("├──"/"└──") with a vertical bar continued
        \\down through non-final branches. Entries within a directory are sorted by
        \\name. Dotfiles are hidden unless -a; -d lists directories only; -f prints
        \\each entry's full path instead of just its name. -L LEVEL limits the depth of
        \\the walk (LEVEL <= 0 means unlimited).
        \\
        \\Each DIR gets its own header line and subtree, followed by a blank line;
        \\unless --noreport, a combined "N directories, M files" summary (correctly
        \\pluralized; the file count is omitted with -d) follows at the end, tallied
        \\across all DIR operands.
        ,
        .operands = "DIR...  the directories to display; defaults to . when none are given.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a DIR operand is not a directory (remaining operands are still processed)" },
            .{ .code = 2, .when = "usage error (unrecognized option or missing option value)" },
        },
        .deviations = &.{
            "No -P/-I (name-pattern include/exclude), -C (color), -p/-s/-h (permissions/size/human-size columns), -J (JSON output), or -X (XML output); entries are always name-sorted (no -U/-t/--dirsfirst).",
            "Symbolic links are not distinguished from their targets: a symlink to a directory is listed and recursed into exactly like a real directory (no \"name -> target\" annotation, and no cycle detection for symlink loops).",
        },
        .examples = &.{
            .{ .cmd = "tree", .note = "the current directory" },
            .{ .cmd = "tree -L 2 -d src/", .note = "directories only, at most 2 levels deep" },
            .{ .cmd = "tree -f --noreport .", .note = "full paths per entry, no trailing summary line" },
        },
        .see_also = "ls -R (flat recursive listing), find.",
    },
    .positionals = .{ .name = "DIR", .min = 0, .max = null },
};

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn parseI64(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
    }
    if (i >= s.len) return null;
    var v: i64 = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] < '0' or s[i] > '9') return null;
        v = v * 10 + (s[i] - '0');
    }
    return if (neg) -v else v;
}

const Counts = struct { dirs: usize = 0, files: usize = 0 };

const Opts = struct {
    max_level: ?usize,
    dirs_only: bool,
    show_hidden: bool,
    full_path: bool,
};

fn walk(
    ctx: *Ctx,
    fs_path: []const u8,
    disp_path: []const u8,
    depth: usize,
    o: Opts,
    prefix_buf: []u8,
    prefix_len: usize,
    counts: *Counts,
) void {
    const names = fsutil.list(ctx.gpa, fs_path) catch return;

    var filtered: std.ArrayListUnmanaged([]const u8) = .empty;
    for (names) |n| {
        if (!o.show_hidden and n.len > 0 and n[0] == '.') continue;
        if (o.dirs_only) {
            const child_fs = fsutil.join(ctx.gpa, fs_path, n) catch continue;
            if (!fsutil.isDir(child_fs)) continue;
        }
        filtered.append(ctx.gpa, n) catch continue;
    }
    std.mem.sort([]const u8, filtered.items, {}, lessThanName);

    for (filtered.items, 0..) |name, i| {
        const is_last = i == filtered.items.len - 1;
        const child_fs = fsutil.join(ctx.gpa, fs_path, name) catch continue;
        const child_is_dir = fsutil.isDir(child_fs);
        const display_name = if (o.full_path) (fsutil.join(ctx.gpa, disp_path, name) catch name) else name;

        ctx.outWrite(prefix_buf[0..prefix_len]) catch return;
        ctx.outWrite(if (is_last) "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ") catch return;
        ctx.outWrite(display_name) catch return;
        ctx.outWrite("\n") catch return;

        if (child_is_dir) counts.dirs += 1 else counts.files += 1;

        if (child_is_dir) {
            const can_descend = if (o.max_level) |ml| depth < ml else true;
            if (can_descend) {
                const ext: []const u8 = if (is_last) "    " else "\xe2\x94\x82   ";
                if (prefix_len + ext.len <= prefix_buf.len) {
                    @memcpy(prefix_buf[prefix_len..][0..ext.len], ext);
                    walk(ctx, child_fs, display_name, depth + 1, o, prefix_buf, prefix_len + ext.len, counts);
                }
            }
        }
    }
}

fn dirWord(n: usize) []const u8 {
    return if (n == 1) "directory" else "directories";
}
fn fileWord(n: usize) []const u8 {
    return if (n == 1) "file" else "files";
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var max_level: ?usize = null;
    if (m.value("L")) |lv| {
        if (parseI64(lv)) |parsed| {
            if (parsed > 0) max_level = @intCast(parsed);
        }
    }
    const o = Opts{
        .max_level = max_level,
        .dirs_only = m.has("d"),
        .show_hidden = m.has("a"),
        .full_path = m.has("f"),
    };
    const noreport = m.has("noreport");

    const positional_roots = m.positionalSlice();
    var default_root_buf = [_][]const u8{"."};
    const roots: []const []const u8 = if (positional_roots.len == 0) &default_root_buf else positional_roots;

    var rc: u8 = 0;
    var counts = Counts{};
    for (roots) |root| {
        if (!fsutil.isDir(root)) {
            ctx.errPrint("tree: {s}: Not a directory\n", .{root});
            rc = 1;
            continue;
        }
        ctx.outPrint("{s}\n", .{root});
        var prefix_buf: [4096]u8 = undefined;
        walk(ctx, root, root, 1, o, &prefix_buf, 0, &counts);
        ctx.outWrite("\n") catch return rc;
    }

    if (!noreport) {
        if (o.dirs_only) {
            ctx.outPrint("{d} {s}\n", .{ counts.dirs, dirWord(counts.dirs) });
        } else {
            ctx.outPrint("{d} {s}, {d} {s}\n", .{ counts.dirs, dirWord(counts.dirs), counts.files, fileWord(counts.files) });
        }
    }
    return rc;
}
