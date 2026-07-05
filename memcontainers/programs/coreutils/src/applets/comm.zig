//! `comm` -- uutils 0.9.0 parity port (reference/uutils-coreutils/src/uu/comm/src/comm.rs).
//! Reads two individually-SORTED files line by line and does a 3-way merge in RAW BYTE
//! order (no locale collation): col 1 = lines only in FILE1, col 2 = lines only in
//! FILE2, col 3 = lines in both. `-1`/`-2`/`-3` suppress the corresponding column
//! (not printed at all -- not even blank). `--output-delimiter=STR` (default TAB,
//! repeatable but every occurrence must be textually identical or it's a fatal
//! `multiple conflicting output delimiters specified`; an empty STR is normalized to a
//! single NUL byte). `-z`/`--zero-terminated` makes the line terminator NUL on both
//! input and output. `--total` appends a `n1<delim>n2<delim>n3<delim>total<term>`
//! summary line (delim used verbatim, never repeated; counts include lines whose
//! column was suppressed). A directory operand is `comm: {path}: Is a directory`
//! (exit 1); any other open/stat failure is `comm: {path}: {strerror}` (exit 1).
//!
//! Column prefixes: col 2 lines get `delim` repeated `width_col_1` times (0 if `-1`,
//! else 1); col 3 lines get `delim` repeated `width_col_1 + width_col_2` times; col 1
//! lines never get a prefix. Byte-model deviation from the Rust source (ruling,
//! documented in the parity report handed back with this port): the Rust reader keeps
//! the line terminator IN the compared/written buffer; this port strips it on read and
//! re-appends the chosen terminator on write, which is comparison-equivalent for
//! individually sorted ASCII input (the terminator byte is lower than any content byte
//! that would otherwise tie) and lets one bespoke NUL/`\n`-parametrized reader serve
//! both `-z` and default modes without touching the shared `textio.LineReader` (which
//! is `\n`-only and strips a trailing `\r` that `comm` must NOT strip).
//!
//! Order checking (see `comm()` in the Rust source): `should_check_order =
//! !nocheck_order && (check_order || !same_or_identical(FILE1, FILE2))` -- i.e. by
//! default, order is checked UNLESS the two operands are the same path or have
//! byte-identical contents (a file trivially "agrees" with itself). A first
//! out-of-order line in a given input prints `comm: file N is not in sorted order` to
//! stderr exactly once (has_error latch); with explicit `--check-order` this is fatal
//! (the merge loop stops immediately, before printing that line); under the *implicit*
//! (heuristic) checking path it is NOT fatal -- processing runs to EOF, and iff any
//! violation was seen this way, an extra `comm: input is not in sorted order` line is
//! printed at the very end, alongside the (still nonzero) exit code. `--nocheck-order`
//! disables all of the above unconditionally.
//!
//! Same-file heuristic (ruling): `-` (stdin) never triggers the same-file skip.
//! Otherwise two operands are treated as "the same file" if their argument strings are
//! textually identical, or (as a fallback, approximating uutils'
//! `are_files_identical`) their sizes and full byte contents match -- this port has no
//! stat dev/ino (`sys.Stat` carries no inode fields), so true hardlink/bind-mount
//! detection is out of scope; this is a defensible, documented simplification.
//!
//! `--check-order`/`--nocheck-order` together: clap's `.conflicts_with` makes this a
//! parse-level error; verified against the oracle binary, the message echoes whichever
//! of the two flags appeared FIRST on the command line as "the argument", and the
//! other as what it "cannot be used with" -- reproduced verbatim here by scanning the
//! raw argv for first-occurrence order (ruling: full clap fidelity was cheap enough to
//! just do).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "comm",
    .flags = &.{
        cli.flagOpt('1', null, "suppress column 1 (lines unique to FILE1)"),
        cli.flagOpt('2', null, "suppress column 2 (lines unique to FILE2)"),
        cli.flagOpt('3', null, "suppress column 3 (lines that appear in both files)"),
        cli.valueOpt(null, "output-delimiter", "separate columns with STR"),
        cli.flagOpt('z', "zero-terminated", "line delimiter is NUL, not newline"),
        cli.flagOpt(null, "total", "output a summary"),
        cli.flagOpt(null, "check-order", "check that the input is correctly sorted, even if all input lines are pairable"),
        cli.flagOpt(null, "nocheck-order", "do not check that the input is correctly sorted"),
    },
    .help = .{
        .summary = "compare two sorted files line by line",
        .synopsis = &.{"comm [OPTION]... FILE1 FILE2"},
        .description =
        \\Reads FILE1 and FILE2 -- each assumed already sorted in raw byte
        \\order -- and writes three columns: lines only in FILE1, lines only
        \\in FILE2, and lines common to both, separated by
        \\--output-delimiter (default TAB; an empty STR is treated as a
        \\single NUL byte). -1/-2/-3 suppress the corresponding column
        \\entirely (nothing is printed for it, not even a blank field).
        \\
        \\-z uses NUL instead of newline as the line terminator on both input
        \\and output. --total appends a final summary line of the form
        \\`N1<delim>N2<delim>N3<delim>total`. Input order is checked by
        \\default (a first violation prints a warning once and, unless
        \\--check-order was given explicitly, processing continues to EOF);
        \\--nocheck-order disables the check entirely.
        ,
        .operands = "FILE1 and FILE2 (both required); either may be \"-\" for standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened (or is a directory), the input was found out of sorted order under checking, or --check-order and --nocheck-order were both given" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "The \"same file\" heuristic that decides whether order-checking applies compares the argument strings and, failing that, file size plus full byte-for-byte content -- there is no inode/device comparison, so hardlinks or bind-mounts of the same file are not detected as identical.",
        },
        .examples = &.{
            .{ .cmd = "comm sorted1.txt sorted2.txt", .note = "three columns: unique to 1, unique to 2, common to both" },
            .{ .cmd = "comm -12 sorted1.txt sorted2.txt", .note = "print only the lines common to both files" },
            .{ .cmd = "comm --total a.txt b.txt", .note = "append a final summary count line" },
        },
        .see_also = "diff (line-level differences without requiring sorted input); sort/uniq (produce the sorted input comm expects).",
    },
    .positionals = .{ .name = "FILE", .min = 2, .max = 2 },
};

