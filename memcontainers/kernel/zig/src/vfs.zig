//! vfs.zig — the per-task namespace and mount resolution (ZIG_KERNEL §2.4, §4.1).
//!
//! Owns: the shared VFS vocabulary (FsError, NodeType, Metadata, OpenFlags, SeekFrom), the
//!   FileSystem / FileHandle interfaces every backend implements, path helpers, and the
//!   Namespace — the mount table, longest-prefix resolution, the ONE symlink-following
//!   canonicalizer (`..` collapse, fixed hop limit, per-component search perms), and
//!   open/read/stat/readdir dispatch to the owning backend.
//! Invariants: A7 (deterministic dir iteration — readdir output is sorted), A9 (denials are
//!   errno via FsError, never traps); §4.3 error discipline. Matches kernel/rust/src/vfs/*.
//! Not here: backend IMPLEMENTATIONS (fs/*.zig); the control scratch protocol (control.zig);
//!   base-image tar seeding (boot.zig). This file is dispatch + policy only.

const std = @import("std");
const constants = @import("constants_zig");
const state = @import("state.zig");

/// Cached wall clock in ms since the epoch — the kernel refreshes it from the clock bridge
/// each tick (mirrors the Rust kernel's cached WALL_CLOCK static). Backends stamp node times
/// from it without each taking a clock dependency. `0` until the clock is wired (Phase 4).
/// The kernel's cached wall-clock (ms), owned by `Kernel.wall_ms` and refreshed each tick. Read from
/// the many low-level sites (memfs timestamps, service deadlines) through this accessor so none of
/// them needs a Kernel handle. Returns 0 before the kernel is initialized.
pub fn wallNowMs() i64 {
    return if (state.isInitialized()) state.kernel().wall_ms else 0;
}

pub const CallerId = u32;
/// Boot-time / internal opens that act on no task's behalf.
pub const SYSTEM_CALLER: CallerId = 0;
/// The agent owns the root namespace (pid 1).
pub const AGENT_OWNER: CallerId = 1;

/// POSIX SYMLOOP_MAX: the most symlinks one resolution may traverse before ELOOP.
const SYMLOOP_MAX: usize = 40;

pub const MODE_FILE_DEFAULT: u16 = 0o644;
pub const MODE_DIR_DEFAULT: u16 = 0o755;
pub const MODE_SYMLINK: u16 = 0o777;

/// The whole VFS error vocabulary (mirrors Rust `FsError`). Allocation failure is fatal in
/// this freestanding kernel (like Rust's talc abort), so it never appears here.
pub const FsError = error{
    NotFound,
    AlreadyExists,
    NotDir,
    IsDir,
    /// A capability/mount/identity denial — maps to EPERM.
    PermissionDenied,
    /// A file-mode bit check failed (owner r/w/x) — maps to EACCES.
    AccessDenied,
    InvalidPath,
    NotEmpty,
    IoError,
    BadFileDescriptor,
    NotImplemented,
    CrossDevice,
    WouldBlock,
    MessageTooBig,
    /// Symlink-following depth exceeded — ELOOP. Produced only by the canonicalizer.
    Loop,
};

pub const NodeType = enum { file, dir, symlink };

