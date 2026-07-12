//! `numfmt` -- DESIGN.md §1: converts numbers to/from human-readable
//! scaled forms. Ports `uu_numfmt`'s `format.rs`/`options.rs`/`units.rs`/`numeric.rs`
//! (0.9.0). All locale-dependent behavior (`--grouping`'s separator, the decimal
//! point) is hard-coded to the C/POSIX locale (decimal sep `.`, grouping sep EMPTY --
//! confirmed against the oracle under `LC_ALL=C`: `--grouping` is a byte-for-byte
//! no-op there), matching the environment this port always runs under.
//!
//! SCALING: SI = 1000^n, IEC = 1024^n, IEC-with-`i` accepts/emits two-char `Ki/Mi/...`
//! suffixes; ladder `K M G T P E Z Y R Q`. `div_round` rounds to 1 decimal place if
//! `|v|<10` else to an integer; IEC output additionally caps the ROUNDING precision at
//! 3 decimals (GNU parity) while the DISPLAYED precision (from `--format`) can still
//! ask for more, padding with zeros past the 3rd decimal -- confirmed against the
//! oracle (`--to=iec --format=%.5f` on 123456789 -> `117.73800M`: rounded to .738,
//! printed to 5). Large exact integers take an i128 fast path (`ParsedNumber`) so
//! huge inputs divisible by `--to-unit` print without float rounding at all.
//!
//! CLI: everything is a declarative `core/cli.zig` `Spec` except `--header`, which
//! (like od's `-w`/`-S`) is a clap "optional value" arg -- an attached value or an
//! unattached FOLLOWING token that doesn't start with `-` is consumed (confirmed:
//! `numfmt --header 2` DOES eat the `2`); a small argv pre-pass normalizes a bare
//! `--header`/`--header N` into `--header=N` (default missing value `1`) before
//! `cli.zig` ever sees it.
//!
//! ERROR TAXONOMY: `IllegalArgument` (bad CLI/unit/format-string values) -> exit 1;
//! `FormattingError` (a bad NUMBER, reachable only per-line/per-arg once `--invalid`
//! gates whether it's fatal) -> exit 2; a bare I/O error -> exit 1.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const fmtnum = @import("../core/fmtnum.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const PROG = "numfmt";

// ============================================================================ units/suffixes

const Unit = enum { auto, si, iec, iec_i, none };

const RawSuffix = enum {
    k,
    m,
    g,
    t,
    p,
    e,
    z,
    y,
    r,
    q,

    fn fromChar(c: u8) ?RawSuffix {
        return switch (c) {
            'K', 'k' => .k,
            'M' => .m,
            'G' => .g,
            'T' => .t,
            'P' => .p,
            'E' => .e,
            'Z' => .z,
            'Y' => .y,
            'R' => .r,
            'Q' => .q,
            else => null,
        };
    }

    /// Index into the base tables (`K` at 1, ..., `Q` at 10).
    fn baseIndex(self: RawSuffix) usize {
        return @as(usize, @intFromEnum(self)) + 1;
    }

    fn upperChar(self: RawSuffix) u8 {
        return "KMGTPEZYRQ"[@intFromEnum(self)];
    }
};

const Suffix = struct { raw: RawSuffix, with_i: bool };

fn siBaseF64(idx: usize) f64 {
    var v: f64 = 1.0;
    var k: usize = 0;
    while (k < idx) : (k += 1) v *= 1000.0;
    return v;
}

fn iecBaseF64(idx: usize) f64 {
    var v: f64 = 1.0;
    var k: usize = 0;
    while (k < idx) : (k += 1) v *= 1024.0;
    return v;
}

fn displaySuffixChar(s: Suffix, unit: Unit) u8 {
    if (s.raw == .k and unit == .si) return 'k';
    return s.raw.upperChar();
}

// ============================================================================ numeric

const ParsedNumber = union(enum) {
    exact_int: i128,
    float: f64,

    fn toF64(self: ParsedNumber) f64 {
        return switch (self) {
            .exact_int => |n| @floatFromInt(n),
            .float => |f| f,
        };
    }
    fn exactInt(self: ParsedNumber) ?i128 {
        return switch (self) {
            .exact_int => |n| n,
            .float => null,
        };
    }
};

const RoundMethod = enum {
    up,
    down,
    from_zero,
    towards_zero,
    nearest,

    fn round(self: RoundMethod, f: f64) f64 {
        return switch (self) {
            .up => @ceil(f),
            .down => @floor(f),
            .from_zero => if (f < 0.0) @floor(f) else @ceil(f),
            .towards_zero => if (f < 0.0) @ceil(f) else @floor(f),
            .nearest => @round(f),
        };
    }
};

const InvalidMode = enum { abort, fail, warn, ignore };

// ============================================================================ field ranges

const Range = struct { low: usize, high: usize };

const RangeErr = error{ Zero, TooLarge, ParseFail, NoEndpoint, Decreasing };

fn rangeErrText(e: RangeErr) []const u8 {
    return switch (e) {
        error.Zero => "fields and positions are numbered from 1",
        error.TooLarge => "byte/character offset is too large",
        error.ParseFail => "failed to parse range",
        error.NoEndpoint => "invalid range with no endpoint",
        error.Decreasing => "high end of range less than low end",
    };
}

fn parseRangeEndpoint(s: []const u8) RangeErr!usize {
    const n = std.fmt.parseUnsigned(usize, s, 10) catch return error.ParseFail;
    if (n == 0) return error.Zero;
    if (n == std.math.maxInt(usize)) return error.TooLarge;
    return n;
}

fn parseRange(s: []const u8) RangeErr!Range {
    if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
        const lo_s = s[0..dash];
        const hi_s = s[dash + 1 ..];
        if (lo_s.len == 0 and hi_s.len == 0) return error.NoEndpoint;
        if (hi_s.len == 0) return .{ .low = try parseRangeEndpoint(lo_s), .high = std.math.maxInt(usize) - 1 };
        if (lo_s.len == 0) return .{ .low = 1, .high = try parseRangeEndpoint(hi_s) };
        const lo = try parseRangeEndpoint(lo_s);
        const hi = try parseRangeEndpoint(hi_s);
        if (lo > hi) return error.Decreasing;
        return .{ .low = lo, .high = hi };
    }
    const n = try parseRangeEndpoint(s);
    return .{ .low = n, .high = n };
}

/// `Range::from_list`: split on `,`/` `, parse each independently (no merge step --
/// unobservable here, since we only ever ask "is N in ANY of these ranges"). On
/// `error.Invalid`, `err_msg.*` carries the fully-rendered `range '<item>' was
/// invalid: <reason>` text (gpa-owned).
fn parseRangeList(gpa: std.mem.Allocator, list: []const u8, err_msg: *[]const u8) error{ Invalid, ENOMEM }![]Range {
    var out: std.ArrayListUnmanaged(Range) = .empty;
    var it = std.mem.splitAny(u8, list, ", ");
    while (it.next()) |item| {
        const r = parseRange(item) catch |e| {
            err_msg.* = std.fmt.allocPrint(gpa, "range '{s}' was invalid: {s}", .{ item, rangeErrText(e) }) catch return error.ENOMEM;
            return error.Invalid;
        };
        out.append(gpa, r) catch return error.ENOMEM;
    }
    return out.toOwnedSlice(gpa) catch error.ENOMEM;
}

fn rangesContain(ranges: []const Range, n: usize) bool {
    for (ranges) |r| {
        if (n >= r.low and n <= r.high) return true;
    }
    return false;
}

// ============================================================================ numeric-string parsing
//
// Ports `format.rs`'s `find_numeric_beginning`/`find_valid_number_with_suffix`/
// `detailed_error_message`/`parse_number_part`/`parse_suffix`. All byte-oriented
// (every character these functions actually distinguish -- digits, `-`, `.`, suffix
// letters, `i` -- is ASCII, so a byte scan is equivalent to Rust's char scan here).
// The DEFAULT `--from=none` makes `accepts_suffix` false, so in practice
// `find_valid_number_with_suffix` almost always yields just the bare numeric prefix,
// which is why plain `numfmt 5Kx` reports "rejecting suffix ... (consider using
// --from)" rather than "invalid suffix in input '5Kx': 'x'" (confirmed against the
// oracle; the latter shape is only reachable with an explicit `--from=auto|si|iec`
// AND a garbage string whose valid prefix already includes one suffix letter, e.g.
// `--from=auto numfmt 5KM`).

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
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

