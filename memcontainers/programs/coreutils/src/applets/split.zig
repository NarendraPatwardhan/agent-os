//! `split` -- DESIGN.md §1: create output files containing consecutive
//! or interleaved sections of input. Four chunking strategies (mutually exclusive):
//!   * `-l N`/`--lines`      N lines per file (default 1000)
//!   * `-b SIZE`/`--bytes`   SIZE bytes per file (K/M/G... suffixes, 1024 vs 1000 bases)
//!   * `-C SIZE`/`--line-bytes`  at most SIZE bytes of whole lines per file
//!   * `-n CHUNKS`/`--number`   N | K/N | l/N | l/K/N | r/N | r/K/N (K/N forms -> stdout)
//! Suffix odometer: default alphabetic base-26 dynamic-width (aa,ab,...,az,ba,...,yz,zaaa),
//! `-d`/`--numeric-suffixes[=FROM]` decimal, `-x`/`--hex-suffixes[=FROM]` hex; `-a N` fixes
//! the width (disables auto-widen -> `output file suffixes exhausted` when overflowed).
//! `--additional-suffix`, `--verbose` ("creating file 'NAME'" to STDOUT), `-e/--elide-empty-files`,
//! `-t/--separator` (record separator, `\0` = NUL), obsolete leading `-NUMBER` (== `-l NUMBER`),
//! `--filter=CMD` (pipe each chunk to `sh -c CMD` with the chunk file name in `$FILE`).
//!
//! Divergences from the uutils 0.9.0 oracle (see final ledger notes): `--verbose` prints to
//! STDOUT (uutils uses println!, i.e. stdout -- the M7c brief's "stderr" claim was wrong);
//! CLI-parse-level errors exit 1 with a single `split: <msg>` line (clap prose not reproduced);
//! `-n l/0`/`-n r/0` (uutils panics/divide-by-zero) are handled as no-op success here;
//! `--filter` routes `$FILE` via shell-variable injection + a temp-file stdin (nutils `sys.spawn`
//! has no per-child env or pipe primitive); would-overwrite-input detection is path-based
//! (`fsutil.canonicalize`) not device/inode-based; infinite-stdin `-n` size detection is not
//! reproduced (whole input is buffered).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const proc = @import("../core/proc.zig");
const envfs = @import("../core/envfs.zig");
const fsutil = @import("../core/fsutil.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Allocator = std.mem.Allocator;

const help_doc = cli.Help{
    .summary = "split a file into pieces",
    .synopsis = &.{"split [OPTION]... [INPUT [PREFIX]]"},
    .description =
    \\Splits INPUT (default standard input) into files named PREFIX followed by
    \\a generated suffix (default PREFIX "x", suffixes "aa", "ab", ...). Exactly
    \\one chunking strategy applies: -l/--lines (N lines per file, default
    \\1000), -b/--bytes SIZE (SIZE bytes per file), -C/--line-bytes SIZE (at
    \\most SIZE bytes of whole lines per file), or -n/--number CHUNKS. CHUNKS
    \\may be N (N files of nearly-equal size), K/N (write only the Kth chunk,
    \\to standard output), l/N or l/K/N (line-based), or r/N or r/K/N
    \\(round-robin by line). SIZE accepts K/M/G/... suffixes (powers of 1024)
    \\and KB/MB/... (powers of 1000).
    \\
    \\The suffix is alphabetic (base-26, dynamically widened) by default; -d/
    \\--numeric-suffixes and -x/--hex-suffixes switch to decimal or hex, each
    \\optionally starting from a given value; -a fixes the suffix width instead
    \\of widening it. --filter=CMD pipes each chunk through "sh -c CMD" (with
    \\the chunk's file name in $FILE) instead of writing a file.
    ,
    .options = &.{
        .{ .flags = "-l, --lines=N", .desc = "put N lines per output file (default 1000)" },
        .{ .flags = "-b, --bytes=SIZE", .desc = "put SIZE bytes per output file" },
        .{ .flags = "-C, --line-bytes=SIZE", .desc = "put at most SIZE bytes of whole lines per file" },
        .{ .flags = "-n, --number=CHUNKS", .desc = "generate CHUNKS files (N, K/N, l/N, l/K/N, r/N, r/K/N)" },
        .{ .flags = "-a, --suffix-length=N", .desc = "use suffixes of length N (default 2; auto-widens unless given)" },
        .{ .flags = "-d, --numeric-suffixes[=FROM]", .desc = "use decimal suffixes, optionally starting at FROM" },
        .{ .flags = "-x, --hex-suffixes[=FROM]", .desc = "use hexadecimal suffixes, optionally starting at FROM" },
        .{ .flags = "--additional-suffix=SUFFIX", .desc = "append an additional literal SUFFIX to file names" },
        .{ .flags = "-e, --elide-empty-files", .desc = "do not produce empty output files" },
        .{ .flags = "--verbose", .desc = "print a line to standard output before each file is created" },
        .{ .flags = "-t, --separator=SEP", .desc = "use SEP instead of newline as the record separator" },
        .{ .flags = "--filter=CMD", .desc = "pipe each chunk through the shell command CMD (with $FILE set)" },
    },
    .operands = "INPUT the file to split; '-' or omitted means standard input. PREFIX the output filename prefix (default 'x').",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "any error: a bad option value, INPUT could not be read, an output file could not be written, output would overwrite INPUT, or suffixes were exhausted" },
    },
    .deviations_from = "GNU coreutils split",
    .deviations = &.{
        "A parse error exits with a single 'split: <message>' line; GNU's longer 'Try split --help for more information' usage hint is not printed.",
        "-n l/0 and -n r/0 are treated as a successful no-op that writes nothing, rather than being rejected as an invalid chunk count.",
        "Detection of an output file that would silently overwrite INPUT compares canonicalized paths, not device/inode identity, so a different path to the same file (e.g. via a symlink) may not be caught.",
    },
    .examples = &.{
        .{ .cmd = "split -l 500 access.log", .note = "500-line chunks named xaa, xab, ..." },
        .{ .cmd = "split -b 10M big.iso part_ -d", .note = "10MiB chunks named part_00, part_01, ..." },
        .{ .cmd = "split -n 4 data.csv", .note = "4 nearly-equal byte chunks" },
    },
    .see_also = "csplit (content-driven splitting); cat reassembles the pieces (cat xa* > whole).",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn startsWith(a: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, a, p);
}
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

// ============================================================================ size parsing
// Port of the relevant subset of uucore::parser::parse_size (default Parser: no allow_list,
// no default_unit, no b_byte_count, no_empty_numeric = false, capital_b_bytes = false).

const SizeErr = enum { parse_failure, invalid_suffix, too_big };
const SizeU128 = union(enum) { ok: u128, err: SizeErr };

