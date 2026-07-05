//! `zip` -- docs/analysis/applets-s-z.md: full-rewrite ZIP archiver over
//! `engines/archive/zipwriter.zig`. Every invocation loads whatever members already
//! exist in `ARCHIVE` (decompressing each into memory), merges in the requested
//! change (`upsert` by name for a normal add/replace, or drop-by-glob for `-d`), and
//! rewrites the whole archive from scratch -- matching the reference `zip` crate
//! wrapper's own `load_existing` + `upsert` + rewrite model (it back-patches via
//! seeks; full-rewrite is the equivalent whole-buffer operation).
//!
//! Hand-parsed argv (not `core/cli.zig`): `-r`/`-R` (recurse; treated identically --
//! the matrix doesn't distinguish their traversal semantics here), `-j` (junk paths:
//! store only the basename), `-m` (move: unlink sources after a successful add),
//! `-d` (delete: `FILE` operands become glob patterns to *remove* from the existing
//! archive instead of disk paths to add), `-u` (update -- treated as a no-op alias for
//! the default add/replace `upsert` behavior; the matrix's "update≈add/replace"
//! phrasing does not describe a staleness/mtime comparison, and `upsert`-by-name is
//! already unconditional replace, ledgered), `-q` (accepted, no-op: this port is
//! silent by design -- see below), `-0`(store)/`-1`..`-9`(deflate level, hidden
//! digits so `-rj9` clusters same as gzip's), `-x PATTERN...` (exclude globs -- Info-Zip
//! grammar: bare `-x` consumes every remaining token to the end of the command line as
//! patterns, so it must be the last flag given). `ARCHIVE FILE...`.
//!
//! **Chatter ruling** (ledgered, flagged prominently per the milestone brief): real
//! Info-Zip prints `  adding: NAME (deflated NN%)` per entry; the matrix only lists
//! flags, not output shape, and the origin is a thin wrapper, not real zip -- this port
//! is **silent except for errors** (`-q` is accepted but changes nothing observable).
//! Revisit if a golden oracle ever surfaces requiring that chatter.
//!
//! `archive_name` normalization: leading `./` stripped, backslashes become `/`, `-j`
//! reduces to `basename`, directories get a trailing `/`. Exit 0 ok / 1 a file
//! couldn't be read or the archive couldn't be found for `-d` / 2 usage.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const textio = @import("../core/textio.zig");
const glob = @import("../engines/glob.zig");
const zipwriter = @import("../engines/archive/zipwriter.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "package files into a new or existing ZIP archive",
    .synopsis = &.{
        "zip [OPTION]... ARCHIVE FILE...",
        "zip -d ARCHIVE PATTERN...",
    },
    .description =
    \\Adds each FILE to ARCHIVE, creating it if it doesn't exist yet: existing
    \\members already in ARCHIVE are loaded, decompressed, and merged with the
    \\requested change (upsert by name), then the whole archive is rewritten from
    \\scratch. -d instead removes archive members matching PATTERN (a glob)
    \\rather than adding files. -r/-R recurses into directory operands; -j stores
    \\only each file's basename ("junks" its path). -m deletes each source file
    \\after it has been added successfully.
    \\
    \\Compression level is 6 (deflate) by default; -0 stores without
    \\compression, -1..-9 select a deflate level. -x PATTERN... excludes
    \\matching paths -- being Info-Zip's own grammar, -x consumes every
    \\remaining argument as a pattern, so it must be the last option given.
    ,
    .options = &.{
        .{ .flags = "-r, -R", .desc = "recurse into directories" },
        .{ .flags = "-j", .desc = "junk paths: store only each file's basename" },
        .{ .flags = "-m", .desc = "move: delete each source file after adding it" },
        .{ .flags = "-d", .desc = "delete: FILE operands are glob patterns removed from ARCHIVE" },
        .{ .flags = "-u", .desc = "update (no-op alias for the default add/replace behavior)" },
        .{ .flags = "-q", .desc = "quiet (accepted; this port is silent by default anyway)" },
        .{ .flags = "-0", .desc = "store without compression" },
        .{ .flags = "-1 .. -9", .desc = "deflate compression level (default 6)" },
        .{ .flags = "-x PATTERN...", .desc = "exclude matching paths (greedy: consumes the rest of argv)" },
    },
    .operands = "ARCHIVE the .zip file to create or update. FILE... paths to add (or, with -d, glob PATTERN... of archive member names to remove).",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "a file could not be read, or (-d) ARCHIVE does not exist" },
        .{ .code = 2, .when = "usage error: bad option, missing ARCHIVE, no files given, or -d with no PATTERN" },
    },
    .deviations_from = "Info-Zip zip",
    .deviations = &.{
        "Silent by default: real zip prints \"adding: NAME (deflated NN%)\" per entry; this port prints nothing but errors, even without -q.",
        "-u is a no-op alias for the default add/replace behavior, not a staleness/mtime comparison.",
        "-R is treated identically to -r (both simply recurse).",
    },
    .examples = &.{
        .{ .cmd = "zip archive.zip a.txt b.txt", .note = "add two files" },
        .{ .cmd = "zip -r archive.zip src/", .note = "recursively add a directory tree" },
        .{ .cmd = "zip -d archive.zip '*.log'", .note = "remove every *.log member" },
    },
    .see_also = "unzip (read the archive back), tar/gzip (the tar/gzip formats).",
};

