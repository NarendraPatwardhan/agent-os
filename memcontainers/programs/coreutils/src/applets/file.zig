//! `file` -- docs/analysis/applets-a-f.md: wrapper over `infer` (magic-byte detection)
//! + hand-written text/shebang/JSON/XML/HTML heuristics, ported wholesale into
//! `engines/magic.zig`. **Note the outlier: clap-error exit is 1, not the usual 2**
//! (matrix: "file which returns 1"). Empty operand list -> `Usage: file [-bi] FILE...`
//! to stderr, exit 1.
//!
//! Flags: `-b`/`--brief` (no filename prefix); `-i`/`--mime-type` (alias `--mime`,
//! handled via a local argv pre-pass since `cli.zig`'s `Opt` supports only one long
//! name per option and it is a shared file other agents are touching -- see the ledger
//! entry for the full ruling).
//!
//! Per file: `-` reads all of stdin into memory and always runs through
//! `magic.identify()` (even if that turns out empty, which resolves to the same
//! "empty"/`inode/x-empty` result magic.zig gives zero-size regular files). Any other
//! operand is `lstat`ed (never dereferenced): symlink -> "symbolic link"/`inode/symlink`
//! (target is never read); directory -> "directory"/`inode/directory`; zero size ->
//! "empty"/`inode/x-empty`; else the first 8192 bytes are read and passed to
//! `magic.identify()`. `-i` selects the mime string over the description for every one
//! of those outcomes (including symlink/dir/empty, each of which already has a
//! well-defined mime string above) -- see ledger for the ambiguity this resolves.
//!
//! Exit 0 if every operand was successfully stat/read (even an unrecognized "data"
//! result is success, matching GNU `file`'s semantics); 1 if any operand could not be
//! stat/opened/read, or on the empty-operand-list usage case. Errors:
//! `file: {path}: {strerror}` (the same convention every other applet uses).

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const magic = @import("../engines/magic.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "file",
    .flags = &.{
        cli.flagOpt('b', "brief", "do not prepend filenames to output"),
        cli.flagOpt('i', "mime-type", "output MIME type strings instead of descriptions"),
    },
    .help = .{
        .summary = "identify the type of each FILE from its magic bytes and structure",
        .synopsis = &.{"file [-bi] FILE..."},
        .description =
        \\Prints a description of each FILE's content, without trusting its name or
        \\extension. `-` reads all of standard input into memory and identifies that;
        \\any other operand is `lstat`-ed (a symlink is NEVER followed or read -- see
        \\DEVIATIONS) and, if it is a regular file with nonzero size, its first 8192
        \\bytes are read and matched against a signature table.
        \\
        \\Detection order: a table of roughly 35 magic-byte signatures (PNG, JPEG, PDF,
        \\Zip, ELF, WebAssembly, ...); a `#!` shebang line (reports the interpreter,
        \\special-casing `env`); JSON/XML/HTML heuristics; a printable/whitespace-only
        \\text scan; otherwise "data". Symlinks, directories, and empty files are
        \\reported directly without reading their target/contents. `-i`/`--mime-type`
        \\(alias `--mime`) prints the matching MIME string instead of the English
        \\description for every one of those outcomes.
        ,
        .operands = "FILE... (at least one required); \"-\" means standard input.",
        .exit = &.{
            .{ .code = 0, .when = "every operand was successfully identified (an unrecognized \"data\" result still counts as success)" },
            .{ .code = 1, .when = "the operand list was empty (\"Usage: file [-bi] FILE...\"), or any operand could not be stat/opened/read (processing continues with the remaining operands)" },
            .{ .code = 2, .when = "an unrecognized option (cli.zig's generic parse-error convention -- a deliberate, documented deviation from this command's own outlier exit-1 rule for every other error)" },
        },
        .deviations_from = "GNU file(1) / libmagic",
        .deviations = &.{
            "No libmagic database: detection uses a fixed ~35-entry byte-signature table plus hand-written shebang/JSON/XML/HTML/text heuristics, so far fewer file types are recognized than real file(1).",
            "Symbolic links are never dereferenced: every symlink operand reports \"symbolic link\"/`inode/symlink`, whereas real file(1) follows the link and describes its target by default (its `-h`/`--no-dereference` flag, not implemented here, is what would produce this port's behavior in the real tool).",
            "-i/--mime-type prints only the bare MIME type (e.g. `text/plain`); real file(1) also appends a `; charset=...` clause, which this port never produces.",
        },
        .examples = &.{
            .{ .cmd = "file image.png", .note = "image.png: PNG image" },
            .{ .cmd = "file -i notes.txt", .note = "notes.txt: text/plain" },
            .{ .cmd = "file -b script.sh", .note = "sh script, ASCII text executable -- no filename prefix" },
        },
        .see_also = "od (raw byte/format dump), stat (metadata without content inspection).",
    },
    // min=0 deliberately: cli.zig's automatic "missing operand" path exits 2, but this
    // applet's empty-operand-list case must exit 1 (the matrix's outlier rule), so the
    // check is done by hand in run() instead of delegated to the Spec.
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

/// `--mime` is documented as an alias for the canonical `--mime-type` long name, but
/// `cli.zig`'s `Opt` has exactly one `long` slot and is a shared file (out of scope for
/// this applet to edit -- DESIGN.md integration boundaries). Rewriting the token here,
/// before handing argv to `cli.parse`, keeps both spellings working without touching
/// the shared parser (source: spec judgment call, see ledger).
fn rewriteMimeAlias(gpa: std.mem.Allocator, args: []const [:0]const u8) []const [:0]const u8 {
    var out: std.ArrayListUnmanaged([:0]const u8) = .empty;
    for (args) |a| {
        out.append(gpa, if (std.mem.eql(u8, a, "--mime")) "--mime-type" else a) catch @panic("OOM");
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

fn identifyStdin(ctx: *Ctx) sys.Error!magic.Result {
    const bytes = try textio.readAll(ctx.gpa, ctx.stdin);
    return magic.identify(bytes);
}

fn identifyPath(path: []const u8) !magic.Result {
    const st = try sys.lstat(path);
    if (st.is_symlink) return .{ .desc = "symbolic link", .mime = "inode/symlink" };
    if (st.is_dir) return .{ .desc = "directory", .mime = "inode/directory" };
    if (st.size == 0) return .{ .desc = "empty", .mime = "inode/x-empty" };

    const fd = try sys.open(path, .{ .read = true });
    defer sys.close(fd);
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = try sys.read(fd, buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return magic.identify(buf[0..total]);
}

pub fn run(ctx: *Ctx) u8 {
    const patched_args = rewriteMimeAlias(ctx.gpa, ctx.args);
    var pctx = ctx.*;
    pctx.args = patched_args;

    const res = cli.parse(&pctx, spec);
    const m = switch (res) {
        // The generic cli.zig parse-error path (unknown flag, etc.) keeps its exit 2 --
        // an accepted, documented deviation from the matrix's "clap-error exit 1"
        // outlier rule (see ledger: modifying the shared parser's convention was ruled
        // out of scope for this applet).
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const files = m.positionalSlice();
    if (files.len == 0) {
        ctx.errPrint("Usage: file [-bi] FILE...\n", .{});
        return 1;
    }

    const brief = m.has("brief");
    const want_mime = m.has("mime-type");

    var rc: u8 = 0;
    for (files) |name| {
        const is_stdin = std.mem.eql(u8, name, "-");
        const result = if (is_stdin)
            identifyStdin(ctx) catch |e| {
                ctx.errPrint("file: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
                rc = 1;
                continue;
            }
        else
            identifyPath(name) catch |e| {
                ctx.errPrint("file: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
                rc = 1;
                continue;
            };

        const body = if (want_mime) result.mime else result.desc;
        if (brief) {
            ctx.outPrint("{s}\n", .{body});
        } else {
            ctx.outPrint("{s}: {s}\n", .{ name, body });
        }
    }
    return rc;
}