const NumSys = enum { decimal, octal, hex, binary };

fn determineNumberSystem(s: []const u8) NumSys {
    if (s.len <= 1) return .decimal;
    if (startsWith(s, "0x")) return .hex;
    if (startsWith(s, "0b") and s.len > 2) return .binary;
    var num_digits: usize = 0;
    while (num_digits < s.len and isDigit(s[num_digits])) num_digits += 1;
    var all_zeros = true;
    for (s) |c| {
        if (c != '0') {
            all_zeros = false;
            break;
        }
    }
    if (s[0] == '0' and num_digits > 1 and !all_zeros) return .octal;
    return .decimal;
}

fn parseRadixChecked(s: []const u8, radix: u8) SizeU128 {
    if (s.len == 0) return .{ .err = .parse_failure };
    var v: u128 = 0;
    for (s) |c| {
        const d: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return .{ .err = .parse_failure },
        };
        if (d >= radix) return .{ .err = .parse_failure };
        v = std.math.mul(u128, v, radix) catch return .{ .err = .too_big };
        v = std.math.add(u128, v, d) catch return .{ .err = .too_big };
    }
    return .{ .ok = v };
}

fn parseSizeU128(size: []const u8) SizeU128 {
    if (size.len == 0) return .{ .err = .parse_failure };
    const ns = determineNumberSystem(size);

    // Split into numeric string and unit.
    var numeric_len: usize = 0;
    switch (ns) {
        .hex => {
            numeric_len = 2; // "0x"
            while (numeric_len < size.len and isHexDigit(size[numeric_len])) numeric_len += 1;
        },
        .binary => {
            numeric_len = 2; // "0b"
            while (numeric_len < size.len and (size[numeric_len] == '0' or size[numeric_len] == '1')) numeric_len += 1;
        },
        else => {
            while (numeric_len < size.len and isDigit(size[numeric_len])) numeric_len += 1;
        },
    }
    const numeric = size[0..numeric_len];
    const unit = size[numeric_len..];

    const Factor = struct { base: u128, exp: u32 };
    const f: Factor = blk: {
        if (unit.len == 0) break :blk .{ .base = 1, .exp = 0 };
        if (eq(unit, "b")) break :blk .{ .base = 512, .exp = 1 };
        const iec = [_][]const u8{ "K", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q" };
        // powers-of-1024 forms: X | Xi B | (lower) ...
        inline for (iec, 1..) |ltr, exp| {
            const up = ltr[0];
            const lo = up | 0x20;
            if (unit.len == 1 and (unit[0] == up or unit[0] == lo)) break :blk .{ .base = 1024, .exp = @intCast(exp) };
            if (unit.len == 3 and (unit[0] == up or unit[0] == lo) and unit[1] == 'i' and unit[2] == 'B') break :blk .{ .base = 1024, .exp = @intCast(exp) };
            // powers-of-1000: XB | Xb | XD | xd (second char B or D, any case of first)
            if (unit.len == 2 and (unit[0] == up or unit[0] == lo) and (unit[1] == 'B' or unit[1] == 'b' or unit[1] == 'D' or unit[1] == 'd')) break :blk .{ .base = 1000, .exp = @intCast(exp) };
        }
        // unknown unit
        if (numeric.len == 0) return .{ .err = .parse_failure };
        return .{ .err = .invalid_suffix };
    };
    var factor: u128 = 1;
    {
        var i: u32 = 0;
        while (i < f.exp) : (i += 1) {
            factor = std.math.mul(u128, factor, f.base) catch return .{ .err = .too_big };
        }
    }

    const number: u128 = switch (ns) {
        .decimal => if (numeric.len == 0) 1 else switch (parseRadixChecked(numeric, 10)) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        },
        .octal => blk: {
            var t = numeric;
            while (t.len > 0 and t[0] == '0') t = t[1..];
            break :blk switch (parseRadixChecked(t, 8)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
        },
        .hex => blk: {
            const t = if (numeric.len >= 2) numeric[2..] else numeric;
            break :blk switch (parseRadixChecked(t, 16)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
        },
        .binary => blk: {
            const t = if (numeric.len >= 2) numeric[2..] else numeric;
            break :blk switch (parseRadixChecked(t, 2)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
        },
    };

    const prod = std.math.mul(u128, number, factor) catch return .{ .err = .too_big };
    return .{ .ok = prod };
}

const U64Max = std.math.maxInt(u64);

/// parse_size_u64: overflow (>u64) or u128 overflow -> too_big.
fn parseSizeU64(size: []const u8) ?u64 {
    switch (parseSizeU128(size)) {
        .ok => |v| return if (v > U64Max) null else @intCast(v),
        .err => return null,
    }
}

const U64Result = union(enum) { ok: u64, err: SizeErr };

/// parse_size_u64_max: like parse_size_u64 but clamps too-big to u64::MAX.
fn parseSizeU64Max(size: []const u8) U64Result {
    switch (parseSizeU128(size)) {
        .ok => |v| return .{ .ok = if (v > U64Max) U64Max else @intCast(v) },
        .err => |e| return if (e == .too_big) .{ .ok = U64Max } else .{ .err = e },
    }
}

// ============================================================================ number types

const Kth = struct { k: u64, n: u64 };

const NumberType = union(enum) {
    bytes: u64,
    kth_bytes: Kth,
    lines: u64,
    kth_lines: Kth,
    round_robin: u64,
    kth_round_robin: Kth,

    fn numChunks(self: NumberType) u64 {
        return switch (self) {
            .bytes => |n| n,
            .kth_bytes => |x| x.n,
            .lines => |n| n,
            .kth_lines => |x| x.n,
            .round_robin => |n| n,
            .kth_round_robin => |x| x.n,
        };
    }
};

const NumberErr = union(enum) {
    /// invalid number of chunks: '<s>'
    num_chunks: []const u8,
    /// invalid chunk number: '<s>'
    chunk_number: []const u8,
};

const NumberParse = union(enum) { ok: NumberType, err: NumberErr };

fn splitSlash(s: []const u8, parts: *[4][]const u8) usize {
    // up to 4 parts (splitn(4,'/')): the 4th part keeps any remaining slashes.
    var n: usize = 0;
    var rest = s;
    while (n < 3) {
        if (std.mem.indexOfScalar(u8, rest, '/')) |p| {
            parts[n] = rest[0..p];
            rest = rest[p + 1 ..];
            n += 1;
        } else break;
    }
    parts[n] = rest;
    n += 1;
    return n;
}

fn isInvalidChunk(k: u64, n: u64) bool {
    return k > n or k == 0;
}

fn parseNumberType(s: []const u8) NumberParse {
    var parts: [4][]const u8 = undefined;
    const np = splitSlash(s, &parts);
    if (np == 1) {
        const num = parseSizeU64(parts[0]) orelse return .{ .err = .{ .num_chunks = parts[0] } };
        if (num > 0) return .{ .ok = .{ .bytes = num } };
        return .{ .err = .{ .num_chunks = s } };
    }
    if (np == 2) {
        const a = parts[0];
        const b = parts[1];
        if (eq(a, "l")) {
            const num = parseSizeU64(b) orelse return .{ .err = .{ .num_chunks = b } };
            return .{ .ok = .{ .lines = num } };
        }
        if (eq(a, "r")) {
            const num = parseSizeU64(b) orelse return .{ .err = .{ .num_chunks = b } };
            return .{ .ok = .{ .round_robin = num } };
        }
        if (a.len > 0 and (a[0] == 'l' or a[0] == 'r')) {
            // starts with l/r but is not exactly "l"/"r" -> falls through to the catch-all
            return .{ .err = .{ .num_chunks = s } };
        }
        // K/N bytes
        const num = parseSizeU64(b) orelse return .{ .err = .{ .num_chunks = b } };
        const k = parseSizeU64(a) orelse return .{ .err = .{ .chunk_number = a } };
        if (isInvalidChunk(k, num)) return .{ .err = .{ .chunk_number = a } };
        return .{ .ok = .{ .kth_bytes = .{ .k = k, .n = num } } };
    }
    if (np == 3) {
        const a = parts[0];
        const kk = parts[1];
        const nn = parts[2];
        if (eq(a, "l")) {
            const num = parseSizeU64(nn) orelse return .{ .err = .{ .num_chunks = nn } };
            const k = parseSizeU64(kk) orelse return .{ .err = .{ .chunk_number = kk } };
            if (isInvalidChunk(k, num)) return .{ .err = .{ .chunk_number = kk } };
            return .{ .ok = .{ .kth_lines = .{ .k = k, .n = num } } };
        }
        if (eq(a, "r")) {
            const num = parseSizeU64(nn) orelse return .{ .err = .{ .num_chunks = nn } };
            const k = parseSizeU64(kk) orelse return .{ .err = .{ .chunk_number = kk } };
            if (isInvalidChunk(k, num)) return .{ .err = .{ .chunk_number = kk } };
            return .{ .ok = .{ .kth_round_robin = .{ .k = k, .n = num } } };
        }
        return .{ .err = .{ .num_chunks = s } };
    }
    return .{ .err = .{ .num_chunks = s } };
}

// ============================================================================ strategy

const Strategy = union(enum) {
    lines: u64,
    bytes: u64,
    line_bytes: u64,
    number: NumberType,
};

// ============================================================================ filename odometer

fn mapDigit(radix: u8, d: u8) u8 {
    return switch (radix) {
        10 => '0' + d,
        16 => if (d < 10) '0' + d else 'a' + (d - 10),
        26 => 'a' + d,
        else => 0,
    };
}

const NameGen = struct {
    gpa: Allocator,
    prefix: []const u8,
    additional: []const u8,
    radix: u8,
    dynamic: bool,
    digits: []u8, // fixed-width only
    current: usize, // dynamic-width only
    first: bool,
    exhausted: bool,

    fn init(
        gpa: Allocator,
        prefix: []const u8,
        additional: []const u8,
        radix: u8,
        dynamic: bool,
        width: usize,
        start: usize,
    ) error{StartTooLarge}!NameGen {
        if (dynamic) {
            return .{
                .gpa = gpa,
                .prefix = prefix,
                .additional = additional,
                .radix = radix,
                .dynamic = true,
                .digits = &.{},
                .current = start,
                .first = true,
                .exhausted = false,
            };
        }
        const digits = gpa.alloc(u8, width) catch @panic("OOM");
        @memset(digits, 0);
        var s = start;
        var i = width;
        while (i > 0) {
            i -= 1;
            digits[i] = @intCast(s % radix);
            s /= radix;
            if (s == 0) break;
        }
        if (s != 0) return error.StartTooLarge;
        return .{
            .gpa = gpa,
            .prefix = prefix,
            .additional = additional,
            .radix = radix,
            .dynamic = false,
            .digits = digits,
            .current = 0,
            .first = true,
            .exhausted = false,
        };
    }

    fn increment(self: *NameGen) bool {
        if (self.dynamic) {
            self.current += 1;
            return true;
        }
        var i = self.digits.len;
        while (i > 0) {
            i -= 1;
            self.digits[i] += 1;
            if (self.digits[i] == self.radix) {
                self.digits[i] = 0;
            } else break;
        }
        for (self.digits) |d| {
            if (d != 0) return true;
        }
        return false; // all zero => overflow
    }

    fn next(self: *NameGen) ?[]const u8 {
        if (self.exhausted) return null;
        if (self.first) {
            self.first = false;
        } else if (!self.increment()) {
            self.exhausted = true;
            return null;
        }
        return self.render();
    }

    fn render(self: *NameGen) []const u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        list.appendSlice(self.gpa, self.prefix) catch @panic("OOM");
        if (self.dynamic) {
            self.renderDynamic(&list);
        } else {
            for (self.digits) |d| list.append(self.gpa, mapDigit(self.radix, d)) catch @panic("OOM");
        }
        list.appendSlice(self.gpa, self.additional) catch @panic("OOM");
        return list.toOwnedSlice(self.gpa) catch @panic("OOM");
    }

    fn renderDynamic(self: *NameGen, list: *std.ArrayListUnmanaged(u8)) void {
        const radix: usize = self.radix;
        var remaining = self.current;
        var sub_value = (radix - 1) * radix;
        var num_fill: usize = 2;
        while (remaining >= sub_value) {
            remaining -= sub_value;
            sub_value *= radix;
            num_fill += 1;
        }
        var dbuf: [160]u8 = undefined;
        var dn: usize = 0;
        var r = remaining;
        while (r > 0) : (dn += 1) {
            dbuf[dn] = @intCast(r % radix);
            r /= radix;
        }
        while (dn < num_fill) : (dn += 1) dbuf[dn] = 0;
        const maxc = mapDigit(self.radix, self.radix - 1);
        var k: usize = 0;
        while (k + 2 < num_fill + 1) : (k += 1) {
            // (num_fill - 2) fill chars
            if (k >= num_fill - 2) break;
            list.append(self.gpa, maxc) catch @panic("OOM");
        }
        var idx = dn;
        while (idx > 0) {
            idx -= 1;
            list.append(self.gpa, mapDigit(self.radix, dbuf[idx])) catch @panic("OOM");
        }
    }
};

// ============================================================================ suffix computation

const SuffixMode = enum { alpha, dec_short, hex_short, dec_long, hex_long };

const SuffixParams = struct {
    radix: u8,
    length: usize,
    start: usize,
    auto_widening: bool,
};

const SuffixErrKind = enum { not_parsable, contains_separator, too_small };
const SuffixResult = union(enum) {
    ok: SuffixParams,
    /// value carries the offending string (not_parsable / contains_separator) or the
    /// required length rendered as decimal (too_small).
    err: struct { kind: SuffixErrKind, val: []const u8 },
};

fn parseUsizeDec(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var i: usize = 0;
    if (s[0] == '+') i = 1;
    if (i >= s.len) return null;
    var v: usize = 0;
    while (i < s.len) : (i += 1) {
        if (!isDigit(s[i])) return null;
        v = std.math.mul(usize, v, 10) catch return null;
        v = std.math.add(usize, v, s[i] - '0') catch return null;
    }
    return v;
}

fn parseUsizeHex(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var i: usize = 0;
    if (s[0] == '+') i = 1;
    if (i >= s.len) return null;
    var v: usize = 0;
    while (i < s.len) : (i += 1) {
        const d: usize = switch (s[i]) {
            '0'...'9' => s[i] - '0',
            'a'...'f' => s[i] - 'a' + 10,
            'A'...'F' => s[i] - 'A' + 10,
            else => return null,
        };
        v = std.math.mul(usize, v, 16) catch return null;
        v = std.math.add(usize, v, d) catch return null;
    }
    return v;
}

fn requiredLength(start: usize, chunks: u64, radix: u8) usize {
    const x: f64 = @floatFromInt(@as(u128, start) + chunks);
    const b: f64 = @floatFromInt(radix);
    const req = @ceil(@log(x) / @log(b));
    if (req <= 0) return 0;
    return @intFromFloat(req);
}

fn computeSuffix(
    gpa: Allocator,
    mode: SuffixMode,
    suffix_from: ?[]const u8,
    suf_len_str: ?[]const u8,
    additional: []const u8,
    strategy: Strategy,
) SuffixResult {
    var radix: u8 = 26;
    var start: usize = 0;
    var auto_widening = true;

    switch (mode) {
        .alpha => radix = 26,
        .dec_short => radix = 10,
        .hex_short => radix = 16,
        .dec_long => {
            radix = 10;
            if (suffix_from) |v| {
                start = parseUsizeDec(v) orelse return .{ .err = .{ .kind = .not_parsable, .val = v } };
                auto_widening = false;
            }
        },
        .hex_long => {
            radix = 16;
            if (suffix_from) |v| {
                start = parseUsizeHex(v) orelse return .{ .err = .{ .kind = .not_parsable, .val = v } };
                auto_widening = false;
            }
        },
    }

    var length: usize = 2;
    var is_len_opt = false;
    if (suf_len_str) |v| {
        length = parseUsizeDec(v) orelse return .{ .err = .{ .kind = .not_parsable, .val = v } };
        is_len_opt = true;
    }

    if (is_len_opt and length > 0) auto_widening = false;

    if (strategy == .number) {
        const chunks = strategy.number.numChunks();
        const required = requiredLength(start, chunks, radix);
        if (start < chunks and !(is_len_opt and length > 0)) {
            auto_widening = false;
            if (length < required) length = required;
        }
        if (length < required) {
            const owned = std.fmt.allocPrint(gpa, "{d}", .{required}) catch "?";
            return .{ .err = .{ .kind = .too_small, .val = owned } };
        }
    }

    if (is_len_opt and length == 0) length = 2;

    // additional suffix must not contain a directory separator.
    for (additional) |c| {
        if (c == '/') return .{ .err = .{ .kind = .contains_separator, .val = additional } };
    }

    return .{ .ok = .{ .radix = radix, .length = length, .start = start, .auto_widening = auto_widening } };
}

// ============================================================================ settings + run

const Settings = struct {
    input: []const u8,
    prefix: []const u8,
    additional: []const u8,
    filter: ?[]const u8,
    strategy: Strategy,
    verbose: bool,
    separator: u8,
    elide_empty_files: bool,
    suffix: SuffixParams,
};

/// Records iterator: yields each record including its trailing separator, with the final
/// record lacking a separator if the input did not end with one. Matches uutils
/// `lines_with_sep` / `read_until` / `BufRead::split(+re-add)` byte-for-byte.
const RecordIter = struct {
    data: []const u8,
    pos: usize,
    sep: u8,

    fn init(data: []const u8, sep: u8) RecordIter {
        return .{ .data = data, .pos = 0, .sep = sep };
    }
    fn next(self: *RecordIter) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        if (std.mem.indexOfScalarPos(u8, self.data, start, self.sep)) |p| {
            self.pos = p + 1;
            return self.data[start .. p + 1];
        }
        self.pos = self.data.len;
        return self.data[start..];
    }
};

fn verbosePrint(ctx: *Ctx, settings: *const Settings, name: []const u8) void {
    if (settings.verbose) ctx.outPrint("creating file '{s}'\n", .{name});
}

fn writeStdout(ctx: *Ctx, bytes: []const u8) void {
    sys.writeAll(ctx.stdout, bytes) catch {};
}

fn wouldOverwrite(ctx: *Ctx, settings: *const Settings, filename: []const u8) bool {
    if (eq(settings.input, "-")) return false;
    const ca = fsutil.canonicalize(ctx.gpa, settings.input, .all);
    const cb = fsutil.canonicalize(ctx.gpa, filename, .parent);
    if (ca != null and cb != null) return eq(ca.?, cb.?);
    return eq(settings.input, filename);
}

var filter_counter: usize = 0;

fn buildFilterScript(gpa: Allocator, filename: []const u8, command: []const u8) []const u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    list.appendSlice(gpa, "FILE='") catch @panic("OOM");
    for (filename) |c| {
        if (c == '\'') {
            list.appendSlice(gpa, "'\\''") catch @panic("OOM");
        } else list.append(gpa, c) catch @panic("OOM");
    }
    list.appendSlice(gpa, "'\nexport FILE\n") catch @panic("OOM");
    list.appendSlice(gpa, command) catch @panic("OOM");
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}