pub const Metadata = struct {
    node_type: NodeType,
    size: u64,
    nlink: u32,
    mode: u16,
    mtime: i64,
    atime: i64,
    ctime: i64,

    pub fn file(size: u64) Metadata {
        return .{ .node_type = .file, .size = size, .nlink = 1, .mode = MODE_FILE_DEFAULT, .mtime = 0, .atime = 0, .ctime = 0 };
    }
    pub fn fileWithNlink(size: u64, nlink: u32) Metadata {
        var m = Metadata.file(size);
        m.nlink = nlink;
        return m;
    }
    pub fn dir() Metadata {
        return .{ .node_type = .dir, .size = 0, .nlink = 2, .mode = MODE_DIR_DEFAULT, .mtime = 0, .atime = 0, .ctime = 0 };
    }
    pub fn dirWithNlink(nlink: u32) Metadata {
        var m = Metadata.dir();
        m.nlink = nlink;
        return m;
    }
    pub fn symlink(target_len: u64) Metadata {
        return .{ .node_type = .symlink, .size = target_len, .nlink = 1, .mode = MODE_SYMLINK, .mtime = 0, .atime = 0, .ctime = 0 };
    }
    pub fn symlinkWithNlink(target_len: u64, nlink: u32) Metadata {
        var m = Metadata.symlink(target_len);
        m.nlink = nlink;
        return m;
    }
    pub fn withMode(self: Metadata, mode: u16) Metadata {
        var m = self;
        m.mode = mode;
        return m;
    }
    pub fn withTimes(self: Metadata, atime: i64, mtime: i64, ctime: i64) Metadata {
        var m = self;
        m.atime = atime;
        m.mtime = mtime;
        m.ctime = ctime;
        return m;
    }
    pub fn ownerReadable(self: Metadata) bool {
        return self.mode & 0o400 != 0;
    }
    pub fn ownerWritable(self: Metadata) bool {
        return self.mode & 0o200 != 0;
    }
    pub fn ownerExecutable(self: Metadata) bool {
        return self.mode & 0o100 != 0;
    }
};

pub const DirEntry = struct {
    /// Owned by the caller-provided arena/allocator; the Namespace dupes into `arena`.
    name: []const u8,
    node_type: NodeType,
};

pub const OpenFlags = struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    noatime: bool = false,

    pub const READ: OpenFlags = .{ .read = true };
    pub const WRITE: OpenFlags = .{ .write = true };
    pub const CREATE: OpenFlags = .{ .write = true, .create = true };
    pub const TRUNCATE: OpenFlags = .{ .write = true, .create = true, .truncate = true };
    pub const APPEND: OpenFlags = .{ .write = true, .create = true, .append = true };

    fn writes(self: OpenFlags) bool {
        return self.write or self.create or self.truncate or self.append;
    }
};

pub const SeekFrom = union(enum) { start: u64, current: i64, end: i64 };

// ── FileHandle interface (an open file) ────────────────────────────────────────────────
pub const FileHandle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (*anyopaque, buf: []u8) FsError!usize,
        write: *const fn (*anyopaque, buf: []const u8) FsError!usize,
        seek: *const fn (*anyopaque, pos: SeekFrom) FsError!u64,
        stat: *const fn (*anyopaque) FsError!Metadata,
        truncate: *const fn (*anyopaque, size: u64) FsError!void,
        close: *const fn (*anyopaque) void,
    };

    pub fn read(self: FileHandle, buf: []u8) FsError!usize {
        return self.vtable.read(self.ptr, buf);
    }
    pub fn write(self: FileHandle, buf: []const u8) FsError!usize {
        return self.vtable.write(self.ptr, buf);
    }
    pub fn seek(self: FileHandle, pos: SeekFrom) FsError!u64 {
        return self.vtable.seek(self.ptr, pos);
    }
    pub fn stat(self: FileHandle) FsError!Metadata {
        return self.vtable.stat(self.ptr);
    }
    pub fn truncate(self: FileHandle, size: u64) FsError!void {
        return self.vtable.truncate(self.ptr, size);
    }
    /// Release the handle's own allocation (the backing file/inode is untouched).
    pub fn close(self: FileHandle) void {
        self.vtable.close(self.ptr);
    }
};

/// Default `truncate` for read-only handles.
pub fn handleTruncateUnsupported(_: *anyopaque, _: u64) FsError!void {
    return FsError.NotImplemented;
}

