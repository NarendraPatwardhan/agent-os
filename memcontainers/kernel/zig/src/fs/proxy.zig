//! src/fs/proxy.zig — the shared metadata/dirent codec used across backends (§2.5).
//!
//! Owns: exact binary decoding of metadata + dirents, escape rejection, unsupported-symlink behavior.
//! Invariants: byte-exact decoding (parity is bit-for-bit), A9.
//! Oracle (behavior to match): kernel/rust/src/fs/proxy.rs.

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const Metadata = vfs.Metadata;
const NodeType = vfs.NodeType;
const DirEntry = vfs.DirEntry;

pub const STAT_RECORD_LEN: usize = @intCast(constants.STAT_REC_LEN);

fn need(data: []const u8, off: usize, len: usize) FsError![]const u8 {
    const end = std.math.add(usize, off, len) catch return FsError.IoError;
    if (end > data.len) return FsError.IoError;
    return data[off..end];
}

fn u32At(data: []const u8, off: usize) FsError!u32 {
    const b = try need(data, off, 4);
    return @as(u32, b[0]) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);
}

fn u64At(data: []const u8, off: usize) FsError!u64 {
    const b = try need(data, off, 8);
    var out: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) out |= @as(u64, b[i]) << @as(u6, @intCast(i * 8));
    return out;
}

fn i64At(data: []const u8, off: usize) FsError!i64 {
    return @bitCast(try u64At(data, off));
}

pub fn parseMetadata(data: []const u8) FsError!Metadata {
    if (data.len != STAT_RECORD_LEN) return FsError.IoError;
    const kind = try u32At(data, @intCast(constants.STAT_REC_NODE_TYPE_OFF));
    const node_type: NodeType = switch (kind) {
        constants.SERVE_DIRENT_FILE => .file,
        constants.SERVE_DIRENT_DIR => .dir,
        constants.SERVE_DIRENT_SYMLINK => return FsError.NotImplemented,
        else => return FsError.IoError,
    };
    return .{
        .node_type = node_type,
        .size = try u64At(data, @intCast(constants.STAT_REC_SIZE_OFF)),
        .nlink = try u32At(data, @intCast(constants.STAT_REC_NLINK_OFF)),
        .mode = @intCast(try u32At(data, @intCast(constants.STAT_REC_MODE_OFF))),
        .mtime = try i64At(data, @intCast(constants.STAT_REC_MTIME_OFF)),
        .atime = try i64At(data, @intCast(constants.STAT_REC_ATIME_OFF)),
        .ctime = try i64At(data, @intCast(constants.STAT_REC_CTIME_OFF)),
    };
}

fn direntMeta(kind: u32) FsError!struct { NodeType, Metadata } {
    return switch (kind) {
        constants.SERVE_DIRENT_FILE => .{ .file, Metadata.file(0) },
        constants.SERVE_DIRENT_DIR => .{ .dir, Metadata.dir() },
        constants.SERVE_DIRENT_SYMLINK => FsError.NotImplemented,
        else => FsError.IoError,
    };
}

pub const ParsedDirent = struct {
    entry: DirEntry,
    child: []const u8,
    metadata: Metadata,
};

pub fn childPath(arena: std.mem.Allocator, parent: []const u8, name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, parent, "/")) return std.fmt.allocPrint(arena, "{s}{s}", .{ parent, name }) catch @panic("OOM");
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, name }) catch @panic("OOM");
}

pub fn parseDirents(arena: std.mem.Allocator, data: []const u8, parent: []const u8, out: *std.ArrayList(ParsedDirent)) FsError!void {
    var off: usize = 0;
    while (off < data.len) {
        const kind = try u32At(data, off);
        const len = try u32At(data, off + 4);
        const name_start = off + 8;
        const name_end = std.math.add(usize, name_start, @intCast(len)) catch return FsError.IoError;
        if (name_end > data.len) return FsError.IoError;
        const name = data[name_start..name_end];
        if (!std.unicode.utf8ValidateSlice(name)) return FsError.IoError;
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return FsError.IoError;
        if (std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, name, '/') != null) return FsError.IoError;
        const parsed = try direntMeta(kind);
        const owned_name = arena.dupe(u8, name) catch @panic("OOM");
        out.append(arena, .{
            .entry = .{ .name = owned_name, .node_type = parsed[0] },
            .child = childPath(arena, parent, owned_name),
            .metadata = parsed[1],
        }) catch @panic("OOM");
        off = name_end;
    }
}