/// Run the `--filter` shell command over one chunk. Returns true on success. The chunk is
/// fed on the child's stdin via a temp file (nutils `sys.spawn` exposes no pipe primitive);
/// the target file name reaches the command as `$FILE` via shell-variable injection (no
/// per-child env in `sys.spawn`).
fn runFilter(ctx: *Ctx, settings: *const Settings, filename: []const u8, bytes: []const u8) bool {
    filter_counter += 1;
    var tmp_buf: [128]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "/tmp/nutils_split_filter_{d}_{d}", .{ sys.getpid(), filter_counter }) catch {
        ctx.errPrint("split: filter: internal error\n", .{});
        return false;
    };
    {
        const fd = sys.open(tmp, .{ .write = true, .create = true, .trunc = true }) catch {
            ctx.errPrint("split: unable to open '{s}'; aborting\n", .{tmp});
            return false;
        };
        sys.writeAll(fd, bytes) catch {};
        sys.close(fd);
    }
    defer sys.unlink(tmp) catch {};
    const rfd = sys.open(tmp, .{ .read = true }) catch {
        ctx.errPrint("split: unable to open '{s}'; aborting\n", .{tmp});
        return false;
    };
    defer sys.close(rfd);

    const shell_env = envfs.get(ctx.gpa, "SHELL");
    const shell: []const u8 = if (shell_env) |s| (if (s.len == 0) "/bin/sh" else s) else "/bin/sh";
    const script = buildFilterScript(ctx.gpa, filename, settings.filter.?);
    const blob = proc.argvBlob(ctx.gpa, &.{ shell, "-c", script }) catch @panic("OOM");
    switch (proc.spawnWait(blob, rfd, ctx.stdout, ctx.stderr)) {
        .status => |st| {
            if (st == 0) return true;
            ctx.errPrint("split: Shell process returned {d}\n", .{st});
            return false;
        },
        .spawn_err => |e| {
            ctx.errPrint("split: {s}\n", .{sys.strerror(sys.toErrno(e))});
            return false;
        },
        .wait_err => return false,
    }
}

