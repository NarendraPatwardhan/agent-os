//! `sed` -- stream editor (docs/analysis/uutils-applets.md). CLI: -n (no auto-print),
//! -e SCRIPT (repeatable), -f FILE (repeatable), -E/-r (ERE), -i[=SUFFIX] (in-place),
//! -s (separate files), -z (NUL line separator), --posix (no-op), first non-flag operand
//! is the script when no -e/-f was given, remaining operands are input files. The engine
//! is engines/sedlang. Exit 0 ok, 4 on script-compile error.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;
const textio = @import("../core/textio.zig");
const sed = @import("../engines/sedlang/sed.zig");

const help_doc = cli.Help{
    .summary = "stream editor for filtering and transforming text",
    .synopsis = &.{
        "sed [OPTION]... SCRIPT [FILE]...",
        "sed [OPTION]... -e SCRIPT... [-f SCRIPT-FILE]... [FILE]...",
    },
    .description =
    \\Applies a SCRIPT of editing commands to each line of input and writes the
    \\result to standard output (or back to each FILE, with -i). Each line is
    \\loaded into a "pattern space", every command whose address matches the
    \\current line runs against it in order, and -- unless -n suppresses it -- the
    \\pattern space is printed before moving to the next line. An address is a
    \\line number, `$` (last line), `/REGEX/`, an `addr1,addr2` range, or any of
    \\these negated with a leading `!`.
    \\
    \\The regex dialect is Basic Regular Expressions (BRE) by default -- translated
    \\to the project's Extended Regular Expression (ERE) engine -- or ERE directly
    \\with -E/-r. Supported commands: `s///` (flags `g`, a numeric occurrence
    \\count, `p`, `i`/`I` case-fold, `m`/`M`), `y///` (transliterate), the
    \\pattern/hold-space operators `p P d D n N g G h H x z`, `a i c`
    \\(append/insert/change text, GNU one-line or backslash-continued form), `b t
    \\T` branches with `:` labels, `{ }` blocks, `q Q` (quit, with an optional
    \\exit code), and `=` (print the line number). In a replacement, `&` and
    \\`\1`..`\9` refer to the whole match and capture groups.
    ,
    .options = &.{
        .{ .flags = "-n, --quiet, --silent", .desc = "suppress automatic printing of the pattern space" },
        .{ .flags = "-e SCRIPT", .desc = "add SCRIPT to the commands to run (repeatable)" },
        .{ .flags = "-f FILE", .desc = "add the commands in FILE to the script (repeatable)" },
        .{ .flags = "-E, -r, --regexp-extended", .desc = "use Extended Regular Expressions (ERE) instead of BRE" },
        .{ .flags = "-i[SUFFIX], --in-place[=SUFFIX]", .desc = "edit each FILE in place (SUFFIX is accepted but no backup file is ever written)" },
        .{ .flags = "-s, --separate", .desc = "treat each FILE as its own stream (line numbers and $ reset per file) instead of one continuous stream" },
        .{ .flags = "-z, --null-data", .desc = "split input on NUL bytes instead of newlines" },
        .{ .flags = "--posix", .desc = "accepted, no effect" },
    },
    .operands = "SCRIPT is the editing script, taken from the first non-option argument unless -e or -f already supplied one. FILE...   input files; with none, standard input is read; \"-\" means standard input.",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 1, .when = "with -i: an input FILE could not be opened, or the script failed to compile, for at least one FILE" },
        .{ .code = 2, .when = "with -s (no -i): an input FILE could not be opened (that file is skipped; the rest still run)" },
        .{ .code = 4, .when = "a usage error (bad option, missing -e/-f argument, no SCRIPT), or the script failed to compile" },
    },
    .deviations_from = "GNU sed",
    .deviations = &.{
        "Backreferences INSIDE a pattern (e.g. `\\(a\\)\\1`) are not supported; `\\1`..`\\9` and `&` in the REPLACEMENT of s/// work normally.",
        "Address forms `first~step`, `0,/regex/`, and `addr,+N` are not recognized -- only a line number, $, /regex/, and addr1,addr2 ranges.",
        "The `e`, `r`, `R`, `w`, and `W` commands (shell-out and file read/write) are not supported, nor is a `w file` clause on s///.",
        "-z splits input on NUL bytes, but the OUTPUT line separator is always \\n (GNU sed's -z also makes the output NUL-separated).",
        "-i accepts an attached SUFFIX (e.g. -i.bak) for compatibility, but never writes a backup file -- the original is simply overwritten.",
        "s///'s m/M flag is accepted but has no effect: ^ and $ always match only the start/end of the whole pattern space, never an embedded newline.",
        "`c` on a two-address range prints the change text once per matching line instead of once at the end of the range.",
    },
    .examples = &.{
        .{ .cmd = "sed 's/foo/bar/g' file.txt", .note = "replace every \"foo\" with \"bar\"" },
        .{ .cmd = "sed -n '/ERROR/p' log.txt", .note = "print only matching lines" },
        .{ .cmd = "sed -E 's/[0-9]+/N/g' file.txt", .note = "ERE mode: replace runs of digits with N" },
    },
    .see_also = "awk (field-oriented transforms), grep (search without editing).",
};

