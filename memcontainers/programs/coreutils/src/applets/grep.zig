//! `grep` -- docs/analysis/applets-g-r.md: ripgrep-family behavior (Rust `regex`
//! dialect via `src/engines/regex.zig`, `BinaryDetection::quit(NUL)`, no mmap --
//! whole-file read into memory). Hand-parsed argv (like find/cat/echo): `-e`'s optional
//! attached value and `--color[=WHEN]`'s optional-value long flag don't fit
//! `core/cli.zig`'s fixed flag/value option kinds, and `-h` must NOT mean help (only
//! the literal `--help` token does) which cli.zig's `-h`-cluster path already permits,
//! but hand-parsing keeps every corner in one place.
//!
//! Flags: `-i -n -v -c -l -r/-R -F -w -H -h --color[=WHEN] -e/--regexp PATTERN`
//! (repeatable; short glued `-ePAT` and clustered `-in` both accepted). Positional
//! `PATTERN [FILE]...`; without `-e`, the first positional is PATTERN. No targets ⇒
//! stdin (`(standard input)`). Filename shown when `!h && (H || r || targets > 1)`
//! (targets = the raw argv target count, before `-r` expands a dir). Output
//! `[name:][lnum:]line`; `-l` prints the name once and stops scanning that file after
//! the first (post `-v`) match; `-c` prints `[name:]count`; **`-l` wins over `-c`**
//! when both are given (ledger ruling, GNU precedent). `-w` is applied at the match
//! level (DESIGN note): a line is selected iff some `find()` result, tried from
//! successive start positions, has non-word-or-edge bytes on both sides.
//!
//! Lines are NOT the CRLF-stripped `textio.LineReader` model: grep-searcher keeps a
//! trailing `\r` in the line and in the output (matrix ruling), so this file splits
//! its own whole-buffer lines on bare `\n` only. `BinaryDetection::quit(NUL)`: the
//! first NUL byte found anywhere in a file's content ends the search for that file at
//! the end of the last complete line before the NUL (the ledger records this as the
//! chosen truncation point; ripgrep's own line-buffered quit is chunk-boundary
//! dependent and not independently reproducible here).
//!
//! Exit: 0 any match anywhere, 1 no match, 2 any error (error beats no-match beats
//! match, matrix ruling); `-r` recurses sorted directory listings (matrix: "directory
//! listings sorted" for find applies here too, by the same ledger rationale --
//! `walkdir`'s raw order is host-readdir-dependent and not reproducible in a golden
//! corpus) skipping symlinked subdirectories, searching regular files and
//! symlinks-to-files.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const fsutil = @import("../core/fsutil.zig");
const textio = @import("../core/textio.zig");
const rx = @import("../engines/regex.zig");
const Ctx = @import("../ctx.zig").Ctx;

const help_doc = cli.Help{
    .summary = "print lines matching a pattern",
    .synopsis = &.{
        "grep [OPTION]... PATTERN [FILE]...",
        "grep [OPTION]... -e PATTERN... [FILE]...",
    },
    .description =
    \\Searches each FILE for lines matching a regular expression and prints the matching
    \\lines. The regex engine is a linear-time Pike VM using the Rust `regex`/RE2 dialect
    \\(ERE): . * + ? {m,n} | ( ) [ ] ^ $, the shorthands \d \w \s (and \D \W \S), POSIX
    \\classes like [[:alpha:]], word boundaries \b \B, and \xHH. Each file is read wholly
    \\into memory (no mmap); a file is treated as binary and scanning stops at the first
    \\NUL byte. Without -e, the first positional is the PATTERN; with no FILE (or "-"),
    \\standard input is searched.
    ,
    .options = &.{
        .{ .flags = "-e, --regexp=PATTERN", .desc = "match PATTERN (repeatable; -ePAT glued form accepted)" },
        .{ .flags = "-i", .desc = "case-insensitive matching" },
        .{ .flags = "-v", .desc = "select non-matching lines" },
        .{ .flags = "-n", .desc = "prefix each output line with its 1-based line number" },
        .{ .flags = "-c", .desc = "print only a count of matching lines per file" },
        .{ .flags = "-l", .desc = "print only the names of files containing a match" },
        .{ .flags = "-w", .desc = "match only whole words (word boundaries on both sides)" },
        .{ .flags = "-F", .desc = "treat PATTERN as a fixed string, not a regex" },
        .{ .flags = "-r, -R", .desc = "recurse into directories" },
        .{ .flags = "-H", .desc = "always print the filename with each match" },
        .{ .flags = "-h", .desc = "never print the filename (does NOT mean help)" },
        .{ .flags = "--color[=WHEN]", .desc = "colorize matches; WHEN is always, never, or auto" },
    },
    .operands = "PATTERN is the regular expression (unless supplied via -e). FILE... are the files to search; \"-\" or no FILE reads standard input, and a directory FILE requires -r. The filename is shown when -H, -r, or more than one target is given, unless -h.",
    .exit = &.{
        .{ .code = 0, .when = "one or more lines matched" },
        .{ .code = 1, .when = "no lines matched" },
        .{ .code = 2, .when = "an error occurred (invalid pattern, unreadable file, or usage error)" },
    },
    .deviations_from = "GNU grep",
    .deviations = &.{
        "The regex is the linear-time Rust `regex`/RE2 dialect: no backreferences and no PCRE (-P); a few GNU-only constructs are unsupported.",
        "Only the flags listed above are supported -- no -o, -A/-B/-C context, -f, -x, -q, -Z, --include/--exclude, or -m.",
        "Binary detection stops scanning a file at its first NUL byte.",
        "When both -l and -c are given, -l takes precedence.",
    },
    .examples = &.{
        .{ .cmd = "grep -i error log.txt", .note = "case-insensitive search for \"error\"" },
        .{ .cmd = "grep -rn TODO src/", .note = "recursive, with line numbers" },
        .{ .cmd = "grep -F '.' file", .note = "a literal dot (fixed string), not \"any character\"" },
    },
    .see_also = "sed, awk (transform matched lines); find (locate files by name).",
};

