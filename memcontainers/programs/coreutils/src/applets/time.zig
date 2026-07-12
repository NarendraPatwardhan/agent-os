//! `time` -- DESIGN.md §1: `-p/--portability`, `-v/--verbose`,
//! `-o/--output FILE`, `-a/--append`, `-f/--format FORMAT`; COMMAND required (missing
//! -> usage, 125). Spawn (inherit stdio), t0/t1 via `sys.timeMonotonicMs`, waitpid with
//! EINTR retry. There is no process accounting on the kernel, so user/sys are always
//! `0.000`, CPU% is `?`, RSS/avg-mem are 0 -- integer-only formatting throughout.
//!
//! Report shapes (byte layouts chosen here, documented in DESIGN.md §1 since the
//! matrix pins only "real/user/sys `<m>m<s>.<mmm>s`" for the default and names the
//! others):
//!   default: "real\t<m>m<s>.<mmm>s\nuser\t0m0.000s\nsys\t0m0.000s\n"
//!   -p:      "real <s>.<mmm>\nuser 0.000\nsys 0.000\n"
//!   -f:      template with %e %E %C %x %U %S %P %M %K %t %% (+ \n \t \\ escapes,
//!            unknown directives verbatim), trailing newline appended
//!   -v:      GNU-flavored multi-line block (see renderVerbose)
//! Report goes to stderr, or to `-o FILE` (truncate; `-a` append). Exit: COMMAND's
//! status / 125 usage or wait failure / 127 cannot run
//! (`time: cannot run {cmd}: {strerror}`).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const proc = @import("../core/proc.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "run a command and report how long it took",
    .synopsis = &.{"time [OPTION]... COMMAND [ARG]..."},
    .description =
    \\Runs COMMAND, timing its wall-clock duration, and writes a timing report
    \\to standard error (or -o FILE, truncated unless -a appends). The default
    \\report is "real/user/sys <m>m<s>.<mmm>s" per line; -p/--portability uses
    \\POSIX's "real/user/sys <s>.<mmm>" form; -v/--verbose prints a GNU-style
    \\multi-line block; -f FORMAT renders a template of %e %E %C %x %U %S %P
    \\%M %K %t %% directives (plus \n \t \\ escapes; an unknown directive is
    \\copied verbatim).
    \\
    \\There is no process-accounting support in this environment: user/system
    \\CPU time is always reported as 0.000, CPU percentage as "?", and memory
    \\figures as 0 -- only the wall-clock elapsed time is real.
    ,
    .options = &.{
        .{ .flags = "-p, --portability", .desc = "use the POSIX \"real %f.%f\" output format" },
        .{ .flags = "-v, --verbose", .desc = "print a GNU-style multi-line report" },
        .{ .flags = "-o, --output=FILE", .desc = "write the report to FILE instead of standard error" },
        .{ .flags = "-a, --append", .desc = "append to FILE (with -o) instead of truncating it" },
        .{ .flags = "-f, --format=FORMAT", .desc = "use FORMAT (%e %E %C %x %U %S %P %M %K %t %%) for the report" },
    },
    .operands = "COMMAND [ARG]... the program to run and time; required.",
    .exit = &.{
        .{ .code = 0, .when = "COMMAND ran and exited 0" },
        .{ .code = 125, .when = "usage error (no COMMAND, a missing -o/-f value), or waiting on COMMAND failed" },
        .{ .code = 127, .when = "COMMAND could not be run" },
    },
    .deviations_from = "GNU time",
    .deviations = &.{
        "User/system CPU time, CPU percentage, and memory figures are always 0/0.000/? -- there is no process-accounting facility to source real numbers from.",
        "Any spawn failure (not just \"not found\") is reported as exit 127, rather than distinguishing 126 from 127.",
    },
    .examples = &.{
        .{ .cmd = "time sort bigfile.txt", .note = "default real/user/sys report to stderr" },
        .{ .cmd = "time -p make", .note = "POSIX-format report" },
        .{ .cmd = "time -f '%e %C' -o timing.log make", .note = "custom template written to timing.log" },
    },
    .see_also = "timeout, nice.",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const Sink = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayListUnmanaged(u8) = .empty,

    fn byte(self: *Sink, b: u8) void {
        self.list.append(self.gpa, b) catch @panic("OOM");
    }
    fn bytes(self: *Sink, s: []const u8) void {
        self.list.appendSlice(self.gpa, s) catch @panic("OOM");
    }
    fn dec(self: *Sink, v: u64) void {
        var buf: [20]u8 = undefined;
        var vv = v;
        var i: usize = buf.len;
        if (vv == 0) {
            i -= 1;
            buf[i] = '0';
        } else while (vv != 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(vv % 10));
            vv /= 10;
        }
        self.bytes(buf[i..]);
    }
    fn decPad(self: *Sink, v: u64, width: usize) void {
        var digits: usize = 1;
        var vv = v / 10;
        while (vv != 0) : (vv /= 10) digits += 1;
        var pad = if (digits < width) width - digits else 0;
        while (pad > 0) : (pad -= 1) self.byte('0');
        self.dec(v);
    }
};

