//! `xargs` -- docs/analysis/applets-s-z.md: slurps stdin (`textio.readAll`), splits on
//! NUL (`-0/--null`) or ASCII whitespace, truncates at the `-E EOF` marker item (`-e`
//! alias, optional attached value). Flags: `-n N` max args per batch, `-s BYTES` max
//! chars (byte accounting = command+initial args+items, each + 1 for its NUL
//! separator), `-I R` (replace R in every initial arg, implies one item per
//! invocation), `-r/--no-run-if-empty`, `-t/--verbose` (composed command space-joined
//! to stderr before each run), `-p` treated as `-t`, `-L N` ~ `-n N`. COMMAND defaults
//! to `echo` (resolved via PATH like any spawn). Child stdin = open("/dev/null");
//! spawn per batch + EINTR-retried waitpid. Exit: 0; 123 if any invocation exited
//! non-zero; 126 spawn error; 127 not found (`xargs: {cmd}: cannot run command`);
//! usage errors 2 (clap convention).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const proc = @import("../core/proc.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "build and run command lines from standard input",
    .synopsis = &.{"xargs [OPTION]... [COMMAND [INITIAL-ARG]...]"},
    .description =
    \\Reads items from standard input -- split on ASCII whitespace by default,
    \\or on NUL bytes with -0/--null -- and runs COMMAND (default echo) once
    \\per batch of items appended after INITIAL-ARG. -n N caps items per
    \\batch; -s BYTES caps the total byte size of a batch (counting the
    \\command, its initial arguments, and each item, each plus one separator
    \\byte); -L N is treated the same as -n N. -I R replaces every occurrence
    \\of R in each INITIAL-ARG with one item at a time (implying one item per
    \\invocation). -E EOF (or -e EOF) truncates the input at an item exactly
    \\equal to EOF.
    \\
    \\-t/--verbose (also -p) prints each composed command line to standard
    \\error before running it. -r/--no-run-if-empty skips running COMMAND
    \\entirely when there are no items (otherwise, with no items, COMMAND
    \\still runs once with no appended arguments).
    ,
    .options = &.{
        .{ .flags = "-0, --null", .desc = "input items are NUL-terminated, not whitespace-separated" },
        .{ .flags = "-n N", .desc = "use at most N items per command line" },
        .{ .flags = "-s BYTES", .desc = "use at most BYTES bytes per command line" },
        .{ .flags = "-L N", .desc = "same as -n N" },
        .{ .flags = "-I R", .desc = "replace R in each INITIAL-ARG with one item; implies one item per run" },
        .{ .flags = "-E EOF, -e EOF", .desc = "treat an input item exactly equal to EOF as end of input" },
        .{ .flags = "-r, --no-run-if-empty", .desc = "do not run COMMAND when there are no items" },
        .{ .flags = "-t, --verbose, -p", .desc = "print each composed command line to standard error" },
    },
    .operands = "COMMAND [INITIAL-ARG]... the program (default echo) and its fixed leading arguments; each batch of input items is appended (or substituted via -I).",
    .exit = &.{
        .{ .code = 0, .when = "success" },
        .{ .code = 2, .when = "usage error: a missing or invalid option value" },
        .{ .code = 123, .when = "at least one COMMAND invocation exited non-zero" },
        .{ .code = 126, .when = "COMMAND was found but could not be executed" },
        .{ .code = 127, .when = "COMMAND could not be found" },
    },
    .deviations_from = "GNU findutils xargs",
    .deviations = &.{
        "Usage errors (a bad or missing option value) exit 2, not GNU's 1.",
        "There is no -P (run in parallel), -a FILE (read items from FILE instead of stdin), -d DELIM (custom delimiter), -o, or --show-limits.",
    },
    .examples = &.{
        .{ .cmd = "echo a b c | xargs mkdir", .note = "creates three directories: a b c" },
        .{ .cmd = "find . -name '*.o' -print0 | xargs -0 rm", .note = "NUL-delimited, safe with unusual filenames" },
        .{ .cmd = "ls | xargs -I{} mv {} {}.bak", .note = "rename each item by appending .bak" },
    },
    .see_also = "find (-print0 pairs naturally with -0), env, timeout.",
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn parseCount(s: []const u8) ?usize {
    const v = std.fmt.parseInt(usize, s, 10) catch return null;
    if (v == 0) return null;
    return v;
}

