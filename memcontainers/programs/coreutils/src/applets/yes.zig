//! `yes` -- DESIGN.md §1: leading --help/-h/--version only. Line =
//! operands joined by spaces, else "y", plus "\n". Tight write loop, exits 0 the
//! moment the reader closes (broken pipe is normal termination here, not an error).

const std = @import("std");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "repeatedly output a line",
    .synopsis = &.{"yes [STRING]..."},
    .description =
    \\Writes a line to standard output as fast as possible, forever, until the
    \\reader closes the pipe (a broken-pipe write failure is treated as normal
    \\termination, not an error). The line is the STRINGs joined by spaces, or a
    \\single "y" with no arguments, each followed by a newline.
    ,
    .options_note = "yes takes no options. --help/-h and --version are recognized only as the first argument.",
    .operands = "STRING...   words to repeat, joined by a single space; with none, repeats \"y\".",
    .exit = &.{.{ .code = 0, .when = "the output reader closed its end (this is the normal way `yes` stops)" }},
    .deviations_from = "GNU coreutils yes",
    .deviations = &.{
        "Output is buffered through a fixed 4 KiB line buffer; a STRING combination longer than that is silently truncated.",
    },
    .examples = &.{
        .{ .cmd = "yes | head -3", .note = "prints \"y\" three times" },
        .{ .cmd = "yes 'go ahead?'", .note = "repeats \"go ahead?\" until the reader stops" },
    },
    .see_also = "printf, echo.",
};

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "yes", "0.1.0", help_doc)) return 0;

    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    if (ctx.args.len > 1) {
        for (ctx.args[1..], 0..) |a, i| {
            if (i != 0 and n < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
            const room = buf.len -| (n + 1);
            const take = @min(room, a.len);
            @memcpy(buf[n..][0..take], a[0..take]);
            n += take;
        }
    } else {
        buf[0] = 'y';
        n = 1;
    }
    if (n < buf.len) {
        buf[n] = '\n';
        n += 1;
    }
    const line = buf[0..n];

    while (true) {
        ctx.outWrite(line) catch return 0;
    }
}
