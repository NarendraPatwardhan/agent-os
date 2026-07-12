//! `tr` -- DESIGN.md §1: translate/delete/squeeze over a raw byte
//! stream (8 KiB chunks, cross-chunk squeeze state).
//!
//! Flags: `-c`/`-C/--complement`, `-d/--delete`, `-s/--squeeze-repeats`,
//! `-t/--truncate-set1`; operands `SET1 [SET2]` (via cli allow_hyphen_values).
//!
//! SET grammar: literal bytes; byte ranges `a-z` (reversed -> error); escapes
//! `\n \t \r \\ \a \b \f \v` + octal `\NNN` (1-3 digits, `\0` included; other
//! escaped chars are taken literally); the 12 POSIX classes (ASCII definitions, in
//! ascending byte order); repeat `[c*n]` (decimal n, LEADING 0 -> octal; `n=0` or
//! `[c*]` = fill -- SET2 only, any repeat construct in SET1 is an error);
//! equivalence `[=c=]` -> just `c`. Malformed bracket constructs fall back to a
//! literal `[`.
//!
//! Semantics matrix: `-t` truncates SET1 to SET2's length BEFORE building the map;
//! translation uses a 256-byte map where a shorter SET2 is extended with its last
//! byte (unless `-t`); complemented translation maps ALL complement members to the
//! LAST byte of SET2 (matrix ruling -- GNU maps them in ascending order pairwise;
//! see parity ledger); delete with SET2 requires `-s` (SET2 is then the squeeze
//! set); the squeeze set is the LAST set given, complemented only in the
//! one-set `-cs` form. Errors are single-line `tr: <msg>` at exit 1 (no GNU
//! "Try/explanation" lines -- source: spec); usage errors (missing SET1, >2
//! operands) exit 2 via cli.zig.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "tr",
    .flags = &.{
        cli.flagOpt('c', "complement", "use the complement of SET1"),
        cli.flagOpt('C', null, "same as -c"),
        cli.flagOpt('d', "delete", "delete characters in SET1"),
        cli.flagOpt('s', "squeeze-repeats", "squeeze repeated output characters from the last SET"),
        cli.flagOpt('t', "truncate-set1", "first truncate SET1 to length of SET2"),
    },
    .help = .{
        .summary = "translate, squeeze, and/or delete characters",
        .synopsis = &.{"tr [OPTION]... SET1 [SET2]"},
        .description =
        \\Reads standard input as a raw byte stream and writes a transformed
        \\version to standard output. By default, each byte in SET1 is replaced
        \\by the byte at the corresponding position in SET2 (a shorter SET2 is
        \\extended by repeating its last byte); -d deletes every byte in SET1
        \\instead, and -c/-C complement SET1 to mean "every byte not in SET1".
        \\-s squeezes runs of a repeated byte in the squeeze set (SET2 when
        \\translating, otherwise SET1) down to a single occurrence; -t
        \\truncates SET1 to SET2's length before building the translation
        \\table.
        \\
        \\SET syntax: literal bytes; ranges (`a-z`); the escapes \n \t \r \\
        \\\a \b \f \v and octal \NNN; the twelve POSIX classes (e.g.
        \\`[:digit:]`); the repeat construct `[c*n]` (SET2 only; `[c*]` fills
        \\to SET1's length); and the equivalence class `[=c=]` (treated as
        \\plain `c`).
        ,
        .operands = "SET1 (required) and an optional SET2, using the SET syntax above; tr always reads standard input and writes standard output -- it takes no FILE operands.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "an invalid SET, an invalid combination of operands/flags (e.g. -d with two sets but no -s), or a read/write error" },
            .{ .code = 2, .when = "usage error (missing SET1, or more than two operands)" },
        },
        .deviations = &.{
            "Complemented translation (-c/-C with two SETs) maps every complement byte to SET2's LAST byte; GNU instead maps the complement in ascending byte order onto SET2.",
            "Error messages are a single `tr: <message>` line; GNU's additional \"Try 'tr --help'...\" line is not printed.",
        },
        .examples = &.{
            .{ .cmd = "tr 'a-z' 'A-Z' < file.txt", .note = "uppercase every letter" },
            .{ .cmd = "tr -d '[:digit:]' < file.txt", .note = "delete every digit" },
            .{ .cmd = "tr -s ' ' < file.txt", .note = "squeeze runs of spaces to one" },
        },
        .see_also = "sed (general substitution beyond single-byte SETs).",
    },
    .positionals = .{ .name = "SET1 [SET2]", .min = 1, .max = 2 },
    .allow_hyphen_values = true,
};

