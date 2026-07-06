//! src/fs/persistfs.zig — the persistence tree with async commit semantics (§2.5, §2.8).
//!
//! Owns: the /var/persist projection of egress/persist.zig, incl. snapshot blockers.
//! Invariants: A8 (pending commits are snapshot blockers surfaced via counters), A9. ASYNC: pending marker, not deep park (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/persistfs.rs.
//! Not here: the commit state machine (egress/persist.zig).

const std = @import("std");
const constants = @import("constants_zig");
const persist = @import("../egress/persist.zig");
const proxy = @import("proxy.zig");
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

const STALE_INFLIGHT_PASSES: u32 = 256;
const GET_ABSENT: u8 = @intCast(constants.PERSIST_GET_ABSENT);
const GET_PRESENT: u8 = @intCast(constants.PERSIST_GET_PRESENT);

const InflightCall = struct {
    caller: vfs.CallerId,
    op: u32,
    key: []u8,
    fingerprint: u64,
    source: *persist.Source,
    body: std.ArrayList(u8) = .empty,
    age: u32 = 0,
};

const Completed = struct {
    caller: vfs.CallerId,
    op: u32,
    key: []u8,
    fingerprint: u64,
    body: []u8,
};

const ActiveOp = struct {
    caller: vfs.CallerId,
    tag: u8,
    path: []u8,
    extra: []u8,
};

const PendingCommit = struct {
    source: *persist.Source,
};

