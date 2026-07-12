//! `clear` -- DESIGN.md §1: leading --help/-h/--version only (parser
//! not run over operands). Emits a fixed ANSI sequence (cursor home, erase screen,
//! erase scrollback), no trailing LF. Deviation from ncurses: no -x/-T TERM, fixed
//! sequence, not terminfo-driven.

const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const CLEAR_SEQ = "\x1b[H\x1b[2J\x1b[3J";

const help_doc = cli.Help{
    .summary = "clear the terminal screen",
    .synopsis = &.{"clear"},
    .description =
    \\Writes a fixed ANSI escape sequence that moves the cursor to the home
    \\position, erases the visible screen, and erases the terminal's scrollback
    \\buffer. No trailing newline is written. All ARGUMENTs are ignored.
    ,
    .options_note = "clear takes no options. --help/-h and --version are recognized only as the first argument.",
    .exit = &.{.{ .code = 0, .when = "always" }},
    .deviations_from = "ncurses clear",
    .deviations = &.{
        "The sequence is fixed (`ESC[H ESC[2J ESC[3J`), not terminfo-driven -- no -x (don't clear scrollback) and no -T TERM.",
    },
};

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "clear", "0.1.0", help_doc)) return 0;
    ctx.outWrite(CLEAR_SEQ) catch {};
    return 0;
}
