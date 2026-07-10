//! `ls` -- docs/analysis/applets-g-r.md: `-a` all, `-l` long, `-h` human sizes
//! (1024-based, `-l` only; `--help` is long-only, `-h` is NOT help), `-d` list operands
//! themselves, `-R` recursive, `-S` by size desc, `-t` by mtime desc (ties by name),
//! `-r` reverse, `-1` accepted no-op (always one per line), `-F` accepted no-op; `FILE...`
//! (default `.`). Dotfiles hidden unless `-a`. Short output always marks dir `/` and
//! symlink `@` (symlink wins). Long form:
//! `<mode> <nlink:>3> <size:>8> <YYYY-MM-DD HH:MM> <name>` with `format_mode`
//! (`-`/`d`/`l` + rwx triads), `name -> target` for symlinks, NO owner/group columns;
//! times UTC via `core/civil.zig`. `human()` = integer 1024 scaling, round-up: one
//! decimal below 10 (`1.0K`), else integer (`12K`); plain bytes below 1024. Non-dir
//! operands first, then each dir with a `NAME:` header when multiple operands or `-R`
//! (blank line between sections); recursion descends via `stat` (follows
//! symlink-to-dir). Entries via `lstat` (symlinks shown as symlinks). Errors
//! `ls: {p}: {strerror}`, exit 1; usage 2. Byte-lexicographic name sort.

const std = @import("std");
const cli = @import("../core/cli.zig");
const sys = @import("../sys/root.zig");
const fsutil = @import("../core/fsutil.zig");
const civil = @import("../core/civil.zig");
const textio = @import("../core/textio.zig");
const Ctx = @import("../ctx.zig").Ctx;

const spec = cli.Spec{
    .name = "ls",
    .flags = &.{
        cli.flagOpt('a', null, "do not ignore entries starting with ."),
        cli.flagOpt('l', null, "use a long listing format"),
        cli.flagOpt('h', null, "with -l, print sizes in human readable format"),
        cli.flagOpt('d', null, "list directories themselves, not their contents"),
        cli.flagOpt('R', null, "list subdirectories recursively"),
        cli.flagOpt('S', null, "sort by file size, largest first"),
        cli.flagOpt('t', null, "sort by modification time, newest first"),
        cli.flagOpt('r', null, "reverse order while sorting"),
        cli.flagOpt('1', null, "list one file per line (always the case)"),
        cli.flagOpt('F', null, "append indicator (/ for dirs, @ for symlinks)"),
    },
    .help = .{
        .summary = "list directory contents",
        .synopsis = &.{"ls [OPTION]... [FILE]..."},
        .description =
        \\Lists each FILE (default: the current directory, .); a non-directory FILE is
        \\printed as a single entry, and a directory FILE has its contents listed, one
        \\name per line unless -l. Dotfiles are hidden unless -a. With more than one
        \\directory operand, or -R, each directory's listing is preceded by a "NAME:"
        \\header. Short output appends / to directories and @ to symlinks. -R recurses
        \\into subdirectories (following a symlink-to-directory, since traversal
        \\dereferences); -d lists the operands themselves instead of their contents.
        \\
        \\-l uses a long format -- mode, link count, size, "YYYY-MM-DD HH:MM" mtime
        \\(UTC), name, with "name -> target" for symlinks; there is no owner/group
        \\column. -h scales the -l size column to human-readable units (1024-based,
        \\e.g. 12K, 1.0M) instead of raw byte counts. Sorting is by name by default; -S
        \\sorts by size (largest first) and -t by modification time (newest first),
        \\both tying back to name order; -r reverses the chosen order. -F is accepted
        \\for compatibility; classification marks are always shown in short output.
        ,
        .operands = "FILE...  files and/or directories to list; defaults to . when none are given.",
        .exit = &.{
            .{ .code = 0, .when = "success" },
            .{ .code = 1, .when = "a FILE/directory could not be stat'd or read (remaining operands are still processed)" },
            .{ .code = 2, .when = "usage error (unrecognized option)" },
        },
        .deviations = &.{
            "-l has no owner or group columns (single-user facade), and there is no -i (inode numbers), -n, -G, or --color.",
            "-1 is accepted for compatibility but is always a no-op: listings are always one name per line; there is no column/across terminal-width layout.",
            "-F is accepted for compatibility but is always a no-op: short listings always classify directories and symlinks.",
            "With -R, a symlink to a directory IS followed and recursed into; GNU ls -R does not descend into symlinked directories unless -L is also given.",
            "No -X (sort by extension) or --group-directories-first.",
        },
        .examples = &.{
            .{ .cmd = "ls -la", .note = "long format, including dotfiles" },
            .{ .cmd = "ls -lh big/", .note = "human-readable sizes in the size column (e.g. 1.0M)" },
            .{ .cmd = "ls -R proj/", .note = "recurses, following symlinked subdirectories (see DEVIATIONS)" },
        },
        .see_also = "tree (recursive listing as a tree), stat (per-file detail).",
    },
    .positionals = .{ .name = "FILE", .min = 0, .max = null },
};