fn asciiEqlNoCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Hand-rolled decimal f64 parse matching Rust `str::parse::<f64>` -- the SAME
/// grammar `format.rs`'s `parse_number_part`/`find_numeric_beginning` rely on
/// (optional sign, digits, optional point+digits, optional `[eE][sign]digits`,
/// case-insensitive `inf`/`infinity`/`nan`). `std.fmt.parseFloat` is deliberately
/// avoided here too (see `seq.zig`'s identical note: ~26 KiB of eisel-lemire tables
/// in the isolated/readonly boxes); this is the same construction (u128 mantissa x
/// 10^exp in f128, rounded once to f64).
fn parseF64Loose(s: []const u8) ?f64 {
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
    while (i < s.len and isDigit(s[i])) : (i += 1) {
        any_digits = true;
        if (mant <= MANT_CAP) {
            mant = mant * 10 + (s[i] - '0');
        } else {
            exp10 += 1;
        }
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
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
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            ev = @min(ev * 10 + @as(i32, s[i] - '0'), 100_000);
        }
        exp10 += if (eneg) -ev else ev;
    }
    if (i != s.len) return null;

    if (mant == 0) return if (neg) -0.0 else 0.0;
    const wide: f128 = if (exp10 > 400)
        std.math.inf(f128)
    else if (exp10 < -420)
        0
    else
        @as(f128, @floatFromInt(mant)) * pow10f128(exp10);
    const v: f64 = @floatCast(wide);
    return if (neg) -v else v;
}

fn findNumericBeginning(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (s[0] == '.') return s[0..1];
    var seen_dec = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '-' and i == 0) continue;
        if (isDigit(c)) continue;
        if (!seen_dec and c == '.') {
            seen_dec = true;
            continue;
        }
        if (parseF64Loose(s[0..i]) == null) return null;
        return s[0..i];
    }
    return s;
}

fn findValidNumberWithSuffix(s: []const u8, unit: Unit) ?[]const u8 {
    const numeric_part = findNumericBeginning(s) orelse return null;
    const accepts_suffix = unit != .none;
    const accepts_i = unit == .auto or unit == .iec_i;
    if (!accepts_suffix) return numeric_part;
    const rest = s[numeric_part.len..];
    if (rest.len == 0) return numeric_part;
    const suf = rest[0];
    if (RawSuffix.fromChar(suf) == null) return numeric_part;
    if (rest.len == 1) return s[0 .. numeric_part.len + 1];
    if (rest[1] == 'i' and accepts_i) return s[0 .. numeric_part.len + 2];
    return s[0 .. numeric_part.len + 1];
}

fn allocErr(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(gpa, fmt, args) catch "invalid number";
}

/// `None` = "no enrichment, use whatever `parse_suffix` already produced".
fn detailedErrorMessage(gpa: std.mem.Allocator, s: []const u8, unit: Unit, unit_separator: []const u8) ?[]const u8 {
    if (s.len == 0) return allocErr(gpa, "invalid number: ''", .{});
    const number_prefix = findValidNumberWithSuffix(s, unit) orelse return null;
    if (std.mem.eql(u8, number_prefix, ".")) return allocErr(gpa, "invalid suffix in input: '{s}'", .{s});
    if (std.mem.endsWith(u8, number_prefix, ".")) return allocErr(gpa, "invalid number: '{s}'", .{s});

    var valid_end = number_prefix.len;
    if (unit_separator.len != 0) {
        const numeric_only = findNumericBeginning(s) orelse "";
        if (std.mem.eql(u8, number_prefix, numeric_only)) {
            valid_end = validEndWithUnitSeparator(s, number_prefix, unit, unit_separator) orelse number_prefix.len;
        }
    }
    const valid_part = s[0..valid_end];
    if (std.mem.eql(u8, valid_part, s)) return null;

    if (parseF64Loose(valid_part)) |_| {
        const next: ?u8 = if (valid_part.len < s.len) s[valid_part.len] else null;
        if (next == @as(u8, '+') or next == @as(u8, '-')) return allocErr(gpa, "invalid suffix in input: '{s}'", .{s});
        if (next) |v| {
            if (RawSuffix.fromChar(v) != null) {
                return allocErr(gpa, "rejecting suffix in input: '{s}' (consider using --from)", .{s});
            }
        }
        return allocErr(gpa, "invalid suffix in input: '{s}'", .{s});
    }

    const trailing = std.mem.trimStart(u8, s[valid_part.len..], " \t\n\r\x0b\x0c");
    return allocErr(gpa, "invalid suffix in input '{s}': '{s}'", .{ s, trailing });
}

fn validEndWithUnitSeparator(s: []const u8, valid_part: []const u8, unit: Unit, unit_separator: []const u8) ?usize {
    if (valid_part.len > s.len) return null;
    const after = s[valid_part.len..];
    if (!std.mem.startsWith(u8, after, unit_separator)) return null;
    const rest = after[unit_separator.len..];
    if (rest.len == 0) return null;
    if (RawSuffix.fromChar(rest[0]) == null) return null;
    const is_iec = rest.len > 1 and rest[1] == 'i' and (unit == .auto or unit == .iec_i);
    const suffix_len: usize = 1 + @as(usize, @intFromBool(is_iec));
    return valid_part.len + unit_separator.len + suffix_len;
}

const NumErr = error{Invalid};

fn parseNumberPart(gpa: std.mem.Allocator, s: []const u8, input: []const u8, err_msg: *[]const u8) NumErr!ParsedNumber {
    if (s.len > 0 and s[s.len - 1] == '.') {
        err_msg.* = allocErr(gpa, "invalid number: '{s}'", .{input});
        return error.Invalid;
    }
    if (std.fmt.parseInt(i128, s, 10)) |n| {
        return .{ .exact_int = n };
    } else |_| {}
    const f = parseF64Loose(s) orelse {
        err_msg.* = allocErr(gpa, "invalid number: '{s}'", .{input});
        return error.Invalid;
    };
    return .{ .float = f };
}

const ParsedSuffix = struct { num: ParsedNumber, suffix: ?Suffix };

fn parseSuffix(gpa: std.mem.Allocator, s: []const u8, unit: Unit, unit_separator: []const u8, explicit_unit_separator: bool, err_msg: *[]const u8) NumErr!ParsedSuffix {
    const trimmed = std.mem.trimEnd(u8, s, " \t\n\r\x0b\x0c");
    if (trimmed.len == 0) {
        err_msg.* = "invalid number: ''";
        return error.Invalid;
    }

    const with_i = trimmed[trimmed.len - 1] == 'i';
    if (with_i and !(unit == .auto or unit == .iec_i)) {
        err_msg.* = allocErr(gpa, "invalid suffix in input: '{s}'", .{s});
        return error.Invalid;
    }
    const core_len = trimmed.len - @as(usize, @intFromBool(with_i));
    const last: ?u8 = if (core_len > 0) trimmed[core_len - 1] else null;
    var suffix: ?Suffix = null;
    if (last) |c| {
        if (RawSuffix.fromChar(c)) |raw| suffix = .{ .raw = raw, .with_i = with_i };
    }
    if (suffix == null) {
        const ok = last != null and isDigit(last.?) and !with_i;
        if (!ok) {
            err_msg.* = allocErr(gpa, "invalid number: '{s}'", .{s});
            return error.Invalid;
        }
    }

    const suffix_len: usize = if (suffix != null) 1 + @as(usize, @intFromBool(with_i)) else 0;
    const number_part = trimmed[0 .. trimmed.len - suffix_len];

    if (suffix != null) {
        var separator_len: usize = 0;
        if (explicit_unit_separator) {
            if (std.mem.endsWith(u8, number_part, unit_separator)) {
                separator_len = unit_separator.len;
            } else if (unit_separator.len != 0) {
                err_msg.* = allocErr(gpa, "invalid suffix in input: '{s}'", .{s});
                return error.Invalid;
            }
        } else {
            const number_trimmed = std.mem.trimEnd(u8, number_part, " \t\n\r\x0b\x0c");
            const whitespace = number_part.len - number_trimmed.len;
            if (whitespace > 1) {
                err_msg.* = allocErr(gpa, "invalid suffix in input: '{s}'", .{s});
                return error.Invalid;
            }
            separator_len = whitespace;
        }
        const num = try parseNumberPart(gpa, number_part[0 .. number_part.len - separator_len], s, err_msg);
        return .{ .num = num, .suffix = suffix };
    }

    const num = try parseNumberPart(gpa, number_part, s, err_msg);
    return .{ .num = num, .suffix = null };
}

