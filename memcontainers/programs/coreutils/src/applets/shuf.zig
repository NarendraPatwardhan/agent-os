//! `shuf` -- docs/analysis/uutils-applets.md "shuf": shuffle input lines (default:
//! read FILE/stdin, `\n`- or NUL-separated), or `-e ARG...` (echo mode: shuffle the
//! operands themselves), or `-i LO-HI` (range mode: shuffle the integers LO..=HI).
//! `-n/--head-count COUNT` caps output (repeated `-n` takes the MIN, an intentional
//! GNU quirk); `-o FILE` redirects output (opened/truncated even when `-n 0` makes
//! the run a no-op); `-r/--repeat` draws WITH replacement (an unbounded `-r` with no
//! `-n` loops `u64::MAX` times, matching the oracle -- never exercised without a
//! `-n` bound in the corpus); `-z/--zero-terminated` uses NUL instead of `\n`.
//!
//! Three interchangeable entropy sources, dispatched through one Lemire-bounded
//! "generate at most N" primitive feeding a shared left-to-right partial
//! Fisher-Yates (the same recipe the non-repeat path uses for ALL of file/echo/
//! range mode -- verified algebraically equivalent to the reference's separate
//! lazy/hashmap-backed `NonrepeatingIterator` for range mode, see the ledger):
//!
//!   - default: raw OS entropy via `sys.randomBytes` (getrandom/random_get/
//!     mc_sys_random depending on backend) -- NOT byte-parity-tested (nondeterministic
//!     by construction), only structurally (the permutation-property unit test).
//!   - `--random-seed=STRING` (uutils extension, DOCUMENTED STABLE, byte-parity
//!     tested): SHA3-256(seed) -> ChaCha12 (rand_chacha's ORIGINAL 64-bit-counter,
//!     64-bit-nonce variant -- constants/key/counter/nonce layout, 6 double-rounds,
//!     final add-back, little-endian word serialization) -> `next_u64` pairs of
//!     `next_u32` words -> Lemire's nearly-divisionless bounded generator.
//!     VERIFIED byte-for-byte against the pinned oracle binary during development
//!     (`shuf --random-seed=abc -i 1-10`, echo mode, `-r`, and more -- see
//!     docs/parity-ledger.md) via a throwaway harness before any corpus was
//!     authored, per the milestone brief's requirement.
//!   - `--random-source=FILE`: GNU's own reverse-engineered byte-consumption
//!     adapter (`RandomSourceAdapter` below) -- rejection sampling one byte at a
//!     time with leftover-entropy recycling, ALSO verified byte-for-byte against
//!     the oracle with a pinned-bytes fixture.
//!
//! Scope cut (ledgered): range mode always materializes the full LO..=HI array
//! (skips the reference's hashmap-backed sparse representation used only to save
//! memory on huge ranges with a small `-n`); output-identical for every range this
//! port's corpus exercises, just not memory-optimal for adversarially huge ranges.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const textio = @import("../core/textio.zig");
const hash = @import("../engines/hash.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Allocator = std.mem.Allocator;

const spec = cli.Spec{
    .name = "shuf",
    .flags = &.{
        cli.flagOpt('e', "echo", "treat each ARG as an input line"),
        cli.valueOpt('i', "input-range", "treat each number LO through HI as an input line"),
        cli.valueOpt('n', "head-count", "output at most COUNT lines"),
        cli.valueOpt('o', "output", "write result to FILE instead of standard output"),
        cli.valueOpt(null, "random-seed", "seed with STRING for reproducible output"),
        cli.valueOpt(null, "random-source", "get random bytes from FILE"),
        cli.flagOpt('r', "repeat", "output lines can be repeated"),
        cli.flagOpt('z', "zero-terminated", "line delimiter is NUL, not newline"),
    },
    .positionals = .{ .name = "[FILE | ARG...]", .min = 0, .max = null },
    // NOT allow_hyphen_values: verified against the oracle that a hyphen-prefixed
    // echo arg like `shuf -e -1 -2 -3` is REJECTED (`error: unexpected argument
    // '-1' found`, exit 1), not silently accepted as a positional -- clap does not
    // apply a "looks like a negative number" heuristic here. `--` still lets a
    // caller pass a literal hyphen-leading FILE/ARG.
    .help = .{
        .summary = "generate a random permutation of input lines, ARGs, or an integer range",
        .synopsis = &.{
            "shuf [OPTION]... [FILE]",
            "shuf -e [OPTION]... [ARG]...",
            "shuf -i LO-HI [OPTION]...",
        },
        .description =
        \\Writes a random permutation of its input to standard output, one item per
        \\line ('\0'-terminated instead with -z). The input is, by default, the lines of
        \\FILE (or standard input if FILE is "-" or omitted); with -e/--echo, the input
        \\is the ARG operands themselves; with -i/--input-range=LO-HI, the input is
        \\every integer from LO through HI inclusive. -n/--head-count COUNT limits
        \\output to at most COUNT items via a partial Fisher-Yates shuffle (only the
        \\requested prefix is ever computed); if -n is given more than once, the
        \\smallest of the given counts wins. -r/--repeat instead draws COUNT items
        \\independently WITH replacement.
        \\
        \\Randomness comes from one of three interchangeable sources feeding the same
        \\Lemire-bounded generator and left-to-right partial Fisher-Yates: raw OS
        \\entropy by default (nondeterministic); --random-seed=STRING, which derives a
        \\ChaCha12 stream from SHA3-256(STRING) for reproducible output; or
        \\--random-source=FILE, GNU's own byte-consumption scheme for reading randomness
        \\from a file. --random-seed and --random-source are mutually exclusive.
        ,
        .operands =
        \\With neither -e nor -i: an optional FILE ("-" or omitted means standard
        \\input); at most one FILE may be given. With -e/--echo: zero or more ARG
        \\operands, each treated as one input line. With -i/--input-range=LO-HI: no
        \\operands are accepted (LO and HI come from -i itself, not from operands).
        ,
        .exit = &.{
            .{ .code = 0, .when = "success, including -n 0 (which still creates/truncates -o's FILE but writes nothing)" },
            .{ .code = 1, .when = "a usage error; -e combined with -i, or --random-seed combined with --random-source; an invalid --input-range or --head-count value; more than one FILE (or any positional given together with -i); -r with no lines to repeat from; a FILE/--random-source/-o path that could not be opened; a FILE or standard-input read error; or --random-source running out of bytes (or another read failure) mid-shuffle" },
        },
        .deviations = &.{
            "--random-seed=STRING does not exist in plain GNU shuf; it is a uutils extension for reproducible output (SHA3-256(seed) -> ChaCha12 -> Lemire-bounded generation -> Fisher-Yates), included here because it was verified byte-for-byte against the reference implementation.",
            "-i/--input-range mode always materializes the full LO..HI array in memory rather than the reference's sparse/hashmap representation, which exists only to bound memory for huge ranges combined with a small -n; output is identical for every range exercised, just not memory-optimal for adversarially huge ranges.",
            "Usage-error messages reproduce the applet's own single diagnostic line (e.g. \"shuf: unexpected argument '<arg>' found\") but drop the reference's second line (\"Try '<argv0> shuf --help' for more information.\"), which embeds a non-reproducible host build path.",
        },
        .examples = &.{
            .{ .cmd = "shuf --random-seed=abc -i 1-10", .note = "deterministic permutation \"8 4 1 5 3 9 2 10 6 7\" -- --random-seed is a uutils extension not present in plain GNU shuf" },
            .{ .cmd = "shuf -n5 -n2 -i 1-100", .note = "-n is given twice (5, then 2); the minimum (2) wins and prints 2 random numbers from 1..100 -- an intentional GNU quirk, not last-value-wins" },
            .{ .cmd = "shuf -e -n1 apple banana cherry", .note = "echo mode: prints exactly one of the three ARGs, chosen uniformly at random" },
        },
    },
};

// ============================================================================ ChaCha12 (rand_chacha original variant)

const CHACHA_CONST = [4]u32{ 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 };

fn rotl32(x: u32, n: u5) u32 {
    return (x << n) | (x >> @intCast(32 - @as(u6, n)));
}

fn chachaQr(state: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl32(state[d], 16);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl32(state[b], 12);
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl32(state[d], 8);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl32(state[b], 7);
}

/// One double-round: a column round then a diagonal round (8 quarter-rounds).
/// ChaCha12 = 6 double-rounds.
fn chachaDoubleRound(state: *[16]u32) void {
    chachaQr(state, 0, 4, 8, 12);
    chachaQr(state, 1, 5, 9, 13);
    chachaQr(state, 2, 6, 10, 14);
    chachaQr(state, 3, 7, 11, 15);
    chachaQr(state, 0, 5, 10, 15);
    chachaQr(state, 1, 6, 11, 12);
    chachaQr(state, 2, 7, 8, 13);
    chachaQr(state, 3, 4, 9, 14);
}

/// One 64-byte (16-word) ChaCha12 block: constants(4) / key(8) / counter(2, 64-bit
/// little half first) / nonce(2, 64-bit -- always zero, `from_seed` never sets a
/// custom stream). Final add-back of the original state, per the ChaCha spec.
fn chacha12Block(key: [8]u32, counter: u64, nonce: u64) [16]u32 {
    var state: [16]u32 = undefined;
    state[0..4].* = CHACHA_CONST;
    state[4..12].* = key;
    state[12] = @truncate(counter);
    state[13] = @truncate(counter >> 32);
    state[14] = @truncate(nonce);
    state[15] = @truncate(nonce >> 32);
    var working = state;
    var i: usize = 0;
    while (i < 6) : (i += 1) chachaDoubleRound(&working);
    var out: [16]u32 = undefined;
    for (0..16) |j| out[j] = working[j] +% state[j];
    return out;
}

const ChaCha12 = struct {
    key: [8]u32,
    counter: u64 = 0,
    nonce: u64 = 0,
    block: [16]u32 = undefined,
    idx: usize = 16, // forces a refill on the first call

    fn fromSeedHash(seed_hash: [32]u8) ChaCha12 {
        var key: [8]u32 = undefined;
        for (0..8) |i| key[i] = std.mem.readInt(u32, seed_hash[i * 4 ..][0..4], .little);
        return .{ .key = key };
    }

    fn nextU32(self: *ChaCha12) u32 {
        if (self.idx >= 16) {
            self.block = chacha12Block(self.key, self.counter, self.nonce);
            self.counter +%= 1;
            self.idx = 0;
        }
        const v = self.block[self.idx];
        self.idx += 1;
        return v;
    }

    /// rand_core's standard `next_u64` via two `next_u32` calls: first word is the
    /// LOW 32 bits, second is the HIGH 32 bits.
    fn nextU64(self: *ChaCha12) u64 {
        const lo = self.nextU32();
        const hi = self.nextU32();
        return @as(u64, lo) | (@as(u64, hi) << 32);
    }
};

/// Raw OS entropy wrapped in the same `nextU64` shape as `ChaCha12`, so the shared
/// Lemire/Fisher-Yates code below is oblivious to which source feeds it.
const DefaultSource = struct {
    fn nextU64(_: *DefaultSource) u64 {
        var buf: [8]u8 = undefined;
        sys.randomBytes(&buf) catch @memset(&buf, 0); // entropy failure: degrade, don't crash
        return std.mem.readInt(u64, &buf, .little);
    }
};

/// Lemire's nearly-divisionless bounded generator (uutils' `random_seed.rs`
/// `generate_at_most`, verified byte-for-byte against the oracle). Works for any
/// `src` exposing `nextU64(*Src) u64` -- `ChaCha12` and `DefaultSource` both qualify.
fn lemireGenerateAtMost(src: anytype, at_most: u64) u64 {
    if (at_most == std.math.maxInt(u64)) return src.nextU64();
    const s: u64 = at_most + 1;
    var x: u64 = src.nextU64();
    var m: u128 = @as(u128, x) * @as(u128, s);
    var l: u64 = @truncate(m);
    if (l < s) {
        const t: u64 = (0 -% s) % s;
        while (l < t) {
            x = src.nextU64();
            m = @as(u128, x) * @as(u128, s);
            l = @truncate(m);
        }
    }
    return @truncate(m >> 64);
}

// ============================================================================ --random-source adapter (compat_random_source.rs)

const RngError = error{EndOfRandomSource} || sys.Error;

/// GNU's own byte-consumption scheme for `--random-source`, reverse-engineered by
/// uutils (module doc there): rejection sampling one byte at a time with leftover
/// entropy recycled across calls. Verified byte-for-byte against the oracle with a
/// pinned-bytes fixture (see docs/parity-ledger.md).
const RandomSourceAdapter = struct {
    fd: sys.Fd,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    state: u64 = 0,
    entropy: u64 = 0,

    fn nextByte(self: *RandomSourceAdapter) RngError!u8 {
        if (self.pos >= self.len) {
            const n = try sys.read(self.fd, &self.buf);
            if (n == 0) return error.EndOfRandomSource;
            self.len = n;
            self.pos = 0;
        }
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn generateAtMost(self: *RandomSourceAdapter, at_most: u64) RngError!u64 {
        while (self.entropy < at_most) {
            const byte = try self.nextByte();
            self.state = self.state *% 256 +% byte;
            self.entropy = self.entropy *% 256 +% 255;
        }
        if (at_most == std.math.maxInt(u64)) {
            const val = self.state;
            self.entropy = 0;
            self.state = 0;
            return val;
        }
        const num_possibilities: u64 = at_most + 1;
        const margin: u64 = @intCast((@as(u128, self.entropy) + 1) % @as(u128, num_possibilities));
        const safe_zone: u64 = self.entropy - margin;
        if (self.state <= safe_zone) {
            const val = self.state % num_possibilities;
            self.state /= num_possibilities;
            self.entropy -= at_most;
            self.entropy /= num_possibilities;
            return val;
        }
        self.state %= num_possibilities;
        self.entropy %= num_possibilities;
        return self.generateAtMost(at_most);
    }
};

// ============================================================================ RNG dispatch + shared Fisher-Yates / choose

const RngMode = union(enum) {
    default: DefaultSource,
    seeded: ChaCha12,
    file: RandomSourceAdapter,
};

fn rngGenerateAtMost(rng: *RngMode, at_most: u64) RngError!u64 {
    return switch (rng.*) {
        .default => |*s| lemireGenerateAtMost(s, at_most),
        .seeded => |*s| lemireGenerateAtMost(s, at_most),
        .file => |*s| try s.generateAtMost(at_most),
    };
}

fn writeItem(out: *textio.BufOut, item: anytype) void {
    if (@TypeOf(item) == u64) {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{item}) catch unreachable;
        out.extend(s) catch return;
    } else {
        out.extend(item) catch return;
    }
}

fn handleRngError(ctx: *Ctx, e: RngError) u8 {
    switch (e) {
        error.EndOfRandomSource => ctx.errPrint("shuf: end of random source\n", .{}),
        else => ctx.errPrint("shuf: reading random bytes failed\n", .{}),
    }
    return 1;
}

/// `items` must be a mutable slice (`[]u64` or `[][]const u8`) -- the non-repeat
/// path swaps in place. Faithful port of `shuf_exec`: repeat mode draws WITH
/// replacement `head_count` times (an unbounded default head_count loops
/// `u64::MAX` times, matching the oracle); otherwise a left-to-right partial
/// Fisher-Yates yields `min(head_count, items.len)` items, each followed by `sep`
/// (including the very last one -- no special-casing).
fn shufExec(ctx: *Ctx, rng: *RngMode, out: *textio.BufOut, sep: u8, repeat: bool, head_count: u64, items: anytype) u8 {
    if (repeat) {
        if (items.len == 0) {
            ctx.errPrint("shuf: no lines to repeat\n", .{});
            return 1;
        }
        var i: u64 = 0;
        while (i < head_count) : (i += 1) {
            const idx: usize = @intCast(rngGenerateAtMost(rng, @intCast(items.len - 1)) catch |e| return handleRngError(ctx, e));
            writeItem(out, items[idx]);
            out.push(sep) catch return 0;
        }
        return 0;
    }
    const amount: usize = @intCast(@min(head_count, @as(u64, items.len)));
    var idx: usize = 0;
    while (idx < amount) : (idx += 1) {
        const draw = rngGenerateAtMost(rng, @intCast(items.len - idx - 1)) catch |e| return handleRngError(ctx, e);
        const other = idx + @as(usize, @intCast(draw));
        const tmp = items[idx];
        items[idx] = items[other];
        items[other] = tmp;
        writeItem(out, items[idx]);
        out.push(sep) catch return 0;
    }
    return 0;
}

// ============================================================================ input-range parsing

const Range = struct { lo: u64, hi: u64 };

const RangeResult = union(enum) {
    ok: Range,
    missing_dash,
    start_exceeds_end,
    invalid_number,
};

fn parseInputRange(s: []const u8) RangeResult {
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse return .missing_dash;
    const lo = std.fmt.parseInt(u64, s[0..dash], 10) catch return .invalid_number;
    const hi = std.fmt.parseInt(u64, s[dash + 1 ..], 10) catch return .invalid_number;
    if (lo <= hi or lo == hi +% 1) return .{ .ok = .{ .lo = lo, .hi = hi } };
    return .start_exceeds_end;
}

/// A single trailing separator is ignored (matches `split_seps`); if the LAST
/// segment (after splitting on every occurrence of `sep`) is empty, it is dropped
/// -- this only ever affects the final element, so "a\n\nb\n" keeps its middle
/// blank line but drops the trailing one.
fn splitSeps(gpa: Allocator, data: []const u8, sep: u8) [][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data, sep);
    while (it.next()) |part| list.append(gpa, part) catch @panic("OOM");
    if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) {
        _ = list.pop();
    }
    return list.toOwnedSlice(gpa) catch @panic("OOM");
}