fn classBytes(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), name: []const u8) bool {
    const eq = std.mem.eql;
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        const c: u8 = @intCast(b);
        const member = if (eq(u8, name, "alnum"))
            std.ascii.isAlphanumeric(c)
        else if (eq(u8, name, "alpha"))
            std.ascii.isAlphabetic(c)
        else if (eq(u8, name, "digit"))
            std.ascii.isDigit(c)
        else if (eq(u8, name, "xdigit"))
            std.ascii.isHex(c)
        else if (eq(u8, name, "lower"))
            std.ascii.isLower(c)
        else if (eq(u8, name, "upper"))
            std.ascii.isUpper(c)
        else if (eq(u8, name, "space"))
            std.ascii.isWhitespace(c)
        else if (eq(u8, name, "blank"))
            (c == ' ' or c == '\t')
        else if (eq(u8, name, "cntrl"))
            std.ascii.isControl(c)
        else if (eq(u8, name, "punct"))
            (std.ascii.isPrint(c) and c != ' ' and !std.ascii.isAlphanumeric(c))
        else if (eq(u8, name, "graph"))
            (std.ascii.isPrint(c) and c != ' ')
        else if (eq(u8, name, "print"))
            std.ascii.isPrint(c)
        else
            return false;
        if (member) out.append(gpa, c) catch @panic("OOM");
    }
    return true;
}

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

/// Resolves one escape sequence at `s[i.*]` (s[i.*] == '\\'), advancing `i`.
fn escByte(s: []const u8, i: *usize) u8 {
    if (i.* + 1 >= s.len) {
        i.* += 1;
        return '\\'; // trailing backslash is a literal backslash
    }
    const c = s[i.* + 1];
    switch (c) {
        'a' => {
            i.* += 2;
            return 0x07;
        },
        'b' => {
            i.* += 2;
            return 0x08;
        },
        'f' => {
            i.* += 2;
            return 0x0c;
        },
        'n' => {
            i.* += 2;
            return '\n';
        },
        'r' => {
            i.* += 2;
            return '\r';
        },
        't' => {
            i.* += 2;
            return '\t';
        },
        'v' => {
            i.* += 2;
            return 0x0b;
        },
        '\\' => {
            i.* += 2;
            return '\\';
        },
        '0'...'7' => {
            var j = i.* + 1;
            var val: u32 = 0;
            const lim = @min(s.len, i.* + 4); // up to 3 octal digits
            while (j < lim and isOctal(s[j])) : (j += 1) {
                val = val * 8 + (s[j] - '0');
            }
            i.* = j;
            return @truncate(val);
        },
        else => {
            // any other escaped char is that char, literally
            i.* += 2;
            return c;
        },
    }
}

const ParsedSet = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    fill_pos: ?usize = null, // insertion index of a [c*] fill (SET2 only)
    fill_byte: u8 = 0,
};

/// Expands one SET; on error prints `tr: <msg>` and returns null.
fn parseSet(ctx: *Ctx, s: []const u8, is_set2: bool) ?ParsedSet {
    var ps = ParsedSet{};
    const gpa = ctx.gpa;
    var i: usize = 0;
    while (i < s.len) {
        // bracket constructs
        if (s[i] == '[' and i + 1 < s.len) {
            if (s[i + 1] == ':') {
                if (std.mem.indexOfPos(u8, s, i + 2, ":]")) |end| {
                    const name = s[i + 2 .. end];
                    if (!classBytes(gpa, &ps.bytes, name)) {
                        ctx.errPrint("tr: invalid character class '{s}'\n", .{name});
                        return null;
                    }
                    i = end + 2;
                    continue;
                }
            } else if (s[i + 1] == '=') {
                // [=c=] equivalence class: just c
                if (i + 4 < s.len and s[i + 3] == '=' and s[i + 4] == ']') {
                    ps.bytes.append(gpa, s[i + 2]) catch @panic("OOM");
                    i += 5;
                    continue;
                }
            } else {
                // [c*n] / [c*] repeat -- c may be an escape
                var j = i + 1;
                const rc: u8 = if (s[j] == '\\') escByte(s, &j) else blk: {
                    const b = s[j];
                    j += 1;
                    break :blk b;
                };
                if (j < s.len and s[j] == '*') {
                    j += 1;
                    const digits_start = j;
                    while (j < s.len and s[j] >= '0' and s[j] <= '9') : (j += 1) {}
                    if (j < s.len and s[j] == ']') {
                        const digits = s[digits_start..j];
                        if (!is_set2) {
                            ctx.errPrint("tr: the [c*] repeat construct may not appear in string1\n", .{});
                            return null;
                        }
                        var n: u64 = 0;
                        const base: u64 = if (digits.len > 0 and digits[0] == '0') 8 else 10;
                        for (digits) |dch| {
                            if (base == 8 and dch > '7') {
                                n = 0;
                                break;
                            }
                            n = n * base + (dch - '0');
                            if (n > 1 << 20) n = 1 << 20; // sanity cap
                        }
                        if (digits.len == 0 or n == 0) {
                            if (ps.fill_pos != null) {
                                ctx.errPrint("tr: only one [c*] repeat construct may appear in string2\n", .{});
                                return null;
                            }
                            ps.fill_pos = ps.bytes.items.len;
                            ps.fill_byte = rc;
                        } else {
                            var k: u64 = 0;
                            while (k < n) : (k += 1) ps.bytes.append(gpa, rc) catch @panic("OOM");
                        }
                        i = j + 1;
                        continue;
                    }
                }
                // fall through: literal '['
            }
        }

        // one byte (escape or literal), possibly the start of a range
        var lo: u8 = undefined;
        if (s[i] == '\\') {
            lo = escByte(s, &i);
        } else {
            lo = s[i];
            i += 1;
        }
        if (i + 1 < s.len and s[i] == '-') {
            // range endpoint (escape or literal)
            var j = i + 1;
            const hi: u8 = if (s[j] == '\\') escByte(s, &j) else blk: {
                const b = s[j];
                j += 1;
                break :blk b;
            };
            if (hi < lo) {
                ctx.errPrint("tr: range-endpoints of '{c}-{c}' are in reverse collating sequence order\n", .{ lo, hi });
                return null;
            }
            var b: usize = lo;
            while (b <= hi) : (b += 1) ps.bytes.append(gpa, @intCast(b)) catch @panic("OOM");
            i = j;
        } else {
            ps.bytes.append(gpa, lo) catch @panic("OOM");
        }
    }
    return ps;
}

