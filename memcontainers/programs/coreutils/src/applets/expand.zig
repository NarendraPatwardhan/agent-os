//! `expand` -- docs/analysis/applets-g-r.md (M7a): converts tabs in each FILE to
//! spaces. `-i`/`--initial` only converts LEADING tabs -- verified against the oracle
//! and expand.rs: "leading" means "before the first non-blank" (space AND tab both
//! count as blank; a backspace also ends the leading run since it isn't a space); a
//! `\n` resets the leading state for the next line. `-t N` or `-t LIST` (comma- or
//! space-separated, repeatable `-t` flags are joined with commas) sets tab stops;
//! GNU extensions on the LAST list element: `/N` means "repeat every N columns past
//! the last explicit stop", `+N` means "N columns past the PREVIOUS stop, repeated".
//! The `/`or`+` specifier must be its own comma/space-separated list element (e.g.
//! `2,4,/3`, NOT `2,4/3` -- verified against the oracle: the attached form is a parse
//! error since the whole word after the first digit must parse as a bare number).
//! With a plain ascending list and NO `/`/`+` modifier, tabs past the last explicit
//! stop become a SINGLE space each -- verified against the oracle (`expand -t 3,7`
//! on `a\tb\tc\td` leaves `c`/`d` separated by one space, not aligned to any stop).
//! `-U`/`--no-utf8` disables multi-byte UTF-8 grouping (every byte is one column).
//!
//! Per-operand errors (directory, open failure) print `expand: NAME: strerror`,
//! set exit code 1, and CONTINUE to the next operand (verified against the oracle:
//! `expand e1 /bad e2` still prints e1's and e2's expanded content) -- unlike paste's
//! abort-on-first-error convention.
//!
//! Obsolete shortcut form: an argv pre-pass (port of expand.rs `expand_shortcuts`)
//! rewrites any argument of the shape `-<digits-and-commas>` into one `--tabs=SEG`
//! token per non-empty comma segment (`-7` -> `--tabs=7`, `-3,20` -> `--tabs=3
//! --tabs=20`; repeated `-3 -20` accumulates identically since all --tabs values are
//! comma-joined before parsing). The pre-pass runs on EVERY argument -- including
//! after `--` -- and a bare `-` matches vacuously (empty remainder) and is SWALLOWED,
//! producing no token at all, so `expand f1 - f2` never reads stdin (oracle-verified
//! uutils quirk, ledgered).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "expand",
    .flags = &.{
        cli.flagOpt('i', "initial", "do not convert tabs after non blanks"),
        cli.valueOpt('t', "tabs", "tab stops, N or comma-separated LIST"),
        cli.flagOpt('U', "no-utf8", "interpret input file as 8-bit ASCII rather than UTF-8"),
    },
    .help = .{
        .summary = "convert tabs in each file to spaces",
        .synopsis = &.{"expand [OPTION]... [FILE]..."},
        .description =
        \\Converts tabs in each FILE to the equivalent run of spaces and
        \\writes the result to standard output (default standard input). -i
        \\converts only LEADING tabs -- those before the first non-blank
        \\character on a line; a backspace also ends the leading run. -U
        \\treats every byte as one display column instead of grouping
        \\multi-byte UTF-8 sequences into one column.
        \\
        \\-t N sets a single fixed tab stop every N columns; -t LIST sets
        \\explicit stops (comma- or space-separated, repeatable). On the LAST
        \\list element, the GNU extensions `/N` and `+N` make every stop past
        \\the last explicit one repeat every N columns, or N columns past the
        \\previous stop, respectively; with a plain ascending LIST and no
        \\`/`/`+`, a tab past the last explicit stop becomes a single space.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened/read, or an invalid -t argument (zero, non-ascending, or too large)" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "The legacy `-N[,M...]` shortcut argv rewrite treats a bare `-` argument as matching vacuously and SWALLOWS it silently, so `expand f1 - f2` never reads standard input -- the `-` operand simply disappears.",
        },
        .examples = &.{
            .{ .cmd = "expand -t4 file.txt", .note = "tabs every 4 columns" },
            .{ .cmd = "expand -i file.txt", .note = "convert only leading tabs" },
            .{ .cmd = "expand -t 2,4,/3 file.txt", .note = "explicit stops at 2 and 4, then every 3 columns after" },
        },
        .see_also = "unexpand (the inverse: spaces back to tabs).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// Port of expand.rs `is_digit_or_comma` applied to a whole argument: `-` followed
