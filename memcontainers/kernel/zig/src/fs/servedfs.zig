//! src/fs/servedfs.zig — guest-served filesystems (§2.5).
//!
//! Owns: request/response IDs, metadata cache behavior, and whole-file open behavior.
//! Invariants: A9, A7. ASYNC: pending marker, not deep park (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/servedfs.rs.
//! Not here: the resident service registry (service/registry.zig).

const std = @import("std");
const constants = @import("constants_zig");
const vfs = @import("../vfs.zig");
const proxy = @import("proxy.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

pub const ServeRequest = struct {
    id: u32,
    caller: vfs.CallerId,
    op: u32,
    path: []u8,
    arg: []u8,

    pub fn deinit(self: *ServeRequest, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.arg);
        self.* = undefined;
    }
};

const ServeResponse = struct {
    status: i32,
    data: []u8,

    fn deinit(self: *ServeResponse, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
    }
};

const ResponseEntry = struct {
    id: u32,
    response: ServeResponse,
};

const InflightEntry = struct {
    caller: vfs.CallerId,
    id: u32,
};

pub const ServeChannel = struct {
    gpa: std.mem.Allocator,
    refs: usize = 0,
    next_id: u32 = 1,
    requests: std.ArrayListUnmanaged(ServeRequest) = .empty,
    responses: std.ArrayListUnmanaged(ResponseEntry) = .empty,
    inflight: std.ArrayListUnmanaged(InflightEntry) = .empty,
    meta: std.StringHashMapUnmanaged(Metadata) = .{},
    closed: bool = false,

    pub fn create(gpa: std.mem.Allocator) *ServeChannel {
        const self = gpa.create(ServeChannel) catch @panic("OOM");
        self.* = .{ .gpa = gpa };
        proxy.rememberMeta(gpa, &self.meta, "/", Metadata.dir());
        return self;
    }

    pub fn retain(self: *ServeChannel) *ServeChannel {
        self.refs += 1;
        return self;
    }

    pub fn release(self: *ServeChannel) void {
        self.refs -|= 1;
        if (self.refs != 0) return;
        const gpa = self.gpa;
        self.deinit();
        gpa.destroy(self);
    }

    fn deinit(self: *ServeChannel) void {
        for (self.requests.items) |*r| r.deinit(self.gpa);
        self.requests.deinit(self.gpa);
        for (self.responses.items) |*r| r.response.deinit(self.gpa);
        self.responses.deinit(self.gpa);
        self.inflight.deinit(self.gpa);
        var it = self.meta.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.meta.deinit(self.gpa);
    }

    fn nextId(self: *ServeChannel) u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    fn inflightIndex(self: *const ServeChannel, caller: vfs.CallerId) ?usize {
        for (self.inflight.items, 0..) |entry, i| {
            if (entry.caller == caller) return i;
        }
        return null;
    }

    fn responseIndex(self: *const ServeChannel, id: u32) ?usize {
        for (self.responses.items, 0..) |entry, i| {
            if (entry.id == id) return i;
        }
        return null;
    }

    pub fn peekRequest(self: *const ServeChannel) ?ServeRequest {
        if (self.requests.items.len == 0) return null;
        return self.requests.items[0];
    }

    pub fn takeRequest(self: *ServeChannel) ?ServeRequest {
        if (self.requests.items.len == 0) return null;
        return self.requests.orderedRemove(0);
    }

    pub fn respond(self: *ServeChannel, req_id: u32, status: i32, data: []const u8) bool {
        var found = false;
        for (self.inflight.items) |entry| {
            if (entry.id == req_id) {
                found = true;
                break;
            }
        }
        if (!found) return false;
        self.responses.append(self.gpa, .{
            .id = req_id,
            .response = .{
                .status = status,
                .data = self.gpa.dupe(u8, data) catch @panic("OOM"),
            },
        }) catch @panic("OOM");
        return true;
    }

    pub fn close(self: *ServeChannel) void {
        self.closed = true;
    }

    fn request(self: *ServeChannel, op: u32, path: []const u8, arg: []const u8, caller: vfs.CallerId) FsError!ServeResponse {
        if (self.inflightIndex(caller)) |idx| {
            const req_id = self.inflight.items[idx].id;
            if (self.responseIndex(req_id)) |ridx| {
                const resp = self.responses.orderedRemove(ridx).response;
                _ = self.inflight.orderedRemove(idx);
                return resp;
            }
            if (self.closed) {
                _ = self.inflight.orderedRemove(idx);
                return FsError.IoError;
            }
            return FsError.WouldBlock;
        }
        if (self.closed) return FsError.IoError;
        const id = self.nextId();
        self.requests.append(self.gpa, .{
            .id = id,
            .caller = caller,
            .op = op,
            .path = self.gpa.dupe(u8, path) catch @panic("OOM"),
            .arg = self.gpa.dupe(u8, arg) catch @panic("OOM"),
        }) catch @panic("OOM");
        self.inflight.append(self.gpa, .{ .caller = caller, .id = id }) catch @panic("OOM");
        return FsError.WouldBlock;
    }
};

pub const ServeOwner = struct {
    gpa: std.mem.Allocator,
    channel: *ServeChannel,

    pub fn create(gpa: std.mem.Allocator, channel: *ServeChannel) *ServeOwner {
        const self = gpa.create(ServeOwner) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .channel = channel.retain() };
        return self;
    }

    pub fn release(self: *ServeOwner) void {
        self.channel.close();
        self.channel.release();
        self.gpa.destroy(self);
    }
};

