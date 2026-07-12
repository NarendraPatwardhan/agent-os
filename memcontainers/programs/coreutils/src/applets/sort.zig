//! `sort` -- DESIGN.md §1: THE largest hand-written applet (matrix:
//! "1122 lines" in the reference). External merge-sort with `-k` key grammar,
//! ordering modes (`-n -g -h -V`), transforms (`-f -d -i -b -r`), `-c`/`-C` check
//! mode, `-m` K-way merge mode, `-u`/`-s`/`-o`/`-t`/`-S`. `-h` is human-numeric-sort,
//! NOT help (only the literal long `--help` is help -- `cli.parse` already only
//! intercepts that exact token, so no special-casing is needed here).
//!
//! The reusable internals live under `src/engines/sort/` (like every other shared engine;
//! sort is the only applet with a multi-file core):
//!   engines/sort/key.zig    -- `-k` grammar + GNU begfield/limfield field extraction
//!   engines/sort/cmp.zig    -- parse_num/general/human, version_cmp, str_cmp, total_cmp
//!   engines/sort/engine.zig -- Batch, spool.Run spill, FANIN=16 reduce, K-way merge

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const spool = @import("../core/spool.zig");
const fsutil = @import("../core/fsutil.zig");
const sizes = @import("../core/sizes.zig");
const Ctx = @import("../ctx.zig").Ctx;

const key_mod = @import("../engines/sort/key.zig");
const cmp = @import("../engines/sort/cmp.zig");
const engine = @import("../engines/sort/engine.zig");

const Key = key_mod.Key;
const Mode = key_mod.Mode;

