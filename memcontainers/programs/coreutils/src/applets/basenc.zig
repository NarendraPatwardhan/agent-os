//! `basenc` -- DESIGN.md §1 "base32/base64/basenc". Same
//! `-d/-i/-w` surface as base32/base64 (see those files), plus mutually-exclusive
//! format selectors: `--base64 --base64url --base32 --base32hex --base16
//! --base2lsbf --base2msbf --z85 --base58`. Exactly one is required; none given ->
//! `missing encoding type` (exit 1). If more than one is given, the LAST one wins
//! (clap `overrides_with_all` among the selector group, same last-flag-wins pattern as
//! cksum's `--tag`/`--untagged` -- see that applet's doc comment).

const std = @import("std");
const cli = @import("../core/cli.zig");
const codec = @import("../engines/codec.zig");
const Ctx = @import("../ctx.zig").Ctx;

const FormatSel = struct { flag: []const u8, format: codec.Format };

const SELECTORS = [_]FormatSel{
    .{ .flag = "base64", .format = .base64 },
    .{ .flag = "base64url", .format = .base64url },
    .{ .flag = "base32", .format = .base32 },
    .{ .flag = "base32hex", .format = .base32hex },
    .{ .flag = "base16", .format = .base16 },
    .{ .flag = "base2lsbf", .format = .base2lsbf },
    .{ .flag = "base2msbf", .format = .base2msbf },
    .{ .flag = "z85", .format = .z85 },
    .{ .flag = "base58", .format = .base58 },
};

const spec = cli.Spec{
    .name = "basenc",
    .flags = &.{
        cli.flagOpt('d', "decode", "decode data"),
        cli.flagOpt('D', null, "decode data (alias for -d)"),
        cli.flagOpt('i', "ignore-garbage", "when decoding, ignore non-alphabetic characters"),
        cli.valueOpt('w', "wrap", "wrap encoded lines after COLS character (default 76, 0 to disable)"),
        cli.flagOpt(null, "base64", "same as 'base64' program"),
        cli.flagOpt(null, "base64url", "file- and url-safe base64"),
        cli.flagOpt(null, "base32", "same as 'base32' program"),
        cli.flagOpt(null, "base32hex", "extended hex alphabet base32"),
        cli.flagOpt(null, "base16", "hex encoding"),
        cli.flagOpt(null, "base2lsbf", "bit string with least significant bit first"),
        cli.flagOpt(null, "base2msbf", "bit string with most significant bit first"),
        cli.flagOpt(null, "z85", "ascii85-like encoding"),
        cli.flagOpt(null, "base58", "visually unambiguous base58 encoding"),
    },
    .help = .{
        .summary = "encode or decode data in a selectable format and print to standard output",
        .synopsis = &.{"basenc {--base64|--base64url|--base32|--base32hex|--base16|--base2lsbf|--base2msbf|--z85|--base58} [OPTION]... [FILE]"},
        .description =
        \\Encodes FILE (or standard input, with no FILE or FILE `-`) using the format
        \\selected by one of the format flags, and writes the result to standard
        \\output; `-d` reverses the operation. Exactly one format flag is required
        \\(there is no default); if more than one is given, the LAST one on the command
        \\line wins. `--base64`/`--base32`/`--base16` are the same RFC 4648 alphabets as
        \\the standalone `base64`/`base32` commands (`--base16` is plain hex);
        \\`--base64url`/`--base32hex` are their URL-safe/extended-hex variants;
        \\`--base2lsbf`/`--base2msbf` render each byte as 8 ASCII bits, least- or
        \\most-significant bit first; `--z85` is the ZeroMQ ascii85-like scheme (input
        \\length must be a multiple of 4 bytes); `--base58` is the visually-unambiguous
        \\Bitcoin-style alphabet.
        \\
        \\Encoded output is wrapped to 76 columns by default (`-w COLS` changes this,
        \\`-w 0` disables wrapping); RFC 4648 decoding is strict (unused low-order bits
        \\in the final symbol must be zero) unless relaxed by `-i`/`--ignore-garbage`.
        ,
        .operands = "FILE (optional); \"-\" or an omitted FILE means standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "no format flag was given (\"missing encoding type\"), FILE could not be opened, --wrap's argument was invalid, or (with -d) the input was invalid for the selected format" },
        },
        .deviations_from = "uutils coreutils 0.9.0",
        .deviations = &.{
            "Parse errors (unrecognized option, missing encoding type) print only the single diagnostic line; the oracle's second line (\"Try '--help' for more information.\"), which embeds a host build path, is not reproduced.",
        },
        .examples = &.{
            .{ .cmd = "printf HelloWor | basenc --z85", .note = "nm=QNz=Z<$" },
            .{ .cmd = "printf hello | basenc --base58", .note = "Cn8eVZg" },
            .{ .cmd = "printf ABCD | basenc --base16", .note = "41424344" },
        },
        .see_also = "base32, base64 (the two of these formats that also ship as standalone commands).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = 1 },
};

/// The LAST selector flag present in argv wins (clap `overrides_with_all` among the
/// mutually-exclusive group), matching cksum's `--tag`/`--untagged` precedent.
fn selectFormat(args: []const [:0]const u8) ?codec.Format {
    var chosen: ?codec.Format = null;
    for (args) |arg| {
        for (SELECTORS) |sel| {
            var buf: [16]u8 = undefined;
            const long = std.fmt.bufPrint(&buf, "--{s}", .{sel.flag}) catch continue;
            if (std.mem.eql(u8, arg, long)) chosen = sel.format;
        }
    }
    return chosen;
}

pub fn run(ctx: *Ctx) u8 {
    const prog = ctx.args[0];
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return if (c == 2) 1 else c,
        .ok => |mm| mm,
    };

    const format = selectFormat(ctx.args) orelse {
        ctx.errPrint("{s}: missing encoding type\n", .{prog});
        return 1;
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

    return switch (format) {
        inline else => |f| codec.runBaseIO(ctx, prog, f, decode, ignore_garbage, wrap_cols, filename),
    };
}
