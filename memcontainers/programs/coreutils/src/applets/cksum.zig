//! `cksum` -- DESIGN.md §1 "cksum + hash family". Default (no
//! `-a`) is the legacy POSIX CRC (`ALGO LEN FILE` text, exactly `sum`'s legacy
//! formats for `-a sysv`/`-a bsd`). Non-legacy algorithms default to TAGGED output
//! (`ALGO (FILE) = DIGEST`) -- the opposite default from the standalone `*sum` tools.
//!
//! Flags: `-a/--algorithm` (17 values, see `hash.CLI_ALGO_NAMES`; unknown value
//! reproduces clap's exact multi-line "invalid value" message, verified against the
//! oracle), `-l/--length` (bits; required for `-a sha2/sha3`, optional for
//! blake2b/blake3/shake128/shake256, rejected otherwise), `--tag`/`--untagged` (last
//! flag wins when both given -- clap `overrides_with`, confirmed non-symmetric via the
//! oracle: `-a md5 --untagged --tag` tags, `--tag --untagged` doesn't), `-b`/`-t`
//! (hidden, untagged-mode reading-flag char only, same last-wins rule), `--raw`
//! (exclusive of `--base64`: "the argument '--raw' cannot be used with '--base64'"),
//! `--base64`, `-c/--check` (+ the same warn/status/quiet/ignore-missing/strict matrix
//! as the `*sum` tools; legacy algorithms are rejected: "--check is not supported with
//! --algorithm={bsd,sysv,crc,crc32b}"), `-z/--zero`, `--debug` (hardware capability
//! chatter -- DESIGN.md §2 explicitly exempts this from parity; accepted as a no-op
//! here). FILE... default `-`.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const hash = @import("../engines/hash.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "cksum",
    .flags = &.{
        cli.valueOpt('a', "algorithm", "select the digest type to use"),
        cli.valueOpt('l', "length", "digest length in bits"),
        cli.flagOpt(null, "tag", "create a BSD style checksum"),
        cli.flagOpt(null, "untagged", "create a reversed style checksum"),
        cli.flagOpt('b', "binary", "read in binary mode"),
        cli.flagOpt('t', "text", "read in text mode"),
        cli.flagOpt(null, "raw", "emit a raw binary digest"),
        cli.flagOpt(null, "base64", "emit base64-encoded digests"),
        cli.flagOpt('c', "check", "read checksums from the FILEs and check them"),
        cli.flagOpt('w', "warn", "warn about improperly formatted checksum lines"),
        cli.flagOpt(null, "status", "don't output anything, status code shows success"),
        cli.flagOpt(null, "quiet", "don't print OK for each successfully verified file"),
        cli.flagOpt(null, "ignore-missing", "don't fail or report status for missing files"),
        cli.flagOpt(null, "strict", "exit non-zero for improperly formatted checksum lines"),
        cli.flagOpt('z', "zero", "end each output line with NUL, not newline"),
        cli.flagOpt(null, "debug", "print CPU hardware capability detection info"),
    },
    .help = .{
        .summary = "compute or check file checksums, with a selectable digest algorithm",
        .synopsis = &.{ "cksum [OPTION]... [FILE]...", "cksum -c [OPTION]... [FILE]..." },
        .description =
        \\Prints a checksum and byte count for each FILE (or standard input, with no
        \\FILE or FILE `-`). With no `-a`, this is the legacy POSIX CRC (`CRC LEN
        \\FILE`), the same algorithm as `-a bsd`/`-a sysv`'s formats but with its own
        \\framing. `-a` selects one of 17 digests instead: the legacy
        \\`sysv`/`bsd`/`crc`/`crc32b` formats, or a real cryptographic/non-cryptographic
        \\digest --
        \\`md5`, `sha1`, `sha2`/`sha224`/`sha256`/`sha384`/`sha512`, `sha3`, `sm3`,
        \\`blake2b`, `blake3`, `shake128`, `shake256`. `sha2`/`sha3` require an explicit
        \\`-l/--length` (224/256/384/512); `blake2b`/`blake3`/`shake128`/`shake256`
        \\accept an optional one.
        \\
        \\Non-legacy algorithms default to TAGGED output, `ALGO (FILE) = DIGEST` -- the
        \\opposite default from the standalone `md5sum`/`sha256sum`/... tools, which
        \\default to untagged. `--tag`/`--untagged` switch explicitly (the last one
        \\given wins); `--raw` emits the raw digest bytes instead (only with a single
        \\FILE); `--base64` encodes the digest in base64 instead of hex.
        \\
        \\`-c`/`--check` re-verifies checksums read from FILE (a checksum list, not
        \\data) instead of computing new ones; it is rejected for the legacy algorithms
        \\(`bsd`/`sysv`/`crc`/`crc32b`).
        ,
        .operands = "FILE... (default -, meaning standard input); with -c, each FILE is a checksum list to verify rather than data to hash.",
        .exit = &.{
            .{ .code = 0, .when = "success (or, with -c, every listed checksum verified)" },
            .{ .code = 1, .when = "an invalid argument (bad --algorithm/--length value, --raw with multiple files, an option meaningless outside -c mode), a file could not be read, or (with -c) a checksum mismatch, missing file, or malformed line -- usage/parse errors also exit 1 here, not 2" },
        },
        .deviations_from = "uutils coreutils 0.9.0",
        .examples = &.{
            .{ .cmd = "cksum file.txt", .note = "legacy CRC + byte count, no -a" },
            .{ .cmd = "cksum -a md5 file.txt", .note = "MD5 (file.txt) = <hex digest> -- tagged by default" },
            .{ .cmd = "cksum -c sums.md5", .note = "re-verify a checksum list" },
        },
        .see_also = "md5sum, sha1sum, sha256sum, sha512sum, b2sum (standalone, untagged-by-default equivalents); sum (legacy-only checksum).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// Scans raw argv (not `cli.Matches`, which has no ordering) for the last of two
/// mutually-overriding boolean flags, matching clap's `overrides_with` semantics.
fn lastBoolFlag(args: []const [:0]const u8, on_forms: []const []const u8, off_forms: []const []const u8, default: bool) bool {
    var result = default;
    for (args) |arg| {
        for (on_forms) |f| {
            if (std.mem.eql(u8, arg, f)) result = true;
        }
        for (off_forms) |f| {
            if (std.mem.eql(u8, arg, f)) result = false;
        }
    }
    return result;
}

fn checkOnlyFlag(m: *const cli.Matches, prog: []const u8, ctx: *Ctx, check: bool, name: []const u8) ?u8 {
    if (m.has(name) and !check) {
        ctx.errPrint("{s}: the --{s} option is meaningful only when verifying checksums\n", .{ prog, name });
        return 1;
    }
    return null;
}

pub fn run(ctx: *Ctx) u8 {
    const prog = ctx.args[0];
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return if (c == 2) 1 else c,
        .ok => |mm| mm,
    };

    if (m.has("raw") and m.has("base64")) {
        ctx.errPrint("error: the argument '--raw' cannot be used with '--base64'\n\nFor more information, try '--help'.\n", .{});
        return 1;
    }

    const check = m.has("check");
    if (checkOnlyFlag(&m, prog, ctx, check, "warn")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "status")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "quiet")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "ignore-missing")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "strict")) |rc| return rc;

    var cli_algo: ?hash.CliAlgo = null;
    if (m.value("algorithm")) |a| {
        cli_algo = hash.cliAlgoFromString(a) orelse {
            ctx.errPrint(
                "error: invalid value '{s}' for '--algorithm <ALGORITHM>'\n\n  [possible values: {s}]\n\nFor more information, try '--help'.\n",
                .{ a, joinedAlgoNames() },
            );
            return 1;
        };
    }

    const untagged_flag = m.has("untagged");
    const text_flag = m.has("text");
    if (text_flag and !untagged_flag) {
        ctx.errPrint("{s}: --text mode is only supported with --untagged\n", .{prog});
        return 1;
    }

    const tag = lastBoolFlag(ctx.args, &.{"--tag"}, &.{"--untagged"}, true);
    const binary = lastBoolFlag(ctx.args, &.{ "-b", "--binary" }, &.{ "-t", "--text" }, false);
    const zero = m.has("zero");

    var files_buf: [256][]const u8 = undefined;
    var n: usize = 0;
    for (m.positionalSlice()) |f| {
        if (n < files_buf.len) {
            files_buf[n] = f;
            n += 1;
        }
    }
    if (n == 0) {
        files_buf[0] = "-";
        n = 1;
    }
    const files = files_buf[0..n];

    if (check) {
        if (cli_algo) |ca| {
            if (hash.cliAlgoIsLegacy(ca)) {
                ctx.errPrint("{s}: --check is not supported with --algorithm={s}\n", .{ prog, "{bsd,sysv,crc,crc32b}" });
                return 1;
            }
        }
        if (m.has("tag")) {
            ctx.errPrint("{s}: the --tag option is meaningless when verifying checksums\n", .{prog});
            return 1;
        }
        if (binary or text_flag) {
            ctx.errPrint("{s}: the --binary and --text options are meaningless when verifying checksums\n", .{prog});
            return 1;
        }
        const opts = hash.CheckOptions{
            .ignore_missing = m.has("ignore-missing"),
            .strict = m.has("strict"),
            .verbose = hash.checkVerboseFromFlags(m.has("status"), m.has("quiet"), m.has("warn")),
        };
        return hash.checkFiles(ctx, prog, cli_algo, null, opts, files);
    }

    const algo_kind = cli_algo orelse .crc;
    var bit_length: ?usize = null;
    if (m.value("length")) |lstr| {
        switch (algo_kind) {
            .blake2b, .blake3 => switch (hash.parseBlakeLength(algo_kind == .blake2b, lstr)) {
                .ok => |v| bit_length = v,
                .invalid_number => {
                    ctx.errPrint("{s}: invalid length: '{s}'\n", .{ prog, lstr });
                    return 1;
                },
                .not_multiple_of_8 => {
                    ctx.errPrint("{s}: invalid length: '{s}'\n", .{ prog, lstr });
                    ctx.errPrint("{s}: length is not a multiple of 8\n", .{prog});
                    return 1;
                },
                .too_big => {
                    ctx.errPrint("{s}: invalid length: '{s}'\n", .{ prog, lstr });
                    ctx.errPrint("{s}: maximum digest length for 'BLAKE2b' is 512 bits\n", .{prog});
                    return 1;
                },
            },
            .shake128, .shake256 => {
                const v = std.fmt.parseInt(usize, lstr, 10) catch {
                    ctx.errPrint("{s}: invalid length: '{s}'\n", .{ prog, lstr });
                    return 1;
                };
                if (v != 0) bit_length = v;
            },
            .sha2, .sha3 => {
                const v = std.fmt.parseInt(usize, lstr, 10) catch null;
                if (v == null or hash.shaLenFromBits(v.?) == null) {
                    ctx.errPrint("{s}: invalid length: '{s}'\n", .{ prog, lstr });
                    ctx.errPrint("{s}: digest length for '{s}' must be 224, 256, 384, or 512\n", .{ prog, if (algo_kind == .sha2) "SHA2" else "SHA3" });
                    return 1;
                }
                bit_length = v.?;
            },
            else => {
                const v = std.fmt.parseInt(usize, lstr, 10) catch 1;
                if (v != 0) {
                    ctx.errPrint("{s}: --length is only supported with --algorithm blake2b, sha2, or sha3\n", .{prog});
                    return 1;
                }
            },
        }
    }

    const sized = hash.resolveSized(algo_kind, bit_length) catch |e| {
        switch (e) {
            error.LengthRequiredForSha => ctx.errPrint("{s}: --algorithm={s} requires specifying --length 224, 256, 384, or 512\n", .{ prog, @tagName(algo_kind) }),
            else => ctx.errPrint("{s}: invalid length\n", .{prog}),
        }
        return 1;
    };

    const fmt: hash.OutputFormat = if (m.has("raw"))
        .raw
    else if (sized.isLegacy())
        .legacy
    else if (tag)
        .{ .tagged = if (m.has("base64")) .base64 else .hex }
    else
        .{ .untagged = .{ .fmt = if (m.has("base64")) .base64 else .hex, .binary = binary } };

    return hash.computeAndPrint(ctx, prog, sized, fmt, zero, files);
}

fn joinedAlgoNames() []const u8 {
    return "sysv, bsd, crc, crc32b, md5, sha1, sha2, sha3, blake2b, sm3, sha224, sha256, sha384, sha512, blake3, shake128, shake256";
}