const Flags = struct {
    ignore_case: bool = false,
    line_number: bool = false,
    invert: bool = false,
    count: bool = false,
    files_with_matches: bool = false,
    recursive: bool = false,
    fixed: bool = false,
    word: bool = false,
    with_filename: bool = false,
    no_filename: bool = false,
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------- argv parsing

const Parsed = struct {
    flags: Flags,
    patterns: std.ArrayListUnmanaged([]const u8),
    targets: std.ArrayListUnmanaged([]const u8),
};

const ParseOutcome = union(enum) { ok: Parsed, exit: u8 };

fn parseArgs(ctx: *Ctx) ParseOutcome {
    var f = Flags{};
    var patterns: std.ArrayListUnmanaged([]const u8) = .empty;
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;
    const args = ctx.args[1..];
    var i: usize = 0;
    var no_more_flags = false;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (no_more_flags or a.len == 0 or a[0] != '-' or eq(a, "-")) {
            positionals.append(ctx.gpa, a) catch @panic("OOM");
            continue;
        }
        if (eq(a, "--")) {
            no_more_flags = true;
            continue;
        }
        if (eq(a, "--help")) {
            cli.renderHelp(ctx, "grep", help_doc);
            return .{ .exit = 0 };
        }
        if (eq(a, "--version")) {
            ctx.outPrint("grep 0.1.0\n", .{});
            return .{ .exit = 0 };
        }
        if (a.len >= 2 and a[1] == '-') {
            const body = a[2..];
            const eqidx = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eqidx) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eqidx) |e| body[e + 1 ..] else null;
            if (eq(name, "ignore-case")) {
                f.ignore_case = true;
            } else if (eq(name, "line-number")) {
                f.line_number = true;
            } else if (eq(name, "invert-match")) {
                f.invert = true;
            } else if (eq(name, "count")) {
                f.count = true;
            } else if (eq(name, "files-with-matches")) {
                f.files_with_matches = true;
            } else if (eq(name, "recursive") or eq(name, "dereference-recursive")) {
                f.recursive = true;
            } else if (eq(name, "fixed-strings")) {
                f.fixed = true;
            } else if (eq(name, "word-regexp")) {
                f.word = true;
            } else if (eq(name, "with-filename")) {
                f.with_filename = true;
            } else if (eq(name, "no-filename")) {
                f.no_filename = true;
            } else if (eq(name, "color")) {
                // accepted + ignored, with or without =WHEN
            } else if (eq(name, "regexp")) {
                var v = attached;
                if (v == null) {
                    i += 1;
                    if (i >= args.len) {
                        ctx.errPrint("grep: option '--regexp' requires a value\n", .{});
                        return .{ .exit = 2 };
                    }
                    v = args[i];
                }
                patterns.append(ctx.gpa, v.?) catch @panic("OOM");
            } else {
                ctx.errPrint("grep: unrecognized option '--{s}'\n", .{name});
                return .{ .exit = 2 };
            }
            continue;
        }
        // short option cluster
        var ci: usize = 1;
        while (ci < a.len) {
            const c = a[ci];
            switch (c) {
                'i' => f.ignore_case = true,
                'n' => f.line_number = true,
                'v' => f.invert = true,
                'c' => f.count = true,
                'l' => f.files_with_matches = true,
                'r', 'R' => f.recursive = true,
                'F' => f.fixed = true,
                'w' => f.word = true,
                'H' => f.with_filename = true,
                'h' => f.no_filename = true,
                'e' => {
                    var v: []const u8 = undefined;
                    if (ci + 1 < a.len) {
                        v = a[ci + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            ctx.errPrint("grep: option '-e' requires a value\n", .{});
                            return .{ .exit = 2 };
                        }
                        v = args[i];
                    }
                    patterns.append(ctx.gpa, v) catch @panic("OOM");
                    ci = a.len;
                    continue;
                },
                else => {
                    ctx.errPrint("grep: unrecognized option '-{c}'\n", .{c});
                    return .{ .exit = 2 };
                },
            }
            ci += 1;
        }
    }

    var targets = positionals;
    if (patterns.items.len == 0) {
        if (targets.items.len == 0) {
            ctx.errPrint("Usage: grep [OPTIONS] PATTERN [FILE]...\n", .{});
            return .{ .exit = 2 };
        }
        patterns.append(ctx.gpa, targets.items[0]) catch @panic("OOM");
        targets = .empty;
        for (positionals.items[1..]) |t| targets.append(ctx.gpa, t) catch @panic("OOM");
    }

    return .{ .ok = .{ .flags = f, .patterns = patterns, .targets = targets } };
}