/// Emit one complete chunk: create+write a file, or run the filter. Returns true on success.
fn emitChunk(ctx: *Ctx, settings: *const Settings, filename: []const u8, bytes: []const u8) bool {
    if (settings.filter != null) return runFilter(ctx, settings, filename, bytes);

    if (wouldOverwrite(ctx, settings, filename)) {
        ctx.errPrint("split: '{s}' would overwrite input; aborting\n", .{filename});
        return false;
    }
    const fd = sys.open(filename, .{ .write = true, .create = true, .trunc = true }) catch |e| {
        if (e == error.EISDIR) {
            ctx.errPrint("split: '{s}': Is a directory\n", .{filename});
        } else {
            ctx.errPrint("split: unable to open '{s}'; aborting\n", .{filename});
        }
        return false;
    };
    sys.writeAll(fd, bytes) catch {
        sys.close(fd);
        ctx.errPrint("split: input/output error\n", .{});
        return false;
    };
    sys.close(fd);
    return true;
}

fn exhausted(ctx: *Ctx) u8 {
    ctx.errPrint("split: output file suffixes exhausted\n", .{});
    return 1;
}

fn makeGen(ctx: *Ctx, settings: *const Settings) ?NameGen {
    const s = settings.suffix;
    return NameGen.init(ctx.gpa, settings.prefix, settings.additional, s.radix, s.auto_widening, s.length, s.start) catch {
        ctx.errPrint("split: numerical suffix start value is too large for the suffix length\n", .{});
        return null;
    };
}

