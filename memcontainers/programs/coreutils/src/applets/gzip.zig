//! `gzip` -- DESIGN.md §1: thin CLI over `engines/compress/gzcli.zig`
//! (which wraps `std.compress.flate`). Flags: `-d/--decompress` (+ `--uncompress`
//! alias), `-c/--stdout` (+ `--to-stdout`), `-k/--keep`, `-f/--force`, `-r/--recursive`,
//! `-l/--list`, `-t/--test`, `-q/--quiet` (no-op), `-v/--verbose` (no-op -- the matrix
//! doesn't pin any extra visible effect for it, and the reference is a thin flate2
//! wrapper, not real GNU gzip's per-file percentage chatter; ledgered), `-S/--suffix
//! SUF` (default `.gz`), `--fast`(=1)/`--best`(=9), hidden `-1..-9` digit flags,
//! `-n/--no-name` & `-N/--name` (no-ops), `-V`/`--version` (`--version` is handled by
//! `core/cli.zig`'s universal auto-intercept; `-V` is handled by hand here since that
//! auto-intercept only recognizes the literal long spelling).
//!
//! Level precedence ruling (not pinned by the matrix beyond "--fast=1, --best=9,
//! default 6"): scanned left-to-right over the raw argv tokens (not through
//! `core/cli.zig`'s `Matches`, which loses cross-key ordering), last one wins --
//! `--fast`/`--best`/any `-1`..`-9` digit character in a short cluster (stopping a
//! cluster scan at `S` so `-S9`'s suffix value `"9"` is never mistaken for `-9`).
//! Ledgered in DESIGN.md §2.
//!
//! Whole-file-in-memory model throughout (DESIGN.md §8: compress engines are fed from
//! fixed buffers, not fd-streamed) -- every operand is read to EOF, transformed, then
//! written in one shot. `-l`'s table is spec-authored (`{:>12} {:>12} {:>6} {}`
//! compressed/uncompressed/ratio/name; ratio `100*(1-c/u)` at one decimal place,
//! `renderFloat`+`emitStr` for the right-justified `%`-suffixed column) with no GNU-style
//! header row or totals line (the matrix describes only the per-row shape; the Rust
//! origin is a hand wrapper, not real gzip -- ledgered).