/// `<m>m<s>.<mmm>s` (default-format value shape).
fn writeMinSec(s: *Sink, ms: u64) void {
    s.dec(ms / 60_000);
    s.byte('m');
    s.dec((ms % 60_000) / 1000);
    s.byte('.');
    s.decPad(ms % 1000, 3);
    s.byte('s');
}

/// `<s>.<mmm>` (posix / %e value shape).
fn writeSecMs(s: *Sink, ms: u64) void {
    s.dec(ms / 1000);
    s.byte('.');
    s.decPad(ms % 1000, 3);
}

/// `<m>:<ss>.<mmm>` (%E / verbose elapsed shape; minutes unbounded).
fn writeClock(s: *Sink, ms: u64) void {
    s.dec(ms / 60_000);
    s.byte(':');
    s.decPad((ms % 60_000) / 1000, 2);
    s.byte('.');
    s.decPad(ms % 1000, 3);
}

fn writeCommand(s: *Sink, command: []const [:0]const u8) void {
    for (command, 0..) |a, i| {
        if (i > 0) s.byte(' ');
        s.bytes(a);
    }
}

fn renderDefault(s: *Sink, ms: u64) void {
    s.bytes("real\t");
    writeMinSec(s, ms);
    s.bytes("\nuser\t0m0.000s\nsys\t0m0.000s\n");
}

fn renderPosix(s: *Sink, ms: u64) void {
    s.bytes("real ");
    writeSecMs(s, ms);
    s.bytes("\nuser 0.000\nsys 0.000\n");
}

fn renderVerbose(s: *Sink, ms: u64, command: []const [:0]const u8, status: i32) void {
    s.bytes("\tCommand being timed: \"");
    writeCommand(s, command);
    s.bytes("\"\n");
    s.bytes("\tUser time (seconds): 0.000\n");
    s.bytes("\tSystem time (seconds): 0.000\n");
    s.bytes("\tPercent of CPU this job got: ?%\n");
    s.bytes("\tElapsed (wall clock) time (m:ss.mmm): ");
    writeClock(s, ms);
    s.byte('\n');
    s.bytes("\tMaximum resident set size (kbytes): 0\n");
    s.bytes("\tExit status: ");
    if (status < 0) {
        s.byte('-');
        s.dec(@intCast(-@as(i64, status)));
    } else {
        s.dec(@intCast(status));
    }
    s.byte('\n');
}