fn splitItems(gpa: std.mem.Allocator, input: []const u8, null_mode: bool) []const []const u8 {
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    if (null_mode) {
        var it = std.mem.splitScalar(u8, input, 0);
        while (it.next()) |piece| {
            if (piece.len == 0 and it.peek() == null) break; // trailing NUL
            items.append(gpa, piece) catch @panic("OOM");
        }
    } else {
        var i: usize = 0;
        while (i < input.len) {
            while (i < input.len and isWs(input[i])) i += 1;
            if (i >= input.len) break;
            const start = i;
            while (i < input.len and !isWs(input[i])) i += 1;
            items.append(gpa, input[start..i]) catch @panic("OOM");
        }
    }
    return items.toOwnedSlice(gpa) catch @panic("OOM");
}

fn replaceAll(gpa: std.mem.Allocator, hay: []const u8, needle: []const u8, repl: []const u8) []const u8 {
    if (needle.len == 0) return hay;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < hay.len) {
        if (i + needle.len <= hay.len and std.mem.eql(u8, hay[i..][0..needle.len], needle)) {
            out.appendSlice(gpa, repl) catch @panic("OOM");
            i += needle.len;
        } else {
            out.append(gpa, hay[i]) catch @panic("OOM");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

const Runner = struct {
    ctx: *Ctx,
    child_in: sys.Fd,
    trace: bool,
    any_failed: bool = false,

    /// Runs one composed argv. Returns an exit code to bail out with, or null to
    /// continue with the next batch.
    fn runBatch(self: *Runner, argv: []const []const u8) ?u8 {
        if (self.trace) {
            var line: std.ArrayListUnmanaged(u8) = .empty;
            for (argv, 0..) |a, i| {
                if (i > 0) line.append(self.ctx.gpa, ' ') catch @panic("OOM");
                line.appendSlice(self.ctx.gpa, a) catch @panic("OOM");
            }
            line.append(self.ctx.gpa, '\n') catch @panic("OOM");
            sys.writeAll(self.ctx.stderr, line.items) catch {};
        }
        const blob = proc.argvBlob(self.ctx.gpa, argv) catch @panic("OOM");
        switch (proc.spawnWait(blob, self.child_in, self.ctx.stdout, self.ctx.stderr)) {
            .status => |st| {
                if (st != 0) self.any_failed = true;
                return null;
            },
            .spawn_err => |e| {
                self.ctx.errPrint("xargs: {s}: cannot run command\n", .{argv[0]});
                return if (e == error.ENOENT) 127 else 126;
            },
            .wait_err => {
                self.any_failed = true;
                return null;
            },
        }
    }
};

pub fn run(ctx: *Ctx) u8 {
    const args = ctx.args[1..];

    var null_mode = false;
    var max_args: ?usize = null;
    var max_bytes: ?usize = null;
    var replace: ?[]const u8 = null;
    var no_run_if_empty = false;
    var trace = false;
    var eof_marker: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--help")) {
            cli.renderHelp(ctx, "xargs", help_doc);
            return 0;
        }
        if (eq(a, "--version")) {
            ctx.outPrint("xargs 0.1.0\n", .{});
            return 0;
        }
        if (eq(a, "-0") or eq(a, "--null")) {
            null_mode = true;
            continue;
        }
        if (eq(a, "-r") or eq(a, "--no-run-if-empty")) {
            no_run_if_empty = true;
            continue;
        }
        if (eq(a, "-t") or eq(a, "--verbose") or eq(a, "-p")) {
            trace = true;
            continue;
        }
        if (eq(a, "-n") or eq(a, "-L")) {
            i += 1;
            if (i >= args.len) {
                ctx.errPrint("xargs: option '{s}' requires a value\n", .{a});
                return 2;
            }
            max_args = parseCount(args[i]) orelse {
                ctx.errPrint("xargs: invalid number '{s}'\n", .{args[i]});
                return 2;
            };
            continue;
        }
        if (a.len > 2 and (std.mem.startsWith(u8, a, "-n") or std.mem.startsWith(u8, a, "-L"))) {
            max_args = parseCount(a[2..]) orelse {
                ctx.errPrint("xargs: invalid number '{s}'\n", .{a[2..]});
                return 2;
            };
            continue;
        }
        if (eq(a, "-s")) {
            i += 1;
            if (i >= args.len) {
                ctx.errPrint("xargs: option '-s' requires a value\n", .{});
                return 2;
            }
            max_bytes = parseCount(args[i]) orelse {
                ctx.errPrint("xargs: invalid number '{s}'\n", .{args[i]});
                return 2;
            };
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-s")) {
            max_bytes = parseCount(a[2..]) orelse {
                ctx.errPrint("xargs: invalid number '{s}'\n", .{a[2..]});
                return 2;
            };
            continue;
        }
        if (eq(a, "-I")) {
            i += 1;
            if (i >= args.len) {
                ctx.errPrint("xargs: option '-I' requires a value\n", .{});
                return 2;
            }
            replace = args[i];
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-I")) {
            replace = a[2..];
            continue;
        }
        if (eq(a, "-E")) {
            i += 1;
            if (i >= args.len) {
                ctx.errPrint("xargs: option '-E' requires a value\n", .{});
                return 2;
            }
            eof_marker = args[i];
            continue;
        }
        if (a.len > 2 and std.mem.startsWith(u8, a, "-E")) {
            eof_marker = a[2..];
            continue;
        }
        if (eq(a, "-e")) continue; // bare -e: no default EOF marker to disable, no-op
        if (a.len > 2 and std.mem.startsWith(u8, a, "-e")) {
            eof_marker = a[2..];
            continue;
        }
        if (eq(a, "--")) {
            i += 1;
            break;
        }
        break; // COMMAND starts here (dash-prefixed unknowns included, GNU-compatible enough)
    }

    const command_and_args = args[i..];
    var base: std.ArrayListUnmanaged([]const u8) = .empty;
    if (command_and_args.len == 0) {
        base.append(ctx.gpa, "echo") catch @panic("OOM");
    } else {
        for (command_and_args) |a| base.append(ctx.gpa, a) catch @panic("OOM");
    }

    const input = textio.readAll(ctx.gpa, ctx.stdin) catch "";
    var items = splitItems(ctx.gpa, input, null_mode);
    if (eof_marker) |marker| {
        for (items, 0..) |item, idx| {
            if (std.mem.eql(u8, item, marker)) {
                items = items[0..idx];
                break;
            }
        }
    }

    if (items.len == 0 and no_run_if_empty) return 0;

    const child_in = sys.open("/dev/null", .{ .read = true }) catch ctx.stdin;
    defer if (child_in != ctx.stdin) sys.close(child_in);

    var runner = Runner{ .ctx = ctx, .child_in = child_in, .trace = trace };

    if (replace) |needle| {
        // -I: one item per invocation, replace in every initial arg (not the command).
        if (items.len == 0) {
            // With no input there is nothing to substitute; run once verbatim
            // (matches the no-item non -r behavior below).
            if (runner.runBatch(base.items)) |rc| return rc;
        }
        for (items) |item| {
            var argv: std.ArrayListUnmanaged([]const u8) = .empty;
            argv.append(ctx.gpa, base.items[0]) catch @panic("OOM");
            for (base.items[1..]) |a| {
                argv.append(ctx.gpa, replaceAll(ctx.gpa, a, needle, item)) catch @panic("OOM");
            }
            if (runner.runBatch(argv.items)) |rc| return rc;
        }
        return if (runner.any_failed) 123 else 0;
    }

    // Batch by -n and/or -s. Base cost: every fixed argv piece + its NUL separator.
    var base_bytes: usize = 0;
    for (base.items) |a| base_bytes += a.len + 1;

    var idx: usize = 0;
    var ran_any = false;
    while (idx < items.len or (!ran_any and items.len == 0)) {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        for (base.items) |a| argv.append(ctx.gpa, a) catch @panic("OOM");
        var cur_bytes = base_bytes;
        var cur_n: usize = 0;
        while (idx < items.len) {
            const item = items[idx];
            if (max_args) |n| {
                if (cur_n >= n) break;
            }
            if (max_bytes) |s| {
                if (cur_n > 0 and cur_bytes + item.len + 1 > s) break;
            }
            argv.append(ctx.gpa, item) catch @panic("OOM");
            cur_bytes += item.len + 1;
            cur_n += 1;
            idx += 1;
        }
        ran_any = true;
        if (runner.runBatch(argv.items)) |rc| return rc;
        if (items.len == 0) break;
    }

    return if (runner.any_failed) 123 else 0;
}
