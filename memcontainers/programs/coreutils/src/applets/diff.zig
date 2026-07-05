//! `diff` -- docs/analysis/applets-a-f.md: wrapper-parity port of the Rust `similar`
//! based applet. Flags: `-u`/`--unified` (3 ctx, the DEFAULT format), `-U N`,
//! `-c`/`--context` (3 ctx), `-C N`, `-r`/`-R`/`--recursive`, `-q`/`--brief`,
//! `-i`/`--ignore-case`, `-w`/`--ignore-all-space`, `-B`/`--ignore-blank-lines`.
//! Exactly two positionals else `diff: requires exactly two file or directory
//! arguments` exit 2; `-` = stdin. Exit 0 identical / 1 differ / 2 error.
//!
//! Byte model: operands are read whole; lines are split on `\n` with the terminator
//! stripped for comparison; `\r` is NOT stripped (diff preserves bytes verbatim per
//! the matrix's cross-cutting note). Every emitted line gets a `\n` appended -- no
//! "\ No newline at end of file" marker is ever produced (ruling, source: spec).
//! Unified/context headers carry no timestamps (ruling, source: spec).
//!
//! Rulings recorded in docs/parity-ledger.md: default format = unified; `-C`/`-c`
//! take precedence over `-U`/`-u`; `-q` wins over format flags; normal format is
//! implemented (emitNormal) but not reachable from any flag combination (open parity
//! question for ring 4); `-B` diffs the blank-filtered arrays and hunk line numbers
//! refer to the FILTERED arrays while the printed text is the original lines;
//! dir/dir without `-r` errors on the first operand; mixed file/dir during `-r`
//! prints GNU's "File {a} is a directory while file {b} is a regular file".

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const fsutil = @import("../core/fsutil.zig");
const fmt_min = @import("../core/fmt_min.zig");
const diffcore = @import("../engines/diffcore.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "diff",
    .flags = &.{
        cli.flagOpt('u', "unified", "output 3 lines of unified context"),
        cli.valueOpt('U', null, "output NUM lines of unified context"),
        cli.flagOpt('c', "context", "output 3 lines of copied context"),
        cli.valueOpt('C', null, "output NUM lines of copied context"),
        cli.flagOpt('r', "recursive", "recursively compare subdirectories"),
        cli.flagOpt('R', null, "recursively compare subdirectories"),
        cli.flagOpt('q', "brief", "report only when files differ"),
        cli.flagOpt('i', "ignore-case", "ignore case differences in file contents"),
        cli.flagOpt('w', "ignore-all-space", "ignore all white space"),
        cli.flagOpt('B', "ignore-blank-lines", "ignore changes where lines are all blank"),
    },
    .help = .{
        .summary = "compare two files or directories line by line",
        .synopsis = &.{"diff [OPTION]... FILE1 FILE2"},
        .description =
        \\Compares FILE1 and FILE2 (`-` means standard input) using the Myers diff
        \\algorithm over whole lines, and prints the differences. Default output is
        \\unified format with 3 lines of context (`-u`, or `-U NUM` for a different
        \\radius); `-c`/`-C NUM` selects context format instead (context/copied-context
        \\flags take precedence over unified when both are given); `-q`/`--brief`
        \\reports only whether the files differ, suppressing the hunk output; when
        \\neither operand is a directory, exactly these two forms are reachable (the
        \\classic "normal" `NdM`/`NaM`/`NcM` format is implemented but not wired to any
        \\flag combination).
        \\
        \\If both operands are directories, `-r`/`-R`/`--recursive` is required (else
        \\it is an error); matching entries are recursively compared, one-sided entries
        \\print "Only in DIR: NAME", and a file paired with a directory of the same
        \\name prints GNU's "File X is a directory while file Y is a regular file".
        \\A directory paired with a plain file (without `-r`) diffs the file against
        \\DIR/basename(FILE).
        \\
        \\`-i`/`--ignore-case`, `-w`/`--ignore-all-space` (collapse+trim runs of
        \\space/tab/CR/VT/FF), and `-B`/`--ignore-blank-lines` (drop all-blank lines before
        \\comparing) may be combined; they affect only which lines are considered
        \\equal, never the text printed in the hunks.
        ,
        .operands = "FILE1 FILE2 (exactly two required); \"-\" means standard input for that operand.",
        .exit = &.{
            .{ .code = 0, .when = "the operands are identical" },
            .{ .code = 1, .when = "the operands differ" },
            .{ .code = 2, .when = "trouble: not exactly two operands, an operand could not be read, a directory pair was given without -r, or -U/-C's argument was not a number" },
        },
        .deviations_from = "GNU diffutils",
        .deviations = &.{
            "Unified/context hunk headers carry no file timestamps (GNU prints each file's mtime after a tab).",
            "No \"\\ No newline at end of file\" marker is ever printed; every emitted line gets a trailing newline regardless of whether the source had one.",
            "Plain dir/dir comparison without -r is an error (\"diff: DIR is a directory\"), rather than GNU's shallow common-file listing.",
        },
        .examples = &.{
            .{ .cmd = "diff a.txt b.txt", .note = "unified format, 3 lines of context" },
            .{ .cmd = "diff -q a.txt b.txt", .note = "\"Files a.txt and b.txt differ\", or silent + exit 0 if identical" },
            .{ .cmd = "diff -r dir1 dir2", .note = "recursive directory comparison" },
        },
        .see_also = "comm (compare sorted files by line presence), cmp.",
    },
    .positionals = .{ .name = "FILES", .min = 0, .max = null },
};