const Opts = struct {
    all: bool,
    long: bool,
    human: bool,
    dirs_themselves: bool,
    recursive: bool,
    by_size: bool,
    by_time: bool,
    reverse: bool,
    classify: bool,
};

const Entry = struct {
    name: []const u8, // displayed
    path: []const u8, // stat/readlink path
    st: sys.Stat, // lstat
};

const SortMode = enum { name, size, time };

fn sortMode(o: Opts) SortMode {
    if (o.by_size) return .size;
    if (o.by_time) return .time;
    return .name;
}

const SortCtx = struct { mode: SortMode, reverse: bool };

fn entryLess(c: SortCtx, a: Entry, b: Entry) bool {
    const base = switch (c.mode) {
        .name => std.mem.lessThan(u8, a.name, b.name),
        .size => if (a.st.size != b.st.size)
            a.st.size > b.st.size // largest first
        else
            std.mem.lessThan(u8, a.name, b.name),
        .time => if (a.st.mtime_ms != b.st.mtime_ms)
            a.st.mtime_ms > b.st.mtime_ms // newest first
        else
            std.mem.lessThan(u8, a.name, b.name),
    };
    return if (c.reverse) !base else base;
}

// ---------------------------------------------------------------- rendering

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

/// Integer-math 1024 scaling, rounding UP: `<n>` below 1024; one decimal below 10
/// units (`1.0K`, `9.3M`); integer otherwise (`12K`, `730G`).
fn human(buf: []u8, size: u64) []const u8 {
    if (size < 1024) return decimal(buf[0..20], size);
    const units = "KMGTPE";
    var ui: usize = 0;
    var scale: u64 = 1024;
    while (ui + 1 < units.len and size >= scale * 1024) {
        scale *= 1024;
        ui += 1;
    }
    const tenths: u64 = @intCast((@as(u128, size) * 10 + scale - 1) / scale); // ceil(size*10/scale)
    if (tenths < 100) {
        // x.y<unit>
        var tmp: [20]u8 = undefined;
        const whole = decimal(&tmp, tenths / 10);
        var off: usize = 0;
        @memcpy(buf[off..][0..whole.len], whole);
        off += whole.len;
        buf[off] = '.';
        off += 1;
        buf[off] = '0' + @as(u8, @intCast(tenths % 10));
        off += 1;
        buf[off] = units[ui];
        off += 1;
        return buf[0..off];
    }
    const whole: u64 = (size + scale - 1) / scale; // ceil
    if (whole >= 1024 and ui + 1 < units.len) {
        // rounding pushed it to the next unit: 1024K -> 1.0M
        ui += 1;
        @memcpy(buf[0..3], "1.0");
        buf[3] = units[ui];
        return buf[0..4];
    }
    var tmp: [20]u8 = undefined;
    const digits = decimal(&tmp, whole);
    @memcpy(buf[0..digits.len], digits);
    buf[digits.len] = units[ui];
    return buf[0 .. digits.len + 1];
}

fn formatMode(buf: *[10]u8, st: sys.Stat) []const u8 {
    buf[0] = if (st.is_symlink) 'l' else if (st.is_dir) 'd' else '-';
    const m = st.mode;
    const bits = [9]u32{ 0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001 };
    const chars = "rwxrwxrwx";
    for (bits, 0..) |bit, i| {
        buf[i + 1] = if (m & bit != 0) chars[i] else '-';
    }
    return buf[0..10];
}

fn padLeft(out: *textio.BufOut, s: []const u8, width: usize) sys.Error!void {
    var pad = if (s.len < width) width - s.len else 0;
    while (pad > 0) : (pad -= 1) try out.push(' ');
    try out.extend(s);
}

/// One output line for `entry`. Short output preserves the original behavior:
/// directories and symlinks are always visibly classified.
fn writeLine(ctx: *Ctx, out: *textio.BufOut, o: Opts, e: Entry) sys.Error!void {
    if (!o.long) {
        try out.extend(e.name);
        if (e.st.is_symlink) {
            try out.push('@');
        } else if (e.st.is_dir) {
            try out.push('/');
        }
        try out.endLine();
        return;
    }
    var mode_buf: [10]u8 = undefined;
    try out.extend(formatMode(&mode_buf, e.st));
    try out.push(' ');
    var num_buf: [24]u8 = undefined;
    try padLeft(out, decimal(num_buf[0..20], e.st.nlink), 3);
    try out.push(' ');
    if (o.human) {
        var hbuf: [24]u8 = undefined;
        try padLeft(out, human(&hbuf, e.st.size), 8);
    } else {
        try padLeft(out, decimal(num_buf[0..20], e.st.size), 8);
    }
    try out.push(' ');
    var time_buf: [32]u8 = undefined;
    try out.extend(civil.formatYmdHm(&time_buf, e.st.mtime_ms));
    try out.push(' ');
    try out.extend(e.name);
    if (e.st.is_symlink) {
        var lb: [4096]u8 = undefined;
        if (sys.readlink(e.path, &lb)) |n| {
            try out.extend(" -> ");
            try out.extend(lb[0..n]);
        } else |_| {}
    } else if (e.st.is_dir) {
        try out.push('/');
    }
    _ = ctx;
    try out.endLine();
}

