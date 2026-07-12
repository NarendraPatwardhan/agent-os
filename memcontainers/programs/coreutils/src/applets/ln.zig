//! `ln` -- DESIGN.md §1: hand-written, raw `sys.*` + `fsutil` path
//! math. Operand dispatch: `-t DIR` links every TARGET into DIR; `-T` requires exactly
//! 2 operands (no directory redirection); 1 operand links `basename(TARGET)` into cwd;
//! otherwise if the last operand is a directory, every preceding TARGET links into it;
//! with exactly 2 operands and a non-directory last operand, classic `TARGET LINK`;
//! anything else is `ln: {last}: is not a directory`.
//!
//! `-s/--symbolic`, `-f/--force`, `-i/--interactive`, `-n/--no-dereference` (treat an
//! existing LINK that is itself a symlink-to-directory as a plain file, not a
//! redirection target), `-v/--verbose`, `-r/--relative` (rewrite the symlink target as
//! a relative path from the link's directory), `-L/--logical` (deref TARGET through the
//! facade's 40-hop `canonicalize` before a hardlink), `-P/--physical` (default).

const std = @import("std");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Allocator = std.mem.Allocator;

const spec = cli.Spec{
    .name = "ln",
    .flags = &.{
        cli.flagOpt('s', "symbolic", "make symbolic links instead of hard links"),
        cli.flagOpt('f', "force", "remove existing destination files"),
        cli.flagOpt('i', "interactive", "prompt whether to remove destinations"),
        cli.flagOpt('n', "no-dereference", "treat LINK_NAME as a normal file if it is a symlink to a directory"),
        cli.flagOpt('v', "verbose", "print name of each linked file"),
        cli.flagOpt('T', "no-target-directory", "treat LINK_NAME as a normal file always"),
        cli.valueOpt('t', "target-directory", "specify the DIRECTORY in which to create the links"),
        cli.flagOpt('r', "relative", "create symbolic links relative to link location"),
        cli.flagOpt('L', "logical", "dereference TARGETs that are symbolic links"),
        cli.flagOpt('P', "physical", "make hard links directly to symbolic links"),
    },
    .help = .{
        .summary = "make links between files",
        .synopsis = &.{
            "ln [OPTION]... [-T] TARGET LINK_NAME",
            "ln [OPTION]... TARGET",
            "ln [OPTION]... TARGET... DIRECTORY",
            "ln [OPTION]... -t DIRECTORY TARGET...",
        },
        .description =
        \\Creates a hard link (or, with -s, a symbolic link) named LINK_NAME pointing at
        \\TARGET. With a single operand, LINK_NAME defaults to basename(TARGET) created
        \\in the current directory. With TARGET... DIRECTORY (DIRECTORY being the last
        \\operand and an existing directory, or given via -t), every TARGET is linked
        \\into it as DIRECTORY/basename(TARGET). -T forces the classic two-operand
        \\TARGET LINK_NAME form even when LINK_NAME happens to be a directory.
        \\
        \\By default a hard link is made directly to TARGET (-P/--physical); -L/--logical
        \\instead resolves TARGET through symlinks (up to 40 hops) before linking. -s
        \\makes a symbolic link instead, and -r additionally rewrites it as a path
        \\relative to LINK_NAME's directory. An existing LINK_NAME is left untouched
        \\(error) unless -f (remove and relink) or -i (prompt first, on stderr).
        ,
        .operands = "TARGET...  the file(s) to link to. The final operand, unless consumed as a TARGET (via -t DIRECTORY or the TARGET...  DIRECTORY form), is LINK_NAME.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "LINK_NAME already exists (without -f, or declined via -i), a link/symlink/unlink error, an extra operand with -T, or 3+ operands whose last is not a directory" },
            .{ .code = 2, .when = "no TARGET/LINK_NAME operand, or usage error (unrecognized option)" },
        },
        .deviations = &.{
            "No -b/--backup, -S/--suffix, or -d/-F/--directory (superuser hard-linking of directories).",
        },
        .examples = &.{
            .{ .cmd = "ln src.txt link.txt", .note = "hard link" },
            .{ .cmd = "ln -s ../shared/lib.so lib.so", .note = "symbolic link with the target written exactly as given; add -r to compute a relative target automatically" },
            .{ .cmd = "ln -t /usr/local/bin a.sh b.sh", .note = "links each TARGET into DIRECTORY" },
        },
        .see_also = "cp, mv.",
    },
    .positionals = .{ .name = "TARGET", .min = 0, .max = null },
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

/// Directory check used for redirection decisions: with `-n`, a symlink-to-directory
/// no longer counts (it's treated as an ordinary file), matching `--no-dereference`.
fn isDirForRedirect(path: []const u8, no_dereference: bool) bool {
    if (!no_dereference) return fsutil.isDir(path);
    const st = sys.lstat(path) catch return false;
    return st.is_dir and !st.is_symlink;
}

