//! `seq` -- DESIGN.md §1: dual-path number sequencer, all arithmetic
//! and formatting hand-rolled over core/fmtnum.
//!
//! Flags: `-w/--equal-width` (zero-pad to the widest rendered value; the pad goes
//! after a leading `-`, i.e. C `%0Nd`/`%0N.Pf` semantics), `-s/--separator STRING`
//! (default `\n`), `-f/--format FORMAT` (single `%f`/`%e`/`%g` conversion with
//! optional flags/width/precision, plus literal prefix/suffix and `%%`). `-f`+`-w`
//! is an error. Operands `[FIRST [INCREMENT]] LAST`, 1..=3, defaults 1. Negative
//! operands parse via cli.zig's allow_hyphen_values.
//!
//! PATH SELECTION on the raw tokens: float path iff `-f` is given or any operand
//! token contains one of `. e E n N` (matrix `is_floaty`); zero operands is
//! vacuously the integer path. INTEGER PATH: exact i64 operands (parse failure,
//! incl. overflowing all-digit tokens -> `seq: <tok>: invalid argument`), i128
//! internally so `last-first` can never overflow. FLOAT PATH: parse failure ->
//! `seq: <tok>: invalid floating point argument`; `value_i = first + i*incr`
//! computed per iteration (not accumulated); count `n = floor((last-first)/incr +
//! 1e-9) + 1` clamped at >= 0. Derived precision = max fractional-digit count
//! among ALL supplied operands (FIRST, INCREMENT, and LAST -- confirmed against
//! the Rust oracle, see ledger), counted literally between `.` and any exponent.
//! Default rendering = `%f` at that precision.
//!
//! `-w` width derivation: render every value (two passes; the first uses a counting
//! sink, so no buffering) and take the max -- simple and correct for both paths.
//! Trailing newline whenever at least one value was emitted.
//!
//! ERROR SURFACE (source: rust-oracle-excerpt, see parity ledger) -- all exit 1:
//! wrong operand count (0 or >3) -> `seq: usage: seq [-w] [-s sep] [first [incr]]
//! last` (float path inserts `[-f fmt]` after `[-s sep]`); `increment must not be
//! zero`; `<tok>: invalid argument` / `<tok>: invalid floating point argument`;
//! `format string may not be specified when printing equal-width strings`;
//! `invalid format string` (no/multiple directives); `format conversion must be
//! f, e, or g`. Flag-level parse errors (unknown option, missing value) remain
//! cli.zig usage errors at exit 2.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const fmtnum = @import("../core/fmtnum.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "seq",
    .flags = &.{
        cli.flagOpt('w', "equal-width", "equalize width by padding with leading zeroes"),
        cli.valueOpt('s', "separator", "use STRING to separate numbers"),
        cli.valueOpt('f', "format", "use printf style floating-point FORMAT"),
    },
    .positionals = .{ .name = "[FIRST [INCREMENT]] LAST", .min = 0, .max = null },
    .allow_hyphen_values = true,
    .help = .{
        .summary = "print a sequence of numbers",
        .synopsis = &.{"seq [-w] [-s STRING] [-f FORMAT] [FIRST [INCREMENT]] LAST"},
        .description =
        \\Prints the numbers from FIRST to LAST in steps of INCREMENT (each defaulting
        \\to 1), one per line unless -s changes the separator. Which of two arithmetic
        \\paths is used is decided up front from the raw operand text, not from -f: if
        \\-f is given or any operand contains one of the characters `. e E n N`, all
        \\arithmetic is done in floating point (value_i = FIRST + i*INCREMENT,
        \\computed fresh each step, with the iteration count derived from
        \\(LAST-FIRST)/INCREMENT); otherwise every operand must be a plain integer and
        \\arithmetic is exact 64-bit (widened internally so LAST-FIRST cannot
        \\overflow).
        \\
        \\On the float path, the default rendering precision is the largest number of
        \\fractional digits written in ANY of the supplied operands (FIRST, INCREMENT,
        \\and LAST together); -f overrides this with an explicit printf-style
        \\`%[flags][width][.precision](f|e|g)` conversion (plus optional literal
        \\prefix/suffix text). -w instead renders every value once to measure the
        \\widest result and zero-pads all of them (after any leading sign) to that
        \\width; -w and -f are mutually exclusive.
        ,
        .operands = "[FIRST [INCREMENT]] LAST -- one to three numbers: LAST alone, or FIRST and LAST, or FIRST, INCREMENT, and LAST. Negative numbers (e.g. -5) are accepted as operands, not mistaken for flags, because seq parses with allow-hyphen-values. Exactly one to three operands are accepted; zero or more than three is a usage error.",
        .exit = &.{
            .{ .code = 0, .when = "success (including an empty sequence, e.g. FIRST > LAST with a positive INCREMENT, which prints nothing)" },
            .{ .code = 1, .when = "wrong operand count (0 or more than 3), INCREMENT is zero, an operand fails to parse, -f and -w were both given, or -f's FORMAT is malformed" },
            .{ .code = 2, .when = "a flag-level usage error (unknown option, missing option value) from cli.zig's generic parser" },
        },
        .deviations = &.{
            "Derived float precision (used when -f/-w are absent) includes LAST as well as FIRST/INCREMENT: `seq 1 1 2.5` prints \"1.0\" and \"2.0\" at one fractional digit, whereas GNU seq derives precision from FIRST and INCREMENT only and would print \"1\" and \"2\".",
            "Zero operands and more than three operands are usage errors at exit 1 with the message \"seq: usage: seq [-w] [-s sep] [first [incr]] last\" (the float path inserts \"[-f fmt]\" after \"[-s sep]\"); GNU seq exits 1 for the same cases too, but with its own \"missing operand\"/\"extra operand '...'\" wording instead.",
            "Error wording departs from GNU throughout: \"<tok>: invalid argument\" / \"<tok>: invalid floating point argument\" (token before the message, not GNU's quoted-after form), \"increment must not be zero\", \"format string may not be specified when printing equal-width strings\", \"invalid format string\", and \"format conversion must be f, e, or g\" are this port's own oracle-derived strings, not GNU's.",
        },
        .examples = &.{
            .{ .cmd = "seq 3", .note = "1, 2, 3 -- one per line" },
            .{ .cmd = "seq -w 8 10", .note = "08, 09, 10 -- zero-padded to the widest value's width" },
            .{ .cmd = "seq 1 1 2.5", .note = "1.0, 2.0 -- precision 1 because LAST (2.5) contributes a fractional digit, unlike GNU seq which would print 1, 2" },
        },
        .see_also = "printf (custom per-value formatting without a sequence).",
    },
};

