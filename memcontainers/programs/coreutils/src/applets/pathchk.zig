//! `pathchk` -- DESIGN.md §1: checks whether PATH operands are valid/portable.
//! Multiple PATH operands, each checked independently (a violation on one does not
//! stop the others from being checked); silent on success per-path, any violation
//! prints one line to stderr and the overall exit code is 1 if ANY path failed.
//!
//! Modes (`reference/uutils-coreutils/src/uu/pathchk/src/pathchk.rs`):
//!   default   -- `checkDefault`: filesystem-backed (lengths against PATH_MAX/
//!                FILENAME_MAX, plus a `lstat` "is this even reachable" check).
//!   -p        -- `checkBasic`: fixed POSIX limits (path <= 256, component <= 14),
//!                portable-charset check (`[-A-Za-z0-9._]`), THEN still ends with the
//!                same `lstat`-based reachability check as default mode.
//!   -P        -- `checkDefault(path) && checkExtra(path)`: default-mode checks first,
//!                then empty-path/leading-hyphen. (Yes, `-P` alone still runs the
//!                default filesystem checks -- verified against the oracle: `pathchk -P
//!                ''` reports the default-mode empty-path message, not the basic one.)
//!   --portability (equivalent to `-p -P` together) -- `checkBasic(path) &&
//!                checkExtra(path)`.
//!
//! The default/`-p` filesystem reachability check (`checkSearchable`) does a single
//! `lstat` on the whole joined path: `ENOENT` is silently OK (the reference doesn't
//! distinguish "leaf not created yet" from "an intermediate directory doesn't exist
//! either" -- both surface as one `ENOENT` from a single whole-path `lstat` and both
//! are accepted), while any OTHER error (e.g. `ENOTDIR` because some earlier
//! component is a plain file, or a permission error) is fatal and its OS message is
//! printed verbatim with a `(os error N)` suffix -- confirmed empirically against the
//! oracle binary (see the parity policy in DESIGN.md §2;
//! this file does not touch the ledger itself).
//!
//! PATH_MAX/FILENAME_MAX fallback: this Zig port's `sys` layer has no `pathconf`
//! equivalent, and neither does the reference -- `check_default` in the Rust source
//! just compares against `libc::PATH_MAX`/`libc::FILENAME_MAX` unconditionally (no
//! runtime query at all). On Linux those are both 4096; empirically confirmed via the
//! oracle binary's exact wording for an over-length path ("limit 4096 exceeded...").
//! We use the same two hardcoded values here.

const std = @import("std");
const sys = @import("../sys/root.zig");
const cli = @import("../core/cli.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "pathchk",
    .flags = &.{
        cli.flagOpt('p', null, "check for most POSIX systems"),
        cli.flagOpt('P', null, "check for empty names and leading \"-\""),
        cli.flagOpt(null, "portability", "check for all POSIX systems (equivalent to -p -P)"),
    },
    // Positional count is enforced by hand below (pathchk's missing-operand wording
    // and exit code -- 1, not cli.zig's generic parse-error exit 2 -- diverge from the
    // shared convention).
    .positionals = .{ .name = "NAME", .min = 0, .max = null },
    .help = .{
        .summary = "check whether file name(s) are valid or portable",
        .synopsis = &.{"pathchk [-p] [-P] [--portability] NAME..."},
        .description =
        \\Checks each NAME operand for validity and portability problems and is silent
        \\on success; a violation on one NAME does not stop the others from being
        \\checked. With no options, checks the name's length against this platform's
        \\filesystem limits and confirms the path is at least reachable (an
        \\intermediate or leaf component that does not exist yet is fine; anything
        \\else stat-worthy, e.g. a non-directory in the middle of the path, is not).
        \\
        \\-p checks fixed POSIX limits (256-byte path, 14-byte component) and a
        \\portable character set (`[-A-Za-z0-9._]`), then still runs the same
        \\reachability check as the default mode. -P additionally rejects empty names
        \\and components starting with a hyphen, but -P alone runs the default
        \\filesystem checks FIRST -- it does not replace them. --portability is -p and
        \\-P combined.
        ,
        .operands = "NAME...   one or more path strings to check; at least one is required.",
        .exit = &.{
            .{ .code = 0, .when = "every NAME passed its checks" },
            .{ .code = 1, .when = "at least one NAME failed a check, or no NAME was given" },
        },
        .deviations = &.{
            "Default- and -p-mode length limits are the fixed values 4096/4096 (PATH_MAX/FILENAME_MAX) rather than a pathconf() query against the actual filesystem, so an over-length check is against a constant, not the real mount's limits.",
            "The default/-p existence check is one lstat of the whole path rather than checking each leading directory component individually: ENOENT anywhere along the path (leaf or intermediate) is silently accepted; any other error (e.g. ENOTDIR, a permission error) is fatal and printed verbatim as \"<strerror> (os error N)\".",
        },
        .examples = &.{
            .{ .cmd = "pathchk /etc/passwd", .note = "silent, exit 0: default-mode checks pass" },
            .{ .cmd = "pathchk -p \"$(printf 'a%.0s' {1..300})\"", .note = "exit 1: \"limit 256 exceeded by length 300 of file name ...\"" },
            .{ .cmd = "pathchk -P -- -oops", .note = "exit 1: \"leading hyphen in file name component '-oops'\"" },
        },
    },
};

