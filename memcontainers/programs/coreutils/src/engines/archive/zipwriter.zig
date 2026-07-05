//! ZIP writer + reader (DESIGN.md §7.5) for the `zip`/`unzip` applets. Whole-archive
//! in-memory model: entries are buffered (as the reference Rust `zip` crate's own
//! writer effectively is too -- it back-patches the central directory via seeks, which
//! is equivalent to "know everything before you finalize"), the local file header +
//! compressed data are appended as each entry is added, and `finish()` appends the
//! central directory + End Of Central Directory record and hands back one owned byte
//! buffer.
//!
//! **Reader deviation from the milestone brief**: the brief suggested reusing
//! `std.zip`'s `Iterator`, but that type's `init` takes a `*std.Io.File.Reader` --
//! i.e. it is wired to `std.Io.File`, the exact high-level filesystem/IO machinery
//! DESIGN.md §11 rule 2 says never to import in shipped code (wasm bloat; the sys
//! backends own all real fd I/O). Since this project already holds whole archives in
//! memory (`fs/` fixtures are tiny, and the zip applet's own "full-rewrite" model loads
//! everything anyway), the reader here is a small hand-rolled central-directory parse
//! directly over an in-memory `[]const u8` -- format constants (signatures, record
//! layouts) match `std.zip`, only the traversal machinery differs. `std.compress.flate`
//! (raw container) still does the actual inflate work.
//!
//! Local file header (30 bytes) + name; central directory record (46 bytes) + name;
//! EOCD (22 bytes). No zip64 (DESIGN.md §7.5: the in-memory model already caps
//! practical sizes; archives/entries over 4 GiB are a documented error). DOS
//! date/time fields are derived from a Unix mtime via `core/civil.zig`. External
//! attributes store the Unix mode in the high 16 bits (`mode << 16`), matching the
//! reference `zip` crate's `unix_permissions`; `version_made_by`'s high byte is 3
//! (Unix, RFC-ish convention used by every zip implementation that wants Unix modes
//! respected by other unzippers). `version_needed_to_extract` is always 20 (2.0,
//! deflate's minimum).

const std = @import("std");
const flate = std.compress.flate;
const gzcli = @import("../compress/gzcli.zig");
const civil = @import("../../core/civil.zig");

pub const Method = enum(u16) { store = 0, deflate = 8 };

const local_sig = [4]u8{ 'P', 'K', 3, 4 };
const central_sig = [4]u8{ 'P', 'K', 1, 2 };
const eocd_sig = [4]u8{ 'P', 'K', 5, 6 };

fn dosFromEpochS(epoch_s: i64) struct { time: u16, date: u16 } {
    const clamped = @max(epoch_s, 0);
    const days = @divFloor(clamped, 86400);
    const tod = clamped - days * 86400;
    const d = civil.civilFromDays(days);
    const hh: u32 = @intCast(@divTrunc(tod, 3600));
    const mm: u32 = @intCast(@mod(@divTrunc(tod, 60), 60));
    const ss: u32 = @intCast(@mod(tod, 60));
    // DOS can't represent years before 1980; clamp (matches every real zip writer).
    const dos_year: u32 = if (d.year < 1980) 0 else @intCast(@min(@as(i64, d.year) - 1980, 127));
    const time: u16 = @intCast((hh << 11) | (mm << 5) | (ss / 2));
    const date: u16 = @intCast((dos_year << 9) | (d.month << 5) | d.day);
    return .{ .time = time, .date = date };
}

fn epochSFromDos(dos_date: u16, dos_time: u16) i64 {
    const year: i64 = 1980 + (dos_date >> 9);
    const month: u32 = (dos_date >> 5) & 0xf;
    const day: u32 = dos_date & 0x1f;
    const hh: u32 = dos_time >> 11;
    const mm: u32 = (dos_time >> 5) & 0x3f;
    const ss: u32 = (dos_time & 0x1f) * 2;
    if (month < 1 or month > 12 or day < 1) return 0;
    return civil.daysFromCivil(year, month, day) * 86400 + hh * 3600 + mm * 60 + ss;
}

fn deflateRaw(gpa: std.mem.Allocator, input: []const u8, level: u8) ![]u8 {
    const initial_cap = @max(64, input.len / 2 + 64);
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, initial_cap);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var comp = try flate.Compress.init(&out.writer, &window, .raw, gzcli.optsForLevel(level));
    try comp.writer.writeAll(input);
    try comp.finish();
    var al = out.toArrayList();
    return al.toOwnedSlice(gpa);
}

fn inflateRaw(gpa: std.mem.Allocator, compressed: []const u8, uncompressed_size: u32) ![]u8 {
    var in_reader = std.Io.Reader.fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in_reader, .raw, &window);
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    dec.reader.appendRemaining(gpa, &list, .limited(@max(uncompressed_size, 1) * 4 + 4096)) catch |e| switch (e) {
        error.StreamTooLong => return error.CorruptZipEntry,
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return error.CorruptZipEntry,
    };
    return list.toOwnedSlice(gpa);
}

