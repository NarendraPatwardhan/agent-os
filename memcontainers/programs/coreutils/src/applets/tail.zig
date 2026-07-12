//! `tail` -- DESIGN.md §1: argv pre-pass rewrites obsolete `-<digits>`
//! -> `-n N` and `+<digits>` -> `-n +N`. `-c/--bytes N|+N`, `-n/--lines N|+N` (default
//! 10), `-q/--quiet`, `-v/--verbose`, `-f/--follow`. Four modes: `Lines(N)`/`Bytes(N)`
//! keep a ring of the last N whole lines/bytes; `FromLine(+N)`/`FromByte(+N)` skip a
//! prefix then copy verbatim. 8 KiB reads, no CRLF handling. Headers `==> NAME <==`:
//! Auto (>1 file) / `-v` Always / `-q` Never; blank line between headers after the
//! first. `-f` polls regular-file operands every 1000 ms, ignores stdin, loops forever
//! (not corpus-tested; see the ring-buffer unit tests instead). Exit 0/1/2.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "tail",
    .flags = &.{
        cli.valueOpt('c', "bytes", "output the last (or from) NUM bytes"),
        cli.valueOpt('n', "lines", "output the last (or from) NUM lines"),
        cli.flagOpt('q', "quiet", "never print headers"),
        cli.flagOpt('v', "verbose", "always print headers"),
        cli.flagOpt('f', "follow", "output appended data as the file grows"),
    },
    .help = .{
        .summary = "output the last part of files",
        .synopsis = &.{"tail [OPTION]... [FILE]..."},
        .description =
        \\Prints the last part of each FILE to standard output. With -n (the
        \\default), prints the last NUM lines (default 10); with -c, the last
        \\NUM bytes. A `+NUM` count instead prints starting FROM line/byte NUM
        \\through the end of the file. With more than one FILE, each is preceded
        \\by a `==> NAME <==` header (suppressed by -q, forced by -v even for a
        \\single file).
        \\
        \\-f follows growing files: after the initial output, it polls each
        \\named regular-file operand for appended data roughly once a second and
        \\prints it as it arrives, reprinting the header when the active file
        \\changes; it never terminates on its own and it ignores stdin entirely.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be opened or read (remaining files are still processed)" },
            .{ .code = 2, .when = "usage error" },
        },
        .deviations = &.{
            "-n/-c accept only a plain decimal count (optionally +-prefixed); no K/M/G suffix multipliers.",
            "-f polls named regular files roughly every 1000 ms; there is no --retry/-F, no --pid, and no rename/truncation detection (no inotify).",
        },
        .examples = &.{
            .{ .cmd = "tail -n 20 file.log", .note = "the last 20 lines" },
            .{ .cmd = "tail -f access.log", .note = "follow a growing file (never exits)" },
            .{ .cmd = "tail +5 file.txt", .note = "obsolete form: line 5 to the end, equivalent to -n +5" },
        },
        .see_also = "head (the first part of files).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn rewriteObsolete(gpa: std.mem.Allocator, args: []const [:0]const u8) []const [:0]const u8 {
    if (args.len < 2) return args;
    const a = args[1];
    if (a.len >= 2 and a[0] == '-' and isDigits(a[1..])) {
        var out = gpa.alloc([:0]const u8, args.len + 1) catch @panic("OOM");
        out[0] = args[0];
        out[1] = "-n";
        out[2] = gpa.dupeZ(u8, a[1..]) catch @panic("OOM");
        @memcpy(out[3..], args[2..]);
        return out;
    }
    if (a.len >= 2 and a[0] == '+' and isDigits(a[1..])) {
        var out = gpa.alloc([:0]const u8, args.len + 1) catch @panic("OOM");
        out[0] = args[0];
        out[1] = "-n";
        out[2] = gpa.dupeZ(u8, a) catch @panic("OOM");
        @memcpy(out[3..], args[2..]);
        return out;
    }
    return args;
}

const Count = struct { n: usize, from: bool };

fn parseCount(s: []const u8) Count {
    if (s.len > 0 and s[0] == '+') {
        return .{ .n = parseUsizeForgiving(s[1..]), .from = true };
    }
    return .{ .n = parseUsizeForgiving(s), .from = false };
}

