//! USTAR read + write engine (DESIGN.md §7.5) for the `tar` applet. Whole-buffer
//! in-memory model throughout, matching the rest of the compress/archive cluster: the
//! writer accumulates a complete archive byte buffer, the reader/iterator walks a
//! complete archive byte buffer already resident in memory (after any gzip/bzip2/xz
//! decompression has already produced plain tar bytes).
//!
//! Headers are built by hand (not via `std.tar.Writer`) per DESIGN.md §7.5: POSIX
//! ustar, magic `"ustar\x00"` + version `"00"` (the `tar` crate's `Builder` default,
//! matching GNU/BSD tar's own POSIX mode), name split into `prefix`(155)/`name`(100) at
//! a `/` boundary when the path exceeds 100 bytes, octal numeric fields, checksum
//! computed with the checksum field itself treated as eight ASCII spaces during the
//! sum. Defaults: regular files 0644, directories 0755, symlinks 0777, uid/gid 0,
//! mtime from the caller (lstat's mtime in the applet).
//!
//! Reader supports: typeflags `'0'`/`'\0'` (file), `'5'` (dir), `'2'` (symlink), `'1'`
//! (hardlink -- surfaced as `.hardlink` so the applet can skip it with a notice, per the
//! matrix), GNU longname/longlink (`'L'`/`'K'`) transparently splicing the following
//! entry's name/linkname, and pax extended headers (`'x'`) transparently applying a
//! `path` record to the following entry if present (global pax `'g'` headers are
//! consumed and ignored). Both octal and GNU base-256 size encodings are accepted.
//! Anything else (char/block device, fifo, contiguous, or any other typeflag) comes back
//! as `.unsupported` for the applet to skip-with-notice, same as hardlinks -- the `tar`
//! crate's own `Archive` reader only special-cases the types above and reports
//! everything else as a diagnostic, not a hard error (ledgered).

const std = @import("std");

pub const block_size: usize = 512;

pub const Kind = enum { file, dir, symlink, hardlink, unsupported };

pub const Entry = struct {
    name: []const u8,
    linkname: []const u8 = "",
    size: u64 = 0,
    mode: u32 = 0,
    mtime: i64 = 0, // seconds since epoch
    kind: Kind,
    /// Slice into the iterator's source buffer (valid only for `.file`; borrowed, not
    /// owned -- do not free).
    data: []const u8 = &.{},
};

fn isAllZero(block: []const u8) bool {
    for (block) |b| {
        if (b != 0) return false;
    }
    return true;
}

fn roundUp512(n: u64) u64 {
    return (n + 511) & ~@as(u64, 511);
}

fn trimNulPad(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    return s[0..end];
}

/// Octal ASCII (possibly space/NUL padded either side) or GNU base-256 (top bit of the
/// first byte set) numeric field decode.
fn parseNumField(field: []const u8) u64 {
    if (field.len > 0 and (field[0] & 0x80) != 0) {
        // GNU base-256: remaining bits of the first byte + the rest, big-endian.
        var v: u64 = field[0] & 0x7f;
        for (field[1..]) |b| v = (v << 8) | b;
        return v;
    }
    var v: u64 = 0;
    for (field) |b| {
        if (b == 0 or b == ' ') {
            if (v != 0 or b == 0) continue else continue;
        }
        if (b < '0' or b > '7') continue;
        v = v * 8 + (b - '0');
    }
    return v;
}

fn writeOctalField(buf: []u8, value: u64) void {
    // Zero-padded octal digits filling the field, NUL-terminated in the last byte.
    const width = buf.len - 1;
    var v = value;
    var i = width;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 8));
        v /= 8;
    }
    buf[width] = 0;
}

fn writeChecksumField(buf: *[8]u8, value: u32) void {
    // POSIX: six octal digits, NUL, space.
    var v = value;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 8));
        v /= 8;
    }
    buf[6] = 0;
    buf[7] = ' ';
}

const SplitName = struct { prefix: []const u8, name: []const u8 };

