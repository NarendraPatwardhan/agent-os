//! src/fs/mountfs.zig — host-backed mounted filesystems (§2.5).
//!
//! Owns: host-call request shape, polling, stale-call aging, and commit draining.
//! Invariants: A9, A8 (stale calls are snapshot blockers). ASYNC: pending marker (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/mountfs.rs.
//! Not here: the opaque host_call engine (egress/host_call.zig).

const std = @import("std");
const constants = @import("constants_zig");
const host_call = @import("../egress/host_call.zig");
const proxy = @import("proxy.zig");
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

const STALE_INFLIGHT_PASSES: u32 = 256;

const InflightCall = struct {
    caller: vfs.CallerId,
    op: u32,
    path: []u8,
    arg: []u8,
    fingerprint: u64,
    source: *host_call.Source,
    body: std.ArrayList(u8) = .empty,
    age: u32 = 0,
};

const PendingCommit = struct {
    source: *host_call.Source,
};

const Response = struct {
    status: i32,
    body: []u8,
};

pub const MountChannel = struct {
    gpa: std.mem.Allocator,
    engine: *host_call.Engine,
    driver: []u8,
    inflight: std.ArrayListUnmanaged(InflightCall) = .empty,
    meta: std.StringHashMapUnmanaged(Metadata) = .{},
    pending_commits: std.ArrayListUnmanaged(PendingCommit) = .empty,

    pub fn create(gpa: std.mem.Allocator, engine: *host_call.Engine, driver: []const u8) *MountChannel {
        const self = gpa.create(MountChannel) catch @panic("OOM");
        self.* = .{
            .gpa = gpa,
            .engine = engine,
            .driver = gpa.dupe(u8, driver) catch @panic("OOM"),
        };
        proxy.rememberMeta(gpa, &self.meta, "/", Metadata.dir());
        return self;
    }

    fn removeInflightAt(self: *MountChannel, i: usize) void {
        var call = self.inflight.orderedRemove(i);
        self.gpa.free(call.path);
        self.gpa.free(call.arg);
        call.body.deinit(self.gpa);
        call.source.release();
    }

    fn findInflight(self: *MountChannel, caller: vfs.CallerId) ?usize {
        for (self.inflight.items, 0..) |c, i| {
            if (c.caller == caller) return i;
        }
        return null;
    }

    pub fn request(self: *MountChannel, caller: vfs.CallerId, op: u32, path: []const u8, arg: []const u8, data: []const u8) FsError!Response {
        self.drainCommits();
        const fingerprint = requestDataFingerprint(data);
        if (self.findInflight(caller)) |i| {
            const c = self.inflight.items[i];
            if (c.op != op or c.fingerprint != fingerprint or !std.mem.eql(u8, c.path, path) or !std.mem.eql(u8, c.arg, arg)) {
                self.removeInflightAt(i);
            }
        }
        if (self.findInflight(caller) == null) {
            const blob = encodeRequest(self.gpa, self.driver, op, path, arg, data);
            defer self.gpa.free(blob);
            const source = self.engine.start(blob) catch return FsError.PermissionDenied;
            self.inflight.append(self.gpa, .{
                .caller = caller,
                .op = op,
                .path = self.gpa.dupe(u8, path) catch @panic("OOM"),
                .arg = self.gpa.dupe(u8, arg) catch @panic("OOM"),
                .fingerprint = fingerprint,
                .source = source,
            }) catch @panic("OOM");
        }

        const idx = self.findInflight(caller) orelse return FsError.IoError;
        var tmp: [4096]u8 = undefined;
        while (true) {
            self.inflight.items[idx].age = 0;
            switch (self.inflight.items[idx].source.readInto(&tmp)) {
                .pending => return FsError.WouldBlock,
                .got => |n| self.inflight.items[idx].body.appendSlice(self.gpa, tmp[0..n]) catch @panic("OOM"),
                .eof => break,
                .failed => {
                    self.removeInflightAt(idx);
                    return FsError.IoError;
                },
            }
        }

        var call = self.inflight.orderedRemove(idx);
        defer self.gpa.free(call.path);
        defer self.gpa.free(call.arg);
        defer call.source.release();
        const body = call.body.toOwnedSlice(self.gpa) catch @panic("OOM");
        return decodeResponse(self.gpa, body);
    }

    pub fn drainCommits(self: *MountChannel) void {
        var scratch: [256]u8 = undefined;
        var i: usize = 0;
        while (i < self.pending_commits.items.len) {
            const source = self.pending_commits.items[i].source;
            var keep = true;
            while (true) {
                switch (source.readInto(&scratch)) {
                    .pending => break,
                    .got => continue,
                    .eof, .failed => {
                        keep = false;
                        break;
                    },
                }
            }
            if (keep) {
                i += 1;
            } else {
                const c = self.pending_commits.orderedRemove(i);
                c.source.release();
            }
        }
    }

    pub fn evictStaleInflight(self: *MountChannel, alive: *const fn (*anyopaque, vfs.CallerId) bool, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < self.inflight.items.len) {
            var keep = true;
            const caller = self.inflight.items[i].caller;
            if (caller == vfs.SYSTEM_CALLER) {
                self.inflight.items[i].age +|= 1;
                keep = self.inflight.items[i].age <= STALE_INFLIGHT_PASSES;
            } else {
                keep = alive(ctx, caller);
            }
            if (keep) {
                i += 1;
            } else {
                self.removeInflightAt(i);
            }
        }
    }
};