/// numfmt.rs's own pre-check, ahead of any `format.rs` parsing: `E`/`e` immediately
/// followed by an ASCII digit anywhere but the last position.
fn isScientific(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if ((s[i] == 'E' or s[i] == 'e') and i + 1 < s.len and isDigit(s[i + 1])) return true;
    }
    return false;
}

// ============================================================================ scaling (from/to units)

const TransformOptions = struct {
    from: Unit,
    from_unit: usize,
    to: Unit,
    to_unit: usize,
};

fn baseF64(unit_with_i: bool, idx: usize) f64 {
    return if (unit_with_i) iecBaseF64(idx) else siBaseF64(idx);
}

/// `remove_suffix`: applies the suffix's scale factor, or errors per the unit's own
/// suffix-acceptance rules (`Unit::None` rejects ANY suffix; `Iec(true)` demands the
/// literal `i`; a bare-`K`-under-`Iec(false)`/an `i`-suffix-under-Auto/Iec(true) both
/// use IEC bases; everything else SI).
fn removeSuffix(gpa: std.mem.Allocator, i: f64, s: ?Suffix, u: Unit, err_msg: *[]const u8) NumErr!f64 {
    const suf = s orelse return i;
    const idx = suf.raw.baseIndex();
    if (!suf.with_i and (u == .auto or u == .si)) return i * siBaseF64(idx);
    if ((!suf.with_i and u == .iec) or (suf.with_i and (u == .auto or u == .iec_i))) return i * iecBaseF64(idx);
    if (!suf.with_i and u == .iec_i) {
        err_msg.* = allocErr(gpa, "missing 'i' suffix in input: '{d}{c}' (e.g Ki/Mi/Gi)", .{ i, suf.raw.upperChar() });
        return error.Invalid;
    }
    if (u == .none) {
        err_msg.* = allocErr(gpa, "rejecting suffix in input: '{d}{c}{s}' (consider using --from)", .{ i, suf.raw.upperChar(), if (suf.with_i) @as([]const u8, "i") else "" });
        return error.Invalid;
    }
    err_msg.* = "This suffix is unsupported for specified unit";
    return error.Invalid;
}

fn tryScaleExactIntWithFromUnit(value: ParsedNumber, from_unit: usize) ?ParsedNumber {
    const integer = value.exactInt() orelse return null;
    const fu: i128 = @intCast(from_unit);
    const scaled = std.math.mul(i128, integer, fu) catch return null;
    return .{ .exact_int = scaled };
}

fn transformFrom(gpa: std.mem.Allocator, s: []const u8, opts: TransformOptions, unit_separator: []const u8, explicit_unit_separator: bool, err_msg: *[]const u8) NumErr!ParsedNumber {
    var parse_err: []const u8 = "";
    const parsed = parseSuffix(gpa, s, opts.from, unit_separator, explicit_unit_separator, &parse_err) catch {
        err_msg.* = detailedErrorMessage(gpa, s, opts.from, unit_separator) orelse parse_err;
        return error.Invalid;
    };
    const had_no_suffix = parsed.suffix == null;

    if (had_no_suffix) {
        if (tryScaleExactIntWithFromUnit(parsed.num, opts.from_unit)) |scaled| return scaled;
    }

    const i = parsed.num.toF64() * @as(f64, @floatFromInt(opts.from_unit));
    const n = try removeSuffix(gpa, i, parsed.suffix, opts.from, err_msg);
    const adjusted = if (opts.from == .none or had_no_suffix)
        (if (n == -0.0) @as(f64, 0.0) else n)
    else if (n < 0.0)
        -@ceil(@abs(n))
    else
        @ceil(n);
    return .{ .float = adjusted };
}

pub fn divRound(n: f64, d: f64, method: RoundMethod) f64 {
    const v = n / d;
    if (@abs(v) < 10.0) return method.round(10.0 * v) / 10.0;
    return method.round(v);
}

fn roundWithPrecision(n: f64, method: RoundMethod, precision: usize) f64 {
    const p = std.math.pow(f64, 10.0, @floatFromInt(precision));
    return method.round(p * n) / p;
}

const ConsiderResult = struct { value: f64, suffix: ?Suffix };

fn considerSuffix(gpa: std.mem.Allocator, n: f64, u: Unit, round_method: RoundMethod, precision: usize, err_msg: *[]const u8) NumErr!ConsiderResult {
    _ = gpa; // no allocations on this path; kept for call-site symmetry with sibling helpers
    const suffixes = [_]RawSuffix{ .k, .m, .g, .t, .p, .e, .z, .y, .r, .q };
    const abs_n = @abs(n);

    // `with_i` (the DISPLAY flag: does the printed suffix get a trailing `i`?) is a
    // separate concern from which base table is used -- `.iec` (no `i` shown) and
    // `.iec_i` (`Ki`/`Mi`/...) both scale by 1024^n; only `.si` scales by 1000^n.
    const with_i = switch (u) {
        .si => false,
        .iec => false,
        .iec_i => true,
        .auto => {
            err_msg.* = "invalid argument 'auto' for '--to'";
            return error.Invalid;
        },
        .none => return .{ .value = n, .suffix = null },
    };
    const use_iec = u == .iec or u == .iec_i;

    var i: usize = 0;
    if (abs_n <= baseF64(use_iec, 1) - 1.0) {
        return .{ .value = n, .suffix = null };
    } else if (abs_n < baseF64(use_iec, 2)) {
        i = 1;
    } else if (abs_n < baseF64(use_iec, 3)) {
        i = 2;
    } else if (abs_n < baseF64(use_iec, 4)) {
        i = 3;
    } else if (abs_n < baseF64(use_iec, 5)) {
        i = 4;
    } else if (abs_n < baseF64(use_iec, 6)) {
        i = 5;
    } else if (abs_n < baseF64(use_iec, 7)) {
        i = 6;
    } else if (abs_n < baseF64(use_iec, 8)) {
        i = 7;
    } else if (abs_n < baseF64(use_iec, 9)) {
        i = 8;
    } else if (abs_n < baseF64(use_iec, 10)) {
        i = 9;
    } else if (abs_n < baseF64(use_iec, 10) * 1000.0) {
        i = 10;
    } else {
        err_msg.* = "Number is too big and unsupported";
        return error.Invalid;
    }

    const effective_precision = if (use_iec) @min(precision, 3) else precision;
    const base_i = baseF64(use_iec, i);
    const v = if (precision > 0) roundWithPrecision(n / base_i, round_method, effective_precision) else divRound(n, base_i, round_method);

    if (@abs(v) >= baseF64(use_iec, 1)) {
        return .{ .value = v / baseF64(use_iec, 1), .suffix = .{ .raw = suffixes[@min(i, suffixes.len - 1)], .with_i = with_i } };
    }
    return .{ .value = v, .suffix = .{ .raw = suffixes[i - 1], .with_i = with_i } };
}