pub const NameError = error{NameTooLong};

/// Splits `path` into ustar's `prefix`(<=155)/`name`(<=100) at the rightmost `/` that
/// satisfies both limits (maximizing how much lands in `name`, the conventional
/// approach also used by GNU/BSD tar and the `tar` crate). A path that fits within 100
/// bytes needs no prefix at all.
pub fn splitName(path: []const u8) NameError!SplitName {
    if (path.len <= 100) return .{ .prefix = "", .name = path };
    if (path.len > 255) return error.NameTooLong;
    var best: ?usize = null;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, pos, '/')) |slash| {
        const prefix_len = slash;
        const name_len = path.len - slash - 1;
        if (prefix_len <= 155 and name_len <= 100 and name_len > 0) best = slash;
        pos = slash + 1;
    }
    const slash = best orelse return error.NameTooLong;
    return .{ .prefix = path[0..slash], .name = path[slash + 1 ..] };
}

// ============================================================================ Writer

pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    /// Low-level header-only write, exposed for callers (and tests) that need a
    /// typeflag `addFile`/`addDir`/`addSymlink` don't cover directly (e.g. a hardlink
    /// fixture for `tar` applet tests).
    pub fn writeHeader(self: *Writer, path: []const u8, typeflag: u8, mode: u32, mtime: i64, size: u64, linkname: []const u8) !void {
        const split = try splitName(path);
        var block: [block_size]u8 = @splat(0);
        @memcpy(block[0..split.name.len], split.name);
        writeOctalField(block[100..108], mode & 0o7777);
        writeOctalField(block[108..116], 0); // uid
        writeOctalField(block[116..124], 0); // gid
        writeOctalField(block[124..136], size);
        writeOctalField(block[136..148], @intCast(@max(mtime, 0)));
        block[156] = typeflag;
        @memcpy(block[157..][0..linkname.len], linkname);
        @memcpy(block[257..263], "ustar\x00");
        @memcpy(block[263..265], "00");
        @memcpy(block[345..][0..split.prefix.len], split.prefix);

        // Checksum: sum of all bytes with the checksum field itself treated as eight
        // ASCII spaces.
        @memset(block[148..156], ' ');
        var sum: u32 = 0;
        for (block) |b| sum += b;
        writeChecksumField(block[148..156], sum);

        try self.buf.appendSlice(self.gpa, &block);
    }

    pub fn addFile(self: *Writer, path: []const u8, mode: u32, mtime: i64, data: []const u8) !void {
        try self.writeHeader(path, '0', mode, mtime, data.len, "");
        try self.buf.appendSlice(self.gpa, data);
        const pad = roundUp512(data.len) - data.len;
        try self.buf.appendNTimes(self.gpa, 0, @intCast(pad));
    }

    pub fn addDir(self: *Writer, path: []const u8, mode: u32, mtime: i64) !void {
        var with_slash = path;
        var owned: ?[]u8 = null;
        if (path.len == 0 or path[path.len - 1] != '/') {
            owned = try self.gpa.alloc(u8, path.len + 1);
            @memcpy(owned.?[0..path.len], path);
            owned.?[path.len] = '/';
            with_slash = owned.?;
        }
        defer if (owned) |o| self.gpa.free(o);
        try self.writeHeader(with_slash, '5', mode, mtime, 0, "");
    }

    pub fn addSymlink(self: *Writer, path: []const u8, mode: u32, mtime: i64, target: []const u8) !void {
        try self.writeHeader(path, '2', mode, mtime, 0, target);
    }

    /// Two 512-byte zero blocks close the archive; returns the `gpa`-owned complete tar
    /// byte buffer. The `Writer` must not be used again after calling this.
    pub fn finish(self: *Writer) ![]u8 {
        try self.buf.appendNTimes(self.gpa, 0, block_size * 2);
        return self.buf.toOwnedSlice(self.gpa);
    }
};

// ============================================================================ Iterator

pub const IterError = error{OutOfMemory};

