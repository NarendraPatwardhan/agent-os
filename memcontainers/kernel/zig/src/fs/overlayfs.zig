//! src/fs/overlayfs.zig — overlay composition of a writable layer over read-only lowers (§2.5).
//!
//! Owns: the lower/upper stack view and lookup precedence that cowfs writes into.
//! Invariants: A7, A9.
//! Oracle (behavior to match): kernel/rust/src/fs/overlayfs.rs.
//! Not here: copy-up mechanics (cowfs.zig); mount policy (vfs.zig).

const std = @import("std");
const TarFs = @import("tarfs.zig").TarFs;
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;

pub const OverlayFs = struct {
    gpa: std.mem.Allocator,
    layers: []const *TarFs,

    pub fn create(gpa: std.mem.Allocator, layers: []const *TarFs) *OverlayFs {
        const self = gpa.create(OverlayFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .layers = gpa.dupe(*TarFs, layers) catch @panic("OOM") };
        return self;
    }

    pub fn fileSystem(self: *OverlayFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn provider(self: *OverlayFs, path: []const u8) ?usize {
        var i = self.layers.len;
        while (i > 0) {
            i -= 1;
            if (self.layers[i].fileSystem().stat(path)) |_| return i else |_| {}
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const a = scratch.allocator();
            const prefixes = whiteoutPrefixes(a, path);
            for (prefixes) |wh| {
                if (self.layers[i].fileSystem().stat(wh)) |_| return null else |_| {}
            }
        }
        return null;
    }

    fn open(self: *OverlayFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        if (flags.write or flags.create or flags.truncate or flags.append) return FsError.PermissionDenied;
        const i = self.provider(path) orelse return FsError.NotFound;
        return self.layers[i].fileSystem().open(caller, path, flags);
    }

    fn stat(self: *OverlayFs, path: []const u8) FsError!Metadata {
        const i = self.provider(path) orelse return FsError.NotFound;
        return self.layers[i].fileSystem().stat(path);
    }

    fn readdir(self: *OverlayFs, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        if (self.provider(path) == null) return FsError.NotFound;
        var merged: std.StringHashMapUnmanaged(vfs.DirEntry) = .{};
        for (self.layers) |layer| {
            var entries: std.ArrayList(vfs.DirEntry) = .empty;
            layer.fileSystem().readdir(caller, path, arena, &entries) catch continue;
            for (entries.items) |entry| {
                if (std.mem.startsWith(u8, entry.name, ".wh.")) {
                    const name = entry.name[".wh.".len..];
                    if (merged.fetchRemove(name)) |kv| {
                        _ = kv;
                    }
                } else {
                    const owned = arena.dupe(u8, entry.name) catch @panic("OOM");
                    merged.put(arena, owned, .{ .name = owned, .node_type = entry.node_type }) catch @panic("OOM");
                }
            }
        }
        var it = merged.iterator();
        while (it.next()) |kv| out.append(arena, kv.value_ptr.*) catch @panic("OOM");
    }

    fn deny(_: *OverlayFs, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn denyRename(_: *OverlayFs, _: vfs.CallerId, _: []const u8, _: []const u8) FsError!void {
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
        .readlink = fsReadlink,
        .setMode = vfs.fsSetModeUnsupported,
        .setTimes = vfs.fsSetTimesUnsupported,
    };
    fn self_(p: *anyopaque) *OverlayFs {
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
        return self_(p).deny(caller, path);
    }
    fn fsUnlink(p: *anyopaque, caller: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).deny(caller, path);
    }
    fn fsRename(p: *anyopaque, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        return self_(p).denyRename(caller, from, to);
    }
    fn fsReadlink(p: *anyopaque, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        const self = self_(p);
        const i = self.provider(path) orelse return FsError.NotFound;
        return self.layers[i].fileSystem().readlink(path, out);
    }
};

fn whiteoutPrefixes(arena: std.mem.Allocator, path: []const u8) []const []const u8 {
    const trimmed = std.mem.trim(u8, path, "/");
    if (trimmed.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var parent: []const u8 = "";
    var it = std.mem.splitScalar(u8, trimmed, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue;
        if (parent.len == 0) {
            out.append(arena, std.fmt.allocPrint(arena, "/.wh.{s}", .{component}) catch @panic("OOM")) catch @panic("OOM");
            parent = std.fmt.allocPrint(arena, "/{s}", .{component}) catch @panic("OOM");
        } else {
            out.append(arena, std.fmt.allocPrint(arena, "{s}/.wh.{s}", .{ parent, component }) catch @panic("OOM")) catch @panic("OOM");
            parent = std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, component }) catch @panic("OOM");
        }
    }
    return out.items;
}
