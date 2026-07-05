//! The C printf engine (DESIGN.md §6): integer conversions `%d %i %u %o %x %X %c %s`
//! and float conversions `%f %e %E %g %G` with C99 semantics -- flags `- + space 0 #`,
//! field width, precision (both runtime values, for `*`). Consumed by printf, seq, and
//! later awk/numfmt/od/stat/date. This is the single hardest byte-parity surface
//! outside the engines (DESIGN.md §6 table, R4), so semantics are pinned by unit-test
//! vectors authored from C-double oracles (python3 `%`-formatting == glibc-on-f64;
//! host GNU printf(1) uses long double and was only used where the two agree).
//!
//! ## Float digit extraction: approach and bounds
//!
//! We need the decimal digits of an f64 with *correct rounding of the exact binary
//! value* (ties-to-even on exact ties), because that is what glibc printf and Rust's
//! `{:.N}` formatting both do -- and the reference seq derives its output from Rust
//! `{:.N}`. Implementation: widen the f64 to f128 (exact) and run the classic digit
//! loops -- `@mod`/divide-by-10 for the integer part, multiply-by-10 for the fraction
//! -- collecting up to 40 significant digits plus an `exact` flag ("the tail beyond
//! the extracted digits is exactly zero"), then round the digit string at the
//! requested position with half-even tie-breaking.
//!
//! Bounds (documented, deliberate): both loops are *exact* while every intermediate
//! fits f128's 113-bit mantissa. That holds for (a) integer parts < 2^113 ~= 1.04e34
//! (above that, digits are approximate -- glibc would print the exact binary
//! expansion), and (b) roughly the first 30-34 significant digits of any value (the
//! fraction loop gains ~2.3 mantissa bits per extracted leading zero in the worst
//! case). seq/printf corpus magnitudes are orders of magnitude below both bounds; a
//! user-supplied `seq -f %.60f` would see zeros where glibc prints the exact binary
//! tail -- accepted and documented here.
//!
//! Allocation-free: digit buffers are fixed (352 bytes covers f64's 309 max integer
//! digits); width/precision padding is emitted by loops, so huge widths need no
//! buffer. Output goes to any sink with `extend([]const u8)` / `push(u8)` (textio's
//! BufOut, or the FixedSink/CountingSink below).

const std = @import("std");

pub const Flags = struct {
    minus: bool = false, // left-justify (overrides zero-pad)
    plus: bool = false, // signed: always emit sign
    space: bool = false, // signed: blank before positive
    zero: bool = false, // pad with zeros after sign/prefix
    hash: bool = false, // alternate form (0/0x prefix, keep point/zeros)
};

pub const Spec = struct {
    flags: Flags = .{},
    width: usize = 0,
    precision: ?usize = null,
    conv: u8, // 'd' 'i' 'u' 'o' 'x' 'X' 'c' 's' 'f' 'e' 'E' 'g' 'G'
};

pub const ScannedSpec = struct { spec: Spec, end: usize };

/// Scans one printf conversion spec starting at `s[start]` (which must be `%`), parsing
/// `[flags][width][.precision]` + C length modifiers (`l h L q j z t`, skipped) + the
/// conversion char. Does NOT support `*` width/precision from an argument stream --
/// printf, which needs that, scans inline and consumes args mid-scan. Returns the parsed
/// `Spec` and the index just past the conversion char, or `null` if the `%` is
/// unterminated (no conversion char before end). `%%` must be handled by the caller.
pub fn scanSpec(s: []const u8, start: usize) ?ScannedSpec {
    var j = start + 1; // past '%'
    var spec = Spec{ .conv = 0 };
    while (j < s.len) : (j += 1) {
        switch (s[j]) {
            '-' => spec.flags.minus = true,
            '+' => spec.flags.plus = true,
            ' ' => spec.flags.space = true,
            '0' => spec.flags.zero = true,
            '#' => spec.flags.hash = true,
            '\'' => {}, // thousands-grouping flag: accepted and ignored
            else => break,
        }
    }
    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) spec.width = spec.width * 10 + (s[j] - '0');
    if (j < s.len and s[j] == '.') {
        j += 1;
        var p: usize = 0;
        while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) p = p * 10 + (s[j] - '0');
        spec.precision = p;
    }
    while (j < s.len and std.mem.indexOfScalar(u8, "lhLqjzt", s[j]) != null) j += 1;
    if (j >= s.len) return null;
    spec.conv = s[j];
    return .{ .spec = spec, .end = j + 1 };
}

