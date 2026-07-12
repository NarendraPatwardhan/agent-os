//! `factor` -- DESIGN.md §1 "factor": NUMBER operands (else stdin,
//! whitespace/tab/NUL split, byte-for-byte port of factor.rs's memchr3_iter loop
//! including its "NUL swallows the next segment" quirk), `-h`/`--exponents` (NOT
//! help -- prints `p^e` instead of repeating `p` e times).
//!
//! Number theory, uniformly in u128 (Zig's native u128, mulmod via a u256
//! intermediate -- `@as(u256,a) * @as(u256,b) % @as(u256,m)` is exact and needs no
//! hand-written Barrett/Montgomery reduction):
//!   - trial division by primes up to 10,000 (computed once per run by a plain
//!     trial-division sieve -- cheap enough at this bound to skip a bitset sieve)
//!   - primality: the 12-prime SPRP base set {2..37} is a PROVEN deterministic
//!     witness set for all of u64 (covers up to ~3.3e24 >> 2^64); u128 extends this
//!     with the next ~29 small primes as EXTRA (non-adversarial-strength, not a
//!     BPSW proof) witnesses -- see DESIGN.md §2 for the scope ruling.
//!   - Pollard's rho with Brent's cycle-batching improvement for splitting
//!     composites (deterministic PRNG seeded from n, so factor's own output is
//!     reproducible run-to-run without touching any entropy source).
//!
//! >u128 (BigUint) inputs: parsed as a plain decimal digit string, trial-divided by
//! the same small-prime list; a cofactor that still doesn't fit u128 afterward
//! reports the oracle's exact `Factorization incomplete. Remainders exists.`
//! wording rather than attempting arbitrary-precision Pollard rho -- verified with
//! `timeout 5` that the oracle itself hangs indefinitely on a 61-digit semiprime of
//! two ~30-digit primes, so there is no finite oracle output to match beyond this
//! bound (DESIGN.md §2 "factor: BigUint factorization is scope-bounded").
//!
//! Invalid-input error: `factor: {quoted} is not a valid positive integer` where
//! `quoted` octal-escapes genuinely-invalid-UTF-8 bytes (NumError's algorithm) and
//! wraps in `'...'` (or `"..."` if the text itself contains a `'`) -- the oracle's
//! own deeper shell-quoting (switching to `$'...'` with `\xHH` escapes around raw
//! control bytes) is NOT replicated (ledgered simplification; only reachable via
//! literal control bytes in stdin input, not plain invalid text).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Allocator = std.mem.Allocator;

