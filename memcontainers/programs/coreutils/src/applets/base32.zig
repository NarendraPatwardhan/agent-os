//! `base32` -- DESIGN.md §1 "base32/base64/basenc" (uucore
//! `base_common`). Thin CLI wrapper: parses flags, delegates all I/O to
//! `engines/codec.zig`'s `runBaseIO` (shared with `base64`/`basenc` there, since
//! applets may not import each other -- DESIGN.md §3).
//!
//! Flags: `-d/--decode` (alias `-D`), `-i/--ignore-garbage`, `-w/--wrap=COLS`
//! (default 76, `0` disables); one optional FILE (`-` = stdin, default stdin).
//! Extra operand -> `error: extra operand '{op}'`; nonexistent FILE ->
//! `{file}: No such file or directory`; invalid `-w` value ->
//! `invalid wrap size: '{value}'`. Decode error -> `error: invalid input` (stderr),
//! exit 1, AFTER writing whatever prefix was already decodable (see codec.zig's
//! module doc). All exit codes here are 1 (uutils-family clap convention, not the
//! cli.zig-generic 2 -- see DESIGN.md §2).

const std = @import("std");
const cli = @import("../core/cli.zig");
const codec = @import("../engines/codec.zig");
const Ctx = @import("../ctx.zig").Ctx;

pub const spec = cli.Spec{
    .name = "base32",
    .flags = &.{
        cli.flagOpt('d', "decode", "decode data"),
        cli.flagOpt('D', null, "decode data (alias for -d)"),
        cli.flagOpt('i', "ignore-garbage", "when decoding, ignore non-alphabetic characters"),
        cli.valueOpt('w', "wrap", "wrap encoded lines after COLS character (default 76, 0 to disable)"),
    },
    .help = .{
        .summary = "base32 encode or decode data and print to standard output",
        .synopsis = &.{"base32 [OPTION]... [FILE]"},
        .description =
        \\Encodes FILE (or standard input, with no FILE or FILE `-`) using the RFC 4648
        \\base32 alphabet and writes the result to standard output; `-d` reverses the
        \\operation. Encoded output is wrapped to 76 columns by default (`-w COLS`
        \\changes this, `-w 0` disables wrapping entirely).
        \\
        \\Decoding is strict: input must be validly padded base32, and any unused
        \\low-order bits in the final symbol must be zero, or decoding fails with
        \\"error: invalid input" -- `-i`/`--ignore-garbage` first strips any character
        \\outside the base32 alphabet (newlines included) before decoding.
        ,
        .operands = "FILE (optional); \"-\" or an omitted FILE means standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "FILE could not be opened, --wrap's argument was not a valid number, or (with -d) the input was not valid base32 (usage/parse errors also exit 1 here, not 2 -- see DEVIATIONS)" },
        },
        .deviations_from = "uutils coreutils 0.9.0",
        .deviations = &.{
            "Parse errors (unrecognized option, extra operand) print only the single diagnostic line; the oracle's second line (\"Try '--help' for more information.\"), which embeds a host build path, is not reproduced.",
        },
        .examples = &.{
            .{ .cmd = "printf foobar | base32", .note = "MZXW6YTBOI======" },
            .{ .cmd = "base32 -d <<< MZXW6YTBOI======", .note = "foobar" },
        },
        .see_also = "base64, basenc (selectable encodings incl. base16/z85/base58).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = 1 },
};

pub fn runFormat(ctx: *Ctx, comptime format: codec.Format) u8 {
    const prog = ctx.args[0];
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return if (c == 2) 1 else c,
        .ok => |mm| mm,
    };

    const decode = m.has("decode") or m.has("D");
    const ignore_garbage = m.has("ignore-garbage");
    var wrap_cols: ?usize = null;
    if (m.value("wrap")) |w| {
        wrap_cols = std.fmt.parseInt(usize, w, 10) catch {
            ctx.errPrint("{s}: invalid wrap size: '{s}'\n", .{ prog, w });
            return 1;
        };
    }

    const files = m.positionalSlice();
    const filename: ?[]const u8 = if (files.len == 0) null else files[0];
    return codec.runBaseIO(ctx, prog, format, decode, ignore_garbage, wrap_cols, filename);
}

pub fn run(ctx: *Ctx) u8 {
    return runFormat(ctx, .base32);
}
