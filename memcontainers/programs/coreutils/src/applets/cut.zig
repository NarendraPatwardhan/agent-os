//! `cut` -- DESIGN.md §1: facade-streaming, bounded memory. Exactly one
//! of `-b`/`-c` (share "Chars" mode) or `-f` (Fields mode). `-d DELIM` single byte
//! (fields-only), `-s` only-delimited (fields-only), `-n` accepted no-op,
//! `--complement`, `--output-delimiter=STRING`. LIST: comma-separated 1-based `lo-hi`
//! (`-3`=1..3, `4-`=4..MAX, `N`=N..N). Selection `sel(i) = inList != complement`.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "cut",
    .flags = &.{
        cli.valueOpt('b', "bytes", "select only these bytes"),
        cli.valueOpt('c', "characters", "select only these characters"),
        cli.valueOpt('f', "fields", "select only these fields"),
        cli.valueOpt('d', "delimiter", "use DELIM instead of TAB for field delimiter"),
        cli.flagOpt('s', "only-delimited", "do not print lines not containing delimiters"),
        cli.flagOpt('n', null, "(no-op, accepted for compatibility)"),
        cli.flagOpt(null, "complement", "complement the set of selected bytes/characters/fields"),
        cli.valueOpt(null, "output-delimiter", "use STRING as the output delimiter"),
    },
    .help = .{
        .summary = "remove sections from each line of files",
        .synopsis = &.{"cut OPTION... [FILE]..."},
        .description =
        \\Writes selected portions of each input line to standard output: byte ranges
        \\(-b), character ranges (-c), or delimiter-separated fields (-f). Exactly one of
        \\-b, -c, or -f must be given. Processing is streaming and bounded-memory.
        \\
        \\LIST is a comma-separated list of 1-based ranges: N (a single position), N-M (N
        \\through M), -M (1 through M), or N- (N through end of line). With --complement,
        \\the unselected positions are emitted instead.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened (remaining files are still processed)" },
            .{ .code = 2, .when = "usage error: none or more than one of -b/-c/-f, or a malformed LIST" },
        },
        .deviations = &.{
            "-d takes a single BYTE delimiter (no multibyte characters).",
            "-n is accepted for compatibility but is always a no-op.",
        },
        .examples = &.{
            .{ .cmd = "cut -f1,3 -d: /etc/passwd", .note = "fields 1 and 3, ':'-delimited" },
            .{ .cmd = "cut -c1-10 file.txt", .note = "the first 10 characters of each line" },
            .{ .cmd = "printf 'a-b-c\\n' | cut -d- -f2", .note = "prints: b" },
        },
        .see_also = "paste (join lines), awk (richer field processing).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

const MAXV: usize = std.math.maxInt(usize);

const Range = struct { lo: usize, hi: usize };

const ListError = error{ Invalid, Zero, Decreasing, ENOMEM };

fn parseUsizeStrict(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn parseList(gpa: std.mem.Allocator, s: []const u8) ListError![]Range {
    if (s.len == 0) return error.Invalid;
    var ranges: std.ArrayListUnmanaged(Range) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) return error.Invalid;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo_s = part[0..dash];
            const hi_s = part[dash + 1 ..];
            var lo: usize = 1;
            var hi: usize = MAXV;
            if (lo_s.len > 0) lo = parseUsizeStrict(lo_s) orelse return error.Invalid;
            if (hi_s.len > 0) hi = parseUsizeStrict(hi_s) orelse return error.Invalid;
            if (lo == 0 or (hi_s.len > 0 and hi == 0)) return error.Zero;
            if (hi_s.len > 0 and hi < lo) return error.Decreasing;
            ranges.append(gpa, .{ .lo = lo, .hi = hi }) catch return error.ENOMEM;
        } else {
            const v = parseUsizeStrict(part) orelse return error.Invalid;
            if (v == 0) return error.Zero;
            ranges.append(gpa, .{ .lo = v, .hi = v }) catch return error.ENOMEM;
        }
    }
    if (ranges.items.len == 0) return error.Invalid;
    return ranges.toOwnedSlice(gpa) catch return error.ENOMEM;
}

fn inRanges(ranges: []const Range, idx: usize) bool {
    for (ranges) |r| {
        if (idx >= r.lo and idx <= r.hi) return true;
    }
    return false;
}