// ── FileSystem interface (a mountable backend) ──────────────────────────────────────────
pub const FileSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open: *const fn (*anyopaque, caller: CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle,
        stat: *const fn (*anyopaque, path: []const u8) FsError!Metadata,
        /// Append DirEntry values (names duped into `arena`) for a directory listing.
        readdir: *const fn (*anyopaque, caller: CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void,
        mkdir: *const fn (*anyopaque, caller: CallerId, path: []const u8) FsError!void,
        unlink: *const fn (*anyopaque, caller: CallerId, path: []const u8) FsError!void,
        rename: *const fn (*anyopaque, caller: CallerId, from: []const u8, to: []const u8) FsError!void,
        symlink: *const fn (*anyopaque, target: []const u8, link: []const u8) FsError!void,
        link: *const fn (*anyopaque, existing: []const u8, new: []const u8) FsError!void,
        /// Write the link target into `out`; caller owns `out`.
        readlink: *const fn (*anyopaque, path: []const u8, out: *std.ArrayList(u8)) FsError!void,
        setMode: *const fn (*anyopaque, path: []const u8, mode: u16) FsError!void,
        setTimes: *const fn (*anyopaque, path: []const u8, atime: i64, mtime: i64) FsError!void,
    };

    pub fn open(self: FileSystem, caller: CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        return self.vtable.open(self.ptr, caller, path, flags);
    }
    pub fn stat(self: FileSystem, path: []const u8) FsError!Metadata {
        return self.vtable.stat(self.ptr, path);
    }
    pub fn readdir(self: FileSystem, caller: CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(DirEntry)) FsError!void {
        return self.vtable.readdir(self.ptr, caller, path, arena, out);
    }
    pub fn mkdir(self: FileSystem, caller: CallerId, path: []const u8) FsError!void {
        return self.vtable.mkdir(self.ptr, caller, path);
    }
    pub fn unlink(self: FileSystem, caller: CallerId, path: []const u8) FsError!void {
        return self.vtable.unlink(self.ptr, caller, path);
    }
    pub fn rename(self: FileSystem, caller: CallerId, from: []const u8, to: []const u8) FsError!void {
        return self.vtable.rename(self.ptr, caller, from, to);
    }
    pub fn symlink(self: FileSystem, target: []const u8, link_path: []const u8) FsError!void {
        return self.vtable.symlink(self.ptr, target, link_path);
    }
    pub fn link(self: FileSystem, existing: []const u8, new: []const u8) FsError!void {
        return self.vtable.link(self.ptr, existing, new);
    }
    pub fn readlink(self: FileSystem, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        return self.vtable.readlink(self.ptr, path, out);
    }
    pub fn setMode(self: FileSystem, path: []const u8, mode: u16) FsError!void {
        return self.vtable.setMode(self.ptr, path, mode);
    }
    pub fn setTimes(self: FileSystem, path: []const u8, atime: i64, mtime: i64) FsError!void {
        return self.vtable.setTimes(self.ptr, path, atime, mtime);
    }
};

pub fn fsSymlinkUnsupported(_: *anyopaque, _: []const u8, _: []const u8) FsError!void {
    return FsError.NotImplemented;
}
pub fn fsLinkUnsupported(_: *anyopaque, _: []const u8, _: []const u8) FsError!void {
    return FsError.NotImplemented;
}
pub fn fsReadlinkUnsupported(_: *anyopaque, _: []const u8, _: *std.ArrayList(u8)) FsError!void {
    return FsError.NotImplemented;
}
pub fn fsSetModeUnsupported(_: *anyopaque, _: []const u8, _: u16) FsError!void {
    return FsError.NotImplemented;
}
pub fn fsSetTimesUnsupported(_: *anyopaque, _: []const u8, _: i64, _: i64) FsError!void {
    return FsError.NotImplemented;
}
pub fn fsRenameUnsupported(_: *anyopaque, _: CallerId, _: []const u8, _: []const u8) FsError!void {
    return FsError.NotImplemented;
}

// ── Path helpers (mirror KPath + namespace free fns) ────────────────────────────────────