pub fn cachedMeta(meta: *std.StringHashMapUnmanaged(Metadata), path: []const u8) ?Metadata {
    return meta.get(path);
}

pub fn rememberMeta(gpa: std.mem.Allocator, meta: *std.StringHashMapUnmanaged(Metadata), path: []const u8, m: Metadata) void {
    if (meta.getPtr(path)) |slot| {
        slot.* = m;
        return;
    }
    meta.put(gpa, gpa.dupe(u8, path) catch @panic("OOM"), m) catch @panic("OOM");
}

pub fn forgetPath(gpa: std.mem.Allocator, meta: *std.StringHashMapUnmanaged(Metadata), path: []const u8) void {
    if (std.mem.eql(u8, path, "/")) return;
    const prefix = if (std.mem.endsWith(u8, path, "/"))
        gpa.dupe(u8, path) catch @panic("OOM")
    else
        std.fmt.allocPrint(gpa, "{s}/", .{path}) catch @panic("OOM");
    defer gpa.free(prefix);
    var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer doomed.deinit(gpa);
    var it = meta.keyIterator();
    while (it.next()) |k| {
        if (std.mem.eql(u8, k.*, path) or std.mem.startsWith(u8, k.*, prefix)) {
            doomed.append(gpa, k.*) catch @panic("OOM");
        }
    }
    for (doomed.items) |k| {
        if (meta.fetchRemove(k)) |kv| gpa.free(kv.key);
    }
}

pub fn renamePath(gpa: std.mem.Allocator, meta: *std.StringHashMapUnmanaged(Metadata), from: []const u8, to: []const u8) void {
    if (std.mem.eql(u8, from, "/")) return;
    const prefix = if (std.mem.endsWith(u8, from, "/"))
        gpa.dupe(u8, from) catch @panic("OOM")
    else
        std.fmt.allocPrint(gpa, "{s}/", .{from}) catch @panic("OOM");
    defer gpa.free(prefix);

    var moved: std.ArrayListUnmanaged(struct { old: []const u8, new: []u8, meta: Metadata }) = .empty;
    defer moved.deinit(gpa);
    var it = meta.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, from) or std.mem.startsWith(u8, key, prefix)) {
            const suffix = if (std.mem.eql(u8, key, from)) "" else key[from.len..];
            moved.append(gpa, .{
                .old = key,
                .new = std.fmt.allocPrint(gpa, "{s}{s}", .{ to, suffix }) catch @panic("OOM"),
                .meta = entry.value_ptr.*,
            }) catch @panic("OOM");
        }
    }
    for (moved.items) |m| {
        if (meta.fetchRemove(m.old)) |kv| gpa.free(kv.key);
        meta.put(gpa, m.new, m.meta) catch @panic("OOM");
    }
}

pub fn forgetChildrenOf(gpa: std.mem.Allocator, meta: *std.StringHashMapUnmanaged(Metadata), dir: []const u8) void {
    const prefix = if (std.mem.endsWith(u8, dir, "/"))
        gpa.dupe(u8, dir) catch @panic("OOM")
    else
        std.fmt.allocPrint(gpa, "{s}/", .{dir}) catch @panic("OOM");
    defer gpa.free(prefix);
    var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer doomed.deinit(gpa);
    var it = meta.keyIterator();
    while (it.next()) |k| {
        if (!std.mem.eql(u8, k.*, dir) and std.mem.startsWith(u8, k.*, prefix)) doomed.append(gpa, k.*) catch @panic("OOM");
    }
    for (doomed.items) |k| {
        if (meta.fetchRemove(k)) |kv| gpa.free(kv.key);
    }
}