const ParsedArgs = struct {
    recurse: bool = false,
    junk: bool = false,
    move: bool = false,
    delete: bool = false,
    update: bool = false,
    quiet: bool = false,
    level: u8 = 6,
    store: bool = false,
    excludes: []const []const u8 = &.{},
    positionals: []const []const u8 = &.{},
};

fn parseArgs(gpa: std.mem.Allocator, args: []const [:0]const u8) !union(enum) { ok: ParsedArgs, bad_flag: u8 } {
    var recurse = false;
    var junk = false;
    var move = false;
    var delete = false;
    var update = false;
    var quiet = false;
    var level: u8 = 6;
    var store = false;
    var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-x")) {
            i += 1;
            while (i < args.len) : (i += 1) try excludes.append(gpa, args[i]);
            break;
        }
        if (a.len >= 2 and a[0] == '-') {
            for (a[1..]) |c| {
                switch (c) {
                    'r', 'R' => recurse = true,
                    'j' => junk = true,
                    'm' => move = true,
                    'd' => delete = true,
                    'u' => update = true,
                    'q' => quiet = true,
                    '0' => {
                        store = true;
                        level = 0;
                    },
                    '1'...'9' => {
                        store = false;
                        level = c - '0';
                    },
                    else => return .{ .bad_flag = c },
                }
            }
            i += 1;
            continue;
        }
        try positionals.append(gpa, a);
        i += 1;
    }
    return .{ .ok = .{
        .recurse = recurse,
        .junk = junk,
        .move = move,
        .delete = delete,
        .update = update,
        .quiet = quiet,
        .level = level,
        .store = store,
        .excludes = excludes.items,
        .positionals = positionals.items,
    } };
}

const Entry = struct {
    name: []const u8,
    data: []const u8,
    mode: u32,
    mtime_s: i64,
    is_dir: bool,
    method: zipwriter.Method,
};

fn findByName(entries: *std.ArrayListUnmanaged(Entry), name: []const u8) ?usize {
    for (entries.items, 0..) |e, idx| {
        if (std.mem.eql(u8, e.name, name)) return idx;
    }
    return null;
}

fn upsert(gpa: std.mem.Allocator, entries: *std.ArrayListUnmanaged(Entry), e: Entry) void {
    if (findByName(entries, e.name)) |idx| {
        entries.items[idx] = e;
    } else {
        entries.append(gpa, e) catch {};
    }
}