pub const Iterator = struct {
    buf: []const u8,
    pos: usize = 0,
    pending_longname: ?[]const u8 = null,
    pending_longlink: ?[]const u8 = null,
    pending_pax_path: ?[]const u8 = null,

    pub fn init(buf: []const u8) Iterator {
        return .{ .buf = buf };
    }

    fn joinPrefixName(gpa: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
        if (prefix.len == 0) return gpa.dupe(u8, name);
        return std.mem.concat(gpa, u8, &.{ prefix, "/", name });
    }

    fn findPaxPath(data: []const u8) ?[]const u8 {
        // pax extended header records: "<len> <key>=<value>\n", length-prefixed.
        var i: usize = 0;
        while (i < data.len) {
            const rec_start = i;
            var j = i;
            while (j < data.len and data[j] >= '0' and data[j] <= '9') j += 1;
            if (j == i or j >= data.len or data[j] != ' ') break;
            const len = std.fmt.parseInt(usize, data[i..j], 10) catch break;
            if (rec_start + len > data.len or len == 0) break;
            const rec = data[rec_start .. rec_start + len];
            const body = rec[(j - rec_start) + 1 ..];
            const body_trimmed = if (body.len > 0 and body[body.len - 1] == '\n') body[0 .. body.len - 1] else body;
            if (std.mem.startsWith(u8, body_trimmed, "path=")) {
                return body_trimmed["path=".len..];
            }
            i = rec_start + len;
        }
        return null;
    }

    /// Next entry, or `null` at end of archive (a zero-filled header block, or the
    /// buffer simply running out). Directive entries (GNU longname/longlink, pax
    /// headers) are consumed transparently and never surfaced to the caller.
    pub fn next(self: *Iterator, gpa: std.mem.Allocator) IterError!?Entry {
        while (true) {
            if (self.pos + block_size > self.buf.len) return null;
            const block = self.buf[self.pos..][0..block_size];
            if (isAllZero(block)) return null;
            self.pos += block_size;

            const name_field = trimNulPad(block[0..100]);
            const mode = parseNumField(block[100..108]);
            const size = parseNumField(block[124..136]);
            const mtime = parseNumField(block[136..148]);
            const typeflag = block[156];
            const linkname_field = trimNulPad(block[157..257]);
            const magic_ok = std.mem.eql(u8, block[257..263], "ustar\x00");
            const prefix_field = if (magic_ok) trimNulPad(block[345..500]) else "";

            const data_start = self.pos;
            const avail = if (self.buf.len > data_start) self.buf.len - data_start else 0;
            const data_len: usize = @intCast(@min(size, avail));
            const data = self.buf[data_start..][0..data_len];
            self.pos += @intCast(roundUp512(size));

            switch (typeflag) {
                'L' => {
                    self.pending_longname = trimNulPad(data);
                    continue;
                },
                'K' => {
                    self.pending_longlink = trimNulPad(data);
                    continue;
                },
                'x', 'g' => {
                    if (typeflag == 'x') {
                        if (findPaxPath(data)) |p| self.pending_pax_path = p;
                    }
                    continue;
                },
                else => {},
            }

            var name: []const u8 = undefined;
            if (self.pending_longname) |ln| {
                name = ln;
                self.pending_longname = null;
            } else if (self.pending_pax_path) |pp| {
                name = pp;
                self.pending_pax_path = null;
            } else {
                name = try joinPrefixName(gpa, prefix_field, name_field);
            }

            var linkname: []const u8 = linkname_field;
            if (self.pending_longlink) |ll| {
                linkname = ll;
                self.pending_longlink = null;
            }

            const kind: Kind = switch (typeflag) {
                '0', 0, '7' => .file,
                '5' => .dir,
                '2' => .symlink,
                '1' => .hardlink,
                else => .unsupported,
            };

            return Entry{
                .name = name,
                .linkname = linkname,
                .size = size,
                .mode = @intCast(mode & 0o7777),
                .mtime = @intCast(mtime),
                .kind = kind,
                .data = data,
            };
        }
    }
};
