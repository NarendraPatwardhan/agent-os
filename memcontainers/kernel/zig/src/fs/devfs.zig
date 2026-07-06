//! src/fs/devfs.zig — device files: /dev/null, /dev/zero, /dev/random, /dev/cons (§2.5).
//!
//! Owns: the device nodes and their read/write behavior; entropy and console output flow
//! through the bridge (A5). Oracle: kernel/rust/src/fs/devfs.rs.
//! Not here: the line editor (scheduler.zig); pipes (ipc/pipe.zig).

const std = @import("std");
const vfs = @import("../vfs.zig");
const bridge = @import("../bridge.zig");
const FsError = vfs.FsError;
const NodeType = vfs.NodeType;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const DirEntry = vfs.DirEntry;

const DevType = enum { null_, zero, random, cons };

const DEVICES = [_]struct { name: []const u8, dev: DevType }{
    .{ .name = "null", .dev = .null_ },
    .{ .name = "zero", .dev = .zero },
    .{ .name = "random", .dev = .random },
    .{ .name = "cons", .dev = .cons },
};

pub const DevFs = struct {
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator) *DevFs {
        const self = gpa.create(DevFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa };
        return self;
    }
    pub fn fileSystem(self: *DevFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    /// Handle both /dev/X and /X (the namespace hands us the mount-relative path).
    fn getDevice(path: []const u8) ?DevType {
        const clean = if (std.mem.startsWith(u8, path, "/dev")) path[4..] else path;
        const name = if (std.mem.startsWith(u8, clean, "/")) clean[1..] else clean;
        for (DEVICES) |d| {
            if (std.mem.eql(u8, d.name, name)) return d.dev;
        }
        return null;
    }

    fn open(self: *DevFs, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const dev = getDevice(path) orelse return FsError.NotFound;
        if (flags.write) switch (dev) {
            .zero, .random => return FsError.PermissionDenied,
            .null_, .cons => {},
        };
        const h = self.gpa.create(DevFileHandle) catch @panic("OOM");
        h.* = .{ .fs = self, .dev = dev, .offset = 0 };
        return .{ .ptr = h, .vtable = &DevFileHandle.handle_vtable };
    }

    fn stat(_: *DevFs, path: []const u8) FsError!Metadata {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/dev")) return Metadata.dir();
        _ = getDevice(path) orelse return FsError.NotFound;
        return Metadata.file(0);
    }

    fn readdir(_: *DevFs, _: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void {
        for (DEVICES) |d| {
            out.append(arena, .{ .name = arena.dupe(u8, d.name) catch @panic("OOM"), .node_type = .file }) catch @panic("OOM");
        }
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
        .readlink = vfs.fsReadlinkUnsupported,
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
    fn self_(p: *anyopaque) *DevFs {
        return @ptrCast(@alignCast(p));
    }
};

const DevFileHandle = struct {
    fs: *DevFs,
    dev: DevType,
    offset: u64,

    fn read(self: *DevFileHandle, buf: []u8) FsError!usize {
        switch (self.dev) {
            .null_, .cons => return 0,
            .zero => {
                @memset(buf, 0);
                self.offset += buf.len;
                return buf.len;
            },
            .random => {
                bridge.mc_random(buf.ptr, buf.len);
                self.offset += buf.len;
                return buf.len;
            },
        }
    }
    fn write(self: *DevFileHandle, buf: []const u8) FsError!usize {
        switch (self.dev) {
            .null_ => return buf.len,
            .cons => {
                bridge.mc_stdout_write(buf.ptr, buf.len);
                return buf.len;
            },
            .zero, .random => return FsError.PermissionDenied,
        }
    }
    fn seek(self: *DevFileHandle, pos: SeekFrom) FsError!u64 {
        const new_off: i64 = switch (pos) {
            .start => |n| @intCast(n),
            .current => |n| @as(i64, @intCast(self.offset)) + n,
            .end => |n| if (n < 0) 0 else n,
        };
        if (new_off < 0) return FsError.InvalidPath;
        self.offset = @intCast(new_off);
        return self.offset;
    }
    fn stat(_: *DevFileHandle) FsError!Metadata {
        return Metadata.file(0);
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
    fn h_(p: *anyopaque) *DevFileHandle {
        return @ptrCast(@alignCast(p));
    }
};
