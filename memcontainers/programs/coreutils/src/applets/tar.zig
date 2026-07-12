//! `tar` -- DESIGN.md §1: USTAR archiver over `engines/archive/tarx.zig`
//! + the compress engines (`gzcli.zig` gzip both ways, `bzip2.zig` decode-only,
//! `std.compress.xz` decode-only).
//!
//! Modes `-c`/`-x`/`-t` (exactly one required); `-r`/`-u` are recognized only to reject
//! with the matrix's "Unsupported" error. Compression: `-z` (gzip, both directions on
//! create/extract), `-j`/`-J` (bzip2/xz, decode-only -- `-cj`/`-cJ` error). On
//! extract/list, the actual codec is auto-detected by magic bytes regardless of which
//! of `-z/-j/-J` was passed (matches the reference's `open_reader`), so those flags
//! only gate what's *allowed* on create. `-f ARCHIVE` (`-` = stdin/stdout) is required.
//! `-C DIR` chdirs before any archive I/O. `-v` prints member names (to stderr instead
//! of stdout when the archive itself is being written to/read from stdout/stdin, so
//! verbose chatter never corrupts the archive stream -- a ledgered ruling, the matrix
//! doesn't pin the exact stream). `-k`/`--keep-old-files` skips (does not error on) an
//! existing extract destination. `-O`/`--to-stdout` streams file contents to stdout
//! instead of writing them, no directory/symlink creation. `-p`/`-m` are silent
//! no-ops. `--strip-components N` drops N leading path components (entries left with
//! nothing are skipped). `--exclude PATTERN` (repeatable) globs against the
//! (post-strip) member name via `engines/glob.zig`. `-h` is help, not GNU's
//! dereference (the reference doesn't support dereferencing).
//!
//! Old bare-cluster form (`tar cf x.tar`) is rewritten to `-cf x.tar` before flag
//! parsing, matching GNU/BSD tar's historical grammar. Create strips a single leading
//! `/` from operand paths (tar never stores absolute member names). Extract rejects
//! path traversal (`/`-rooted or containing a literal `..` component, checked *after*
//! `--strip-components`); hardlink and any other unsupported entry type (char/block
//! device, fifo, contiguous) are skipped with a notice, matching the matrix's "skipped
//! with notice" for symlink/hardlink (generalized to any unsupported type, since the
//! `tar` crate's own reader only special-cases file/dir/symlink/hardlink and reports
//! everything else as a diagnostic, not a hard error -- ledgered).
//!
//! Exit: 0 normal completion (including entries skipped with a notice -- the matrix
//! pins tar's exit code to exactly 0/2, no intermediate warning status), 2 for usage
//! errors or a fatal `tar: <err>`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const sys = @import("../sys/root.zig");
const fsutil = @import("../core/fsutil.zig");
const textio = @import("../core/textio.zig");
const glob = @import("../engines/glob.zig");
const tarx = @import("../engines/archive/tarx.zig");
const gzcli = @import("../engines/compress/gzcli.zig");
const bzip2 = @import("../engines/compress/bzip2.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "tar",
    .flags = &.{
        cli.flagOpt('c', "create", "create an archive"),
        cli.flagOpt('x', "extract", "extract an archive"),
        cli.flagOpt('t', "list", "list an archive's contents"),
        cli.flagOpt('r', "append", "append (unsupported)"),
        cli.flagOpt('u', "update", "update (unsupported)"),
        cli.flagOpt('z', "gzip", "filter through gzip"),
        cli.flagOpt('j', "bzip2", "filter through bzip2 (decode-only)"),
        cli.flagOpt('J', "xz", "filter through xz (decode-only)"),
        cli.valueOpt('f', "file", "archive file (- = stdio)"),
        cli.valueOpt('C', "directory", "change to DIR before any operation"),
        cli.flagOpt('v', "verbose", "verbosely list files processed"),
        cli.flagOpt('k', "keep-old-files", "don't overwrite existing files on extract"),
        cli.flagOpt('O', "to-stdout", "extract files to stdout"),
        cli.flagOpt('p', "preserve-permissions", "no-op"),
        cli.flagOpt('m', "touch", "no-op"),
        cli.valueOpt(null, "strip-components", "strip N leading path components"),
        cli.valueOpt(null, "exclude", "exclude paths matching PATTERN"),
        cli.flagOpt('h', null, "print help (not dereference)"),
    },
    .help = .{
        .summary = "create, list, or extract a tar archive",
        .synopsis = &.{
            "tar -c -f ARCHIVE [OPTION]... [FILE]...",
            "tar -x -f ARCHIVE [OPTION]... [FILE]...",
            "tar -t -f ARCHIVE [OPTION]...",
        },
        .description =
        \\Creates (-c), extracts (-x), or lists (-t) a USTAR archive; exactly one of
        \\the three modes is required, along with -f ARCHIVE (- means standard
        \\input/output). The historical bare-letter grammar is also accepted:
        \\"tar cf x.tar file" is rewritten to "tar -cf x.tar file" before parsing.
        \\
        \\-z filters the archive through gzip in both directions. -j (bzip2) and -J
        \\(xz) are decode-only: creating an archive with either is rejected, but
        \\reading auto-detects the actual codec by magic bytes regardless of which
        \\of -z/-j/-J (if any) was given. On extract, path-traversal entries and
        \\entry types other than file/directory/symlink are skipped with a stderr
        \\notice rather than aborting the whole run.
        ,
        .operands = "FILE... names to add on create (a single leading '/' is stripped); ignored for -x/-t, which use the archive's own stored names.",
        .exit = &.{
            .{ .code = 0, .when = "success, including runs where individual entries were skipped with a notice" },
            .{ .code = 2, .when = "usage error, or a fatal tar: <message> (bad/missing archive, missing -f, unsupported -r/-u, create+bzip2/xz)" },
        },
        .deviations_from = "GNU tar",
        .deviations = &.{
            "-r/-u (append/update) are recognized only to reject with an error; there is no append or update support.",
            "Creating with -j/-J is rejected (bzip2/xz are decode-only); reading still auto-detects the codec by magic bytes regardless of -z/-j/-J.",
            "-h prints this help, not GNU's dereference-symlinks option; dereferencing on create isn't supported.",
            "Hardlink entries, and any entry type other than file/dir/symlink, are skipped with a notice instead of erroring; extraction continues and the run still exits 0.",
            "-p/-m are accepted but are silent no-ops.",
        },
        .examples = &.{
            .{ .cmd = "tar -cf out.tar dir/", .note = "create out.tar from dir/" },
            .{ .cmd = "tar -tzf out.tar.gz", .note = "list a gzip-compressed archive (codec auto-detected)" },
            .{ .cmd = "tar -xf out.tar -C /tmp --strip-components 1", .note = "extract, dropping the first path component" },
        },
        .see_also = "gzip (standalone compression), zip/unzip (the ZIP format).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// GNU/BSD tar's historical grammar: a first argument not starting with `-`, composed
/// only of recognized single-letter flag characters, is treated as a bundled short
/// option cluster (`tar cf x.tar` == `tar -cf x.tar`).
fn oldStyleRewrite(gpa: std.mem.Allocator, args: []const [:0]const u8) ![]const [:0]const u8 {
    if (args.len < 2) return args;
    const first = args[1];
    if (first.len == 0 or first[0] == '-') return args;
    for (first) |c| {
        if (std.mem.indexOfScalar(u8, "cxtzjJfvkOpmh", c) == null) return args;
    }
    const rewritten = try gpa.allocSentinel(u8, first.len + 1, 0);
    rewritten[0] = '-';
    @memcpy(rewritten[1..], first);
    var out = try gpa.alloc([:0]const u8, args.len);
    out[0] = args[0];
    out[1] = rewritten;
    for (args[2..], 2..) |a, i| out[i] = a;
    return out;
}

fn stripLeadingSlash(name: []const u8) []const u8 {
    if (name.len > 0 and name[0] == '/') return name[1..];
    return name;
}

fn stripComponents(name: []const u8, n: u32) ?[]const u8 {
    var rest = name;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash + 1 ..];
    }
    if (rest.len == 0) return null;
    return rest;
}

