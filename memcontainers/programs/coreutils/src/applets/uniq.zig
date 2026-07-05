//! `uniq` -- docs/analysis/applets-s-z.md: streams, adjacent comparison. `-c/--count`
//! (right-justified width-7 count + space), `-d/--repeated`, `-D/--all-repeated` (bare;
//! `-c`+`-D` rejected exit 1), `-u/--unique`, `-i/--ignore-case` (ASCII),
//! `-f/--skip-fields N`, `-s/--skip-chars N`, `-w/--check-chars N`. Operands
//! `[INPUT [OUTPUT]]`; OUTPUT is staged through a `SpoolFile` and copied to the real
//! path after INPUT is fully consumed (input==output safe), with an in-memory fallback
//! when `/scratch` is unavailable.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const spool = @import("../core/spool.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "uniq",
    .flags = &.{
        cli.flagOpt('c', "count", "prefix lines by the number of occurrences"),
        cli.flagOpt('d', "repeated", "only print duplicate lines, one for each group"),
        cli.flagOpt('D', "all-repeated", "print all duplicate lines"),
        cli.flagOpt('u', "unique", "only print unique lines"),
        cli.flagOpt('i', "ignore-case", "ignore differences in case when comparing"),
        cli.valueOpt('f', "skip-fields", "avoid comparing the first N fields"),
        cli.valueOpt('s', "skip-chars", "avoid comparing the first N characters"),
        cli.valueOpt('w', "check-chars", "compare no more than N characters in lines"),
    },
    .help = .{
        .summary = "report or omit repeated adjacent lines",
        .synopsis = &.{"uniq [OPTION]... [INPUT [OUTPUT]]"},
        .description =
        \\Filters ADJACENT matching lines from INPUT, writing the result to
        \\OUTPUT; only consecutive duplicates are collapsed, so input that
        \\isn't already sorted may still contain repeats. -c prefixes each
        \\output line with its occurrence count (right-justified, width 7); -d
        \\prints only the lines that had duplicates (one per group); -D prints
        \\every line of each duplicated group; -u prints only the lines that
        \\had no duplicates.
        \\
        \\-i folds ASCII case when comparing. -f/-s/-w narrow the comparison:
        \\-f skips the first N whitespace-separated fields, -s skips the first
        \\N characters of what remains, and -w caps the comparison to at most N
        \\characters after that -- the full line is always still written, only
        \\the comparison key is narrowed.
        ,
        .operands = "INPUT (optional) is the file to read, or \"-\"/omitted for standard input. OUTPUT (optional) is the file to write, or \"-\"/omitted for standard output; OUTPUT may safely name the same file as INPUT.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "-c combined with -D, an invalid -f/-s/-w argument, or INPUT/OUTPUT could not be opened" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "-i folds only ASCII case (A-Z/a-z); it is not locale-aware.",
            "No --group, and no -z/--zero-terminated.",
        },
        .examples = &.{
            .{ .cmd = "sort file.txt | uniq -c", .note = "count occurrences of each line" },
            .{ .cmd = "uniq -d file.txt", .note = "print only lines that had duplicates" },
            .{ .cmd = "uniq -f1 file.txt", .note = "ignore the first field when comparing" },
        },
        .see_also = "sort (uniq only collapses ADJACENT duplicates; sort the input first for a global count).",
    },
    .positionals = .{ .name = "INPUT", .min = 0, .max = 2 },
};