fn parseUsizeForgiving(s: []const u8) usize {
    if (s.len == 0) return 0;
    var v: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return 0;
        v = v * 10 + (c - '0');
    }
    return v;
}

const Mode = union(enum) {
    lines: usize,
    bytes: usize,
    from_line: usize,
    from_byte: usize,
};

/// A pointer-agnostic byte sink: either straight to `ctx.stdout` or into a caller
/// buffer (used by the ring-buffer unit tests below).
const Sink = struct {
    ctx: *Ctx,
    fn extend(self: *Sink, bytes: []const u8) sys.Error!void {
        return self.ctx.outWrite(bytes);
    }
};

fn tailBytesLastN(gpa: std.mem.Allocator, fd: sys.Fd, n: usize, out: *Sink) sys.Error!void {
    if (n == 0) {
        var buf: [8192]u8 = undefined;
        while (true) {
            const r = try sys.read(fd, &buf);
            if (r == 0) break;
        }
        return;
    }
    const ring = gpa.alloc(u8, n) catch return error.ENOMEM;
    var filled: usize = 0;
    var pos: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const r = try sys.read(fd, &buf);
        if (r == 0) break;
        for (buf[0..r]) |b| {
            ring[pos] = b;
            pos = (pos + 1) % n;
            if (filled < n) filled += 1;
        }
    }
    if (filled < n) {
        try out.extend(ring[0..filled]);
    } else {
        try out.extend(ring[pos..n]);
        try out.extend(ring[0..pos]);
    }
}

const LineRing = struct {
    buf: [][]const u8,
    n: usize,
    count: usize = 0,

    fn push(self: *LineRing, line: []const u8) void {
        const idx = self.count % self.n;
        self.buf[idx] = line;
        self.count += 1;
    }

    fn emit(self: *LineRing, out: *Sink) sys.Error!void {
        const take = @min(self.count, self.n);
        const start = if (self.count > self.n) self.count - take else 0;
        var i: usize = 0;
        while (i < take) : (i += 1) {
            const idx = (start + i) % self.n;
            try out.extend(self.buf[idx]);
        }
    }
};

fn tailLastNLines(gpa: std.mem.Allocator, fd: sys.Fd, n: usize, out: *Sink) sys.Error!void {
    if (n == 0) {
        var buf: [8192]u8 = undefined;
        while (true) {
            const r = try sys.read(fd, &buf);
            if (r == 0) break;
        }
        return;
    }
    var ring = LineRing{ .buf = gpa.alloc([]const u8, n) catch return error.ENOMEM, .n = n };
    var cur: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const r = try sys.read(fd, &buf);
        if (r == 0) break;
        for (buf[0..r]) |b| {
            cur.append(gpa, b) catch return error.ENOMEM;
            if (b == '\n') {
                const owned = cur.toOwnedSlice(gpa) catch return error.ENOMEM;
                ring.push(owned);
                cur = .empty;
            }
        }
    }
    if (cur.items.len > 0) {
        const owned = cur.toOwnedSlice(gpa) catch return error.ENOMEM;
        ring.push(owned);
    }
    try ring.emit(out);
}

fn tailFromLine(from_n: usize, fd: sys.Fd, out: *Sink) sys.Error!void {
    var skip: usize = if (from_n > 0) from_n - 1 else 0;
    var buf: [8192]u8 = undefined;
    while (skip > 0) {
        const r = try sys.read(fd, &buf);
        if (r == 0) return;
        var i: usize = 0;
        while (i < r) : (i += 1) {
            if (buf[i] == '\n') {
                skip -= 1;
                if (skip == 0) {
                    try out.extend(buf[i + 1 .. r]);
                    break;
                }
            }
        }
        if (skip == 0) break;
    }
    while (true) {
        const r = try sys.read(fd, &buf);
        if (r == 0) break;
        try out.extend(buf[0..r]);
    }
}

fn tailFromByte(from_n: usize, fd: sys.Fd, out: *Sink) sys.Error!void {
    var skip: usize = if (from_n > 0) from_n - 1 else 0;
    var buf: [8192]u8 = undefined;
    while (skip > 0) {
        const want = @min(skip, buf.len);
        const r = try sys.read(fd, buf[0..want]);
        if (r == 0) return;
        skip -= r;
    }
    while (true) {
        const r = try sys.read(fd, &buf);
        if (r == 0) break;
        try out.extend(buf[0..r]);
    }
}