pub const ServedFs = struct {
    gpa: std.mem.Allocator,
    channel: *ServeChannel,

    pub fn create(gpa: std.mem.Allocator, channel: *ServeChannel) *ServedFs {
        const self = gpa.create(ServedFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .channel = channel.retain() };
        return self;
    }

    pub fn fileSystem(self: *ServedFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn request(self: *ServedFs, op: u32, path: []const u8, arg: []const u8, caller: vfs.CallerId) FsError!ServeResponse {
        return self.channel.request(op, path, arg, caller);
    }

    fn open(self: *ServedFs, caller: vfs.CallerId, path: []const u8, _: OpenFlags) FsError!FileHandle {
        var resp = try self.request(constants.SERVE_OP_OPEN, path, "", caller);
        defer resp.deinit(self.gpa);
        try fsResultFromErrno(resp.status);
        proxy.rememberMeta(self.gpa, &self.channel.meta, path, Metadata.file(resp.data.len));
        const h = self.gpa.create(ServedFileHandle) catch @panic("OOM");
        h.* = .{ .gpa = self.gpa, .data = self.gpa.dupe(u8, resp.data) catch @panic("OOM") };
        return h.fileHandle();
    }

    fn stat(self: *ServedFs, path: []const u8) FsError!Metadata {
        return proxy.cachedMeta(&self.channel.meta, path) orelse Metadata.dir();
    }

    fn readdir(self: *ServedFs, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        var resp = try self.request(constants.SERVE_OP_READDIR, path, "", caller);
        defer resp.deinit(self.gpa);
        try fsResultFromErrno(resp.status);
        var parsed: std.ArrayList(proxy.ParsedDirent) = .empty;
        try proxy.parseDirents(arena, resp.data, path, &parsed);
        proxy.forgetChildrenOf(self.gpa, &self.channel.meta, path);
        for (parsed.items) |p| {
            proxy.rememberMeta(self.gpa, &self.channel.meta, p.child, p.metadata);
            out.append(arena, p.entry) catch @panic("OOM");
        }
    }

    fn mkdir(self: *ServedFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        var resp = try self.request(constants.SERVE_OP_MKDIR, path, "", caller);
        defer resp.deinit(self.gpa);
        try fsResultFromErrno(resp.status);
        proxy.rememberMeta(self.gpa, &self.channel.meta, path, Metadata.dir());
    }

    fn unlink(self: *ServedFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        var resp = try self.request(constants.SERVE_OP_UNLINK, path, "", caller);
        defer resp.deinit(self.gpa);
        try fsResultFromErrno(resp.status);
        proxy.forgetPath(self.gpa, &self.channel.meta, path);
    }

    fn rename(self: *ServedFs, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        var resp = try self.request(constants.SERVE_OP_RENAME, from, to, caller);
        defer resp.deinit(self.gpa);
        try fsResultFromErrno(resp.status);
        proxy.renamePath(self.gpa, &self.channel.meta, from, to);
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

    fn self_(p: *anyopaque) *ServedFs {
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
        return self_(p).mkdir(caller, path);
    }
    fn fsUnlink(p: *anyopaque, caller: vfs.CallerId, path: []const u8) FsError!void {
        return self_(p).unlink(caller, path);
    }
    fn fsRename(p: *anyopaque, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        return self_(p).rename(caller, from, to);
    }
};

fn fsResultFromErrno(errno: i32) FsError!void {
    if (errno == 0) return;
    return switch (errno) {
        constants.ENOENT => FsError.NotFound,
        constants.EEXIST => FsError.AlreadyExists,
        constants.ENOTDIR => FsError.NotDir,
        constants.EISDIR => FsError.IsDir,
        constants.EPERM => FsError.PermissionDenied,
        constants.EACCES => FsError.AccessDenied,
        constants.EINVAL => FsError.InvalidPath,
        constants.ENOTEMPTY => FsError.NotEmpty,
        constants.EBADF => FsError.BadFileDescriptor,
        constants.ENOSYS => FsError.NotImplemented,
        constants.EXDEV => FsError.CrossDevice,
        constants.EAGAIN => FsError.WouldBlock,
        constants.EMSGSIZE => FsError.MessageTooBig,
        constants.ELOOP => FsError.Loop,
        else => FsError.IoError,
    };
}

const ServedFileHandle = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    offset: usize = 0,

    fn fileHandle(self: *ServedFileHandle) FileHandle {
        return .{ .ptr = self, .vtable = &handle_vtable };
    }

    fn read(self: *ServedFileHandle, out: []u8) FsError!usize {
        const start = @min(self.offset, self.data.len);
        const n = @min(out.len, self.data.len - start);
        if (n != 0) @memcpy(out[0..n], self.data[start .. start + n]);
        self.offset = start + n;
        return n;
    }

    fn write(_: *ServedFileHandle, _: []const u8) FsError!usize {
        return FsError.PermissionDenied;
    }

    fn seek(self: *ServedFileHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.offset)) + n,
            .end => |n| @as(i64, @intCast(self.data.len)) + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.offset = @intCast(next);
        return @intCast(self.offset);
    }

    fn stat(self: *ServedFileHandle) FsError!Metadata {
        return Metadata.file(self.data.len);
    }

    fn truncate(_: *ServedFileHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }

    fn close(self: *ServedFileHandle) void {
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

    fn self_(p: *anyopaque) *ServedFileHandle {
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
