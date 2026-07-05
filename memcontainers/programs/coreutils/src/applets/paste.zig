//! `paste` -- docs/analysis/applets-g-r.md (M7a): merges lines of FILE operands.
//! `-s`/`--serial` pastes one file at a time (all its lines joined into one output
//! row) instead of the default parallel mode (one output row per line-index across
//! ALL files, short files contributing empty fields once exhausted). `-d LIST`
//! (default a single TAB) supplies delimiters that CYCLE across the fields of a row;
//! escapes inside LIST: `\\`->backslash, `\n`->newline, `\t`->tab, `\b`->backspace,
//! `\f`->formfeed, `\r`->CR, `\v`->vertical tab, `\0`->an EMPTY delimiter (NOT a NUL
//! byte -- verified against the uutils 0.9.0 oracle: `paste -d '\0' f1 f2` joins with
//! nothing between fields), any other `\X` strips the backslash and uses `X` literally;
//! a trailing unescaped `\` is an error. `-z`/`--zero-terminated` makes NUL the line
//! (and row) terminator instead of `\n` -- this also changes what byte `read_until`
//! splits FIELDS on, so on ordinary `\n`-separated input `-z` swallows an entire file
//! as one field (verified against the oracle).
//!
//! Delimiter-cycle reset semantics (verified against the oracle by tracing byte-exact
//! output, docs/parity-ledger.md): in PARALLEL mode the cycle resets to the first
//! delimiter at the start of every output ROW (POSIX: "reset...after each file operand
//! is processed" -- in practice, after each row is complete); in SERIAL mode the cycle
//! is NEVER reset -- it runs continuously across every line of every file for the
//! whole invocation.
//!
//! FILE operands default to `["-"]`. Multiple `-` operands share ONE stdin cursor
//! (read incrementally, not independently) -- verified against the oracle. All
//! non-stdin operands are opened UP FRONT before any output; the first open failure
//! aborts immediately with NO filename in the message (`paste: <strerror>`) and NO
//! output at all -- this is a real divergence from cut/head's per-operand
//! continue-on-error convention (see docs/parity-ledger.md).
//!
//! With exactly one input source and no `-s`, paste bypasses delimiter handling
//! entirely and streams input to output byte-for-byte, appending the line/row
//! terminator only if the input didn't already end with one.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "paste",
    .flags = &.{
        cli.flagOpt('s', "serial", "paste one file at a time instead of in parallel"),
        cli.valueOpt('d', "delimiters", "reuse characters from LIST instead of TABs"),
        cli.flagOpt('z', "zero-terminated", "line delimiter is NUL, not newline"),
    },
    .help = .{
        .summary = "merge lines of files",
        .synopsis = &.{"paste [OPTION]... [FILE]..."},
        .description =
        \\By default, writes one output line per input line-index, joining the
        \\corresponding line of each FILE with a delimiter (a file that runs
        \\out of lines contributes empty fields for the rest of the row). -s
        \\instead pastes one FILE at a time: every line of that FILE is joined
        \\into a single output row before moving to the next FILE.
        \\
        \\-d LIST supplies the delimiters, cycling across the fields of each
        \\row (default a single TAB); LIST supports the escapes \\, \n, \t,
        \\\b, \f, \r, \v, and \0 (an EMPTY delimiter, not a NUL byte). -z uses
        \\NUL instead of newline as the line/row terminator, which also
        \\changes what byte input lines are split on.
        ,
        .operands = "FILE...   input files, default \"-\" (standard input) if none are given; \"-\" may appear more than once and every occurrence shares one stdin cursor, read incrementally rather than restarted.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE operand could not be opened, or -d's LIST ends with an unescaped backslash" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "Every FILE operand is opened up front before any output; the FIRST one that fails to open aborts the whole run immediately with `paste: <strerror>` (no filename, no partial output), unlike GNU's per-operand continue-on-error.",
        },
        .examples = &.{
            .{ .cmd = "paste -d, a.txt b.txt", .note = "join corresponding lines with a comma" },
            .{ .cmd = "paste -s a.txt", .note = "join every line of a.txt into one TAB-separated row" },
            .{ .cmd = "paste -d '\\0' f1 f2", .note = "concatenate fields with no delimiter between them" },
        },
        .see_also = "cut (the inverse operation: split fields apart instead of joining them).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// A cycling list of delimiter byte-strings. `list.len == 0` means "no delimiter at
/// all" (the `-d ''` case); this falls naturally out of `next()` returning `&.{}`
/// without ever touching the modulo. A list of exactly one entry (including the
/// single *empty* entry produced by `-d '\0'`) behaves identically to the "no
/// delimiter" case byte-for-byte, so no special variant is needed for it.
const DelimEngine = struct {
    list: []const []const u8,
    idx: usize = 0,

    fn next(self: *DelimEngine) []const u8 {
        if (self.list.len == 0) return &.{};
        const d = self.list[self.idx % self.list.len];
        self.idx += 1;
        return d;
    }

    fn resetToFirst(self: *DelimEngine) void {
        self.idx = 0;
    }
};