// ---------------------------------------------------------------- whole-buffer line splitting

/// Yields raw `\n`-delimited lines (no CRLF stripping -- grep-searcher keeps `\r` in
/// the line, matrix ruling); the final unterminated chunk (if any) is still yielded.
fn nextLine(buf: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= buf.len) return null;
    const start = pos.*;
    if (std.mem.indexOfScalarPos(u8, buf, start, '\n')) |nl| {
        pos.* = nl + 1;
        return buf[start..nl];
    }
    pos.* = buf.len;
    return buf[start..];
}

/// `BinaryDetection::quit(NUL)`: truncates `buf` at the end of the last complete line
/// before the first NUL byte (dropping any partial line that would have contained it).
/// No NUL ⇒ `buf` unchanged.
fn truncateAtNul(buf: []const u8) []const u8 {
    const nul = std.mem.indexOfScalar(u8, buf, 0) orelse return buf;
    if (std.mem.lastIndexOfScalar(u8, buf[0..nul], '\n')) |nl| return buf[0 .. nl + 1];
    return buf[0..0];
}

// ---------------------------------------------------------------- word-regexp match level

fn wordMatch(r: *rx.Regex, line: []const u8) bool {
    var start: usize = 0;
    while (start <= line.len) {
        const m = r.find(line, start) orelse return false;
        const before_ok = m.start == 0 or !rx.isWordChar(line[m.start - 1]);
        const after_ok = m.end == line.len or !rx.isWordChar(line[m.end]);
        if (before_ok and after_ok) return true;
        start = if (m.end > m.start) m.start + 1 else m.end + 1;
    }
    return false;
}

fn lineMatches(r: *rx.Regex, line: []const u8, word: bool) bool {
    return if (word) wordMatch(r, line) else r.isMatch(line);
}

