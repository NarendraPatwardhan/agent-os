//! src/fs/tarfs.zig — read-only POSIX-ustar base-image view (§2.5).
//!
//! Owns: ustar parsing, hardlink/symlink treatment, read-only file/dir handles. The base
//! images are uncompressed .tar (matching the oracle, whose `compressed` flag never drives
//! inline decompression). Oracle: kernel/rust/src/fs/tarfs.rs.
//! Not here: COW writes (cowfs.zig); mount policy (vfs.zig).

const std = @import("std");
const vfs = @import("../vfs.zig");
const FsError = vfs.FsError;
const NodeType = vfs.NodeType;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const DirEntry = vfs.DirEntry;

const MAX_PATH = 4096;
const TAR_TYPE_HARDLINK: u8 = '1';
const TAR_TYPE_SYMLINK: u8 = '2';
const TAR_TYPE_DIR: u8 = '5';

const TarEntry = struct {
    data_offset: usize,
    size: usize,
    entry_type: NodeType,
    mode: u32,
    mtime: i64,
    nlink: u32,
    target: []const u8, // owned; symlink target text (empty for non-symlinks)
};

pub const TarFs = struct {
    gpa: std.mem.Allocator,
    data: []u8, // owned tar bytes
    entries: std.StringHashMapUnmanaged(TarEntry) = .{}, // owns path keys

    /// Build a TarFs over owned `data`. Returns null on a malformed archive.
    pub fn create(gpa: std.mem.Allocator, data: []u8) ?*TarFs {
        const self = gpa.create(TarFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .data = data };
        self.buildIndex();
        if (!self.entries.contains("/")) {
            self.entries.put(gpa, gpa.dupe(u8, "/") catch @panic("OOM"), .{
                .data_offset = 0,
                .size = 0,
                .entry_type = .dir,
                .mode = 0o755,
                .mtime = 0,
                .nlink = 1,
                .target = "",
            }) catch @panic("OOM");
        }
        return self;
    }

    pub fn fileSystem(self: *TarFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn readOctal(field: []const u8) u64 {
        const t = std.mem.trim(u8, field, " \x00");
        return std.fmt.parseInt(u64, t, 8) catch 0;
    }

    fn headerString(header: []const u8, start: usize, max_len: usize) []const u8 {
        var end = start;
        while (end < start + max_len and end < header.len and header[end] != 0) : (end += 1) {}
        return header[start..end];
    }

    /// ustar path: name (0-99) + optional strict-ustar prefix (345-499). GNU headers reuse
    /// bytes 345+ for times, so gate the prefix on the strict `ustar\0` magic (257-262).
    fn readPath(self: *TarFs, gpa: std.mem.Allocator, header: []const u8) []const u8 {
        _ = self;
        const name = headerString(header, 0, 100);
        const posix_ustar = header.len >= 263 and std.mem.eql(u8, header[257..263], "ustar\x00");
        if (!posix_ustar) return gpa.dupe(u8, name) catch @panic("OOM");
        const prefix = headerString(header, 345, 155);
        if (prefix.len == 0) return gpa.dupe(u8, name) catch @panic("OOM");
        if (name.len == 0) return gpa.dupe(u8, prefix) catch @panic("OOM");
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, name }) catch @panic("OOM");
    }

    fn buildIndex(self: *TarFs) void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();

        var offset: usize = 0;
        while (offset + 512 <= self.data.len) {
            const header = self.data[offset .. offset + 512];
            var all_zero = true;
            for (header) |b| {
                if (b != 0) {
                    all_zero = false;
                    break;
                }
            }
            if (all_zero) break;

            const raw_name = self.readPath(sa, header);
            const size: usize = @intCast(readOctal(header[124..136]));
            const typeflag = header[156];
            const entry_type: NodeType = switch (typeflag) {
                TAR_TYPE_DIR => .dir,
                TAR_TYPE_SYMLINK => .symlink,
                else => .file,
            };
            const linkname = headerString(header, 157, 100);
            const mode: u32 = @intCast(readOctal(header[100..108]));
            const mtime: i64 = @intCast(readOctal(header[136..148]));
            const data_offset = offset + 512;
            const next_offset = data_offset + ((size + 511) / 512) * 512;
            const path = tarPath(self.gpa, raw_name);

            var target: []const u8 = "";
            if (typeflag == TAR_TYPE_SYMLINK) {
                target = self.gpa.dupe(u8, linkname) catch @panic("OOM");
            }

            var entry = TarEntry{
                .data_offset = data_offset,
                .size = size,
                .entry_type = entry_type,
                .mode = if (mode == 0) 0o644 else mode,
                .mtime = mtime,
                .nlink = 1,
                .target = target,
            };
            // Resolve a hard link ('1') to its (already-indexed) target's bytes.
            if (entry_type == .file and typeflag == TAR_TYPE_HARDLINK) {
                const hl_target = tarPath(sa, linkname);
                if (self.entries.get(hl_target)) |t| {
                    entry.data_offset = t.data_offset;
                    entry.size = t.size;
                }
            }
            self.putEntry(path, entry);
            offset = next_offset;
        }

        // Hard-link counts: file entries sharing a resolved data_offset are one inode.
        var links = std.AutoHashMapUnmanaged(usize, u32){};
        defer links.deinit(self.gpa);
        var it = self.entries.valueIterator();
        while (it.next()) |e| {
            if (e.entry_type == .file) {
                const gop = links.getOrPut(self.gpa, e.data_offset) catch @panic("OOM");
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
        var it2 = self.entries.valueIterator();
        while (it2.next()) |e| {
            if (e.entry_type == .file) {
                if (links.get(e.data_offset)) |n| e.nlink = n;
            }
        }
    }

    fn putEntry(self: *TarFs, path: []const u8, entry: TarEntry) void {
        const gop = self.entries.getOrPut(self.gpa, path) catch @panic("OOM");
        if (gop.found_existing) {
            self.gpa.free(path);
        }
        gop.value_ptr.* = entry;
    }

    fn getEntry(self: *TarFs, path_in: []const u8) ?*TarEntry {
        var nb: [MAX_PATH]u8 = undefined;
        const path = normPath(path_in, &nb) orelse return null;
        return self.entries.getPtr(path);
    }

    fn entryMeta(entry: *const TarEntry) Metadata {
        const ms = entry.mtime *| 1000;
        const base = switch (entry.entry_type) {
            .dir => Metadata.dir(),
            .file => Metadata.fileWithNlink(entry.size, entry.nlink),
            .symlink => Metadata.symlink(entry.target.len),
        };
        return base.withMode(@intCast(entry.mode & 0o7777)).withTimes(ms, ms, ms);
    }

    // ── FileSystem impl ───────────────────────────────────────────────────────────────────
    fn open(self: *TarFs, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const entry = self.getEntry(path) orelse return FsError.NotFound;
        if (flags.write or flags.create or flags.truncate) return FsError.PermissionDenied;
        switch (entry.entry_type) {
            .dir => return FsError.IsDir,
            .symlink => return FsError.InvalidPath,
            .file => {},
        }
        const h = self.gpa.create(TarFileHandle) catch @panic("OOM");
        h.* = .{ .fs = self, .offset = 0, .data_offset = entry.data_offset, .size = entry.size, .nlink = entry.nlink, .mode = entry.mode, .mtime = entry.mtime };
        return .{ .ptr = h, .vtable = &TarFileHandle.handle_vtable };
    }

    fn stat(self: *TarFs, path: []const u8) FsError!Metadata {
        const entry = self.getEntry(path) orelse return FsError.NotFound;
        return entryMeta(entry);
    }

    fn readdir(self: *TarFs, path_in: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const path = normPath(path_in, &nb) orelse return FsError.InvalidPath;
        var prefix_buf: [MAX_PATH + 1]u8 = undefined;
        const prefix = if (std.mem.endsWith(u8, path, "/")) path else blk: {
            @memcpy(prefix_buf[0..path.len], path);
            prefix_buf[path.len] = '/';
            break :blk prefix_buf[0 .. path.len + 1];
        };
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const ep = kv.key_ptr.*;
            if (std.mem.eql(u8, ep, path)) continue;
            if (std.mem.startsWith(u8, ep, prefix)) {
                const rel = ep[prefix.len..];
                if (std.mem.indexOfScalar(u8, rel, '/') == null) {
                    out.append(arena, .{ .name = arena.dupe(u8, rel) catch @panic("OOM"), .node_type = kv.value_ptr.entry_type }) catch @panic("OOM");
                }
            }
        }
    }

    fn readlink(self: *TarFs, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        const entry = self.getEntry(path) orelse return FsError.NotFound;
        if (entry.entry_type != .symlink) return FsError.InvalidPath;
        out.appendSlice(self.gpa, entry.target) catch @panic("OOM");
    }

    const fs_vtable = FileSystem.VTable{
        .open = fsOpen,
        .stat = fsStat,
        .readdir = fsReaddir,
        .mkdir = fsReadOnly1,
        .unlink = fsReadOnly1,
        .rename = vfs.fsRenameUnsupported,
        .symlink = vfs.fsSymlinkUnsupported,
        .link = vfs.fsLinkUnsupported,
        .readlink = fsReadlink,
        .setMode = vfs.fsSetModeUnsupported,
        .setTimes = vfs.fsSetTimesUnsupported,
    };
    fn fsOpen(p: *anyopaque, _: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        return self_(p).open(path, flags);
    }
    fn fsStat(p: *anyopaque, path: []const u8) FsError!Metadata {
        return self_(p).stat(path);
    }
    fn fsReaddir(p: *anyopaque, _: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void {
        return self_(p).readdir(path, arena, out);
    }
    fn fsReadOnly1(_: *anyopaque, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn fsReadlink(p: *anyopaque, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        return self_(p).readlink(path, out);
    }
    fn self_(p: *anyopaque) *TarFs {
        return @ptrCast(@alignCast(p));
    }
};

const TarFileHandle = struct {
    fs: *TarFs,
    offset: u64,
    data_offset: usize,
    size: usize,
    nlink: u32,
    mode: u32,
    mtime: i64,

    fn read(self: *TarFileHandle, buf: []u8) FsError!usize {
        const start: usize = @intCast(self.offset);
        if (start >= self.size) return 0;
        const end = @min(start + buf.len, self.size);
        const n = end - start;
        @memcpy(buf[0..n], self.fs.data[self.data_offset + start .. self.data_offset + end]);
        self.offset += n;
        return n;
    }
    fn write(_: *TarFileHandle, _: []const u8) FsError!usize {
        return FsError.PermissionDenied;
    }
    fn seek(self: *TarFileHandle, pos: SeekFrom) FsError!u64 {
        const size: i64 = @intCast(self.size);
        const new_off: i64 = switch (pos) {
            .start => |n| @intCast(n),
            .current => |n| @as(i64, @intCast(self.offset)) + n,
            .end => |n| size + n,
        };
        if (new_off < 0) return FsError.InvalidPath;
        self.offset = @intCast(new_off);
        return self.offset;
    }
    fn stat(self: *TarFileHandle) FsError!Metadata {
        const ms = self.mtime *| 1000;
        return Metadata.fileWithNlink(self.size, self.nlink).withMode(@intCast(self.mode & 0o7777)).withTimes(ms, ms, ms);
    }

    const handle_vtable = FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = vfs.handleTruncateUnsupported,
        .close = hClose,
    };
    fn hRead(p: *anyopaque, buf: []u8) FsError!usize {
        return h_(p).read(buf);
    }
    fn hWrite(p: *anyopaque, buf: []const u8) FsError!usize {
        return h_(p).write(buf);
    }
    fn hSeek(p: *anyopaque, pos: SeekFrom) FsError!u64 {
        return h_(p).seek(pos);
    }
    fn hStat(p: *anyopaque) FsError!Metadata {
        return h_(p).stat();
    }
    fn hClose(p: *anyopaque) void {
        const self = h_(p);
        self.fs.gpa.destroy(self);
    }
    fn h_(p: *anyopaque) *TarFileHandle {
        return @ptrCast(@alignCast(p));
    }
};

fn normPath(path: []const u8, buf: []u8) ?[]const u8 {
    _ = buf;
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return "/";
    return path;
}

/// Normalize a tar entry name to an absolute VFS path (arena/gpa-owned).
fn tarPath(alloc: std.mem.Allocator, name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "./")) {
        const stripped = std.mem.trimEnd(u8, name[1..], "/");
        return alloc.dupe(u8, if (stripped.len == 0) "/" else stripped) catch @panic("OOM");
    } else if (std.mem.startsWith(u8, name, "/")) {
        return alloc.dupe(u8, std.mem.trimEnd(u8, name, "/")) catch @panic("OOM");
    }
    const stripped = std.mem.trimEnd(u8, name, "/");
    return std.fmt.allocPrint(alloc, "/{s}", .{stripped}) catch @panic("OOM");
}