fn parseUsizeStrict(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn isBlank(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn toLowerAscii(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

const Options = struct {
    count: bool = false,
    only_dup: bool = false,
    all_repeated: bool = false,
    only_uniq: bool = false,
    ignore_case: bool = false,
    skip_fields: usize = 0,
    skip_chars: usize = 0,
    compare_width: ?usize = null,
};

fn keyOf(opts: Options, line: []const u8) []const u8 {
    var s = line;
    var f: usize = 0;
    while (f < opts.skip_fields) : (f += 1) {
        var i: usize = 0;
        while (i < s.len and isBlank(s[i])) i += 1;
        while (i < s.len and !isBlank(s[i])) i += 1;
        s = s[i..];
    }
    s = if (opts.skip_chars < s.len) s[opts.skip_chars..] else s[s.len..];
    if (opts.compare_width) |w| {
        if (s.len > w) s = s[0..w];
    }
    return s;
}

fn eqKeys(a: []const u8, b: []const u8, ignore_case: bool) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |ca, i| {
        var x = ca;
        var y = b[i];
        if (ignore_case) {
            x = toLowerAscii(x);
            y = toLowerAscii(y);
        }
        if (x != y) return false;
    }
    return true;
}

const Sink = union(enum) {
    direct: textio.BufOut,
    spool: spool.SpoolFile,
    mem: *std.ArrayListUnmanaged(u8),

    fn extend(self: *Sink, gpa: std.mem.Allocator, bytes: []const u8) sys.Error!void {
        switch (self.*) {
            .direct => |*d| try d.extend(bytes),
            .spool => |*s| try s.writeAll(bytes),
            .mem => |m| m.appendSlice(gpa, bytes) catch return error.ENOMEM,
        }
    }
};

fn writeCount(sink: *Sink, gpa: std.mem.Allocator, n: usize) sys.Error!void {
    var digits: [20]u8 = undefined;
    var len: usize = 0;
    var v = n;
    if (v == 0) {
        digits[0] = '0';
        len = 1;
    } else {
        while (v != 0) {
            digits[len] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
            len += 1;
        }
    }
    var buf: [20]u8 = undefined;
    for (0..len) |k| buf[k] = digits[len - 1 - k];
    var pad: usize = if (len < 7) 7 - len else 0;
    while (pad > 0) : (pad -= 1) try sink.extend(gpa, " ");
    try sink.extend(gpa, buf[0..len]);
    try sink.extend(gpa, " ");
}

const UniqState = struct {
    sink: *Sink,
    gpa: std.mem.Allocator,
    opts: Options,
    prev: ?[]const u8 = null,
    count: usize = 0,
    group_lines: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn emitOne(us: *UniqState, line: []const u8, count: ?usize) sys.Error!void {
    if (us.opts.count) {
        try writeCount(us.sink, us.gpa, count.?);
    }
    try us.sink.extend(us.gpa, line);
    try us.sink.extend(us.gpa, "\n");
}

fn flushGroup(us: *UniqState) sys.Error!void {
    if (us.prev == null) return;
    const cnt = us.count;
    if (us.opts.all_repeated) {
        if (cnt > 1) {
            for (us.group_lines.items) |l| try emitOne(us, l, null);
        }
    } else {
        const show = if (us.opts.only_dup)
            cnt > 1
        else if (us.opts.only_uniq)
            cnt == 1
        else
            true;
        if (show) try emitOne(us, us.prev.?, cnt);
    }
    us.group_lines.clearRetainingCapacity();
    us.prev = null;
    us.count = 0;
}

fn onLine(us: *UniqState, line: []const u8) anyerror!void {
    const dup = us.gpa.dupe(u8, line) catch return error.ENOMEM;
    if (us.prev) |p| {
        const pk = keyOf(us.opts, p);
        const nk = keyOf(us.opts, dup);
        if (eqKeys(pk, nk, us.opts.ignore_case)) {
            us.count += 1;
            if (us.opts.all_repeated) us.group_lines.append(us.gpa, dup) catch return error.ENOMEM;
            return;
        }
        try flushGroup(us);
    }
    us.prev = dup;
    us.count = 1;
    if (us.opts.all_repeated) {
        us.group_lines.clearRetainingCapacity();
        us.group_lines.append(us.gpa, dup) catch return error.ENOMEM;
    }
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    var opts = Options{
        .count = m.has("count"),
        .only_dup = m.has("repeated"),
        .all_repeated = m.has("all-repeated"),
        .only_uniq = m.has("unique"),
        .ignore_case = m.has("ignore-case"),
    };

    if (opts.count and opts.all_repeated) {
        ctx.errPrint("uniq: printing all duplicate lines and repeat counts is meaningless\n", .{});
        return 1;
    }

    if (m.value("skip-fields")) |v| {
        opts.skip_fields = parseUsizeStrict(v) orelse {
            ctx.errPrint("uniq: invalid number of fields to skip: '{s}'\n", .{v});
            return 1;
        };
    }
    if (m.value("skip-chars")) |v| {
        opts.skip_chars = parseUsizeStrict(v) orelse {
            ctx.errPrint("uniq: invalid number of characters to skip: '{s}'\n", .{v});
            return 1;
        };
    }
    if (m.value("check-chars")) |v| {
        opts.compare_width = parseUsizeStrict(v) orelse {
            ctx.errPrint("uniq: invalid number of characters to compare: '{s}'\n", .{v});
            return 1;
        };
    }

    const positionals = m.positionalSlice();
    const input_path: ?[]const u8 = if (positionals.len >= 1) positionals[0] else null;
    const output_path: ?[]const u8 = if (positionals.len >= 2) positionals[1] else null;

    const is_input_stdin = input_path == null or std.mem.eql(u8, input_path.?, "-");
    const in_fd = if (is_input_stdin) ctx.stdin else sys.open(input_path.?, .{ .read = true }) catch |e| {
        ctx.errPrint("uniq: {s}: {s}\n", .{ input_path.?, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    defer if (!is_input_stdin) sys.close(in_fd);

    const is_output_stdout = output_path == null or std.mem.eql(u8, output_path.?, "-");

    var mem_buf: std.ArrayListUnmanaged(u8) = .empty;
    var sink: Sink = undefined;
    if (is_output_stdout) {
        sink = .{ .direct = textio.BufOut.init(ctx.stdout) };
    } else if (spool.SpoolFile.create()) |sf| {
        sink = .{ .spool = sf };
    } else {
        sink = .{ .mem = &mem_buf };
    }

    var us = UniqState{ .sink = &sink, .gpa = ctx.gpa, .opts = opts };
    var rc: u8 = 0;

    var lr = textio.LineReader.init(in_fd);
    while (true) {
        const maybe = lr.next() catch {
            rc = 1;
            break;
        };
        const line = maybe orelse break;
        onLine(&us, line) catch {
            rc = 1;
            break;
        };
    }
    flushGroup(&us) catch {
        rc = 1;
    };

    if (is_output_stdout) {
        sink.direct.finish() catch {};
    } else {
        const out_fd = sys.open(output_path.?, .{ .write = true, .create = true, .trunc = true }) catch |e| {
            ctx.errPrint("uniq: {s}: {s}\n", .{ output_path.?, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
        defer sys.close(out_fd);
        switch (sink) {
            .spool => |*sf| {
                sf.rewind() catch {};
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = sys.read(sf.fd(), &buf) catch break;
                    if (n == 0) break;
                    sys.writeAll(out_fd, buf[0..n]) catch break;
                }
                sf.deinit();
            },
            .mem => |mm| {
                sys.writeAll(out_fd, mm.items) catch {};
            },
            .direct => unreachable,
        }
    }

    return rc;
}