const POSIX_PATH_MAX: usize = 256;
const POSIX_NAME_MAX: usize = 14;
const PATH_MAX: usize = 4096;
const FILENAME_MAX: usize = 4096;

const Mode = enum { default, basic, extra, both };

fn errW(ctx: *Ctx, s: []const u8) void {
    sys.writeAll(ctx.stderr, s) catch {};
}

fn errNum(ctx: *Ctx, n: usize) void {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    errW(ctx, s);
}

/// Standard Linux errno numbers (matching what Rust's `io::Error` Display prints as
/// the `(os error N)` suffix), for the small set of errors `checkSearchable` can
/// realistically surface. Kept local to this applet -- `sys/errno.zig`'s `Errno` is a
/// cross-platform normalized enum with no raw number, deliberately, so this mapping
/// does not belong there.
fn osErrNum(e: sys.Errno) usize {
    return switch (e) {
        .SUCCESS => 0,
        .EPERM => 1,
        .ENOENT => 2,
        .ESRCH => 3,
        .EINTR => 4,
        .EIO => 5,
        .ENXIO => 6,
        .EAGAIN => 11,
        .ENOMEM => 12,
        .EACCES => 13,
        .EEXIST => 17,
        .EXDEV => 18,
        .EINVAL => 22,
        .ENOTDIR => 20,
        .EISDIR => 21,
        .EMFILE => 24,
        .ENFILE => 23,
        .ESPIPE => 29,
        .EPIPE => 32,
        .ERANGE => 34,
        .ENOSYS => 38,
        .ENOTEMPTY => 39,
        .ELOOP => 40,
        .ENOSPC => 28,
        .EBADF => 9,
        .ECHILD => 10,
        .ETIMEDOUT => 110,
        .ECONNREFUSED => 111,
        .EMSGSIZE => 90,
        .ENAMETOOLONG => 36,
        .EUNKNOWN => 0,
    };
}

fn isPortableChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
}

/// `check_portable_chars`: first non-portable byte fails the whole component.
fn checkPortableChars(ctx: *Ctx, comp: []const u8) bool {
    for (comp) |c| {
        if (!isPortableChar(c)) {
            errW(ctx, "nonportable character '");
            errW(ctx, &.{c});
            errW(ctx, "' in file name component '");
            errW(ctx, comp);
            errW(ctx, "'\n");
            return false;
        }
    }
    return true;
}

/// `check_searchable`: a single `lstat` of the whole path. Not-found is fine (the
/// path -- or one of its ancestors -- simply doesn't exist yet); anything else is a
/// real, fatal problem reported with the OS's own message.
fn checkSearchable(ctx: *Ctx, path: []const u8) bool {
    if (sys.lstat(path)) |_| {
        return true;
    } else |e| {
        if (e == error.ENOENT) return true;
        const errno = sys.toErrno(e);
        errW(ctx, sys.strerror(errno));
        errW(ctx, " (os error ");
        errNum(ctx, osErrNum(errno));
        errW(ctx, ")\n");
        return false;
    }
}

