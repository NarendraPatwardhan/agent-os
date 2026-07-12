//! `sum` -- DESIGN.md §1 "cksum + hash family". `-r` (default): BSD
//! algorithm, 1024-byte blocks, 5-digit zero-padded fields. `-s`/`--sysv`: System V
//! algorithm, 512-byte blocks, unpadded (width-1) fields. Filenames are appended when
//! more than one FILE is given OR the sole operand isn't `-`/omitted; multi-file mode
//! separates fields from the name with exactly one space (verified against the
//! oracle's `write!(stdout, "{sum:0w$} {blocks:w$} ")` + filename, vs. the no-name
//! `writeln!("{sum:0w$} {blocks:w$}")`). FILE `-` = stdin; default operand is `-`.
//! Errors: directory -> `sum: {name}: Is a directory` exit 2; missing ->
//! `sum: {name}: No such file or directory` exit 2 (note: exit 2, not 1 -- verified
//! against `USimpleError::new(2, ...)` in `sum.rs`, an outlier vs. the rest of this
//! family).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const hash = @import("../engines/hash.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "sum",
    .flags = &.{
        cli.flagOpt('r', null, "use the BSD sum algorithm (default)"),
        cli.flagOpt('s', "sysv", "use System V sum algorithm"),
    },
    .help = .{
        .summary = "compute a legacy 16-bit checksum and block count for files",
        .synopsis = &.{"sum [OPTION]... [FILE]..."},
        .description =
        \\Computes a legacy checksum and block count for each FILE (or standard input,
        \\with no FILE or FILE `-`), using one of two historical algorithms: the BSD
        \\algorithm (`-r`, the default), which uses 1024-byte blocks and prints the
        \\checksum zero-padded to 5 digits; or the System V algorithm (`-s`/`--sysv`),
        \\which uses 512-byte blocks and prints unpadded fields.
        \\
        \\Each line is `CHECKSUM BLOCKS`, plus the FILE name appended whenever more
        \\than one FILE is given, or the sole operand is neither `-` nor omitted; a
        \\single implicit-stdin or explicit `-` operand omits the name.
        ,
        .operands = "FILE... (default -, meaning standard input).",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "an unrecognized option or other usage error" },
            .{ .code = 2, .when = "a FILE could not be opened, or is a directory (this command's own outlier: every other tool in this family uses exit 1 for file-access errors)" },
        },
        .examples = &.{
            .{ .cmd = "sum file.txt", .note = "BSD algorithm, 1024-byte blocks" },
            .{ .cmd = "sum -s file.txt", .note = "System V algorithm, 512-byte blocks" },
        },
        .see_also = "cksum (legacy CRC plus modern digests), md5sum/sha256sum/... (cryptographic digests).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

pub fn run(ctx: *Ctx) u8 {
    const prog = ctx.args[0];
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return if (c == 2) 1 else c,
        .ok => |mm| mm,
    };

    const sysv = m.has("sysv");
    const width: usize = if (sysv) 1 else 5;

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
    const print_names = files.len > 1 or !std.mem.eql(u8, files[0], "-");

    var rc: u8 = 0;
    for (files) |filename| {
        const is_stdin = std.mem.eql(u8, filename, "-");
        if (!is_stdin) {
            const st = sys.stat(filename) catch |e| {
                ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
                rc = 2;
                continue;
            };
            if (st.is_dir) {
                ctx.errPrint("{s}: {s}: Is a directory\n", .{ prog, filename });
                rc = 2;
                continue;
            }
        }
        const fd = if (is_stdin) ctx.stdin else sys.open(filename, .{ .read = true }) catch |e| {
            ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
            rc = 2;
            continue;
        };
        defer if (!is_stdin) sys.close(fd);

        var buf: [8192]u8 = undefined;
        var total: u64 = 0;
        var sum_val: u32 = 0;
        if (sysv) {
            var d = hash.SysvSum{};
            while (true) {
                const nr = sys.read(fd, &buf) catch |e| {
                    ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
                    rc = 2;
                    break;
                };
                if (nr == 0) break;
                d.update(buf[0..nr]);
                total += nr;
            }
            sum_val = d.final();
        } else {
            var d = hash.BsdSum{};
            while (true) {
                const nr = sys.read(fd, &buf) catch |e| {
                    ctx.errPrint("{s}: {s}: {s}\n", .{ prog, filename, sys.strerror(sys.toErrno(e)) });
                    rc = 2;
                    break;
                };
                if (nr == 0) break;
                d.update(buf[0..nr]);
                total += nr;
            }
            sum_val = d.final();
        }
        const blocks: u64 = if (sysv) hash.SysvSum.blocks(total) else hash.BsdSum.blocks(total);

        var sumbuf: [16]u8 = undefined;
        var blkbuf: [16]u8 = undefined;
        const sum_text = hash.padDecimal(&sumbuf, sum_val, width, true);
        const blk_text = hash.padDecimal(&blkbuf, blocks, width, false);
        if (print_names) {
            ctx.outPrint("{s} {s} {s}\n", .{ sum_text, blk_text, filename });
        } else {
            ctx.outPrint("{s} {s}\n", .{ sum_text, blk_text });
        }
    }
    return rc;
}