const std = @import("std");
const cli = @import("../core/cli.zig");
const sys = @import("../sys/root.zig");
const fsutil = @import("../core/fsutil.zig");
const textio = @import("../core/textio.zig");
const fmtnum = @import("../core/fmtnum.zig");
const gzcli = @import("../engines/compress/gzcli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "gzip",
    .flags = &.{
        cli.flagOpt('d', "decompress", "decompress"),
        cli.flagOpt(null, "uncompress", "decompress (alias)"),
        cli.flagOpt('c', "stdout", "write to stdout"),
        cli.flagOpt(null, "to-stdout", "write to stdout (alias)"),
        cli.flagOpt('k', "keep", "keep input files"),
        cli.flagOpt('f', "force", "force overwrite"),
        cli.flagOpt('r', "recursive", "recurse into directories"),
        cli.flagOpt('l', "list", "list compressed file contents"),
        cli.flagOpt('t', "test", "test compressed file integrity"),
        cli.flagOpt('q', "quiet", "suppress warnings"),
        cli.flagOpt('v', "verbose", "verbose output"),
        cli.valueOpt('S', "suffix", "use SUF instead of .gz"),
        cli.flagOpt(null, "fast", "compression level 1"),
        cli.flagOpt(null, "best", "compression level 9"),
        cli.flagOpt('1', null, ""),
        cli.flagOpt('2', null, ""),
        cli.flagOpt('3', null, ""),
        cli.flagOpt('4', null, ""),
        cli.flagOpt('5', null, ""),
        cli.flagOpt('6', null, ""),
        cli.flagOpt('7', null, ""),
        cli.flagOpt('8', null, ""),
        cli.flagOpt('9', null, ""),
        cli.flagOpt('n', "no-name", "do not save/restore the file name"),
        cli.flagOpt('N', "name", "save/restore the file name"),
        cli.flagOpt('V', null, "print version"),
    },
    .help = .{
        .summary = "compress or decompress files with DEFLATE",
        .synopsis = &.{
            "gzip [OPTION]... [FILE]...",
            "gzip -d [OPTION]... [FILE]...",
        },
        .description =
        \\Compresses each FILE in place, replacing it with FILE.gz (or FILE plus the
        \\-S suffix), unless -c writes to standard output instead or -k keeps the
        \\original. -d/--decompress (alias --uncompress) reverses the operation,
        \\stripping the suffix to recover the original name. -r recurses into
        \\directory operands (symlinks are skipped). With no FILE, reads standard
        \\input and writes standard output.
        \\
        \\-l lists a compressed file's compressed/uncompressed byte counts,
        \\percentage ratio, and name; -t verifies a file decodes cleanly without
        \\writing any output. Compression level 1-9 is chosen by -1..-9, --fast
        \\(level 1), or --best (level 9) -- scanned over the raw arguments left to
        \\right, so the last one given wins; the default is 6.
        ,
        .operands = "FILE... input files; with no FILE, reads standard input and writes standard output.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a file could not be processed (wrong suffix, not in gzip format, would overwrite an existing file, directory given without -r); the highest code across all operands is returned" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations_from = "GNU gzip",
        .deviations = &.{
            "-v and -q are accepted but are no-ops: there is no per-file percentage chatter.",
            "-n/-N are accepted but are no-ops: the name and timestamp are never stored or restored (the gzip header's MTIME is always 0).",
            "-l's table is a bare row per file (compressed size, uncompressed size, ratio, name); there is no header row or totals line.",
        },
        .examples = &.{
            .{ .cmd = "gzip -k file.txt", .note = "compress, keeping file.txt" },
            .{ .cmd = "gzip -d file.txt.gz", .note = "decompress back to file.txt" },
            .{ .cmd = "gzip -l file.txt.gz", .note = "show compressed/uncompressed sizes and ratio" },
        },
        .see_also = "tar (-z filters an archive through this same codec), zip/unzip.",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

const Mode = enum { compress, decompress, list, test_ };

/// Last-token-wins scan over raw argv (see module doc). `S` stops a cluster scan so its
/// attached value is never misread as a level digit.
fn computeLevel(args: []const [:0]const u8) u8 {
    var level: u8 = 6;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--fast")) {
            level = 1;
            continue;
        }
        if (std.mem.eql(u8, a, "--best")) {
            level = 9;
            continue;
        }
        if (a.len < 2 or a[0] != '-' or a[1] == '-') continue;
        for (a[1..]) |c| {
            if (c == 'S') break;
            if (c >= '1' and c <= '9') level = c - '0';
        }
    }
    return level;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn writeOutputGuarded(ctx: *Ctx, out_path: []const u8, bytes: []const u8, force: bool) bool {
    if (!force and fsutil.exists(out_path)) {
        ctx.errPrint("gzip: {s}: File exists\n", .{out_path});
        return false;
    }
    const fd = sys.open(out_path, .{ .write = true, .create = true, .trunc = true }) catch |e| {
        ctx.errPrint("gzip: {s}: {s}\n", .{ out_path, sys.strerror(sys.toErrno(e)) });
        return false;
    };
    defer sys.close(fd);
    sys.writeAll(fd, bytes) catch |e| {
        ctx.errPrint("gzip: {s}: {s}\n", .{ out_path, sys.strerror(sys.toErrno(e)) });
        return false;
    };
    return true;
}

fn doList(ctx: *Ctx, name: []const u8, bytes: []const u8) u8 {
    if (bytes.len < 10 or bytes[0] != 0x1f or bytes[1] != 0x8b) {
        ctx.errPrint("gzip: {s}: not in gzip format\n", .{name});
        return 1;
    }
    const compressed_len: u64 = bytes.len;
    const uncompressed_len: u64 = gzcli.isizeFromTrailer(bytes) orelse 0;
    const ratio: f64 = if (uncompressed_len == 0)
        0.0
    else
        100.0 * (1.0 - @as(f64, @floatFromInt(compressed_len)) / @as(f64, @floatFromInt(uncompressed_len)));

    var out = textio.BufOut.init(ctx.stdout);
    fmtnum.emitUint(&out, .{ .conv = 'u', .width = 12 }, compressed_len) catch {};
    out.push(' ') catch {};
    fmtnum.emitUint(&out, .{ .conv = 'u', .width = 12 }, uncompressed_len) catch {};
    out.push(' ') catch {};

    var rbuf: [32]u8 = undefined;
    var rsink = fmtnum.FixedSink{ .buf = &rbuf };
    fmtnum.emitFloat(&rsink, .{ .conv = 'f', .precision = 1 }, ratio) catch {};
    rsink.push('%') catch {};
    fmtnum.emitStr(&out, .{ .conv = 's', .width = 6 }, rsink.slice()) catch {};

    out.push(' ') catch {};
    out.extend(name) catch {};
    out.endLine() catch {};
    out.finish() catch {};
    return 0;
}

fn doTest(ctx: *Ctx, name: []const u8, bytes: []const u8) u8 {
    const result = gzcli.decompress(ctx.gpa, bytes) catch {
        ctx.errPrint("gzip: {s}: not in gzip format\n", .{name});
        return 1;
    };
    result.free(ctx.gpa);
    return 0;
}

const Opts = struct {
    level: u8,
    suffix: []const u8,
    keep: bool,
    to_stdout: bool,
    force: bool,
};

fn processFile(ctx: *Ctx, path: []const u8, mode: Mode, o: Opts) u8 {
    const bytes = textio.readFileByPath(ctx.gpa, path) catch |e| {
        ctx.errPrint("gzip: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    defer ctx.gpa.free(bytes);

    switch (mode) {
        .list => return doList(ctx, path, bytes),
        .test_ => return doTest(ctx, path, bytes),
        .decompress => {
            if (!std.mem.endsWith(u8, path, o.suffix)) {
                ctx.errPrint("gzip: {s}: unknown suffix -- ignored\n", .{path});
                return 1;
            }
            const stem = path[0 .. path.len - o.suffix.len];
            if (stem.len == 0) {
                ctx.errPrint("gzip: {s}: invalid name\n", .{path});
                return 1;
            }
            const result = gzcli.decompress(ctx.gpa, bytes) catch {
                ctx.errPrint("gzip: {s}: not in gzip format\n", .{path});
                return 1;
            };
            defer result.free(ctx.gpa);
            if (o.to_stdout) {
                ctx.outWrite(result.data) catch {};
                return 0;
            }
            if (!writeOutputGuarded(ctx, stem, result.data, o.force)) return 1;
            if (!o.keep) sys.unlink(path) catch {};
            return 0;
        },
        .compress => {
            const compressed = gzcli.compress(ctx.gpa, bytes, o.level) catch {
                ctx.errPrint("gzip: {s}: compression failed\n", .{path});
                return 1;
            };
            defer ctx.gpa.free(compressed);
            if (o.to_stdout) {
                ctx.outWrite(compressed) catch {};
                return 0;
            }
            const out_name = std.mem.concat(ctx.gpa, u8, &.{ path, o.suffix }) catch return 1;
            defer ctx.gpa.free(out_name);
            if (!writeOutputGuarded(ctx, out_name, compressed, o.force)) return 1;
            if (!o.keep) sys.unlink(path) catch {};
            return 0;
        },
    }
}

fn collectFiles(gpa: std.mem.Allocator, dir: []const u8, out: *std.ArrayListUnmanaged([]const u8)) void {
    const names = fsutil.list(gpa, dir) catch return;
    defer fsutil.freeList(gpa, names);
    std.mem.sort([]const u8, names, {}, lessThanStr);
    for (names) |name| {
        const child = fsutil.join(gpa, dir, name) catch continue;
        const st = sys.lstat(child) catch continue;
        if (st.is_dir) {
            collectFiles(gpa, child, out);
        } else if (!st.is_symlink) {
            out.append(gpa, child) catch {};
        }
    }
}

fn processOperand(ctx: *Ctx, path: []const u8, mode: Mode, o: Opts, recursive: bool) u8 {
    const st = sys.lstat(path) catch |e| {
        ctx.errPrint("gzip: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    if (st.is_dir) {
        if (!recursive) {
            ctx.errPrint("gzip: {s}: is a directory\n", .{path});
            return 1;
        }
        var files: std.ArrayListUnmanaged([]const u8) = .empty;
        collectFiles(ctx.gpa, path, &files);
        var rc: u8 = 0;
        for (files.items) |f| {
            const r = processFile(ctx, f, mode, o);
            if (r > rc) rc = r;
        }
        return rc;
    }
    return processFile(ctx, path, mode, o);
}

fn runStdin(ctx: *Ctx, mode: Mode, level: u8) u8 {
    const bytes = textio.readAll(ctx.gpa, ctx.stdin) catch |e| {
        ctx.errPrint("gzip: stdin: {s}\n", .{sys.strerror(sys.toErrno(e))});
        return 1;
    };
    defer ctx.gpa.free(bytes);
    switch (mode) {
        .list => return doList(ctx, "stdin", bytes),
        .test_ => return doTest(ctx, "stdin", bytes),
        .decompress => {
            const result = gzcli.decompress(ctx.gpa, bytes) catch {
                ctx.errPrint("gzip: stdin: not in gzip format\n", .{});
                return 1;
            };
            defer result.free(ctx.gpa);
            ctx.outWrite(result.data) catch {};
            return 0;
        },
        .compress => {
            const compressed = gzcli.compress(ctx.gpa, bytes, level) catch {
                ctx.errPrint("gzip: stdin: compression failed\n", .{});
                return 1;
            };
            defer ctx.gpa.free(compressed);
            ctx.outWrite(compressed) catch {};
            return 0;
        },
    }
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    if (m.has("V")) {
        ctx.print(ctx.stdout, "{s} {s}\n", .{ "gzip", "0.1.0" });
        return 0;
    }

    const level = computeLevel(ctx.args[1..]);
    const decompress_flag = m.has("decompress") or m.has("uncompress");
    const mode: Mode = if (m.has("list")) .list else if (m.has("test")) .test_ else if (decompress_flag) .decompress else .compress;

    const o = Opts{
        .level = level,
        .suffix = m.value("suffix") orelse ".gz",
        .keep = m.has("keep"),
        .to_stdout = m.has("stdout") or m.has("to-stdout"),
        .force = m.has("force"),
    };
    const recursive = m.has("recursive");

    const files = m.positionalSlice();
    if (files.len == 0) return runStdin(ctx, mode, level);

    var rc: u8 = 0;
    for (files) |f| {
        const r = processOperand(ctx, f, mode, o, recursive);
        if (r > rc) rc = r;
    }
    return rc;
}