fn sel(ranges: []const Range, complement: bool, idx: usize) bool {
    return inRanges(ranges, idx) != complement;
}

const CutState = struct {
    out: *textio.BufOut,
    ranges: []const Range,
    complement: bool,
    chars_mode: bool,
    delim: u8,
    only_delim: bool,
    out_delim: []const u8,
};

fn onLineChars(cs: *CutState, line: []const u8) anyerror!void {
    var first = true;
    var i: usize = 0;
    while (i < line.len) {
        if (sel(cs.ranges, cs.complement, i + 1)) {
            var j = i;
            while (j < line.len and sel(cs.ranges, cs.complement, j + 1)) : (j += 1) {}
            if (!first) try cs.out.extend(cs.out_delim);
            try cs.out.extend(line[i..j]);
            first = false;
            i = j;
        } else {
            i += 1;
        }
    }
    try cs.out.endLine();
}

fn onLineFields(cs: *CutState, line: []const u8) anyerror!void {
    if (std.mem.indexOfScalar(u8, line, cs.delim) == null) {
        if (cs.only_delim) return;
        try cs.out.line(line);
        return;
    }
    var first_out = true;
    var field_no: usize = 1;
    var start: usize = 0;
    while (true) {
        const end = std.mem.indexOfScalarPos(u8, line, start, cs.delim) orelse line.len;
        const field = line[start..end];
        if (sel(cs.ranges, cs.complement, field_no)) {
            if (!first_out) try cs.out.extend(cs.out_delim);
            try cs.out.extend(field);
            first_out = false;
        }
        if (end == line.len) break;
        start = end + 1;
        field_no += 1;
    }
    try cs.out.endLine();
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const mode_count: u8 = @as(u8, @intFromBool(m.has("bytes"))) + @as(u8, @intFromBool(m.has("characters"))) + @as(u8, @intFromBool(m.has("fields")));
    if (mode_count == 0) {
        ctx.errPrint("cut: you must specify a list of bytes, characters, or fields\n", .{});
        return 1;
    }
    if (mode_count > 1) {
        ctx.errPrint("cut: only one type of list may be specified\n", .{});
        return 1;
    }

    const fields_mode = m.has("fields");
    const chars_mode = !fields_mode;
    const list_str = if (fields_mode) m.value("fields").? else if (m.has("bytes")) m.value("bytes").? else m.value("characters").?;

    if (chars_mode) {
        if (m.has("delimiter")) {
            ctx.errPrint("cut: an input delimiter may be specified only when operating on fields\n", .{});
            return 1;
        }
        if (m.has("only-delimited")) {
            ctx.errPrint("cut: suppressing non-delimited lines makes sense only when operating on fields\n", .{});
            return 1;
        }
    }

    var delim: u8 = '\t';
    if (m.value("delimiter")) |d| {
        if (d.len != 1) {
            ctx.errPrint("cut: the delimiter must be a single character\n", .{});
            return 1;
        }
        delim = d[0];
    }

    const complement = m.has("complement");
    const only_delim = m.has("only-delimited");
    const out_delim: []const u8 = if (m.value("output-delimiter")) |v| v else if (fields_mode) std.mem.asBytes(&delim) else "";

    const ranges = parseList(ctx.gpa, list_str) catch |e| {
        switch (e) {
            error.Invalid => {
                const what: []const u8 = if (chars_mode) "byte/character" else "field";
                ctx.errPrint("cut: invalid {s} list\n", .{what});
            },
            error.Zero => ctx.errPrint("cut: fields and positions are numbered from 1\n", .{}),
            error.Decreasing => ctx.errPrint("cut: invalid decreasing range\n", .{}),
            error.ENOMEM => ctx.errPrint("cut: out of memory\n", .{}),
        }
        return 1;
    };

    var out = textio.BufOut.init(ctx.stdout);
    var cs = CutState{
        .out = &out,
        .ranges = ranges,
        .complement = complement,
        .chars_mode = chars_mode,
        .delim = delim,
        .only_delim = only_delim,
        .out_delim = out_delim,
    };
    const rc = if (chars_mode)
        textio.streamLines(ctx, "cut", m.positionalSlice(), &cs, onLineChars)
    else
        textio.streamLines(ctx, "cut", m.positionalSlice(), &cs, onLineFields);
    out.finish() catch {};
    return rc;
}