const spec = cli.Spec{
    .name = "sort",
    .flags = &.{
        cli.flagOpt('n', "numeric-sort", "compare according to string numerical value"),
        cli.flagOpt('g', "general-numeric-sort", "compare according to general numerical value"),
        cli.flagOpt('h', "human-numeric-sort", "compare human readable numbers (e.g., 2K 1G)"),
        cli.flagOpt('V', "version-sort", "natural sort of (version) numbers"),
        cli.flagOpt('f', "ignore-case", "fold lower case to upper case characters"),
        cli.flagOpt('d', "dictionary-order", "consider only blanks and alphanumeric characters"),
        cli.flagOpt('i', "ignore-nonprinting", "consider only printable characters"),
        cli.flagOpt('b', "ignore-leading-blanks", "ignore leading blanks"),
        cli.flagOpt('r', "reverse", "reverse the result of comparisons"),
        cli.valueOpt('k', "key", "sort via a key"),
        cli.valueOpt('t', "field-separator", "use SEP instead of non-blank to blank transition"),
        cli.flagOpt('u', "unique", "output only the first of an equal run"),
        cli.flagOpt('s', "stable", "stabilize sort by disabling last-resort comparison"),
        cli.valueOpt('o', "output", "write result to FILE instead of standard output"),
        cli.flagOpt('c', "check", "check for sorted input; do not sort"),
        cli.flagOpt('C', "check-silent", "like -c, but do not report first bad line"),
        cli.flagOpt('m', "merge", "merge already sorted files; do not sort"),
        cli.valueOpt('S', "buffer-size", "use SIZE for main memory buffer"),
    },
    .help = .{
        .summary = "sort lines of text files",
        .synopsis = &.{"sort [OPTION]... [FILE]..."},
        .description =
        \\Sorts the concatenated lines of each FILE (default standard input)
        \\and writes the result to standard output (or -o FILE). By default
        \\lines compare in raw byte order; -n/-g/-h/-V switch to numeric,
        \\general-numeric, human-numeric (e.g. 2K, 1G), or version-number
        \\comparison, and -k KEYSPEC restricts the comparison to one or more
        \\field ranges (repeatable). -h selects human-numeric sort -- it is
        \\NOT a request for help.
        \\
        \\-c/-C check whether input is already sorted instead of sorting it;
        \\-m merges FILE operands that are already individually sorted,
        \\without re-sorting them. Large input is handled with bounded
        \\memory: -S sets the in-memory budget (default 1 MiB) past which
        \\runs are spilled to a scratch file and combined in a final external
        \\K-way merge.
        ,
        .operands = "FILE...   input files; \"-\" means standard input; with no FILE, reads standard input.",
        .exit = &.{
            .{ .code = 0, .when = "success (or, with -c/-C, the input is already correctly sorted)" },
            .{ .code = 1, .when = "with -c/-C, the input is not sorted (or a duplicate was rejected under -u); or a write error occurred while producing output" },
            .{ .code = 2, .when = "a usage error (a bad -k/-t/-S argument, conflicting options) or a FILE could not be read" },
        },
        .deviations = &.{
            "When more than one of -n/-g/-h/-V is given together, a fixed precedence -g > -h > -V > -n applies, rather than GNU's last-flag-wins.",
            "-c/-C report disorder as `sort: disorder detected` followed by the offending line on stderr, instead of GNU's `sort: FILE:LINE: disorder: LINE`.",
            "Per-key M (month name) and R (random) letters are accepted but behave as an explicit default byte-wise comparison; they do not actually sort by month name or randomize.",
        },
        .examples = &.{
            .{ .cmd = "sort -k2,2n data.txt", .note = "sort by the second field, numerically" },
            .{ .cmd = "sort -u -o data.txt data.txt", .note = "sort in place, keeping the first line of each duplicate group" },
            .{ .cmd = "sort -m sorted1.txt sorted2.txt", .note = "merge two already-sorted files without re-sorting" },
        },
        .see_also = "uniq (collapse adjacent duplicates after sorting); comm (compare two sorted files).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

const DEFAULT_BUFFER: usize = 1024 * 1024;

/// digits + optional single-letter suffix (k/K m/M g/G x1024^n, b x1, case-insensitive).
/// Matches the matrix's "k/m/g suffixes, default 1 MiB". source: spec for b/case handling.
fn parseBufferSize(s: []const u8) ?usize {
    const v = sizes.parse(s, .{ .base = 1024, .case_insensitive = true, .allow_b = true }) orelse return null;
    return std.math.cast(usize, v);
}

/// Global order-mode precedence when more than one of -n/-g/-h/-V is given: since
/// `cli.zig`'s `Matches` doesn't retain cross-option argv order, a fixed precedence
/// is used instead of "last flag wins" (source: spec, DESIGN.md §2):
/// -g > -h > -V > -n.
fn globalMode(m: cli.Matches) Mode {
    if (m.has("general-numeric-sort")) return .general;
    if (m.has("human-numeric-sort")) return .human;
    if (m.has("version-sort")) return .version;
    if (m.has("numeric-sort")) return .numeric;
    return .default;
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const global_mode = globalMode(m);
    const global_fold = m.has("ignore-case");
    const global_dict = m.has("dictionary-order");
    const global_ip = m.has("ignore-nonprinting");
    const global_blanks = m.has("ignore-leading-blanks");
    const global_reverse = m.has("reverse");
    const unique = m.has("unique");
    // `-u` implies `-s`: with unique output, comparison is by key only -- the
    // whole-line last-resort is disabled so the FIRST line of each key-equal group
    // (in input order) is the one kept, matching GNU (matrix silent; ruling in
    // DESIGN.md §2).
    const stable = m.has("stable") or unique;
    const check = m.has("check");
    const check_silent = m.has("check-silent");
    const merge_mode = m.has("merge");

    var sep: ?u8 = null;
    if (m.value("field-separator")) |v| {
        if (v.len != 1) {
            ctx.errPrint("sort: the delimiter must be a single character\n", .{});
            return 2;
        }
        sep = v[0];
    }

    var keys_list: std.ArrayListUnmanaged(Key) = .empty;
    for (m.values("key")) |kspec| {
        const k = key_mod.parseKeySpec(kspec) orelse {
            ctx.errPrint("sort: invalid key specification '{s}'\n", .{kspec});
            return 2;
        };
        keys_list.append(ctx.gpa, key_mod.resolveAgainstGlobal(k, global_mode, global_fold, global_dict, global_ip, global_blanks, global_reverse)) catch @panic("OOM");
    }
    var keys: []const Key = keys_list.items;
    if (keys.len == 0) {
        const owned = ctx.gpa.alloc(Key, 1) catch @panic("OOM");
        owned[0] = key_mod.implicitKey(global_mode, global_fold, global_dict, global_ip, global_blanks, global_reverse);
        keys = owned;
    }

    var buffer_size: usize = DEFAULT_BUFFER;
    if (m.value("buffer-size")) |v| {
        buffer_size = parseBufferSize(v) orelse {
            ctx.errPrint("sort: invalid --buffer-size argument '{s}'\n", .{v});
            return 2;
        };
    }

    const output_path: ?[]const u8 = m.value("output");
    const positionals = m.positionalSlice();

    if (check or check_silent) {
        return checkMode(ctx, positionals, keys, sep, stable, global_reverse, unique, check_silent);
    }
    if (merge_mode) {
        return mergeMode(ctx, positionals, output_path, keys, sep, stable, global_reverse, unique);
    }
    return normalSort(ctx, positionals, output_path, keys, sep, stable, global_reverse, unique, buffer_size);
}

// ---------------------------------------------------------------- check mode

const CheckState = struct {
    ctx: *Ctx,
    keys: []const Key,
    sep: ?u8,
    stable: bool,
    global_reverse: bool,
    unique: bool,
    silent: bool,
    prev: ?[]u8 = null,
    disorder: bool = false,
};

fn checkOnLine(cs: *CheckState, line: []const u8) anyerror!void {
    if (cs.prev) |p| {
        const c = cmp.totalCmp(p, line, cs.keys, cs.sep, cs.stable, cs.global_reverse);
        const bad = c == .gt or (cs.unique and cmp.keysEqual(p, line, cs.keys, cs.sep));
        if (bad) {
            cs.disorder = true;
            if (!cs.silent) {
                cs.ctx.errPrint("sort: disorder detected\n", .{});
                cs.ctx.errPrint("{s}\n", .{line});
            }
            return error.Disorder;
        }
    }
    cs.prev = cs.ctx.gpa.dupe(u8, line) catch return error.ENOMEM;
}

fn checkMode(ctx: *Ctx, positionals: []const []const u8, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool, unique: bool, silent: bool) u8 {
    var cs = CheckState{ .ctx = ctx, .keys = keys, .sep = sep, .stable = stable, .global_reverse = global_reverse, .unique = unique, .silent = silent };
    const rc = textio.streamLines(ctx, "sort", positionals, &cs, checkOnLine);
    if (cs.disorder) return 1;
    if (rc != 0) return 2;
    return 0;
}

// ---------------------------------------------------------------- merge mode

/// True if `a` and `b` name the same file. The kernel stat record carries no dev/ino, so
/// identity is by canonical path (resolves `.`/`..`, symlinks, trailing slashes, abs-vs-rel)
/// -- catching aliases like `./foo` vs `foo` that plain string equality misses. Falls back
/// to byte equality if either path can't be canonicalized.
fn samePath(gpa: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    const ca = fsutil.canonicalize(gpa, a, .none);
    const cb = fsutil.canonicalize(gpa, b, .none);
    if (ca != null and cb != null) return std.mem.eql(u8, ca.?, cb.?);
    return std.mem.eql(u8, a, b);
}

fn mergeMode(ctx: *Ctx, positionals: []const []const u8, output_path: ?[]const u8, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool, unique: bool) u8 {
    const gpa = ctx.gpa;
    var single_dash = [1][]const u8{"-"};
    const files: []const []const u8 = if (positionals.len == 0) &single_dash else positionals;

    var sources: std.ArrayListUnmanaged(engine.Source) = .empty;
    var staged_runs: std.ArrayListUnmanaged(*spool.Run) = .empty;
    var opened_fds: std.ArrayListUnmanaged(sys.Fd) = .empty;

    for (files) |name| {
        const is_stdin = std.mem.eql(u8, name, "-");
        const aliases_output = !is_stdin and output_path != null and samePath(gpa, name, output_path.?);
        if (aliases_output) {
            const fd = sys.open(name, .{ .read = true }) catch |e| {
                ctx.errPrint("sort: cannot read: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
                return 2;
            };
            const content = textio.readAll(gpa, fd) catch {
                sys.close(fd);
                ctx.errPrint("sort: {s}: read error\n", .{name});
                return 2;
            };
            sys.close(fd);
            if (spool.SpoolFile.create()) |sf| {
                const run_ptr = gpa.create(spool.Run) catch @panic("OOM");
                run_ptr.* = spool.Run.init(sf);
                // Propagate scratch write/rewind failures: staging a partial or
                // mis-positioned run would silently corrupt the merge (input is already
                // read into memory, so a failed stage means we must abort, not continue).
                run_ptr.writeAll(content) catch {
                    ctx.errPrint("sort: write error\n", .{});
                    return 1;
                };
                run_ptr.rewindForRead() catch {
                    ctx.errPrint("sort: write error\n", .{});
                    return 1;
                };
                staged_runs.append(gpa, run_ptr) catch @panic("OOM");
                sources.append(gpa, .{ .run = run_ptr }) catch @panic("OOM");
            } else {
                const b = gpa.create(engine.Batch) catch @panic("OOM");
                b.* = engine.Batch{};
                engine.fillBatchFromBytes(gpa, b, content) catch @panic("OOM");
                const mc = gpa.create(engine.MemCursor) catch @panic("OOM");
                mc.* = .{ .batch = b };
                sources.append(gpa, .{ .mem = mc }) catch @panic("OOM");
            }
            continue;
        }
        const fd = if (is_stdin) ctx.stdin else sys.open(name, .{ .read = true }) catch |e| {
            ctx.errPrint("sort: cannot read: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
            return 2;
        };
        opened_fds.append(gpa, if (is_stdin) -1 else fd) catch @panic("OOM");
        const lr = gpa.create(textio.LineReader) catch @panic("OOM");
        lr.* = textio.LineReader.init(fd);
        sources.append(gpa, .{ .reader = lr }) catch @panic("OOM");
    }

    const is_stdout = output_path == null;
    const out_fd = if (is_stdout) ctx.stdout else sys.open(output_path.?, .{ .write = true, .create = true, .trunc = true }) catch |e| {
        ctx.errPrint("sort: {s}: {s}\n", .{ output_path.?, sys.strerror(sys.toErrno(e)) });
        return 2;
    };

    var sink = engine.OutSink.init(out_fd);
    var rc: u8 = 0;
    if (engine.mergeToSink(gpa, &sink, sources.items, keys, sep, stable, global_reverse, unique)) |_| {
        sink.finish() catch {
            ctx.errPrint("sort: write error\n", .{});
            rc = 1;
        };
    } else |_| {
        ctx.errPrint("sort: write error\n", .{});
        rc = 1;
    }

    if (!is_stdout) sys.close(out_fd);
    for (opened_fds.items) |fd| {
        if (fd >= 0) sys.close(fd);
    }
    for (staged_runs.items) |r| r.deinit();
    return rc;
}

// ---------------------------------------------------------------- normal sort

fn normalSort(ctx: *Ctx, positionals: []const []const u8, output_path: ?[]const u8, keys: []const Key, sep: ?u8, stable: bool, global_reverse: bool, unique: bool, buffer_size: usize) u8 {
    const gpa = ctx.gpa;
    var single_dash = [1][]const u8{"-"};
    const files: []const []const u8 = if (positionals.len == 0) &single_dash else positionals;

    var runs: std.ArrayListUnmanaged(spool.Run) = .empty;
    var batch = engine.Batch{};
    var spool_avail = true;

    for (files) |name| {
        const is_stdin = std.mem.eql(u8, name, "-");
        const fd = if (is_stdin) ctx.stdin else sys.open(name, .{ .read = true }) catch |e| {
            ctx.errPrint("sort: cannot read: {s}: {s}\n", .{ name, sys.strerror(sys.toErrno(e)) });
            return 2;
        };
        defer if (!is_stdin) sys.close(fd);

        var lr = textio.LineReader.init(fd);
        while (true) {
            const maybe = lr.next() catch {
                ctx.errPrint("sort: {s}: read error\n", .{name});
                return 2;
            };
            const line = maybe orelse break;
            batch.addLine(gpa, line) catch @panic("OOM");
            if (spool_avail and batch.approxBytes() >= buffer_size) {
                if (engine.spillBatch(&batch, keys, sep, stable, global_reverse)) |spilled| {
                    runs.append(gpa, spilled) catch @panic("OOM");
                    batch = engine.Batch{};
                } else {
                    spool_avail = false;
                }
            }
        }
    }

    var sources: std.ArrayListUnmanaged(engine.Source) = .empty;
    var reduced: []spool.Run = &.{};
    if (runs.items.len > 0) {
        reduced = engine.reduceRuns(gpa, runs.items, keys, sep, stable, global_reverse) catch |e| switch (e) {
            error.OutOfMemory => @panic("OOM"),
            else => {
                ctx.errPrint("sort: write error\n", .{});
                return 1;
            },
        };
        for (reduced) |*r| r.rewindForRead() catch {
            ctx.errPrint("sort: write error\n", .{});
            return 1;
        };
        for (reduced) |*r| sources.append(gpa, .{ .run = r }) catch @panic("OOM");
    }
    var mc: engine.MemCursor = undefined;
    if (!batch.isEmpty() or runs.items.len == 0) {
        batch.sort(keys, sep, stable, global_reverse);
        mc = .{ .batch = &batch };
        sources.append(gpa, .{ .mem = &mc }) catch @panic("OOM");
    }

    const is_stdout = output_path == null;
    const out_fd = if (is_stdout) ctx.stdout else sys.open(output_path.?, .{ .write = true, .create = true, .trunc = true }) catch |e| {
        ctx.errPrint("sort: {s}: {s}\n", .{ output_path.?, sys.strerror(sys.toErrno(e)) });
        return 2;
    };
    defer if (!is_stdout) sys.close(out_fd);

    var sink = engine.OutSink.init(out_fd);
    var rc: u8 = 0;
    if (engine.mergeToSink(gpa, &sink, sources.items, keys, sep, stable, global_reverse, unique)) |_| {
        sink.finish() catch {
            ctx.errPrint("sort: write error\n", .{});
            rc = 1;
        };
    } else |_| {
        ctx.errPrint("sort: write error\n", .{});
        rc = 1;
    }
    for (reduced) |*r| r.deinit();
    return rc;
}