const Format = enum { unified, context, normal };

const Opts = struct {
    format: Format = .unified,
    radius: usize = 3,
    brief: bool = false,
    recursive: bool = false,
    icase: bool = false,
    iws: bool = false,
    iblank: bool = false,

    fn anyIgnore(o: Opts) bool {
        return o.icase or o.iws or o.iblank;
    }
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const pos = m.positionalSlice();
    if (pos.len != 2) {
        ctx.errPrint("diff: requires exactly two file or directory arguments\n", .{});
        return 2;
    }

    var opts = Opts{
        .brief = m.has("brief"),
        .recursive = m.has("recursive") or m.has("R"),
        .icase = m.has("ignore-case"),
        .iws = m.has("ignore-all-space"),
        .iblank = m.has("ignore-blank-lines"),
    };
    // Format selection: -C/-c beat -U/-u when both are given (ruling, source: spec);
    // with no format flag the default is unified with 3 context lines.
    if (m.has("context") or m.value("C") != null) {
        opts.format = .context;
        if (m.value("C")) |v| {
            opts.radius = std.fmt.parseInt(usize, v, 10) catch {
                ctx.errPrint("diff: invalid context length '{s}'\n", .{v});
                return 2;
            };
        }
    } else {
        opts.format = .unified;
        if (m.value("U")) |v| {
            opts.radius = std.fmt.parseInt(usize, v, 10) catch {
                ctx.errPrint("diff: invalid context length '{s}'\n", .{v});
                return 2;
            };
        }
    }

    const a_name = pos[0];
    const b_name = pos[1];

    const a_is_dir = !std.mem.eql(u8, a_name, "-") and fsutil.isDir(a_name);
    const b_is_dir = !std.mem.eql(u8, b_name, "-") and fsutil.isDir(b_name);

    // Non-dir, non-stdin operands must be statable up front (unreadable operand ->
    // `diff: {path}: {strerror}`, exit 2).
    for ([_]struct { name: []const u8, is_dir: bool }{
        .{ .name = a_name, .is_dir = a_is_dir },
        .{ .name = b_name, .is_dir = b_is_dir },
    }) |operand| {
        if (operand.is_dir or std.mem.eql(u8, operand.name, "-")) continue;
        _ = sys.stat(operand.name) catch |e| {
            ctx.errPrint("diff: {s}: {s}\n", .{ operand.name, sys.strerror(sys.toErrno(e)) });
            return 2;
        };
    }

    var out = textio.BufOut.init(ctx.stdout);

    var rc: u8 = 0;
    if (a_is_dir and b_is_dir) {
        if (!opts.recursive) {
            ctx.errPrint("diff: {s} is a directory\n", .{a_name});
            return 2;
        }
        rc = diffDirs(ctx, &out, a_name, b_name, opts);
    } else if (a_is_dir or b_is_dir) {
        // dir/file: the dir side becomes dir/basename(file). Works without -r.
        // A `-` operand paired with a dir is treated as a file named "-" inside the
        // dir on the dir side (ruling, source: spec) -- in practice it stats ENOENT.
        if (a_is_dir) {
            const joined = fsutil.join(ctx.gpa, a_name, fsutil.basename(b_name)) catch return oom(ctx);
            rc = diffFiles(ctx, &out, joined, b_name, opts);
        } else {
            const joined = fsutil.join(ctx.gpa, b_name, fsutil.basename(a_name)) catch return oom(ctx);
            rc = diffFiles(ctx, &out, a_name, joined, opts);
        }
    } else {
        rc = diffFiles(ctx, &out, a_name, b_name, opts);
    }

    out.finish() catch {};
    return rc;
}