const NUL_DELIM = [1]u8{0};

// ------------------------------------------------------------------ line reader

/// Bespoke line reader parametrized on the terminator byte (`\n` or NUL for `-z`);
/// unlike `textio.LineReader` this does NOT strip a trailing `\r` (comm's byte model
/// preserves the line verbatim -- the Rust source never touches `\r`). Returned lines
/// are duped into `gpa` so callers may retain the previous line across reads (needed
/// for order-check history), trading the bounded-memory ideal other filters chase for
/// straightforward correctness on an applet whose own reference implementation is not
/// bounded-memory either (it keeps a growable `Vec<u8>` per side).
const CommReader = struct {
    fd: sys.Fd,
    term: u8,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    fn init(fd: sys.Fd, term: u8) CommReader {
        return .{ .fd = fd, .term = term };
    }

    fn fill(self: *CommReader) sys.Error!void {
        if (self.start > 0) {
            const remaining = self.end - self.start;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.start..self.end]);
            self.start = 0;
            self.end = remaining;
        }
        if (self.end == self.buf.len) return;
        const n = try sys.read(self.fd, self.buf[self.end..]);
        if (n == 0) {
            self.eof = true;
            return;
        }
        self.end += n;
    }

    fn next(self: *CommReader, gpa: std.mem.Allocator) sys.Error!?[]const u8 {
        while (true) {
            if (self.start < self.end) {
                if (std.mem.indexOfScalar(u8, self.buf[self.start..self.end], self.term)) |rel| {
                    const line_end = self.start + rel;
                    const line = self.buf[self.start..line_end];
                    self.start = line_end + 1;
                    return gpa.dupe(u8, line) catch return error.ENOMEM;
                }
                if (self.end - self.start == self.buf.len) {
                    const line = self.buf[self.start..self.end];
                    self.start = self.end;
                    return gpa.dupe(u8, line) catch return error.ENOMEM;
                }
            }
            if (self.eof) {
                if (self.start < self.end) {
                    const line = self.buf[self.start..self.end];
                    self.start = self.end;
                    return gpa.dupe(u8, line) catch return error.ENOMEM;
                }
                return null;
            }
            try self.fill();
        }
    }
};

// ------------------------------------------------------------------ order checking

const OrderChecker = struct {
    last: ?[]const u8 = null,
    /// Mirrors the Rust `OrderChecker.check_order` field: true only when
    /// `--check-order` was given EXPLICITLY (not the implicit/heuristic path).
    explicit_check_order: bool,
    has_error: bool = false,
    file_num: u8,

    /// Returns whether the merge loop may continue (false = fatal, caller breaks).
    fn verify(self: *OrderChecker, ctx: *Ctx, cur: []const u8) bool {
        if (self.last == null) {
            self.last = cur;
            return true;
        }
        const is_ordered = std.mem.order(u8, cur, self.last.?) != .lt;
        if (!is_ordered and !self.has_error) {
            ctx.errPrint("comm: file {c} is not in sorted order\n", .{self.file_num});
            self.has_error = true;
        }
        self.last = cur;
        return is_ordered or !self.explicit_check_order;
    }
};

