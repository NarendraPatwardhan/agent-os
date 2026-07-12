//! `unzip` -- DESIGN.md §1: reader side of `engines/archive/
//! zipwriter.zig` (see that file's module doc for why the reader is hand-rolled here
//! instead of `std.zip`'s `Iterator`, which is wired to `std.Io.File`).
//!
//! Hand-parsed argv (mirrors `zip.zig`'s style; `-x` is Info-Zip's own greedy
//! multi-value flag, so it can't fit `core/cli.zig`'s single-value model either):
//! `-l` (list), `-v` (verbose list -- implies `-l`; the matrix doesn't ask for extra
//! columns beyond the base `-l` shape, so `-v` is a plain alias here, ledgered), `-t`
//! (test), `-o` (overwrite -- already the default; kept as an accepted no-op flag),
//! `-n` (never overwrite an existing destination file), `-j` (junk paths: extract every
//! member flat into the destination, discarding directory components), `-p` (pipe file
//! contents to stdout; implies quiet), `-q` (quiet: suppresses the per-entry
//! `inflating`/`creating` chatter -- see below), `-d DIR` (extraction root, created if
//! missing), `-x PATTERN...` (exclude globs, greedy to end of argv like `zip -x`).
//! `ARCHIVE [MEMBER...]` -- member operands are globs; `wanted(name) = (no MEMBER
//! globs, or name matches one) AND name doesn't match any -x exclude glob`.
//!
//! **`-l` table ruling** (ledgered; no runnable oracle, matrix only says "Length Name +
//! totals"): a minimal two-column `Length`/`Name` table with a totals row, spec-authored
//! per the milestone brief's instruction to implement exactly the two columns named.
//! **Chatter ruling**: unlike `zip` (ruled silent-by-default because the matrix only
//! lists flags), `unzip`'s matrix explicitly includes a `-q`/quiet flag, which only
//! makes sense if the un-quiet default prints something -- so the default prints the
//! real Info-Zip wording (`  inflating: NAME` / `   creating: NAME/`), and `-q`
//! suppresses it. `-t`'s per-entry line and trailer are spec-authored per the
//! milestone brief's suggested shape (`    testing: NAME   OK`, trailer only on full
//! success). Traversal safety mirrors `tar`'s (absolute path or a literal `..`
//! component after normalization is rejected, notice printed, extraction continues).
//! Exit 0 ok / 1 a test/extract failure occurred / 2 usage or the archive couldn't be
//! read.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const textio = @import("../core/textio.zig");
const fmtnum = @import("../core/fmtnum.zig");
const glob = @import("../engines/glob.zig");
const zipwriter = @import("../engines/archive/zipwriter.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "list, test, or extract members of a ZIP archive",
    .synopsis = &.{
        "unzip [OPTION]... ARCHIVE [MEMBER...]",
        "unzip -l ARCHIVE",
        "unzip -t ARCHIVE",
    },
    .description =
    \\Extracts ARCHIVE into the current directory (or -d DIR), recreating each
    \\member's path. -l lists members with their uncompressed length and a
    \\totals row; -t verifies every member decodes without writing anything.
    \\MEMBER operands are globs: with none given, every member is selected; -x
    \\PATTERN... excludes matching names.
    \\
    \\-p pipes member contents to standard output instead of writing files (and
    \\implies -q). -j junks paths, extracting every member flat. -n never
    \\overwrites an existing destination file; -o (already the default) is
    \\accepted for compatibility. An entry with an unsafe path (absolute, or
    \\containing a ".." component) is skipped with a notice rather than
    \\extracted.
    ,
    .options = &.{
        .{ .flags = "-l", .desc = "list archive contents instead of extracting" },
        .{ .flags = "-v", .desc = "verbose listing (alias for -l here)" },
        .{ .flags = "-t", .desc = "test archive integrity instead of extracting" },
        .{ .flags = "-o", .desc = "overwrite existing files (accepted; already the default)" },
        .{ .flags = "-n", .desc = "never overwrite an existing file" },
        .{ .flags = "-j", .desc = "junk paths: extract every member flat" },
        .{ .flags = "-p", .desc = "pipe extracted contents to standard output (implies -q)" },
        .{ .flags = "-q", .desc = "suppress the inflating/creating messages" },
        .{ .flags = "-d DIR", .desc = "extract into DIR instead of the current directory" },
        .{ .flags = "-x PATTERN...", .desc = "exclude matching members (greedy: consumes the rest of argv)" },
    },
    .operands = "ARCHIVE the .zip file to read. MEMBER... optional glob patterns selecting which archive members to act on (default: all).",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "a member failed to extract or verify (bad CRC, unsafe path); the remaining members are still processed" },
        .{ .code = 2, .when = "usage error, or ARCHIVE could not be opened / is not a valid zip file" },
    },
    .deviations_from = "Info-Zip unzip",
    .deviations = &.{
        "-v is a plain alias for -l: it adds no extra columns to the listing.",
        "-l's table is a minimal two-column Length/Name shape with a totals row, not Info-Zip's full header/footer.",
        "-x is Info-Zip's own grammar: it consumes every remaining argument as an exclude pattern, so it must be the last option given (put -d DIR before -x).",
    },
    .examples = &.{
        .{ .cmd = "unzip archive.zip -d out/", .note = "extract into out/" },
        .{ .cmd = "unzip -l archive.zip", .note = "list members with sizes" },
        .{ .cmd = "unzip -p archive.zip file.txt", .note = "print one member's contents to stdout" },
    },
    .see_also = "zip (create/update the archive), tar/gzip.",
};