const spec = cli.Spec{
    .name = "factor",
    .flags = &.{cli.flagOpt('h', "exponents", "print factors in the form p^e")},
    .help = .{
        .summary = "print the prime factorization of each NUMBER",
        .synopsis = &.{"factor [-h|--exponents] [NUMBER]..."},
        .description =
        \\For each NUMBER, prints a line "NUMBER: p p p ..." listing its prime factors
        \\in ascending order with multiplicity; with -h/--exponents, repeated factors
        \\are collapsed to "p^e" instead of being repeated p times. Factorization works
        \\uniformly in u128 (covering the full u64 range and beyond): trial division by
        \\primes up to 10,000, extended-witness Miller-Rabin primality, then Pollard's
        \\rho with Brent's cycle-batching improvement, seeded deterministically from the
        \\number itself so output never depends on system entropy.
        \\
        \\With no NUMBER operands, factor instead reads whitespace/tab/NUL-delimited
        \\tokens from standard input and factors each one in turn; a NUL delimiter also
        \\suppresses the token that follows it, a quirk inherited byte-for-byte from the
        \\oracle's own stdin-splitting loop. Numbers beyond u128::MAX are trial-divided
        \\by the same small-prime list and handed off to the exact u128 path once the
        \\remaining cofactor fits; if it never fits, factor reports an
        \\incomplete-factorization message instead of attempting arbitrary-precision
        \\factoring (see DEVIATIONS).
        ,
        .operands =
        \\NUMBER... (zero or more): a non-negative decimal integer, optionally with a
        \\leading '+'. With no NUMBER given, factor reads and factors every
        \\whitespace/tab/NUL-separated token from standard input instead. An invalid
        \\token is reported individually and does not stop processing of the remaining
        \\operands or tokens.
        ,
        .exit = &.{
            .{ .code = 0, .when = "every NUMBER (or every stdin token) was a valid non-negative integer and was fully factored" },
            .{ .code = 1, .when = "a usage error, an invalid (non-integer) NUMBER/token, a >u128 number whose cofactor could not be reduced to u128 by small-prime trial division (\"Factorization incomplete. Remainders exists.\"), or a standard-input read error" },
        },
        .deviations = &.{
            "Invalid-input error text quotes the offending token with a simplified single/double-quote wrap ('text', or \"text\" if text itself contains a '); GNU's fuller shell-quoting (switching to $'...' ANSI-C quoting with \\xHH hex escapes for embedded control bytes) is not replicated -- only observable when a token mixes invalid-UTF-8 bytes with valid-but-control bytes in the same token.",
            "Numbers beyond u128::MAX (340282366920938463463374607431768211455) are trial-divided by primes up to 10,000 and handed to the exact u128 path once the cofactor fits; a cofactor still >u128::MAX is reported as \"Factorization incomplete. Remainders exists.\" rather than attempted via arbitrary-precision Pollard rho -- GNU factor instead keeps attempting its own bignum factoring, which for a hard large semiprime can run effectively forever in practice, so this port's bounded-and-diagnosed behavior is a deliberate, practical scope cut rather than a faithful full replication.",
            "Primality above u64 (up to u128::MAX) relies on Miller-Rabin extended with 41 fixed small-prime witnesses rather than a full BPSW proof; this is not an adversarial-strength determinism guarantee, though every value checked during development (including u128::MAX) matched the reference implementation.",
            "Generic usage/parse errors (an unrecognized option, or -h/--exponents given a value it doesn't take) print a single diagnostic line and exit 1; GNU's second line (\"Try '--help' for more information.\") is not reproduced.",
        },
        .examples = &.{
            .{ .cmd = "factor 42 90", .note = "prints \"42: 2 3 7\" then \"90: 2 3 3 5\" -- ascending order, with multiplicity" },
            .{ .cmd = "factor -h 90", .note = "prints \"90: 2 3^2 5\" -- -h means --exponents here, not help" },
            .{ .cmd = "factor 1000000000000000000000000098844000000000000000000000005630859", .note = "exceeds u128::MAX and never reduces to a u128 cofactor; exits 1 with \"factor: Factorization incomplete. Remainders exists.\" (GNU factor would instead keep attempting bignum factoring, impractically slow for a number this large)" },
        },
    },
    .positionals = .{ .name = "NUMBER", .min = 0, .max = null },
};

// ============================================================================ number theory (u128)

fn gcd128(a_in: u128, b_in: u128) u128 {
    var a = a_in;
    var b = b_in;
    while (b != 0) {
        const t = b;
        b = a % b;
        a = t;
    }
    return a;
}

/// Exact `a*b mod m` via a u256 intermediate -- correct for the full u128 range
/// (max product just fits u256, no overflow).
fn mulmod128(a: u128, b: u128, m: u128) u128 {
    const full: u256 = @as(u256, a) * @as(u256, b);
    return @intCast(full % @as(u256, m));
}

fn addmod128(a: u128, b: u128, m: u128) u128 {
    const full: u256 = @as(u256, a) + @as(u256, b);
    return @intCast(full % @as(u256, m));
}

fn absDiff128(a: u128, b: u128) u128 {
    return if (a > b) a - b else b - a;
}

fn powmod128(base_in: u128, exp_in: u128, m: u128) u128 {
    if (m == 1) return 0;
    var result: u128 = 1;
    var base = base_in % m;
    var exp = exp_in;
    while (exp > 0) {
        if (exp & 1 == 1) result = mulmod128(result, base, m);
        exp >>= 1;
        if (exp > 0) base = mulmod128(base, base, m);
    }
    return result;
}

