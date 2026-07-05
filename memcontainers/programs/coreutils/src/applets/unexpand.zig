//! `unexpand` -- docs/analysis/applets-g-r.md (M7a): converts runs of blanks (spaces
//! and tabs) to tabs. Default behavior converts only LEADING runs; `-a`/`--all`
//! converts runs anywhere on the line; `-t LIST` (repeatable, comma-joined, same `/N`
//! `+N` grammar as `expand` but comma-only separated -- no spaces) IMPLIES `-a`
//! (verified against the oracle: `unexpand -t4 'ab  cd'` converts the MID-line run);
//! `-f`/`--first-only` forces leading-only and overrides a preceding `-a`/`-t`
//! (verified: `-a --first-only` behaves like plain default). `-U`/`--no-utf8` disables
//! multi-byte grouping.
//!
//! The subtlest rule (verified against the oracle by constructing exact column-boundary
//! cases): a run of blanks is only ever rewritten into a tab if doing so SAVES at
//! least one byte -- a single space that happens to land exactly on a tab stop is
//! left as a space (`aaaaaaa b` with `-a` stays `aaaaaaa b`), but two or more spaces
//! reaching a stop do become a tab (`aaaaaa  b` -> `aaaaaa<TAB>b`). This falls out of
//! `writeTabs`'s `col > scol + 1` guard, ported directly from unexpand.rs.
//!
//! With a plain ascending `-t LIST` (no `/N`/`+N`), columns past the last explicit
//! stop are never touched at all (not even collapsed to a single space, unlike
//! `expand`'s fallback) -- ported via the `lastcol` cutoff in unexpand.rs.
//!
//! Obsolete shortcut form: an argv pre-pass (port of unexpand.rs `expand_shortcuts`)
//! rewrites any `-<digits-and-commas>` argument into `--tabs=SEG` tokens (one per
//! non-empty comma segment), and -- when at least one shortcut was seen and no
//! literal `-a`/`--all` argument appeared among the NON-shortcut args -- appends one
//! trailing `--first-only`, so `-7` does NOT imply `-a` (unlike `-t 7`; verified:
//! `unexpand -3 'xx  y'` leaves the mid-line run alone, `-t3` converts it). The
//! pre-pass runs on every argument, ignoring `--`, and a bare `-` matches vacuously:
//! it is swallowed (stdin never read when other operands exist) AND counts as a
//! shortcut, so `unexpand -t3 - g` gets `--first-only` appended, canceling `-t`'s
//! implied `-a` (oracle-verified uutils quirk, ledgered).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "unexpand",
    .flags = &.{
        cli.flagOpt('a', "all", "convert all blanks, instead of just initial blanks"),
        cli.flagOpt('f', "first-only", "convert only leading sequences of blanks (overrides -a)"),
        cli.valueOpt('t', "tabs", "tab stops, N or comma-separated LIST (enables -a)"),
        cli.flagOpt('U', "no-utf8", "interpret input file as 8-bit ASCII rather than UTF-8"),
    },
    .help = .{
        .summary = "convert spaces in each file to tabs",
        .synopsis = &.{"unexpand [OPTION]... [FILE]..."},
        .description =
        \\Converts runs of blanks (spaces and tabs) in each FILE back into
        \\tabs and writes the result to standard output; by default only
        \\LEADING runs are converted. -a (or supplying -t LIST) converts runs
        \\anywhere on the line; -f forces leading-only conversion, overriding
        \\a preceding -a/-t. -U treats every byte as one display column
        \\instead of grouping multi-byte UTF-8 sequences.
        \\
        \\A run of blanks is rewritten into a tab only when doing so saves at
        \\least one byte: a single space that lands exactly on a tab stop is
        \\left as a space, but two or more spaces reaching the same stop
        \\become one tab. -t LIST uses the same tab-stop grammar as expand's
        \\-t (including the `/N`/`+N` extensions), except columns past the
        \\last explicit stop are left untouched rather than collapsed to a
        \\single space.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened/read, or an invalid -t argument" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "The legacy `-N[,M...]` shortcut form does NOT imply -a the way a real -t does, and it appends a trailing --first-only -- so `unexpand -3 file` stays leading-only unless a literal -a/--all also appears among the other arguments.",
            "A bare `-` argument in that same shortcut pre-pass is swallowed (never read as stdin) AND counts as a shortcut, so `unexpand -t3 - g` gains an implicit --first-only, canceling -t's own implied -a.",
        },
        .examples = &.{
            .{ .cmd = "unexpand -a file.txt", .note = "convert every run of blanks, not just leading ones" },
            .{ .cmd = "unexpand -t4 file.txt", .note = "use 4-column tab stops (implies -a)" },
            .{ .cmd = "printf '        x\\n' | unexpand", .note = "8 leading spaces become one tab" },
        },
        .see_also = "expand (the inverse: tabs back to spaces).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// Port of unexpand.rs `is_digit_or_comma` applied to a whole argument: `-` followed
