//! src/fs/memfs.zig — mutable in-memory filesystem, inode + hard-link-count model (§2.5).
//!
//! Names and nodes are many-to-one: `paths` maps a path to an inode number, `inodes` maps
//! that number to the node payload + hard-link count. A hard link adds a path and bumps
//! nlink; the inode frees at zero. Symlinks are inodes holding target text — never followed
//! here (that is the namespace's job); every method has lstat semantics.
//! Oracle: kernel/rust/src/fs/memfs.rs. Not here: mount/path policy (vfs.zig).

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
const ROOT_INO: u64 = 1;

const InodeData = union(enum) {
    file: std.ArrayList(u8),
    dir: std.StringHashMapUnmanaged(void),
    symlink: []u8,
};

const Inode = struct {
    data: InodeData,
    nlink: u32,
    mode: u16,
    mtime: i64,
    atime: i64,
    ctime: i64,
};

pub const MemFs = struct {
    gpa: std.mem.Allocator,
    inodes: std.AutoHashMapUnmanaged(u64, Inode) = .{},
    paths: std.StringHashMapUnmanaged(u64) = .{},
    next_ino: u64 = ROOT_INO + 1,

    pub fn create(gpa: std.mem.Allocator) *MemFs {
        const self = gpa.create(MemFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa };
        const now = vfs.wallNowMs();
        self.inodes.put(gpa, ROOT_INO, .{
            .data = .{ .dir = .{} },
            .nlink = 2,
            .mode = vfs.MODE_DIR_DEFAULT,
            .mtime = now,
            .atime = now,
            .ctime = now,
        }) catch @panic("OOM");
        self.paths.put(gpa, gpa.dupe(u8, "/") catch @panic("OOM"), ROOT_INO) catch @panic("OOM");
        return self;
    }

    pub fn fileSystem(self: *MemFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    // ── path helpers ────────────────────────────────────────────────────────────────────
    fn norm(path: []const u8, buf: []u8) ?[]const u8 {
        const s = if (path.len == 0 or std.mem.eql(u8, path, ".")) "/" else path;
        if (std.mem.startsWith(u8, s, "/")) {
            return s;
        }
        if (s.len + 1 > buf.len) return null;
        buf[0] = '/';
        @memcpy(buf[1 .. 1 + s.len], s);
        return buf[0 .. 1 + s.len];
    }

    fn inoOf(self: *MemFs, path: []const u8) ?u64 {
        return self.paths.get(path);
    }
    fn node(self: *MemFs, path: []const u8) ?*Inode {
        const ino = self.inoOf(path) orelse return null;
        return self.inodes.getPtr(ino);
    }
    fn allocIno(self: *MemFs) u64 {
        const ino = self.next_ino;
        self.next_ino += 1;
        return ino;
    }

    fn ensureDirExists(self: *MemFs, path: []const u8) FsError!void {
        const n = self.node(path) orelse return FsError.NotFound;
        if (n.data != .dir) return FsError.NotDir;
    }

    fn addChild(self: *MemFs, parent: []const u8, name: []const u8) void {
        const n = self.node(parent) orelse return;
        if (n.data == .dir) {
            if (!n.data.dir.contains(name)) {
                n.data.dir.put(self.gpa, self.gpa.dupe(u8, name) catch @panic("OOM"), {}) catch @panic("OOM");
            }
        }
    }
    fn removeChild(self: *MemFs, parent: []const u8, name: []const u8) void {
        const n = self.node(parent) orelse return;
        if (n.data == .dir) {
            if (n.data.dir.fetchRemove(name)) |kv| self.gpa.free(kv.key);
        }
    }

    /// Detach `path` from its inode; free the inode (+ bytes) at the last hard link.
    fn dropPath(self: *MemFs, path: []const u8) void {
        const kv = self.paths.fetchRemove(path) orelse return;
        self.gpa.free(kv.key);
        const inode = self.inodes.getPtr(kv.value) orelse return;
        const free = switch (inode.data) {
            .dir => true,
            else => blk: {
                inode.nlink -|= 1;
                break :blk inode.nlink == 0;
            },
        };
        if (free) {
            self.freeInodeData(inode);
            _ = self.inodes.remove(kv.value);
        }
    }

    fn freeInodeData(self: *MemFs, inode: *Inode) void {
        switch (inode.data) {
            .file => |*f| f.deinit(self.gpa),
            .symlink => |t| self.gpa.free(t),
            .dir => |*d| {
                var it = d.keyIterator();
                while (it.next()) |k| self.gpa.free(k.*);
                d.deinit(self.gpa);
            },
        }
    }

    /// 2 + immediate-subdirectory count (POSIX st_nlink for a dir).
    fn dirNlink(self: *MemFs, parent: []const u8, entries: *std.StringHashMapUnmanaged(void)) u32 {
        var subdirs: u32 = 0;
        var it = entries.keyIterator();
        var buf: [MAX_PATH]u8 = undefined;
        while (it.next()) |name| {
            const child = joinInto(&buf, parent, name.*) orelse continue;
            if (self.node(child)) |cn| {
                if (cn.data == .dir) subdirs += 1;
            }
        }
        return 2 + subdirs;
    }

    fn metaOf(self: *MemFs, path: []const u8, inode: *Inode) Metadata {
        const base = switch (inode.data) {
            .file => |f| Metadata.fileWithNlink(f.items.len, inode.nlink),
            .dir => |*d| Metadata.dirWithNlink(self.dirNlink(path, d)),
            .symlink => |t| Metadata.symlinkWithNlink(t.len, inode.nlink),
        };
        return base.withMode(inode.mode).withTimes(inode.atime, inode.mtime, inode.ctime);
    }

    // ── FileSystem impl ───────────────────────────────────────────────────────────────────
    pub fn open(self: *MemFs, path_in: []const u8, flags: OpenFlags) FsError!FileHandle {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        if (self.inoOf(path)) |ino| {
            switch (self.inodes.getPtr(ino).?.data) {
                .dir => return FsError.IsDir,
                .symlink => return FsError.InvalidPath,
                .file => {},
            }
            if (flags.truncate) {
                const inode = self.inodes.getPtr(ino).?;
                inode.data.file.clearRetainingCapacity();
                const now = vfs.wallNowMs();
                inode.mtime = now;
                inode.ctime = now;
            }
            const offset: u64 = if (flags.append) self.inodes.getPtr(ino).?.data.file.items.len else 0;
            return self.makeHandle(ino, offset, flags);
        }
        if (!flags.create) return FsError.NotFound;
        const parent = vfs.parentPath(path) orelse return FsError.NotFound;
        var pbuf: [MAX_PATH]u8 = undefined;
        const parent_owned = dupInto(&pbuf, parent);
        try self.ensureDirExists(parent_owned);
        var nmbuf: [MAX_PATH]u8 = undefined;
        const name = dupInto(&nmbuf, vfs.baseName(path));
        const ino = self.allocIno();
        const now = vfs.wallNowMs();
        self.inodes.put(self.gpa, ino, .{ .data = .{ .file = .empty }, .nlink = 1, .mode = vfs.MODE_FILE_DEFAULT, .mtime = now, .atime = now, .ctime = now }) catch @panic("OOM");
        self.paths.put(self.gpa, self.gpa.dupe(u8, path) catch @panic("OOM"), ino) catch @panic("OOM");
        self.addChild(parent_owned, name);
        return self.makeHandle(ino, 0, flags);
    }

    fn makeHandle(self: *MemFs, ino: u64, offset: u64, flags: OpenFlags) FileHandle {
        const h = self.gpa.create(MemFileHandle) catch @panic("OOM");
        h.* = .{ .fs = self, .ino = ino, .offset = offset, .append = flags.append, .noatime = flags.noatime };
        return .{ .ptr = h, .vtable = &MemFileHandle.handle_vtable };
    }

    fn stat(self: *MemFs, path_in: []const u8) FsError!Metadata {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        const inode = self.node(path) orelse return FsError.NotFound;
        return self.metaOf(path, inode);
    }

    pub fn readdir(self: *MemFs, path_in: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        const n = self.node(path) orelse return FsError.NotFound;
        if (n.data != .dir) return FsError.NotDir;
        var it = n.data.dir.keyIterator();
        var jb: [MAX_PATH]u8 = undefined;
        while (it.next()) |name| {
            const child = joinInto(&jb, path, name.*) orelse continue;
            const cn = self.node(child) orelse continue;
            const nt: NodeType = switch (cn.data) {
                .file => .file,
                .dir => .dir,
                .symlink => .symlink,
            };
            out.append(arena, .{ .name = arena.dupe(u8, name.*) catch @panic("OOM"), .node_type = nt }) catch @panic("OOM");
        }
    }

    pub fn mkdir(self: *MemFs, path_in: []const u8) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        if (self.paths.contains(path)) return FsError.AlreadyExists;
        const parent = vfs.parentPath(path) orelse return FsError.NotFound;
        var pbuf: [MAX_PATH]u8 = undefined;
        const parent_owned = dupInto(&pbuf, parent);
        try self.ensureDirExists(parent_owned);
        var nmbuf: [MAX_PATH]u8 = undefined;
        const name = dupInto(&nmbuf, vfs.baseName(path));
        const ino = self.allocIno();
        const now = vfs.wallNowMs();
        self.inodes.put(self.gpa, ino, .{ .data = .{ .dir = .{} }, .nlink = 2, .mode = vfs.MODE_DIR_DEFAULT, .mtime = now, .atime = now, .ctime = now }) catch @panic("OOM");
        self.paths.put(self.gpa, self.gpa.dupe(u8, path) catch @panic("OOM"), ino) catch @panic("OOM");
        self.addChild(parent_owned, name);
    }

    pub fn unlink(self: *MemFs, path_in: []const u8) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        const n = self.node(path) orelse return FsError.NotFound;
        if (n.data == .dir and n.data.dir.count() != 0) return FsError.NotEmpty;
        const parent = vfs.parentPath(path) orelse return FsError.NotFound;
        var name_buf: [MAX_PATH]u8 = undefined;
        const name = dupInto(&name_buf, vfs.baseName(path));
        var pbuf: [MAX_PATH]u8 = undefined;
        const parent_owned = dupInto(&pbuf, parent);
        self.removeChild(parent_owned, name);
        self.dropPath(path);
    }

    pub fn symlinkOp(self: *MemFs, target: []const u8, link_in: []const u8) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const link = norm(link_in, &nb) orelse return FsError.InvalidPath;
        if (self.paths.contains(link)) return FsError.AlreadyExists;
        const parent = vfs.parentPath(link) orelse return FsError.NotFound;
        var pbuf: [MAX_PATH]u8 = undefined;
        const parent_owned = dupInto(&pbuf, parent);
        try self.ensureDirExists(parent_owned);
        var nmbuf: [MAX_PATH]u8 = undefined;
        const name = dupInto(&nmbuf, vfs.baseName(link));
        const ino = self.allocIno();
        const now = vfs.wallNowMs();
        self.inodes.put(self.gpa, ino, .{ .data = .{ .symlink = self.gpa.dupe(u8, target) catch @panic("OOM") }, .nlink = 1, .mode = vfs.MODE_SYMLINK, .mtime = now, .atime = now, .ctime = now }) catch @panic("OOM");
        self.paths.put(self.gpa, self.gpa.dupe(u8, link) catch @panic("OOM"), ino) catch @panic("OOM");
        self.addChild(parent_owned, name);
    }

    pub fn readlink(self: *MemFs, path_in: []const u8, out: *std.ArrayList(u8)) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        const n = self.node(path) orelse return FsError.NotFound;
        switch (n.data) {
            .symlink => |t| out.appendSlice(self.gpa, t) catch @panic("OOM"),
            else => return FsError.InvalidPath,
        }
    }

    pub fn setMode(self: *MemFs, path_in: []const u8, mode: u16) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        const n = self.node(path) orelse return FsError.NotFound;
        n.mode = mode & 0o7777;
        n.ctime = vfs.wallNowMs();
    }

    pub fn setTimes(self: *MemFs, path_in: []const u8, atime: i64, mtime: i64) FsError!void {
        var nb: [MAX_PATH]u8 = undefined;
        const path = norm(path_in, &nb) orelse return FsError.InvalidPath;
        const n = self.node(path) orelse return FsError.NotFound;
        n.atime = atime;
        n.mtime = mtime;
        n.ctime = vfs.wallNowMs();
    }

    // ── vtable trampolines ────────────────────────────────────────────────────────────────
    const fs_vtable = FileSystem.VTable{
        .open = fsOpen,
        .stat = fsStat,
        .readdir = fsReaddir,
        .mkdir = fsMkdir,
        .unlink = fsUnlink,
        .rename = vfs.fsRenameUnsupported, // full rename lands with the shell (Phase 4)
        .symlink = fsSymlink,
        .readlink = fsReadlink,
        .setMode = fsSetMode,
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
    fn fsMkdir(p: *anyopaque, _: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).mkdir(path);
    }
    fn fsUnlink(p: *anyopaque, _: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).unlink(path);
    }
    fn fsSymlink(p: *anyopaque, target: []const u8, link: []const u8) FsError!void {
        return self_(p).symlinkOp(target, link);
    }
    fn fsReadlink(p: *anyopaque, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        return self_(p).readlink(path, out);
    }
    fn fsSetMode(p: *anyopaque, path: []const u8, mode: u16) FsError!void {
        return self_(p).setMode(path, mode);
    }
    fn self_(p: *anyopaque) *MemFs {
        return @ptrCast(@alignCast(p));
    }
};

