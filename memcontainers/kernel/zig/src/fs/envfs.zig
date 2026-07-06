//! src/fs/envfs.zig — environment variables projected as files (§2.5).
//!
//! Owns: reads/writes of env entries, env inheritance, and error behavior.
//! Invariants: A7, A9.
//! Oracle (behavior to match): kernel/rust/src/fs/envfs.rs.
//! Not here: process env ownership (task.zig).
//!
//! Scaffold status: header-only. Fill Phase 3.
// TODO(E2): projected /env is outside the resident-service protocol core.

const std = @import("std");
const scheduler = @import("../scheduler.zig");
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

const EnvMap = std.StringHashMapUnmanaged([]const u8);

pub const EnvFs = struct {
    gpa: std.mem.Allocator,
    sched: *scheduler.Scheduler,
    fallback: *EnvMap,

    pub fn create(gpa: std.mem.Allocator, sched: *scheduler.Scheduler, fallback: *EnvMap) *EnvFs {
        const self = gpa.create(EnvFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .sched = sched, .fallback = fallback };
        return self;
    }

    pub fn fileSystem(self: *EnvFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn varName(path: []const u8) ?[]const u8 {
        const name = std.mem.trim(u8, path, "/");
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
        return name;
    }

    fn mapFor(self: *EnvFs, caller: vfs.CallerId) *EnvMap {
        var pid = caller;
        if (pid == vfs.SYSTEM_CALLER) pid = self.sched.current orelse vfs.SYSTEM_CALLER;
        if (pid != vfs.SYSTEM_CALLER) {
            if (self.sched.getTask(pid)) |t| return &t.env;
        }
        return self.fallback;
    }

    fn open(self: *EnvFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const name = varName(path) orelse return FsError.IsDir;
        const writes = flags.write or flags.create or flags.truncate or flags.append;
        const map = if (writes and caller == vfs.SYSTEM_CALLER) self.fallback else self.mapFor(caller);
        if (writes) {
            const h = self.gpa.create(WriteHandle) catch @panic("OOM");
            h.* = .{
                .gpa = self.gpa,
                .map = map,
                .name = self.gpa.dupe(u8, name) catch @panic("OOM"),
            };
            if (flags.append) {
                if (map.get(name)) |old| h.buf.appendSlice(self.gpa, old) catch @panic("OOM");
            }
            return h.fileHandle();
        }
        const value = map.get(name) orelse return FsError.NotFound;
        return ReadHandle.open(self.gpa, value);
    }

    fn stat(self: *EnvFs, path: []const u8) FsError!Metadata {
        const name = varName(path) orelse return Metadata.dir();
        const map = self.mapFor(vfs.SYSTEM_CALLER);
        const value = map.get(name) orelse return FsError.NotFound;
        return Metadata.file(value.len);
    }

    fn readdir(self: *EnvFs, _: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        if (varName(path) != null or std.mem.trim(u8, path, "/").len != 0) return FsError.NotDir;
        const map = self.mapFor(vfs.SYSTEM_CALLER);
        var it = map.keyIterator();
        while (it.next()) |k| out.append(arena, .{ .name = arena.dupe(u8, k.*) catch @panic("OOM"), .node_type = .file }) catch @panic("OOM");
    }

    fn unlink(self: *EnvFs, _: vfs.CallerId, path: []const u8) FsError!void {
        const name = varName(path) orelse return FsError.IsDir;
        const map = self.mapFor(vfs.SYSTEM_CALLER);
        if (map.fetchRemove(name)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
            return;
        }
        return FsError.NotFound;
    }

    fn denyMkdir(_: *EnvFs, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn denyRename(_: *EnvFs, _: vfs.CallerId, _: []const u8, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }

    const fs_vtable = FileSystem.VTable{
        .open = fsOpen,
        .stat = fsStat,
        .readdir = fsReaddir,
        .mkdir = fsMkdir,
        .unlink = fsUnlink,
        .rename = fsRename,
        .symlink = vfs.fsSymlinkUnsupported,
        .link = vfs.fsLinkUnsupported,
        .readlink = vfs.fsReadlinkUnsupported,
        .setMode = vfs.fsSetModeUnsupported,
        .setTimes = vfs.fsSetTimesUnsupported,
    };

    fn self_(p: *anyopaque) *EnvFs {
        return @ptrCast(@alignCast(p));
    }
    fn fsOpen(p: *anyopaque, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        return self_(p).open(caller, path, flags);
    }
    fn fsStat(p: *anyopaque, path: []const u8) FsError!Metadata {
        return self_(p).stat(path);
    }
    fn fsReaddir(p: *anyopaque, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        return self_(p).readdir(caller, path, arena, out);
    }
    fn fsMkdir(p: *anyopaque, caller: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).denyMkdir(caller, path);
    }
    fn fsUnlink(p: *anyopaque, caller: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).unlink(caller, path);
    }
    fn fsRename(p: *anyopaque, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        return self_(p).denyRename(caller, from, to);
    }
};

