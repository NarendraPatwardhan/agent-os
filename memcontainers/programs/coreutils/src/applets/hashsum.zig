//! md5sum/sha1sum/sha256sum/sha512sum/b2sum -- docs/analysis/uutils-applets.md "cksum +
//! hash family". One implementation (per uutils 0.9.0: these are ~6-line wrappers
//! around `uu_checksum_common::{declare_standalone, standalone_with_length_main}`),
//! parameterized per algorithm via comptime-generated `run` wrappers (registry.zig
//! wires each name to its own thin export, since the registry's `run` slot takes only
//! `*Ctx` -- see registry.zig's `test`/`[` precedent for sharing one impl, extended
//! here to sharing one impl PARAMETERIZED by algo).
//!
//! Flags (`uu_checksum_common::{default_checksum_app, standalone_checksum_app[_with_length]}`):
//! `-b/--binary` (hidden, sets untagged flag char to `*`), `-c/--check` (+ `-w/--warn`
//! `--status` `--quiet` `--ignore-missing` `--strict`), `--tag` (BSD-style tagged
//! output), `-t/--text` (hidden except on... actually shown here, default untagged
//! reading-mode char ` `), `-z/--zero` (NUL line ending, disables filename escaping),
//! FILE... (default `-`). b2sum adds `-l/--length` (bits, multiple of 8, <=512).
//!
//! Every non-check flag combined with `-c` (except `-b`/`-t`, see below) is an error:
//! "the --{flag} option is meaningful only when verifying checksums" (exit 1). `--tag`
//! together with `-c` is "the --tag option is meaningless when verifying checksums";
//! `-b`/`-t` together with `-c` is "the --binary and --text options are meaningless
//! when verifying checksums". `--text` together with `--tag` (compute mode) is
//! "--tag does not support --text mode". All exact strings verified against the
//! oracle; clap-parse-error exit code is 1 here (not the cli.zig-generic 2 -- see
//! docs/parity-ledger.md: this is a verified, deliberate uutils-family convention).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const hash = @import("../engines/hash.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "hashsum",
    .flags = &.{
        cli.flagOpt('b', "binary", "read in binary mode"),
        cli.flagOpt('c', "check", "read checksums from the FILEs and check them"),
        cli.flagOpt('w', "warn", "warn about improperly formatted checksum lines"),
        cli.flagOpt(null, "status", "don't output anything, status code shows success"),
        cli.flagOpt(null, "quiet", "don't print OK for each successfully verified file"),
        cli.flagOpt(null, "ignore-missing", "don't fail or report status for missing files"),
        cli.flagOpt(null, "strict", "exit non-zero for improperly formatted checksum lines"),
        cli.flagOpt(null, "tag", "create a BSD style checksum"),
        cli.flagOpt('t', "text", "read in text mode (default)"),
        cli.flagOpt('z', "zero", "end each output line with NUL, not newline"),
        cli.valueOpt('l', "length", "digest length in bits (BLAKE2b only)"),
    },
    .help = .{
        .summary = "compute and check message digests (algorithm fixed by the invoked command name)",
        .synopsis = &.{
            "md5sum|sha1sum|sha256sum|sha512sum|b2sum [OPTION]... [FILE]...",
            "md5sum|sha1sum|sha256sum|sha512sum|b2sum -c [OPTION]... [FILE]...",
        },
        .description =
        \\Computes and prints a message digest for each FILE (or standard input, with
        \\no FILE or FILE `-`), one line per file. The digest algorithm is fixed by the
        \\name this program is invoked as: `md5sum` (MD5), `sha1sum` (SHA-1), `sha256sum`
        \\(SHA-256), `sha512sum` (SHA-512), or `b2sum` (BLAKE2b, 512 bits by default,
        \\`-l/--length` narrows it -- the only one of these five that accepts `-l`).
        \\One shared implementation backs all five names; see `cksum` for a single
        \\command that picks the algorithm dynamically via `-a`.
        \\
        \\Default output is untagged: `DIGEST` then two spaces then FILE (a single
        \\space then `*` before FILE in `-b`/binary-read mode instead). `--tag` switches to BSD-style tagged
        \\output, `ALGO (FILE) = DIGEST`, and cannot be combined with `-t`/`--text`.
        \\With `-c`, FILE is instead read as a list of previously computed checksums
        \\(tagged or untagged) and each is re-verified against the named file's current
        \\contents.
        ,
        .operands = "FILE... (default -, meaning standard input); with -c, each FILE is a checksum list to verify rather than data to hash.",
        .exit = &.{
            .{ .code = 0, .when = "success (or, with -c, every listed checksum verified)" },
            .{ .code = 1, .when = "an unrecognized option or invalid argument, a file could not be read, or (with -c) a checksum mismatch, missing file, or malformed line -- usage/parse errors also exit 1 here, not 2" },
        },
        .deviations_from = "uutils coreutils 0.9.0",
        .deviations = &.{
            "--help and any cli.zig-generated parse-error diagnostic (e.g. an unrecognized option) always name the shared binary \"hashsum\", never the invoked command name (md5sum/sha1sum/sha256sum/sha512sum/b2sum) -- these five names share one underlying CLI spec. Diagnostics hand-written by this applet (e.g. \"the --warn option is meaningful only when verifying checksums\") DO use the invoked name correctly.",
        },
        .examples = &.{
            .{ .cmd = "md5sum file.txt", .note = "<hex digest>  file.txt -- untagged by default" },
            .{ .cmd = "sha256sum --tag file.txt", .note = "SHA256 (file.txt) = <hex digest>" },
            .{ .cmd = "md5sum -c sums.md5", .note = "re-verify a checksum list" },
        },
        .see_also = "cksum (one command, -a picks the algorithm, tagged by default); sum (legacy-only checksum).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

fn checkOnlyFlag(m: *const cli.Matches, prog: []const u8, ctx: *Ctx, check: bool, name: []const u8) ?u8 {
    if (m.has(name) and !check) {
        ctx.errPrint("{s}: the --{s} option is meaningful only when verifying checksums\n", .{ prog, name });
        return 1;
    }
    return null;
}

fn runStandalone(ctx: *Ctx, comptime algo: hash.CliAlgo, comptime has_length: bool) u8 {
    const prog = ctx.args[0];
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return if (c == 2) 1 else c, // uutils-family clap errors exit 1
        .ok => |mm| mm,
    };

    const check = m.has("check");
    if (checkOnlyFlag(&m, prog, ctx, check, "warn")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "status")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "quiet")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "ignore-missing")) |rc| return rc;
    if (checkOnlyFlag(&m, prog, ctx, check, "strict")) |rc| return rc;

    const binary = m.has("binary");
    const text = m.has("text");
    const tag = m.has("tag");
    const zero = m.has("zero");

    if (text and tag) {
        ctx.errPrint("{s}: --tag does not support --text mode\n", .{prog});
        return 1;
    }

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
        if (tag) {
            ctx.errPrint("{s}: the --tag option is meaningless when verifying checksums\n", .{prog});
            return 1;
        }
        if (binary or text) {
            ctx.errPrint("{s}: the --binary and --text options are meaningless when verifying checksums\n", .{prog});
            return 1;
        }
        const opts = hash.CheckOptions{
            .ignore_missing = m.has("ignore-missing"),
            .strict = m.has("strict"),
            .verbose = hash.checkVerboseFromFlags(m.has("status"), m.has("quiet"), m.has("warn")),
        };
        return hash.checkFiles(ctx, prog, algo, null, opts, files);
    }

    var bit_length: ?usize = null;
    if (has_length) {
        if (m.value("length")) |lstr| {
            switch (hash.parseBlakeLength(true, lstr)) {
                .ok => |n2| bit_length = n2,
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
            }
        }
    }

    const sized = hash.resolveSized(algo, bit_length) catch {
        ctx.errPrint("{s}: invalid length\n", .{prog});
        return 1;
    };
    const fmt: hash.OutputFormat = if (tag)
        .{ .tagged = .hex }
    else
        .{ .untagged = .{ .fmt = .hex, .binary = binary } };
    return hash.computeAndPrint(ctx, prog, sized, fmt, zero, files);
}

pub fn runMd5(ctx: *Ctx) u8 {
    return runStandalone(ctx, .md5, false);
}
pub fn runSha1(ctx: *Ctx) u8 {
    return runStandalone(ctx, .sha1, false);
}
pub fn runSha256(ctx: *Ctx) u8 {
    return runStandalone(ctx, .sha256, false);
}
pub fn runSha512(ctx: *Ctx) u8 {
    return runStandalone(ctx, .sha512, false);
}
pub fn runB2sum(ctx: *Ctx) u8 {
    return runStandalone(ctx, .blake2b, true);
}
