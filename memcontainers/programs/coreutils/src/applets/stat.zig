//! `stat` -- DESIGN.md §1: `lstat`/`readlink` raw (no dereferencing).
//! `-c/--format FMT` (literal, trailing `\n` per file); `--printf FMT` (interprets
//! `\n \t \r \\ \"` escapes, no trailing newline; wins over `-c`); `FILE...` (1+, else
//! `stat: missing operand`, exit 2). Directives: `%n %N %s %F %f %a %A %h %x/%X %y/%Y
//! %z/%Z %u %g %U %G %i %d %t %T %o %b %%`; unknown -> literal `%c`. Default (no
//! format) is an 8-line report: File/Size/Links/Type/Mode/Modify/Change/Access -- the
//! exact field order/spacing chosen here (not pinned by the source matrix beyond that
//! list) is documented in DESIGN.md §1. Times are UTC via `core/civil.zig`.
//! Errors: `stat: <path>: <strerror>`, exit 1.

const std = @import("std");
const cli = @import("../core/cli.zig");
const sys = @import("../sys/root.zig");
const civil = @import("../core/civil.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "stat",
    .flags = &.{
        cli.valueOpt('c', "format", "use the specified FORMAT instead of the default"),
        cli.valueOpt(null, "printf", "like --format, but interpret backslash escapes, no trailing newline"),
    },
    .help = .{
        .summary = "display file status",
        .synopsis = &.{"stat [OPTION]... FILE..."},
        .description =
        \\Prints status information for each FILE without following symbolic links
        \\(uses lstat(2); a symlink is reported as a symlink, with its target after
        \\"->", rather than being dereferenced). With neither -c/--format nor --printf,
        \\a fixed 8-line report is printed per FILE: File, Size, Links, Type, Mode,
        \\Modify, Change, Access. -c/--format FORMAT prints FORMAT, with % directives
        \\substituted, followed by a newline per FILE; --printf FORMAT does the same
        \\but additionally interprets \n \t \r \\ \" backslash escapes and does not
        \\append a trailing newline -- --printf wins if both are given.
        \\
        \\Directives: %n (name) %N (quoted name, plus "-> target" for symlinks) %s
        \\(size) %F (type, as text) %f (raw mode, hex) %a (permission bits, octal) %A
        \\(permission bits, symbolic, e.g. -rwxr-xr-x) %h (link count) %x/%X (access
        \\time, human/epoch seconds) %y/%Y (modify time, human/epoch) %z/%Z (change
        \\time, human/epoch) %%. An unrecognized directive is emitted verbatim.
        ,
        .operands = "FILE...  one or more paths to report on; at least one is required.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE could not be lstat'd (remaining operands are still processed)" },
            .{ .code = 2, .when = "no FILE operand, or usage error" },
        },
        .deviations = &.{
            "The default report (no -c/--printf) is a simplified 8-line summary (File/Size/Links/Type/Mode/Modify/Change/Access); GNU stat's default additionally reports Device, Inode, Uid/Gid, and (on newer coreutils) Birth.",
            "%u %g %U %G %i %d %t %T %o %b (uid, gid, owner name, group name, inode, device, and block-size fields) are accepted directives but always print '?' -- there is no owner, inode, or device information to report.",
            "Times are formatted in UTC only (no local timezone).",
        },
        .examples = &.{
            .{ .cmd = "stat -c '%n %s %F' file.txt", .note = "name, size, type" },
            .{ .cmd = "stat --printf '%Y\\n' file.txt", .note = "mtime as Unix epoch seconds, with a real newline (--printf interprets \\n; -c would print it literally)" },
            .{ .cmd = "stat a_symlink", .note = "default report shows \"File: a_symlink -> target\" without following the link" },
        },
        .see_also = "ls -l (per-directory listing), touch (change timestamps).",
    },
    .positionals = .{ .name = "FILE", .min = 1, .max = null },
};

const Sink = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayListUnmanaged(u8) = .empty,

    fn byte(self: *Sink, b: u8) void {
        self.list.append(self.gpa, b) catch @panic("OOM");
    }
    fn bytes(self: *Sink, s: []const u8) void {
        self.list.appendSlice(self.gpa, s) catch @panic("OOM");
    }
};

