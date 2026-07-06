//! src/fs/servicefs.zig — resident services projected under /svc (§2.5, §2.8).
//!
//! Owns: the read-only VFS face of the resident-service registry.
//! Oracle (behavior to match): kernel/rust/src/fs/servicefs.rs.
//! Not here: the registry/session lifecycle engine (service/registry.zig) — servicefs is its VFS face.

const std = @import("std");
const vfs = @import("../vfs.zig");
const state = @import("../state.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

pub const ServiceFs = struct {
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator) *ServiceFs {
        const self = gpa.create(ServiceFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa };
        return self;
    }

    pub fn fileSystem(self: *ServiceFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn name(path: []const u8) ?[]const u8 {
        const n = std.mem.trim(u8, path, "/");
        if (n.len == 0 or std.mem.indexOfScalar(u8, n, '/') != null) return null;
        return n;
    }

    fn open(self: *ServiceFs, _: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const n = name(path) orelse return FsError.IsDir;
        if (flags.write or flags.create or flags.truncate or flags.append) return FsError.PermissionDenied;
        const line = state.kernel().services.serviceStatusLine(self.gpa, n) orelse return FsError.NotFound;
        const h = self.gpa.create(StatusHandle) catch @panic("OOM");
        h.* = .{ .gpa = self.gpa, .data = line };
        return h.fileHandle();
    }

    fn stat(self: *ServiceFs, path: []const u8) FsError!Metadata {
        const n = name(path) orelse return Metadata.dir();
        const line = state.kernel().services.serviceStatusLine(self.gpa, n) orelse return FsError.NotFound;
        defer self.gpa.free(line);
        return Metadata.file(line.len);
    }

    fn readdir(_: *ServiceFs, _: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        if (name(path) != null or std.mem.trim(u8, path, "/").len != 0) return FsError.NotDir;
        var names: std.ArrayList([]const u8) = .empty;
        state.kernel().services.knownServiceNames(arena, &names);
        for (names.items) |n| out.append(arena, .{ .name = n, .node_type = .file }) catch @panic("OOM");
    }

    fn denyMkdir(_: *ServiceFs, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn denyUnlink(_: *ServiceFs, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn denyRename(_: *ServiceFs, _: vfs.CallerId, _: []const u8, _: []const u8) FsError!void {
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

    fn self_(p: *anyopaque) *ServiceFs {
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
        return self_(p).denyUnlink(caller, path);
    }
    fn fsRename(p: *anyopaque, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        return self_(p).denyRename(caller, from, to);
    }
};

const StatusHandle = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    pos: usize = 0,

    fn fileHandle(self: *StatusHandle) FileHandle {
        return .{ .ptr = self, .vtable = &handle_vtable };
    }

    fn read(self: *StatusHandle, out: []u8) FsError!usize {
        const start = @min(self.pos, self.data.len);
        const n = @min(out.len, self.data.len - start);
        if (n != 0) @memcpy(out[0..n], self.data[start .. start + n]);
        self.pos = start + n;
        return n;
    }
    fn write(_: *StatusHandle, _: []const u8) FsError!usize {
        return FsError.PermissionDenied;
    }
    fn seek(self: *StatusHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.pos)) + n,
            .end => |n| @as(i64, @intCast(self.data.len)) + n,
        };
        self.pos = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(self.data.len))));
        return @intCast(self.pos);
    }
    fn stat(self: *StatusHandle) FsError!Metadata {
        return Metadata.file(self.data.len);
    }
    fn truncate(_: *StatusHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }
    fn close(self: *StatusHandle) void {
        const gpa = self.gpa;
        gpa.free(self.data);
        gpa.destroy(self);
    }

    const handle_vtable = FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
        .close = hClose,
    };
    fn self_(p: *anyopaque) *StatusHandle {
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