fn renderFormat(s: *Sink, fmt: []const u8, ms: u64, command: []const [:0]const u8, status: i32) void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '\\' and i + 1 < fmt.len) {
            const nc = fmt[i + 1];
            switch (nc) {
                'n' => s.byte('\n'),
                't' => s.byte('\t'),
                '\\' => s.byte('\\'),
                else => {
                    s.byte('\\');
                    s.byte(nc);
                },
            }
            i += 2;
            continue;
        }
        if (c == '%' and i + 1 < fmt.len) {
            const d = fmt[i + 1];
            i += 2;
            switch (d) {
                '%' => s.byte('%'),
                'e' => writeSecMs(s, ms),
                'E' => writeClock(s, ms),
                'C' => writeCommand(s, command),
                'x' => {
                    if (status < 0) {
                        s.byte('-');
                        s.dec(@intCast(-@as(i64, status)));
                    } else {
                        s.dec(@intCast(status));
                    }
                },
                'U', 'S' => s.bytes("0.000"),
                'P' => s.byte('?'),
                'M', 'K', 't' => s.byte('0'),
                else => {
                    s.byte('%');
                    s.byte(d);
                },
            }
            continue;
        }
        s.byte(c);
        i += 1;
    }
    s.byte('\n');
}

fn usage(ctx: *Ctx) u8 {
    ctx.errPrint("Usage: time [-pv] [-a] [-o FILE] [-f FORMAT] COMMAND [ARG]...\n", .{});
    return 125;
}

pub fn run(ctx: *Ctx) u8 {
    const args = ctx.args[1..];

    var posix = false;
    var verbose = false;
    var append = false;
    var out_file: ?[]const u8 = null;
    var format: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--help")) {
            cli.renderHelp(ctx, "time", help_doc);
            return 0;
        }
        if (eq(a, "--version")) {
            ctx.outPrint("time 0.1.0\n", .{});
            return 0;
        }
        if (eq(a, "-p") or eq(a, "--portability")) {
            posix = true;
            continue;
        }
        if (eq(a, "-v") or eq(a, "--verbose")) {
            verbose = true;
            continue;
        }
        if (eq(a, "-a") or eq(a, "--append")) {
            append = true;
            continue;
        }
        if (eq(a, "-o") or eq(a, "--output")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            out_file = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--output=")) {
            out_file = a["--output=".len..];
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-o")) {
            out_file = a[2..];
            continue;
        }
        if (eq(a, "-f") or eq(a, "--format")) {
            i += 1;
            if (i >= args.len) return usage(ctx);
            format = args[i];
            continue;
        }
        if (std.mem.startsWith(u8, a, "--format=")) {
            format = a["--format=".len..];
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-f")) {
            format = a[2..];
            continue;
        }
        if (eq(a, "--")) {
            i += 1;
            break;
        }
        if (a.len > 1 and a[0] == '-') return usage(ctx);
        break;
    }

    const command = args[i..];
    if (command.len == 0) return usage(ctx);

    // Open the report destination BEFORE running, so a bad -o path fails fast.
    var report_fd = ctx.stderr;
    var opened = false;
    if (out_file) |f| {
        report_fd = sys.open(f, .{ .write = true, .create = true, .trunc = !append, .append = append }) catch |e| {
            ctx.errPrint("time: {s}: {s}\n", .{ f, sys.strerror(sys.toErrno(e)) });
            return 125;
        };
        opened = true;
    }
    defer if (opened) sys.close(report_fd);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    for (command) |a| argv.append(ctx.gpa, a) catch @panic("OOM");
    const blob = proc.argvBlob(ctx.gpa, argv.items) catch @panic("OOM");

    const t0 = sys.timeMonotonicMs() catch 0;
    const pid = sys.spawn(blob, ctx.stdin, ctx.stdout, ctx.stderr) catch |e| {
        ctx.errPrint("time: cannot run {s}: {s}\n", .{ command[0], sys.strerror(sys.toErrno(e)) });
        return 127;
    };
    const status = proc.waitRetry(pid) catch return 125;
    const t1 = sys.timeMonotonicMs() catch t0;
    const elapsed: u64 = if (t1 > t0) @intCast(t1 - t0) else 0;

    var s = Sink{ .gpa = ctx.gpa };
    if (format) |f| {
        renderFormat(&s, f, elapsed, command, status);
    } else if (verbose) {
        renderVerbose(&s, elapsed, command, status);
    } else if (posix) {
        renderPosix(&s, elapsed);
    } else {
        renderDefault(&s, elapsed);
    }
    sys.writeAll(report_fd, s.list.items) catch {};

    return proc.statusToExit(status);
}