fn isTooLargeToFormat(scaled: i128, precision: usize) bool {
    const MAX_FORMATTED: u128 = 10_000_000_000_000_000_000;
    var precision_factor: u128 = 1;
    var k: usize = 0;
    while (k < @min(precision, 19)) : (k += 1) precision_factor *= 10;
    const abs_scaled: u128 = @intCast(@abs(scaled));
    const prod = std.math.mul(u128, abs_scaled, precision_factor) catch return true;
    return prod >= MAX_FORMATTED;
}

fn formatGnuScientific(gpa: std.mem.Allocator, v: f64) []const u8 {
    var buf: [64]u8 = undefined;
    var sink = fmtnum.FixedSink{ .buf = &buf };
    fmtnum.emitFloat(&sink, .{ .conv = 'e', .precision = 5 }, v) catch {};
    const s = sink.slice();
    const e_pos = std.mem.indexOfScalar(u8, s, 'e') orelse return gpa.dupe(u8, s) catch s;
    var mantissa = s[0..e_pos];
    const exp = s[e_pos + 1 ..];
    mantissa = std.mem.trimEnd(u8, mantissa, "0");
    mantissa = std.mem.trimEnd(u8, mantissa, ".");
    return std.fmt.allocPrint(gpa, "{s}e{s}", .{ mantissa, exp }) catch s;
}

const ExactIntResult = union(enum) { not_applicable, ok: []const u8, err: []const u8 };

/// The i128 exact-integer fast path: if the (unscaled) input is an exact integer
/// evenly divisible by `--to-unit` and `--to=none`, format it with zero float error.
fn tryFormatExactIntWithoutSuffixScaling(gpa: std.mem.Allocator, value: ParsedNumber, opts: TransformOptions, precision: usize) ExactIntResult {
    if (opts.to != .none) return .not_applicable;
    const integer = value.exactInt() orelse return .not_applicable;
    const to_unit: i128 = @intCast(opts.to_unit);
    if (@mod(integer, to_unit) != 0) return .not_applicable;
    const scaled = @divExact(integer, to_unit);

    if (isTooLargeToFormat(scaled, precision)) {
        const sci = formatGnuScientific(gpa, @floatFromInt(scaled));
        return .{ .err = allocErr(gpa, "value/precision too large to be printed: '{s}/{d}' (consider using --to)", .{ sci, precision }) };
    }
    if (precision == 0) {
        return .{ .ok = std.fmt.allocPrint(gpa, "{d}", .{scaled}) catch "0" };
    }
    var zeros_buf: [32]u8 = undefined;
    const zeros = zeros_buf[0..@min(precision, zeros_buf.len)];
    @memset(zeros, '0');
    return .{ .ok = std.fmt.allocPrint(gpa, "{d}.{s}", .{ scaled, zeros }) catch "0" };
}

/// Rust's `{:.precision$}` on a plain f64 (fixed notation, no width/sign flags) --
/// byte-identical to fmtnum's own `%f` (same exact-binary-value rounding, ties-to-
/// even; see fmtnum's module doc), so it's reused rather than re-derived.
fn fmtFloatPrec(gpa: std.mem.Allocator, value: f64, precision: usize) []const u8 {
    var buf: [512]u8 = undefined;
    var sink = fmtnum.FixedSink{ .buf = &buf };
    fmtnum.emitFloat(&sink, .{ .conv = 'f', .precision = precision }, value) catch {};
    return gpa.dupe(u8, sink.slice()) catch sink.slice();
}

fn fmtFloatPrecSuffix(gpa: std.mem.Allocator, value: f64, precision: usize, unit_separator: []const u8, suf: Suffix, to: Unit) []const u8 {
    var buf: [512]u8 = undefined;
    var sink = fmtnum.FixedSink{ .buf = &buf };
    fmtnum.emitFloat(&sink, .{ .conv = 'f', .precision = precision }, value) catch {};
    sink.extend(unit_separator) catch {};
    sink.push(displaySuffixChar(suf, to)) catch {};
    if (suf.with_i) sink.push('i') catch {};
    return gpa.dupe(u8, sink.slice()) catch sink.slice();
}

fn transformTo(gpa: std.mem.Allocator, s: ParsedNumber, opts: TransformOptions, round_method: RoundMethod, precision: usize, unit_separator: []const u8, is_precision_specified: bool, err_msg: *[]const u8) NumErr![]const u8 {
    switch (tryFormatExactIntWithoutSuffixScaling(gpa, s, opts, precision)) {
        .ok => |v| return v,
        .err => |e| {
            err_msg.* = e;
            return error.Invalid;
        },
        .not_applicable => {},
    }

    const to_raw = s.toF64() / @as(f64, @floatFromInt(opts.to_unit));
    const cr = try considerSuffix(gpa, to_raw, opts.to, round_method, precision, err_msg);
    const scaled = cr.value;

    if (cr.suffix) |suf| {
        if (precision > 0) return fmtFloatPrecSuffix(gpa, scaled, precision, unit_separator, suf, opts.to);
        if (is_precision_specified) return fmtFloatPrecSuffix(gpa, scaled, 0, unit_separator, suf, opts.to);
        if (@abs(scaled) < 10.0) return fmtFloatPrecSuffix(gpa, scaled, 1, unit_separator, suf, opts.to);
        return fmtFloatPrecSuffix(gpa, scaled, 0, unit_separator, suf, opts.to);
    }
    if (opts.to == .none) return fmtFloatPrec(gpa, roundWithPrecision(scaled, round_method, precision), precision);
    if (is_precision_specified) return fmtFloatPrec(gpa, roundWithPrecision(scaled, round_method, 0), precision);
    return fmtFloatPrec(gpa, scaled, 0);
}

// ============================================================================ --format string

const FormatOptions = struct {
    grouping: bool = false,
    padding: ?isize = null,
    precision: ?usize = null,
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    zero_padding: bool = false,
};

const FormatParseErr = error{Invalid};

/// `FormatOptions::from_str`: `[PREFIX]%[0]['][-][N][.][N]f[SUFFIX]`. `%%` inside the
/// prefix/suffix collapses to a literal `%` (GNU drops one char of the prefix per
/// `%%` pair -- ported verbatim, including that quirk).
fn parseFormatOptions(gpa: std.mem.Allocator, s: []const u8, err_msg: *[]const u8) FormatParseErr!FormatOptions {
    var opts = FormatOptions{};
    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var double_pct: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 1 < s.len and s[i + 1] == '%') {
            i += 2;
            double_pct += 1;
            prefix.appendSlice(gpa, "%%") catch @panic("OOM");
        } else if (s[i] == '%') {
            i += 1;
            break;
        } else {
            prefix.append(gpa, s[i]) catch @panic("OOM");
            i += 1;
        }
    }
    var k: usize = 0;
    while (k < double_pct and prefix.items.len > 0) : (k += 1) prefix.items.len -= 1;
    opts.prefix = prefix.toOwnedSlice(gpa) catch @panic("OOM");

    // `i >= s.len` here means the scan above either ran clean off the end (no `%` at
    // all) or consumed a lone trailing `%` with nothing after it -- both are errors,
    // distinguished only by whether the prefix ended up being the WHOLE string.
    if (i >= s.len) {
        if (std.mem.eql(u8, opts.prefix, s)) {
            err_msg.* = allocErr(gpa, "format '{s}' has no % directive", .{s});
        } else {
            err_msg.* = allocErr(gpa, "format '{s}' ends in %", .{s});
        }
        return error.Invalid;
    }

    while (i < s.len and (s[i] == ' ' or s[i] == '\'' or s[i] == '0')) : (i += 1) {
        if (s[i] == '\'') opts.grouping = true;
        if (s[i] == '0') opts.zero_padding = true;
    }

    var padding_buf: [32]u8 = undefined;
    var padding_len: usize = 0;
    if (i < s.len and s[i] == '-') {
        if (i + 1 < s.len and isDigit(s[i + 1])) {
            padding_buf[padding_len] = '-';
            padding_len += 1;
            i += 1;
        } else {
            err_msg.* = allocErr(gpa, "invalid format '{s}', directive must be %[0]['][-][N][.][N]f", .{s});
            return error.Invalid;
        }
    }
    while (i < s.len and isDigit(s[i]) and padding_len < padding_buf.len) : (i += 1) {
        padding_buf[padding_len] = s[i];
        padding_len += 1;
    }
    if (padding_len > 0) {
        opts.padding = std.fmt.parseInt(isize, padding_buf[0..padding_len], 10) catch {
            err_msg.* = allocErr(gpa, "invalid format '{s}' (width overflow)", .{s});
            return error.Invalid;
        };
    }

    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i < s.len and (s[i] == ' ' or s[i] == '+' or s[i] == '-')) {
            err_msg.* = allocErr(gpa, "invalid precision in format '{s}'", .{s});
            return error.Invalid;
        }
        var prec_buf: [32]u8 = undefined;
        var prec_len: usize = 0;
        while (i < s.len and isDigit(s[i]) and prec_len < prec_buf.len) : (i += 1) {
            prec_buf[prec_len] = s[i];
            prec_len += 1;
        }
        if (prec_len == 0) {
            opts.precision = 0;
        } else {
            opts.precision = std.fmt.parseInt(usize, prec_buf[0..prec_len], 10) catch {
                err_msg.* = allocErr(gpa, "invalid precision in format '{s}'", .{s});
                return error.Invalid;
            };
        }
    }

    if (i < s.len and s[i] == 'f') {
        i += 1;
    } else {
        err_msg.* = allocErr(gpa, "invalid format '{s}', directive must be %[0]['][-][N][.][N]f", .{s});
        return error.Invalid;
    }

    var suffix: std.ArrayListUnmanaged(u8) = .empty;
    while (i < s.len) {
        if (s[i] != '%') {
            suffix.append(gpa, s[i]) catch @panic("OOM");
            i += 1;
        } else if (i + 1 < s.len and s[i + 1] == '%') {
            suffix.appendSlice(gpa, "%%") catch @panic("OOM");
            i += 2;
        } else {
            err_msg.* = allocErr(gpa, "format '{s}' has too many % directives", .{s});
            return error.Invalid;
        }
    }
    opts.suffix = suffix.toOwnedSlice(gpa) catch @panic("OOM");
    return opts;
}