// ---------------------------------------------------------------- directory sections

const Lister = struct {
    ctx: *Ctx,
    out: textio.BufOut,
    o: Opts,
    show_headers: bool,
    first_section: bool = true,
    rc: u8 = 0,

    fn err(self: *Lister, path: []const u8, e: sys.Error) void {
        self.out.finish() catch {};
        self.ctx.errPrint("ls: {s}: {s}\n", .{ path, sys.strerror(sys.toErrno(e)) });
        self.rc = 1;
    }

    /// Lists one directory; recurses when -R (descending via `stat`, so a
    /// symlink-to-dir is followed -- matrix ruling).
    fn listDir(self: *Lister, path: []const u8) void {
        const gpa = self.ctx.gpa;
        if (self.show_headers) {
            if (!self.first_section) self.out.push('\n') catch return;
            self.out.extend(path) catch return;
            self.out.extend(":\n") catch return;
        }
        self.first_section = false;

        const names = fsutil.list(gpa, path) catch |e| {
            self.err(path, e);
            return;
        };
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        for (names) |name| {
            if (!self.o.all and name.len > 0 and name[0] == '.') continue;
            const full = fsutil.join(gpa, path, name) catch @panic("OOM");
            const st = sys.lstat(full) catch |e| {
                self.err(full, e);
                continue;
            };
            entries.append(gpa, .{ .name = name, .path = full, .st = st }) catch @panic("OOM");
        }
        std.mem.sort(Entry, entries.items, SortCtx{ .mode = sortMode(self.o), .reverse = self.o.reverse }, entryLess);
        for (entries.items) |e| writeLine(self.ctx, &self.out, self.o, e) catch return;

        if (self.o.recursive) {
            for (entries.items) |e| {
                const st_follow = sys.stat(e.path) catch continue;
                if (st_follow.is_dir) self.listDir(e.path);
            }
        }
    }
};

pub fn run(ctx: *Ctx) u8 {
    const res = cli.parse(ctx, spec);
    const m = switch (res) {
        .exit => |c| return c,
        .ok => |mm| mm,
    };
    const o = Opts{
        .all = m.has("a"),
        .long = m.has("l"),
        .human = m.has("h"),
        .dirs_themselves = m.has("d"),
        .recursive = m.has("R"),
        .by_size = m.has("S"),
        .by_time = m.has("t"),
        .reverse = m.has("r"),
        .classify = m.has("F"),
    };
    var operands = m.positionalSlice();
    if (operands.len == 0) operands = &.{"."};

    var lister = Lister{
        .ctx = ctx,
        .out = textio.BufOut.init(ctx.stdout),
        .o = o,
        .show_headers = o.recursive or operands.len > 1,
    };

    if (o.dirs_themselves) {
        // List the operands themselves (no headers, no recursion).
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        for (operands) |op| {
            const st = sys.lstat(op) catch |e| {
                lister.err(op, e);
                continue;
            };
            entries.append(ctx.gpa, .{ .name = op, .path = op, .st = st }) catch @panic("OOM");
        }
        std.mem.sort(Entry, entries.items, SortCtx{ .mode = sortMode(o), .reverse = o.reverse }, entryLess);
        for (entries.items) |e| writeLine(ctx, &lister.out, o, e) catch break;
        lister.out.finish() catch {};
        return lister.rc;
    }

    // Classify operands: non-dirs listed first (as plain lines), then each dir.
    var file_entries: std.ArrayListUnmanaged(Entry) = .empty;
    var dir_ops: std.ArrayListUnmanaged([]const u8) = .empty;
    for (operands) |op| {
        if (sys.stat(op)) |st_follow| {
            if (st_follow.is_dir) {
                dir_ops.append(ctx.gpa, op) catch @panic("OOM");
                continue;
            }
        } else |_| {}
        const st = sys.lstat(op) catch |e| {
            lister.err(op, e);
            continue;
        };
        file_entries.append(ctx.gpa, .{ .name = op, .path = op, .st = st }) catch @panic("OOM");
    }

    if (file_entries.items.len > 0) {
        std.mem.sort(Entry, file_entries.items, SortCtx{ .mode = sortMode(o), .reverse = o.reverse }, entryLess);
        for (file_entries.items) |e| writeLine(ctx, &lister.out, o, e) catch break;
        lister.first_section = false;
    }

    // Directory operands in byte order (reversed with -r), independent of -S/-t
    // (their stats describe the dirs, not their contents; name order is stable).
    std.mem.sort([]const u8, dir_ops.items, o.reverse, dirOpLess);
    for (dir_ops.items) |d| lister.listDir(d);

    lister.out.finish() catch {};
    return lister.rc;
}

fn dirOpLess(reverse: bool, a: []const u8, b: []const u8) bool {
    const base = std.mem.lessThan(u8, a, b);
    return if (reverse) !base else base;
}
