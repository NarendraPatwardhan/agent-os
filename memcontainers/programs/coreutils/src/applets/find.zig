//! `find` -- DESIGN.md §1: hand-tokenized argv (no `core/cli.zig`; the
//! matrix says clap only collects raw ARGS here) -> a recursive-descent expression
//! parser (precedence `-o < -a/implicit < !/-not < primary`) -> an AST tree-walked once
//! per visited entry.
//!
//! Leading operands up to the first token starting with `-`/`(`/`!` are the search
//! PATHs (default `.`); everything from there on is the expression. `-maxdepth`/
//! `-mindepth`/`-depth` are parsed as ordinary primaries (so `-exec ... ;`'s opaque
//! argument block is never misread as one) that mutate shared traversal config and
//! fold to an always-true node, matching GNU's "these are really global options"
//! behavior despite the primary-looking spelling. `-delete` implies `-depth`
//! (post-order) the same way. If the expression contains no action (`-print`/
//! `-print0`/`-exec`/`-delete`), the parser wraps the whole tree in
//! `(expr) -a -print` once, so the traversal driver never needs a separate
//! "did anything act?" check.
//!
//! Directory listings are sorted at each level (ledger ruling: the reference
//! `fsutil::list`/`rt::readdir` order is raw-host-readdir-dependent, not reproducible
//! in a golden corpus -- same rationale as grep's `-r`). `-exec ... +` batches into a
//! single accumulator (only one batched clause is allowed per invocation) flushed once
//! at the very end of traversal (including a `-quit`-triggered early stop); `-exec ...
//! ;` spawns immediately per match, child inherits this process's stdio, and its exit
//! status feeds the predicate directly (`0` = true) -- a ledger ruling, since the
//! matrix doesn't pin this.
//!
//! Errors: `find: {tok}: missing argument` / `find: {tok}: unknown predicate` /
//! unbalanced parens / missing `-exec` terminator -> exit 2 (no traversal is run).
//! Runtime failures (stat/readdir/-delete) -> `find: {p}: {strerror}` (or `find: {p}:
//! cannot delete`), rc degrades to 1, traversal continues.