const MemFileHandle = struct {
    fs: *MemFs,
    ino: u64,
    offset: u64,
    append: bool,
    noatime: bool,

    fn read(self: *MemFileHandle, buf: []u8) FsError!usize {
        const offset: usize = @intCast(self.offset);
        const inode = self.fs.inodes.getPtr(self.ino) orelse return FsError.NotFound;
        const to_read: usize = switch (inode.data) {
            .file => |*f| blk: {
                if (offset >= f.items.len) break :blk 0;
                const end = @min(offset + buf.len, f.items.len);
                const n = end - offset;
                @memcpy(buf[0..n], f.items[offset..end]);
                break :blk n;
            },
            .dir => return FsError.IsDir,
            .symlink => return FsError.InvalidPath,
        };
        self.offset += to_read;
        if (to_read > 0 and !self.noatime) {
            const now = vfs.wallNowMs();
            if (inode.atime <= inode.mtime or inode.atime <= inode.ctime or now - inode.atime >= 86_400_000) {
                inode.atime = now;
            }
        }
        return to_read;
    }

    fn write(self: *MemFileHandle, buf: []const u8) FsError!usize {
        const inode = self.fs.inodes.getPtr(self.ino) orelse return FsError.NotFound;
        switch (inode.data) {
            .file => |*f| {
                if (self.append) {
                    f.appendSlice(self.fs.gpa, buf) catch @panic("OOM");
                    self.offset = f.items.len;
                } else {
                    const start: usize = @intCast(self.offset);
                    const end = start + buf.len;
                    if (end > f.items.len) {
                        const old = f.items.len;
                        f.resize(self.fs.gpa, end) catch @panic("OOM");
                        @memset(f.items[old..end], 0);
                    }
                    @memcpy(f.items[start..end], buf);
                    self.offset = end;
                }
            },
            .dir => return FsError.IsDir,
            .symlink => return FsError.InvalidPath,
        }
        const now = vfs.wallNowMs();
        inode.mtime = now;
        inode.ctime = now;
        return buf.len;
    }

    fn seek(self: *MemFileHandle, pos: SeekFrom) FsError!u64 {
        const inode = self.fs.inodes.getPtr(self.ino) orelse return FsError.NotFound;
        const size: i64 = switch (inode.data) {
            .file => |f| @intCast(f.items.len),
            .dir => 0,
            .symlink => |t| @intCast(t.len),
        };
        const new_off: i64 = switch (pos) {
            .start => |n| @intCast(n),
            .current => |n| @as(i64, @intCast(self.offset)) + n,
            .end => |n| size + n,
        };
        if (new_off < 0) return FsError.InvalidPath;
        self.offset = @intCast(new_off);
        return self.offset;
    }

    fn stat(self: *MemFileHandle) FsError!Metadata {
        const inode = self.fs.inodes.getPtr(self.ino) orelse return FsError.NotFound;
        const base = switch (inode.data) {
            .file => |f| Metadata.fileWithNlink(f.items.len, inode.nlink),
            .dir => Metadata.dir(),
            .symlink => |t| Metadata.symlinkWithNlink(t.len, inode.nlink),
        };
        return base.withMode(inode.mode).withTimes(inode.atime, inode.mtime, inode.ctime);
    }

    fn truncate(self: *MemFileHandle, size: u64) FsError!void {
        const inode = self.fs.inodes.getPtr(self.ino) orelse return FsError.NotFound;
        switch (inode.data) {
            .file => |*f| {
                const old = f.items.len;
                f.resize(self.fs.gpa, @intCast(size)) catch @panic("OOM");
                if (size > old) @memset(f.items[old..], 0);
            },
            .dir => return FsError.IsDir,
            .symlink => return FsError.InvalidPath,
        }
        const now = vfs.wallNowMs();
        inode.mtime = now;
        inode.ctime = now;
    }

    const handle_vtable = FileHandle.VTable{
        .read = hRead,
        .write = hWrite,
        .seek = hSeek,
        .stat = hStat,
        .truncate = hTruncate,
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
    fn hTruncate(p: *anyopaque, size: u64) FsError!void {
        return h_(p).truncate(size);
    }
    fn hClose(p: *anyopaque) void {
        const self = h_(p);
        self.fs.gpa.destroy(self);
    }
    fn h_(p: *anyopaque) *MemFileHandle {
        return @ptrCast(@alignCast(p));
    }
};

/// Join `dir`/`name` into `buf`; null if it would overflow.
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