/// Strip a trailing slash for mount comparisons (except root).
pub fn normalizeMount(alloc: std.mem.Allocator, path: []const u8) []u8 {
    const t = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    const s = if (t.len == 0) "/" else t;
    return alloc.dupe(u8, s) catch @panic("OOM");
}

/// The parent directory of `path`, or null for root / a bare name.
pub fn parentPath(path: []const u8) ?[]const u8 {
    const s = std.mem.trimEnd(u8, path, "/");
    const idx = std.mem.lastIndexOfScalar(u8, s, '/') orelse return null;
    if (idx == 0) return "/";
    return s[0..idx];
}

/// The final component of `path`.
pub fn baseName(path: []const u8) []const u8 {
    const s = std.mem.trimEnd(u8, path, "/");
    const idx = std.mem.lastIndexOfScalar(u8, s, '/') orelse return s;
    return s[idx + 1 ..];
}

/// Join a directory path and an entry name with a single `/` (allocates).
pub fn joinPath(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) []u8 {
    if (std.mem.endsWith(u8, dir, "/")) {
        return std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, name }) catch @panic("OOM");
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name }) catch @panic("OOM");
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn dirEntryLess(_: void, a: DirEntry, b: DirEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

// ── Mount + resolution ──────────────────────────────────────────────────────────────────

const Mount = struct {
    fs: FileSystem,
    /// Path WITHIN `fs` this mount maps to — "" for an ordinary mount (bind sets it).
    sub: []const u8,
    label: []const u8,
    read_only: bool,
    write_cap: u8,
};

pub const MountInfo = struct {
    path: []const u8,
    label: []const u8,
    read_only: bool,
};

const Resolved = struct {
    mount_point: []const u8,
    /// fs-relative path, owned by the transient arena.
    fs_path: []const u8,
    fs: FileSystem,
    read_only: bool,
    write_cap: u8,
};

/// The mount namespace. Phase 3 has a single root namespace (per-task forking is Phase 4);
/// it owns its mount table and every backing FileSystem struct via `gpa`.
pub const Namespace = struct {
    gpa: std.mem.Allocator,
    owner: CallerId = AGENT_OWNER,
    /// mount-point (normalized, owned) → Mount.
    mounts: std.StringHashMapUnmanaged(Mount) = .{},

    pub fn init(gpa: std.mem.Allocator) Namespace {
        return .{ .gpa = gpa };
    }

    /// Mount `fs` at `path` with a `label` and `read_only` flag (writes need CAP_FS_WRITE).
    pub fn mountLabeled(self: *Namespace, path: []const u8, fs: FileSystem, label: []const u8, read_only: bool) void {
        const key = normalizeMount(self.gpa, path);
        const gop = self.mounts.getOrPut(self.gpa, key) catch @panic("OOM");
        if (gop.found_existing) {
            if (gop.value_ptr.sub.len != 0) self.gpa.free(gop.value_ptr.sub);
            self.gpa.free(key);
        }
        gop.value_ptr.* = .{ .fs = fs, .sub = "", .label = label, .read_only = read_only, .write_cap = constants.CAP_FS_WRITE };
    }

    /// Bind an existing resolved namespace path at another mount point.
    pub fn bind(self: *Namespace, arena: std.mem.Allocator, old: []const u8, new: []const u8) FsError!void {
        const old_path = try self.canonicalize(arena, old, true);
        const new_path = try self.canonicalize(arena, new, false);
        const source = self.resolve(arena, old_path) orelse return FsError.NotFound;
        if (parentPath(new_path)) |parent| {
            const md = try self.statPath(arena, parent);
            if (md.node_type != .dir) return FsError.NotDir;
        } else {
            return FsError.InvalidPath;
        }

        const key = normalizeMount(self.gpa, new_path);
        const sub = self.gpa.dupe(u8, source.fs_path) catch @panic("OOM");
        const gop = self.mounts.getOrPut(self.gpa, key) catch @panic("OOM");
        if (gop.found_existing) {
            if (gop.value_ptr.sub.len != 0) self.gpa.free(gop.value_ptr.sub);
            self.gpa.free(key);
        }
        gop.value_ptr.* = .{
            .fs = source.fs,
            .sub = sub,
            .label = "bind",
            .read_only = source.read_only,
            .write_cap = source.write_cap,
        };
    }

    /// Unmount at `path`; refuses (NotEmpty) while a child mount exists beneath it.
    pub fn unmount(self: *Namespace, path: []const u8) FsError!void {
        const norm = normalizeMount(self.gpa, path);
        defer self.gpa.free(norm);
        var it = self.mounts.keyIterator();
        while (it.next()) |k| {
            if (!std.mem.eql(u8, k.*, norm) and mountBeneath(norm, k.*)) return FsError.NotEmpty;
        }
        if (self.mounts.fetchRemove(norm)) |kv| {
            if (kv.value.sub.len != 0) self.gpa.free(kv.value.sub);
            self.gpa.free(kv.key);
        } else {
            return FsError.NotFound;
        }
    }

    /// Longest-prefix resolution. `arena` owns the returned `fs_path`.
    fn resolve(self: *Namespace, arena: std.mem.Allocator, path: []const u8) ?Resolved {
        var best: ?[]const u8 = null;
        var it = self.mounts.keyIterator();
        while (it.next()) |kptr| {
            const mp = kptr.*;
            const matches = if (std.mem.eql(u8, mp, "/"))
                std.mem.startsWith(u8, path, "/")
            else
                std.mem.eql(u8, path, mp) or (std.mem.startsWith(u8, path, mp) and path.len > mp.len and path[mp.len] == '/');
            if (matches and (best == null or mp.len > best.?.len)) best = mp;
        }
        const mount_point = best orelse return null;
        const mount = self.mounts.getPtr(mount_point).?;

        const rel: []const u8 = if (std.mem.eql(u8, path, mount_point))
            "/"
        else if (std.mem.eql(u8, mount_point, "/"))
            path
        else
            path[mount_point.len..];

        const fs_path: []const u8 = if (mount.sub.len == 0)
            arena.dupe(u8, rel) catch @panic("OOM")
        else if (std.mem.eql(u8, rel, "/"))
            arena.dupe(u8, mount.sub) catch @panic("OOM")
        else
            std.fmt.allocPrint(arena, "{s}{s}", .{ mount.sub, rel }) catch @panic("OOM");

        return .{
            .mount_point = mount_point,
            .fs_path = fs_path,
            .fs = mount.fs,
            .read_only = mount.read_only,
            .write_cap = mount.write_cap,
        };
    }

    pub fn writeCapAt(self: *Namespace, arena: std.mem.Allocator, path: []const u8) u8 {
        const r = self.resolve(arena, path) orelse return constants.CAP_FS_WRITE;
        return r.write_cap;
    }

    pub fn mountList(self: *Namespace, arena: std.mem.Allocator, out: *std.ArrayList(MountInfo)) void {
        var it = self.mounts.iterator();
        while (it.next()) |entry| {
            out.append(arena, .{
                .path = arena.dupe(u8, entry.key_ptr.*) catch @panic("OOM"),
                .label = entry.value_ptr.label,
                .read_only = entry.value_ptr.read_only,
            }) catch @panic("OOM");
        }
        std.mem.sort(MountInfo, out.items, {}, struct {
            fn less(_: void, a: MountInfo, b: MountInfo) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.less);
    }

    /// Basenames of every mount whose parent directory is `path` (deduped, appended sorted).
    fn childMountBasenames(self: *Namespace, arena: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]const u8)) void {
        const norm = normalizeMount(arena, path);
        var it = self.mounts.keyIterator();
        while (it.next()) |kptr| {
            if (childMountName(norm, kptr.*)) |name| {
                var dup = false;
                for (out.items) |existing| {
                    if (std.mem.eql(u8, existing, name)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) out.append(arena, arena.dupe(u8, name) catch @panic("OOM")) catch @panic("OOM");
            }
        }
    }

    // ── delegated operations ────────────────────────────────────────────────────────────

    pub fn openAs(self: *Namespace, arena: std.mem.Allocator, caller: CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        if (flags.writes() and r.read_only) return FsError.PermissionDenied;
        // Owner-triad mode enforcement, AND-ed with the capability checks the caller did.
        if (r.fs.stat(r.fs_path)) |meta| {
            if (flags.read and !meta.ownerReadable()) return FsError.AccessDenied;
            if (flags.writes() and !meta.ownerWritable()) return FsError.AccessDenied;
        } else |e| switch (e) {
            FsError.NotFound => {
                if (flags.create) {
                    if (parentPath(r.fs_path)) |parent| {
                        if (r.fs.stat(parent)) |pm| {
                            if (!pm.ownerWritable()) return FsError.AccessDenied;
                        } else |_| {}
                    }
                }
            },
            else => {},
        }
        return r.fs.open(caller, r.fs_path, flags);
    }

    pub fn statPath(self: *Namespace, arena: std.mem.Allocator, path: []const u8) FsError!Metadata {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        return r.fs.stat(r.fs_path);
    }

    /// Readdir merged with child-mount basenames; results sorted (A7). `arena` owns names.
    pub fn readdir(self: *Namespace, arena: std.mem.Allocator, caller: CallerId, path: []const u8, out: *std.ArrayList(DirEntry)) FsError!void {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        if (r.fs.stat(r.fs_path)) |meta| {
            if (!meta.ownerReadable() or !meta.ownerExecutable()) return FsError.AccessDenied;
        } else |_| {}

        var fs_entries: std.ArrayList(DirEntry) = .empty;
        const fs_err = r.fs.readdir(caller, r.fs_path, arena, &fs_entries);

        var children: std.ArrayList([]const u8) = .empty;
        self.childMountBasenames(arena, path, &children);

        if (fs_err) |_| {} else |e| switch (e) {
            FsError.WouldBlock => return FsError.WouldBlock,
            else => if (children.items.len == 0) return e,
        }

        // Merge into a name→entry map (last write wins; child mounts win), then sort.
        var merged: std.StringHashMapUnmanaged(DirEntry) = .{};
        for (fs_entries.items) |e| {
            merged.put(arena, e.name, e) catch @panic("OOM");
        }
        for (children.items) |name| {
            merged.put(arena, name, .{ .name = name, .node_type = .dir }) catch @panic("OOM");
        }
        var it = merged.valueIterator();
        while (it.next()) |v| out.append(arena, v.*) catch @panic("OOM");
        std.mem.sort(DirEntry, out.items, {}, dirEntryLess);
    }

    pub fn mkdir(self: *Namespace, arena: std.mem.Allocator, caller: CallerId, path: []const u8) FsError!void {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        if (r.read_only) return FsError.PermissionDenied;
        try requireParentWritable(r);
        return r.fs.mkdir(caller, r.fs_path);
    }

    pub fn unlink(self: *Namespace, arena: std.mem.Allocator, caller: CallerId, path: []const u8) FsError!void {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        if (r.read_only) return FsError.PermissionDenied;
        try requireParentWritable(r);
        return r.fs.unlink(caller, r.fs_path);
    }

    pub fn rename(self: *Namespace, arena: std.mem.Allocator, caller: CallerId, from: []const u8, to: []const u8) FsError!void {
        const rf = self.resolve(arena, from) orelse return FsError.NotFound;
        const rt = self.resolve(arena, to) orelse return FsError.NotFound;
        if (!std.mem.eql(u8, rf.mount_point, rt.mount_point)) return FsError.CrossDevice;
        if (rf.read_only) return FsError.PermissionDenied;
        try requireParentWritable(rf);
        try requireParentWritable(rt);
        return rf.fs.rename(caller, rf.fs_path, rt.fs_path);
    }

    pub fn readlink(self: *Namespace, arena: std.mem.Allocator, path: []const u8, out: *std.ArrayList(u8)) FsError!void {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        return r.fs.readlink(r.fs_path, out);
    }

    pub fn symlink(self: *Namespace, arena: std.mem.Allocator, target: []const u8, link_path: []const u8) FsError!void {
        const r = self.resolve(arena, link_path) orelse return FsError.NotFound;
        if (r.read_only) return FsError.PermissionDenied;
        try requireParentWritable(r);
        return r.fs.symlink(target, r.fs_path);
    }

    pub fn link(self: *Namespace, arena: std.mem.Allocator, existing: []const u8, new: []const u8) FsError!void {
        const re = self.resolve(arena, existing) orelse return FsError.NotFound;
        const rn = self.resolve(arena, new) orelse return FsError.NotFound;
        if (!std.mem.eql(u8, re.mount_point, rn.mount_point)) return FsError.CrossDevice;
        if (rn.read_only) return FsError.PermissionDenied;
        try requireParentWritable(rn);
        return re.fs.link(re.fs_path, rn.fs_path);
    }

    pub fn setMode(self: *Namespace, arena: std.mem.Allocator, path: []const u8, mode: u16) FsError!void {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        if (r.read_only) return FsError.PermissionDenied;
        return r.fs.setMode(r.fs_path, mode);
    }

    pub fn setTimes(self: *Namespace, arena: std.mem.Allocator, path: []const u8, atime: i64, mtime: i64) FsError!void {
        const r = self.resolve(arena, path) orelse return FsError.NotFound;
        if (r.read_only) return FsError.PermissionDenied;
        return r.fs.setTimes(r.fs_path, atime, mtime);
    }

    /// lstat-equivalent used by canonicalize: (node type, link target) at `path`, no follow.
    fn lstatKind(self: *Namespace, arena: std.mem.Allocator, path: []const u8) ?struct { NodeType, []const u8 } {
        const r = self.resolve(arena, path) orelse return null;
        const md = r.fs.stat(r.fs_path) catch return null;
        if (md.node_type == .symlink) {
            var buf: std.ArrayList(u8) = .empty;
            r.fs.readlink(r.fs_path, &buf) catch {};
            return .{ .symlink, buf.items };
        }
        return .{ md.node_type, "" };
    }

    /// Search (`x`) permission on an already-resolved directory path, before looking up the
    /// next component (so a symlink in a no-search dir can't bypass its mode).
    fn requireSearchDir(self: *Namespace, arena: std.mem.Allocator, path: []const u8) FsError!void {
        const r = self.resolve(arena, path) orelse {
            var children: std.ArrayList([]const u8) = .empty;
            self.childMountBasenames(arena, path, &children);
            return if (children.items.len == 0) FsError.NotFound else {};
        };
        if (r.fs.stat(r.fs_path)) |meta| {
            if (meta.node_type != .dir) return FsError.NotDir;
            if (!meta.ownerExecutable()) return FsError.AccessDenied;
        } else |e| switch (e) {
            FsError.NotFound => {
                var children: std.ArrayList([]const u8) = .empty;
                self.childMountBasenames(arena, path, &children);
                if (children.items.len == 0) return e;
            },
            else => return e,
        }
    }

    /// Canonicalize `path`: collapse `.`/`..` and follow symlinks (final only if `follow_final`).
    /// The kernel's ONLY symlink-following site. `arena` owns the returned path.
    pub fn canonicalize(self: *Namespace, arena: std.mem.Allocator, path: []const u8, follow_final: bool) FsError![]const u8 {
        var pending: std.ArrayList([]const u8) = .empty;
        var pit = std.mem.splitScalar(u8, path, '/');
        while (pit.next()) |c| pending.append(arena, c) catch @panic("OOM");
        var out: std.ArrayList([]const u8) = .empty;
        var hops: usize = 0;
        var idx: usize = 0;

        while (idx < pending.items.len) {
            const comp = pending.items[idx];
            idx += 1;
            if (comp.len == 0) continue;
            try self.requireSearchDir(arena, absJoin(arena, out.items));
            if (std.mem.eql(u8, comp, ".")) continue;
            if (std.mem.eql(u8, comp, "..")) {
                if (out.items.len > 0) _ = out.pop();
                continue;
            }
            const candidate = absFrom(arena, out.items, comp);
            const is_final = idx == pending.items.len;
            const follow = !is_final or follow_final;
            const kind: ?struct { NodeType, []const u8 } = if (follow) self.lstatKind(arena, candidate) else null;
            if (kind != null and kind.?[0] == .symlink) {
                hops += 1;
                if (hops > SYMLOOP_MAX) return FsError.Loop;
                const target = kind.?[1];
                var next: std.ArrayList([]const u8) = .empty;
                var tit = std.mem.splitScalar(u8, target, '/');
                while (tit.next()) |c| next.append(arena, c) catch @panic("OOM");
                for (pending.items[idx..]) |c| next.append(arena, c) catch @panic("OOM");
                if (std.mem.startsWith(u8, target, "/")) out.clearRetainingCapacity();
                pending = next;
                idx = 0;
            } else {
                out.append(arena, comp) catch @panic("OOM");
            }
        }
        return absJoin(arena, out.items);
    }
};

/// Owner-`w` on the parent directory of a resolved path (permissive if the parent can't stat).
fn requireParentWritable(r: Resolved) FsError!void {
    if (parentPath(r.fs_path)) |parent| {
        if (r.fs.stat(parent)) |pm| {
            if (!pm.ownerWritable()) return FsError.AccessDenied;
        } else |_| {}
    }
}

/// Build `/<out…>/<comp>` from a resolved component stack and one more name (arena-owned).
fn absFrom(arena: std.mem.Allocator, out: []const []const u8, comp: []const u8) []const u8 {
    const base = absJoin(arena, out);
    if (std.mem.eql(u8, base, "/")) return std.fmt.allocPrint(arena, "/{s}", .{comp}) catch @panic("OOM");
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, comp }) catch @panic("OOM");
}