fn loadExisting(gpa: std.mem.Allocator, archive_path: []const u8, entries: *std.ArrayListUnmanaged(Entry)) !void {
    if (!fsutil.exists(archive_path)) return;
    const fd = try sys.open(archive_path, .{ .read = true });
    defer sys.close(fd);
    const bytes = try textio.readAll(gpa, fd);
    const central = zipwriter.listEntries(gpa, bytes) catch return; // not a zip / empty -> start fresh
    for (central) |c| {
        const data = zipwriter.extractEntry(gpa, bytes, c) catch continue;
        entries.append(gpa, .{
            .name = gpa.dupe(u8, c.name) catch continue,
            .data = data,
            .mode = if (c.unixMode() == 0) (if (c.isDir()) @as(u32, 0o755) else @as(u32, 0o644)) else c.unixMode(),
            .mtime_s = c.mtime_s,
            .is_dir = c.isDir(),
            .method = c.method,
        }) catch {};
    }
}

/// Normalizes an on-disk operand path into an archive member name: backslashes become
/// `/`, a leading `./` is stripped, `-j` reduces to the basename, directories get a
/// trailing `/`.
fn archiveName(gpa: std.mem.Allocator, path: []const u8, junk: bool, is_dir: bool) ![]const u8 {
    var buf = try gpa.alloc(u8, path.len);
    for (path, 0..) |c, idx| buf[idx] = if (c == '\\') '/' else c;
    var name: []const u8 = buf;
    while (std.mem.startsWith(u8, name, "./")) name = name[2..];
    while (name.len > 0 and name[0] == '/') name = name[1..];
    if (junk) name = fsutil.basename(name);
    while (name.len > 1 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
    if (is_dir and (name.len == 0 or name[name.len - 1] != '/')) {
        return std.mem.concat(gpa, u8, &.{ name, "/" });
    }
    return gpa.dupe(u8, name);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `-d`'s patterns are user-typed paths (often still carrying the leading `/` or `./`
/// the operand had on disk), but stored archive member names never do (see
/// `archiveName`) -- normalize patterns the same way before globbing against them.
fn normalizePattern(gpa: std.mem.Allocator, p: []const u8) ![]const u8 {
    var buf = try gpa.alloc(u8, p.len);
    for (p, 0..) |c, idx| buf[idx] = if (c == '\\') '/' else c;
    var name: []const u8 = buf;
    while (std.mem.startsWith(u8, name, "./")) name = name[2..];
    while (name.len > 0 and name[0] == '/') name = name[1..];
    return name;
}

fn matchesAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| {
        if (glob.match(p, name)) return true;
    }
    return false;
}

fn addDiskPath(ctx: *Ctx, entries: *std.ArrayListUnmanaged(Entry), path: []const u8, o: ParsedArgs, added_paths: *std.ArrayListUnmanaged([]const u8)) u8 {
    const st = sys.lstat(path) catch |e| {
        ctx.errPrint("zip: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    if (st.is_dir) {
        if (!o.recurse) {
            ctx.errPrint("zip: {s}: is a directory (use -r)\n", .{path});
            return 1;
        }
        const name = archiveName(ctx.gpa, path, o.junk, true) catch return 1;
        if (!matchesAny(o.excludes, name)) {
            upsert(ctx.gpa, entries, .{ .name = name, .data = "", .mode = st.mode & 0o7777, .mtime_s = @divFloor(st.mtime_ms, 1000), .is_dir = true, .method = .store });
        }
        const names = fsutil.list(ctx.gpa, path) catch return 0;
        std.mem.sort([]const u8, names, {}, lessThanStr);
        var rc: u8 = 0;
        for (names) |child| {
            const child_path = fsutil.join(ctx.gpa, path, child) catch continue;
            const r = addDiskPath(ctx, entries, child_path, o, added_paths);
            if (r > rc) rc = r;
        }
        added_paths.append(ctx.gpa, path) catch {};
        return rc;
    }
    const fd = sys.open(path, .{ .read = true }) catch |e| {
        ctx.errPrint("zip: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    const data = textio.readAll(ctx.gpa, fd) catch |e| {
        sys.close(fd);
        ctx.errPrint("zip: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    sys.close(fd);
    const name = archiveName(ctx.gpa, path, o.junk, false) catch return 1;
    if (!matchesAny(o.excludes, name)) {
        const method: zipwriter.Method = if (o.store) .store else .deflate;
        upsert(ctx.gpa, entries, .{ .name = name, .data = data, .mode = st.mode & 0o7777, .mtime_s = @divFloor(st.mtime_ms, 1000), .is_dir = false, .method = method });
    }
    added_paths.append(ctx.gpa, path) catch {};
    return 0;
}

fn writeArchive(ctx: *Ctx, archive_path: []const u8, entries: []const Entry, level: u8) u8 {
    var w = zipwriter.Writer.init(ctx.gpa);
    for (entries) |e| {
        w.addEntryLeveled(e.name, e.data, e.mode, e.mtime_s, e.method, e.is_dir, level) catch {
            ctx.errPrint("zip: {s}: {s}\n", .{ archive_path, "failed to write entry" });
            return 1;
        };
    }
    const bytes = w.finish() catch {
        ctx.errPrint("zip: out of memory\n", .{});
        return 2;
    };
    const fd = sys.open(archive_path, .{ .write = true, .create = true, .trunc = true }) catch |e| {
        ctx.errPrint("zip: {s}: {s}\n", .{ archive_path, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    defer sys.close(fd);
    sys.writeAll(fd, bytes) catch |e| {
        ctx.errPrint("zip: {s}: {s}\n", .{ archive_path, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    return 0;
}

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "zip", "0.1.0", help_doc)) return 0;

    const parsed = parseArgs(ctx.gpa, ctx.args) catch {
        ctx.errPrint("zip: out of memory\n", .{});
        return 2;
    };
    const o = switch (parsed) {
        .bad_flag => |c| {
            ctx.errPrint("zip: invalid option -- '{c}'\n", .{c});
            return 2;
        },
        .ok => |o| o,
    };

    if (o.positionals.len == 0) {
        ctx.errPrint("zip: missing archive operand\n", .{});
        return 2;
    }
    const archive_path = o.positionals[0];
    const files = o.positionals[1..];

    if (o.delete) {
        if (!fsutil.exists(archive_path)) {
            ctx.errPrint("zip: {s}: cannot find or open zip file\n", .{archive_path});
            return 1;
        }
        if (files.len == 0) {
            ctx.errPrint("zip: -d requires at least one pattern\n", .{});
            return 2;
        }
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        loadExisting(ctx.gpa, archive_path, &entries) catch {};
        var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
        for (files) |f| patterns.append(ctx.gpa, normalizePattern(ctx.gpa, f) catch f) catch {};
        var kept: std.ArrayListUnmanaged(Entry) = .empty;
        for (entries.items) |e| {
            if (!matchesAny(patterns.items, e.name)) kept.append(ctx.gpa, e) catch {};
        }
        return writeArchive(ctx, archive_path, kept.items, o.level);
    }

    if (files.len == 0) {
        ctx.errPrint("zip: nothing to do\n", .{});
        return 2;
    }

    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    loadExisting(ctx.gpa, archive_path, &entries) catch {};

    var added_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var rc: u8 = 0;
    for (files) |f| {
        const r = addDiskPath(ctx, &entries, f, o, &added_paths);
        if (r > rc) rc = r;
    }

    const wrc = writeArchive(ctx, archive_path, entries.items, o.level);
    if (wrc > rc) rc = wrc;

    if (o.move and rc == 0) {
        for (added_paths.items) |p| {
            const st = sys.lstat(p) catch continue;
            if (st.is_dir) {
                fsutil.removeRecursive(ctx.gpa, p) catch {};
            } else {
                sys.unlink(p) catch {};
            }
        }
    }

    return rc;
}