const Operand = struct {
    raw: []const u8,
    int: ?i64, // set when the operand is a plain i64 integer literal
    float: f64,
    frac_digits: usize,
};

fn parseI64Strict(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        i = 1;
    }
    if (i >= s.len) return null;
    var v: i128 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > std.math.maxInt(i64) + 1) return null; // room for minInt
    }
    if (neg) v = -v;
    if (v < std.math.minInt(i64) or v > std.math.maxInt(i64)) return null;
    return @intCast(v);
}

/// Fractional digits = literal digit count between '.' and any exponent marker.
fn fracDigitsOf(s: []const u8) usize {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return 0;
    var n: usize = 0;
    for (s[dot + 1 ..]) |c| {
        if (c == 'e' or c == 'E') break;
        if (c < '0' or c > '9') break;
        n += 1;
    }
    return n;
}

fn asciiEqlNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != y) return false;
    }
    return true;
}

fn pow10f128(e: i32) f128 {
    var result: f128 = 1;
    var base: f128 = 10;
    var n: u32 = @abs(e);
    while (n != 0) : (n >>= 1) {
        if (n & 1 == 1) result *= base;
        base *= base;
    }
    return if (e < 0) 1 / result else result;
}

/// Hand-rolled decimal f64 parse matching Rust `str::parse::<f64>` (the reference's
/// operand parser): optional sign, decimal digits with optional point and e/E
/// exponent, case-insensitive `inf`/`infinity`/`nan`; NO hex floats, NO whitespace.
/// std.fmt.parseFloat is deliberately avoided: it costs ~26 KiB of eisel-lemire
/// tables in the isolated box AND accepts hex floats the reference rejects. The
/// value is assembled as u128-mantissa x 10^exp in f128 (mantissa exact to 34
/// digits, pow10 by squaring), then rounded once to f64 -- relative error < 2^-108
/// before the final rounding, i.e. correctly rounded except for adversarial 30+
/// digit inputs sitting within 2^-108 of an f64 midpoint (same bounds philosophy as
/// fmtnum's digit extraction; documented, unreachable by realistic operands).
fn parseF64(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        i = 1;
    }
    const rest = s[i..];
    if (asciiEqlNoCase(rest, "inf") or asciiEqlNoCase(rest, "infinity")) {
        return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    }
    if (asciiEqlNoCase(rest, "nan")) return std.math.nan(f64);

    const MANT_CAP: u128 = (std.math.maxInt(u128) - 9) / 10;
    var mant: u128 = 0;
    var exp10: i32 = 0;
    var any_digits = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        any_digits = true;
        if (mant <= MANT_CAP) {
            mant = mant * 10 + (s[i] - '0');
        } else {
            exp10 += 1; // dropped low-order integer digit
        }
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            any_digits = true;
            if (mant <= MANT_CAP) {
                mant = mant * 10 + (s[i] - '0');
                exp10 -= 1;
            }
        }
    }
    if (!any_digits) return null;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        var eneg = false;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            eneg = s[i] == '-';
            i += 1;
        }
        if (i >= s.len) return null;
        var ev: i32 = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            ev = @min(ev * 10 + @as(i32, s[i] - '0'), 100_000);
        }
        exp10 += if (eneg) -ev else ev;
    }
    if (i != s.len) return null;

    if (mant == 0) return if (neg) -0.0 else 0.0;
    // clamp far outside f64's decimal range (f64 max ~1.8e308, min subnormal ~5e-324)
    const wide: f128 = if (exp10 > 400)
        std.math.inf(f128)
    else if (exp10 < -420)
        0
    else
        @as(f128, @floatFromInt(mant)) * pow10f128(exp10);
    const v: f64 = @floatCast(wide);
    return if (neg) -v else v;
}