fn utf8Len(b: u8) usize {
    if (b < 0x80) return 1;
    if (b & 0xE0 == 0xC0) return 2;
    if (b & 0xF0 == 0xE0) return 3;
    if (b & 0xF8 == 0xF0) return 4;
    return 1;
}

/// Parses `-d`'s LIST into a sequence of delimiter byte-strings (paste.rs
/// `parse_delimiters`). Non-escaped bytes (including multi-byte UTF-8 sequences) are
/// sliced directly out of `s` (stable argv storage, no copy needed); escapes are
/// synthesized into small owned buffers.
fn parseDelimiters(gpa: std.mem.Allocator, s: []const u8) error{UnescapedBackslash}![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\') {
            i += 1;
            if (i >= s.len) return error.UnescapedBackslash;
            const c = s[i];
            switch (c) {
                '0' => {
                    list.append(gpa, &.{}) catch @panic("OOM");
                    i += 1;
                },
                '\\', 'n', 't', 'b', 'f', 'r', 'v' => {
                    const b: u8 = switch (c) {
                        '\\' => '\\',
                        'n' => '\n',
                        't' => '\t',
                        'b' => 0x08,
                        'f' => 0x0C,
                        'r' => '\r',
                        'v' => 0x0B,
                        else => unreachable,
                    };
                    const buf = gpa.alloc(u8, 1) catch @panic("OOM");
                    buf[0] = b;
                    list.append(gpa, buf) catch @panic("OOM");
                    i += 1;
                },
                else => {
                    const len = @min(utf8Len(c), s.len - i);
                    list.append(gpa, s[i .. i + len]) catch @panic("OOM");
                    i += len;
                },
            }
        } else {
            const len = @min(utf8Len(s[i]), s.len - i);
            list.append(gpa, s[i .. i + len]) catch @panic("OOM");
            i += len;
        }
    }
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}

/// A buffered byte-stream reader that splits on an arbitrary caller-chosen delimiter
/// byte (`\n` normally, NUL under `-z`) rather than always `\n` (so `textio.LineReader`
/// doesn't fit). Shared by pointer across every `-` operand so repeats read the same
/// underlying stream incrementally instead of each restarting at the top.
const ByteReader = struct {
    fd: sys.Fd,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    fn init(fd: sys.Fd) ByteReader {
        return .{ .fd = fd };
    }

    fn fill(self: *ByteReader) sys.Error!void {
        if (self.eof) return;
        if (self.start > 0) {
            const remaining = self.end - self.start;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.start..self.end]);
            self.start = 0;
            self.end = remaining;
        }
        if (self.end == self.buf.len) return;
        const n = try sys.read(self.fd, self.buf[self.end..]);
        if (n == 0) {
            self.eof = true;
            return;
        }
        self.end += n;
    }

    /// Reads up to and including `delim` into `out` (cleared first). Returns the
    /// number of bytes appended (delimiter included if found); 0 means true EOF with
    /// nothing left to read. Mirrors `BufRead::read_until`.
    fn readField(self: *ByteReader, gpa: std.mem.Allocator, delim: u8, out: *std.ArrayListUnmanaged(u8)) sys.Error!usize {
        out.clearRetainingCapacity();
        var total: usize = 0;
        while (true) {
            if (self.start < self.end) {
                if (std.mem.indexOfScalar(u8, self.buf[self.start..self.end], delim)) |rel| {
                    const abs = self.start + rel;
                    out.appendSlice(gpa, self.buf[self.start .. abs + 1]) catch return error.ENOMEM;
                    total += (abs + 1) - self.start;
                    self.start = abs + 1;
                    return total;
                }
                const chunk = self.buf[self.start..self.end];
                out.appendSlice(gpa, chunk) catch return error.ENOMEM;
                total += chunk.len;
                self.start = self.end;
            }
            if (self.eof) return total;
            try self.fill();
        }
    }
};

fn stripTrailingByte(list: *std.ArrayListUnmanaged(u8), b: u8) void {
    if (list.items.len > 0 and list.items[list.items.len - 1] == b) {
        list.items = list.items[0 .. list.items.len - 1];
    }
}

const Source = struct {
    reader: *ByteReader,
    owns_fd: bool,
};

/// Opens every FILE operand up front (paste.rs collects `input_source_vec` before any
/// reading/writing occurs); the first failure aborts with no filename in the message
/// and no output produced so far (verified against the oracle: `paste f1 /bad f2`
/// prints only `paste: No such file or directory` and nothing on stdout).
fn openSources(ctx: *Ctx, files: []const []const u8) error{Aborted}![]Source {
    var sources: std.ArrayListUnmanaged(Source) = .empty;
    var stdin_reader: ?*ByteReader = null;
    for (files) |name| {
        if (std.mem.eql(u8, name, "-")) {
            if (stdin_reader == null) {
                const r = ctx.gpa.create(ByteReader) catch @panic("OOM");
                r.* = ByteReader.init(ctx.stdin);
                stdin_reader = r;
            }
            sources.append(ctx.gpa, .{ .reader = stdin_reader.?, .owns_fd = false }) catch @panic("OOM");
            continue;
        }
        const fd = sys.open(name, .{ .read = true }) catch |e| {
            ctx.errPrint("paste: {s}\n", .{sys.strerror(sys.toErrno(e))});
            return error.Aborted;
        };
        const r = ctx.gpa.create(ByteReader) catch @panic("OOM");
        r.* = ByteReader.init(fd);
        sources.append(ctx.gpa, .{ .reader = r, .owns_fd = true }) catch @panic("OOM");
    }
    return sources.toOwnedSlice(ctx.gpa) catch @panic("OOM");
}