/// Parses a complete single `"%...conv"` spec string into a `Spec` (awk's sprintf
/// directive, already delimited by the caller). Falls back to `conv = last byte` on a
/// malformed spec, matching the lenient callers.
pub fn parseSpec(s: []const u8) Spec {
    if (scanSpec(s, 0)) |r| return r.spec;
    return .{ .conv = if (s.len > 0) s[s.len - 1] else 's' };
}

/// Fixed-capacity sink matching BufOut's extend/push shape; errors on overflow.
pub const FixedSink = struct {
    buf: []u8,
    len: usize = 0,

    pub fn extend(self: *FixedSink, bytes: []const u8) error{NoSpaceLeft}!void {
        if (self.len + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn push(self: *FixedSink, b: u8) error{NoSpaceLeft}!void {
        if (self.len >= self.buf.len) return error.NoSpaceLeft;
        self.buf[self.len] = b;
        self.len += 1;
    }

    pub fn slice(self: *const FixedSink) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Adapts a growable `std.ArrayListUnmanaged(u8)` (+ its allocator) to the extend/push
/// sink shape, for consumers that render into an owned buffer (awk's sprintf). Propagates
/// allocation failure so the caller decides how to handle it.
pub const ListSink = struct {
    gpa: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(u8),

    pub fn extend(self: *ListSink, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.list.appendSlice(self.gpa, bytes);
    }
    pub fn push(self: *ListSink, b: u8) std.mem.Allocator.Error!void {
        try self.list.append(self.gpa, b);
    }
};

/// Counts bytes without storing them (seq -w's first width-measuring pass).
pub const CountingSink = struct {
    len: usize = 0,

    pub fn extend(self: *CountingSink, bytes: []const u8) error{}!void {
        self.len += bytes.len;
    }

    pub fn push(self: *CountingSink, b: u8) error{}!void {
        _ = b;
        self.len += 1;
    }
};

fn padOut(out: anytype, byte: u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try out.push(byte);
}

// ------------------------------------------------------------------ integers

/// Digits of `v` in `base` written into the tail of `buf`; returns the slice ("0"
/// for 0).
fn udigits(buf: *[64]u8, v: u64, base: u8, upper: bool) []const u8 {
    const alphabet = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var i: usize = buf.len;
    var x = v;
    if (x == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (x != 0) {
            i -= 1;
            buf[i] = alphabet[@intCast(x % base)];
            x /= base;
        }
    }
    return buf[i..];
}

/// Shared field layout: [spaces][prefix][zero-pad][precision-zeros][digits][spaces].
/// `zero_allowed` differs between families (C99: precision disables `0` for
/// integers but not for floats; `-` always disables it).
fn emitNumField(out: anytype, spec: Spec, prefix: []const u8, prec_zeros: usize, digits: []const u8, zero_allowed: bool) !void {
    const body = prefix.len + prec_zeros + digits.len;
    const zero_pad = spec.flags.zero and !spec.flags.minus and zero_allowed;
    const pad = if (spec.width > body) spec.width - body else 0;
    if (!spec.flags.minus and !zero_pad) try padOut(out, ' ', pad);
    try out.extend(prefix);
    if (zero_pad) try padOut(out, '0', pad);
    try padOut(out, '0', prec_zeros);
    try out.extend(digits);
    if (spec.flags.minus) try padOut(out, ' ', pad);
}

/// `%d`/`%i`.
pub fn emitInt(out: anytype, spec: Spec, value: i64) !void {
    var dbuf: [64]u8 = undefined;
    var digits = udigits(&dbuf, @abs(value), 10, false);
    if (spec.precision) |p| {
        if (p == 0 and value == 0) digits = digits[0..0]; // C99: %.0d of 0 is empty
    }
    const prec_zeros = if (spec.precision) |p|
        (if (p > digits.len) p - digits.len else 0)
    else
        0;
    const prefix: []const u8 = if (value < 0)
        "-"
    else if (spec.flags.plus)
        "+"
    else if (spec.flags.space)
        " "
    else
        "";
    try emitNumField(out, spec, prefix, prec_zeros, digits, spec.precision == null);
}

/// `%u %o %x %X` (`+`/space ignored for unsigned, per C99).
pub fn emitUint(out: anytype, spec: Spec, value: u64) !void {
    const base: u8 = switch (spec.conv) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    var dbuf: [64]u8 = undefined;
    var digits = udigits(&dbuf, value, base, spec.conv == 'X');
    if (spec.precision) |p| {
        if (p == 0 and value == 0) digits = digits[0..0];
    }
    var prec_zeros = if (spec.precision) |p|
        (if (p > digits.len) p - digits.len else 0)
    else
        0;
    var prefix: []const u8 = "";
    if (spec.flags.hash) {
        switch (spec.conv) {
            // C99 `#o`: increase precision just enough to force one leading zero.
            'o' => if (prec_zeros == 0 and (digits.len == 0 or digits[0] != '0')) {
                prec_zeros = 1;
            },
            'x' => if (value != 0) {
                prefix = "0x";
            },
            'X' => if (value != 0) {
                prefix = "0X";
            },
            else => {},
        }
    }
    try emitNumField(out, spec, prefix, prec_zeros, digits, spec.precision == null);
}

/// `%s` (precision truncates bytes) and `%c` (pass a 1-byte or empty slice). The `0`
/// flag is ignored (undefined in C for s/c; GNU pads spaces).
pub fn emitStr(out: anytype, spec: Spec, s: []const u8) !void {
    const content = if (spec.precision) |p| s[0..@min(p, s.len)] else s;
    const pad = if (spec.width > content.len) spec.width - content.len else 0;
    if (!spec.flags.minus) try padOut(out, ' ', pad);
    try out.extend(content);
    if (spec.flags.minus) try padOut(out, ' ', pad);
}

// -------------------------------------------------------------------- floats

const MAX_DIG = 352; // 309 integer digits (f64 max) + fraction guard
const MAX_FRAC_SIG = 40; // significant fraction digits collected (see module doc)

/// Exported (beyond this file's own %f/%e/%g engine) so other exact-rounding
/// consumers (od's float formatters, numfmt's scaling display) can build their own
/// field layouts on the same digit-extraction/rounding core instead of duplicating
/// the f128 digit loops -- see od.zig/numfmt.zig module docs.
pub const Dec = struct {
    digits: [MAX_DIG]u8 = undefined, // ASCII, digits[0] nonzero unless value == 0
    n: usize = 0,
    exp10: i32 = 0, // value = 0.d1 d2 ... dn x 10^exp10
    exact: bool = true, // tail beyond digits[0..n] is exactly zero
};

/// Decimal digit extraction of a positive finite f64 via f128 digit loops (bounds in
/// the module doc).
pub fn decompose(x: f64) Dec {
    var d = Dec{};
    if (x == 0) {
        d.digits[0] = '0';
        d.n = 1;
        d.exp10 = 1;
        return d;
    }
    const w: f128 = x;
    const ip = @trunc(w);
    var frac = w - ip;

    // Integer part, least-significant first, then reversed into place. Both @mod and
    // the shrink-by-10 division are exact while the quotient fits 113 bits.
    var rev: [MAX_DIG]u8 = undefined;
    var k: usize = 0;
    var v = ip;
    while (v >= 1 and k < MAX_DIG) {
        const r = @mod(v, 10);
        rev[k] = '0' + @as(u8, @intFromFloat(r));
        v = (v - r) / 10;
        k += 1;
    }
    for (0..k) |i| d.digits[i] = rev[k - 1 - i];
    d.n = k;
    d.exp10 = @intCast(k);

    if (k == 0) {
        // Pure fraction: skip leading zeros, tracking the decimal exponent.
        while (frac != 0) {
            frac *= 10;
            const digf = @trunc(frac);
            frac -= digf;
            if (digf == 0) {
                d.exp10 -= 1;
                continue;
            }
            d.digits[0] = '0' + @as(u8, @intFromFloat(digf));
            d.n = 1;
            break;
        }
    }
    const frac_cap = @min(d.digits.len, k + MAX_FRAC_SIG);
    while (frac != 0 and d.n < frac_cap) {
        frac *= 10;
        const digf = @trunc(frac);
        frac -= digf;
        d.digits[d.n] = '0' + @as(u8, @intFromFloat(digf));
        d.n += 1;
    }
    d.exact = frac == 0;
    return d;
}

/// Rounds the digit string to `keep` significant digits (glibc semantics: round to
/// nearest by the true value; ties-to-even on exact ties). `keep >= n` is a no-op
/// (implied zero tail). A full carry ("999" -> "100") bumps `exp10`.
pub fn roundAt(d: *Dec, keep: usize) void {
    if (keep >= d.n) return;
    const rd = d.digits[keep];
    var up = false;
    if (rd > '5') {
        up = true;
    } else if (rd == '5') {
        var tail_zero = true;
        for (d.digits[keep + 1 .. d.n]) |c| {
            if (c != '0') {
                tail_zero = false;
                break;
            }
        }
        if (!tail_zero or !d.exact) {
            up = true;
        } else {
            const prev: u8 = if (keep == 0) 0 else d.digits[keep - 1] - '0';
            up = (prev % 2) == 1; // exact tie: round half to even
        }
    }
    d.n = keep;
    if (!up) return;
    var i = keep;
    while (i > 0) {
        i -= 1;
        if (d.digits[i] == '9') {
            d.digits[i] = '0';
        } else {
            d.digits[i] += 1;
            return;
        }
    }
    // Carried all the way out: 0.99..9 x 10^e rounds to 0.10..0 x 10^(e+1).
    d.digits[0] = '1';
    if (d.n == 0) d.n = 1;
    d.exp10 += 1;
}

pub fn sigDigit(d: *const Dec, i: i64) u8 {
    if (i < 0 or i >= @as(i64, @intCast(d.n))) return '0';
    return d.digits[@intCast(i)];
}

/// Emits the unsigned fixed-notation body `intpart[.frac]` (no sign, no padding).
fn emitFixedBody(out: anytype, d: *const Dec, prec: usize, force_point: bool) !void {
    const ilen: usize = if (d.exp10 > 0) @intCast(d.exp10) else 0;
    if (ilen == 0) {
        try out.push('0');
    } else {
        for (0..ilen) |pos| try out.push(sigDigit(d, @intCast(pos)));
    }
    if (prec > 0 or force_point) try out.push('.');
    var p: usize = 1;
    while (p <= prec) : (p += 1) {
        try out.push(sigDigit(d, @as(i64, d.exp10) - 1 + @as(i64, @intCast(p))));
    }
}

fn fixedBodyLen(d: *const Dec, prec: usize, force_point: bool) usize {
    const ilen: usize = if (d.exp10 > 0) @intCast(d.exp10) else 1;
    return ilen + @as(usize, @intFromBool(prec > 0 or force_point)) + prec;
}

fn expDigitsLen(x: i32) usize {
    var v: u32 = @abs(x);
    var n: usize = 0;
    while (v != 0) : (v /= 10) n += 1;
    return @max(n, 2); // C: exponent has at least two digits
}

fn emitExpSuffix(out: anytype, upper: bool, x: i32) !void {
    try out.push(if (upper) 'E' else 'e');
    try out.push(if (x < 0) '-' else '+');
    var buf: [16]u8 = undefined;
    var v: u32 = @abs(x);
    var i: usize = buf.len;
    while (v != 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }
    while (buf.len - i < 2) {
        i -= 1;
        buf[i] = '0';
    }
    try out.extend(buf[i..]);
}

/// Emits the scientific-notation body `d.ddd e+XX` (no sign, no padding).
/// `mant_frac` = digits after the point (already-rounded Dec).
fn emitSciBody(out: anytype, d: *const Dec, mant_frac: usize, force_point: bool, upper: bool) !void {
    try out.push(sigDigit(d, 0));
    if (mant_frac > 0 or force_point) try out.push('.');
    for (0..mant_frac) |j| try out.push(sigDigit(d, @intCast(j + 1)));
    try emitExpSuffix(out, upper, d.exp10 - 1);
}

fn sciBodyLen(d: *const Dec, mant_frac: usize, force_point: bool) usize {
    return 1 + @as(usize, @intFromBool(mant_frac > 0 or force_point)) + mant_frac + 2 + expDigitsLen(d.exp10 - 1);
}

/// Index (exclusive) of the last nonzero digit in `d.digits[from..n]`, i.e. digits
/// beyond the returned count are all '0'. Used by %g's trailing-zero strip.
pub fn lastNonzero(d: *const Dec, upto: usize) usize {
    var m = @min(upto, d.n);
    while (m > 0 and d.digits[m - 1] == '0') m -= 1;
    return m;
}

const FloatKind = enum { fixed, sci };

/// `%f %e %E %g %G` with C99 semantics.
pub fn emitFloat(out: anytype, spec: Spec, x: f64) !void {
    const upper = spec.conv == 'E' or spec.conv == 'G';
    const negative = std.math.signbit(x);
    const prefix: []const u8 = if (negative)
        "-"
    else if (spec.flags.plus)
        "+"
    else if (spec.flags.space)
        " "
    else
        "";

    if (std.math.isNan(x) or std.math.isInf(x)) {
        const body: []const u8 = if (std.math.isNan(x))
            (if (upper) "NAN" else "nan")
        else
            (if (upper) "INF" else "inf");
        // Zero-pad is ignored for non-finite values (C99: pad with spaces).
        const total = prefix.len + body.len;
        const pad = if (spec.width > total) spec.width - total else 0;
        if (!spec.flags.minus) try padOut(out, ' ', pad);
        try out.extend(prefix);
        try out.extend(body);
        if (spec.flags.minus) try padOut(out, ' ', pad);
        return;
    }

    var d = decompose(@abs(x));
    var kind: FloatKind = undefined;
    var prec: usize = undefined; // fixed: frac digits; sci: mantissa frac digits
    var force_point = spec.flags.hash;

    switch (spec.conv) {
        'f' => {
            kind = .fixed;
            prec = spec.precision orelse 6;
            const keep = @as(i64, d.exp10) + @as(i64, @intCast(prec));
            if (keep < 0) {
                d = decompose(0); // rounds to zero
            } else {
                roundAt(&d, @intCast(@min(keep, @as(i64, @intCast(d.n)))));
                if (d.n == 0) d = decompose(0);
            }
        },
        'e', 'E' => {
            kind = .sci;
            prec = spec.precision orelse 6;
            roundAt(&d, prec + 1);
            if (d.n == 0) d = decompose(0);
        },
        'g', 'G' => {
            var p = spec.precision orelse 6;
            if (p == 0) p = 1;
            roundAt(&d, p);
            if (d.n == 0) d = decompose(0);
            const ex = d.exp10 - 1; // %e-style exponent after rounding
            if (ex < -4 or ex >= @as(i64, @intCast(p))) {
                kind = .sci;
                prec = p - 1;
                if (!spec.flags.hash) {
                    // Strip trailing zeros from the mantissa fraction.
                    const nz = lastNonzero(&d, p);
                    prec = if (nz > 1) nz - 1 else 0;
                }
            } else {
                kind = .fixed;
                prec = @intCast(@as(i64, @intCast(p)) - 1 - ex);
                if (!spec.flags.hash) {
                    // Strip trailing fraction zeros: significant digits past the
                    // decimal point run from index max(exp10,0) to p.
                    const int_digits: usize = if (d.exp10 > 0) @intCast(d.exp10) else 0;
                    const nz = lastNonzero(&d, p);
                    prec = if (nz > int_digits) nz - int_digits else 0;
                    // Values < 1 have exp10 <= 0: leading fraction zeros are not
                    // stored as digits but still printed, extend prec accordingly.
                    if (nz > 0 and d.exp10 <= 0 and d.digits[0] != '0') {
                        prec += @intCast(-d.exp10);
                    }
                }
            }
            if (spec.flags.hash) force_point = true;
        },
        else => unreachable,
    }

    const body_len = switch (kind) {
        .fixed => fixedBodyLen(&d, prec, force_point),
        .sci => sciBodyLen(&d, prec, force_point),
    };
    const total = prefix.len + body_len;
    const zero_pad = spec.flags.zero and !spec.flags.minus;
    const pad = if (spec.width > total) spec.width - total else 0;
    if (!spec.flags.minus and !zero_pad) try padOut(out, ' ', pad);
    try out.extend(prefix);
    if (zero_pad) try padOut(out, '0', pad);
    switch (kind) {
        .fixed => try emitFixedBody(out, &d, prec, force_point),
        .sci => try emitSciBody(out, &d, prec, force_point, upper),
    }
    if (spec.flags.minus) try padOut(out, ' ', pad);
}

/// One-shot render into a caller buffer (seq's width probing, tests).
pub fn renderFloat(buf: []u8, spec: Spec, x: f64) error{NoSpaceLeft}![]const u8 {
    var sink = FixedSink{ .buf = buf };
    try emitFloat(&sink, spec, x);
    return sink.slice();
}

pub fn renderInt(buf: []u8, spec: Spec, value: i64) error{NoSpaceLeft}![]const u8 {
    var sink = FixedSink{ .buf = buf };
    try emitInt(&sink, spec, value);
    return sink.slice();
}