fn isTraversalUnsafe(name: []const u8) bool {
    if (name.len > 0 and name[0] == '/') return true;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

fn matchesAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| {
        if (glob.match(p, name)) return true;
    }
    return false;
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const xz_magic = [_]u8{ 0xFD, '7', 'z', 'X', 'Z', 0x00 };

/// Auto-detects the codec by magic bytes and returns a `gpa`-owned plain-tar byte
/// buffer (a copy is made even when no container is detected, so callers always free
/// uniformly).
fn loadPlainTar(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len >= 2 and raw[0] == 0x1f and raw[1] == 0x8b) {
        const r = try gzcli.decompress(gpa, raw);
        return r.data;
    }
    if (raw.len >= 3 and raw[0] == 'B' and raw[1] == 'Z' and raw[2] == 'h') {
        return bzip2.decompress(gpa, raw);
    }
    if (raw.len >= 6 and std.mem.eql(u8, raw[0..6], &xz_magic)) {
        var in_reader = std.Io.Reader.fixed(raw);
        const buffer: []u8 = &.{};
        var dec = try std.compress.xz.Decompress.init(&in_reader, gpa, buffer);
        defer dec.deinit();
        var list: std.ArrayListUnmanaged(u8) = .empty;
        dec.reader.appendRemainingUnlimited(gpa, &list) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptArchive,
        };
        return list.toOwnedSlice(gpa);
    }
    return gpa.dupe(u8, raw);
}