/// Parses one operand for the already-selected path; on failure prints the
/// oracle's path-specific diagnostic and returns null (caller exits 1).
fn parseOperandOrDie(ctx: *Ctx, raw: []const u8, floaty: bool) ?Operand {
    if (!floaty) {
        // integer path: strict i64 (an overflowing all-digit token dies here too)
        const v = parseI64Strict(raw) orelse {
            ctx.errPrint("seq: {s}: invalid argument\n", .{raw});
            return null;
        };
        return .{ .raw = raw, .int = v, .float = @floatFromInt(v), .frac_digits = 0 };
    }
    const f = parseF64(raw) orelse {
        ctx.errPrint("seq: {s}: invalid floating point argument\n", .{raw});
        return null;
    };
    return .{ .raw = raw, .int = null, .float = f, .frac_digits = fracDigitsOf(raw) };
}

const Format = struct {
    prefix: []const u8,
    suffix: []const u8,
    fspec: fmtnum.Spec,
};

const FormatError = enum {
    invalid, // no directive, or more than one -> "seq: invalid format string"
    bad_conversion, // -> "seq: format conversion must be f, e, or g"
};

/// Parses a `-f` FORMAT: literal text (with `%%`) around exactly one
/// `%[flags][width][.prec](f|e|g)` conversion.
fn parseFormat(gpa: std.mem.Allocator, s: []const u8) union(enum) { ok: Format, err: FormatError } {
    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    var suffix: std.ArrayListUnmanaged(u8) = .empty;
    var fspec: ?fmtnum.Spec = null;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            const lit = if (fspec == null) &prefix else &suffix;
            lit.append(gpa, s[i]) catch @panic("OOM");
            i += 1;
            continue;
        }
        if (i + 1 < s.len and s[i + 1] == '%') {
            const lit = if (fspec == null) &prefix else &suffix;
            lit.append(gpa, '%') catch @panic("OOM");
            i += 2;
            continue;
        }
        if (fspec != null) return .{ .err = .invalid };
        var j = i + 1;
        var fs = fmtnum.Spec{ .conv = 0 };
        while (j < s.len) : (j += 1) {
            switch (s[j]) {
                '-' => fs.flags.minus = true,
                '+' => fs.flags.plus = true,
                ' ' => fs.flags.space = true,
                '0' => fs.flags.zero = true,
                '#' => fs.flags.hash = true,
                '\'' => {},
                else => break,
            }
        }
        while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
            fs.width = fs.width * 10 + (s[j] - '0');
        }
        if (j < s.len and s[j] == '.') {
            j += 1;
            var p: usize = 0;
            while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {
                p = p * 10 + (s[j] - '0');
            }
            fs.precision = p;
        }
        if (j >= s.len) return .{ .err = .invalid };
        const conv = s[j];
        switch (conv) {
            'f', 'e', 'g' => {},
            else => return .{ .err = .bad_conversion },
        }
        fs.conv = conv;
        fspec = fs;
        i = j + 1;
    }
    if (fspec == null) return .{ .err = .invalid };
    return .{ .ok = .{ .prefix = prefix.items, .suffix = suffix.items, .fspec = fspec.? } };
}

