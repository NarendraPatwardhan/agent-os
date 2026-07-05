//! Declarative flag parser replacing clap's used subset (DESIGN.md §6.1): short flag
//! clustering (`-ne`), long opts (`--wrap=76` / `--wrap 76`), flag vs value kinds,
//! repeatable options, `allow_hyphen_values`/`trailing_var_arg`, auto `--help`/
//! `--version` (stdout, exit 0), parse errors (`<name>: <problem>` to stderr, exit 2).
//!
//! Applets that hand-parse in the Rust original (echo, printf, test, find, kill, nice,
//! xargs' trailing command) hand-parse here too -- don't force them through this. Use
//! `leadingHelpOnly` for the first-arg-only `--help`/`--version` twins (echo, printf,
//! nice, nohup, true, false, yes, clear).

const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const help_mod = @import("help.zig");

pub const Help = help_mod.Help;

pub const OptKind = enum { flag, value };

pub const Opt = struct {
    short: ?u8 = null,
    long: ?[]const u8 = null,
    kind: OptKind = .flag,
    help: []const u8 = "",
};

pub fn flagOpt(short: ?u8, long: ?[]const u8, help: []const u8) Opt {
    return .{ .short = short, .long = long, .kind = .flag, .help = help };
}

pub fn valueOpt(short: ?u8, long: ?[]const u8, help: []const u8) Opt {
    return .{ .short = short, .long = long, .kind = .value, .help = help };
}

pub const Positionals = struct {
    name: []const u8 = "ARGS",
    min: usize = 0,
    max: ?usize = null,
};

pub const Spec = struct {
    name: []const u8,
    version: []const u8 = "0.1.0",
    flags: []const Opt = &.{},
    /// Structured `--help` (core/help.zig). When set, `--help` renders it (with the
    /// OPTIONS section auto-derived from `flags`); when null, a terse generic usage is
    /// printed instead.
    help: ?help_mod.Help = null,
    positionals: Positionals = .{},
    /// Values (and positionals) may start with '-' without being mistaken for an
    /// unknown option.
    allow_hyphen_values: bool = false,
    /// After the first positional is seen, every remaining token is a positional
    /// verbatim (no more flag parsing) -- e.g. xargs' trailing command.
    trailing_var_arg: bool = false,
};

/// The canonical key a match is stored/looked-up under: the long name if the option
/// has one (so `-w76` and `--width=76` collapse to the same key), else a
/// gpa-allocated single-character string (must be allocated, not a stack temporary --
/// the returned slice is retained by the `Matches` hash map after this call returns).
fn optKey(gpa: std.mem.Allocator, o: Opt) []const u8 {
    if (o.long) |l| return l;
    const buf = gpa.alloc(u8, 1) catch @panic("OOM");
    buf[0] = o.short.?;
    return buf;
}

pub const Matches = struct {
    gpa: std.mem.Allocator,
    counts: std.StringHashMapUnmanaged(usize) = .empty,
    vals: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty,
    positionals: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn flagCount(self: *const Matches, name: []const u8) usize {
        return self.counts.get(name) orelse 0;
    }

    pub fn has(self: *const Matches, name: []const u8) bool {
        return self.flagCount(name) > 0;
    }

    /// Last-wins value, matching GNU getopt_long semantics for repeated options.
    pub fn value(self: *const Matches, name: []const u8) ?[]const u8 {
        const list = self.vals.get(name) orelse return null;
        if (list.items.len == 0) return null;
        return list.items[list.items.len - 1];
    }

    pub fn values(self: *const Matches, name: []const u8) []const []const u8 {
        const list = self.vals.get(name) orelse return &.{};
        return list.items;
    }

    pub fn positionalSlice(self: *const Matches) []const []const u8 {
        return self.positionals.items;
    }
};

pub const ParseResult = union(enum) {
    ok: Matches,
    /// help/version handled (exit 0) or a parse error was reported (exit 2).
    exit: u8,
};

fn findShort(spec: Spec, c: u8) ?Opt {
    for (spec.flags) |o| {
        if (o.short) |s| if (s == c) return o;
    }
    return null;
}

fn findLong(spec: Spec, name: []const u8) ?Opt {
    for (spec.flags) |o| {
        if (o.long) |l| if (std.mem.eql(u8, l, name)) return o;
    }
    return null;
}

fn record(m: *Matches, key: []const u8, val: ?[]const u8) !void {
    const gop = try m.counts.getOrPut(m.gpa, key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
    if (val) |v| {
        const lgop = try m.vals.getOrPut(m.gpa, key);
        if (!lgop.found_existing) lgop.value_ptr.* = .empty;
        try lgop.value_ptr.append(m.gpa, v);
    }
}

/// Formats one flag's left column: `-x`, `--long`, or `-x, --long`, with `=VALUE`
/// appended for value options (the spec carries no metavar, so a generic VALUE is used).
fn formatFlags(gpa: std.mem.Allocator, o: Opt) []const u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    if (o.short) |s| {
        b.append(gpa, '-') catch {};
        b.append(gpa, s) catch {};
    }
    if (o.long) |l| {
        if (o.short != null) b.appendSlice(gpa, ", ") catch {};
        b.appendSlice(gpa, "--") catch {};
        b.appendSlice(gpa, l) catch {};
    }
    if (o.kind == .value) b.appendSlice(gpa, "=VALUE") catch {};
    return b.items;
}