const Out = struct {
    ctx: *Ctx,
    fd: sys.Fd,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn write(ctx_ptr: *anyopaque, bytes: []const u8) void {
        const self: *Out = @ptrCast(@alignCast(ctx_ptr));
        self.buf.appendSlice(self.ctx.gpa, bytes) catch {};
        if (self.buf.items.len >= 1 << 15) self.flush();
    }
    fn flush(self: *Out) void {
        if (self.buf.items.len != 0) {
            sys.writeAll(self.fd, self.buf.items) catch {};
            self.buf.clearRetainingCapacity();
        }
    }
};

pub fn run(ctx: *Ctx) u8 {
    var no_print = false;
    var ere = false;
    var separate = false;
    var zero = false;
    var in_place = false;
    var scripts: std.ArrayListUnmanaged([]const u8) = .empty;
    var have_script = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "sed", help_doc);
            return 0;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "--silent")) {
            no_print = true;
        } else if (std.mem.eql(u8, a, "-E") or std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--regexp-extended")) {
            ere = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--separate")) {
            separate = true;
        } else if (std.mem.eql(u8, a, "-z") or std.mem.eql(u8, a, "--null-data")) {
            zero = true;
        } else if (std.mem.eql(u8, a, "--posix")) {
            // no-op
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--in-place") or std.mem.startsWith(u8, a, "-i") or std.mem.startsWith(u8, a, "--in-place=")) {
            in_place = true;
        } else if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--expression")) {
            i += 1;
            if (i >= ctx.args.len) return usageErr(ctx, "option requires an argument -- 'e'");
            scripts.append(ctx.gpa, ctx.args[i]) catch return 4;
            have_script = true;
        } else if (std.mem.startsWith(u8, a, "-e")) {
            scripts.append(ctx.gpa, a[2..]) catch return 4;
            have_script = true;
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
            i += 1;
            if (i >= ctx.args.len) return usageErr(ctx, "option requires an argument -- 'f'");
            const fd = sys.open(ctx.args[i], .{ .read = true }) catch return usageErr(ctx, "can't read script file");
            const data = textio.readAll(ctx.gpa, fd) catch return 4;
            sys.close(fd);
            scripts.append(ctx.gpa, data) catch return 4;
            have_script = true;
        } else if (a.len > 1 and a[0] == '-' and !std.mem.eql(u8, a, "-")) {
            return usageErr(ctx, "unrecognized option");
        } else {
            break;
        }
    }

    if (!have_script) {
        if (i >= ctx.args.len) return usageErr(ctx, "no script");
        scripts.append(ctx.gpa, ctx.args[i]) catch return 4;
        i += 1;
    }
    while (i < ctx.args.len) : (i += 1) files.append(ctx.gpa, ctx.args[i]) catch return 4;

    // Join -e scripts with newlines.
    var script_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (scripts.items, 0..) |s, k| {
        if (k != 0) script_buf.append(ctx.gpa, '\n') catch return 4;
        script_buf.appendSlice(ctx.gpa, s) catch return 4;
    }

    const sep: u8 = if (zero) 0 else '\n';

    // in-place editing implies per-file processing.
    if (in_place and files.items.len != 0) {
        var rc: u8 = 0;
        for (files.items) |f| {
            if (editInPlace(ctx, script_buf.items, ere, no_print, sep, f) != 0) rc = 1;
        }
        return rc;
    }

    var out = Out{ .ctx = ctx, .fd = ctx.stdout };
    defer out.flush();

    if (separate and files.items.len != 0) {
        var rc: u8 = 0;
        for (files.items) |f| {
            const data = readFile(ctx, f) orelse {
                rc = 2;
                continue;
            };
            if (runScript(ctx, script_buf.items, ere, no_print, sep, data, &out) != 0) rc = 4;
        }
        return rc;
    }

    // Concatenate all inputs (default: $ = last line of the last file).
    var all: std.ArrayListUnmanaged(u8) = .empty;
    if (files.items.len == 0) {
        const data = textio.readAll(ctx.gpa, sys.STDIN) catch return 4;
        all.appendSlice(ctx.gpa, data) catch return 4;
    } else {
        for (files.items) |f| {
            const data = readFile(ctx, f) orelse continue;
            all.appendSlice(ctx.gpa, data) catch return 4;
        }
    }
    return runScript(ctx, script_buf.items, ere, no_print, sep, all.items, &out);
}