pub fn drainAll(registry: *std.ArrayListUnmanaged(*MountChannel), alive: *const fn (*anyopaque, vfs.CallerId) bool, ctx: *anyopaque) void {
    for (registry.items) |ch| {
        ch.evictStaleInflight(alive, ctx);
        ch.drainCommits();
    }
}

pub fn pendingCommitCount(registry: *std.ArrayListUnmanaged(*MountChannel)) i32 {
    var total: i32 = 0;
    for (registry.items) |ch| total += @intCast(ch.pending_commits.items.len);
    return total;
}

pub const MountFs = struct {
    gpa: std.mem.Allocator,
    channel: *MountChannel,

    pub fn create(gpa: std.mem.Allocator, driver: []const u8, engine: *host_call.Engine, registry: *std.ArrayListUnmanaged(*MountChannel)) *MountFs {
        const self = gpa.create(MountFs) catch @panic("OOM");
        const ch = MountChannel.create(gpa, engine, driver);
        registry.append(gpa, ch) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .channel = ch };
        return self;
    }

    pub fn fileSystem(self: *MountFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn request(self: *MountFs, caller: vfs.CallerId, op: u32, path: []const u8, arg: []const u8, data: []const u8) FsError!Response {
        return self.channel.request(caller, op, path, arg, data);
    }

    fn checkStatus(self: *MountFs, status: i32, path: []const u8) FsError!void {
        fsResultFromErrno(status) catch |e| {
            if (e == FsError.NotFound) proxy.forgetPath(self.gpa, &self.channel.meta, path);
            return e;
        };
    }

    fn open(self: *MountFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const writes = flags.write or flags.create or flags.truncate or flags.append;
        if (writes) {
            var initial: []u8 = undefined;
            var existed = true;
            if (flags.truncate) {
                const resp = try self.request(caller, constants.MOUNT_OP_STAT, path, "", "");
                defer self.gpa.free(resp.body);
                fsResultFromErrno(resp.status) catch |e| switch (e) {
                    FsError.NotFound => {
                        if (!flags.create) return FsError.NotFound;
                        proxy.forgetPath(self.gpa, &self.channel.meta, path);
                        existed = false;
                    },
                    else => return e,
                };
                if (existed) {
                    const meta = try proxy.parseMetadata(resp.body);
                    if (meta.node_type == .dir) return FsError.IsDir;
                    proxy.rememberMeta(self.gpa, &self.channel.meta, path, meta);
                }
                initial = self.gpa.dupe(u8, "") catch @panic("OOM");
            } else {
                var resp = try self.request(caller, constants.MOUNT_OP_OPEN, path, "", "");
                fsResultFromErrno(resp.status) catch |e| switch (e) {
                    FsError.NotFound => {
                        self.gpa.free(resp.body);
                        if (!flags.create) return FsError.NotFound;
                        proxy.forgetPath(self.gpa, &self.channel.meta, path);
                        existed = false;
                        resp.body = self.gpa.dupe(u8, "") catch @panic("OOM");
                    },
                    else => {
                        self.gpa.free(resp.body);
                        return e;
                    },
                };
                initial = resp.body;
            }
            const h = self.gpa.create(MountWriteHandle) catch @panic("OOM");
            h.* = .{
                .gpa = self.gpa,
                .channel = self.channel,
                .path = self.gpa.dupe(u8, path) catch @panic("OOM"),
                .buf = initial,
                .offset = if (flags.append) initial.len else 0,
                .dirty = flags.truncate or (flags.create and !existed),
            };
            proxy.rememberMeta(self.gpa, &self.channel.meta, path, Metadata.file(initial.len));
            return h.fileHandle();
        }

        const resp = try self.request(caller, constants.MOUNT_OP_OPEN, path, "", "");
        try self.checkStatus(resp.status, path);
        proxy.rememberMeta(self.gpa, &self.channel.meta, path, Metadata.file(resp.body.len));
        const h = self.gpa.create(MountReadHandle) catch @panic("OOM");
        h.* = .{ .gpa = self.gpa, .data = resp.body };
        return h.fileHandle();
    }

    fn stat(self: *MountFs, path: []const u8) FsError!Metadata {
        if (proxy.cachedMeta(&self.channel.meta, path)) |m| return m;
        return Metadata.dir();
    }

    fn readdir(self: *MountFs, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        const resp = try self.request(caller, constants.MOUNT_OP_READDIR, path, "", "");
        defer self.gpa.free(resp.body);
        try self.checkStatus(resp.status, path);
        var parsed: std.ArrayList(proxy.ParsedDirent) = .empty;
        try proxy.parseDirents(arena, resp.body, path, &parsed);
        proxy.forgetChildrenOf(self.gpa, &self.channel.meta, path);
        for (parsed.items) |p| {
            proxy.rememberMeta(self.gpa, &self.channel.meta, p.child, p.metadata);
            out.append(arena, p.entry) catch @panic("OOM");
        }
    }

    fn mkdir(self: *MountFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        const resp = try self.request(caller, constants.MOUNT_OP_MKDIR, path, "", "");
        defer self.gpa.free(resp.body);
        try fsResultFromErrno(resp.status);
        proxy.rememberMeta(self.gpa, &self.channel.meta, path, Metadata.dir());
    }

    fn unlink(self: *MountFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        const resp = try self.request(caller, constants.MOUNT_OP_UNLINK, path, "", "");
        defer self.gpa.free(resp.body);
        try fsResultFromErrno(resp.status);
        proxy.forgetPath(self.gpa, &self.channel.meta, path);
    }

    fn rename(self: *MountFs, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        const resp = try self.request(caller, constants.MOUNT_OP_RENAME, from, to, "");
        defer self.gpa.free(resp.body);
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
    fn self_(p: *anyopaque) *MountFs {
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

const MountReadHandle = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    offset: usize = 0,

    fn fileHandle(self: *MountReadHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *MountReadHandle, out: []u8) FsError!usize {
        const start = @min(self.offset, self.data.len);
        const n = @min(out.len, self.data.len - start);
        if (n != 0) @memcpy(out[0..n], self.data[start .. start + n]);
        self.offset = start + n;
        return n;
    }
    fn write(_: *MountReadHandle, _: []const u8) FsError!usize {
        return FsError.PermissionDenied;
    }
    fn seek(self: *MountReadHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.offset)) + n,
            .end => |n| @as(i64, @intCast(self.data.len)) + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.offset = @intCast(next);
        return @intCast(self.offset);
    }
    fn stat(self: *MountReadHandle) FsError!Metadata {
        return Metadata.file(self.data.len);
    }
    fn truncate(_: *MountReadHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }
    fn close(self: *MountReadHandle) void {
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
    fn self_(p: *anyopaque) *MountReadHandle {
        return @ptrCast(@alignCast(p));
    }
    fn hRead(p: *anyopaque, out: []u8) FsError!usize {
        return self_(p).read(out);
    }
    fn hWrite(p: *anyopaque, data: []const u8) FsError!usize {
        return self_(p).write(data);
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

const MountWriteHandle = struct {
    gpa: std.mem.Allocator,
    channel: *MountChannel,
    path: []u8,
    buf: []u8,
    offset: usize = 0,
    dirty: bool = false,

    fn fileHandle(self: *MountWriteHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *MountWriteHandle, out: []u8) FsError!usize {
        const start = @min(self.offset, self.buf.len);
        const n = @min(out.len, self.buf.len - start);
        if (n != 0) @memcpy(out[0..n], self.buf[start .. start + n]);
        self.offset = start + n;
        return n;
    }
    fn write(self: *MountWriteHandle, data: []const u8) FsError!usize {
        const start = self.offset;
        const end = std.math.add(usize, start, data.len) catch return FsError.IoError;
        if (end > self.buf.len) self.buf = self.gpa.realloc(self.buf, end) catch @panic("OOM");
        @memcpy(self.buf[start..end], data);
        self.offset = end;
        self.dirty = true;
        return data.len;
    }
    fn seek(self: *MountWriteHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.offset)) + n,
            .end => |n| @as(i64, @intCast(self.buf.len)) + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.offset = @intCast(next);
        return @intCast(self.offset);
    }
    fn stat(self: *MountWriteHandle) FsError!Metadata {
        return Metadata.file(self.buf.len);
    }
    fn truncate(self: *MountWriteHandle, size: u64) FsError!void {
        self.buf = self.gpa.realloc(self.buf, @intCast(size)) catch @panic("OOM");
        self.dirty = true;
        if (self.offset > self.buf.len) self.offset = self.buf.len;
    }
    fn close(self: *MountWriteHandle) void {
        if (self.dirty) {
            const blob = encodeRequest(self.gpa, self.channel.driver, constants.MOUNT_OP_WRITE, self.path, "", self.buf);
            defer self.gpa.free(blob);
            if (self.channel.engine.start(blob)) |source| {
                self.channel.pending_commits.append(self.gpa, .{ .source = source }) catch @panic("OOM");
            } else |_| {}
            proxy.forgetPath(self.gpa, &self.channel.meta, self.path);
        }
        const gpa = self.gpa;
        gpa.free(self.path);
        gpa.free(self.buf);
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
    fn self_(p: *anyopaque) *MountWriteHandle {
        return @ptrCast(@alignCast(p));
    }
    fn hRead(p: *anyopaque, out: []u8) FsError!usize {
        return self_(p).read(out);
    }
    fn hWrite(p: *anyopaque, data: []const u8) FsError!usize {
        return self_(p).write(data);
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

fn encodeRequest(gpa: std.mem.Allocator, driver: []const u8, op: u32, path: []const u8, arg: []const u8, data: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(gpa, driver) catch @panic("OOM");
    out.append(gpa, 0) catch @panic("OOM");
    appendU32(&out, gpa, op);
    appendU32(&out, gpa, @intCast(path.len));
    out.appendSlice(gpa, path) catch @panic("OOM");
    appendU32(&out, gpa, @intCast(arg.len));
    out.appendSlice(gpa, arg) catch @panic("OOM");
    out.appendSlice(gpa, data) catch @panic("OOM");
    return out.toOwnedSlice(gpa) catch @panic("OOM");
}

fn decodeResponse(gpa: std.mem.Allocator, body: []u8) FsError!Response {
    if (body.len < 4) {
        gpa.free(body);
        return FsError.IoError;
    }
    const raw = @as(u32, body[0]) |
        (@as(u32, body[1]) << 8) |
        (@as(u32, body[2]) << 16) |
        (@as(u32, body[3]) << 24);
    const status: i32 = @bitCast(raw);
    const payload = gpa.dupe(u8, body[4..]) catch @panic("OOM");
    gpa.free(body);
    return .{ .status = status, .body = payload };
}

fn appendU32(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u32) void {
    out.append(a, @truncate(value)) catch @panic("OOM");
    out.append(a, @truncate(value >> 8)) catch @panic("OOM");
    out.append(a, @truncate(value >> 16)) catch @panic("OOM");
    out.append(a, @truncate(value >> 24)) catch @panic("OOM");
}

/// errno -> FsError, the single inverse map in errno.zig (re-exported for the mount host-driver
/// reply decoding).
const fsResultFromErrno = @import("../errno.zig").fsResultFromErrno;

fn requestDataFingerprint(data: []const u8) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (data) |b| {
        hash ^= b;
        hash *%= 0x0000_0100_0000_01b3;
    }
    return hash;
}