const std = @import("std");
const sys = @import("../sys/root.zig");
const fsutil = @import("../core/fsutil.zig");
const proc = @import("../core/proc.zig");
const textio = @import("../core/textio.zig");
const glob = @import("../engines/glob.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const help_doc = cli.Help{
    .summary = "search a directory hierarchy for matching entries",
    .synopsis = &.{"find [PATH...] [EXPRESSION]"},
    .description =
    \\Recursively walks each PATH (default "."), depth-first, visiting
    \\directory entries in sorted (lexicographic) order at every level, and
    \\evaluates EXPRESSION against each visited entry. EXPRESSION is a small
    \\boolean grammar of tests and actions, combined with ! / -not (highest
    \\precedence), an implicit or explicit -a / -and, and -o / -or (lowest
    \\precedence), grouped with ( ... ). If EXPRESSION contains no action
    \\(-print, -print0, -exec, or -delete), the whole expression is wrapped in
    \\an implicit "-a -print", so a bare `find .` still prints every entry.
    \\
    \\-exec CMD ARGS... ; runs CMD once per match, immediately, with this
    \\process's stdio; its exit status (0 = true) is the predicate's value.
    \\-exec CMD ARGS... + instead batches every match into as few CMD
    \\invocations as possible, run once at the very end of traversal. {} in
    \\CMD is replaced with the matched path (or, under +, with all batched
    \\paths at once).
    ,
    .options_note = "find takes no flag-style options of its own; every \"-...\" token in EXPRESSION below is a test, action, or traversal option.",
    .operands =
    \\PATH...   directories or files to search; leading operands up to the
    \\first token starting with "-", "(", or "!" are PATHs (default "."); the
    \\rest of the command line is EXPRESSION.
    \\
    \\Tests: -name/-iname PATTERN and -path/-wholename/-ipath/-iwholename
    \\PATTERN (shell-glob match against the basename / whole path), -type
    \\f|d|l, -size [+-]N[cKMG] (bare N = 512-byte blocks), -mtime [+-]N (age
    \\in days), -newer FILE, -perm [-|/|=]MODE (octal), -empty, -true, -false.
    \\
    \\Actions: -print (default), -print0, -delete (implies -depth), -prune
    \\(do not descend into a matched directory), -quit (stop traversal now),
    \\-exec ... ; , -exec ... + (only one batched clause per invocation).
    \\
    \\Traversal options (ordinary-looking primaries that affect the whole
    \\walk): -maxdepth N, -mindepth N, -depth (visit a directory's contents
    \\before the directory itself).
    ,
    .exit = &.{
        .{ .code = 0, .when = "success (regardless of whether anything matched)" },
        .{ .code = 1, .when = "a runtime error occurred (stat/readdir/-delete/-exec failure); traversal continues" },
        .{ .code = 2, .when = "a usage error in EXPRESSION (unknown predicate, missing argument, unbalanced parens, missing -exec terminator); no traversal runs" },
    },
    .deviations_from = "GNU findutils",
    .deviations = &.{
        "Directory entries are visited in sorted order at every level; GNU find's order follows raw readdir and is filesystem/OS-dependent (typically unsorted).",
        "-name/-path/-iname/-ipath match a simplified shell glob (*, ?, [...] classes; no brace expansion or POSIX classes like [[:alpha:]]), not full fnmatch(3).",
        "-size accepts only c/k/M/G unit suffixes (bare N still means 512-byte blocks); GNU's explicit b and w suffixes are not recognized.",
        "-mtime is the only time-based test; -atime/-ctime/-amin/-cmin/-mmin/-newerXY are not implemented.",
        "-perm takes only an octal MODE (with -, /, or = prefix); GNU's symbolic mode strings (e.g. -perm -g+w) are not supported.",
        "Only one batched -exec ... + clause is allowed per invocation (a second is a usage error), and it always flushes once at the very end of traversal rather than GNU's periodic batching.",
        "This is a scoped subset of GNU find: -regex/-iregex, -user/-group/-uid/-gid, -links, -inum, -samefile, -xtype, -follow/-L/-H, -printf/-fprintf, and -daystart are not implemented.",
    },
    .examples = &.{
        .{ .cmd = "find . -name '*.txt'", .note = "every .txt file under the current directory (implicit -print)" },
        .{ .cmd = "find /var/log -mtime +7 -delete", .note = "delete files under /var/log older than 7 days" },
        .{ .cmd = "find . -type f -exec chmod 644 {} +", .note = "batch-chmod every regular file in as few invocations as possible" },
    },
    .see_also = "grep -r (content search), xargs (batch a command over a list), ls.",
};

// ============================================================================ AST

const Kind = enum {
    true_,
    false_,
    name_pat, // basename glob (pat, ci)
    path_pat, // full-path glob (pat, ci)
    type_, // ch: 'f'/'d'/'l'
    size_, // sign, n, unit_mult
    empty_,
    newer_, // ref_mtime_ms
    mtime_, // sign, n (days)
    perm_, // mode, perm_kind
    print_,
    print0_,
    delete_,
    prune_,
    quit_,
    exec_, // argv, is_plus
    not_,
    and_,
    or_,
};

const PermKind = enum { exact, all, any };

const Node = struct {
    kind: Kind,
    a: i32 = -1,
    b: i32 = -1,
    pat: []const u8 = "",
    ci: bool = false,
    ch: u8 = 0,
    sign: i8 = 0,
    n: u64 = 0,
    unit_mult: u64 = 1,
    ref_mtime_ms: i64 = 0,
    mode: u32 = 0,
    perm_kind: PermKind = .exact,
    argv: []const []const u8 = &.{},
    is_plus: bool = false,
};

// ============================================================================ parser