/// by zero or more digits/commas (a bare `-` matches vacuously and is swallowed).
fn isShortcutForm(a: []const u8) bool {
    if (a.len < 1 or a[0] != '-') return false;
    for (a[1..]) |c| {
        if (!((c >= '0' and c <= '9') or c == ',')) return false;
    }
    return true;
}

/// Port of unexpand.rs `expand_shortcuts`: rewrite `-N[,M...]` args into `--tabs=SEG`
/// tokens; if any shortcut was seen and no literal `-a`/`--all` appeared among the
/// non-shortcut args, append one trailing `--first-only` (so shortcuts do not imply
/// `-a` the way a real `-t` does).
fn rewriteShortcuts(gpa: std.mem.Allocator, args: []const [:0]const u8) []const [:0]const u8 {
    var any = false;
    for (args[1..]) |a| {
        if (isShortcutForm(a)) any = true;
    }
    if (!any) return args;
    var out: std.ArrayListUnmanaged([:0]const u8) = .empty;
    out.append(gpa, args[0]) catch @panic("OOM");
    var all_provided = false;
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
            if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all")) all_provided = true;
        }
    }
    if (!all_provided) out.append(gpa, "--first-only") catch @panic("OOM");
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

const TabConfig = struct {
    tabstops: []const usize,
    increment_size: ?usize,
    extend_size: ?usize,
};

const TabParseError = union(enum) {
    invalid_character: []const u8,
    zero,
    too_large,
    ascending,
};

const TabParse = union(enum) {
    ok: TabConfig,
    err: TabParseError,
};

const ParseNum = union(enum) { ok: usize, overflow, invalid };

fn parseTabNum(s: []const u8, allow_zero: bool) union(enum) { ok: usize, err: TabParseError } {
    if (s.len == 0) return .{ .err = .{ .invalid_character = s } };
    var v: usize = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') {
            var k: usize = 0;
            while (k < s.len and s[k] >= '0' and s[k] <= '9') k += 1;
            return .{ .err = .{ .invalid_character = s[k..] } };
        }
        const d: usize = ch - '0';
        const mul = std.math.mul(usize, v, 10) catch return .{ .err = .too_large };
        v = std.math.add(usize, mul, d) catch return .{ .err = .too_large };
    }
    if (v == 0 and !allow_zero) return .{ .err = .zero };
    return .{ .ok = v };
}