const ReadHandle = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    pos: usize = 0,

    fn open(gpa: std.mem.Allocator, bytes: []const u8) FileHandle {
        const h = gpa.create(ReadHandle) catch @panic("OOM");
        h.* = .{ .gpa = gpa, .data = gpa.dupe(u8, bytes) catch @panic("OOM") };
        return h.fileHandle();
    }
    fn fileHandle(self: *ReadHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *ReadHandle, out: []u8) FsError!usize {
        const start = @min(self.pos, self.data.len);
        const n = @min(out.len, self.data.len - start);
        if (n != 0) @memcpy(out[0..n], self.data[start .. start + n]);
        self.pos = start + n;
        return n;
    }
    fn write(_: *ReadHandle, _: []const u8) FsError!usize {
        return FsError.PermissionDenied;
    }
    fn seek(self: *ReadHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.pos)) + n,
            .end => |n| @as(i64, @intCast(self.data.len)) + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.pos = @intCast(next);
        return @intCast(self.pos);
    }
    fn stat(self: *ReadHandle) FsError!Metadata {
        return Metadata.file(self.data.len);
    }
    fn truncate(_: *ReadHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }
    fn close(self: *ReadHandle) void {
        const gpa = self.gpa;
        gpa.free(self.data);
        gpa.destroy(self);
    }
    const vtable = FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
        .close = hClose,
    };
    fn self_(p: *anyopaque) *ReadHandle {
        return @ptrCast(@alignCast(p));
    }
    fn hRead(p: *anyopaque, out: []u8) FsError!usize {
        return self_(p).read(out);
    }
    fn hWrite(p: *anyopaque, bytes: []const u8) FsError!usize {
        return self_(p).write(bytes);
    }
    fn hSeek(p: *anyopaque, pos: SeekFrom) FsError!u64 {
        return self_(p).seek(pos);
    }
    fn hStat(p: *anyopaque) FsError!Metadata {
        return self_(p).stat();
    }
    fn hTruncate(p: *anyopaque, size: u64) FsError!void {
        return self_(p).truncate(size);
    }
    fn hClose(p: *anyopaque) void {
        self_(p).close();
    }
};

const WriteHandle = struct {
    gpa: std.mem.Allocator,
    map: *EnvMap,
    name: []u8,
    buf: std.ArrayList(u8) = .empty,

    fn fileHandle(self: *WriteHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(_: *WriteHandle, _: []u8) FsError!usize {
        return 0;
    }
    fn write(self: *WriteHandle, bytes: []const u8) FsError!usize {
        self.buf.appendSlice(self.gpa, bytes) catch @panic("OOM");
        return bytes.len;
    }
    fn seek(_: *WriteHandle, _: SeekFrom) FsError!u64 {
        return FsError.NotImplemented;
    }
    fn stat(self: *WriteHandle) FsError!Metadata {
        return Metadata.file(self.buf.items.len);
    }
    fn truncate(self: *WriteHandle, size: u64) FsError!void {
        self.buf.resize(self.gpa, @intCast(size)) catch @panic("OOM");
    }
    fn close(self: *WriteHandle) void {
        var end = self.buf.items.len;
        if (end != 0 and self.buf.items[end - 1] == '\n') end -= 1;
        if (end != 0 and self.buf.items[end - 1] == '\r') end -= 1;
        const value = self.gpa.dupe(u8, self.buf.items[0..end]) catch @panic("OOM");
        if (self.map.fetchRemove(self.name)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
        }
        self.map.put(self.gpa, self.name, value) catch @panic("OOM");
        self.buf.deinit(self.gpa);
        self.gpa.destroy(self);
    }
    const vtable = FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
        .close = hClose,
    };
    fn self_(p: *anyopaque) *WriteHandle {
        return @ptrCast(@alignCast(p));
    }
    fn hRead(p: *anyopaque, out: []u8) FsError!usize {
        return self_(p).read(out);
    }
    fn hWrite(p: *anyopaque, bytes: []const u8) FsError!usize {
        return self_(p).write(bytes);
    }
    fn hSeek(p: *anyopaque, pos: SeekFrom) FsError!u64 {
        return self_(p).seek(pos);
    }
    fn hStat(p: *anyopaque) FsError!Metadata {
        return self_(p).stat();
    }
    fn hTruncate(p: *anyopaque, size: u64) FsError!void {
        return self_(p).truncate(size);
    }
    fn hClose(p: *anyopaque) void {
        self_(p).close();
    }
};
