//! `false` -- DESIGN.md §1: leading --help/-h (exit 0) / --version
//! (exit 0), scanning stops at `--`; parser is NOT run over operands. Exit 1
//! otherwise. Deviation from GNU (documented in the matrix): GNU ignores everything
//! including --help; this twin honors it only as the first argument.

const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "do nothing, unsuccessfully",
    .synopsis = &.{"false [ARGUMENT]..."},
    .description =
    \\Does nothing and exits with status 1. All ARGUMENTs are ignored. (Most shells
    \\provide a `false` builtin with the same behavior; this is the standalone
    \\command.)
    ,
    .options_note = "false takes no options. --help/-h and --version are recognized only as the first argument.",
    .exit = &.{.{ .code = 1, .when = "always" }},
    .deviations_from = "GNU coreutils false",
    .deviations = &.{
        "GNU false ignores everything, including --help/--version; this twin honors them, but only as the very first argument -- `false --help` prints help (exit 0), while `false -- --help` still exits 1.",
    },
    .see_also = "true (do nothing, successfully).",
};

pub fn run(ctx: *Ctx) u8 {
    if (cli.leadingHelp(ctx, "false", "0.1.0", help_doc)) return 0;
    return 1;
}