/// Ports unexpand.rs `parse_tabstops` byte-for-byte.
fn parseTabstops(gpa: std.mem.Allocator, s: []const u8) TabParse {
    var nums: std.ArrayListUnmanaged(usize) = .empty;
    var increment_size: ?usize = null;
    var extend_size: ?usize = null;

    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |word| {
        if (word.len == 0) continue;

        if (word[0] == '+') {
            const rest = word[1..];
            if (increment_size != null or extend_size != null) {
                return .{ .err = .{ .invalid_character = "+" } };
            }
            const value = switch (parseTabNum(rest, true)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            if (nums.items.len == 0) {
                if (value == 0) return .{ .err = .zero };
                const stops = gpa.dupe(usize, &[_]usize{value}) catch @panic("OOM");
                return .{ .ok = .{ .tabstops = stops, .increment_size = null, .extend_size = null } };
            }
            increment_size = value;
        } else if (word[0] == '/') {
            const rest = word[1..];
            if (increment_size != null or extend_size != null) {
                return .{ .err = .{ .invalid_character = "/" } };
            }
            const value = switch (parseTabNum(rest, true)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            if (nums.items.len == 0) {
                if (value == 0) return .{ .err = .zero };
                const stops = gpa.dupe(usize, &[_]usize{value}) catch @panic("OOM");
                return .{ .ok = .{ .tabstops = stops, .increment_size = null, .extend_size = null } };
            }
            extend_size = value;
        } else {
            if (increment_size != null or extend_size != null) {
                return .{ .err = .{ .invalid_character = word } };
            }
            const value = switch (parseTabNum(word, false)) {
                .ok => |v| v,
                .err => |e| return .{ .err = e },
            };
            nums.append(gpa, value) catch @panic("OOM");
        }
    }

    if (nums.items.len == 0 and increment_size == null and extend_size == null) {
        const stops = gpa.dupe(usize, &[_]usize{8}) catch @panic("OOM");
        return .{ .ok = .{ .tabstops = stops, .increment_size = null, .extend_size = null } };
    }

    if (increment_size) |inc| {
        if (inc > 0) {
            const last = nums.items[nums.items.len - 1];
            nums.append(gpa, last + inc) catch @panic("OOM");
        }
    }

    var i: usize = 1;
    while (i < nums.items.len) : (i += 1) {
        if (nums.items[i - 1] >= nums.items[i]) return .{ .err = .ascending };
    }

    return .{ .ok = .{ .tabstops = nums.toOwnedSlice(gpa) catch @panic("OOM"), .increment_size = increment_size, .extend_size = extend_size } };
}

/// Ports unexpand.rs `next_tabstop`. `null` means "no further conversion possible".
fn nextTabstop(cfg: TabConfig, col: usize) ?usize {
    const stops = cfg.tabstops;
    if (stops.len == 0) return null;

    const inc_positive = if (cfg.increment_size) |n| n > 0 else false;
    const ext_positive = if (cfg.extend_size) |n| n > 0 else false;

    if (stops.len == 1 and !inc_positive and !ext_positive) {
        return stops[0] - col % stops[0];
    }

    for (stops) |t| {
        if (t > col) return t - col;
    }
    const last_tab = stops[stops.len - 1];
    if (cfg.extend_size) |extend_size| {
        if (extend_size == 0) return null;
        return extend_size - (col % extend_size);
    } else if (cfg.increment_size) |increment_size| {
        if (increment_size == 0 or col < last_tab) return null;
        const since = col - last_tab;
        const remainder = since % increment_size;
        return if (remainder == 0) increment_size else increment_size - remainder;
    }
    return null;
}

const CharType = enum { backspace, space, tab, other };

const CharInfo = struct { ctype: CharType, width: usize, nbytes: usize };

fn nextCharInfo(utf8: bool, buf: []const u8, byte: usize) CharInfo {
    const b = buf[byte];
    if (b < 0x80) {
        return switch (b) {
            ' ' => .{ .ctype = .space, .width = 0, .nbytes = 1 },
            '\t' => .{ .ctype = .tab, .width = 0, .nbytes = 1 },
            0x08 => .{ .ctype = .backspace, .width = 0, .nbytes = 1 },
            else => .{ .ctype = .other, .width = 1, .nbytes = 1 },
        };
    }
    if (utf8) {
        var nbytes: usize = 1;
        if (b & 0xE0 == 0xC0) nbytes = 2 else if (b & 0xF0 == 0xE0) nbytes = 3 else if (b & 0xF8 == 0xF0) nbytes = 4;
        if (byte + nbytes <= buf.len) return .{ .ctype = .other, .width = nbytes, .nbytes = nbytes };
    }
    return .{ .ctype = .other, .width = 1, .nbytes = 1 };
}

const PrintState = struct {
    col: usize = 0,
    scol: usize = 0,
    leading: bool = true,
    pctype: CharType = .other,

    fn newLine(self: *PrintState) void {
        self.col = 0;
        self.scol = 0;
        self.leading = true;
        self.pctype = .other;
    }
};

/// Ports unexpand.rs `write_tabs`, including the "only convert if it saves a byte"
/// rule (see module doc).
fn writeTabs(out: *textio.BufOut, cfg: TabConfig, ps: *PrintState, amode: bool) sys.Error!void {
    const ai = ps.leading or amode;
    if ((ai and ps.pctype != .tab and ps.col > ps.scol + 1) or
        (ps.col > ps.scol and (ps.leading or (ai and ps.pctype == .tab))))
    {
        while (nextTabstop(cfg, ps.scol)) |nts| {
            if (ps.col < ps.scol + nts) break;
            try out.push('\t');
            ps.scol += nts;
        }
    }
    while (ps.col > ps.scol) {
        try out.push(' ');
        ps.scol += 1;
    }
}

/// Ports unexpand.rs `unexpand_buf`'s general path (the two fast paths in the
/// original are pure streaming optimizations of this same logic and are omitted here
/// -- they produce byte-identical output, just slower).
fn unexpandBuf(out: *textio.BufOut, buf: []const u8, aflag: bool, utf8: bool, lastcol: usize, cfg: TabConfig, ps: *PrintState) sys.Error!void {
    var byte: usize = 0;
    while (byte < buf.len) {
        if (lastcol > 0 and ps.col >= lastcol) {
            try writeTabs(out, cfg, ps, true);
            try out.extend(buf[byte..]);
            ps.scol = ps.col;
            break;
        }

        const info = nextCharInfo(utf8, buf, byte);
        const tabs_buffered = ps.leading or aflag;
        switch (info.ctype) {
            .space, .tab => {
                ps.col += if (info.ctype == .space) 1 else (nextTabstop(cfg, ps.col) orelse 1);
                if (!tabs_buffered) {
                    try out.extend(buf[byte .. byte + info.nbytes]);
                    ps.scol = ps.col;
                }
            },
            .other, .backspace => {
                try writeTabs(out, cfg, ps, aflag);
                ps.leading = false;
                ps.col = if (info.ctype == .other)
                    ps.col + info.width
                else if (ps.col > 0)
                    ps.col - 1
                else
                    0;
                try out.extend(buf[byte .. byte + info.nbytes]);
                ps.scol = ps.col;
            },
        }
        byte += info.nbytes;
        ps.pctype = info.ctype;
    }
}

fn reportTabError(ctx: *Ctx, e: TabParseError) void {
    switch (e) {
        .invalid_character => |c| ctx.errPrint("unexpand: tab size contains invalid character(s): '{s}'\n", .{c}),
        .zero => ctx.errPrint("unexpand: tab size cannot be 0\n", .{}),
        .too_large => ctx.errPrint("unexpand: tab stop value is too large\n", .{}),
        .ascending => ctx.errPrint("unexpand: tab sizes must be ascending\n", .{}),
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
            break :blk .{ .tabstops = stops, .increment_size = null, .extend_size = null };
        }
        const joined = std.mem.join(ctx.gpa, ",", tab_values) catch @panic("OOM");
        switch (parseTabstops(ctx.gpa, joined)) {
            .ok => |c| break :blk c,
            .err => |e| {
                reportTabError(ctx, e);
                return 1;
            },
        }
    };

    const aflag = (m.has("all") or m.has("tabs")) and !m.has("first-only");
    const utf8 = !m.has("no-utf8");

    const lastcol: usize = if (cfg.tabstops.len > 1 and cfg.increment_size == null and cfg.extend_size == null)
        cfg.tabstops[cfg.tabstops.len - 1]
    else
        0;

    const files_raw = m.positionalSlice();
    const files: []const []const u8 = if (files_raw.len == 0) &[_][]const u8{"-"} else files_raw;

    var out = textio.BufOut.init(ctx.stdout);
    var rc: u8 = 0;

    for (files) |name| {
        const is_stdin = std.mem.eql(u8, name, "-");
        if (!is_stdin) {
            if (sys.stat(name)) |st| {
                if (st.is_dir) {
                    ctx.errPrint("unexpand: {s}: Is a directory\n", .{name});
                    rc = 1;
                    continue;
                }
            } else |_| {}
        }
        const fd = if (is_stdin) ctx.stdin else sys.open(name, .{ .read = true }) catch |e| {
            ctx.errPrint("unexpand: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);

        const content = textio.readAll(ctx.gpa, fd) catch |e| {
            ctx.errPrint("unexpand: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };

        var ps = PrintState{};
        var start: usize = 0;
        var i: usize = 0;
        var stop_processing = false;
        while (i < content.len and !stop_processing) {
            if (content[i] == '\n') {
                unexpandBuf(&out, content[start .. i + 1], aflag, utf8, lastcol, cfg, &ps) catch {
                    stop_processing = true;
                    break;
                };
                ps.newLine();
                start = i + 1;
            }
            i += 1;
        }
        if (!stop_processing and start < content.len) {
            unexpandBuf(&out, content[start..content.len], aflag, utf8, lastcol, cfg, &ps) catch {};
        }
        writeTabs(&out, cfg, &ps, aflag) catch {};
    }
    out.finish() catch {};
    return rc;
}
