//! src/fs/netfs.zig — capability-gated HTTP/WebSocket projected as a filesystem (§2.5).
//!
//! Owns: the /net tree that projects egress/net.zig; request/response file handles.
//! Invariants: A9 (capability denials → EPERM/EACCES), A7. ASYNC backend: return a pending marker to the trampoline, never park deep (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/netfs.rs.
//! Not here: the egress state machine itself (egress/net.zig) — netfs is its VFS face.
//!
//! Scaffold status: header-only. Fill Phase 6.
// TODO(E2): projected /net is outside the resident-service protocol core.

const std = @import("std");
const constants = @import("constants_zig");
const net = @import("../egress/net.zig");
const scheduler = @import("../scheduler.zig");
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

const SCHEMES = [_][]const u8{ "ws", "wss", "http", "https" };

pub const NetFs = struct {
    gpa: std.mem.Allocator,
    sched: *scheduler.Scheduler,
    engine: *net.Engine,

    pub fn create(gpa: std.mem.Allocator, sched: *scheduler.Scheduler, engine: *net.Engine) *NetFs {
        const self = gpa.create(NetFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .sched = sched, .engine = engine };
        return self;
    }

    pub fn fileSystem(self: *NetFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn hasNet(self: *NetFs, caller: vfs.CallerId) bool {
        return if (self.sched.getTask(caller)) |t| t.caps.has(constants.CAP_NET) else false;
    }

    fn isScheme(s: []const u8) bool {
        inline for (SCHEMES) |scheme| {
            if (std.mem.eql(u8, s, scheme)) return true;
        }
        return false;
    }

    fn parse(path: []const u8) ?struct { []const u8, []const u8 } {
        const p = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
        var it = std.mem.splitScalar(u8, p, '/');
        const scheme = it.next() orelse return null;
        if (!isScheme(scheme)) return null;
        const rest_start = scheme.len + 1;
        if (p.len <= rest_start) return null;
        const rest = p[rest_start..];
        if (rest.len == 0) return null;
        return .{ scheme, rest };
    }

    fn open(self: *NetFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        if (!self.hasNet(caller)) return FsError.PermissionDenied;
        const parsed = parse(path) orelse return FsError.NotFound;
        const scheme = parsed[0];
        const rest = parsed[1];
        const writes = flags.write or flags.create or flags.truncate or flags.append;
        if ((std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https")) and writes) {
            return FsError.PermissionDenied;
        }
        const url = std.fmt.allocPrint(self.gpa, "{s}://{s}", .{ scheme, rest }) catch @panic("OOM");
        defer self.gpa.free(url);
        if (std.mem.eql(u8, scheme, "ws") or std.mem.eql(u8, scheme, "wss")) {
            const src = self.engine.connectWs(url) catch return FsError.PermissionDenied;
            const h = self.gpa.create(NetHandle) catch @panic("OOM");
            h.* = .{ .gpa = self.gpa, .source = .{ .ws = src } };
            return h.fileHandle();
        }
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(self.gpa);
        const request = std.fmt.allocPrint(self.gpa, "GET {s}\n\n", .{url}) catch @panic("OOM");
        defer self.gpa.free(request);
        blob.appendSlice(self.gpa, request) catch @panic("OOM");
        const src = self.engine.startHttp(blob.items) catch return FsError.PermissionDenied;
        const h = self.gpa.create(NetHandle) catch @panic("OOM");
        h.* = .{ .gpa = self.gpa, .source = .{ .http = src } };
        return h.fileHandle();
    }

    fn stat(_: *NetFs, path: []const u8) FsError!Metadata {
        const rel = std.mem.trim(u8, path, "/");
        if (rel.len == 0 or isScheme(rel) or parse(path) != null) return Metadata.dir();
        return FsError.NotFound;
    }

    fn readdir(_: *NetFs, _: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        const rel = std.mem.trim(u8, path, "/");
        if (rel.len == 0) {
            inline for (SCHEMES) |scheme| {
                out.append(arena, .{ .name = scheme, .node_type = .dir }) catch @panic("OOM");
            }
            return;
        }
        if (isScheme(rel) or parse(path) != null) return;
        return FsError.NotFound;
    }

    fn deny(_: *NetFs, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn denyRename(_: *NetFs, _: vfs.CallerId, _: []const u8, _: []const u8) FsError!void {
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
    fn self_(p: *anyopaque) *NetFs {
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
};

const Source = union(enum) {
    http: *net.HttpSource,
    ws: *net.WsSource,
};

const NetHandle = struct {
    gpa: std.mem.Allocator,
    source: Source,

    fn fileHandle(self: *NetHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *NetHandle, out: []u8) FsError!usize {
        return switch (self.source) {
            .http => |src| switch (src.readInto(out)) {
                .pending => FsError.WouldBlock,
                .got => |n| n,
                .eof => 0,
                .failed => FsError.IoError,
            },
            .ws => |src| switch (src.readInto(out)) {
                .pending => FsError.WouldBlock,
                .got => |n| n,
                .eof => 0,
            },
        };
    }
    fn write(self: *NetHandle, bytes: []const u8) FsError!usize {
        return switch (self.source) {
            .http => FsError.PermissionDenied,
            .ws => |src| switch (src.send(bytes)) {
                .sent => |n| n,
                .pending => FsError.WouldBlock,
                .message_too_big => FsError.MessageTooBig,
                .closed => FsError.IoError,
            },
        };
    }
    fn seek(_: *NetHandle, _: SeekFrom) FsError!u64 {
        return FsError.NotImplemented;
    }
    fn stat(_: *NetHandle) FsError!Metadata {
        return Metadata.file(0);
    }
    fn truncate(_: *NetHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }
    fn close(self: *NetHandle) void {
        switch (self.source) {
            .http => |src| src.release(),
            .ws => |src| src.release(),
        }
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
    fn self_(p: *anyopaque) *NetHandle {
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