fn emitSep(out: anytype, sep: []const u8, first: bool) !void {
    if (!first) try out.extend(sep);
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const equal_width = m.has("equal-width");
    const sep: []const u8 = m.value("separator") orelse "\n";

    if (equal_width and m.has("format")) {
        ctx.errPrint("seq: format string may not be specified when printing equal-width strings\n", .{});
        return 1;
    }

    var format: ?Format = null;
    if (m.value("format")) |fs| {
        switch (parseFormat(ctx.gpa, fs)) {
            .ok => |fmt| format = fmt,
            .err => |e| {
                switch (e) {
                    .invalid => ctx.errPrint("seq: invalid format string\n", .{}),
                    .bad_conversion => ctx.errPrint("seq: format conversion must be f, e, or g\n", .{}),
                }
                return 1;
            },
        }
    }

    // Path selection on the RAW tokens (matrix is_floaty): float iff -f given or
    // any operand contains one of `. e E n N`. Zero operands is vacuously integer.
    const pos = m.positionalSlice();
    var floaty = format != null;
    for (pos) |p| {
        if (std.mem.indexOfAny(u8, p, ".eEnN") != null) floaty = true;
    }

    if (pos.len == 0 or pos.len > 3) {
        // oracle usage error: exit 1, path-flavored usage line
        if (floaty) {
            ctx.errPrint("seq: usage: seq [-w] [-s sep] [-f fmt] [first [incr]] last\n", .{});
        } else {
            ctx.errPrint("seq: usage: seq [-w] [-s sep] [first [incr]] last\n", .{});
        }
        return 1;
    }

    // Operand assignment: 1 -> LAST; 2 -> FIRST LAST; 3 -> FIRST INCREMENT LAST.
    const default_op = Operand{ .raw = "1", .int = 1, .float = 1.0, .frac_digits = 0 };
    var first_op = default_op;
    var incr_op = default_op;
    var last_op = default_op;
    switch (pos.len) {
        1 => last_op = parseOperandOrDie(ctx, pos[0], floaty) orelse return 1,
        2 => {
            first_op = parseOperandOrDie(ctx, pos[0], floaty) orelse return 1;
            last_op = parseOperandOrDie(ctx, pos[1], floaty) orelse return 1;
        },
        else => {
            first_op = parseOperandOrDie(ctx, pos[0], floaty) orelse return 1;
            incr_op = parseOperandOrDie(ctx, pos[1], floaty) orelse return 1;
            last_op = parseOperandOrDie(ctx, pos[2], floaty) orelse return 1;
        },
    }

    if (incr_op.float == 0) {
        ctx.errPrint("seq: increment must not be zero\n", .{});
        return 1;
    }

    var out = textio.BufOut.init(ctx.stdout);

    const integer_path = !floaty;

    if (integer_path) {
        const first: i128 = first_op.int.?;
        const incr: i128 = incr_op.int.?;
        const last: i128 = last_op.int.?;
        const n: i128 = if ((incr > 0 and first > last) or (incr < 0 and first < last))
            0
        else
            @divTrunc(last - first, incr) + 1;

        var ispec = fmtnum.Spec{ .conv = 'd' };
        if (equal_width) {
            var maxw: usize = 0;
            var i: i128 = 0;
            while (i < n) : (i += 1) {
                var cnt = fmtnum.CountingSink{};
                fmtnum.emitInt(&cnt, ispec, @intCast(first + i * incr)) catch unreachable;
                maxw = @max(maxw, cnt.len);
            }
            ispec.width = maxw;
            ispec.flags.zero = true;
        }
        var i: i128 = 0;
        while (i < n) : (i += 1) {
            emitSep(&out, sep, i == 0) catch return 0;
            fmtnum.emitInt(&out, ispec, @intCast(first + i * incr)) catch return 0;
        }
        if (n > 0) out.push('\n') catch return 0;
        out.finish() catch {};
        return 0;
    }

    // FLOAT PATH: value_i = first + i*incr per iteration; count from the drift-
    // guarded step formula.
    const first = first_op.float;
    const incr = incr_op.float;
    const last = last_op.float;
    const steps = (last - first) / incr;
    var n: i64 = 0;
    if (!std.math.isNan(steps)) {
        const fcount = @floor(steps + 1e-9) + 1;
        if (fcount >= 1) {
            n = if (fcount >= 9.2e18) std.math.maxInt(i64) else @intFromFloat(fcount);
        }
    }

    const prec = @max(first_op.frac_digits, @max(incr_op.frac_digits, last_op.frac_digits));
    var fspec = if (format) |fmt| fmt.fspec else fmtnum.Spec{ .conv = 'f', .precision = prec };
    const prefix: []const u8 = if (format) |fmt| fmt.prefix else "";
    const suffix: []const u8 = if (format) |fmt| fmt.suffix else "";

    if (equal_width) {
        var maxw: usize = 0;
        var i: i64 = 0;
        while (i < n) : (i += 1) {
            const v = first + @as(f64, @floatFromInt(i)) * incr;
            var cnt = fmtnum.CountingSink{};
            fmtnum.emitFloat(&cnt, fspec, v) catch unreachable;
            maxw = @max(maxw, cnt.len);
        }
        fspec.width = maxw;
        fspec.flags.zero = true;
    }

    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const v = first + @as(f64, @floatFromInt(i)) * incr;
        emitSep(&out, sep, i == 0) catch return 0;
        out.extend(prefix) catch return 0;
        fmtnum.emitFloat(&out, fspec, v) catch return 0;
        out.extend(suffix) catch return 0;
    }
    if (n > 0) out.push('\n') catch return 0;
    out.finish() catch {};
    return 0;
}
