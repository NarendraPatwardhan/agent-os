//! `base64` -- DESIGN.md §1 "base32/base64/basenc". Same shape as
//! `base32` (own copy of the tiny CLI spec -- DESIGN.md §3 forbids applet-to-applet
//! imports, so the identical flag set is duplicated rather than shared) over the
//! standard base64 alphabet; all I/O delegated to `engines/codec.zig`'s `runBaseIO`.

const std = @import("std");
const cli = @import("../core/cli.zig");
const codec = @import("../engines/codec.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "base64",
    .flags = &.{
        cli.flagOpt('d', "decode", "decode data"),
        cli.flagOpt('D', null, "decode data (alias for -d)"),
        cli.flagOpt('i', "ignore-garbage", "when decoding, ignore non-alphabetic characters"),
        cli.valueOpt('w', "wrap", "wrap encoded lines after COLS character (default 76, 0 to disable)"),
    },
    .help = .{
        .summary = "base64 encode or decode data and print to standard output",
        .synopsis = &.{"base64 [OPTION]... [FILE]"},
        .description =
        \\Encodes FILE (or standard input, with no FILE or FILE `-`) using the RFC 4648
        \\base64 alphabet (`+`/`/`, `=` padding) and writes the result to standard
        \\output; `-d` reverses the operation. Encoded output is wrapped to 76 columns
        \\by default (`-w COLS` changes this, `-w 0` disables wrapping entirely).
        \\
        \\Decoding is strict: input must be validly padded base64, and any unused
        \\low-order bits in the final symbol must be zero, or decoding fails with
        \\"error: invalid input" -- `-i`/`--ignore-garbage` first strips any character
        \\outside the base64 alphabet (newlines included) before decoding.
        ,
        .operands = "FILE (optional); \"-\" or an omitted FILE means standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "FILE could not be opened, --wrap's argument was not a valid number, or (with -d) the input was not valid base64 (usage/parse errors also exit 1 here, not 2 -- see DEVIATIONS)" },
        },
        .deviations_from = "uutils coreutils 0.9.0",
        .deviations = &.{
            "Parse errors (unrecognized option, extra operand) print only the single diagnostic line; the oracle's second line (\"Try '--help' for more information.\"), which embeds a host build path, is not reproduced.",
        },
        .examples = &.{
            .{ .cmd = "printf hello | base64", .note = "aGVsbG8=" },
            .{ .cmd = "base64 -d <<< aGVsbG8=", .note = "hello" },
        },
        .see_also = "base32, basenc (selectable encodings incl. base16/z85/base58).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = 1 },
};

pub fn run(ctx: *Ctx) u8 {
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
    return codec.runBaseIO(ctx, prog, .base64, decode, ignore_garbage, wrap_cols, filename);
}