fn parseImplicitPrecision(s: []const u8) usize {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return 0;
    var n: usize = 0;
    var i = dot + 1;
    while (i < s.len and isDigit(s[i])) : (i += 1) n += 1;
    return n;
}

/// Locale-dependent under GNU numfmt; hard-coded to the C/POSIX locale's EMPTY
/// grouping separator (verified: `--grouping` is a byte-for-byte no-op under
/// `LC_ALL=C` on the oracle) -- see module doc.
fn applyGrouping(s: []const u8) []const u8 {
    return s;
}

fn padString(gpa: std.mem.Allocator, s: []const u8, width: usize, fill: u8, right_align: bool) []const u8 {
    if (s.len >= width) return s;
    const pad = width - s.len;
    var out = gpa.alloc(u8, width) catch @panic("OOM");
    if (right_align) {
        @memset(out[0..pad], fill);
        @memcpy(out[pad..], s);
    } else {
        @memcpy(out[0..s.len], s);
        @memset(out[s.len..], fill);
    }
    return out;
}

const NumfmtOptions = struct {
    transform: TransformOptions,
    padding: isize = 0,
    header: usize = 0,
    fields: []const Range,
    delimiter: ?[]const u8 = null,
    round: RoundMethod = .from_zero,
    suffix: ?[]const u8 = null,
    unit_separator: []const u8 = "",
    grouping: bool = false,
    explicit_unit_separator: bool = false,
    format: FormatOptions = .{},
    invalid: InvalidMode = .abort,
    zero_terminated: bool = false,
    debug: bool = false,
};

fn formatString(gpa: std.mem.Allocator, source: []const u8, options: NumfmtOptions, implicit_padding: ?isize, err_msg: *[]const u8) NumErr![]const u8 {
    const source_without_suffix = if (options.suffix) |suf|
        (if (std.mem.endsWith(u8, source, suf)) source[0 .. source.len - suf.len] else source)
    else
        source;

    var is_precision_specified = true;
    const precision: usize = if (options.format.precision) |p|
        p
    else if (options.transform.to == .none and !(source_without_suffix.len > 0 and std.ascii.isAlphabetic(source_without_suffix[source_without_suffix.len - 1])))
        parseImplicitPrecision(source_without_suffix)
    else blk: {
        is_precision_specified = false;
        break :blk 0;
    };

    const from = try transformFrom(gpa, source_without_suffix, options.transform, options.unit_separator, options.explicit_unit_separator, err_msg);
    const number = try transformTo(gpa, from, options.transform, options.round, precision, options.unit_separator, is_precision_specified, err_msg);

    const grouped_number = if (options.grouping) applyGrouping(number) else number;
    const number_with_suffix = if (options.suffix) |suf| std.fmt.allocPrint(gpa, "{s}{s}", .{ grouped_number, suf }) catch grouped_number else grouped_number;

    const padding = options.format.padding orelse (implicit_padding orelse options.padding);

    var padded_number: []const u8 = number_with_suffix;
    if (padding == 0) {
        padded_number = number_with_suffix;
    } else if (padding > 0 and options.format.zero_padding) {
        const p: usize = @intCast(padding);
        var zero_padded: []const u8 = undefined;
        if (number_with_suffix.len > 0 and (number_with_suffix[0] == '-' or number_with_suffix[0] == '+')) {
            const sign = number_with_suffix[0..1];
            const unsigned = number_with_suffix[1..];
            zero_padded = std.fmt.allocPrint(gpa, "{s}{s}", .{ sign, padString(gpa, unsigned, p - 1, '0', true) }) catch number_with_suffix;
        } else {
            zero_padded = padString(gpa, number_with_suffix, p, '0', true);
        }
        const outer = implicit_padding orelse options.padding;
        if (outer == 0) {
            padded_number = zero_padded;
        } else if (outer > 0) {
            padded_number = padString(gpa, zero_padded, @intCast(outer), ' ', true);
        } else {
            padded_number = padString(gpa, zero_padded, @intCast(-outer), ' ', false);
        }
    } else if (padding > 0) {
        padded_number = padString(gpa, number_with_suffix, @intCast(padding), ' ', true);
    } else {
        padded_number = padString(gpa, number_with_suffix, @intCast(-padding), ' ', false);
    }

    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ options.format.prefix, padded_number, options.format.suffix }) catch padded_number;
}