fn oom(ctx: *Ctx) u8 {
    ctx.errPrint("diff: out of memory\n", .{});
    return 2;
}

// ------------------------------------------------------------------ file comparison

fn readOperand(ctx: *Ctx, path: []const u8) ?[]u8 {
    if (std.mem.eql(u8, path, "-")) {
        return textio.readAll(ctx.gpa, ctx.stdin) catch |e| {
            ctx.errPrint("diff: -: {s}\n", .{sys.strerror(sys.toErrno(e))});
            return null;
        };
    }
    const fd = sys.open(path, .{ .read = true }) catch |e| {
        ctx.errPrint("diff: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return null;
    };
    defer sys.close(fd);
    return textio.readAll(ctx.gpa, fd) catch |e| {
        ctx.errPrint("diff: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return null;
    };
}

/// Split on `\n`, stripping the terminator only (no `\r` handling -- bytes are
/// preserved verbatim). An unterminated final line is still a line; empty input has
/// zero lines.
fn splitLines(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var start: usize = 0;
    while (start < bytes.len) {
        if (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| {
            try list.append(gpa, bytes[start..nl]);
            start = nl + 1;
        } else {
            try list.append(gpa, bytes[start..]);
            break;
        }
    }
    return list.toOwnedSlice(gpa);
}

fn isDiffSpace(b: u8) bool {
    // ASCII whitespace set for -w/-B: space, tab, CR, VT, FF (never \n -- lines are
    // already split). Ruling, source: spec.
    return b == ' ' or b == '\t' or b == '\r' or b == 0x0b or b == 0x0c;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |b| if (!isDiffSpace(b)) return false;
    return true;
}

/// -w: collapse each whitespace run to a single space and trim both ends.
/// -i: lowercase ASCII. Returns the original slice when no transform applies.
fn preprocessLine(gpa: std.mem.Allocator, line: []const u8, icase: bool, iws: bool) error{OutOfMemory}![]const u8 {
    if (!icase and !iws) return line;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (iws) {
        var pending_space = false;
        var seen_any = false;
        for (line) |b| {
            if (isDiffSpace(b)) {
                if (seen_any) pending_space = true;
                continue;
            }
            if (pending_space) {
                try buf.append(gpa, ' ');
                pending_space = false;
            }
            try buf.append(gpa, if (icase) std.ascii.toLower(b) else b);
            seen_any = true;
        }
    } else {
        try buf.appendSlice(gpa, line);
        for (buf.items) |*b| b.* = std.ascii.toLower(b.*);
    }
    return buf.toOwnedSlice(gpa);
}

const Prepared = struct {
    /// Lines the diff runs on (preprocessed when an ignore flag is set).
    cmp: []const []const u8,
    /// Original line text at each cmp index (identity unless -B filtered).
    display: []const []const u8,
};

fn prepare(gpa: std.mem.Allocator, raw: []const []const u8, opts: Opts) error{OutOfMemory}!Prepared {
    if (!opts.anyIgnore()) return .{ .cmp = raw, .display = raw };
    var cmp: std.ArrayListUnmanaged([]const u8) = .empty;
    var display: std.ArrayListUnmanaged([]const u8) = .empty;
    for (raw) |line| {
        if (opts.iblank and isBlankLine(line)) continue;
        try cmp.append(gpa, try preprocessLine(gpa, line, opts.icase, opts.iws));
        try display.append(gpa, line);
    }
    return .{
        .cmp = try cmp.toOwnedSlice(gpa),
        .display = try display.toOwnedSlice(gpa),
    };
}

fn linesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Compare two file operands; prints output/errors. Returns 0/1/2.
fn diffFiles(ctx: *Ctx, out: *textio.BufOut, a_name: []const u8, b_name: []const u8, opts: Opts) u8 {
    const a_bytes = readOperand(ctx, a_name) orelse return 2;
    const b_bytes = readOperand(ctx, b_name) orelse return 2;

    const a_raw = splitLines(ctx.gpa, a_bytes) catch return oom(ctx);
    const b_raw = splitLines(ctx.gpa, b_bytes) catch return oom(ctx);
    const a = prepare(ctx.gpa, a_raw, opts) catch return oom(ctx);
    const b = prepare(ctx.gpa, b_raw, opts) catch return oom(ctx);

    if (linesEqual(a.cmp, b.cmp)) return 0;

    if (opts.brief) {
        out.extend("Files ") catch return 1;
        out.extend(a_name) catch return 1;
        out.extend(" and ") catch return 1;
        out.extend(b_name) catch return 1;
        out.extend(" differ\n") catch return 1;
        return 1;
    }

    const ops = diffcore.diffLines(ctx.gpa, a.cmp, b.cmp) catch return oom(ctx);
    if (!diffcore.hasChanges(ops)) return 0; // unreachable given linesEqual, kept safe

    switch (opts.format) {
        .unified => {
            const groups = diffcore.groupOps(ctx.gpa, ops, opts.radius) catch return oom(ctx);
            emitUnified(out, groups, a.display, b.display, a_name, b_name) catch return 1;
        },
        .context => {
            const groups = diffcore.groupOps(ctx.gpa, ops, opts.radius) catch return oom(ctx);
            emitContext(out, groups, a.display, b.display, a_name, b_name) catch return 1;
        },
        .normal => {
            emitNormal(out, ops, a.display, b.display) catch return 1;
        },
    }
    return 1;
}

// ------------------------------------------------------------------------ emitters

fn pushDec(out: *textio.BufOut, v: usize) sys.Error!void {
    var buf: [20]u8 = undefined;
    try out.extend(fmt_min.formatBuf(&buf, "{d}", .{v}));
}

/// GNU unified range: 1-based start; count==1 renders as `{s}`; count==0 renders as
/// `{s0},0` where `s0` is the line number BEFORE the gap (the 0-based start index).
fn pushURange(out: *textio.BufOut, r: diffcore.Range) sys.Error!void {
    if (r.count == 0) {
        try pushDec(out, r.start);
        try out.extend(",0");
    } else if (r.count == 1) {
        try pushDec(out, r.start + 1);
    } else {
        try pushDec(out, r.start + 1);
        try out.push(',');
        try pushDec(out, r.count);
    }
}

fn pushPrefixedLine(out: *textio.BufOut, prefix: []const u8, line: []const u8) sys.Error!void {
    try out.extend(prefix);
    try out.extend(line);
    try out.push('\n');
}

fn emitUnified(
    out: *textio.BufOut,
    groups: []const []diffcore.Op,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    a_name: []const u8,
    b_name: []const u8,
) sys.Error!void {
    // No timestamps in headers (ruling, source: spec).
    try pushPrefixedLine(out, "--- ", a_name);
    try pushPrefixedLine(out, "+++ ", b_name);
    for (groups) |group| {
        const r = diffcore.hunkRanges(group);
        try out.extend("@@ -");
        try pushURange(out, r.a);
        try out.extend(" +");
        try pushURange(out, r.b);
        try out.extend(" @@\n");
        for (group) |op| {
            var i: usize = 0;
            switch (op.tag) {
                .equal => while (i < op.len) : (i += 1) {
                    try pushPrefixedLine(out, " ", a_lines[op.a + i]);
                },
                .delete => while (i < op.len) : (i += 1) {
                    try pushPrefixedLine(out, "-", a_lines[op.a + i]);
                },
                .insert => while (i < op.len) : (i += 1) {
                    try pushPrefixedLine(out, "+", b_lines[op.b + i]);
                },
            }
        }
    }
}

/// Context range, 1-based inclusive: count==0 renders the line number before the gap
/// (single number); count==1 renders `{s}`; else `{s},{e}` (ruling, source: spec).
fn pushCRange(out: *textio.BufOut, r: diffcore.Range) sys.Error!void {
    if (r.count == 0) {
        try pushDec(out, r.start);
    } else if (r.count == 1) {
        try pushDec(out, r.start + 1);
    } else {
        try pushDec(out, r.start + 1);
        try out.push(',');
        try pushDec(out, r.start + r.count);
    }
}

fn emitContext(
    out: *textio.BufOut,
    groups: []const []diffcore.Op,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
    a_name: []const u8,
    b_name: []const u8,
) sys.Error!void {
    try pushPrefixedLine(out, "*** ", a_name);
    try pushPrefixedLine(out, "--- ", b_name);
    for (groups) |group| {
        var has_del = false;
        var has_ins = false;
        for (group) |op| switch (op.tag) {
            .delete => has_del = true,
            .insert => has_ins = true,
            .equal => {},
        };
        const r = diffcore.hunkRanges(group);
        try out.extend("***************\n");
        try out.extend("*** ");
        try pushCRange(out, r.a);
        try out.extend(" ****\n");
        if (has_del) {
            // Old-side body: equal + delete lines; GNU omits the body when the side
            // has no changes (ruling, source: spec). No `!` change-pairs.
            for (group) |op| {
                var i: usize = 0;
                switch (op.tag) {
                    .equal => while (i < op.len) : (i += 1) {
                        try pushPrefixedLine(out, "  ", a_lines[op.a + i]);
                    },
                    .delete => while (i < op.len) : (i += 1) {
                        try pushPrefixedLine(out, "- ", a_lines[op.a + i]);
                    },
                    .insert => {},
                }
            }
        }
        try out.extend("--- ");
        try pushCRange(out, r.b);
        try out.extend(" ----\n");
        if (has_ins) {
            for (group) |op| {
                var i: usize = 0;
                switch (op.tag) {
                    .equal => while (i < op.len) : (i += 1) {
                        try pushPrefixedLine(out, "  ", b_lines[op.b + i]);
                    },
                    .insert => while (i < op.len) : (i += 1) {
                        try pushPrefixedLine(out, "+ ", b_lines[op.b + i]);
                    },
                    .delete => {},
                }
            }
        }
    }
}

/// Normal-format range: `start` if a single line else `start,end` (1-based inclusive).
fn pushNRange(out: *textio.BufOut, start0: usize, count: usize) sys.Error!void {
    if (count <= 1) {
        try pushDec(out, start0 + 1);
    } else {
        try pushDec(out, start0 + 1);
        try out.push(',');
        try pushDec(out, start0 + count);
    }
}

/// Normal format: no context (radius-0 clusters straight off the normalized op list).
/// NOT reachable from any flag combination (ruling: unified is the default; ledgered
/// as an open ring-4 parity question) -- implemented and unit-tested for completeness.
fn emitNormal(
    out: *textio.BufOut,
    ops: []const diffcore.Op,
    a_lines: []const []const u8,
    b_lines: []const []const u8,
) sys.Error!void {
    var i: usize = 0;
    while (i < ops.len) {
        if (ops[i].tag == .equal) {
            i += 1;
            continue;
        }
        // Cluster: delete op optionally followed by its paired insert (normalized).
        var del: ?diffcore.Op = null;
        var ins: ?diffcore.Op = null;
        if (ops[i].tag == .delete) {
            del = ops[i];
            i += 1;
        }
        if (i < ops.len and ops[i].tag == .insert) {
            ins = ops[i];
            i += 1;
        }
        if (del != null and ins != null) {
            const d = del.?;
            const n = ins.?;
            try pushNRange(out, d.a, d.len);
            try out.push('c');
            try pushNRange(out, n.b, n.len);
            try out.push('\n');
            var j: usize = 0;
            while (j < d.len) : (j += 1) try pushPrefixedLine(out, "< ", a_lines[d.a + j]);
            try out.extend("---\n");
            j = 0;
            while (j < n.len) : (j += 1) try pushPrefixedLine(out, "> ", b_lines[n.b + j]);
        } else if (del) |d| {
            try pushNRange(out, d.a, d.len);
            try out.push('d');
            try pushDec(out, d.b); // 0-based b index == 1-based line before
            try out.push('\n');
            var j: usize = 0;
            while (j < d.len) : (j += 1) try pushPrefixedLine(out, "< ", a_lines[d.a + j]);
        } else if (ins) |n| {
            try pushDec(out, n.a);
            try out.push('a');
            try pushNRange(out, n.b, n.len);
            try out.push('\n');
            var j: usize = 0;
            while (j < n.len) : (j += 1) try pushPrefixedLine(out, "> ", b_lines[n.b + j]);
        }
    }
}

// --------------------------------------------------------------------- directories

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Recursive dir/dir walk: sorted union of entry names; "Only in {dir}: {name}" for
/// one-sided entries; recurse into dir pairs; file pairs diff with joined-path
/// headers; mixed pairs print GNU's directory-vs-regular-file line and count as a
/// difference. Returns max of 0/1/2 seen.
fn diffDirs(ctx: *Ctx, out: *textio.BufOut, a_dir: []const u8, b_dir: []const u8, opts: Opts) u8 {
    const a_names = fsutil.list(ctx.gpa, a_dir) catch |e| {
        ctx.errPrint("diff: {s}: {s}\n", .{ a_dir, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    const b_names = fsutil.list(ctx.gpa, b_dir) catch |e| {
        ctx.errPrint("diff: {s}: {s}\n", .{ b_dir, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    std.mem.sort([]const u8, a_names, {}, strLess);
    std.mem.sort([]const u8, b_names, {}, strLess);

    var rc: u8 = 0;
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a_names.len or bi < b_names.len) {
        const order: std.math.Order = if (ai >= a_names.len)
            .gt
        else if (bi >= b_names.len)
            .lt
        else
            std.mem.order(u8, a_names[ai], b_names[bi]);

        switch (order) {
            .lt => {
                printOnlyIn(ctx, out, a_dir, a_names[ai]) catch return rc;
                rc = @max(rc, 1);
                ai += 1;
            },
            .gt => {
                printOnlyIn(ctx, out, b_dir, b_names[bi]) catch return rc;
                rc = @max(rc, 1);
                bi += 1;
            },
            .eq => {
                const name = a_names[ai];
                ai += 1;
                bi += 1;
                const pa = fsutil.join(ctx.gpa, a_dir, name) catch return oom(ctx);
                const pb = fsutil.join(ctx.gpa, b_dir, name) catch return oom(ctx);
                const pa_dir = fsutil.isDir(pa);
                const pb_dir = fsutil.isDir(pb);
                if (pa_dir and pb_dir) {
                    rc = @max(rc, diffDirs(ctx, out, pa, pb, opts));
                } else if (!pa_dir and !pb_dir) {
                    rc = @max(rc, diffFiles(ctx, out, pa, pb, opts));
                } else {
                    printMixed(out, pa, pa_dir, pb) catch return rc;
                    rc = @max(rc, 1);
                }
            },
        }
    }
    return rc;
}

fn printOnlyIn(ctx: *Ctx, out: *textio.BufOut, dir: []const u8, name: []const u8) sys.Error!void {
    _ = ctx;
    try out.extend("Only in ");
    try out.extend(dir);
    try out.extend(": ");
    try out.extend(name);
    try out.push('\n');
}

fn printMixed(out: *textio.BufOut, pa: []const u8, pa_is_dir: bool, pb: []const u8) sys.Error!void {
    try out.extend("File ");
    try out.extend(pa);
    if (pa_is_dir) {
        try out.extend(" is a directory while file ");
        try out.extend(pb);
        try out.extend(" is a regular file\n");
    } else {
        try out.extend(" is a regular file while file ");
        try out.extend(pb);
        try out.extend(" is a directory\n");
    }
}