/// Trial-division-generated ascending prime list up to `limit` (inclusive), written
/// into `buf`. `limit=10_000` yields 1229 primes -- microseconds at runtime, so a
/// bitset sieve isn't worth the code.
fn smallPrimesUpTo(buf: []u32, limit: u32) []const u32 {
    var n: usize = 0;
    var candidate: u32 = 2;
    while (candidate <= limit and n < buf.len) : (candidate += 1) {
        var is_p = true;
        for (buf[0..n]) |p| {
            if (@as(u64, p) * @as(u64, p) > candidate) break;
            if (candidate % p == 0) {
                is_p = false;
                break;
            }
        }
        if (is_p) {
            buf[n] = candidate;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Deterministic-for-u64 (12 witnesses) extended with more small-prime witnesses
/// for u128 (module doc: not a BPSW proof, an empirically-verified-against-the-
/// oracle scope decision). `primes` is the full small-prime list; only the first
/// ~41 are used as MR witnesses (the rest of the list is for trial division only).
fn isPrime(n: u128, primes: []const u32) bool {
    if (n < 2) return false;
    for (primes) |p32| {
        const p: u128 = p32;
        if (n == p) return true;
        if (n % p == 0) return false;
        if (p * p > n) break;
    }
    // n survived trial division by every small prime it's big enough to need;
    // fall through to extended Miller-Rabin.
    var d = n - 1;
    var r: u32 = 0;
    while (d % 2 == 0) {
        d /= 2;
        r += 1;
    }
    const nwit = @min(@as(usize, 41), primes.len);
    witness_loop: for (primes[0..nwit]) |w32| {
        const a = @as(u128, w32) % n;
        if (a < 2) continue; // a==0 would wrongly signal composite; a==1 is a no-op
        var x = powmod128(a, d, n);
        if (x == 1 or x == n - 1) continue;
        var i: u32 = 1;
        while (i < r) : (i += 1) {
            x = mulmod128(x, x, n);
            if (x == n - 1) continue :witness_loop;
        }
        return false;
    }
    return true;
}

fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// Pollard's rho with Brent's improvement. `n` must be odd, composite, and > 1.
/// The PRNG is seeded deterministically from `seed` (itself derived from `n`), so
/// factor's own output never depends on system entropy.
fn pollardBrent(n: u128, seed: *u64) u128 {
    if (n % 2 == 0) return 2;
    while (true) {
        const c: u128 = 1 + @as(u128, splitmix64(seed)) % (n - 1);
        var y: u128 = 1 + @as(u128, splitmix64(seed)) % (n - 1);
        const m: u128 = 128;
        var g: u128 = 1;
        var r: u128 = 1;
        var q: u128 = 1;
        var x: u128 = y;
        var ys: u128 = y;
        while (g == 1) {
            x = y;
            var i: u128 = 0;
            while (i < r) : (i += 1) y = addmod128(mulmod128(y, y, n), c, n);
            var k: u128 = 0;
            while (k < r and g == 1) {
                ys = y;
                const lim = @min(m, r - k);
                var j: u128 = 0;
                while (j < lim) : (j += 1) {
                    y = addmod128(mulmod128(y, y, n), c, n);
                    q = mulmod128(q, absDiff128(x, y), n);
                }
                g = gcd128(q, n);
                k += m;
            }
            r *= 2;
        }
        if (g == n) {
            g = 1;
            while (g == 1) {
                ys = addmod128(mulmod128(ys, ys, n), c, n);
                g = gcd128(absDiff128(x, ys), n);
            }
        }
        if (g != n) return g;
        // total failure for this (c, y0): retry with a fresh draw.
    }
}

const Factor = struct { p: u128, e: u32 };

fn addFactor(gpa: Allocator, out: *std.ArrayListUnmanaged(Factor), p: u128, e: u32) void {
    for (out.items) |*f| {
        if (f.p == p) {
            f.e += e;
            return;
        }
    }
    out.append(gpa, .{ .p = p, .e = e }) catch @panic("OOM");
}

fn factorLessThan(_: void, a: Factor, b: Factor) bool {
    return a.p < b.p;
}

fn factorRec(gpa: Allocator, n: u128, seed: *u64, primes: []const u32, out: *std.ArrayListUnmanaged(Factor)) void {
    if (n == 1) return;
    if (isPrime(n, primes)) {
        addFactor(gpa, out, n, 1);
        return;
    }
    var d: u128 = n;
    while (d == n) d = pollardBrent(n, seed);
    factorRec(gpa, d, seed, primes, out);
    factorRec(gpa, n / d, seed, primes, out);
}

/// Full factorization of `n` (0 and 1 yield an empty factor list, matching the
/// oracle's `0:`/`1:` bare output).
fn factorizeU128(gpa: Allocator, n_in: u128, primes: []const u32, out: *std.ArrayListUnmanaged(Factor)) void {
    var n = n_in;
    if (n <= 1) return;
    for (primes) |p32| {
        const p: u128 = p32;
        if (p * p > n) break;
        var e: u32 = 0;
        while (n % p == 0) {
            n /= p;
            e += 1;
        }
        if (e > 0) addFactor(gpa, out, p, e);
    }
    if (n == 1) return;
    var seed: u64 = @as(u64, @truncate(n)) ^ @as(u64, @truncate(n >> 64)) ^ 0xD1B54A32D192ED03;
    factorRec(gpa, n, &seed, primes, out);
}

// ============================================================================ BigUint (>u128) tail

const U128_MAX_DIGITS = "340282366920938463463374607431768211455";

/// Strips leading zeros (keeps a single "0").
fn bigTrim(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < s.len and s[i] == '0') i += 1;
    return s[i..];
}

fn bigFitsU128(digits: []const u8) bool {
    if (digits.len < U128_MAX_DIGITS.len) return true;
    if (digits.len > U128_MAX_DIGITS.len) return false;
    return std.mem.order(u8, digits, U128_MAX_DIGITS) != .gt;
}

fn bigToU128(digits: []const u8) u128 {
    var v: u128 = 0;
    for (digits) |c| v = v * 10 + (c - '0');
    return v;
}

/// Big-decimal / small-uint long division; `quot_buf` must be >= `digits.len`.
/// Returns the trimmed quotient (a view into `quot_buf`) and the remainder.
fn bigDivModSmall(digits: []const u8, divisor: u32, quot_buf: []u8) struct { quot: []const u8, rem: u32 } {
    var rem: u64 = 0;
    for (digits, 0..) |ch, i| {
        const cur = rem * 10 + (ch - '0');
        quot_buf[i] = @intCast('0' + cur / divisor);
        rem = cur % divisor;
    }
    return .{ .quot = bigTrim(quot_buf[0..digits.len]), .rem = @intCast(rem) };
}

const BigStatus = enum { ok, incomplete };

/// `digits` must already be leading-zero-trimmed, non-"0"/"1", and confirmed to
/// exceed u128::MAX (the caller routes smaller values through `factorizeU128`).
fn factorizeBig(gpa: Allocator, digits_in: []const u8, primes: []const u32, out: *std.ArrayListUnmanaged(Factor)) BigStatus {
    var digits = digits_in;
    const quot_buf = gpa.alloc(u8, digits.len) catch @panic("OOM");
    for (primes) |p| {
        var e: u32 = 0;
        while (true) {
            const r = bigDivModSmall(digits, p, quot_buf);
            if (r.rem != 0) break;
            digits = gpa.dupe(u8, r.quot) catch @panic("OOM");
            e += 1;
        }
        if (e > 0) addFactor(gpa, out, p, e);
        if (std.mem.eql(u8, digits, "1")) return .ok;
    }
    if (bigFitsU128(digits)) {
        const n = bigToU128(digits);
        var seed: u64 = @as(u64, @truncate(n)) ^ @as(u64, @truncate(n >> 64)) ^ 0xD1B54A32D192ED03;
        factorRec(gpa, n, &seed, primes, out);
        return .ok;
    }
    return .incomplete;
}

// ============================================================================ invalid-input quoting

/// Byte length of the valid UTF-8 sequence starting at `s[0]`, or 0 if `s[0]`
/// doesn't start one (either an invalid lead byte, a truncated sequence at the end
/// of `s`, or bad continuation bytes) -- deliberately collapses any invalid
/// sequence to exactly one byte, matching the common (isolated stray byte) case the
/// oracle's own octal-escaping exercises; a "valid lead byte but truncated/garbled
/// multi-byte tail" is treated the same way (byte-at-a-time), a documented
/// simplification vs Rust's `Utf8Chunks` maximal-subpart algorithm.
fn validUtf8Len(s: []const u8) usize {
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (len > s.len) return 0;
    _ = std.unicode.utf8Decode(s[0..len]) catch return 0;
    return len;
}

fn appendNumErrorEscaped(list: *std.ArrayListUnmanaged(u8), gpa: Allocator, raw: []const u8) void {
    var i: usize = 0;
    while (i < raw.len) {
        const n = validUtf8Len(raw[i..]);
        if (n > 0) {
            list.appendSlice(gpa, raw[i .. i + n]) catch @panic("OOM");
            i += n;
        } else {
            var obuf: [4]u8 = .{ '\\', '0', '0', '0' };
            const b = raw[i];
            obuf[3] = '0' + (b & 7);
            obuf[2] = '0' + ((b >> 3) & 7);
            obuf[1] = '0' + ((b >> 6) & 7);
            list.appendSlice(gpa, &obuf) catch @panic("OOM");
            i += 1;
        }
    }
}

/// `factor: {quoted} is not a valid positive integer` quoting: NumError's octal
/// escape for invalid UTF-8 bytes, then wrapped in `'...'` (or `"..."` if the
/// escaped text itself contains a `'`) -- see module doc for the scope cut vs the
/// oracle's fuller shell-quoting.
fn quoteForError(gpa: Allocator, raw: []const u8) []const u8 {
    var escaped: std.ArrayListUnmanaged(u8) = .empty;
    appendNumErrorEscaped(&escaped, gpa, raw);
    const has_squote = std.mem.indexOfScalar(u8, escaped.items, '\'') != null;
    const qc: u8 = if (has_squote) '"' else '\'';
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(gpa, qc) catch @panic("OOM");
    out.appendSlice(gpa, escaped.items) catch @panic("OOM");
    out.append(gpa, qc) catch @panic("OOM");
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

// ============================================================================ number token parsing

const ParsedNum = union(enum) {
    invalid,
    small: u128, // fits in u128 (covers the whole u64 range too)
    big: []const u8, // trimmed decimal digits, confirmed > u128::MAX
};

fn parseNumber(gpa: Allocator, s_in: []const u8) ParsedNum {
    var s = s_in;
    if (s.len > 0 and s[0] == '+') s = s[1..];
    if (s.len == 0) return .invalid;
    for (s) |c| {
        if (c < '0' or c > '9') return .invalid;
    }
    const digits = bigTrim(s);
    if (bigFitsU128(digits)) return .{ .small = bigToU128(digits) };
    return .{ .big = gpa.dupe(u8, digits) catch @panic("OOM") };
}

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r\x0b\x0c");
}

// ============================================================================ output

fn writeResult(out: *textio.BufOut, num_str: []const u8, factors: []const Factor, exponents: bool) void {
    out.extend(num_str) catch return;
    out.push(':') catch return;
    for (factors) |f| {
        var pbuf: [40]u8 = undefined;
        const pstr = std.fmt.bufPrint(&pbuf, "{d}", .{f.p}) catch unreachable;
        if (exponents) {
            out.push(' ') catch return;
            out.extend(pstr) catch return;
            if (f.e > 1) {
                out.push('^') catch return;
                var ebuf: [12]u8 = undefined;
                const estr = std.fmt.bufPrint(&ebuf, "{d}", .{f.e}) catch unreachable;
                out.extend(estr) catch return;
            }
        } else {
            var k: u32 = 0;
            while (k < f.e) : (k += 1) {
                out.push(' ') catch return;
                out.extend(pstr) catch return;
            }
        }
    }
    out.push('\n') catch return;
}

fn processToken(ctx: *Ctx, out: *textio.BufOut, tok: []const u8, exponents: bool, primes: []const u32, rc: *u8) void {
    switch (parseNumber(ctx.gpa, tok)) {
        .invalid => {
            const q = quoteForError(ctx.gpa, tok);
            ctx.errPrint("factor: {s} is not a valid positive integer\n", .{q});
            rc.* = 1;
        },
        .small => |n| {
            var factors: std.ArrayListUnmanaged(Factor) = .empty;
            factorizeU128(ctx.gpa, n, primes, &factors);
            std.mem.sort(Factor, factors.items, {}, factorLessThan);
            var numbuf: [40]u8 = undefined;
            const numstr = std.fmt.bufPrint(&numbuf, "{d}", .{n}) catch unreachable;
            writeResult(out, numstr, factors.items, exponents);
        },
        .big => |digits| {
            var factors: std.ArrayListUnmanaged(Factor) = .empty;
            switch (factorizeBig(ctx.gpa, digits, primes, &factors)) {
                .ok => {
                    std.mem.sort(Factor, factors.items, {}, factorLessThan);
                    writeResult(out, digits, factors.items, exponents);
                },
                .incomplete => {
                    ctx.errPrint("factor: Factorization incomplete. Remainders exists.\n", .{});
                    rc.* = 1;
                },
            }
        },
    }
}

/// Faithful port of factor.rs's stdin loop: scans space/tab/NUL delimiter positions
/// (plus a line-end sentinel); a NUL delimiter suppresses display of the FOLLOWING
/// segment (mimicking a NUL-terminated-string read), matching the oracle exactly.
fn processLine(ctx: *Ctx, out: *textio.BufOut, line: []const u8, exponents: bool, primes: []const u32, rc: *u8) void {
    var display = true;
    var prev: usize = 0;
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        const at_end = i == line.len;
        const is_delim = !at_end and (line[i] == ' ' or line[i] == '\t' or line[i] == 0);
        if (at_end or is_delim) {
            const has_null = !at_end and line[i] == 0;
            if (display and (prev != i or has_null)) {
                processToken(ctx, out, line[prev..i], exponents, primes, rc);
            }
            display = !has_null;
            prev = i + 1;
        }
    }
}

fn processStdin(ctx: *Ctx, out: *textio.BufOut, data: []const u8, exponents: bool, primes: []const u32, rc: *u8) void {
    var line_start: usize = 0;
    while (line_start < data.len) {
        const maybe_nl = std.mem.indexOfScalarPos(u8, data, line_start, '\n');
        const line_end = maybe_nl orelse data.len;
        processLine(ctx, out, data[line_start..line_end], exponents, primes, rc);
        if (maybe_nl == null) break;
        line_start = line_end + 1;
    }
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        // uutils-family ruling (DESIGN.md §2): clap parse errors exit 1, not
        // cli.zig's generic 2.
        .exit => |c| return if (c == 2) 1 else c,
        .ok => |mm| mm,
    };
    const exponents = m.has("exponents");

    var prime_buf: [1300]u32 = undefined;
    const primes = smallPrimesUpTo(&prime_buf, 10_000);

    var out = textio.BufOut.init(ctx.stdout);
    var rc: u8 = 0;

    const positionals = m.positionalSlice();
    if (positionals.len > 0) {
        for (positionals) |raw| {
            processToken(ctx, &out, trimAscii(raw), exponents, primes, &rc);
        }
    } else {
        const data = textio.readAll(ctx.gpa, ctx.stdin) catch |e| {
            out.finish() catch {};
            ctx.errPrint("factor: error reading input: {s}\n", .{sys.strerror(sys.toErrno(e))});
            return 1;
        };
        processStdin(ctx, &out, data, exponents, primes, &rc);
    }

    out.finish() catch {};
    return rc;
}