fn runScript(ctx: *Ctx, script: []const u8, ere: bool, no_print: bool, sep: u8, data: []const u8, out: *Out) u8 {
    const prog = sed.Compiler.compile(ctx.gpa, script, ere) catch {
        ctx.errPrint("sed: -e expression: unknown or malformed command\n", .{});
        return 4;
    };
    const lines = splitLines(ctx, data, sep) catch return 4;
    var ex = sed.Executor.init(ctx.gpa, prog, out, Out.write, !no_print);
    ex.run(lines) catch return 4;
    return 0;
}

fn editInPlace(ctx: *Ctx, script: []const u8, ere: bool, no_print: bool, sep: u8, path: []const u8) u8 {
    const data = readFile(ctx, path) orelse return 1;
    var mem = MemSink{ .ctx = ctx };
    const prog = sed.Compiler.compile(ctx.gpa, script, ere) catch {
        ctx.errPrint("sed: -e expression: unknown or malformed command\n", .{});
        return 1;
    };
    const lines = splitLines(ctx, data, sep) catch return 1;
    var ex = sed.Executor.init(ctx.gpa, prog, &mem, MemSink.write, !no_print);
    ex.run(lines) catch return 1;
    const fd = sys.open(path, .{ .write = true, .create = true, .trunc = true }) catch return 1;
    defer sys.close(fd);
    sys.writeAll(fd, mem.buf.items) catch return 1;
    return 0;
}

const MemSink = struct {
    ctx: *Ctx,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    fn write(ctx_ptr: *anyopaque, bytes: []const u8) void {
        const self: *MemSink = @ptrCast(@alignCast(ctx_ptr));
        self.buf.appendSlice(self.ctx.gpa, bytes) catch {};
    }
};

fn readFile(ctx: *Ctx, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "-")) return textio.readAll(ctx.gpa, sys.STDIN) catch null;
    const fd = sys.open(path, .{ .read = true }) catch {
        ctx.errPrint("sed: can't read {s}: No such file or directory\n", .{path});
        return null;
    };
    defer sys.close(fd);
    return textio.readAll(ctx.gpa, fd) catch null;
}

/// Split into lines on `sep`, dropping a single trailing empty piece (no phantom last line
/// when the input ends with the separator).
fn splitLines(ctx: *Ctx, data: []const u8, sep: u8) ![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, sep);
    var pending: ?[]const u8 = null;

    while (it.next()) |line| {
        if (pending) |p| try lines.append(ctx.gpa, p);
        pending = line;

    }
    if (pending) |p| {
        if (p.len != 0) try lines.append(ctx.gpa, p);
    }
    return lines.items;
}

fn usageErr(ctx: *Ctx, msg: []const u8) u8 {
    ctx.errPrint("sed: {s}\n", .{msg});
    return 4;
}