/// Octal-escapes non-graphic/non-whitespace ASCII bytes and raw invalid-UTF-8 bytes,
/// leaving valid multi-byte UTF-8 alone -- used only to safely embed raw input bytes
/// in error messages (`escape_line`).
fn escapeLine(gpa: std.mem.Allocator, line: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (line) |b| {
        if (b < 0x80 and !std.ascii.isPrint(b) and !std.ascii.isWhitespace(b)) {
            out.append(gpa, '\\') catch @panic("OOM");
            out.append(gpa, '0' + ((b >> 6) & 7)) catch @panic("OOM");
            out.append(gpa, '0' + ((b >> 3) & 7)) catch @panic("OOM");
            out.append(gpa, '0' + (b & 7)) catch @panic("OOM");
        } else {
            out.append(gpa, b) catch @panic("OOM");
        }
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

// ============================================================================ field splitting + line drivers

fn splitBytesNext(input: []const u8, delim: []const u8) struct { field: []const u8, rest: ?[]const u8 } {
    if (delim.len == 0 or input.len == 0) return .{ .field = input, .rest = null };
    if (std.mem.indexOf(u8, input, delim)) |pos| {
        return .{ .field = input[0..pos], .rest = input[pos + delim.len ..] };
    }
    return .{ .field = input, .rest = null };
}

fn isAsciiWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

const FieldSplit = struct { prefix: []const u8, field: []const u8, rest: []const u8 };

fn splitNextField(s: []const u8) FieldSplit {
    var prefix_len: usize = 0;
    while (prefix_len < s.len and isAsciiWs(s[prefix_len])) : (prefix_len += 1) {}
    var field_end = prefix_len;
    while (field_end < s.len and !isAsciiWs(s[field_end])) : (field_end += 1) {}
    return .{ .prefix = s[0..prefix_len], .field = s[prefix_len..field_end], .rest = s[field_end..] };
}

/// When `--unit-separator` is itself whitespace, a suffix like `K` may land as its
/// OWN whitespace-delimited field (e.g. `5 K`); detect that so the caller can splice
/// it back onto the number field -- `split_mergeable_suffix`.
fn splitMergeableSuffix(s: []const u8, unit_separator: []const u8, explicit_unit_separator: bool) ?FieldSplit {
    if (!explicit_unit_separator or unit_separator.len == 0) return null;
    for (unit_separator) |c| if (!isAsciiWs(c)) return null;
    if (!std.mem.startsWith(u8, s, unit_separator)) return null;
    const sp = splitNextField(s);
    if (!std.mem.eql(u8, sp.prefix, unit_separator)) return null;
    if (sp.field.len == 0) return null;
    if (RawSuffix.fromChar(sp.field[0]) == null) return null;
    if (sp.field.len == 1) return sp;
    if (sp.field.len == 2 and sp.field[1] == 'i') return sp;
    return null;
}

const WhitespaceSplitter = struct {
    s: ?[]const u8,
    unit_separator: []const u8,
    explicit_unit_separator: bool,

    fn next(self: *WhitespaceSplitter) ?struct { prefix: []const u8, field: []const u8 } {
        const haystack = self.s orelse return null;
        const sp = splitNextField(haystack);
        if (sp.field.len == 0) {
            self.s = null;
            return .{ .prefix = sp.prefix, .field = sp.field };
        }
        if (splitMergeableSuffix(sp.rest, self.unit_separator, self.explicit_unit_separator)) |m| {
            const merged_len = sp.prefix.len + sp.field.len + m.prefix.len + m.field.len;
            const merged_field = haystack[sp.prefix.len..merged_len];
            const remainder = haystack[merged_len..];
            self.s = if (remainder.len > 0) remainder else null;
            return .{ .prefix = sp.prefix, .field = merged_field };
        }
        self.s = if (sp.rest.len > 0) sp.rest else null;
        return .{ .prefix = sp.prefix, .field = sp.field };
    }
};

fn writeFormattedWithDelimiter(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), input: []const u8, options: NumfmtOptions, eol: ?u8, err_msg: *[]const u8) NumErr!void {
    const delim = options.delimiter.?;
    var n: usize = 1;
    var rest: ?[]const u8 = input;
    while (rest) |cur| {
        const sp = splitBytesNext(cur, delim);
        rest = sp.rest;
        if (n > 1) out.appendSlice(gpa, delim) catch @panic("OOM");
        if (rangesContain(options.fields, n)) {
            if (!std.unicode.utf8ValidateSlice(sp.field)) {
                err_msg.* = allocErr(gpa, "invalid number: '{s}'", .{escapeLine(gpa, sp.field)});
                return error.Invalid;
            }
            var i: usize = 0;
            while (i < sp.field.len and isAsciiWs(sp.field[i])) : (i += 1) {}
            const formatted = try formatString(gpa, sp.field[i..], options, null, err_msg);
            out.appendSlice(gpa, formatted) catch @panic("OOM");
        } else {
            out.appendSlice(gpa, sp.field) catch @panic("OOM");
        }
        n += 1;
    }
    if (eol) |e| out.append(gpa, e) catch @panic("OOM");
}

fn writeFormattedWithWhitespace(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8, options: NumfmtOptions, eol: ?u8, err_msg: *[]const u8) NumErr!void {
    var splitter = WhitespaceSplitter{ .s = s, .unit_separator = options.unit_separator, .explicit_unit_separator = options.explicit_unit_separator };
    var n: usize = 1;
    while (splitter.next()) |pf| : (n += 1) {
        if (rangesContain(options.fields, n)) {
            const empty_prefix = pf.prefix.len == 0;
            var prefix = pf.prefix;
            if (n > 1) {
                out.append(gpa, ' ') catch @panic("OOM");
                prefix = prefix[1..];
            }
            const implicit_padding: ?isize = if (!empty_prefix and options.padding == 0) @intCast(prefix.len + pf.field.len) else null;
            const formatted = try formatString(gpa, pf.field, options, implicit_padding, err_msg);
            out.appendSlice(gpa, formatted) catch @panic("OOM");
        } else {
            var prefix = pf.prefix;
            if (options.zero_terminated and prefix.len > 0 and prefix[0] == '\n') {
                out.append(gpa, ' ') catch @panic("OOM");
                prefix = prefix[1..];
            }
            out.appendSlice(gpa, prefix) catch @panic("OOM");
            out.appendSlice(gpa, pf.field) catch @panic("OOM");
        }
    }
    if (eol) |e| out.append(gpa, e) catch @panic("OOM");
}

const LineOutcome = enum { ok, invalid, abort };

/// Formats one line/arg, honoring `--invalid`. In ABORT mode `real_sink` IS the
/// destination the field-by-field writers append to directly -- matching the
/// reference exactly: a line whose first field succeeds and second field fails
/// still leaves the first field's bytes in the (real, unbuffered) output before the
/// abort. Every OTHER mode buffers into a throwaway temp first, discarding it (and
/// emitting the ORIGINAL raw line instead) on failure.
fn formatAndWrite(gpa: std.mem.Allocator, ctx: *Ctx, real_sink: *std.ArrayListUnmanaged(u8), input_line: []const u8, options: NumfmtOptions, eol: ?u8) LineOutcome {
    const line = if (std.mem.indexOfScalar(u8, input_line, 0)) |z| input_line[0..z] else input_line;

    const buffer_output = options.invalid != .abort;
    var temp: std.ArrayListUnmanaged(u8) = .empty;
    const dest: *std.ArrayListUnmanaged(u8) = if (buffer_output) &temp else real_sink;

    var err_msg: []const u8 = "";
    const result: NumErr!void = blk: {
        if (options.delimiter != null) {
            break :blk writeFormattedWithDelimiter(gpa, dest, line, options, eol, &err_msg);
        }
        if (!std.unicode.utf8ValidateSlice(line)) {
            err_msg = allocErr(gpa, "invalid number: '{s}'", .{escapeLine(gpa, line)});
            break :blk error.Invalid;
        }
        if (isScientific(line)) {
            err_msg = allocErr(gpa, "invalid suffix in input: '{s}'", .{line});
            break :blk error.Invalid;
        }
        break :blk writeFormattedWithWhitespace(gpa, dest, line, options, eol, &err_msg);
    };

    if (result) |_| {
        if (buffer_output) real_sink.appendSlice(gpa, temp.items) catch @panic("OOM");
        return .ok;
    } else |_| {}

    switch (options.invalid) {
        .abort => {
            ctx.errPrint("{s}: {s}\n", .{ PROG, err_msg });
            return .abort;
        },
        .fail, .warn => ctx.errPrint("{s}: {s}\n", .{ PROG, err_msg }),
        .ignore => {},
    }
    real_sink.appendSlice(gpa, input_line) catch @panic("OOM");
    if (eol) |e| real_sink.append(gpa, e) catch @panic("OOM");
    return .invalid;
}

/// Raw (NO `\r`-stripping -- unlike `core/textio.LineReader`, which numfmt must NOT
/// use) terminator-delimited reader; growable so a pathologically long line never
/// silently truncates. `had_term` lets the caller preserve a missing final
/// terminator, matching `read_until`'s exact contract.
const RawLineReader = struct {
    fd: sys.Fd,
    gpa: std.mem.Allocator,
    term: u8,
    chunk: [8192]u8 = undefined,
    pending: std.ArrayListUnmanaged(u8) = .empty,
    pending_start: usize = 0,
    eof: bool = false,

    fn next(self: *RawLineReader) ?struct { line: []const u8, had_term: bool } {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.pending.items, self.pending_start, self.term)) |pos| {
                const line = self.pending.items[self.pending_start..pos];
                self.pending_start = pos + 1;
                return .{ .line = line, .had_term = true };
            }
            if (self.eof) {
                if (self.pending_start < self.pending.items.len) {
                    const line = self.pending.items[self.pending_start..];
                    self.pending_start = self.pending.items.len;
                    return .{ .line = line, .had_term = false };
                }
                return null;
            }
            const n = sys.read(self.fd, &self.chunk) catch 0;
            if (n == 0) {
                self.eof = true;
                continue;
            }
            if (self.pending_start > 0) {
                const remaining = self.pending.items.len - self.pending_start;
                std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[self.pending_start..]);
                self.pending.items.len = remaining;
                self.pending_start = 0;
            }
            self.pending.appendSlice(self.gpa, self.chunk[0..n]) catch @panic("OOM");
        }
    }
};