/// Join a resolved component stack into an absolute path (`/` when empty; arena-owned).
fn absJoin(arena: std.mem.Allocator, components: []const []const u8) []const u8 {
    if (components.len == 0) return "/";
    var buf: std.ArrayList(u8) = .empty;
    for (components) |c| {
        buf.append(arena, '/') catch @panic("OOM");
        buf.appendSlice(arena, c) catch @panic("OOM");
    }
    return buf.items;
}

/// True when `child` is a mount point below `parent`, at any depth.
fn mountBeneath(parent: []const u8, child: []const u8) bool {
    if (std.mem.eql(u8, parent, "/")) return !std.mem.eql(u8, child, "/") and std.mem.startsWith(u8, child, "/");
    return std.mem.startsWith(u8, child, parent) and child.len > parent.len and child[parent.len] == '/';
}

/// The immediate child entry under `parent` needed to reach mount point `mp`.
fn childMountName(parent: []const u8, mp: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, mp, parent)) return null;
    var rest: []const u8 = undefined;
    if (std.mem.eql(u8, parent, "/")) {
        if (!std.mem.startsWith(u8, mp, "/")) return null;
        rest = mp[1..];
    } else {
        if (!std.mem.startsWith(u8, mp, parent) or mp.len <= parent.len or mp[parent.len] != '/') return null;
        rest = mp[parent.len + 1 ..];
    }
    if (rest.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    return if (slash) |s| rest[0..s] else rest;
}