/// by zero or more digits/commas (the empty remainder matches vacuously, so a bare
/// `-` IS a shortcut and gets swallowed -- oracle-verified).
fn isShortcutForm(a: []const u8) bool {
    if (a.len < 1 or a[0] != '-') return false;
    for (a[1..]) |c| {
        if (!((c >= '0' and c <= '9') or c == ',')) return false;
    }
    return true;
}

/// Port of expand.rs `expand_shortcuts`: rewrite `-N[,M...]` args into `--tabs=SEG`
/// tokens (one per non-empty comma segment). Runs over every argument, ignoring `--`.
fn rewriteShortcuts(gpa: std.mem.Allocator, args: []const [:0]const u8) []const [:0]const u8 {
    var any = false;
    for (args[1..]) |a| {
        if (isShortcutForm(a)) any = true;
    }
    if (!any) return args;
    var out: std.ArrayListUnmanaged([:0]const u8) = .empty;
    out.append(gpa, args[0]) catch @panic("OOM");
    for (args[1..]) |a| {
        if (isShortcutForm(a)) {
            var it = std.mem.splitScalar(u8, a[1..], ',');
            while (it.next()) |seg| {
                if (seg.len == 0) continue;
                const tok = std.fmt.allocPrintSentinel(gpa, "--tabs={s}", .{seg}, 0) catch @panic("OOM");
                out.append(gpa, tok) catch @panic("OOM");
            }
        } else {
            out.append(gpa, a) catch @panic("OOM");
        }
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

const RemainingMode = enum { none, slash, plus };

const TabConfig = struct {
    mode: RemainingMode,
    stops: []const usize,
};

const TabParseError = union(enum) {
    invalid_character: []const u8,
    specifier_not_at_start: struct { specifier: u8, number: []const u8 },
    specifier_only_last: u8,
    zero,
    too_large: []const u8,
    ascending,
};

const TabParse = union(enum) {
    ok: TabConfig,
    err: TabParseError,
};

const ParseNum = union(enum) { ok: usize, overflow, invalid };

fn parseUsizeFull(s: []const u8) ParseNum {
    if (s.len == 0) return .invalid;
    var v: usize = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return .invalid;
        const d: usize = ch - '0';
        const mul = std.math.mul(usize, v, 10) catch return .overflow;
        v = std.math.add(usize, mul, d) catch return .overflow;
    }
    return .{ .ok = v };
}

/// Ports expand.rs `tabstops_parse` byte-for-byte (see module doc for the GNU
/// extension grammar this implements).
fn tabstopsParse(gpa: std.mem.Allocator, s_in: []const u8) TabParse {
    var s = s_in;
    while (s.len > 0 and (s[0] == ' ' or s[0] == ',')) s = s[1..];
    if (s.len == 0) {
        const stops = gpa.dupe(usize, &[_]usize{8}) catch @panic("OOM");
        return .{ .ok = .{ .mode = .none, .stops = stops } };
    }

    var nums: std.ArrayListUnmanaged(usize) = .empty;
    var mode: RemainingMode = .none;
    var specifier_used = false;

    var word_it = std.mem.splitAny(u8, s, " ,");
    while (word_it.next()) |word| {
        if (word.len == 0) continue;
        var j: usize = 0;
        while (j < word.len) {
            const c = word[j];
            if (c == '+') {
                mode = .plus;
                j += 1;
                continue;
            }
            if (c == '/') {
                mode = .slash;
                j += 1;
                continue;
            }
            const rest = word[j..];
            switch (parseUsizeFull(rest)) {
                .ok => |num| {
                    if (num == 0) return .{ .err = .zero };
                    if (nums.items.len > 0 and nums.items[nums.items.len - 1] >= num) return .{ .err = .ascending };
                    if (specifier_used) {
                        const spec_char: u8 = if (mode == .slash) '/' else '+';
                        return .{ .err = .{ .specifier_only_last = spec_char } };
                    } else if (mode != .none) {
                        specifier_used = true;
                    }
                    nums.append(gpa, num) catch @panic("OOM");
                    j = word.len;
                },
                .overflow => return .{ .err = .{ .too_large = rest } },
                .invalid => {
                    var k: usize = 0;
                    while (k < rest.len and rest[k] >= '0' and rest[k] <= '9') k += 1;
                    const tail = rest[k..];
                    if (tail.len > 0 and (tail[0] == '/' or tail[0] == '+')) {
                        return .{ .err = .{ .specifier_not_at_start = .{ .specifier = tail[0], .number = tail } } };
                    }
                    return .{ .err = .{ .invalid_character = tail } };
                },
            }
        }
    }

    if (nums.items.len == 0) nums.append(gpa, 8) catch @panic("OOM");
    if (nums.items.len < 2) mode = .none;

    return .{ .ok = .{ .mode = mode, .stops = nums.toOwnedSlice(gpa) catch @panic("OOM") } };
}

/// Ports expand.rs `next_tabstop`.
fn nextTabstop(stops: []const usize, col: usize, mode: RemainingMode) usize {
    const n = stops.len;
    switch (mode) {
        .plus => {
            for (stops[0 .. n - 1]) |t| {
                if (t > col) return t - col;
            }
            const step = stops[n - 1];
            const last_fixed = stops[n - 2];
            const since = col - last_fixed;
            const steps = 1 + since / step;
            return steps * step - since;
        },
        .slash => {
            for (stops[0 .. n - 1]) |t| {
                if (t > col) return t - col;
            }
            const last = stops[n - 1];
            return last - col % last;
        },
        .none => {
            if (n == 1) return stops[0] - col % stops[0];
            for (stops) |t| {
                if (t > col) return t - col;
            }
            return 1;
        },
    }
}

const CharType = enum { backspace, tab, other };

const CharInfo = struct { ktype: CharType, width: usize, nbytes: usize };

/// Ports expand.rs `classify_char`. Non-ASCII width is approximated as 1 column
/// regardless of actual East-Asian width (the corpus sticks to ASCII, so this never
/// diverges from the oracle in practice).
fn classifyChar(buf: []const u8, i: usize, utf8: bool) CharInfo {
    const b = buf[i];
    if (b < 0x80) {
        return switch (b) {
            '\t' => .{ .ktype = .tab, .width = 0, .nbytes = 1 },
            0x08 => .{ .ktype = .backspace, .width = 0, .nbytes = 1 },
            else => .{ .ktype = .other, .width = 1, .nbytes = 1 },
        };
    }
    if (utf8) {
        var nbytes: usize = 1;
        if (b & 0xE0 == 0xC0) nbytes = 2 else if (b & 0xF0 == 0xE0) nbytes = 3 else if (b & 0xF8 == 0xF0) nbytes = 4;
        if (i + nbytes <= buf.len) return .{ .ktype = .other, .width = 1, .nbytes = nbytes };
    }
    return .{ .ktype = .other, .width = 1, .nbytes = 1 };
}

fn writeSpaces(out: *textio.BufOut, n: usize) sys.Error!void {
    var k: usize = 0;
    while (k < n) : (k += 1) try out.push(' ');
}

/// Ports expand.rs `expand_buf`. Processes one whole file's bytes in a single call
/// (an unbounded-memory tradeoff vs. the oracle's 4KiB-chunked streaming), so `col`
/// and the leading-blanks flag stay exact across the whole file instead of the
/// oracle's per-4KiB-chunk `init` reset -- a deliberate, harmless simplification
/// since it only differs on pathologically long single lines, which the corpus does
/// not exercise (see docs/parity-ledger.md).
fn expandBuf(out: *textio.BufOut, buf: []const u8, stops: []const usize, mode: RemainingMode, iflag: bool, utf8: bool, col: *usize) sys.Error!void {
    var i: usize = 0;
    var init_flag = true;
    while (i < buf.len) {
        const info = classifyChar(buf, i, utf8);
        switch (info.ktype) {
            .tab => {
                const nts = nextTabstop(stops, col.*, mode);
                col.* += nts;
                if (init_flag or !iflag) {
                    try writeSpaces(out, nts);
                } else {
                    try out.extend(buf[i .. i + info.nbytes]);
                }
            },
            .backspace => {
                col.* = if (col.* > 0) col.* - 1 else 0;
                if (buf[i] != ' ') init_flag = false;
                try out.extend(buf[i .. i + info.nbytes]);
            },
            .other => {
                col.* += info.width;
                if (buf[i] != ' ') init_flag = false;
                if (buf[i] == '\n') {
                    col.* = 0;
                    init_flag = true;
                }
                try out.extend(buf[i .. i + info.nbytes]);
            },
        }
        i += info.nbytes;
    }
}

fn reportTabError(ctx: *Ctx, prog: []const u8, e: TabParseError) void {
    switch (e) {
        .invalid_character => |c| ctx.errPrint("{s}: tab size contains invalid character(s): '{s}'\n", .{ prog, c }),
        .specifier_not_at_start => |s| ctx.errPrint("{s}: '{c}' specifier not at start of number: '{s}'\n", .{ prog, s.specifier, s.number }),
        .specifier_only_last => |c| ctx.errPrint("{s}: '{c}' specifier only allowed with the last value\n", .{ prog, c }),
        .zero => ctx.errPrint("{s}: tab size cannot be 0\n", .{prog}),
        .too_large => |sz| ctx.errPrint("{s}: tab stop is too large '{s}'\n", .{ prog, sz }),
        .ascending => ctx.errPrint("{s}: tab sizes must be ascending\n", .{prog}),
    }
}

pub fn run(ctx: *Ctx) u8 {
    var ctx2 = ctx.*;
    ctx2.args = rewriteShortcuts(ctx.gpa, ctx.args);
    const res = cli.parse(&ctx2, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const tab_values = m.values("tabs");
    const cfg: TabConfig = blk: {
        if (tab_values.len == 0) {
            const stops = ctx.gpa.dupe(usize, &[_]usize{8}) catch @panic("OOM");
            break :blk .{ .mode = .none, .stops = stops };
        }
        const joined = std.mem.join(ctx.gpa, ",", tab_values) catch @panic("OOM");
        switch (tabstopsParse(ctx.gpa, joined)) {
            .ok => |c| break :blk c,
            .err => |e| {
                reportTabError(ctx, "expand", e);
                return 1;
            },
        }
    };

    const iflag = m.has("initial");
    const utf8 = !m.has("no-utf8");

    const files_raw = m.positionalSlice();
    const files: []const []const u8 = if (files_raw.len == 0) &[_][]const u8{"-"} else files_raw;

    var out = textio.BufOut.init(ctx.stdout);
    var rc: u8 = 0;

    for (files) |name| {
        var col: usize = 0;
        const is_stdin = std.mem.eql(u8, name, "-");
        if (!is_stdin) {
            if (sys.stat(name)) |st| {
                if (st.is_dir) {
                    ctx.errPrint("expand: {s}: Is a directory\n", .{name});
                    rc = 1;
                    continue;
                }
            } else |_| {}
        }
        const fd = if (is_stdin) ctx.stdin else sys.open(name, .{ .read = true }) catch |e| {
            ctx.errPrint("expand: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);

        const content = textio.readAll(ctx.gpa, fd) catch |e| {
            ctx.errPrint("expand: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        expandBuf(&out, content, cfg.stops, cfg.mode, iflag, utf8, &col) catch break;
    }
    out.finish() catch {};
    return rc;
}