// -------- strategy: -l (lines) --------
fn doLines(ctx: *Ctx, settings: *const Settings, data: []const u8, n: u64) u8 {
    var gen = makeGen(ctx, settings) orelse return 1;
    var cur_name = gen.next() orelse return exhausted(ctx); // xaa eagerly
    verbosePrint(ctx, settings, cur_name);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var lines_in_cur: u64 = 0;

    var it = RecordIter.init(data, settings.separator);
    while (it.next()) |rec| {
        if (lines_in_cur == n) {
            if (!emitChunk(ctx, settings, cur_name, buf.items)) return 1;
            buf.clearRetainingCapacity();
            cur_name = gen.next() orelse return exhausted(ctx);
            verbosePrint(ctx, settings, cur_name);
            lines_in_cur = 0;
        }
        buf.appendSlice(ctx.gpa, rec) catch @panic("OOM");
        lines_in_cur += 1;
    }
    if (!emitChunk(ctx, settings, cur_name, buf.items)) return 1;
    return 0;
}

// -------- strategy: -b (bytes) --------
fn doBytes(ctx: *Ctx, settings: *const Settings, data: []const u8, sz: u64) u8 {
    var gen = makeGen(ctx, settings) orelse return 1;
    if (data.len == 0) {
        const name = gen.next() orelse return exhausted(ctx);
        verbosePrint(ctx, settings, name);
        if (!emitChunk(ctx, settings, name, "")) return 1;
        return 0;
    }
    var off: usize = 0;
    while (off < data.len) {
        const name = gen.next() orelse return exhausted(ctx);
        const take: usize = @intCast(@min(sz, data.len - off));
        verbosePrint(ctx, settings, name);
        if (!emitChunk(ctx, settings, name, data[off .. off + take])) return 1;
        off += take;
    }
    return 0;
}

// -------- strategy: -C (line-bytes) --------
fn doLineBytes(ctx: *Ctx, settings: *const Settings, data: []const u8, sz_u: u64) u8 {
    const sz: usize = @intCast(@min(sz_u, @as(u64, std.math.maxInt(usize))));
    var gen = makeGen(ctx, settings) orelse return 1;
    var have_cur = false;
    var cur_name: []const u8 = "";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var remaining: usize = 0;

    var it = RecordIter.init(data, settings.separator);
    while (it.next()) |rec| {
        var line = rec;
        while (true) {
            if (remaining == 0) {
                if (have_cur) {
                    if (!emitChunk(ctx, settings, cur_name, buf.items)) return 1;
                    buf.clearRetainingCapacity();
                }
                cur_name = gen.next() orelse return exhausted(ctx);
                verbosePrint(ctx, settings, cur_name);
                have_cur = true;
                remaining = sz;
            }
            // Last line without a trailing separator that exactly fills a partial chunk:
            // treat as though it ended with a separator and push to the next chunk.
            if (line.len == remaining and remaining < sz and line[line.len - 1] != settings.separator) {
                remaining = 0;
                continue;
            }
            if (line.len <= remaining) {
                buf.appendSlice(ctx.gpa, line) catch @panic("OOM");
                remaining -= line.len;
                break;
            }
            if (line.len > sz and remaining == sz) {
                buf.appendSlice(ctx.gpa, line[0..sz]) catch @panic("OOM");
                line = line[sz..];
                remaining = 0;
                continue;
            }
            remaining = 0;
        }
    }
    if (have_cur) {
        if (!emitChunk(ctx, settings, cur_name, buf.items)) return 1;
    }
    return 0;
}

// -------- generate N filenames up-front (for -n modes) --------
fn genNames(ctx: *Ctx, settings: *const Settings, n: u64) ?[]const []const u8 {
    var gen = makeGen(ctx, settings) orelse return null; // StartTooLarge already reported
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const name = gen.next() orelse {
            _ = exhausted(ctx);
            return null;
        };
        out.append(ctx.gpa, name) catch @panic("OOM");
    }
    return out.toOwnedSlice(ctx.gpa) catch @panic("OOM");
}