/// Builds the help OPTIONS rows from a spec's flags (help text already lives on each Opt).
fn helpOpts(gpa: std.mem.Allocator, spec: Spec) []const help_mod.Opt {
    var list: std.ArrayListUnmanaged(help_mod.Opt) = .empty;
    for (spec.flags) |o| {
        list.append(gpa, .{ .flags = formatFlags(gpa, o), .desc = o.help }) catch {};
    }
    return list.toOwnedSlice(gpa) catch &.{};
}

fn printHelp(ctx: *const Ctx, spec: Spec) void {
    if (spec.help) |h| {
        var mut = ctx.*;
        // Use the invoked name (argv[0] basename) for the NAME line, so a shared-spec
        // family (md5sum/sha256sum/... all backed by one `hashsum` spec) shows the name
        // it was actually run as. For a normal applet this equals spec.name.
        const invoked = if (ctx.args.len > 0) std.fs.path.basename(ctx.args[0]) else spec.name;
        help_mod.render(&mut, invoked, h, helpOpts(ctx.gpa, spec));
        return;
    }
    // Fallback terse usage for applets that don't yet carry a structured Help.
    ctx.print(ctx.stdout, "Usage: {s} [OPTIONS] {s}\n", .{ spec.name, spec.positionals.name });
    for (spec.flags) |o| {
        if (o.short) |s| {
            ctx.print(ctx.stdout, "  -{c}", .{s});
        } else {
            ctx.print(ctx.stdout, "    ", .{});
        }
        if (o.long) |l| {
            ctx.print(ctx.stdout, ", --{s}", .{l});
        }
        ctx.print(ctx.stdout, "  {s}\n", .{o.help});
    }
}

fn printVersion(ctx: *const Ctx, spec: Spec) void {
    ctx.print(ctx.stdout, "{s} {s}\n", .{ spec.name, spec.version });
}

fn errExit(ctx: *const Ctx, spec: Spec, comptime fmt: []const u8, args: anytype) ParseResult {
    ctx.print(ctx.stderr, "{s}: ", .{spec.name});
    ctx.print(ctx.stderr, fmt, args);
    return .{ .exit = 2 };
}

