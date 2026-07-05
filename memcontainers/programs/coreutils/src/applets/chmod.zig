//! `chmod` -- docs/analysis/applets-a-f.md: `-R/--recursive` (post-order tree walk).
//! Hand-parsed (not `core/cli.zig`): the operand grammar is `chmod [-R] MODE FILE...`
//! where MODE is the first non-`-R` token and may itself begin with `-` (symbolic
//! modes like `go-w`), so a declarative flag parser can't disambiguate it from an
//! unknown option -- exactly the `allow_hyphen_values`+`trailing_var_arg` combination
//! DESIGN.md §6.1 says to hand-parse rather than force into the declarative mold.
//!
//! MODE is octal (`755`, `0644`; masked `&0o7777`, absolute) or symbolic comma-clauses
//! `[ugoa]*[+-=][rwx]*` (relative: `r=0o444 w=0o222 x=0o111`, `who` defaults to
//! `0o777`). MODE is parsed (and thus validated) before any file is touched.

const std = @import("std");
const fsutil = @import("../core/fsutil.zig");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const Allocator = std.mem.Allocator;

const help_doc = cli.Help{
    .summary = "change file mode bits",
    .synopsis = &.{"chmod [-R] MODE FILE..."},
    .description =
    \\Changes the file mode (permission) bits of each FILE to MODE. MODE is either an
    \\octal number (e.g. 755, 0644; masked to 12 bits, so 4755 sets setuid) or one or
    \\more comma-separated symbolic clauses of the form [ugoa]*[+-=][rwx]* (e.g.
    \\u+x,go-w; a clause with no who letters applies to all of user/group/other). MODE
    \\is parsed and validated before any FILE is touched, so a malformed MODE leaves
    \\every FILE unmodified. With -R/--recursive, the change is applied to each FILE
    \\and, for directories, to their contents first and the directory itself last.
    ,
    .options = &.{
        .{ .flags = "-R, --recursive", .desc = "change files and directories recursively" },
    },
    .operands = "MODE (required) describes the change; FILE...  is one or more paths to change.",
    .exit = &.{
        .{ .code = 0, .when = "success (every FILE changed)" },
        .{ .code = 1, .when = "an invalid MODE, a stat/chmod failure, or a missing operand" },
    },
    .deviations = &.{
        "No -c/--changes, -f/--silent/--quiet, -v/--verbose, --preserve-root/--no-preserve-root, or --reference=RFILE.",
        "Symbolic MODE supports only r/w/x; there is no s (setuid/setgid), t (sticky), or X (conditional execute) permission, and no copy-from-class form (e.g. u=g). Use octal MODE (e.g. 4755) to set setuid/setgid/sticky bits.",
        "Each comma-separated symbolic clause allows exactly one [+-=] operator; GNU's chained form within one clause (e.g. u+x-w) is rejected here as an invalid mode -- write u+x,u-w instead.",
        "A symbolic clause with no who letters (e.g. +x) applies to all of user/group/other unconditionally; GNU additionally masks the change by the process umask in this case.",
        "With -R, a directory entry that is a symbolic link to a directory is followed and both modified and recursed into (chmod uses stat, not lstat); GNU chmod never dereferences symlinks encountered during the recursive walk. A symlink cycle can therefore make -R loop indefinitely.",
    },
    .examples = &.{
        .{ .cmd = "chmod 0644 notes.txt", .note = "rw for owner, r for group/other" },
        .{ .cmd = "chmod -R g+w,o-w /srv/data", .note = "comma-separated clauses; the chained form g+w-o would be rejected" },
        .{ .cmd = "chmod 4755 tool", .note = "sets setuid via octal; symbolic mode cannot express setuid/setgid/sticky" },
    },
    .see_also = "chown, stat (inspect current mode bits).",
};

const Clause = struct { who_mask: u32, op: u8, bits: u32 };

const ModeOp = union(enum) {
    absolute: u32,
    symbolic: []const Clause,
};

fn isOctalDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '7') return false;
    }
    return true;
}

fn parseOctal(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| v = v * 8 + (c - '0');
    return v & 0o7777;
}

