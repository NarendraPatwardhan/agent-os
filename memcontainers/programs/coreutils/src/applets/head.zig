//! `head` -- DESIGN.md §1: raw byte counting (no `LineReader`, byte-exact
//! streaming). `-c/--bytes N` first N bytes, `-n/--lines N` first N lines (default 10),
//! obsolete `-N` (e.g. `head -5`) rewritten to `-n N` by an argv pre-pass. Count parsed
//! by a custom decimal-only parser (non-digit => 0). Multi-file => `==> NAME <==`
//! headers with a blank line between files; stdin header = `==> standard input <==`. No
//! CRLF normalization. Exit: 0; 1 if a FILE can't open; 2 usage.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "head",
    .flags = &.{
        cli.valueOpt('c', "bytes", "print the first NUM bytes of each file"),
        cli.valueOpt('n', "lines", "print the first NUM lines of each file"),
    },
    .help = .{
        .summary = "output the first part of files",
        .synopsis = &.{"head [OPTION]... [FILE]..."},
        .description =
        \\Prints the first part of each FILE to standard output, streaming rather
        \\than buffering the whole file. With -c, prints the first NUM bytes; with
        \\-n (the default), prints the first NUM lines (default 10). With more
        \\than one FILE, each is preceded by a `==> NAME <==` header, and headers
        \\are separated by a blank line.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened (remaining files are still processed)" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "-n/-c accept only a plain non-negative decimal count: no negative counts (GNU's \"all but the last N\" extension) and no K/M/G suffix multipliers; a malformed count is silently treated as 0.",
            "No -q/--quiet or -v/--verbose (multi-file headers always print automatically, single-file never prints one).",
        },
        .examples = &.{
            .{ .cmd = "head -n 5 file.txt", .note = "the first 5 lines" },
            .{ .cmd = "head -c 100 file.txt", .note = "the first 100 bytes" },
            .{ .cmd = "head -5 file.txt", .note = "obsolete form, equivalent to -n 5" },
        },
        .see_also = "tail (the last part of files).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// Decimal-only, non-digit (or empty) => 0 -- matches the matrix's `parse_usize`.
fn parseCount(s: []const u8) usize {
    if (s.len == 0) return 0;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return 0;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn isObsoleteForm(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    for (a[1..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// `head -5` -> `head -n 5` (only the leading argument is eligible, matching the
/// historical single obsolete-form slot).
fn rewriteObsolete(gpa: std.mem.Allocator, args: []const [:0]const u8) []const [:0]const u8 {
    if (args.len < 2 or !isObsoleteForm(args[1])) return args;
    var out = gpa.alloc([:0]const u8, args.len + 1) catch @panic("OOM");
    out[0] = args[0];
    out[1] = "-n";
    out[2] = gpa.dupeZ(u8, args[1][1..]) catch @panic("OOM");
    @memcpy(out[3..], args[2..]);
    return out;
}

fn headBytes(ctx: *Ctx, fd: sys.Fd, n: usize) bool {
    var remaining = n;
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const want = @min(remaining, buf.len);
        const r = sys.read(fd, buf[0..want]) catch return true;
        if (r == 0) return false;
        ctx.outWrite(buf[0..r]) catch return true;
        remaining -= r;
    }
    return false;
}

fn headLines(ctx: *Ctx, fd: sys.Fd, n: usize) bool {
    if (n == 0) return false;
    var seen: usize = 0;
    var buf: [4096]u8 = undefined;
    while (true) {
        const r = sys.read(fd, &buf) catch return true;
        if (r == 0) return false;
        var i: usize = 0;
        while (i < r) : (i += 1) {
            if (buf[i] == '\n') {
                seen += 1;
                if (seen == n) {
                    ctx.outWrite(buf[0 .. i + 1]) catch return true;
                    return false;
                }
            }
        }
        ctx.outWrite(buf[0..r]) catch return true;
    }
}

pub fn run(ctx: *Ctx) u8 {
    const args = rewriteObsolete(ctx.gpa, ctx.args);
    var ctx2 = ctx.*;
    ctx2.args = args;
    const res = cli.parse(&ctx2, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const use_bytes = m.has("bytes");
    const n: usize = if (use_bytes)
        parseCount(m.value("bytes").?)
    else if (m.has("lines"))
        parseCount(m.value("lines").?)
    else
        10;

    var files_buf: [256][]const u8 = undefined;
    var file_count: usize = 0;
    for (m.positionalSlice()) |f| {
        if (file_count < files_buf.len) {
            files_buf[file_count] = f;
            file_count += 1;
        }
    }
    const files = files_buf[0..file_count];
    const multi = files.len > 1;

    var rc: u8 = 0;
    if (files.len == 0) {
        _ = if (use_bytes) headBytes(ctx, ctx.stdin, n) else headLines(ctx, ctx.stdin, n);
        return rc;
    }

    var first = true;
    for (files) |file| {
        const is_stdin = std.mem.eql(u8, file, "-");
        if (multi) {
            if (!first) ctx.outPrint("\n", .{});
            const label: []const u8 = if (is_stdin) "standard input" else file;
            ctx.outPrint("==> {s} <==\n", .{label});
        }
        first = false;
        const fd = if (is_stdin) ctx.stdin else sys.open(file, .{ .read = true }) catch |e| {
            ctx.errPrint("head: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);
        const stop = if (use_bytes) headBytes(ctx, fd, n) else headLines(ctx, fd, n);
        if (stop) break;
    }
    return rc;
}