/// Full declarative parse (DESIGN.md §6.1).
pub fn parse(ctx: *Ctx, spec: Spec) ParseResult {
    var m = Matches{ .gpa = ctx.gpa };
    const argv = ctx.args[1..];
    var i: usize = 0;
    var no_more_flags = false;

    while (i < argv.len) : (i += 1) {
        const a = argv[i];

        if (no_more_flags) {
            m.positionals.append(ctx.gpa, a) catch @panic("OOM");
            if (spec.trailing_var_arg) {
                // everything else is swallowed verbatim, already handled by no_more_flags
            }
            continue;
        }

        if (std.mem.eql(u8, a, "--")) {
            no_more_flags = true;
            continue;
        }

        if (std.mem.eql(u8, a, "--help")) {
            printHelp(ctx, spec);
            return .{ .exit = 0 };
        }
        if (std.mem.eql(u8, a, "--version")) {
            printVersion(ctx, spec);
            return .{ .exit = 0 };
        }

        if (a.len >= 2 and a[0] == '-' and a[1] == '-') {
            // long option
            const body = a[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
            const o = findLong(spec, name) orelse {
                if (spec.allow_hyphen_values) {
                    // Not a recognized option: the whole token is a positional
                    // (clap's allow_hyphen_values).
                    m.positionals.append(ctx.gpa, a) catch @panic("OOM");
                    if (spec.trailing_var_arg) no_more_flags = true;
                    continue;
                }
                return errExit(ctx, spec, "unrecognized option '--{s}'\n", .{name});
            };
            switch (o.kind) {
                .flag => {
                    if (attached != null) return errExit(ctx, spec, "option '--{s}' takes no value\n", .{name});
                    record(&m, optKey(ctx.gpa, o), null) catch @panic("OOM");
                },
                .value => {
                    var v = attached;
                    if (v == null) {
                        i += 1;
                        if (i >= argv.len) return errExit(ctx, spec, "option '--{s}' requires a value\n", .{name});
                        v = argv[i];
                    }
                    record(&m, optKey(ctx.gpa, o), v) catch @panic("OOM");
                },
            }
            continue;
        }

        if (a.len >= 2 and a[0] == '-') {
            // A token like `-5`/`-0.5`/`-x1` whose first character is not a known
            // short option becomes a positional under allow_hyphen_values (seq's
            // negative operands, tr's hyphen-leading SETs). A recognized first
            // character still parses as a cluster, so `-w5` with unknown `5` stays
            // an error -- matching clap.
            if (spec.allow_hyphen_values and findShort(spec, a[1]) == null) {
                m.positionals.append(ctx.gpa, a) catch @panic("OOM");
                if (spec.trailing_var_arg) no_more_flags = true;
                continue;
            }
            // short option cluster
            var ci: usize = 1;
            while (ci < a.len) {
                const c = a[ci];
                const o = findShort(spec, c) orelse
                    return errExit(ctx, spec, "unrecognized option '-{c}'\n", .{c});
                switch (o.kind) {
                    .flag => {
                        record(&m, optKey(ctx.gpa, o), null) catch @panic("OOM");
                        ci += 1;
                    },
                    .value => {
                        var v: []const u8 = undefined;
                        if (ci + 1 < a.len) {
                            v = a[ci + 1 ..];
                        } else {
                            i += 1;
                            if (i >= argv.len) return errExit(ctx, spec, "option '-{c}' requires a value\n", .{c});
                            v = argv[i];
                        }
                        record(&m, optKey(ctx.gpa, o), v) catch @panic("OOM");
                        ci = a.len;
                    },
                }
            }
            continue;
        }

        // positional
        m.positionals.append(ctx.gpa, a) catch @panic("OOM");
        if (spec.trailing_var_arg) no_more_flags = true;
    }

    if (m.positionals.items.len < spec.positionals.min) {
        return errExit(ctx, spec, "missing operand\n", .{});
    }
    if (spec.positionals.max) |max| {
        if (m.positionals.items.len > max) {
            return errExit(ctx, spec, "extra operand '{s}'\n", .{m.positionals.items[max]});
        }
    }

    return .{ .ok = m };
}

pub const ClobberMode = struct { force: bool, no_clobber: bool, interactive: bool };

/// The GNU `-f` > `-n` > `-i` overwrite precedence shared by `cp`/`mv`: `-f` overrides
/// `-n`, and both override `-i`. Centralized because the short-circuit ordering is easy to
/// get subtly wrong. Reads the long flag names `force`/`no-clobber`/`interactive`.
pub fn clobberMode(m: Matches) ClobberMode {
    const force = m.has("force");
    const no_clobber = m.has("no-clobber") and !force;
    return .{
        .force = force,
        .no_clobber = no_clobber,
        .interactive = m.has("interactive") and !no_clobber and !force,
    };
}

/// Renders a structured `--help` for a hand-parsed applet (one that doesn't drive a
/// `Spec`). The applet supplies its OPTIONS rows via `h.options`.
pub fn renderHelp(ctx: *Ctx, name: []const u8, h: help_mod.Help) void {
    help_mod.render(ctx, name, h, h.options);
}

/// The structured counterpart of `leadingHelpOnly`: for the first-arg-only `--help`/`-h`/
/// `--version` applets (echo/printf/nice/nohup/true/false/yes/clear). Renders `h` on
/// `--help`/`-h`, the version on `--version`. Returns true if it handled the arg.
pub fn leadingHelp(ctx: *Ctx, name: []const u8, version: []const u8, h: help_mod.Help) bool {
    if (ctx.args.len < 2) return false;
    const a = ctx.args[1];
    if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
        renderHelp(ctx, name, h);
        return true;
    }
    if (std.mem.eql(u8, a, "--version")) {
        ctx.print(ctx.stdout, "{s} {s}\n", .{ name, version });
        return true;
    }
    return false;
}

/// Interactive y/N prompt shared by `cp`/`mv`/`ln`/`rm` (`-i`): writes `fmt`/`args` to
/// stderr, reads up to 64 bytes from stdin, and returns true iff the first non-blank byte
/// is `y`/`Y`. EOF or a read error counts as "no".
pub fn confirm(ctx: *const Ctx, comptime fmt: []const u8, args: anytype) bool {
    const sys = @import("../sys/root.zig");
    ctx.print(ctx.stderr, fmt, args);
    var buf: [64]u8 = undefined;
    const n = sys.read(ctx.stdin, &buf) catch return false;
    for (buf[0..n]) |c| {
        if (c == ' ' or c == '\t') continue;
        return c == 'y' or c == 'Y';
    }
    return false;
}

/// For applets that only honor `--help`/`-h`/`--version` as the very FIRST argument
/// (echo, printf, nice, nohup, true, false, yes, clear -- DESIGN.md §6.1). Returns
/// `true` if help/version was printed and the applet should exit 0 immediately.
pub fn leadingHelpOnly(ctx: *const Ctx, name: []const u8, version: []const u8) bool {
    if (ctx.args.len < 2) return false;
    const a = ctx.args[1];
    if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
        ctx.print(ctx.stdout, "Usage: {s} [OPTIONS]...\n", .{name});
        return true;
    }
    if (std.mem.eql(u8, a, "--version")) {
        ctx.print(ctx.stdout, "{s} {s}\n", .{ name, version });
        return true;
    }
    return false;
}
