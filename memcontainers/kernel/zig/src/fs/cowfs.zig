//! src/fs/cowfs.zig — writable copy-on-write layer over a read-only base (§2.5).
//!
//! Reads check the overlay first, then the base (unless tombstoned). Writes always land in
//! the overlay (copy-up materializes a base file/dir first). Deletes add a tombstone.
//! Oracle: kernel/rust/src/fs/cowfs.rs. commit_layer (the tar-serialize `commit` primitive)
//! needs a TarWriter and is not on the control-VFS path — deferred (mc_commit_layer is a
//! separate export, Phase 6). Not here: overlay composition (overlayfs.zig).

const std = @import("std");
const vfs = @import("../vfs.zig");
const MemFs = @import("memfs.zig").MemFs;
const FsError = vfs.FsError;
const NodeType = vfs.NodeType;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const DirEntry = vfs.DirEntry;
const SYSTEM_CALLER = vfs.SYSTEM_CALLER;

const MAX_PATH = 4096;

pub const CowFs = struct {
    gpa: std.mem.Allocator,
    base: FileSystem,
    overlay: *MemFs,
    tombstones: std.StringHashMapUnmanaged(void) = .{},

    pub fn create(gpa: std.mem.Allocator, base: FileSystem) *CowFs {
        const self = gpa.create(CowFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .base = base, .overlay = MemFs.create(gpa) };
        return self;
    }
    pub fn fileSystem(self: *CowFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }
    fn ov(self: *CowFs) FileSystem {
        return self.overlay.fileSystem();
    }

    fn isTombstoned(self: *CowFs, path: []const u8) bool {
        return self.tombstones.contains(path);
    }
    fn addTombstone(self: *CowFs, path: []const u8) void {
        if (!self.tombstones.contains(path)) {
            self.tombstones.put(self.gpa, self.gpa.dupe(u8, path) catch @panic("OOM"), {}) catch @panic("OOM");
        }
    }
    fn removeTombstone(self: *CowFs, path: []const u8) void {
        if (self.tombstones.fetchRemove(path)) |kv| self.gpa.free(kv.key);
    }

    fn exists(self: *CowFs, path: []const u8) bool {
        if (self.isTombstoned(path)) return false;
        if (self.ov().stat(path)) |_| return true else |_| {}
        if (self.base.stat(path)) |_| return true else |_| {}
        return false;
    }

    /// Mirror every ancestor directory of `path` into the overlay so a subsequent overlay
    /// CREATE does not fail on the parent (the base image may have a chain the overlay lacks).
    fn ensureOverlayParents(self: *CowFs, path: []const u8) FsError!void {
        if (std.mem.eql(u8, path, "/") or path.len == 0) return;
        const parent = vfs.parentPath(path) orelse return;
        var pbuf: [MAX_PATH]u8 = undefined;
        const parent_owned = dupInto(&pbuf, parent);
        try self.ensureOverlayParents(parent_owned);
        if (self.ov().stat(parent_owned)) |_| {} else |_| {
            try self.overlay.mkdir(parent_owned);
            if (self.base.stat(parent_owned)) |meta| {
                self.overlay.setMode(parent_owned, meta.mode) catch {};
                self.overlay.setTimes(parent_owned, meta.atime, meta.mtime) catch {};
            } else |_| {}
        }
    }

    // ── FileSystem impl ───────────────────────────────────────────────────────────────────
    fn open(self: *CowFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        if (self.isTombstoned(path)) {
            if (flags.create) {
                self.removeTombstone(path);
                return self.overlay.open(path, flags);
            }
            return FsError.NotFound;
        }
        if (self.ov().stat(path)) |_| {
            return self.overlay.open(path, flags);
        } else |_| {}

        if (self.base.stat(path)) |meta| {
            if (flags.write or flags.truncate) {
                if (meta.node_type == .file) {
                    try self.ensureOverlayParents(path);
                    var bh = try self.base.open(caller, path, OpenFlags.READ);
                    defer bh.close();
                    var oh = try self.overlay.open(path, OpenFlags.CREATE);
                    var buf: [4096]u8 = undefined;
                    while (true) {
                        const n = try bh.read(&buf);
                        if (n == 0) break;
                        _ = try oh.write(buf[0..n]);
                    }
                    oh.close();
                    self.overlay.setMode(path, meta.mode) catch {};
                    self.overlay.setTimes(path, meta.atime, meta.mtime) catch {};
                    return self.overlay.open(path, flags);
                }
                return self.overlay.open(path, flags);
            }
            // Read-only access to the base (base handles refuse writes intrinsically).
            return self.base.open(caller, path, flags);
        } else |_| {
            if (flags.create) {
                try self.ensureOverlayParents(path);
                return self.overlay.open(path, flags);
            }
            return FsError.NotFound;
        }
    }

    fn stat(self: *CowFs, path: []const u8) FsError!Metadata {
        if (self.isTombstoned(path)) return FsError.NotFound;
        if (self.ov().stat(path)) |meta| return meta else |_| {}
        return self.base.stat(path);
    }

    fn readdir(self: *CowFs, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void {
        if (self.isTombstoned(path)) return FsError.NotFound;
        var base_entries: std.ArrayList(DirEntry) = .empty;
        const base_ok = if (self.base.readdir(caller, path, arena, &base_entries)) |_| true else |_| false;
        var overlay_entries: std.ArrayList(DirEntry) = .empty;
        const overlay_ok = if (self.overlay.readdir(path, arena, &overlay_entries)) |_| true else |_| false;
        if (!base_ok and !overlay_ok) return FsError.NotFound;

        var merged: std.StringHashMapUnmanaged(DirEntry) = .{};
        for (base_entries.items) |e| {
            const full = vfs.joinPath(arena, path, e.name);
            if (!self.isTombstoned(full)) merged.put(arena, e.name, e) catch @panic("OOM");
        }
        for (overlay_entries.items) |e| {
            merged.put(arena, e.name, e) catch @panic("OOM");
        }
        var it = merged.valueIterator();
        while (it.next()) |v| out.append(arena, v.*) catch @panic("OOM");
    }

    fn mkdir(self: *CowFs, path: []const u8) FsError!void {
        if (self.isTombstoned(path)) {
            self.removeTombstone(path);
        } else if (self.exists(path)) {
            return FsError.AlreadyExists;
        }
        try self.ensureOverlayParents(path);
        return self.overlay.mkdir(path);
    }

    fn unlink(self: *CowFs, path: []const u8) FsError!void {
        if (!self.exists(path)) return FsError.NotFound;
        if (self.ov().stat(path)) |_| {
            try self.overlay.unlink(path);
        } else |_| {}
        self.addTombstone(path);
    }

    fn symlink(self: *CowFs, target: []const u8, link: []const u8) FsError!void {
        if (self.isTombstoned(link)) {
            self.removeTombstone(link);
        } else if (self.exists(link)) {
            return FsError.AlreadyExists;
        }
        try self.ensureOverlayParents(link);
        return self.overlay.symlinkOp(target, link);
    }

    fn readlink(self: *CowFs, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        if (self.isTombstoned(path)) return FsError.NotFound;
        if (self.ov().stat(path)) |_| return self.overlay.readlink(path, out) else |_| {}
        return self.base.readlink(path, out);
    }

    fn setMode(self: *CowFs, path: []const u8, mode: u16) FsError!void {
        if (self.isTombstoned(path)) return FsError.NotFound;
        try self.copyUp(path);
        return self.overlay.setMode(path, mode);
    }

    /// Materialize `path` (file / dir subtree / symlink) into the overlay, copying base
    /// content up. No-op for parts already present in the overlay.
    fn copyUp(self: *CowFs, path: []const u8) FsError!void {
        const meta = try self.stat(path);
        try self.ensureOverlayParents(path);
        switch (meta.node_type) {
            .file => {
                if (self.ov().stat(path)) |_| return else |_| {}
                var bh = try self.base.open(SYSTEM_CALLER, path, OpenFlags.READ);
                defer bh.close();
                var oh = try self.overlay.open(path, OpenFlags.CREATE);
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = try bh.read(&buf);
                    if (n == 0) break;
                    _ = try oh.write(buf[0..n]);
                }
                oh.close();
                self.overlay.setMode(path, meta.mode) catch {};
                self.overlay.setTimes(path, meta.atime, meta.mtime) catch {};
            },
            .dir => {
                if (self.ov().stat(path)) |_| {} else |_| {
                    try self.overlay.mkdir(path);
                    self.overlay.setMode(path, meta.mode) catch {};
                    self.overlay.setTimes(path, meta.atime, meta.mtime) catch {};
                }
                var scratch = std.heap.ArenaAllocator.init(self.gpa);
                defer scratch.deinit();
                var entries: std.ArrayList(DirEntry) = .empty;
                try self.readdir(SYSTEM_CALLER, path, scratch.allocator(), &entries);
                for (entries.items) |e| {
                    var cbuf: [MAX_PATH]u8 = undefined;
                    const child = joinInto(&cbuf, path, e.name) orelse continue;
                    try self.copyUp(child);
                }
            },
            .symlink => {
                if (self.ov().stat(path)) |_| return else |_| {}
                var tgt: std.ArrayList(u8) = .empty;
                defer tgt.deinit(self.gpa);
                try self.base.readlink(path, &tgt);
                try self.overlay.symlinkOp(tgt.items, path);
                self.overlay.setTimes(path, meta.atime, meta.mtime) catch {};
            },
        }
    }

    const fs_vtable = FileSystem.VTable{
        .open = fsOpen,
        .stat = fsStat,
        .readdir = fsReaddir,
        .mkdir = fsMkdir,
        .unlink = fsUnlink,
        .rename = vfs.fsRenameUnsupported,
        .symlink = fsSymlink,
        .readlink = fsReadlink,
        .setMode = fsSetMode,
    };
    fn fsOpen(p: *anyopaque, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        return self_(p).open(caller, path, flags);
    }
    fn fsStat(p: *anyopaque, path: []const u8) FsError!Metadata {
        return self_(p).stat(path);
    }
    fn fsReaddir(p: *anyopaque, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void {
        return self_(p).readdir(caller, path, arena, out);
    }
    fn fsMkdir(p: *anyopaque, _: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).mkdir(path);
    }
    fn fsUnlink(p: *anyopaque, _: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).unlink(path);
    }
    fn fsSymlink(p: *anyopaque, target: []const u8, link: []const u8) FsError!void {
        return self_(p).symlink(target, link);
    }
    fn fsReadlink(p: *anyopaque, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        return self_(p).readlink(path, out);
    }
    fn fsSetMode(p: *anyopaque, path: []const u8, mode: u16) FsError!void {
        return self_(p).setMode(path, mode);
    }
    fn self_(p: *anyopaque) *CowFs {
        return @ptrCast(@alignCast(p));
    }
};

fn joinInto(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    const sep: usize = if (std.mem.endsWith(u8, dir, "/")) 0 else 1;
    const total = dir.len + sep + name.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    if (sep == 1) buf[dir.len] = '/';
    @memcpy(buf[dir.len + sep ..][0..name.len], name);
    return buf[0..total];
}

fn dupInto(buf: []u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}