fn readArchiveBytes(ctx: *Ctx, archive: []const u8) ![]u8 {
    if (std.mem.eql(u8, archive, "-")) return textio.readAll(ctx.gpa, ctx.stdin);
    return textio.readFileByPath(ctx.gpa, archive);
}

fn ensureParentDir(path: []const u8) void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        fsutil.mkdirP(path[0..idx]) catch {};
    }
}

fn writeFileMode(path: []const u8, data: []const u8, mode: u32) sys.Error!void {
    const fd = try sys.open(path, .{ .write = true, .create = true, .trunc = true });
    defer sys.close(fd);
    try sys.writeAll(fd, data);
    sys.chmod(path, if (mode == 0) @as(u32, 0o644) else mode) catch {};
}

// ============================================================================ create

const CreateOpts = struct {
    excludes: []const []const u8,
    verbose: bool,
    verbose_fd: sys.Fd,
};

fn addPathRecursive(ctx: *Ctx, w: *tarx.Writer, path: []const u8, member_name: []const u8, o: CreateOpts) void {
    if (matchesAny(o.excludes, member_name)) return;
    const st = sys.lstat(path) catch |e| {
        ctx.errPrint("tar: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return;
    };
    const mtime_s: i64 = @divFloor(st.mtime_ms, 1000);

    if (st.is_symlink) {
        var buf: [4096]u8 = undefined;
        const n = sys.readlink(path, &buf) catch |e| {
            ctx.errPrint("tar: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
            return;
        };
        w.addSymlink(member_name, 0o777, mtime_s, buf[0..n]) catch @panic("OOM");
        if (o.verbose) ctx.print(o.verbose_fd, "{s}\n", .{member_name});
        return;
    }
    if (st.is_dir) {
        w.addDir(member_name, 0o755, mtime_s) catch @panic("OOM");
        if (o.verbose) ctx.print(o.verbose_fd, "{s}/\n", .{member_name});
        const names = fsutil.list(ctx.gpa, path) catch return;
        std.mem.sort([]const u8, names, {}, lessThanStr);
        for (names) |name| {
            const child_path = fsutil.join(ctx.gpa, path, name) catch continue;
            const child_member = std.mem.concat(ctx.gpa, u8, &.{ member_name, "/", name }) catch continue;
            addPathRecursive(ctx, w, child_path, child_member, o);
        }
        return;
    }
    const bytes = textio.readFileByPath(ctx.gpa, path) catch |e| {
        ctx.errPrint("tar: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return;
    };
    w.addFile(member_name, 0o644, mtime_s, bytes) catch @panic("OOM");
    if (o.verbose) ctx.print(o.verbose_fd, "{s}\n", .{member_name});
}

fn doCreate(ctx: *Ctx, operands: []const []const u8, archive: []const u8, gzip: bool, o: CreateOpts) u8 {
    var w = tarx.Writer.init(ctx.gpa);
    for (operands) |path| {
        const member = stripLeadingSlash(path);
        addPathRecursive(ctx, &w, path, member, o);
    }
    const tar_bytes = w.finish() catch {
        ctx.errPrint("tar: out of memory\n", .{});
        return 2;
    };

    const final_bytes = if (gzip)
        gzcli.compress(ctx.gpa, tar_bytes, 6) catch {
            ctx.errPrint("tar: compression failed\n", .{});
            return 2;
        }
    else
        tar_bytes;

    if (std.mem.eql(u8, archive, "-")) {
        ctx.outWrite(final_bytes) catch {};
        return 0;
    }
    const fd = sys.open(archive, .{ .write = true, .create = true, .trunc = true }) catch |e| {
        ctx.errPrint("tar: {s}: {s}\n", .{ archive, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    defer sys.close(fd);
    sys.writeAll(fd, final_bytes) catch |e| {
        ctx.errPrint("tar: {s}: {s}\n", .{ archive, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    return 0;
}

// ============================================================================ extract / list

const ReadOpts = struct {
    excludes: []const []const u8,
    strip: u32,
    keep: bool,
    to_stdout: bool,
    verbose: bool,
    verbose_fd: sys.Fd,
    list_only: bool,
};

fn processArchive(ctx: *Ctx, plain: []const u8, o: ReadOpts) u8 {
    var it = tarx.Iterator.init(plain);
    while (true) {
        const maybe = it.next(ctx.gpa) catch {
            ctx.errPrint("tar: corrupt archive\n", .{});
            return 2;
        };
        const e = maybe orelse break;
        var name = e.name;
        if (o.strip > 0) {
            name = stripComponents(name, o.strip) orelse continue;
        }
        if (matchesAny(o.excludes, name)) continue;

        if (o.list_only) {
            ctx.print(ctx.stdout, "{s}\n", .{name});
            continue;
        }

        if (isTraversalUnsafe(name)) {
            ctx.errPrint("tar: {s}: skipping (unsafe path)\n", .{name});
            continue;
        }

        switch (e.kind) {
            .dir => {
                if (o.to_stdout) continue;
                fsutil.mkdirP(name) catch {};
                if (o.verbose) ctx.print(o.verbose_fd, "{s}\n", .{name});
            },
            .file => {
                if (o.to_stdout) {
                    ctx.outWrite(e.data) catch {};
                    continue;
                }
                if (o.keep and fsutil.exists(name)) continue;
                ensureParentDir(name);
                writeFileMode(name, e.data, e.mode) catch |err| {
                    ctx.errPrint("tar: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(err)) });
                    continue;
                };
                if (o.verbose) ctx.print(o.verbose_fd, "{s}\n", .{name});
            },
            .symlink => {
                if (o.to_stdout) continue;
                if (o.keep and fsutil.exists(name)) continue;
                ensureParentDir(name);
                sys.unlink(name) catch {};
                sys.symlink(e.linkname, name) catch |err| {
                    ctx.errPrint("tar: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(err)) });
                    continue;
                };
                if (o.verbose) ctx.print(o.verbose_fd, "{s}\n", .{name});
            },
            .hardlink, .unsupported => {
                ctx.errPrint("tar: {s}: skipping unsupported entry type\n", .{name});
            },
        }
    }
    return 0;
}

// ============================================================================ run

pub fn run(ctx: *Ctx) u8 {
    const rewritten = oldStyleRewrite(ctx.gpa, ctx.args) catch ctx.args;
    var shadow = Ctx{ .args = rewritten, .gpa = ctx.gpa, .stdin = ctx.stdin, .stdout = ctx.stdout, .stderr = ctx.stderr };

    const res = cli.parse(&shadow, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    if (m.has("h")) {
        ctx.print(ctx.stdout, "Usage: tar -c|-x|-t -f ARCHIVE [FILE...]\n", .{});
        return 0;
    }

    if (m.has("append") or m.has("update")) {
        ctx.errPrint("tar: appending is not supported\n", .{});
        return 2;
    }

    const do_create = m.has("create");
    const do_extract = m.has("extract");
    const do_list = m.has("list");
    const mode_count: u8 = @intFromBool(do_create) + @intFromBool(do_extract) + @intFromBool(do_list);
    if (mode_count != 1) {
        ctx.errPrint("tar: must specify exactly one of -c, -x, -t\n", .{});
        return 2;
    }

    const archive = m.value("file") orelse {
        ctx.errPrint("tar: -f is required\n", .{});
        return 2;
    };

    const gzip = m.has("gzip");
    const bzip2_flag = m.has("bzip2");
    const xz_flag = m.has("xz");
    if (do_create and (bzip2_flag or xz_flag)) {
        ctx.errPrint("tar: bzip2/xz compression is not supported for archive creation\n", .{});
        return 2;
    }

    if (m.value("directory")) |dir| {
        sys.chdir(dir) catch |e| {
            ctx.errPrint("tar: {s}: {s}\n", .{ dir, sys.strerror(sys.toErrno(e)) });
            return 2;
        };
    }

    const verbose = m.has("verbose");
    const to_stdout_archive = std.mem.eql(u8, archive, "-");
    const to_stdout_data = m.has("to-stdout");
    // Verbose chatter must never land on the same stream as archive bytes.
    const verbose_fd: sys.Fd = if ((do_create and to_stdout_archive) or (!do_create and to_stdout_data))
        ctx.stderr
    else
        ctx.stdout;

    const excludes = m.values("exclude");
    const strip: u32 = if (m.value("strip-components")) |s|
        std.fmt.parseInt(u32, s, 10) catch 0
    else
        0;

    if (do_create) {
        const operands = m.positionalSlice();
        return doCreate(ctx, operands, archive, gzip, .{ .excludes = excludes, .verbose = verbose, .verbose_fd = verbose_fd });
    }

    const raw = readArchiveBytes(ctx, archive) catch |e| {
        ctx.errPrint("tar: {s}: {s}\n", .{ archive, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    const plain = loadPlainTar(ctx.gpa, raw) catch {
        ctx.errPrint("tar: {s}: not a valid archive\n", .{archive});
        return 2;
    };

    return processArchive(ctx, plain, .{
        .excludes = excludes,
        .strip = strip,
        .keep = m.has("keep-old-files"),
        .to_stdout = to_stdout_data,
        .verbose = verbose,
        .verbose_fd = verbose_fd,
        .list_only = do_list,
    });
}