const Parser = struct {
    ctx: *Ctx,
    tokens: []const []const u8,
    idx: usize = 0,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    failed: bool = false,
    has_action: bool = false,
    depth_flag: bool = false,
    delete_flag: bool = false,
    batched_seen: bool = false,
    maxdepth: ?u32 = null,
    mindepth: u32 = 0,

    fn atEnd(self: *const Parser) bool {
        return self.idx >= self.tokens.len;
    }
    fn tok(self: *const Parser) []const u8 {
        return self.tokens[self.idx];
    }
    fn advance(self: *Parser) void {
        self.idx += 1;
    }

    fn make(self: *Parser, kind: Kind) i32 {
        self.nodes.append(self.ctx.gpa, Node{ .kind = kind }) catch @panic("OOM");
        return @intCast(self.nodes.items.len - 1);
    }
    fn n(self: *Parser, idx: i32) *Node {
        return &self.nodes.items[@intCast(idx)];
    }
    fn makeUnary(self: *Parser, kind: Kind, child: i32) i32 {
        const nd = self.make(kind);
        self.n(nd).a = child;
        return nd;
    }
    fn makeBin(self: *Parser, kind: Kind, l: i32, r: i32) i32 {
        const nd = self.make(kind);
        self.n(nd).a = l;
        self.n(nd).b = r;
        return nd;
    }

    fn takeArg(self: *Parser, name: []const u8) ?[]const u8 {
        if (self.atEnd()) {
            self.ctx.errPrint("find: {s}: missing argument\n", .{name});
            self.failed = true;
            return null;
        }
        const v = self.tok();
        self.advance();
        return v;
    }

    /// `[+-]N[ckMG]` (bare = 512-byte blocks).
    fn parseSize(s: []const u8) ?struct { sign: i8, n: u64, unit: u64 } {
        var i: usize = 0;
        var sign: i8 = 0;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            sign = if (s[i] == '+') 1 else -1;
            i += 1;
        }
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == start) return null;
        const val = std.fmt.parseInt(u64, s[start..i], 10) catch return null;
        var unit: u64 = 512;
        if (i < s.len) {
            unit = switch (s[i]) {
                'c' => 1,
                'k' => 1024,
                'M' => 1024 * 1024,
                'G' => 1024 * 1024 * 1024,
                else => return null,
            };
            i += 1;
        }
        if (i != s.len) return null;
        return .{ .sign = sign, .n = val, .unit = unit };
    }

    /// `[+-]N` (days).
    fn parseSignedInt(s: []const u8) ?struct { sign: i8, n: u64 } {
        var i: usize = 0;
        var sign: i8 = 0;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            sign = if (s[i] == '+') 1 else -1;
            i += 1;
        }
        if (i >= s.len) return null;
        const val = std.fmt.parseInt(u64, s[i..], 10) catch return null;
        return .{ .sign = sign, .n = val };
    }

    /// `[-/=]MODE` (octal; bare MODE == `=MODE`).
    fn parsePerm(s: []const u8) ?struct { mode: u32, kind: PermKind } {
        if (s.len == 0) return null;
        var kind: PermKind = .exact;
        var rest = s;
        switch (s[0]) {
            '-' => {
                kind = .all;
                rest = s[1..];
            },
            '/' => {
                kind = .any;
                rest = s[1..];
            },
            '=' => rest = s[1..],
            else => {},
        }
        const mode = std.fmt.parseInt(u32, rest, 8) catch return null;
        return .{ .mode = mode & 0o7777, .kind = kind };
    }

    fn parseOr(self: *Parser) i32 {
        var left = self.parseAnd();
        while (!self.atEnd() and (eq(self.tok(), "-o") or eq(self.tok(), "-or"))) {
            self.advance();
            const right = self.parseAnd();
            left = self.makeBin(.or_, left, right);
        }
        return left;
    }

    fn parseAnd(self: *Parser) i32 {
        var left = self.parseNot();
        while (!self.atEnd() and !eq(self.tok(), ")") and !eq(self.tok(), "-o") and !eq(self.tok(), "-or")) {
            if (eq(self.tok(), "-a") or eq(self.tok(), "-and")) self.advance();
            const right = self.parseNot();
            left = self.makeBin(.and_, left, right);
        }
        return left;
    }

    fn parseNot(self: *Parser) i32 {
        if (!self.atEnd() and (eq(self.tok(), "!") or eq(self.tok(), "-not"))) {
            self.advance();
            const child = self.parseNot();
            return self.makeUnary(.not_, child);
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) i32 {
        if (self.atEnd()) {
            self.ctx.errPrint("find: missing argument to expression\n", .{});
            self.failed = true;
            return self.make(.true_);
        }
        const t = self.tok();

        if (eq(t, "(")) {
            self.advance();
            const inner = self.parseOr();
            if (!self.atEnd() and eq(self.tok(), ")")) {
                self.advance();
            } else {
                self.ctx.errPrint("find: unbalanced '('\n", .{});
                self.failed = true;
            }
            return inner;
        }
        if (eq(t, "-true")) {
            self.advance();
            return self.make(.true_);
        }
        if (eq(t, "-false")) {
            self.advance();
            return self.make(.false_);
        }
        if (eq(t, "-name") or eq(t, "-iname")) {
            const ci = eq(t, "-iname");
            self.advance();
            const pat = self.takeArg(t) orelse return self.make(.true_);
            const nd = self.make(.name_pat);
            self.n(nd).pat = pat;
            self.n(nd).ci = ci;
            return nd;
        }
        if (eq(t, "-path") or eq(t, "-wholename") or eq(t, "-ipath") or eq(t, "-iwholename")) {
            const ci = eq(t, "-ipath") or eq(t, "-iwholename");
            self.advance();
            const pat = self.takeArg(t) orelse return self.make(.true_);
            const nd = self.make(.path_pat);
            self.n(nd).pat = pat;
            self.n(nd).ci = ci;
            return nd;
        }
        if (eq(t, "-type")) {
            self.advance();
            const v = self.takeArg("-type") orelse return self.make(.true_);
            if (v.len != 1 or (v[0] != 'f' and v[0] != 'd' and v[0] != 'l')) {
                self.ctx.errPrint("find: -type: unsupported type '{s}'\n", .{v});
                self.failed = true;
                return self.make(.true_);
            }
            const nd = self.make(.type_);
            self.n(nd).ch = v[0];
            return nd;
        }
        if (eq(t, "-size")) {
            self.advance();
            const v = self.takeArg("-size") orelse return self.make(.true_);
            const parsed = parseSize(v) orelse {
                self.ctx.errPrint("find: -size: invalid argument '{s}'\n", .{v});
                self.failed = true;
                return self.make(.true_);
            };
            const nd = self.make(.size_);
            self.n(nd).sign = parsed.sign;
            self.n(nd).n = parsed.n;
            self.n(nd).unit_mult = parsed.unit;
            return nd;
        }
        if (eq(t, "-empty")) {
            self.advance();
            return self.make(.empty_);
        }
        if (eq(t, "-newer")) {
            self.advance();
            const file = self.takeArg("-newer") orelse return self.make(.true_);
            const st = sys.stat(file) catch |e| {
                self.ctx.errPrint("find: '{s}': {s}\n", .{ file, sys.strerror(sys.toErrno(e)) });
                self.failed = true;
                return self.make(.true_);
            };
            const nd = self.make(.newer_);
            self.n(nd).ref_mtime_ms = st.mtime_ms;
            return nd;
        }
        if (eq(t, "-mtime")) {
            self.advance();
            const v = self.takeArg("-mtime") orelse return self.make(.true_);
            const parsed = parseSignedInt(v) orelse {
                self.ctx.errPrint("find: -mtime: invalid argument '{s}'\n", .{v});
                self.failed = true;
                return self.make(.true_);
            };
            const nd = self.make(.mtime_);
            self.n(nd).sign = parsed.sign;
            self.n(nd).n = parsed.n;
            return nd;
        }
        if (eq(t, "-perm")) {
            self.advance();
            const v = self.takeArg("-perm") orelse return self.make(.true_);
            const parsed = parsePerm(v) orelse {
                self.ctx.errPrint("find: -perm: invalid mode '{s}'\n", .{v});
                self.failed = true;
                return self.make(.true_);
            };
            const nd = self.make(.perm_);
            self.n(nd).mode = parsed.mode;
            self.n(nd).perm_kind = parsed.kind;
            return nd;
        }
        if (eq(t, "-print")) {
            self.advance();
            self.has_action = true;
            return self.make(.print_);
        }
        if (eq(t, "-print0")) {
            self.advance();
            self.has_action = true;
            return self.make(.print0_);
        }
        if (eq(t, "-delete")) {
            self.advance();
            self.has_action = true;
            self.delete_flag = true;
            return self.make(.delete_);
        }
        if (eq(t, "-prune")) {
            self.advance();
            return self.make(.prune_);
        }
        if (eq(t, "-quit")) {
            self.advance();
            return self.make(.quit_);
        }
        if (eq(t, "-depth")) {
            self.advance();
            self.depth_flag = true;
            return self.make(.true_);
        }
        if (eq(t, "-maxdepth") or eq(t, "-mindepth")) {
            const is_max = eq(t, "-maxdepth");
            self.advance();
            const v = self.takeArg(t) orelse return self.make(.true_);
            const d = std.fmt.parseInt(u32, v, 10) catch {
                self.ctx.errPrint("find: {s}: invalid argument '{s}'\n", .{ t, v });
                self.failed = true;
                return self.make(.true_);
            };
            if (is_max) self.maxdepth = d else self.mindepth = d;
            return self.make(.true_);
        }
        if (eq(t, "-exec")) {
            self.advance();
            const start = self.idx;
            var end: ?usize = null;
            var is_plus = false;
            while (!self.atEnd()) {
                if (eq(self.tok(), ";")) {
                    end = self.idx;
                    self.advance();
                    break;
                }
                if (eq(self.tok(), "+")) {
                    end = self.idx;
                    is_plus = true;
                    self.advance();
                    break;
                }
                self.advance();
            }
            if (end == null) {
                self.ctx.errPrint("find: -exec: missing terminating ';' or '+'\n", .{});
                self.failed = true;
                return self.make(.true_);
            }
            const argv = self.tokens[start..end.?];
            if (argv.len == 0) {
                self.ctx.errPrint("find: -exec: missing argument\n", .{});
                self.failed = true;
                return self.make(.true_);
            }
            if (is_plus) {
                if (self.batched_seen) {
                    self.ctx.errPrint("find: only one batched '-exec ... +' is supported\n", .{});
                    self.failed = true;
                    return self.make(.true_);
                }
                self.batched_seen = true;
            }
            self.has_action = true;
            const nd = self.make(.exec_);
            self.n(nd).argv = argv;
            self.n(nd).is_plus = is_plus;
            return nd;
        }

        self.ctx.errPrint("find: {s}: unknown predicate\n", .{t});
        self.failed = true;
        self.advance();
        return self.make(.true_);
    }
};