// -------- strategy: -n (number) byte modes --------
fn nChunksByByte(ctx: *Ctx, settings: *const Settings, data: []const u8, num_chunks_in: u64, kth: ?u64) u8 {
    const num_bytes: u64 = data.len;
    if (kth != null and num_bytes == 0) return 0;

    var num_chunks = num_chunks_in;
    if (kth == null and settings.elide_empty_files and num_chunks > num_bytes) num_chunks = num_bytes;
    if (num_chunks == 0) return 0;

    const base = num_bytes / num_chunks;
    const rem = num_bytes % num_chunks;

    var names: []const []const u8 = &.{};
    if (kth == null) {
        names = genNames(ctx, settings, num_chunks) orelse return 1;
    }

    var off: usize = 0;
    var i: u64 = 1;
    while (i <= num_chunks) : (i += 1) {
        const csz = base + @as(u64, if (rem > i - 1) 1 else 0);
        const take: usize = if (i == num_chunks)
            @intCast(num_bytes - off)
        else
            @intCast(@min(csz, num_bytes - off));
        const slice = data[off .. off + take];
        off += take;
        if (kth) |k| {
            if (i == k) {
                writeStdout(ctx, slice);
                return 0;
            }
        } else {
            if (!emitChunk(ctx, settings, names[@intCast(i - 1)], slice)) return 1;
        }
    }
    return 0;
}

// -------- strategy: -n (number) line modes --------
fn nChunksByLine(ctx: *Ctx, settings: *const Settings, data: []const u8, num_chunks: u64, kth: ?u64) u8 {
    const num_bytes: u64 = data.len;
    if (num_bytes == 0 and (kth != null or settings.elide_empty_files)) return 0;
    if (num_chunks == 0) return 0; // guard: uutils divides by zero here

    var names: []const []const u8 = &.{};
    var bufs: []std.ArrayListUnmanaged(u8) = &.{};
    if (kth == null) {
        names = genNames(ctx, settings, num_chunks) orelse return 1;
        bufs = ctx.gpa.alloc(std.ArrayListUnmanaged(u8), @intCast(num_chunks)) catch @panic("OOM");
        for (bufs) |*b| b.* = .empty;
    }

    const base = num_bytes / num_chunks;
    const rem = num_bytes % num_chunks;
    var chunk_number: u64 = 1;
    var num_bytes_should: u64 = base + @as(u64, if (rem > 0) 1 else 0);
    var num_bytes_written: u64 = 0;

    var it = RecordIter.init(data, settings.separator);
    while (it.next()) |rec| {
        if (kth) |k| {
            if (chunk_number == k) writeStdout(ctx, rec);
        } else if (chunk_number >= 1 and chunk_number <= num_chunks) {
            bufs[@intCast(chunk_number - 1)].appendSlice(ctx.gpa, rec) catch @panic("OOM");
        }
        num_bytes_written += rec.len;
        var skipped: i64 = -1;
        while (num_bytes_should <= num_bytes_written) {
            num_bytes_should += base + @as(u64, if (rem > chunk_number) 1 else 0);
            chunk_number += 1;
            skipped += 1;
        }
        if (settings.elide_empty_files and skipped > 0 and kth == null) {
            chunk_number -= @intCast(skipped);
        }
        if (kth) |k| {
            if (chunk_number > k) break;
        }
    }

    if (kth != null) return 0;
    for (names, 0..) |name, idx| {
        const b = bufs[idx].items;
        if (settings.elide_empty_files and b.len == 0) continue;
        if (!emitChunk(ctx, settings, name, b)) return 1;
    }
    return 0;
}

// -------- strategy: -n (number) round-robin modes --------
fn nChunksRoundRobin(ctx: *Ctx, settings: *const Settings, data: []const u8, num_chunks: u64, kth: ?u64) u8 {
    if (num_chunks == 0) return 0; // guard: uutils divides by zero here

    var names: []const []const u8 = &.{};
    var bufs: []std.ArrayListUnmanaged(u8) = &.{};
    if (kth == null) {
        names = genNames(ctx, settings, num_chunks) orelse return 1;
        bufs = ctx.gpa.alloc(std.ArrayListUnmanaged(u8), @intCast(num_chunks)) catch @panic("OOM");
        for (bufs) |*b| b.* = .empty;
    }

    const nc: usize = @intCast(num_chunks);
    var i: usize = 0;
    var it = RecordIter.init(data, settings.separator);
    while (it.next()) |rec| {
        const slot = i % nc;
        if (kth) |k| {
            if (slot == @as(usize, @intCast(k - 1))) writeStdout(ctx, rec);
        } else {
            bufs[slot].appendSlice(ctx.gpa, rec) catch @panic("OOM");
        }
        i += 1;
    }

    if (kth != null) return 0;
    for (names, 0..) |name, idx| {
        const b = bufs[idx].items;
        if (settings.elide_empty_files and b.len == 0) continue;
        if (!emitChunk(ctx, settings, name, b)) return 1;
    }
    return 0;
}

fn runSplit(ctx: *Ctx, settings: *const Settings, data: []const u8) u8 {
    return switch (settings.strategy) {
        .lines => |n| doLines(ctx, settings, data, n),
        .bytes => |n| doBytes(ctx, settings, data, n),
        .line_bytes => |n| doLineBytes(ctx, settings, data, n),
        .number => |nt| switch (nt) {
            .bytes => |n| nChunksByByte(ctx, settings, data, n, null),
            .kth_bytes => |x| nChunksByByte(ctx, settings, data, x.n, x.k),
            .lines => |n| nChunksByLine(ctx, settings, data, n, null),
            .kth_lines => |x| nChunksByLine(ctx, settings, data, x.n, x.k),
            .round_robin => |n| nChunksRoundRobin(ctx, settings, data, n, null),
            .kth_round_robin => |x| nChunksRoundRobin(ctx, settings, data, x.n, x.k),
        },
    };
}

// ============================================================================ obsolete `-NUMBER`

const Obsolete = struct { args: []const [:0]const u8, obs_lines: ?[]const u8 };

fn shouldExtractObsLines(slice: []const u8, pre_long: bool, pre_short: bool) bool {
    return startsWith(slice, "-") and !startsWith(slice, "--") and !pre_long and !pre_short and
        !startsWith(slice, "-a") and !startsWith(slice, "-b") and !startsWith(slice, "-C") and
        !startsWith(slice, "-l") and !startsWith(slice, "-n") and !startsWith(slice, "-t");
}

const ExtractResult = union(enum) { keep, drop, replace: [:0]const u8 };