// ---------------------------------------------------------------- recursive directory walk

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Appends searchable file paths under `path` to `out`, sorted at each directory level
/// (ledger ruling: `walkdir`'s raw readdir order isn't reproducible in a golden
/// corpus). Skips symlinked subdirectories (`is_top` makes an exception for the
/// explicit command-line target itself, matching `ls -R`'s convention of following a
/// symlink-to-dir operand); dangling symlinks are skipped silently. Returns true if any
/// error was reported.
fn walkCollect(ctx: *Ctx, path: []const u8, out: *std.ArrayListUnmanaged([]const u8), is_top: bool) bool {
    const lst = sys.lstat(path) catch |e| {
        ctx.errPrint("grep: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return true;
    };
    var is_dir = lst.is_dir;
    if (lst.is_symlink) {
        const followed = sys.stat(path) catch return false; // dangling: skip silently
        if (!followed.is_dir) {
            out.append(ctx.gpa, path) catch @panic("OOM");
            return false;
        }
        if (!is_top) return false; // nested symlink-to-dir: skip
        is_dir = true;
    }
    if (is_dir) {
        const names = fsutil.list(ctx.gpa, path) catch |e| {
            ctx.errPrint("grep: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
            return true;
        };
        std.mem.sort([]const u8, names, {}, lessThanStr);
        var had_err = false;
        for (names) |name| {
            const child = fsutil.join(ctx.gpa, path, name) catch @panic("OOM");
            if (walkCollect(ctx, child, out, false)) had_err = true;
        }
        return had_err;
    }
    out.append(ctx.gpa, path) catch @panic("OOM");
    return false;
}

// ---------------------------------------------------------------- searcher

const Searcher = struct {
    ctx: *Ctx,
    out: textio.BufOut,
    r: *rx.Regex,
    f: Flags,
    show_filename: bool,
    any_match: bool = false,
    any_error: bool = false,

    fn printName(self: *Searcher, name: []const u8) void {
        self.out.extend(name) catch {};
    }

    fn err(self: *Searcher, path: []const u8, e: sys.Error) void {
        self.out.finish() catch {};
        self.ctx.errPrint("grep: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        self.any_error = true;
    }

    fn searchBuffer(self: *Searcher, name: []const u8, content: []const u8) void {
        const eff = truncateAtNul(content);
        var pos: usize = 0;
        var lineno: u32 = 0;
        var count: u64 = 0;
        var matched_any = false;
        while (nextLine(eff, &pos)) |line| {
            lineno += 1;
            const is_match = lineMatches(self.r, line, self.f.word);
            const selected = is_match != self.f.invert;
            if (!selected) continue;
            matched_any = true;
            count += 1;
            if (self.f.files_with_matches) {
                self.printName(name);
                self.out.endLine() catch {};
                break; // stop scanning this file after the first match
            } else if (!self.f.count) {
                if (self.show_filename) {
                    self.printName(name);
                    self.out.push(':') catch {};
                }
                if (self.f.line_number) {
                    var buf: [20]u8 = undefined;
                    self.out.extend(decimal(&buf, lineno)) catch {};
                    self.out.push(':') catch {};
                }
                self.out.extend(line) catch {};
                self.out.endLine() catch {};
            }
        }
        if (self.f.count and !self.f.files_with_matches) {
            if (self.show_filename) {
                self.printName(name);
                self.out.push(':') catch {};
            }
            var buf: [20]u8 = undefined;
            self.out.extend(decimal(&buf, count)) catch {};
            self.out.endLine() catch {};
        }
        if (matched_any) self.any_match = true;
    }

    fn searchStdin(self: *Searcher) void {
        const content = textio.readAll(self.ctx.gpa, self.ctx.stdin) catch |e| {
            self.err("(standard input)", e);
            return;
        };
        self.searchBuffer("(standard input)", content);
    }

    fn searchPath(self: *Searcher, path: []const u8) void {
        if (eq(path, "-")) {
            self.searchStdin();
            return;
        }
        const fd = sys.open(path, .{ .read = true }) catch |e| {
            self.err(path, e);
            return;
        };
        defer sys.close(fd);
        const content = textio.readAll(self.ctx.gpa, fd) catch |e| {
            self.err(path, e);
            return;
        };
        self.searchBuffer(path, content);
    }
};

fn decimal(buf: []u8, v: u64) []const u8 {
    var vv = v;
    var i: usize = buf.len;
    if (vv == 0) {
        i -= 1;
        buf[i] = '0';
    } else while (vv != 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(vv % 10));
        vv /= 10;
    }
    return buf[i..];
}

// ---------------------------------------------------------------- run

pub fn run(ctx: *Ctx) u8 {
    const parsed = switch (parseArgs(ctx)) {
        .exit => |c| return c,
        .ok => |p| p,
    };
    const f = parsed.flags;

    var diag: rx.Diag = .{};
    var regex = rx.compileMulti(ctx.gpa, parsed.patterns.items, .{
        .case_insensitive = f.ignore_case,
        .literal = f.fixed,
    }, &diag) catch {
        ctx.errPrint("grep: invalid pattern: {s}\n", .{diag.msg});
        return 2;
    };
    defer regex.deinit();

    const raw_targets = parsed.targets.items;
    const show_filename = !f.no_filename and (f.with_filename or f.recursive or raw_targets.len > 1);

    var searcher = Searcher{
        .ctx = ctx,
        .out = textio.BufOut.init(ctx.stdout),
        .r = &regex,
        .f = f,
        .show_filename = show_filename,
    };

    if (raw_targets.len == 0) {
        searcher.searchStdin();
        searcher.out.finish() catch {};
        return finalRc(&searcher);
    }

    for (raw_targets) |target| {
        if (eq(target, "-")) {
            searcher.searchStdin();
            continue;
        }
        if (f.recursive) {
            var files: std.ArrayListUnmanaged([]const u8) = .empty;
            if (walkCollect(ctx, target, &files, true)) searcher.any_error = true;
            for (files.items) |file| searcher.searchPath(file);
            continue;
        }
        const st = if (sys.stat(target)) |s| s else |_| sys.lstat(target) catch |e| {
            searcher.err(target, e);
            continue;
        };
        if (st.is_dir) {
            searcher.out.finish() catch {};
            ctx.errPrint("grep: {s}: Is a directory\n", .{target});
            searcher.any_error = true;
            continue;
        }
        searcher.searchPath(target);
    }

    searcher.out.finish() catch {};
    return finalRc(&searcher);
}

fn finalRc(s: *const Searcher) u8 {
    if (s.any_error) return 2;
    if (s.any_match) return 0;
    return 1;
}