// ============================================================================ evaluator

fn replaceBraces(gpa: std.mem.Allocator, arg: []const u8, path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, arg, "{}") == null) return arg;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < arg.len) {
        if (i + 1 < arg.len and arg[i] == '{' and arg[i + 1] == '}') {
            out.appendSlice(gpa, path) catch @panic("OOM");
            i += 2;
        } else {
            out.append(gpa, arg[i]) catch @panic("OOM");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

const FileInfo = struct {
    path: []const u8,
    basename: []const u8,
    st: sys.Stat,
    now_s: i64,
};

const Evaluator = struct {
    ctx: *Ctx,
    nodes: []const Node,
    out: textio.BufOut,
    quit: bool = false,
    any_error: bool = false,
    batched_argv: ?[]const []const u8 = null,
    batched_paths: std.ArrayListUnmanaged([]const u8) = .empty,

    fn nd(self: *const Evaluator, idx: i32) *const Node {
        return &self.nodes[@intCast(idx)];
    }

    fn runtimeErr(self: *Evaluator, path: []const u8, e: sys.Error) void {
        self.out.finish() catch {};
        self.ctx.errPrint("find: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        self.any_error = true;
    }

    fn ageDays(now_s: i64, mtime_ms: i64) i64 {
        const mtime_s = @divFloor(mtime_ms, 1000);
        return @divFloor(now_s - mtime_s, 86400);
    }

    fn evalSign(sign: i8, n: anytype, actual: @TypeOf(n)) bool {
        return switch (sign) {
            0 => actual == n,
            1 => actual > n,
            else => actual < n,
        };
    }

    fn isEmptyDir(self: *Evaluator, path: []const u8) bool {
        const names = fsutil.list(self.ctx.gpa, path) catch return false;
        return names.len == 0;
    }

    fn eval(self: *Evaluator, idx: i32, fi: *const FileInfo, prune: *bool) bool {
        const node = self.nd(idx);
        return switch (node.kind) {
            .true_ => true,
            .false_ => false,
            .not_ => !self.eval(node.a, fi, prune),
            .and_ => self.eval(node.a, fi, prune) and self.eval(node.b, fi, prune),
            .or_ => self.eval(node.a, fi, prune) or self.eval(node.b, fi, prune),
            .name_pat => if (node.ci) glob.matchCI(node.pat, fi.basename) else glob.match(node.pat, fi.basename),
            .path_pat => if (node.ci) glob.matchCI(node.pat, fi.path) else glob.match(node.pat, fi.path),
            .type_ => switch (node.ch) {
                'l' => fi.st.is_symlink,
                'd' => fi.st.is_dir and !fi.st.is_symlink,
                else => !fi.st.is_dir and !fi.st.is_symlink, // 'f'
            },
            .size_ => blk: {
                const units = (fi.st.size + node.unit_mult - 1) / node.unit_mult;
                break :blk evalSign(node.sign, node.n, units);
            },
            .empty_ => if (fi.st.is_dir) self.isEmptyDir(fi.path) else fi.st.size == 0,
            .newer_ => fi.st.mtime_ms > node.ref_mtime_ms,
            .mtime_ => evalSign(node.sign, @as(i64, @intCast(node.n)), ageDays(fi.now_s, fi.st.mtime_ms)),
            .perm_ => blk: {
                const m = fi.st.mode & 0o7777;
                break :blk switch (node.perm_kind) {
                    .exact => m == node.mode,
                    .all => (m & node.mode) == node.mode,
                    .any => node.mode == 0 or (m & node.mode) != 0,
                };
            },
            .print_ => blk: {
                self.out.extend(fi.path) catch {};
                self.out.endLine() catch {};
                break :blk true;
            },
            .print0_ => blk: {
                self.out.extend(fi.path) catch {};
                self.out.push(0) catch {};
                break :blk true;
            },
            .prune_ => blk: {
                prune.* = true;
                break :blk true;
            },
            .quit_ => blk: {
                self.quit = true;
                break :blk true;
            },
            .delete_ => blk: {
                sys.unlink(fi.path) catch {
                    self.out.finish() catch {};
                    self.ctx.errPrint("find: {s}: cannot delete\n", .{fi.path});
                    self.any_error = true;
                };
                break :blk true;
            },
            .exec_ => self.evalExec(node, fi),
        };
    }

    fn evalExec(self: *Evaluator, node: *const Node, fi: *const FileInfo) bool {
        if (node.is_plus) {
            self.batched_argv = node.argv;
            self.batched_paths.append(self.ctx.gpa, self.ctx.gpa.dupe(u8, fi.path) catch @panic("OOM")) catch @panic("OOM");
            return true;
        }
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        for (node.argv) |a| argv.append(self.ctx.gpa, replaceBraces(self.ctx.gpa, a, fi.path)) catch @panic("OOM");
        const blob = proc.argvBlob(self.ctx.gpa, argv.items) catch @panic("OOM");
        self.out.finish() catch {}; // keep our buffered -print output ordered before the child's
        return switch (proc.spawnWait(blob, self.ctx.stdin, self.ctx.stdout, self.ctx.stderr)) {
            .status => |st| st == 0,
            .spawn_err => |e| {
                self.ctx.errPrint("find: {s}: {s}\n", .{ argv.items[0], sys.strerror(sys.toErrno(e)) });
                self.any_error = true;
                return false;
            },
            .wait_err => {
                self.any_error = true;
                return false;
            },
        };
    }

    fn flushBatch(self: *Evaluator) void {
        const template = self.batched_argv orelse return;
        if (self.batched_paths.items.len == 0) return;
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        for (template) |a| {
            if (eq(a, "{}")) {
                for (self.batched_paths.items) |p| argv.append(self.ctx.gpa, p) catch @panic("OOM");
            } else {
                argv.append(self.ctx.gpa, a) catch @panic("OOM");
            }
        }
        const blob = proc.argvBlob(self.ctx.gpa, argv.items) catch @panic("OOM");
        self.out.finish() catch {}; // ordering: flush our own output before the child's
        switch (proc.spawnWait(blob, self.ctx.stdin, self.ctx.stdout, self.ctx.stderr)) {
            .status => {},
            .spawn_err => |e| {
                self.ctx.errPrint("find: {s}: {s}\n", .{ argv.items[0], sys.strerror(sys.toErrno(e)) });
                self.any_error = true;
            },
            .wait_err => self.any_error = true,
        }
    }
};

// ============================================================================ traversal

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const Config = struct {
    root_idx: i32,
    post_order: bool,
    maxdepth: ?u32,
    mindepth: u32,
    now_s: i64,
};

fn traverse(ev: *Evaluator, cfg: Config, path: []const u8, depth: usize) void {
    if (ev.quit) return;
    const lst = sys.lstat(path) catch |e| {
        ev.runtimeErr(path, e);
        return;
    };
    const within_range = depth >= cfg.mindepth and (cfg.maxdepth == null or depth <= cfg.maxdepth.?);
    var prune = false;
    const fi = FileInfo{ .path = path, .basename = fsutil.basename(path), .st = lst, .now_s = cfg.now_s };

    if (!cfg.post_order and within_range) {
        _ = ev.eval(cfg.root_idx, &fi, &prune);
        if (ev.quit) return;
    }

    if (lst.is_dir and !prune and (cfg.maxdepth == null or depth < cfg.maxdepth.?)) {
        const names: [][]const u8 = fsutil.list(ev.ctx.gpa, path) catch |e| blk: {
            ev.runtimeErr(path, e);
            break :blk &.{};
        };
        std.mem.sort([]const u8, names, {}, lessThanStr);
        for (names) |name| {
            if (ev.quit) break;
            const child = fsutil.join(ev.ctx.gpa, path, name) catch @panic("OOM");
            traverse(ev, cfg, child, depth + 1);
        }
    }

    if (cfg.post_order and within_range and !ev.quit) {
        var prune2 = false;
        _ = ev.eval(cfg.root_idx, &fi, &prune2);
    }
}

// ============================================================================ run

fn wrapDefaultPrint(p: *Parser, root: i32) i32 {
    if (p.has_action) return root;
    const pr = p.make(.print_);
    return p.makeBin(.and_, root, pr);
}

pub fn run(ctx: *Ctx) u8 {
    if (ctx.args.len >= 2) {
        if (eq(ctx.args[1], "--help")) {
            cli.renderHelp(ctx, "find", help_doc);
            return 0;
        }
        if (eq(ctx.args[1], "--version")) {
            ctx.print(ctx.stdout, "find 0.1.0\n", .{});
            return 0;
        }
    }
    const args = ctx.args[1..];

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len > 0 and (a[0] == '-' or eq(a, "(") or eq(a, "!"))) break;
        paths.append(ctx.gpa, a) catch @panic("OOM");
    }
    if (paths.items.len == 0) paths.append(ctx.gpa, ".") catch @panic("OOM");

    const expr_tokens = args[i..];
    var parser = Parser{ .ctx = ctx, .tokens = expr_tokens };
    var root: i32 = undefined;
    if (expr_tokens.len == 0) {
        root = parser.make(.true_);
    } else {
        root = parser.parseOr();
        if (!parser.atEnd()) {
            ctx.errPrint("find: {s}: unexpected token in expression\n", .{parser.tok()});
            parser.failed = true;
        }
    }
    if (parser.failed) return 2;
    root = wrapDefaultPrint(&parser, root);

    const post_order = parser.depth_flag or parser.delete_flag;
    const now_s = @divFloor(sys.timeRealtimeMs() catch 0, 1000);

    var ev = Evaluator{ .ctx = ctx, .nodes = parser.nodes.items, .out = textio.BufOut.init(ctx.stdout) };
    const cfg = Config{ .root_idx = root, .post_order = post_order, .maxdepth = parser.maxdepth, .mindepth = parser.mindepth, .now_s = now_s };

    for (paths.items) |p| {
        if (ev.quit) break;
        traverse(&ev, cfg, p, 0);
    }
    ev.flushBatch();
    ev.out.finish() catch {};

    return if (ev.any_error) 1 else 0;
}