fn relativePath(gpa: Allocator, from_dir: []const u8, to: []const u8) ![]u8 {
    var from_comps: std.ArrayListUnmanaged([]const u8) = .empty;
    var to_comps: std.ArrayListUnmanaged([]const u8) = .empty;
    var fit = std.mem.splitScalar(u8, from_dir, '/');
    while (fit.next()) |c| if (c.len > 0) try from_comps.append(gpa, c);
    var tit = std.mem.splitScalar(u8, to, '/');
    while (tit.next()) |c| if (c.len > 0) try to_comps.append(gpa, c);

    var common: usize = 0;
    while (common < from_comps.items.len and common < to_comps.items.len and
        std.mem.eql(u8, from_comps.items[common], to_comps.items[common])) : (common += 1)
    {}

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = common;
    while (i < from_comps.items.len) : (i += 1) try parts.append(gpa, "..");
    i = common;
    while (i < to_comps.items.len) : (i += 1) try parts.append(gpa, to_comps.items[i]);

    if (parts.items.len == 0) return gpa.dupe(u8, ".");
    var total: usize = 0;
    for (parts.items, 0..) |p, idx| total += p.len + (if (idx > 0) @as(usize, 1) else 0);
    const out = try gpa.alloc(u8, total);
    var off: usize = 0;
    for (parts.items, 0..) |p, idx| {
        if (idx > 0) {
            out[off] = '/';
            off += 1;
        }
        @memcpy(out[off..][0..p.len], p);
        off += p.len;
    }
    return out;
}

const Opts = struct {
    symbolic: bool,
    force: bool,
    interactive: bool,
    no_dereference: bool,
    verbose: bool,
    relative: bool,
    logical: bool,
};

fn createOne(ctx: *Ctx, target: []const u8, link_path: []const u8, o: Opts) u8 {
    if (fsutil.exists(link_path)) {
        if (o.interactive) {
            if (!cli.confirm(ctx, "ln: replace {s}? ", .{link_path})) return 0;
            sys.unlink(link_path) catch {};
        } else if (o.force) {
            sys.unlink(link_path) catch {};
        } else {
            ctx.errPrint("ln: {s}: File exists\n", .{link_path});
            return 1;
        }
    }

    var effective_target: []const u8 = target;
    if (o.symbolic and o.relative) {
        const abs_target = fsutil.lexicalAbs(ctx.gpa, target) catch null;
        const abs_link_dir = fsutil.lexicalAbs(ctx.gpa, dirOf(link_path)) catch null;
        if (abs_target) |at| {
            if (abs_link_dir) |ald| {
                effective_target = relativePath(ctx.gpa, ald, at) catch target;
            }
        }
    }
    var resolved_buf: []const u8 = effective_target;
    if (!o.symbolic and o.logical) {
        if (fsutil.canonicalize(ctx.gpa, target, .all)) |r| resolved_buf = r;
    }

    const err: ?sys.Error = blk: {
        if (o.symbolic) {
            sys.symlink(effective_target, link_path) catch |e| break :blk e;
        } else {
            sys.link(resolved_buf, link_path) catch |e| break :blk e;
        }
        break :blk null;
    };
    if (err) |e| {
        ctx.errPrint("ln: {s}: {s}\n", .{ link_path, sys.strerror(sys.toErrno(e)) });
        return 1;
    }
    if (o.verbose) ctx.outPrint("'{s}' -> '{s}'\n", .{ link_path, target });
    return 0;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const o = Opts{
        .symbolic = m.has("symbolic"),
        .force = m.has("force"),
        .interactive = m.has("interactive") and !m.has("force"),
        .no_dereference = m.has("no-dereference"),
        .verbose = m.has("verbose"),
        .relative = m.has("relative"),
        .logical = m.has("logical"),
    };

    const positionals = m.positionalSlice();

    if (m.value("target-directory")) |dir| {
        if (positionals.len == 0) {
            ctx.errPrint("ln: missing file operand\n", .{});
            return 2;
        }
        var rc: u8 = 0;
        for (positionals) |target| {
            const link_path = fsutil.join(ctx.gpa, dir, fsutil.basename(target)) catch continue;
            const r = createOne(ctx, target, link_path, o);
            if (r != 0) rc = r;
        }
        return rc;
    }

    if (m.has("no-target-directory")) {
        if (positionals.len < 2) {
            ctx.errPrint("ln: missing file operand\n", .{});
            return 2;
        }
        if (positionals.len > 2) {
            ctx.errPrint("ln: extra operand '{s}'\n", .{positionals[2]});
            return 1;
        }
        return createOne(ctx, positionals[0], positionals[1], o);
    }

    if (positionals.len == 0) {
        ctx.errPrint("ln: missing file operand\n", .{});
        return 2;
    }
    if (positionals.len == 1) {
        const link_path = fsutil.basename(positionals[0]);
        return createOne(ctx, positionals[0], link_path, o);
    }

    const last = positionals[positionals.len - 1];
    if (isDirForRedirect(last, o.no_dereference)) {
        var rc: u8 = 0;
        for (positionals[0 .. positionals.len - 1]) |target| {
            const link_path = fsutil.join(ctx.gpa, last, fsutil.basename(target)) catch continue;
            const r = createOne(ctx, target, link_path, o);
            if (r != 0) rc = r;
        }
        return rc;
    }
    if (positionals.len == 2) {
        return createOne(ctx, positionals[0], positionals[1], o);
    }
    ctx.errPrint("ln: {s}: is not a directory\n", .{last});
    return 1;
}
