//! `true` -- DESIGN.md §1: leading --help/-h/--version only; always
//! exits 0 otherwise (no diagnostics for anything else).

const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "do nothing, successfully",
    .synopsis = &.{"true [ARGUMENT]..."},
    .description =
    \\Does nothing and exits with status 0. All ARGUMENTs are ignored. (Most shells
    \\provide a `true` builtin with the same behavior; this is the standalone command.)
    ,
    .options_note = "true takes no options. --help/-h and --version are recognized only as the first argument.",
    .exit = &.{.{ .code = 0, .when = "always" }},
    .see_also = "false (do nothing, unsuccessfully).",
};

pub fn run(ctx: *Ctx) u8 {
    _ = cli.leadingHelp(ctx, "true", "0.1.0", help_doc);
    return 0;
}