const ParsedArgs = struct {
    list: bool = false,
    verbose: bool = false,
    test_only: bool = false,
    never_overwrite: bool = false,
    junk: bool = false,
    pipe: bool = false,
    quiet: bool = false,
    dir: ?[]const u8 = null,
    excludes: []const []const u8 = &.{},
    positionals: []const []const u8 = &.{},
};

fn parseArgs(gpa: std.mem.Allocator, args: []const [:0]const u8) !union(enum) { ok: ParsedArgs, bad_flag: u8, missing_value: u8 } {
    var list = false;
    var verbose = false;
    var test_only = false;
    var never_overwrite = false;
    var junk = false;
    var pipe = false;
    var quiet = false;
    var dir: ?[]const u8 = null;
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
            var ci: usize = 1;
            while (ci < a.len) : (ci += 1) {
                const c = a[ci];
                switch (c) {
                    'l' => list = true,
                    'v' => {
                        verbose = true;
                        list = true;
                    },
                    't' => test_only = true,
                    'o' => {},
                    'n' => never_overwrite = true,
                    'j' => junk = true,
                    'p' => {
                        pipe = true;
                        quiet = true;
                    },
                    'q' => quiet = true,
                    'd' => {
                        if (ci + 1 < a.len) {
                            dir = a[ci + 1 ..];
                        } else {
                            i += 1;
                            if (i >= args.len) return .{ .missing_value = 'd' };
                            dir = args[i];
                        }
                        ci = a.len;
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
        .list = list,
        .verbose = verbose,
        .test_only = test_only,
        .never_overwrite = never_overwrite,
        .junk = junk,
        .pipe = pipe,
        .quiet = quiet,
        .dir = dir,
        .excludes = excludes.items,
        .positionals = positionals.items,
    } };
}

fn matchesAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| {
        if (glob.match(p, name)) return true;
    }
    return false;
}

fn wanted(members: []const []const u8, excludes: []const []const u8, name: []const u8) bool {
    if (members.len > 0 and !matchesAny(members, name)) return false;
    if (matchesAny(excludes, name)) return false;
    return true;
}

fn isTraversalUnsafe(name: []const u8) bool {
    if (name.len > 0 and name[0] == '/') return true;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

fn destPath(gpa: std.mem.Allocator, dir: ?[]const u8, name: []const u8, junk: bool) ![]const u8 {
    const effective_name = if (junk) fsutil.basename(std.mem.trimEnd(u8, name, "/")) else name;
    if (dir) |d| return fsutil.join(gpa, d, effective_name);
    return gpa.dupe(u8, effective_name);
}

fn ensureParentDir(path: []const u8) void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        fsutil.mkdirP(path[0..idx]) catch {};
    }
}

fn doList(ctx: *Ctx, archive: []const u8, entries: []const zipwriter.CentralEntry, o: ParsedArgs) u8 {
    ctx.print(ctx.stdout, "Archive:  {s}\n", .{archive});
    ctx.print(ctx.stdout, "  Length  Name\n", .{});
    ctx.print(ctx.stdout, "--------  ----\n", .{});
    var total: u64 = 0;
    var count: u32 = 0;
    for (entries) |e| {
        if (!wanted(o.positionals[1..], o.excludes, e.name)) continue;
        var out = textio.BufOut.init(ctx.stdout);
        fmtnum.emitUint(&out, .{ .conv = 'u', .width = 8 }, e.uncompressed_size) catch {};
        out.extend("  ") catch {};
        out.extend(e.name) catch {};
        out.endLine() catch {};
        out.finish() catch {};
        total += e.uncompressed_size;
        count += 1;
    }
    ctx.print(ctx.stdout, "--------  -------\n", .{});
    {
        var out = textio.BufOut.init(ctx.stdout);
        fmtnum.emitUint(&out, .{ .conv = 'u', .width = 8 }, total) catch {};
        out.extend("  ") catch {};
        fmtnum.emitUint(&out, .{ .conv = 'u' }, count) catch {};
        out.extend(" file(s)") catch {};
        out.endLine() catch {};
        out.finish() catch {};
    }
    return 0;
}