fn fmtDecU64(buf: *[20]u8, v: u64) []const u8 {
    var vv = v;
    var i: usize = buf.len;
    if (vv == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (vv != 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(vv % 10));
            vv /= 10;
        }
    }
    return buf[i..];
}

fn fmtDecI64(buf: *[21]u8, v: i64) []const u8 {
    if (v < 0) {
        var tmp: [20]u8 = undefined;
        const mag = fmtDecU64(&tmp, @intCast(-v));
        buf[0] = '-';
        @memcpy(buf[1..][0..mag.len], mag);
        return buf[0 .. mag.len + 1];
    }
    var tmp: [20]u8 = undefined;
    const mag = fmtDecU64(&tmp, @intCast(v));
    @memcpy(buf[0..mag.len], mag);
    return buf[0..mag.len];
}

fn fmtHexU32(buf: *[8]u8, v: u32) []const u8 {
    const digits = "0123456789abcdef";
    var vv = v;
    var i: usize = buf.len;
    if (vv == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (vv != 0) {
            i -= 1;
            buf[i] = digits[vv % 16];
            vv /= 16;
        }
    }
    return buf[i..];
}

fn fmtOctU32(buf: *[12]u8, v: u32) []const u8 {
    var vv = v;
    var i: usize = buf.len;
    if (vv == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (vv != 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(vv % 8));
            vv /= 8;
        }
    }
    return buf[i..];
}

/// Reconstructs a raw `st_mode`-shaped value (type bits + permission bits) from our
/// `Stat` (which stores permission bits and `is_dir`/`is_symlink` separately, DESIGN.md
/// §4.1) -- `Stat.mode` itself carries no S_IFMT bits to draw from.
fn synthRawMode(st: sys.Stat) u32 {
    var m: u32 = st.mode & 0o7777;
    if (st.is_dir) {
        m |= 0o40000;
    } else if (st.is_symlink) {
        m |= 0o120000;
    } else {
        m |= 0o100000;
    }
    return m;
}

fn fileTypeStr(st: sys.Stat) []const u8 {
    if (st.is_symlink) return "symbolic link";
    if (st.is_dir) return "directory";
    if (st.size == 0) return "regular empty file";
    return "regular file";
}

fn appendTriad(s: *Sink, mode: u32, r_bit: u32, w_bit: u32, x_bit: u32, special: bool, lower: u8, upper: u8) void {
    s.byte(if (mode & r_bit != 0) 'r' else '-');
    s.byte(if (mode & w_bit != 0) 'w' else '-');
    const x_set = (mode & x_bit) != 0;
    if (special) {
        s.byte(if (x_set) lower else upper);
    } else {
        s.byte(if (x_set) 'x' else '-');
    }
}

fn appendSymbolic(s: *Sink, st: sys.Stat) void {
    const type_c: u8 = if (st.is_dir) 'd' else if (st.is_symlink) 'l' else '-';
    s.byte(type_c);
    const m = st.mode;
    appendTriad(s, m, 0o400, 0o200, 0o100, (m & 0o4000) != 0, 's', 'S');
    appendTriad(s, m, 0o040, 0o020, 0o010, (m & 0o2000) != 0, 's', 'S');
    appendTriad(s, m, 0o004, 0o002, 0o001, (m & 0o1000) != 0, 't', 'T');
}

fn appendHumanTime(s: *Sink, ms: i64) void {
    var buf: [32]u8 = undefined;
    s.bytes(civil.formatYmdHms(&buf, ms));
}

fn appendQuotedName(s: *Sink, path: []const u8, st: sys.Stat, target: ?[]const u8) void {
    s.byte('\'');
    s.bytes(path);
    s.byte('\'');
    if (st.is_symlink) {
        s.bytes(" -> '");
        s.bytes(target orelse "");
        s.byte('\'');
    }
}