fn memberSet(bytes: []const u8) [256]bool {
    var m = [_]bool{false} ** 256;
    for (bytes) |b| m[b] = true;
    return m;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const complement = m.has("complement") or m.has("C");
    const delete = m.has("delete");
    const squeeze = m.has("squeeze-repeats");
    const truncate = m.has("truncate-set1");
    const pos = m.positionalSlice();

    if (delete and pos.len == 2 and !squeeze) {
        ctx.errPrint("tr: extra operand '{s}'\n", .{pos[1]});
        return 1;
    }
    if (!delete and !squeeze and pos.len == 1) {
        ctx.errPrint("tr: missing operand after '{s}'\n", .{pos[0]});
        return 1;
    }

    const set1p = parseSet(ctx, pos[0], false) orelse return 1;
    var set1 = set1p.bytes.items;

    var set2: []const u8 = &.{};
    if (pos.len == 2) {
        var set2p = parseSet(ctx, pos[1], true) orelse return 1;
        // expand [c*] fill: pad SET2 to SET1's length at the fill position
        if (set2p.fill_pos) |fp| {
            const base_len = set2p.bytes.items.len;
            const fill_n = if (set1.len > base_len) set1.len - base_len else 0;
            var k: usize = 0;
            while (k < fill_n) : (k += 1) {
                set2p.bytes.insert(ctx.gpa, fp, set2p.fill_byte) catch @panic("OOM");
            }
        }
        set2 = set2p.bytes.items;
    }

    const translating = pos.len == 2 and !delete;
    if (translating) {
        if (truncate and set1.len > set2.len) set1 = set1[0..set2.len]; // BEFORE building the map
        if (set2.len == 0 and set1.len > 0) {
            ctx.errPrint("tr: when not truncating set1, string2 must be non-empty\n", .{});
            return 1;
        }
    }

    // membership + translation map + squeeze set
    var member1 = memberSet(set1);
    if (complement) {
        for (&member1) |*b| b.* = !b.*;
    }

    var map: [256]u8 = undefined;
    for (0..256) |b| map[b] = @intCast(b);
    if (translating and set2.len > 0) {
        if (complement) {
            // matrix ruling: ALL complement members map to the LAST byte of SET2
            const last = set2[set2.len - 1];
            for (0..256) |b| {
                if (member1[b]) map[b] = last;
            }
        } else {
            for (set1, 0..) |b, idx| {
                map[b] = if (idx < set2.len) set2[idx] else set2[set2.len - 1];
            }
        }
    }

    var squeeze_set = [_]bool{false} ** 256;
    if (squeeze) {
        if (pos.len == 2) {
            // squeeze set is the LAST set: SET2, never complemented
            for (set2) |b| squeeze_set[b] = true;
        } else {
            // one-set -s / -cs: SET1, complement applies
            squeeze_set = member1;
        }
    }

    const delete_set = member1; // only consulted with -d (complement already applied)

    var out = textio.BufOut.init(ctx.stdout);
    var prev: i32 = -1; // last emitted byte; persists across chunks
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(ctx.stdin, &chunk) catch {
            ctx.errPrint("tr: read error\n", .{});
            return 1;
        };
        if (n == 0) break;
        for (chunk[0..n]) |raw| {
            if (delete and delete_set[raw]) continue;
            const b = if (translating) map[raw] else raw;
            if (squeeze and squeeze_set[b] and prev == b) continue;
            out.push(b) catch return 0; // downstream closed: stop quietly
            prev = b;
        }
    }
    out.finish() catch {};
    return 0;
}