fn doTest(ctx: *Ctx, archive: []const u8, bytes: []const u8, entries: []const zipwriter.CentralEntry, o: ParsedArgs) u8 {
    var all_ok = true;
    for (entries) |e| {
        if (!wanted(o.positionals[1..], o.excludes, e.name)) continue;
        if (e.isDir()) continue;
        const data = zipwriter.extractEntry(ctx.gpa, bytes, e) catch {
            ctx.print(ctx.stdout, "    testing: {s}   bad CRC\n", .{e.name});
            all_ok = false;
            continue;
        };
        ctx.gpa.free(data);
        ctx.print(ctx.stdout, "    testing: {s}   OK\n", .{e.name});
    }
    if (all_ok) {
        ctx.print(ctx.stdout, "No errors detected in compressed data of {s}.\n", .{archive});
        return 0;
    }
    return 1;
}

fn doExtract(ctx: *Ctx, bytes: []const u8, entries: []const zipwriter.CentralEntry, o: ParsedArgs) u8 {
    var rc: u8 = 0;
    for (entries) |e| {
        if (!wanted(o.positionals[1..], o.excludes, e.name)) continue;
        if (isTraversalUnsafe(e.name)) {
            ctx.errPrint("unzip: {s}: skipping (unsafe path)\n", .{e.name});
            rc = 1;
            continue;
        }

        if (o.pipe) {
            if (e.isDir()) continue;
            const data = zipwriter.extractEntry(ctx.gpa, bytes, e) catch {
                ctx.errPrint("unzip: {s}: bad CRC\n", .{e.name});
                rc = 1;
                continue;
            };
            ctx.outWrite(data) catch {};
            ctx.gpa.free(data);
            continue;
        }

        const dest = destPath(ctx.gpa, o.dir, e.name, o.junk) catch continue;
        if (e.isDir()) {
            fsutil.mkdirP(dest) catch {};
            if (!o.quiet) ctx.print(ctx.stdout, "   creating: {s}\n", .{dest});
            continue;
        }
        if (o.never_overwrite and fsutil.exists(dest)) continue;
        const data = zipwriter.extractEntry(ctx.gpa, bytes, e) catch {
            ctx.errPrint("unzip: {s}: bad CRC\n", .{e.name});
            rc = 1;
            continue;
        };
        ensureParentDir(dest);
        const fd = sys.open(dest, .{ .write = true, .create = true, .trunc = true }) catch |err| {
            ctx.errPrint("unzip: {s}: {s}\n", .{ dest, sys.strerror(sys.toErrno(err)) });
            ctx.gpa.free(data);
            rc = 1;
            continue;
        };
        sys.writeAll(fd, data) catch {};
        sys.close(fd);
        sys.chmod(dest, if (e.unixMode() == 0) @as(u32, 0o644) else e.unixMode()) catch {};
        ctx.gpa.free(data);
        if (!o.quiet) ctx.print(ctx.stdout, "  inflating: {s}\n", .{dest});
    }
    return rc;
}

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "unzip", "0.1.0", help_doc)) return 0;

    const parsed = parseArgs(ctx.gpa, ctx.args) catch {
        ctx.errPrint("unzip: out of memory\n", .{});
        return 2;
    };
    const o = switch (parsed) {
        .bad_flag => |c| {
            ctx.errPrint("unzip: invalid option -- '{c}'\n", .{c});
            return 2;
        },
        .missing_value => |c| {
            ctx.errPrint("unzip: option -{c} requires a value\n", .{c});
            return 2;
        },
        .ok => |o| o,
    };

    if (o.positionals.len == 0) {
        ctx.errPrint("unzip: missing archive operand\n", .{});
        return 2;
    }
    const archive = o.positionals[0];

    const fd = sys.open(archive, .{ .read = true }) catch |e| {
        ctx.errPrint("unzip: {s}: {s}\n", .{ archive, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    const bytes = textio.readAll(ctx.gpa, fd) catch |e| {
        sys.close(fd);
        ctx.errPrint("unzip: {s}: {s}\n", .{ archive, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    sys.close(fd);

    const entries = zipwriter.listEntries(ctx.gpa, bytes) catch {
        ctx.errPrint("unzip: {s}: not a valid zip file\n", .{archive});
        return 2;
    };

    if (o.list) return doList(ctx, archive, entries, o);
    if (o.test_only) return doTest(ctx, archive, bytes, entries, o);

    if (o.dir) |d| fsutil.mkdirP(d) catch {};
    return doExtract(ctx, bytes, entries, o);
}