fn put16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}
fn put32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
fn get16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}
fn get32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

// ============================================================================ Writer

pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    central: std.ArrayListUnmanaged(u8) = .empty,
    count: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    /// `name` should already be normalized (forward slashes, no leading `./`) by the
    /// caller. `is_dir` entries are always stored (method ignored) with a trailing `/`
    /// name and zero size, matching the reference `zip` crate's directory entries.
    pub fn addEntry(self: *Writer, name: []const u8, data: []const u8, mode: u32, mtime_s: i64, method: Method, is_dir: bool) !void {
        return self.addEntryLeveled(name, data, mode, mtime_s, method, is_dir, 6);
    }

    /// Like `addEntry`, but with an explicit DEFLATE level (1-9; ignored for `.store`).
    pub fn addEntryLeveled(self: *Writer, name: []const u8, data: []const u8, mode: u32, mtime_s: i64, method: Method, is_dir: bool, level: u8) !void {
        const gpa = self.gpa;
        const local_offset: u32 = @intCast(self.buf.items.len);
        const dt = dosFromEpochS(mtime_s);
        const crc = std.hash.Crc32.hash(data);

        const eff_method: Method = if (is_dir) .store else method;
        var compressed: []const u8 = data;
        var owned: ?[]u8 = null;
        if (eff_method == .deflate) {
            owned = try deflateRaw(gpa, data, level);
            compressed = owned.?;
        }
        defer if (owned) |o| gpa.free(o);

        if (compressed.len > std.math.maxInt(u32) or data.len > std.math.maxInt(u32)) return error.EntryTooLarge;

        var lh: [30]u8 = @splat(0);
        @memcpy(lh[0..4], &local_sig);
        put16(&lh, 4, 20); // version needed
        put16(&lh, 6, 0); // flags
        put16(&lh, 8, @intFromEnum(eff_method));
        put16(&lh, 10, dt.time);
        put16(&lh, 12, dt.date);
        put32(&lh, 14, crc);
        put32(&lh, 18, @intCast(compressed.len));
        put32(&lh, 22, @intCast(data.len));
        put16(&lh, 26, @intCast(name.len));
        put16(&lh, 28, 0); // extra len
        try self.buf.appendSlice(gpa, &lh);
        try self.buf.appendSlice(gpa, name);
        try self.buf.appendSlice(gpa, compressed);

        const unix_mode: u32 = if (is_dir) (0o40000 | (mode & 0o7777)) else (0o100000 | (mode & 0o7777));
        const dos_dir_bit: u32 = if (is_dir) 0x10 else 0;
        const external_attrs: u32 = (unix_mode << 16) | dos_dir_bit;

        var ch: [46]u8 = @splat(0);
        @memcpy(ch[0..4], &central_sig);
        put16(&ch, 4, (3 << 8) | 20); // version made by: unix, 2.0
        put16(&ch, 6, 20); // version needed
        put16(&ch, 8, 0); // flags
        put16(&ch, 10, @intFromEnum(eff_method));
        put16(&ch, 12, dt.time);
        put16(&ch, 14, dt.date);
        put32(&ch, 16, crc);
        put32(&ch, 20, @intCast(compressed.len));
        put32(&ch, 24, @intCast(data.len));
        put16(&ch, 28, @intCast(name.len));
        put16(&ch, 30, 0); // extra len
        put16(&ch, 32, 0); // comment len
        put16(&ch, 34, 0); // disk number start
        put16(&ch, 36, 0); // internal attrs
        put32(&ch, 38, external_attrs);
        put32(&ch, 42, local_offset);
        try self.central.appendSlice(gpa, &ch);
        try self.central.appendSlice(gpa, name);

        self.count += 1;
    }

    /// Appends the central directory + EOCD and returns the `gpa`-owned complete zip
    /// byte buffer. The `Writer` must not be used again after calling this.
    pub fn finish(self: *Writer) ![]u8 {
        const gpa = self.gpa;
        const cd_offset: u32 = @intCast(self.buf.items.len);
        const cd_size: u32 = @intCast(self.central.items.len);
        try self.buf.appendSlice(gpa, self.central.items);
        self.central.deinit(gpa);

        var eocd: [22]u8 = @splat(0);
        @memcpy(eocd[0..4], &eocd_sig);
        put16(&eocd, 4, 0); // this disk
        put16(&eocd, 6, 0); // cd start disk
        put16(&eocd, 8, @intCast(self.count));
        put16(&eocd, 10, @intCast(self.count));
        put32(&eocd, 12, cd_size);
        put32(&eocd, 16, cd_offset);
        put16(&eocd, 20, 0); // comment len
        try self.buf.appendSlice(gpa, &eocd);

        return self.buf.toOwnedSlice(gpa);
    }
};