/// `check_basic` (`-p`): fixed POSIX limits + portable charset, then still ends with
/// the filesystem reachability check.
fn checkBasic(ctx: *Ctx, path: []const u8) bool {
    const total_len = path.len;
    if (total_len > POSIX_PATH_MAX) {
        errW(ctx, "limit ");
        errNum(ctx, POSIX_PATH_MAX);
        errW(ctx, " exceeded by length ");
        errNum(ctx, total_len);
        errW(ctx, " of file name ");
        errW(ctx, path);
        errW(ctx, "\n");
        return false;
    } else if (total_len == 0) {
        errW(ctx, "empty file name\n");
        return false;
    }

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len > POSIX_NAME_MAX) {
            errW(ctx, "limit ");
            errNum(ctx, POSIX_NAME_MAX);
            errW(ctx, " exceeded by length ");
            errNum(ctx, comp.len);
            errW(ctx, " of file name component '");
            errW(ctx, comp);
            errW(ctx, "'\n");
            return false;
        }
        if (!checkPortableChars(ctx, comp)) return false;
    }
    return checkSearchable(ctx, path);
}

/// `check_extra` (`-P`'s own additions): no component may start with `-`, and the
/// (rejoined, which for us is just the original) path may not be empty.
fn checkExtra(ctx: *Ctx, path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len > 0 and comp[0] == '-') {
            errW(ctx, "leading hyphen in file name component '");
            errW(ctx, comp);
            errW(ctx, "'\n");
            return false;
        }
    }
    if (path.len == 0) {
        errW(ctx, "empty file name\n");
        return false;
    }
    return true;
}

/// `check_default`: PATH_MAX/FILENAME_MAX fallback limits, then reachability.
fn checkDefault(ctx: *Ctx, path: []const u8) bool {
    const total_len = path.len;
    if (total_len > PATH_MAX) {
        errW(ctx, "limit ");
        errNum(ctx, PATH_MAX);
        errW(ctx, " exceeded by length ");
        errNum(ctx, total_len);
        errW(ctx, " of file name '");
        errW(ctx, path);
        errW(ctx, "'\n");
        return false;
    }
    if (total_len == 0) {
        // `fs::symlink_metadata("").is_err()` -- on every real backend `lstat("")`
        // fails (ENOENT), so this literal (ftl-baked, "pathchk: " included in the
        // string itself) message always fires for an empty path in default mode.
        if (sys.lstat("")) |_| {
            // Unreachable in practice; if it somehow succeeded, fall through like the
            // reference does.
        } else |_| {
            errW(ctx, "pathchk: '': No such file or directory\n");
            return false;
        }
    }

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len > FILENAME_MAX) {
            errW(ctx, "limit ");
            errNum(ctx, FILENAME_MAX);
            errW(ctx, " exceeded by length ");
            errNum(ctx, comp.len);
            errW(ctx, " of file name component '");
            errW(ctx, comp);
            errW(ctx, "'\n");
            return false;
        }
    }
    return checkSearchable(ctx, path);
}

fn checkPath(mode: Mode, ctx: *Ctx, path: []const u8) bool {
    return switch (mode) {
        .basic => checkBasic(ctx, path),
        .extra => checkDefault(ctx, path) and checkExtra(ctx, path),
        .both => checkBasic(ctx, path) and checkExtra(ctx, path),
        .default => checkDefault(ctx, path),
    };
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };

    const is_posix = m.has("p");
    const is_extra = m.has("P");
    const is_portability = m.has("portability");
    const mode: Mode = if ((is_posix and is_extra) or is_portability)
        .both
    else if (is_posix)
        .basic
    else if (is_extra)
        .extra
    else
        .default;

    const pos = m.positionalSlice();
    if (pos.len == 0) {
        errW(ctx, "pathchk: missing operand\nTry 'pathchk --help' for more information.\n");
        return 1;
    }

    var all_ok = true;
    for (pos) |p| {
        if (!checkPath(mode, ctx, p)) all_ok = false;
    }
    return if (all_ok) 0 else 1;
}
