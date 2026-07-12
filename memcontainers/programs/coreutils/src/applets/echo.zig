//! `echo` -- DESIGN.md §1: hand-parsed (clap for help only). Leading
//! flag run of `-n`/`-e`/`-E` (clustered, e.g. `-ne`); first non-flag operand ends
//! flag parsing. `--help`/`-h`/`--version` honored only as the first argument.
//! Operands joined by a single space, trailing bare LF unless `-n`. `-e` escapes:
//! `\n \t \r \\ \a \b \f \v \0`(NUL) `\c`(stop everything, incl. trailing LF);
//! unknown escape is emitted verbatim (backslash + char).

const std = @import("std");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "display a line of text",
    .synopsis = &.{"echo [-neE] [STRING]..."},
    .description =
    \\Writes each STRING to standard output, joined by a single space, followed by a
    \\newline (unless -n). -e turns on backslash-escape interpretation in the
    \\STRINGs; -E turns it back off (the default). The flags are recognized only in
    \\a leading run before the first non-flag argument, and may be clustered
    \\(`-ne`); once a non-flag argument appears, flag scanning stops for good.
    ,
    .options = &.{
        .{ .flags = "-n", .desc = "do not output the trailing newline" },
        .{ .flags = "-e", .desc = "interpret backslash escapes in each STRING" },
        .{ .flags = "-E", .desc = "disable backslash-escape interpretation (default)" },
    },
    .operands = "STRING...   text to print, joined by a single space; with none, only the newline is printed (or nothing at all, with -n).",
    .exit = &.{.{ .code = 0, .when = "always" }},
    .deviations_from = "GNU coreutils echo",
    .deviations = &.{
        "--help/-h and --version are honored only as the very first argument (GNU /bin/echo behavior, not the shell builtin); elsewhere they print like any other operand.",
        "Under -e, escapes are \\\\ \\n \\t \\r \\a \\b \\f \\v \\0 (NUL) and \\c (stops all output immediately, including the trailing newline); an unrecognized \\X is emitted verbatim as backslash+X rather than decoded.",
    },
    .examples = &.{
        .{ .cmd = "echo 'hello world'", .note = "prints: hello world" },
        .{ .cmd = "echo -n 'no newline'", .note = "no trailing newline is written" },
        .{ .cmd = "echo -e 'a\\tb\\c'", .note = "prints \"a<TAB>b\" with no trailing newline (\\c stops output)" },
    },
    .see_also = "printf (richer formatting), yes.",
};

fn isEchoFlag(a: []const u8) bool {
    if (a.len < 2 or a[0] != '-') return false;
    for (a[1..]) |c| {
        if (c != 'n' and c != 'e' and c != 'E') return false;
    }
    return true;
}

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "echo", "0.1.0", help_doc)) return 0;

    var no_newline = false;
    var escapes = false;
    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const a = ctx.args[i];
        if (!isEchoFlag(a)) break;
        for (a[1..]) |c| {
            switch (c) {
                'n' => no_newline = true,
                'e' => escapes = true,
                'E' => escapes = false,
                else => unreachable,
            }
        }
    }

    var out = textio.BufOut.init(ctx.stdout);
    var first = true;
    var stopped = false;
    while (i < ctx.args.len and !stopped) : (i += 1) {
        if (!first) out.push(' ') catch return 0;
        first = false;
        const a = ctx.args[i];
        if (!escapes) {
            out.extend(a) catch return 0;
            continue;
        }
        var j: usize = 0;
        while (j < a.len) {
            if (a[j] == '\\' and j + 1 < a.len) {
                const c = a[j + 1];
                switch (c) {
                    'n' => {
                        out.push('\n') catch return 0;
                        j += 2;
                    },
                    't' => {
                        out.push('\t') catch return 0;
                        j += 2;
                    },
                    'r' => {
                        out.push('\r') catch return 0;
                        j += 2;
                    },
                    '\\' => {
                        out.push('\\') catch return 0;
                        j += 2;
                    },
                    'a' => {
                        out.push(0x07) catch return 0;
                        j += 2;
                    },
                    'b' => {
                        out.push(0x08) catch return 0;
                        j += 2;
                    },
                    'f' => {
                        out.push(0x0c) catch return 0;
                        j += 2;
                    },
                    'v' => {
                        out.push(0x0b) catch return 0;
                        j += 2;
                    },
                    '0' => {
                        out.push(0) catch return 0;
                        j += 2;
                    },
                    'c' => {
                        stopped = true;
                        j = a.len;
                    },
                    else => {
                        out.push('\\') catch return 0;
                        out.push(c) catch return 0;
                        j += 2;
                    },
                }
            } else {
                out.push(a[j]) catch return 0;
                j += 1;
            }
        }
    }
    if (!no_newline and !stopped) out.push('\n') catch return 0;
    out.finish() catch {};
    return 0;
}