fn handleExtractObsLines(gpa: Allocator, slice: []const u8, obs_lines: *?[]const u8) ExtractResult {
    var extracted: std.ArrayListUnmanaged(u8) = .empty;
    var filtered: std.ArrayListUnmanaged(u8) = .empty;
    var end_reached = false;
    for (slice) |c| {
        if (isDigit(c) and !end_reached) {
            extracted.append(gpa, c) catch @panic("OOM");
        } else {
            if (extracted.items.len > 0) end_reached = true;
            filtered.append(gpa, c) catch @panic("OOM");
        }
    }
    if (extracted.items.len == 0) return .keep;
    obs_lines.* = extracted.toOwnedSlice(gpa) catch @panic("OOM");
    if (filtered.items.len > 1) {
        return .{ .replace = gpa.dupeZ(u8, filtered.items) catch @panic("OOM") };
    }
    return .drop;
}

fn updatePreceding(slice: []const u8, pre_long: *bool, pre_short: *bool) void {
    if (startsWith(slice, "--")) {
        const name = slice[2..];
        pre_long.* = eq(name, "bytes") or eq(name, "line-bytes") or eq(name, "lines") or
            eq(name, "additional-suffix") or eq(name, "filter") or eq(name, "number") or
            eq(name, "suffix-length") or eq(name, "separator");
    }
    pre_short.* = eq(slice, "-b") or eq(slice, "-C") or eq(slice, "-l") or
        eq(slice, "-n") or eq(slice, "-a") or eq(slice, "-t");
    if (!startsWith(slice, "-")) {
        pre_short.* = false;
        pre_long.* = false;
    }
}

fn handleObsolete(gpa: Allocator, args: []const [:0]const u8) Obsolete {
    var out: std.ArrayListUnmanaged([:0]const u8) = .empty;
    var obs_lines: ?[]const u8 = null;
    var pre_long = false;
    var pre_short = false;
    for (args) |a| {
        if (shouldExtractObsLines(a, pre_long, pre_short)) {
            switch (handleExtractObsLines(gpa, a, &obs_lines)) {
                .keep => out.append(gpa, a) catch @panic("OOM"),
                .drop => {},
                .replace => |r| out.append(gpa, r) catch @panic("OOM"),
            }
        } else {
            out.append(gpa, a) catch @panic("OOM");
        }
        updatePreceding(a, &pre_long, &pre_short);
    }
    return .{ .args = out.toOwnedSlice(gpa) catch @panic("OOM"), .obs_lines = obs_lines };
}

// ============================================================================ argv parse + run

fn parseErr(ctx: *Ctx, comptime fmt: []const u8, a: anytype) u8 {
    ctx.errPrint(fmt, a);
    return 1;
}