fn processOperand(gpa: std.mem.Allocator, fd: sys.Fd, mode: Mode, out: *Sink) sys.Error!void {
    switch (mode) {
        .lines => |n| try tailLastNLines(gpa, fd, n, out),
        .bytes => |n| try tailBytesLastN(gpa, fd, n, out),
        .from_line => |n| try tailFromLine(n, fd, out),
        .from_byte => |n| try tailFromByte(n, fd, out),
    }
}

pub fn run(ctx: *Ctx) u8 {
    const args = rewriteObsolete(ctx.gpa, ctx.args);
    var ctx2 = ctx.*;
    ctx2.args = args;
    const res = cli.parse(&ctx2, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const use_bytes = m.has("bytes");
    const cnt: Count = if (use_bytes)
        parseCount(m.value("bytes").?)
    else if (m.has("lines"))
        parseCount(m.value("lines").?)
    else
        .{ .n = 10, .from = false };

    const mode: Mode = if (use_bytes)
        (if (cnt.from) Mode{ .from_byte = cnt.n } else Mode{ .bytes = cnt.n })
    else
        (if (cnt.from) Mode{ .from_line = cnt.n } else Mode{ .lines = cnt.n });

    var files_buf: [256][]const u8 = undefined;
    var file_count: usize = 0;
    for (m.positionalSlice()) |f| {
        if (file_count < files_buf.len) {
            files_buf[file_count] = f;
            file_count += 1;
        }
    }
    var files_storage: [1][]const u8 = .{"-"};
    const files: []const []const u8 = if (file_count == 0) files_storage[0..] else files_buf[0..file_count];

    const header_mode: enum { auto, always, never } = if (m.has("quiet")) .never else if (m.has("verbose")) .always else .auto;
    const show_headers = switch (header_mode) {
        .never => false,
        .always => true,
        .auto => files.len > 1,
    };

    var out = Sink{ .ctx = ctx };
    var rc: u8 = 0;
    var first = true;

    for (files) |file| {
        const is_stdin = std.mem.eql(u8, file, "-");
        if (show_headers) {
            if (!first) ctx.outPrint("\n", .{});
            const label: []const u8 = if (is_stdin) "standard input" else file;
            ctx.outPrint("==> {s} <==\n", .{label});
        }
        first = false;
        const fd = if (is_stdin) ctx.stdin else sys.open(file, .{ .read = true }) catch |e| {
            ctx.errPrint("tail: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);
        processOperand(ctx.gpa, fd, mode, &out) catch |e| {
            ctx.errPrint("tail: {s}: {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
    }

    if (m.has("follow")) {
        followLoop(ctx, files);
    }

    return rc;
}

/// `-f`: poll regular-file operands every 1000 ms for growth, printing new bytes as
/// they appear (re-printing the header when the active file changes). Ignores stdin.
/// Loops forever by design -- not exercised by the golden corpus (see file doc).
fn followLoop(ctx: *Ctx, files: []const []const u8) noreturn {
    var fds_buf: [256]sys.Fd = undefined;
    var names_buf: [256][]const u8 = undefined;
    var count: usize = 0;
    for (files) |file| {
        if (std.mem.eql(u8, file, "-")) continue;
        const fd = sys.open(file, .{ .read = true }) catch continue;
        _ = sys.lseek(fd, 0, .end) catch {};
        if (count < fds_buf.len) {
            fds_buf[count] = fd;
            names_buf[count] = file;
            count += 1;
        }
    }
    var active: ?usize = null;
    var buf: [8192]u8 = undefined;
    while (true) {
        sys.sleepMs(1000);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            while (true) {
                const n = sys.read(fds_buf[i], &buf) catch break;
                if (n == 0) break;
                if (active == null or active.? != i) {
                    if (count > 1) ctx.outPrint("==> {s} <==\n", .{names_buf[i]});
                    active = i;
                }
                ctx.outWrite(buf[0..n]) catch {};
            }
        }
    }
}