fn processFormat(s: *Sink, fmt: []const u8, path: []const u8, st: sys.Stat, target: ?[]const u8, printf_mode: bool) void {
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (printf_mode and c == '\\' and i + 1 < fmt.len) {
            const nc = fmt[i + 1];
            switch (nc) {
                'n' => s.byte('\n'),
                't' => s.byte('\t'),
                'r' => s.byte('\r'),
                '\\' => s.byte('\\'),
                '"' => s.byte('"'),
                else => {
                    s.byte('\\');
                    s.byte(nc);
                },
            }
            i += 2;
            continue;
        }
        if (c == '%') {
            if (i + 1 >= fmt.len) {
                s.byte('%');
                i += 1;
                continue;
            }
            const d = fmt[i + 1];
            i += 2;
            switch (d) {
                '%' => s.byte('%'),
                'n' => s.bytes(path),
                'N' => appendQuotedName(s, path, st, target),
                's' => {
                    var b: [20]u8 = undefined;
                    s.bytes(fmtDecU64(&b, st.size));
                },
                'F' => s.bytes(fileTypeStr(st)),
                'f' => {
                    var b: [8]u8 = undefined;
                    s.bytes(fmtHexU32(&b, synthRawMode(st)));
                },
                'a' => {
                    var b: [12]u8 = undefined;
                    s.bytes(fmtOctU32(&b, st.mode & 0o7777));
                },
                'A' => appendSymbolic(s, st),
                'h' => {
                    var b: [20]u8 = undefined;
                    s.bytes(fmtDecU64(&b, st.nlink));
                },
                'x' => appendHumanTime(s, st.atime_ms),
                'X' => {
                    var b: [21]u8 = undefined;
                    s.bytes(fmtDecI64(&b, @divFloor(st.atime_ms, 1000)));
                },
                'y' => appendHumanTime(s, st.mtime_ms),
                'Y' => {
                    var b: [21]u8 = undefined;
                    s.bytes(fmtDecI64(&b, @divFloor(st.mtime_ms, 1000)));
                },
                'z' => appendHumanTime(s, st.ctime_ms),
                'Z' => {
                    var b: [21]u8 = undefined;
                    s.bytes(fmtDecI64(&b, @divFloor(st.ctime_ms, 1000)));
                },
                'u', 'g', 'U', 'G', 'i', 'd', 't', 'T', 'o', 'b' => s.byte('?'),
                else => {
                    s.byte('%');
                    s.byte(d);
                },
            }
            continue;
        }
        s.byte(c);
        i += 1;
    }
}

fn defaultReport(s: *Sink, path: []const u8, st: sys.Stat, target: ?[]const u8) void {
    s.bytes("File: ");
    s.bytes(path);
    if (st.is_symlink) {
        s.bytes(" -> ");
        s.bytes(target orelse "");
    }
    s.byte('\n');

    s.bytes("Size: ");
    {
        var b: [20]u8 = undefined;
        s.bytes(fmtDecU64(&b, st.size));
    }
    s.byte('\n');

    s.bytes("Links: ");
    {
        var b: [20]u8 = undefined;
        s.bytes(fmtDecU64(&b, st.nlink));
    }
    s.byte('\n');

    s.bytes("Type: ");
    s.bytes(fileTypeStr(st));
    s.byte('\n');

    s.bytes("Mode: (0");
    {
        var b: [12]u8 = undefined;
        s.bytes(fmtOctU32(&b, st.mode & 0o7777));
    }
    s.byte('/');
    appendSymbolic(s, st);
    s.bytes(")\n");

    s.bytes("Modify: ");
    appendHumanTime(s, st.mtime_ms);
    s.byte('\n');

    s.bytes("Change: ");
    appendHumanTime(s, st.ctime_ms);
    s.byte('\n');

    s.bytes("Access: ");
    appendHumanTime(s, st.atime_ms);
    s.byte('\n');
}

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const printf_fmt = m.value("printf");
    const format_fmt = m.value("format");

    var rc: u8 = 0;
    for (m.positionalSlice()) |path| {
        const st = sys.lstat(path) catch |e| {
            ctx.errPrint("stat: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
            rc = 1;
            continue;
        };
        var target: ?[]const u8 = null;
        if (st.is_symlink) {
            var lb: [4096]u8 = undefined;
            if (sys.readlink(path, &lb)) |n| {
                target = ctx.gpa.dupe(u8, lb[0..n]) catch null;
            } else |_| {}
        }

        var s = Sink{ .gpa = ctx.gpa };
        if (printf_fmt) |f| {
            processFormat(&s, f, path, st, target, true);
        } else if (format_fmt) |f| {
            processFormat(&s, f, path, st, target, false);
            s.byte('\n');
        } else {
            defaultReport(&s, path, st, target);
        }
        ctx.outWrite(s.list.items) catch {};
    }
    return rc;
}