fn whoMaskOf(c: u8) ?u32 {
    return switch (c) {
        'u' => 0o700,
        'g' => 0o070,
        'o' => 0o007,
        'a' => 0o777,
        else => null,
    };
}

fn permBitOf(c: u8) ?u32 {
    return switch (c) {
        'r' => 0o444,
        'w' => 0o222,
        'x' => 0o111,
        else => null,
    };
}

fn parseSymbolic(gpa: Allocator, s: []const u8) ?[]const Clause {
    var clauses: std.ArrayListUnmanaged(Clause) = .empty;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |part| {
        if (part.len == 0) return null;
        var idx: usize = 0;
        var who_mask: u32 = 0;
        while (idx < part.len) : (idx += 1) {
            const wm = whoMaskOf(part[idx]) orelse break;
            who_mask |= wm;
        }
        if (who_mask == 0) who_mask = 0o777;
        if (idx >= part.len) return null; // missing +/-/=
        const opc = part[idx];
        if (opc != '+' and opc != '-' and opc != '=') return null;
        idx += 1;
        var bits: u32 = 0;
        while (idx < part.len) : (idx += 1) {
            const b = permBitOf(part[idx]) orelse return null;
            bits |= b;
        }
        clauses.append(gpa, .{ .who_mask = who_mask, .op = opc, .bits = bits & who_mask }) catch return null;
    }
    if (clauses.items.len == 0) return null;
    return clauses.toOwnedSlice(gpa) catch null;
}

fn parseMode(gpa: Allocator, s: []const u8) ?ModeOp {
    if (isOctalDigits(s)) return .{ .absolute = parseOctal(s) };
    if (parseSymbolic(gpa, s)) |cl| return .{ .symbolic = cl };
    return null;
}

fn applyMode(op: ModeOp, base: u32) u32 {
    return switch (op) {
        .absolute => |v| v,
        .symbolic => |clauses| blk: {
            var m = base;
            for (clauses) |c| {
                switch (c.op) {
                    '+' => m |= c.bits,
                    '-' => m &= ~c.bits,
                    '=' => m = (m & ~c.who_mask) | c.bits,
                    else => unreachable,
                }
            }
            break :blk m & 0o7777;
        },
    };
}

fn chmodPath(ctx: *Ctx, path: []const u8, op: ModeOp, recursive: bool) u8 {
    const st = sys.stat(path) catch |e| {
        ctx.errPrint("chmod: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    var rc: u8 = 0;
    if (recursive and st.is_dir) {
        const names = fsutil.list(ctx.gpa, path) catch |e| blk: {
            ctx.errPrint("chmod: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            break :blk &[_][]const u8{};
        };
        for (names) |name| {
            const child = fsutil.join(ctx.gpa, path, name) catch continue;
            const r = chmodPath(ctx, child, op, recursive);
            if (r != 0) rc = r;
        }
    }
    sys.chmod(path, applyMode(op, st.mode)) catch |e| {
        ctx.errPrint("chmod: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        return 1;
    };
    return rc;
}

pub fn run(ctx: *Ctx) u8 {
    const args = ctx.args[1..];
    var i: usize = 0;
    var recursive = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            cli.renderHelp(ctx, "chmod", help_doc);
            return 0;
        }
        if (std.mem.eql(u8, a, "-R") or std.mem.eql(u8, a, "--recursive")) {
            recursive = true;
            continue;
        }
        break;
    }
    if (i >= args.len) {
        ctx.errPrint("chmod: missing operand\n", .{});
        return 1;
    }
    const mode_spec = args[i];
    i += 1;
    const files = args[i..];
    if (files.len == 0) {
        ctx.errPrint("chmod: missing operand after '{s}'\n", .{mode_spec});
        return 1;
    }

    const op = parseMode(ctx.gpa, mode_spec) orelse {
        ctx.errPrint("chmod: invalid mode: {s}\n", .{mode_spec});
        return 1;
    };

    var rc: u8 = 0;
    for (files) |f| {
        const r = chmodPath(ctx, f, op, recursive);
        if (r != 0) rc = r;
    }
    return rc;
}