pub fn run(ctx: *Ctx) u8 {
    const gpa = ctx.gpa;
    const ob = handleObsolete(gpa, ctx.args[1..]);
    const args = ob.args;

    // Strategy value sources.
    var lines_str: ?[]const u8 = null;
    var bytes_str: ?[]const u8 = null;
    var line_bytes_str: ?[]const u8 = null;
    var number_str: ?[]const u8 = null;

    var additional: []const u8 = "";
    var filter: ?[]const u8 = null;
    var elide = false;
    var verbose = false;

    var suffix_mode: SuffixMode = .alpha;
    var suffix_from: ?[]const u8 = null;
    var suf_len_str: ?[]const u8 = null;

    var separators: std.ArrayListUnmanaged([]const u8) = .empty;
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--")) {
            var j = i + 1;
            while (j < args.len) : (j += 1) positionals.append(gpa, args[j]) catch @panic("OOM");
            break;
        }
        if (eq(a, "--help") or eq(a, "-h")) {
            cli.renderHelp(ctx, "split", help_doc);
            return 0;
        }
        if (eq(a, "--version") or eq(a, "-V")) {
            ctx.outPrint("split (uutils coreutils) 0.9.0\n", .{});
            return 0;
        }
        if (startsWith(a, "--")) {
            // long option, possibly --opt=value
            var name: []const u8 = a[2..];
            var inline_val: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, name, '=')) |ep| {
                inline_val = name[ep + 1 ..];
                name = name[0..ep];
            }
            const ValNeed = struct {
                fn get(c: *Ctx, arr: []const [:0]const u8, idx: *usize, iv: ?[]const u8, opt: []const u8) ?[]const u8 {
                    if (iv) |v| return v;
                    if (idx.* + 1 >= arr.len) {
                        c.errPrint("split: option '--{s}' requires an argument\n", .{opt});
                        return null;
                    }
                    idx.* += 1;
                    return arr[idx.*];
                }
            };
            if (eq(name, "lines")) {
                lines_str = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
            } else if (eq(name, "bytes")) {
                bytes_str = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
            } else if (eq(name, "line-bytes")) {
                line_bytes_str = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
            } else if (eq(name, "number")) {
                number_str = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
            } else if (eq(name, "additional-suffix")) {
                additional = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
            } else if (eq(name, "filter")) {
                filter = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
            } else if (eq(name, "suffix-length")) {
                suf_len_str = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
            } else if (eq(name, "separator")) {
                const v = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1;
                separators.append(gpa, v) catch @panic("OOM");
            } else if (eq(name, "numeric-suffixes")) {
                suffix_mode = .dec_long;
                suffix_from = inline_val; // require_equals: only via '='
            } else if (eq(name, "hex-suffixes")) {
                suffix_mode = .hex_long;
                suffix_from = inline_val;
            } else if (eq(name, "elide-empty-files")) {
                elide = true;
            } else if (eq(name, "verbose")) {
                verbose = true;
            } else if (eq(name, "io-blksize")) {
                _ = ValNeed.get(ctx, args, &i, inline_val, name) orelse return 1; // consumed, ignored
            } else {
                return parseErr(ctx, "split: unrecognized option '--{s}'\n", .{name});
            }
            continue;
        }
        if (a.len >= 2 and a[0] == '-' and !eq(a, "-")) {
            // short option cluster
            var j: usize = 1;
            var consumed = false;
            while (j < a.len) : (j += 1) {
                const c = a[j];
                switch (c) {
                    'b', 'C', 'l', 'n', 'a', 't' => {
                        var val: []const u8 = undefined;
                        if (j + 1 < a.len) {
                            val = a[j + 1 ..];
                        } else {
                            if (i + 1 >= args.len) {
                                return parseErr(ctx, "split: option requires an argument -- '{c}'\n", .{c});
                            }
                            i += 1;
                            val = args[i];
                        }
                        switch (c) {
                            'b' => bytes_str = val,
                            'C' => line_bytes_str = val,
                            'l' => lines_str = val,
                            'n' => number_str = val,
                            'a' => suf_len_str = val,
                            't' => separators.append(gpa, val) catch @panic("OOM"),
                            else => unreachable,
                        }
                        consumed = true;
                    },
                    'd' => {
                        suffix_mode = .dec_short;
                        suffix_from = null;
                    },
                    'x' => {
                        suffix_mode = .hex_short;
                        suffix_from = null;
                    },
                    'e' => elide = true,
                    'h' => {
                        cli.renderHelp(ctx, "split", help_doc);
                        return 0;
                    },
                    'V' => {
                        ctx.outPrint("split (uutils coreutils) 0.9.0\n", .{});
                        return 0;
                    },
                    else => return parseErr(ctx, "split: invalid option -- '{c}'\n", .{c}),
                }
                if (consumed) break;
            }
            continue;
        }
        positionals.append(gpa, a) catch @panic("OOM");
    }

    if (positionals.items.len > 2) {
        return parseErr(ctx, "split: extra operand '{s}'\n", .{positionals.items[2]});
    }
    const input: []const u8 = if (positionals.items.len >= 1) positionals.items[0] else "-";
    const prefix: []const u8 = if (positionals.items.len >= 2) positionals.items[1] else "x";

    // ---- build Strategy (matches uutils Settings::from ordering) ----
    const lines_present = lines_str != null;
    const bytes_present = bytes_str != null;
    const line_bytes_present = line_bytes_str != null;
    const number_present = number_str != null;
    const obs = ob.obs_lines;
    const num_sources: usize = @as(usize, @intFromBool(obs != null)) +
        @as(usize, @intFromBool(lines_present)) + @as(usize, @intFromBool(bytes_present)) +
        @as(usize, @intFromBool(line_bytes_present)) + @as(usize, @intFromBool(number_present));

    var strategy: Strategy = undefined;
    if (num_sources > 1) {
        ctx.errPrint("split: cannot split in more than one way\nTry 'split --help' for more information.\n", .{});
        return 1;
    } else if (obs) |v| {
        switch (parseSizeU64Max(v)) {
            .ok => |nn| {
                if (nn > 0) {
                    strategy = .{ .lines = nn };
                } else return parseErr(ctx, "split: invalid number of lines: {s}\n", .{v});
            },
            .err => return parseErr(ctx, "split: invalid number of lines: {s}\n", .{v}),
        }
    } else if (lines_present) {
        strategy = strategyFromSize(ctx, lines_str.?, .lines) orelse return 1;
    } else if (bytes_present) {
        strategy = strategyFromSize(ctx, bytes_str.?, .bytes) orelse return 1;
    } else if (line_bytes_present) {
        strategy = strategyFromSize(ctx, line_bytes_str.?, .line_bytes) orelse return 1;
    } else if (number_present) {
        switch (parseNumberType(number_str.?)) {
            .ok => |nt| strategy = .{ .number = nt },
            .err => |e| switch (e) {
                .num_chunks => |s| return parseErr(ctx, "split: invalid number of chunks: '{s}'\n", .{s}),
                .chunk_number => |s| return parseErr(ctx, "split: invalid chunk number: '{s}'\n", .{s}),
            },
        }
    } else {
        strategy = .{ .lines = 1000 };
    }

    // ---- build Suffix ----
    const suffix = switch (computeSuffix(gpa, suffix_mode, suffix_from, suf_len_str, additional, strategy)) {
        .ok => |sp| sp,
        .err => |e| switch (e.kind) {
            .not_parsable => return parseErr(ctx, "split: invalid suffix length: '{s}'\n", .{e.val}),
            .contains_separator => {
                ctx.errPrint("split: invalid suffix '{s}', contains directory separator\nTry 'split --help' for more information.\n", .{e.val});
                return 1;
            },
            .too_small => return parseErr(ctx, "split: the suffix length needs to be at least {s}\n", .{e.val}),
        },
    };

    // ---- separator ----
    var separator: u8 = '\n';
    if (separators.items.len > 0) {
        const first = separators.items[0];
        for (separators.items[1..]) |s| {
            if (!eq(s, first)) return parseErr(ctx, "split: multiple separator characters specified\n", .{});
        }
        if (eq(first, "\\0")) {
            separator = 0;
        } else if (first.len == 1) {
            separator = first[0];
        } else {
            return parseErr(ctx, "split: multi-character separator '{s}'\n", .{first});
        }
    }

    // ---- filter + Kth-chunk conflict ----
    const is_kth = strategy == .number and switch (strategy.number) {
        .kth_bytes, .kth_lines, .kth_round_robin => true,
        else => false,
    };
    if (is_kth and filter != null) {
        return parseErr(ctx, "split: --filter does not process a chunk extracted to stdout\n", .{});
    }

    var settings = Settings{
        .input = input,
        .prefix = prefix,
        .additional = additional,
        .filter = filter,
        .strategy = strategy,
        .verbose = verbose,
        .separator = separator,
        .elide_empty_files = elide,
        .suffix = suffix,
    };

    // ---- read the whole input ----
    const data: []const u8 = blk: {
        if (eq(input, "-")) {
            break :blk textio.readAll(gpa, ctx.stdin) catch {
                ctx.errPrint("split: error reading standard input\n", .{});
                return 1;
            };
        }
        const fd = sys.open(input, .{ .read = true }) catch |e| {
            ctx.errPrint("split: cannot open '{s}' for reading: {s}\n", .{ input, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
        defer sys.close(fd);
        break :blk textio.readAll(gpa, fd) catch {
            ctx.errPrint("split: error reading '{s}'\n", .{input});
            return 1;
        };
    };

    return runSplit(ctx, &settings, data);
}

const SizeKind = enum { lines, bytes, line_bytes };

fn strategyFromSize(ctx: *Ctx, s: []const u8, kind: SizeKind) ?Strategy {
    switch (parseSizeU64Max(s)) {
        .ok => |n| {
            if (n > 0) return switch (kind) {
                .lines => Strategy{ .lines = n },
                .bytes => Strategy{ .bytes = n },
                .line_bytes => Strategy{ .line_bytes = n },
            };
            // parsed to 0 -> ParseFailure(raw), unquoted
            sizeErrMsg(ctx, kind, s, false);
            return null;
        },
        .err => {
            // parse_size failure -> quoted value
            sizeErrMsg(ctx, kind, s, true);
            return null;
        },
    }
}

fn sizeErrMsg(ctx: *Ctx, kind: SizeKind, s: []const u8, quoted: bool) void {
    const label = switch (kind) {
        .lines => "lines",
        .bytes, .line_bytes => "bytes",
    };
    if (quoted) {
        ctx.errPrint("split: invalid number of {s}: '{s}'\n", .{ label, s });
    } else {
        ctx.errPrint("split: invalid number of {s}: {s}\n", .{ label, s });
    }
}