fn handleBuffer(gpa: std.mem.Allocator, ctx: *Ctx, fd: sys.Fd, options: NumfmtOptions) u8 {
    const terminator: u8 = if (options.zero_terminated) 0 else '\n';
    var reader = RawLineReader{ .fd = fd, .gpa = gpa, .term = terminator };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var line_idx: usize = 0;
    var saw_invalid = false;
    var aborted = false;
    while (reader.next()) |ln| {
        const eol: ?u8 = if (ln.had_term) terminator else null;
        if (line_idx < options.header) {
            out.appendSlice(gpa, ln.line) catch @panic("OOM");
            if (eol) |e| out.append(gpa, e) catch @panic("OOM");
        } else {
            switch (formatAndWrite(gpa, ctx, &out, ln.line, options, eol)) {
                .ok => {},
                .invalid => saw_invalid = true,
                .abort => aborted = true,
            }
        }
        line_idx += 1;
        if (aborted) break;
    }
    ctx.outWrite(out.items) catch {};
    if (aborted) return 2;
    if (saw_invalid and options.invalid == .fail) return 2;
    return 0;
}

/// `--header` is ignored entirely here (matches the reference's debug warning
/// "--header ignored with command-line input"); every arg gets a terminator
/// (unconditionally, unlike buffer mode's "only if the source line had one").
fn handleArgs(gpa: std.mem.Allocator, ctx: *Ctx, args: []const []const u8, options: NumfmtOptions) u8 {
    const terminator: u8 = if (options.zero_terminated) 0 else '\n';
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var saw_invalid = false;
    for (args) |a| {
        switch (formatAndWrite(gpa, ctx, &out, a, options, terminator)) {
            .ok => {},
            .invalid => saw_invalid = true,
            .abort => {
                ctx.outWrite(out.items) catch {};
                return 2;
            },
        }
    }
    ctx.outWrite(out.items) catch {};
    if (saw_invalid and options.invalid == .fail) return 2;
    return 0;
}

// ============================================================================ CLI

const spec = cli.Spec{
    .name = "numfmt",
    .flags = &.{
        cli.flagOpt(null, "debug", "print warnings about invalid input"),
        cli.flagOpt(null, "grouping", "use locale-defined grouping of digits"),
        cli.valueOpt('d', "delimiter", "use X instead of whitespace for field delimiter"),
        cli.valueOpt(null, "field", "replace the numbers in these input fields"),
        cli.valueOpt(null, "format", "use printf style floating-point FORMAT"),
        cli.valueOpt(null, "from", "auto-scale input numbers to UNITs"),
        cli.valueOpt(null, "from-unit", "specify the input unit size"),
        cli.valueOpt(null, "to", "auto-scale output numbers to UNITs"),
        cli.valueOpt(null, "to-unit", "the output unit size"),
        cli.valueOpt(null, "padding", "pad the output to N characters"),
        cli.valueOpt(null, "header", "print (without converting) the first N header lines"),
        cli.valueOpt(null, "round", "use METHOD for rounding when scaling"),
        cli.valueOpt(null, "suffix", "print SUFFIX after each formatted number"),
        cli.valueOpt(null, "unit-separator", "use STRING to separate the number from any unit"),
        cli.valueOpt(null, "invalid", "set the failure mode for invalid input"),
        cli.flagOpt('z', "zero-terminated", "line delimiter is NUL, not newline"),
    },
    .help = .{
        .summary = "convert numbers to/from human-readable scaled forms",
        .synopsis = &.{ "numfmt [OPTION]... [NUMBER]...", "numfmt [OPTION]... < input" },
        .description =
        \\Reformats each NUMBER operand (or, with none, each
        \\whitespace/`--delimiter`-separated field of every line of standard input) by
        \\scaling it between a raw
        \\value and a suffixed form. `--from` parses an input suffix; `--to` produces
        \\an output suffix; both take `si` (1000^n ladder), `iec` (1024^n, plain letter
        \\suffix), `iec-i` (1024^n, `Ki`/`Mi`/... suffix), or `none` (default: no
        \\scaling either way; `--from=auto` additionally accepts either ladder on
        \\input). The suffix ladder is `K M G T P E Z Y R Q`. `--from-unit`/`--to-unit`
        \\multiply/divide by a fixed size before/after scaling; `--field` (cut-style
        \\ranges, default `1`) picks which whitespace/delimiter-separated field(s) of
        \\each input line to convert; `--format` supplies a printf-style
        \\`%[0]['][-][N][.][N]f` template around the number; `--round` selects among 5
        \\rounding methods (default `from-zero`); `--padding` and `--header=N` control
        \\field width and how many leading lines/args pass through unconverted.
        \\
        \\`--invalid` controls what happens when an input NUMBER can't be parsed:
        \\`abort` (default, stop immediately), `fail`, `warn`, or `ignore` (pass the
        \\original text through unchanged).
        ,
        .operands = "NUMBER... to format directly; with none given, reads NUMBER(s) from each line of standard input, writing one formatted line per input line.",
        .exit = &.{
            .{ .code = 0, .when = "success (including a tolerated bad NUMBER under --invalid=warn/ignore)" },
            .{ .code = 1, .when = "an illegal command-line argument, unit, or --format string, or an I/O error" },
            .{ .code = 2, .when = "an input NUMBER could not be parsed, under the default --invalid=abort or under --invalid=fail" },
        },
        .deviations_from = "uutils coreutils 0.9.0",
        .deviations = &.{
            "All locale-dependent behavior (the --grouping digit separator, the decimal point) is hard-coded to the C/POSIX locale regardless of the environment, so --grouping is effectively a no-op.",
        },
        .examples = &.{
            .{ .cmd = "numfmt --to=si <<< 123456", .note = "124k" },
            .{ .cmd = "numfmt --to=iec <<< 123456", .note = "121K" },
            .{ .cmd = "numfmt --from=si <<< 5K", .note = "5000" },
        },
        .see_also = "cut (the --field range syntax this shares).",
    },
    .positionals = .{ .name = "NUMBER", .min = 0, .max = null },
    .allow_hyphen_values = true,
};