// ------------------------------------------------------------------ operand setup

const Operand = struct { fd: sys.Fd, is_stdin: bool };

fn openOperand(ctx: *Ctx, name: []const u8) ?Operand {
    if (std.mem.eql(u8, name, "-")) return .{ .fd = ctx.stdin, .is_stdin = true };
    const st = sys.stat(name) catch |e| {
        ctx.errPrint("comm: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
        return null;
    };
    if (st.is_dir) {
        ctx.errPrint("comm: {s}: Is a directory\n", .{name});
        return null;
    }
    const fd = sys.open(name, .{ .read = true }) catch |e| {
        ctx.errPrint("comm: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
        return null;
    };
    return .{ .fd = fd, .is_stdin = false };
}

/// Byte-for-byte comparison of two already-open regular-file fds, rewinding both back
/// to offset 0 afterward (best-effort -- a failed rewind just means the subsequent
/// merge pass would see them positioned wherever the compare left them, which cannot
/// happen for real files).
fn filesByteIdentical(fd1: sys.Fd, fd2: sys.Fd) bool {
    const equal = blk: {
        var b1: [8192]u8 = undefined;
        var b2: [8192]u8 = undefined;
        while (true) {
            const n1 = sys.read(fd1, &b1) catch break :blk false;
            const n2 = sys.read(fd2, &b2) catch break :blk false;
            if (n1 != n2) break :blk false;
            if (n1 == 0) break :blk true;
            if (!std.mem.eql(u8, b1[0..n1], b2[0..n2])) break :blk false;
        }
    };
    _ = sys.lseek(fd1, 0, .set) catch {};
    _ = sys.lseek(fd2, 0, .set) catch {};
    return equal;
}

fn filesLookIdentical(name1: []const u8, name2: []const u8, fd1: sys.Fd, fd2: sys.Fd, stdin1: bool, stdin2: bool) bool {
    if (stdin1 or stdin2) return false;
    if (std.mem.eql(u8, name1, name2)) return true;
    const st1 = sys.stat(name1) catch return false;
    const st2 = sys.stat(name2) catch return false;
    if (st1.is_dir or st2.is_dir) return false;
    if (st1.size != st2.size) return false;
    return filesByteIdentical(fd1, fd2);
}

// ------------------------------------------------------------------ output helpers

fn writeRepeated(out: *textio.BufOut, delim: []const u8, times: usize) sys.Error!void {
    var i: usize = 0;
    while (i < times) : (i += 1) try out.extend(delim);
}

fn emitLine(out: *textio.BufOut, delim: []const u8, prefix_times: usize, line: []const u8, term: u8) sys.Error!void {
    try writeRepeated(out, delim, prefix_times);
    try out.extend(line);
    try out.push(term);
}

// ------------------------------------------------------------------ run

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    // --check-order/--nocheck-order together: a clap-conflict parse error. Reproduce
    // the observed message, ordering the two flag names by first occurrence in argv.
    if (m.has("check-order") and m.has("nocheck-order")) {
        var first: ?[]const u8 = null;
        var second: ?[]const u8 = null;
        for (ctx.args[1..]) |a| {
            if (std.mem.eql(u8, a, "--check-order") or std.mem.eql(u8, a, "--nocheck-order")) {
                if (first == null) {
                    first = a;
                } else if (second == null) {
                    second = a;
                }
            }
        }
        ctx.errPrint(
            "error: the argument '{s}' cannot be used with '{s}'\n\nFor more information, try '--help'.\n",
            .{ first orelse "--check-order", second orelse "--nocheck-order" },
        );
        return 1;
    }

    const suppress1 = m.has("1");
    const suppress2 = m.has("2");
    const suppress3 = m.has("3");
    const width1: usize = if (suppress1) 0 else 1;
    const width2: usize = if (suppress2) 0 else 1;

    const term: u8 = if (m.has("zero-terminated")) 0 else '\n';
    const want_total = m.has("total");
    const explicit_check = m.has("check-order");
    const explicit_nocheck = m.has("nocheck-order");

    // Operands are opened FIRST, matching the Rust source's uumain (open_file for both
    // FILE1/FILE2 runs before the --output-delimiter conflict check) -- a directory or
    // missing-file error on either operand wins over a delimiter conflict.
    const pos = m.positionalSlice();
    const file1 = pos[0];
    const file2 = pos[1];

    const op1 = openOperand(ctx, file1) orelse return 1;
    const op2 = openOperand(ctx, file2) orelse return 1;
    defer if (!op1.is_stdin) sys.close(op1.fd);
    defer if (!op2.is_stdin) sys.close(op2.fd);

    var delim: []const u8 = "\t";
    const delim_vals = m.values("output-delimiter");
    if (delim_vals.len > 0) {
        for (delim_vals[1..]) |v| {
            if (!std.mem.eql(u8, v, delim_vals[0])) {
                ctx.errPrint("comm: multiple conflicting output delimiters specified\n", .{});
                return 1;
            }
        }
        delim = delim_vals[0];
        if (delim.len == 0) delim = &NUL_DELIM;
    }

    const identical = filesLookIdentical(file1, file2, op1.fd, op2.fd, op1.is_stdin, op2.is_stdin);
    const should_check_order = !explicit_nocheck and (explicit_check or !identical);

    var reader1 = CommReader.init(op1.fd, term);
    var reader2 = CommReader.init(op2.fd, term);

    var out = textio.BufOut.init(ctx.stdout);

    var checker1 = OrderChecker{ .explicit_check_order = explicit_check, .file_num = '1' };
    var checker2 = OrderChecker{ .explicit_check_order = explicit_check, .file_num = '2' };
    var input_error = false;

    var total1: usize = 0;
    var total2: usize = 0;
    var total3: usize = 0;

    var ra: ?[]const u8 = reader1.next(ctx.gpa) catch |e| return readErr(ctx, &out, file1, e);
    var rb: ?[]const u8 = reader2.next(ctx.gpa) catch |e| return readErr(ctx, &out, file2, e);

    while (ra != null or rb != null) {
        const ord: std.math.Order = blk: {
            if (ra == null) break :blk .gt;
            if (rb == null) break :blk .lt;
            break :blk std.mem.order(u8, ra.?, rb.?);
        };

        switch (ord) {
            .lt => {
                if (should_check_order and !checker1.verify(ctx, ra.?)) break;
                if (!suppress1) emitLine(&out, delim, 0, ra.?, term) catch return writeErr();
                total1 += 1;
                ra = reader1.next(ctx.gpa) catch |e| return readErr(ctx, &out, file1, e);
            },
            .gt => {
                if (should_check_order and !checker2.verify(ctx, rb.?)) break;
                if (!suppress2) emitLine(&out, delim, width1, rb.?, term) catch return writeErr();
                total2 += 1;
                rb = reader2.next(ctx.gpa) catch |e| return readErr(ctx, &out, file2, e);
            },
            .eq => {
                if (should_check_order and (!checker1.verify(ctx, ra.?) or !checker2.verify(ctx, rb.?))) break;
                if (!suppress3) emitLine(&out, delim, width1 + width2, ra.?, term) catch return writeErr();
                total3 += 1;
                ra = reader1.next(ctx.gpa) catch |e| return readErr(ctx, &out, file1, e);
                rb = reader2.next(ctx.gpa) catch |e| return readErr(ctx, &out, file2, e);
            },
        }

        if ((checker1.has_error or checker2.has_error) and !input_error and !explicit_check) {
            input_error = true;
        }
    }

    if (want_total) writeTotal(&out, delim, total1, total2, total3, term) catch return writeErr();

    out.finish() catch {};

    if (should_check_order and (checker1.has_error or checker2.has_error)) {
        if (input_error) ctx.errPrint("comm: input is not in sorted order\n", .{});
        return 1;
    }
    return 0;
}

fn writeTotal(out: *textio.BufOut, delim: []const u8, n1: usize, n2: usize, n3: usize, term: u8) sys.Error!void {
    var buf: [32]u8 = undefined;
    try out.extend(std.fmt.bufPrint(&buf, "{d}", .{n1}) catch unreachable);
    try out.extend(delim);
    try out.extend(std.fmt.bufPrint(&buf, "{d}", .{n2}) catch unreachable);
    try out.extend(delim);
    try out.extend(std.fmt.bufPrint(&buf, "{d}", .{n3}) catch unreachable);
    try out.extend(delim);
    try out.extend("total");
    try out.push(term);
}

fn readErr(ctx: *Ctx, out: *textio.BufOut, name: []const u8, e: sys.Error) u8 {
    out.finish() catch {};
    ctx.errPrint("comm: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
    return 1;
}

fn writeErr() u8 {
    // A write failure means the downstream reader closed the pipe; stop quietly
    // (same convention as cat.zig/yes.zig: `catch return 0`).
    return 0;
}