// ============================================================================ Reader

pub const ReadError = error{ NotAZip, CorruptZipEntry, OutOfMemory, EntryTooLarge };

pub const CentralEntry = struct {
    name: []const u8,
    method: Method,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
    external_attrs: u32,
    mtime_s: i64,

    pub fn isDir(self: CentralEntry) bool {
        return (self.external_attrs & 0x10) != 0 or (self.name.len > 0 and self.name[self.name.len - 1] == '/');
    }

    pub fn unixMode(self: CentralEntry) u32 {
        return (self.external_attrs >> 16) & 0o7777;
    }
};

/// Scans backward for the EOCD signature (handles a trailing comment, though this
/// engine never writes one).
fn findEocd(archive: []const u8) ReadError!usize {
    if (archive.len < 22) return error.NotAZip;
    const max_comment: usize = 65535;
    const search_from = if (archive.len > 22 + max_comment) archive.len - 22 - max_comment else 0;
    var i = archive.len - 22;
    while (true) {
        if (std.mem.eql(u8, archive[i..][0..4], &eocd_sig)) return i;
        if (i == search_from) break;
        i -= 1;
    }
    return error.NotAZip;
}

/// Parses the central directory into a `gpa`-owned slice of entries (names are slices
/// borrowed from `archive`, valid as long as it is).
pub fn listEntries(gpa: std.mem.Allocator, archive: []const u8) ReadError![]CentralEntry {
    const eocd_pos = try findEocd(archive);
    const total_entries = get16(archive, eocd_pos + 10);
    const cd_size = get32(archive, eocd_pos + 12);
    const cd_offset = get32(archive, eocd_pos + 16);
    if (@as(u64, cd_offset) + cd_size > archive.len) return error.NotAZip;

    var entries: std.ArrayListUnmanaged(CentralEntry) = .empty;
    var pos: usize = cd_offset;
    var i: u16 = 0;
    while (i < total_entries) : (i += 1) {
        if (pos + 46 > archive.len) return error.CorruptZipEntry;
        if (!std.mem.eql(u8, archive[pos..][0..4], &central_sig)) return error.CorruptZipEntry;
        const method_raw = get16(archive, pos + 10);
        const dos_time = get16(archive, pos + 12);
        const dos_date = get16(archive, pos + 14);
        const crc = get32(archive, pos + 16);
        const comp_size = get32(archive, pos + 20);
        const uncomp_size = get32(archive, pos + 24);
        const name_len = get16(archive, pos + 28);
        const extra_len = get16(archive, pos + 30);
        const comment_len = get16(archive, pos + 32);
        const external_attrs = get32(archive, pos + 38);
        const local_offset = get32(archive, pos + 42);
        const name_start = pos + 46;
        if (name_start + name_len > archive.len) return error.CorruptZipEntry;
        const name = archive[name_start..][0..name_len];

        entries.append(gpa, .{
            .name = name,
            .method = if (method_raw == 8) .deflate else .store,
            .crc32 = crc,
            .compressed_size = comp_size,
            .uncompressed_size = uncomp_size,
            .local_header_offset = local_offset,
            .external_attrs = external_attrs,
            .mtime_s = epochSFromDos(dos_date, dos_time),
        }) catch return error.OutOfMemory;

        pos = name_start + name_len + extra_len + comment_len;
    }
    return entries.toOwnedSlice(gpa) catch error.OutOfMemory;
}

/// Decompresses one entry's data (verifying CRC32 against the central directory
/// record), given the whole archive buffer and that entry's `CentralEntry`.
pub fn extractEntry(gpa: std.mem.Allocator, archive: []const u8, entry: CentralEntry) ReadError![]u8 {
    const lh = entry.local_header_offset;
    if (@as(u64, lh) + 30 > archive.len) return error.CorruptZipEntry;
    if (!std.mem.eql(u8, archive[lh..][0..4], &local_sig)) return error.CorruptZipEntry;
    const name_len = get16(archive, lh + 26);
    const extra_len = get16(archive, lh + 28);
    const data_start = lh + 30 + name_len + extra_len;
    if (@as(u64, data_start) + entry.compressed_size > archive.len) return error.CorruptZipEntry;
    const compressed = archive[data_start..][0..entry.compressed_size];

    const data = switch (entry.method) {
        .store => try gpa.dupe(u8, compressed),
        .deflate => inflateRaw(gpa, compressed, entry.uncompressed_size) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CorruptZipEntry,
        },
    };
    errdefer gpa.free(data);
    if (std.hash.Crc32.hash(data) != entry.crc32) return error.CorruptZipEntry;
    return data;
}