/// `--header` is a clap "optional value" arg (see module doc): normalize a bare
/// `--header` (no `=`) into `--header=N` before `cli.zig` (which has no notion of
/// optional-value flags) ever sees it -- attached value if the NEXT raw token
/// doesn't start with `-`, else the default missing value `1`.
fn rewriteHeaderArg(gpa: std.mem.Allocator, args: []const [:0]const u8) []const [:0]const u8 {
    var idx: ?usize = null;
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--header")) {
            idx = i;
            break;
        }
    }
    const at = idx orelse return args;
    const has_next = at + 1 < args.len and args[at + 1].len > 0 and args[at + 1][0] != '-';
    var out = std.ArrayListUnmanaged([:0]const u8).initCapacity(gpa, args.len) catch @panic("OOM");
    out.appendSlice(gpa, args[0..at]) catch @panic("OOM");
    if (has_next) {
        out.append(gpa, std.fmt.allocPrintSentinel(gpa, "--header={s}", .{args[at + 1]}, 0) catch @panic("OOM")) catch @panic("OOM");
        out.appendSlice(gpa, args[at + 2 ..]) catch @panic("OOM");
    } else {
        out.append(gpa, "--header=1") catch @panic("OOM");
        out.appendSlice(gpa, args[at + 1 ..]) catch @panic("OOM");
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

fn parseUnit(s: []const u8, opt_is_to: bool) ?Unit {
    if (std.mem.eql(u8, s, "auto") and !opt_is_to) return .auto;
    if (std.mem.eql(u8, s, "si")) return .si;
    if (std.mem.eql(u8, s, "iec")) return .iec;
    if (std.mem.eql(u8, s, "iec-i")) return .iec_i;
    if (std.mem.eql(u8, s, "none")) return .none;
    return null;
}

fn parseUnitSizeSuffix(s: []const u8) ?usize {
    if (s.len == 0) return 1;
    const letters = "KMGTPE";
    const idx = std.mem.indexOfScalar(u8, letters, s[0]) orelse return null;
    var base: usize = 1;
    var k: usize = 0;
    while (k <= idx) : (k += 1) base *= 1000;
    if (s.len == 1) {
        var ibase: usize = 1;
        k = 0;
        while (k <= idx) : (k += 1) ibase *= 1024;
        return ibase;
    }
    return null;
}

fn parseUnitSize(s: []const u8) ?usize {
    var split: usize = 0;
    while (split < s.len and isDigit(s[split])) : (split += 1) {}
    const number = s[0..split];
    const suffix = s[split..];
    const all_zero = number.len > 0 and blk: {
        for (number) |c| if (c != '0') break :blk false;
        break :blk true;
    };
    if (!all_zero) {
        if (parseUnitSizeSuffix(suffix)) |mult| {
            if (number.len == 0) return mult;
            if (std.fmt.parseUnsigned(usize, number, 10)) |n| return n * mult else |_| {}
        }
    }
    return null;
}

/// `-d`/`--delimiter`: a single character (up to 4 raw bytes if not valid UTF-8, to
/// allow a lone non-UTF8 byte -- `parse_delimiter`); anything longer errors.
fn parseDelimiterArg(s: []const u8) ?[]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) {
        var it = (std.unicode.Utf8View.init(s) catch return null).iterator();
        var count: usize = 0;
        while (it.nextCodepoint() != null) count += 1;
        if (count > 1) return null;
        return s;
    }
    if (s.len > 4) return null;
    return s;
}

pub fn run(ctx: *Ctx) u8 {
    var ctx2 = ctx.*;
    ctx2.args = rewriteHeaderArg(ctx.gpa, ctx.args);
    const res = cli.parse(&ctx2, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const from = parseUnit(m.value("from") orelse "none", false) orelse {
        ctx.errPrint("{s}: invalid argument '{s}' for '--from'\n", .{ PROG, m.value("from").? });
        return 1;
    };
    const to = parseUnit(m.value("to") orelse "none", true) orelse {
        ctx.errPrint("{s}: invalid argument '{s}' for '--to'\n", .{ PROG, m.value("to").? });
        return 1;
    };
    const from_unit = parseUnitSize(m.value("from-unit") orelse "1") orelse {
        ctx.errPrint("{s}: invalid unit size: '{s}'\n", .{ PROG, m.value("from-unit").? });
        return 1;
    };
    const to_unit = parseUnitSize(m.value("to-unit") orelse "1") orelse {
        ctx.errPrint("{s}: invalid unit size: '{s}'\n", .{ PROG, m.value("to-unit").? });
        return 1;
    };

    var padding: isize = 0;
    if (m.value("padding")) |p| {
        const n = std.fmt.parseInt(isize, p, 10) catch {
            ctx.errPrint("{s}: invalid padding value '{s}'\n", .{ PROG, p });
            return 1;
        };
        if (n == 0) {
            ctx.errPrint("{s}: invalid padding value '{s}'\n", .{ PROG, p });
            return 1;
        }
        padding = n;
    }

    var header: usize = 0;
    if (m.value("header")) |h| {
        const n = std.fmt.parseUnsigned(usize, h, 10) catch {
            ctx.errPrint("{s}: invalid header value '{s}'\n", .{ PROG, h });
            return 1;
        };
        if (n == 0) {
            ctx.errPrint("{s}: invalid header value '{s}'\n", .{ PROG, h });
            return 1;
        }
        header = n;
    }

    const field_spec = m.value("field") orelse "1";
    var lone_dash = false;
    {
        var it = std.mem.splitAny(u8, field_spec, ", ");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "-")) lone_dash = true;
        }
    }
    var fields: []Range = undefined;
    if (lone_dash) {
        fields = ctx.gpa.dupe(Range, &[_]Range{.{ .low = 1, .high = std.math.maxInt(usize) }}) catch @panic("OOM");
    } else {
        var err_msg: []const u8 = "";
        fields = parseRangeList(ctx.gpa, field_spec, &err_msg) catch {
            ctx.errPrint("{s}: {s}\n", .{ PROG, err_msg });
            return 1;
        };
    }

    const grouping_flag = m.has("grouping");
    var format = FormatOptions{};
    if (m.value("format")) |fs| {
        var err_msg: []const u8 = "";
        format = parseFormatOptions(ctx.gpa, fs, &err_msg) catch {
            ctx.errPrint("{s}: {s}\n", .{ PROG, err_msg });
            return 1;
        };
    }
    if (grouping_flag and m.has("format")) {
        ctx.errPrint("{s}: --grouping cannot be combined with --format\n", .{PROG});
        return 1;
    }
    const grouping = grouping_flag or format.grouping;
    if (grouping and to != .none) {
        ctx.errPrint("{s}: grouping cannot be combined with --to\n", .{PROG});
        return 1;
    }

    var delimiter: ?[]const u8 = null;
    if (m.value("delimiter")) |d| {
        delimiter = parseDelimiterArg(d) orelse {
            ctx.errPrint("{s}: the delimiter must be a single character\n", .{PROG});
            return 1;
        };
    }

    const round_str = m.value("round") orelse "from-zero";
    const round: RoundMethod = if (std.mem.eql(u8, round_str, "up"))
        .up
    else if (std.mem.eql(u8, round_str, "down"))
        .down
    else if (std.mem.eql(u8, round_str, "from-zero"))
        .from_zero
    else if (std.mem.eql(u8, round_str, "towards-zero"))
        .towards_zero
    else if (std.mem.eql(u8, round_str, "nearest"))
        .nearest
    else {
        ctx.errPrint("{s}: invalid round method: '{s}'\n", .{ PROG, round_str });
        return 1;
    };

    const invalid_str = m.value("invalid") orelse "abort";
    const invalid: InvalidMode = if (std.ascii.eqlIgnoreCase(invalid_str, "abort"))
        .abort
    else if (std.ascii.eqlIgnoreCase(invalid_str, "fail"))
        .fail
    else if (std.ascii.eqlIgnoreCase(invalid_str, "warn"))
        .warn
    else if (std.ascii.eqlIgnoreCase(invalid_str, "ignore"))
        .ignore
    else {
        ctx.errPrint("{s}: Unknown invalid mode: {s}\n", .{ PROG, invalid_str });
        return 1;
    };

    const options = NumfmtOptions{
        .transform = .{ .from = from, .from_unit = from_unit, .to = to, .to_unit = to_unit },
        .padding = padding,
        .header = header,
        .fields = fields,
        .delimiter = delimiter,
        .round = round,
        .suffix = m.value("suffix"),
        .unit_separator = m.value("unit-separator") orelse "",
        .grouping = grouping,
        .explicit_unit_separator = m.has("unit-separator"),
        .format = format,
        .invalid = invalid,
        .zero_terminated = m.has("zero-terminated"),
        .debug = m.has("debug"),
    };

    const positionals = m.positionalSlice();
    if (positionals.len > 0) {
        return handleArgs(ctx.gpa, ctx, positionals, options);
    }
    return handleBuffer(ctx.gpa, ctx, ctx.stdin, options);
}