pub const PersistChannel = struct {
    gpa: std.mem.Allocator,
    engine: *persist.Engine,
    inflight: std.ArrayListUnmanaged(InflightCall) = .empty,
    completed: std.ArrayListUnmanaged(Completed) = .empty,
    active_ops: std.ArrayListUnmanaged(ActiveOp) = .empty,
    meta: std.StringHashMapUnmanaged(Metadata) = .{},
    pending_commits: std.ArrayListUnmanaged(PendingCommit) = .empty,

    pub fn create(gpa: std.mem.Allocator, engine: *persist.Engine) *PersistChannel {
        const self = gpa.create(PersistChannel) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .engine = engine };
        proxy.rememberMeta(gpa, &self.meta, "/", Metadata.dir());
        return self;
    }

    fn activeIndex(self: *PersistChannel, caller: vfs.CallerId) ?usize {
        for (self.active_ops.items, 0..) |op, i| {
            if (op.caller == caller) return i;
        }
        return null;
    }

    fn opMatches(op: ActiveOp, tag: u8, path: []const u8, extra: []const u8) bool {
        return op.tag == tag and std.mem.eql(u8, op.path, path) and std.mem.eql(u8, op.extra, extra);
    }

    pub fn begin(self: *PersistChannel, caller: vfs.CallerId, tag: u8, path: []const u8, extra: []const u8) void {
        if (self.activeIndex(caller)) |i| {
            if (opMatches(self.active_ops.items[i], tag, path, extra)) return;
            self.finish(caller);
        }
        self.active_ops.append(self.gpa, .{
            .caller = caller,
            .tag = tag,
            .path = self.gpa.dupe(u8, path) catch @panic("OOM"),
            .extra = self.gpa.dupe(u8, extra) catch @panic("OOM"),
        }) catch @panic("OOM");
    }

    pub fn finish(self: *PersistChannel, caller: vfs.CallerId) void {
        self.removeInflightFor(caller);
        self.removeCompletedFor(caller);
        if (self.activeIndex(caller)) |i| {
            const op = self.active_ops.orderedRemove(i);
            self.gpa.free(op.path);
            self.gpa.free(op.extra);
        }
    }

    fn removeInflightAt(self: *PersistChannel, i: usize) void {
        var call = self.inflight.orderedRemove(i);
        self.gpa.free(call.key);
        call.body.deinit(self.gpa);
        call.source.release();
    }

    fn removeInflightFor(self: *PersistChannel, caller: vfs.CallerId) void {
        var i: usize = 0;
        while (i < self.inflight.items.len) {
            if (self.inflight.items[i].caller == caller) {
                self.removeInflightAt(i);
            } else {
                i += 1;
            }
        }
    }

    fn removeCompletedFor(self: *PersistChannel, caller: vfs.CallerId) void {
        var i: usize = 0;
        while (i < self.completed.items.len) {
            if (self.completed.items[i].caller == caller) {
                const c = self.completed.orderedRemove(i);
                self.gpa.free(c.key);
                self.gpa.free(c.body);
            } else {
                i += 1;
            }
        }
    }

    fn findCompleted(self: *PersistChannel, caller: vfs.CallerId, op: u32, key: []const u8, fingerprint: u64) ?usize {
        for (self.completed.items, 0..) |c, i| {
            if (c.caller == caller and c.op == op and c.fingerprint == fingerprint and std.mem.eql(u8, c.key, key)) return i;
        }
        return null;
    }

    fn findInflight(self: *PersistChannel, caller: vfs.CallerId) ?usize {
        for (self.inflight.items, 0..) |c, i| {
            if (c.caller == caller) return i;
        }
        return null;
    }

    pub fn request(self: *PersistChannel, caller: vfs.CallerId, op: u32, key: []const u8, value: []const u8) FsError![]u8 {
        self.drainCommits();
        const fingerprint = requestValueFingerprint(value);
        if (self.findCompleted(caller, op, key, fingerprint)) |i| {
            return self.gpa.dupe(u8, self.completed.items[i].body) catch @panic("OOM");
        }

        if (self.findInflight(caller)) |i| {
            const c = self.inflight.items[i];
            if (c.op != op or c.fingerprint != fingerprint or !std.mem.eql(u8, c.key, key)) {
                self.removeInflightAt(i);
            }
        }
        if (self.findInflight(caller) == null) {
            const source = self.engine.start(op, key, value) catch return FsError.PermissionDenied;
            self.inflight.append(self.gpa, .{
                .caller = caller,
                .op = op,
                .key = self.gpa.dupe(u8, key) catch @panic("OOM"),
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
        defer self.gpa.free(call.key);
        defer call.source.release();
        const body = call.body.toOwnedSlice(self.gpa) catch @panic("OOM");
        const remembered = self.gpa.dupe(u8, body) catch @panic("OOM");
        self.completed.append(self.gpa, .{
            .caller = caller,
            .op = op,
            .key = self.gpa.dupe(u8, key) catch @panic("OOM"),
            .fingerprint = fingerprint,
            .body = remembered,
        }) catch @panic("OOM");
        return body;
    }

    pub fn drainCommits(self: *PersistChannel) void {
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

    pub fn evictStaleInflight(self: *PersistChannel, alive: *const fn (*anyopaque, vfs.CallerId) bool, ctx: *anyopaque) void {
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
                self.finish(caller);
            }
        }
    }
};

pub fn drainAll(registry: *std.ArrayListUnmanaged(*PersistChannel), alive: *const fn (*anyopaque, vfs.CallerId) bool, ctx: *anyopaque) void {
    var i: usize = 0;
    while (i < registry.items.len) {
        const ch = registry.items[i];
        ch.evictStaleInflight(alive, ctx);
        ch.drainCommits();
        if (ch.pending_commits.items.len == 0 and ch.inflight.items.len == 0) {
            i += 1;
        } else {
            i += 1;
        }
    }
}

pub fn pendingCommitCount(registry: *std.ArrayListUnmanaged(*PersistChannel)) i32 {
    var total: i32 = 0;
    for (registry.items) |ch| total += @intCast(ch.pending_commits.items.len);
    return total;
}

pub const PersistFs = struct {
    gpa: std.mem.Allocator,
    channel: *PersistChannel,

    pub fn create(gpa: std.mem.Allocator, engine: *persist.Engine, registry: *std.ArrayListUnmanaged(*PersistChannel)) *PersistFs {
        const self = gpa.create(PersistFs) catch @panic("OOM");
        const ch = PersistChannel.create(gpa, engine);
        registry.append(gpa, ch) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .channel = ch };
        return self;
    }

    pub fn fileSystem(self: *PersistFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn finishUnlessBlocked(self: *PersistFs, caller: vfs.CallerId, err: ?FsError) void {
        if (err == null or err.? != FsError.WouldBlock) self.channel.finish(caller);
    }

    fn request(self: *PersistFs, caller: vfs.CallerId, op: u32, key: []const u8, value: []const u8) FsError![]u8 {
        return self.channel.request(caller, op, key, value);
    }

    fn get(self: *PersistFs, caller: vfs.CallerId, key: []const u8) FsError!?[]u8 {
        const body = try self.request(caller, persist.OP_GET, key, "");
        defer self.gpa.free(body);
        return decodeGet(self.gpa, body);
    }

    fn put(self: *PersistFs, caller: vfs.CallerId, key: []const u8, value: []const u8) FsError!void {
        const body = try self.request(caller, persist.OP_PUT, key, value);
        self.gpa.free(body);
    }

    fn delete(self: *PersistFs, caller: vfs.CallerId, key: []const u8) FsError!void {
        const body = try self.request(caller, persist.OP_DELETE, key, "");
        self.gpa.free(body);
    }

    fn list(self: *PersistFs, caller: vfs.CallerId, arena: std.mem.Allocator, prefix: []const u8, out: *std.ArrayList([]const u8)) FsError!void {
        const body = try self.request(caller, persist.OP_LIST, prefix, "");
        defer self.gpa.free(body);
        var it = std.mem.splitScalar(u8, body, 0);
        while (it.next()) |key| {
            if (key.len != 0) out.append(arena, arena.dupe(u8, key) catch @panic("OOM")) catch @panic("OOM");
        }
    }

    fn dirExists(self: *PersistFs, caller: vfs.CallerId, arena: std.mem.Allocator, key: []const u8) FsError!bool {
        if (key.len == 0) return true;
        const prefix = dirPrefix(arena, key);
        var keys: std.ArrayList([]const u8) = .empty;
        try self.list(caller, arena, prefix, &keys);
        return keys.items.len != 0;
    }

    fn rememberMeta(self: *PersistFs, path: []const u8, meta: Metadata) void {
        proxy.rememberMeta(self.gpa, &self.channel.meta, path, meta);
    }

    fn forgetPath(self: *PersistFs, path: []const u8) void {
        proxy.forgetPath(self.gpa, &self.channel.meta, path);
    }

    fn open(self: *PersistFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const flags_id = [_]u8{openFlagsId(flags)};
        self.channel.begin(caller, 'o', path, &flags_id);
        const result = self.openImpl(caller, path, flags) catch |e| {
            self.finishUnlessBlocked(caller, e);
            return e;
        };
        self.finishUnlessBlocked(caller, null);
        return result;
    }

    fn openImpl(self: *PersistFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const key = keyOf(path);
        if (key.len == 0) return FsError.IsDir;
        const existing = try self.get(caller, key);
        var existed = existing != null;
        var buf: []u8 = undefined;
        if (existing) |value| {
            if (flags.truncate) {
                self.gpa.free(value);
                buf = self.gpa.dupe(u8, "") catch @panic("OOM");
            } else {
                buf = value;
            }
        } else {
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            if (try self.dirExists(caller, scratch.allocator(), key)) return FsError.IsDir;
            if (!flags.create) return FsError.NotFound;
            existed = false;
            buf = self.gpa.dupe(u8, "") catch @panic("OOM");
        }
        const h = self.gpa.create(PersistFileHandle) catch @panic("OOM");
        h.* = .{
            .gpa = self.gpa,
            .channel = self.channel,
            .path = self.gpa.dupe(u8, path) catch @panic("OOM"),
            .key = self.gpa.dupe(u8, key) catch @panic("OOM"),
            .buf = buf,
            .offset = if (flags.append) buf.len else 0,
            .dirty = flags.truncate or (flags.create and !existed),
        };
        self.rememberMeta(path, Metadata.file(buf.len));
        return h.fileHandle();
    }

    fn stat(self: *PersistFs, path: []const u8) FsError!Metadata {
        if (std.mem.eql(u8, path, "/")) return Metadata.dir();
        if (proxy.cachedMeta(&self.channel.meta, path)) |m| return m;
        return Metadata.dir();
    }

    fn readdir(self: *PersistFs, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        self.channel.begin(caller, 'r', path, "");
        self.readdirImpl(caller, path, arena, out) catch |e| {
            self.finishUnlessBlocked(caller, e);
            return e;
        };
        self.finishUnlessBlocked(caller, null);
    }

    fn readdirImpl(self: *PersistFs, caller: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        const key = keyOf(path);
        if (key.len != 0) {
            const existing = try self.get(caller, key);
            if (existing) |value| {
                self.gpa.free(value);
                return FsError.NotDir;
            }
        }
        const prefix = dirPrefix(arena, key);
        var keys: std.ArrayList([]const u8) = .empty;
        try self.list(caller, arena, prefix, &keys);
        if (key.len != 0 and keys.items.len == 0) {
            self.forgetPath(path);
            return FsError.NotFound;
        }
        var seen: std.StringHashMapUnmanaged(vfs.NodeType) = .{};
        for (keys.items) |k| {
            if (!std.mem.startsWith(u8, k, prefix)) continue;
            const rest = k[prefix.len..];
            if (rest.len == 0) continue;
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const name = if (slash) |s| rest[0..s] else rest;
            if (name.len == 0 or !std.unicode.utf8ValidateSlice(name)) continue;
            const kind: vfs.NodeType = if (slash == null) .file else .dir;
            if (seen.getPtr(name)) |slot| {
                if (kind == .dir) slot.* = .dir;
            } else {
                seen.put(arena, arena.dupe(u8, name) catch @panic("OOM"), kind) catch @panic("OOM");
            }
        }
        proxy.forgetChildrenOf(self.gpa, &self.channel.meta, path);
        proxy.rememberMeta(self.gpa, &self.channel.meta, path, Metadata.dir());
        var it = seen.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            const kind = kv.value_ptr.*;
            out.append(arena, .{ .name = name, .node_type = kind }) catch @panic("OOM");
            const child = proxy.childPath(arena, path, name);
            proxy.rememberMeta(self.gpa, &self.channel.meta, child, if (kind == .dir) Metadata.dir() else Metadata.file(0));
        }
    }

    fn mkdir(self: *PersistFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        self.channel.begin(caller, 'm', path, "");
        self.mkdirImpl(caller, path) catch |e| {
            self.finishUnlessBlocked(caller, e);
            return e;
        };
        self.finishUnlessBlocked(caller, null);
    }

    fn mkdirImpl(self: *PersistFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        const key = keyOf(path);
        if (key.len == 0) return;
        const existing = try self.get(caller, key);
        if (existing) |value| {
            self.gpa.free(value);
            return FsError.AlreadyExists;
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const marker = dirPrefix(scratch.allocator(), key);
        try self.put(caller, marker, "");
        self.rememberMeta(path, Metadata.dir());
    }

    fn unlink(self: *PersistFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        self.channel.begin(caller, 'u', path, "");
        self.unlinkImpl(caller, path) catch |e| {
            self.finishUnlessBlocked(caller, e);
            return e;
        };
        self.finishUnlessBlocked(caller, null);
    }

    fn unlinkImpl(self: *PersistFs, caller: vfs.CallerId, path: []const u8) FsError!void {
        const key = keyOf(path);
        if (key.len == 0) return FsError.IsDir;
        const existing = try self.get(caller, key);
        if (existing) |value| {
            self.gpa.free(value);
            try self.delete(caller, key);
            self.forgetPath(path);
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        if (try self.dirExists(caller, scratch.allocator(), key)) return FsError.IsDir;
        return FsError.NotFound;
    }

    fn rename(self: *PersistFs, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        var extra: std.ArrayList(u8) = .empty;
        defer extra.deinit(self.gpa);
        extra.appendSlice(self.gpa, to) catch @panic("OOM");
        extra.append(self.gpa, 0) catch @panic("OOM");
        self.channel.begin(caller, 'n', from, extra.items);
        self.renameImpl(caller, from, to) catch |e| {
            self.finishUnlessBlocked(caller, e);
            return e;
        };
        self.finishUnlessBlocked(caller, null);
    }

    fn renameImpl(self: *PersistFs, caller: vfs.CallerId, from: []const u8, to: []const u8) FsError!void {
        const from_key = keyOf(from);
        const to_key = keyOf(to);
        if (from_key.len == 0 or to_key.len == 0) return FsError.IsDir;
        const value = (try self.get(caller, from_key)) orelse return FsError.NotFound;
        defer self.gpa.free(value);
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        if (try self.dirExists(caller, scratch.allocator(), to_key)) return FsError.IsDir;
        try self.put(caller, to_key, value);
        try self.delete(caller, from_key);
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
    fn self_(p: *anyopaque) *PersistFs {
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

const PersistFileHandle = struct {
    gpa: std.mem.Allocator,
    channel: *PersistChannel,
    path: []u8,
    key: []u8,
    buf: []u8,
    offset: usize = 0,
    dirty: bool = false,

    fn fileHandle(self: *PersistFileHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *PersistFileHandle, out: []u8) FsError!usize {
        const start = @min(self.offset, self.buf.len);
        const n = @min(out.len, self.buf.len - start);
        if (n != 0) @memcpy(out[0..n], self.buf[start .. start + n]);
        self.offset = start + n;
        return n;
    }
    fn write(self: *PersistFileHandle, data: []const u8) FsError!usize {
        const start = self.offset;
        const end = std.math.add(usize, start, data.len) catch return FsError.IoError;
        if (end > self.buf.len) {
            self.buf = self.gpa.realloc(self.buf, end) catch @panic("OOM");
        }
        @memcpy(self.buf[start..end], data);
        self.offset = end;
        self.dirty = true;
        return data.len;
    }
    fn seek(self: *PersistFileHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.offset)) + n,
            .end => |n| @as(i64, @intCast(self.buf.len)) + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.offset = @intCast(next);
        return @intCast(self.offset);
    }
    fn stat(self: *PersistFileHandle) FsError!Metadata {
        return Metadata.file(self.buf.len);
    }
    fn truncate(self: *PersistFileHandle, size: u64) FsError!void {
        self.buf = self.gpa.realloc(self.buf, @intCast(size)) catch @panic("OOM");
        self.dirty = true;
        if (self.offset > self.buf.len) self.offset = self.buf.len;
    }
    fn close(self: *PersistFileHandle) void {
        if (self.dirty) {
            if (self.channel.engine.start(persist.OP_PUT, self.key, self.buf)) |source| {
                self.channel.pending_commits.append(self.gpa, .{ .source = source }) catch @panic("OOM");
            } else |_| {}
            proxy.forgetPath(self.gpa, &self.channel.meta, self.path);
        }
        const gpa = self.gpa;
        gpa.free(self.path);
        gpa.free(self.key);
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
    fn self_(p: *anyopaque) *PersistFileHandle {
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

fn keyOf(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}

fn dirPrefix(arena: std.mem.Allocator, key: []const u8) []const u8 {
    if (key.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}/", .{key}) catch @panic("OOM");
}

fn decodeGet(gpa: std.mem.Allocator, body: []const u8) FsError!?[]u8 {
    if (body.len == 1 and body[0] == GET_ABSENT) return null;
    if (body.len >= 1 and body[0] == GET_PRESENT) return gpa.dupe(u8, body[1..]) catch @panic("OOM");
    return FsError.IoError;
}

fn openFlagsId(flags: OpenFlags) u8 {
    return (if (flags.read) @as(u8, 1) else 0) |
        (if (flags.write) @as(u8, 2) else 0) |
        (if (flags.create) @as(u8, 4) else 0) |
        (if (flags.truncate) @as(u8, 8) else 0) |
        (if (flags.append) @as(u8, 16) else 0);
}

fn fnv(seed: u64, bytes: []const u8) u64 {
    var h = seed;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x0000_0100_0000_01b3;
    }
    return h;
}

fn requestValueFingerprint(data: []const u8) u64 {
    return fnv(0xcbf2_9ce4_8422_2325, data);
}