fn closeSources(sources: []const Source) void {
    for (sources) |s| {
        if (s.owns_fd) sys.close(s.reader.fd);
    }
}

/// Single input source, no `-s`: byte-identical passthrough (paste.rs
/// `write_single_input_source`), only ensuring a trailing terminator.
fn writeSingleSource(ctx: *Ctx, reader: *ByteReader, line_ending: u8) sys.Error!void {
    var out = textio.BufOut.init(ctx.stdout);
    var has_data = false;
    var last_byte: u8 = line_ending;
    var buf: [8192]u8 = undefined;
    while (true) {
        // Drain whatever readField's internal buffer already staged (shouldn't be
        // anything for a fresh reader, but stay correct if it is).
        if (reader.start < reader.end) {
            const chunk = reader.buf[reader.start..reader.end];
            try out.extend(chunk);
            has_data = true;
            last_byte = chunk[chunk.len - 1];
            reader.start = reader.end;
            continue;
        }
        if (reader.eof) break;
        const n = try sys.read(reader.fd, &buf);
        if (n == 0) {
            reader.eof = true;
            break;
        }
        try out.extend(buf[0..n]);
        has_data = true;
        last_byte = buf[n - 1];
    }
    if (has_data and last_byte != line_ending) try out.push(line_ending);
    try out.finish();
}

fn runSerial(ctx: *Ctx, sources: []const Source, delims: []const []const u8, line_ending: u8) sys.Error!void {
    var out = textio.BufOut.init(ctx.stdout);
    var engine = DelimEngine{ .list = delims };
    var row: std.ArrayListUnmanaged(u8) = .empty;
    var field: std.ArrayListUnmanaged(u8) = .empty;
    for (sources) |src| {
        row.clearRetainingCapacity();
        var last_delim_len: usize = 0;
        var any = false;
        while (true) {
            const n = try src.reader.readField(ctx.gpa, line_ending, &field);
            if (n == 0) break;
            stripTrailingByte(&field, line_ending);
            row.appendSlice(ctx.gpa, field.items) catch return error.ENOMEM;
            const d = engine.next();
            row.appendSlice(ctx.gpa, d) catch return error.ENOMEM;
            last_delim_len = d.len;
            any = true;
        }
        if (any) row.items.len -= last_delim_len;
        try out.extend(row.items);
        try out.push(line_ending);
    }
    try out.finish();
}

fn runParallel(ctx: *Ctx, sources: []const Source, delims: []const []const u8, line_ending: u8) sys.Error!void {
    var out = textio.BufOut.init(ctx.stdout);
    var engine = DelimEngine{ .list = delims };
    var row: std.ArrayListUnmanaged(u8) = .empty;
    var fields = ctx.gpa.alloc(std.ArrayListUnmanaged(u8), sources.len) catch @panic("OOM");
    for (fields) |*f| f.* = .empty;
    while (true) {
        row.clearRetainingCapacity();
        engine.resetToFirst();
        var any = false;
        var last_delim_len: usize = 0;
        for (sources, 0..) |src, i| {
            const n = try src.reader.readField(ctx.gpa, line_ending, &fields[i]);
            if (n != 0) {
                stripTrailingByte(&fields[i], line_ending);
                row.appendSlice(ctx.gpa, fields[i].items) catch return error.ENOMEM;
                any = true;
            }
            const d = engine.next();
            row.appendSlice(ctx.gpa, d) catch return error.ENOMEM;
            last_delim_len = d.len;
        }
        if (!any) break;
        row.items.len -= last_delim_len;
        try out.extend(row.items);
        try out.push(line_ending);
    }
    try out.finish();
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const serial = m.has("serial");
    const line_ending: u8 = if (m.has("zero-terminated")) 0 else '\n';
    const delim_str = m.value("delimiters") orelse "\t";

    const delims = parseDelimiters(ctx.gpa, delim_str) catch {
        ctx.errPrint("paste: delimiter list ends with an unescaped backslash: {s}\n", .{delim_str});
        return 1;
    };

    const files_raw = m.positionalSlice();
    const files: []const []const u8 = if (files_raw.len == 0) &[_][]const u8{"-"} else files_raw;

    const sources = openSources(ctx, files) catch return 1;

    if (!serial and sources.len == 1) {
        writeSingleSource(ctx, sources[0].reader, line_ending) catch return 0;
        closeSources(sources);
        return 0;
    }

    if (serial) {
        runSerial(ctx, sources, delims, line_ending) catch return 0;
    } else {
        runParallel(ctx, sources, delims, line_ending) catch return 0;
    }
    closeSources(sources);
    return 0;
}