// ============================================================================ run

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        // uutils-family ruling (parity-ledger.md): clap parse errors exit 1.
        .exit => |c| return if (c == 2) 1 else c,
        .ok => |mm| mm,
    };

    const has_echo = m.has("echo");
    const has_range = m.has("input-range");
    if (has_echo and has_range) {
        ctx.errPrint("shuf: the argument '--echo' cannot be used with '--input-range <LO-HI>'\n", .{});
        return 1;
    }
    const positionals = m.positionalSlice();

    const Mode = union(enum) {
        default_file: []const u8,
        echo: []const []const u8,
        range: Range,
    };
    var mode: Mode = undefined;
    if (has_echo) {
        mode = .{ .echo = positionals };
    } else if (has_range) {
        if (positionals.len > 0) {
            ctx.errPrint("shuf: the argument '--input-range <LO-HI>' cannot be used with one or more of the other specified arguments\n", .{});
            return 1;
        }
        switch (parseInputRange(m.value("input-range").?)) {
            .ok => |r| mode = .{ .range = r },
            .missing_dash => {
                ctx.errPrint("shuf: missing '-'\n", .{});
                return 1;
            },
            .start_exceeds_end => {
                ctx.errPrint("shuf: start exceeds end\n", .{});
                return 1;
            },
            .invalid_number => {
                ctx.errPrint("shuf: invalid input range\n", .{});
                return 1;
            },
        }
    } else {
        if (positionals.len > 1) {
            ctx.errPrint("shuf: unexpected argument '{s}' found\n", .{positionals[1]});
            return 1;
        }
        mode = .{ .default_file = if (positionals.len > 0) positionals[0] else "-" };
    }

    const has_seed = m.has("random-seed");
    const has_src = m.has("random-source");
    if (has_seed and has_src) {
        ctx.errPrint("shuf: the argument '--random-seed <STRING>' cannot be used with '--random-source <FILE>'\n", .{});
        return 1;
    }

    var head_count: u64 = std.math.maxInt(u64);
    for (m.values("head-count")) |v| {
        const n = std.fmt.parseInt(u64, v, 10) catch {
            ctx.errPrint("shuf: invalid line count: '{s}'\n", .{v});
            return 1;
        };
        if (n < head_count) head_count = n;
    }

    const repeat = m.has("repeat");
    const sep: u8 = if (m.has("zero-terminated")) 0 else '\n';

    var out_fd = ctx.stdout;
    var opened_out = false;
    if (m.value("output")) |path| {
        out_fd = sys.open(path, .{ .write = true, .create = true, .trunc = true }) catch |e| {
            ctx.errPrint("shuf: failed to open '{s}' for writing: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
        opened_out = true;
    }
    defer if (opened_out) sys.close(out_fd);
    var out = textio.BufOut.init(out_fd);

    // Matches the oracle: an output file is still created/truncated by `-n 0`, but
    // nothing else (no input file is even opened) happens.
    if (head_count == 0) {
        out.finish() catch {};
        return 0;
    }

    var rng: RngMode = undefined;
    if (has_src) {
        const path = m.value("random-source").?;
        const fd = sys.open(path, .{ .read = true }) catch |e| {
            ctx.errPrint("shuf: failed to open random source '{s}': {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
            return 1;
        };
        rng = .{ .file = .{ .fd = fd } };
    } else if (has_seed) {
        const seed_str = m.value("random-seed").?;
        var d = hash.Digest.init(.sha3_256, 32);
        d.update(seed_str);
        var seed_hash: [32]u8 = undefined;
        d.finalize(&seed_hash);
        rng = .{ .seeded = ChaCha12.fromSeedHash(seed_hash) };
    } else {
        rng = .{ .default = .{} };
    }
    defer if (rng == .file) sys.close(rng.file.fd);

    const rc: u8 = switch (mode) {
        .echo => |args| blk: {
            const items = ctx.gpa.dupe([]const u8, args) catch @panic("OOM");
            break :blk shufExec(ctx, &rng, &out, sep, repeat, head_count, items);
        },
        .range => |r| blk: {
            const len: usize = if (r.lo > r.hi) 0 else @intCast(r.hi - r.lo + 1);
            const items = ctx.gpa.alloc(u64, len) catch @panic("OOM");
            for (0..len) |i| items[i] = r.lo + i;
            break :blk shufExec(ctx, &rng, &out, sep, repeat, head_count, items);
        },
        .default_file => |path| blk: {
            const is_stdin = std.mem.eql(u8, path, "-");
            const data = if (is_stdin)
                textio.readAll(ctx.gpa, ctx.stdin) catch |e| {
                    ctx.errPrint("shuf: read error: {s}\n", .{sys.strerror(sys.toErrno(e))});
                    break :blk @as(u8, 1);
                }
            else read_file: {
                const fd = sys.open(path, .{ .read = true }) catch |e| {
                    ctx.errPrint("shuf: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
                    break :blk @as(u8, 1);
                };
                defer sys.close(fd);
                break :read_file textio.readAll(ctx.gpa, fd) catch |e| {
                    ctx.errPrint("shuf: read error: {s}\n", .{sys.strerror(sys.toErrno(e))});
                    break :blk @as(u8, 1);
                };
            };
            const items = splitSeps(ctx.gpa, data, sep);
            break :blk shufExec(ctx, &rng, &out, sep, repeat, head_count, items);
        },
    };

    out.finish() catch {};
    return rc;
}
