//! src/fs/procfs.zig — the process view exposed to userland (§2.5).
//!
//! Owns: task metadata records rendered for /proc as tests and userland observe them.
//! Invariants: A7 (stable ordering), A9.
//! Oracle (behavior to match): kernel/rust/src/fs/procfs.rs.
//! Not here: the task table itself (task.zig) — procfs only RENDERS it.
//!
//! Scaffold status: header-only. Fill Phase 3/4.
// TODO(E2): projected /proc is outside the resident-service protocol core.

const std = @import("std");
const bridge = @import("../bridge.zig");
const scheduler = @import("../scheduler.zig");
const task_mod = @import("../task.zig");
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

const AGENT_PID: vfs.CallerId = 1;

pub const ProcFs = struct {
    gpa: std.mem.Allocator,
    sched: *scheduler.Scheduler,
    ns: *vfs.Namespace,

    pub fn create(gpa: std.mem.Allocator, sched: *scheduler.Scheduler, ns: *vfs.Namespace) *ProcFs {
        const self = gpa.create(ProcFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .sched = sched, .ns = ns };
        return self;
    }

    pub fn fileSystem(self: *ProcFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn rel(path: []const u8) []const u8 {
        return std.mem.trim(u8, path, "/");
    }

    fn renderUptime(self: *ProcFs) []u8 {
        const ms_raw = bridge.mc_time_monotonic();
        const ms: i64 = if (ms_raw < 0) 0 else ms_raw;
        return std.fmt.allocPrint(self.gpa, "{}.{d:0>3}\n", .{ @divTrunc(ms, 1000), @mod(ms, 1000) }) catch @panic("OOM");
    }

    fn renderMounts(self: *ProcFs, arena: std.mem.Allocator) []u8 {
        var mounts: std.ArrayList(vfs.MountInfo) = .empty;
        self.ns.mountList(arena, &mounts);
        var out: std.ArrayList(u8) = .empty;
        for (mounts.items) |m| {
            const line = std.fmt.allocPrint(self.gpa, "{s} {s} {s}\n", .{ m.path, m.label, if (m.read_only) "ro" else "rw" }) catch @panic("OOM");
            defer self.gpa.free(line);
            out.appendSlice(self.gpa, line) catch @panic("OOM");
        }
        return out.toOwnedSlice(self.gpa) catch @panic("OOM");
    }

    fn stateLabel(s: task_mod.TaskState) []const u8 {
        return switch (s) {
            .ready => "R (ready)",
            .running => "R (running)",
            .blocked => "S (blocked)",
            .zombie => "Z (zombie)",
        };
    }

    fn renderPidFile(self: *ProcFs, pid: u32, leaf: []const u8) ?[]u8 {
        const t = self.sched.getTask(pid) orelse return null;
        if (std.mem.eql(u8, leaf, "cmdline")) {
            var out: std.ArrayList(u8) = .empty;
            out.appendSlice(self.gpa, t.command) catch @panic("OOM");
            for (t.args) |arg| {
                out.append(self.gpa, 0) catch @panic("OOM");
                out.appendSlice(self.gpa, arg) catch @panic("OOM");
            }
            out.append(self.gpa, 0) catch @panic("OOM");
            return out.toOwnedSlice(self.gpa) catch @panic("OOM");
        }
        if (std.mem.eql(u8, leaf, "status")) {
            return std.fmt.allocPrint(
                self.gpa,
                "Name:\t{s}\nPid:\t{}\nPPid:\t{}\nState:\t{s}\nCwd:\t{s}\n",
                .{ t.name, t.id, t.parent_id orelse 0, stateLabel(t.state), t.cwd },
            ) catch @panic("OOM");
        }
        if (std.mem.eql(u8, leaf, "cwd")) {
            return std.fmt.allocPrint(self.gpa, "{s}\n", .{t.cwd}) catch @panic("OOM");
        }
        return null;
    }

    fn renderFile(self: *ProcFs, arena: std.mem.Allocator, path: []const u8) ?[]u8 {
        const r = rel(path);
        if (std.mem.eql(u8, r, "uptime")) return self.renderUptime();
        if (std.mem.eql(u8, r, "mounts")) return self.renderMounts(arena);
        var it = std.mem.splitScalar(u8, r, '/');
        const pid_s = it.next() orelse return null;
        const leaf = it.next() orelse return null;
        if (it.next() != null) return null;
        const pid = std.fmt.parseInt(u32, pid_s, 10) catch return null;
        return self.renderPidFile(pid, leaf);
    }

    fn parsePidLeaf(path: []const u8) ?struct { u32, []const u8 } {
        const r = rel(path);
        var it = std.mem.splitScalar(u8, r, '/');
        const pid_s = it.next() orelse return null;
        const leaf = it.next() orelse return null;
        if (it.next() != null) return null;
        const pid = std.fmt.parseInt(u32, pid_s, 10) catch return null;
        return .{ pid, leaf };
    }

    fn kindAt(self: *ProcFs, path: []const u8) ?vfs.NodeType {
        const r = rel(path);
        if (r.len == 0) return .dir;
        if (std.mem.eql(u8, r, "uptime") or std.mem.eql(u8, r, "mounts")) return .file;
        var it = std.mem.splitScalar(u8, r, '/');
        const pid_s = it.next() orelse return null;
        const pid = std.fmt.parseInt(u32, pid_s, 10) catch return null;
        if (self.sched.getTask(pid) == null) return null;
        const leaf = it.next() orelse return .dir;
        if (it.next() != null) return null;
        if (leaf.len == 0) return .dir;
        if (std.mem.eql(u8, leaf, "cmdline") or std.mem.eql(u8, leaf, "status") or
            std.mem.eql(u8, leaf, "cwd") or std.mem.eql(u8, leaf, "ctl")) return .file;
        return null;
    }

    fn open(self: *ProcFs, caller: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        const writes = flags.write or flags.create or flags.truncate or flags.append;
        if (parsePidLeaf(path)) |pl| {
            if (std.mem.eql(u8, pl[1], "ctl")) {
                if (self.sched.getTask(pl[0]) == null) return FsError.NotFound;
                if (!writes) return BufferHandle.open(self.gpa, "");
                const allowed = caller == AGENT_PID or caller == pl[0] or self.sched.isAncestorOf(caller, pl[0]);
                if (!allowed) return FsError.PermissionDenied;
                const h = self.gpa.create(CtlHandle) catch @panic("OOM");
                h.* = .{ .gpa = self.gpa, .sched = self.sched, .target = pl[0] };
                return h.fileHandle();
            }
        }
        if (writes) return FsError.PermissionDenied;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const data = self.renderFile(arena_state.allocator(), path) orelse return FsError.NotFound;
        const h = self.gpa.create(BufferHandle) catch @panic("OOM");
        h.* = .{ .gpa = self.gpa, .data = data };
        return h.fileHandle();
    }

    fn stat(self: *ProcFs, path: []const u8) FsError!Metadata {
        const kind = self.kindAt(path) orelse return FsError.NotFound;
        return switch (kind) {
            .dir => Metadata.dir(),
            .symlink => Metadata.symlink(0),
            .file => blk: {
                if (parsePidLeaf(path)) |pl| {
                    if (std.mem.eql(u8, pl[1], "ctl")) break :blk Metadata.file(0);
                }
                var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer arena_state.deinit();
                const data = self.renderFile(arena_state.allocator(), path) orelse break :blk Metadata.file(0);
                defer self.gpa.free(data);
                break :blk Metadata.file(data.len);
            },
        };
    }

    fn readdir(self: *ProcFs, _: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        const r = rel(path);
        if (r.len == 0) {
            out.append(arena, .{ .name = "mounts", .node_type = .file }) catch @panic("OOM");
            out.append(arena, .{ .name = "uptime", .node_type = .file }) catch @panic("OOM");
            const ids = self.sched.taskIds(arena);
            std.mem.sort(u32, ids, {}, struct {
                fn less(_: void, a: u32, b: u32) bool {
                    return a < b;
                }
            }.less);
            for (ids) |id| {
                const name = std.fmt.allocPrint(arena, "{}", .{id}) catch @panic("OOM");
                out.append(arena, .{ .name = name, .node_type = .dir }) catch @panic("OOM");
            }
            return;
        }
        const pid = std.fmt.parseInt(u32, std.mem.trim(u8, r, "/"), 10) catch return FsError.NotFound;
        if (self.sched.getTask(pid) == null) return FsError.NotFound;
        inline for (.{ "cmdline", "status", "cwd", "ctl" }) |name| {
            out.append(arena, .{ .name = name, .node_type = .file }) catch @panic("OOM");
        }
    }

    fn deny(_: *ProcFs, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn denyRename(_: *ProcFs, _: vfs.CallerId, _: []const u8, _: []const u8) FsError!void {
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
    fn self_(p: *anyopaque) *ProcFs {
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

const BufferHandle = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    pos: usize = 0,

    fn open(gpa: std.mem.Allocator, bytes: []const u8) FileHandle {
        const h = gpa.create(BufferHandle) catch @panic("OOM");
        h.* = .{ .gpa = gpa, .data = gpa.dupe(u8, bytes) catch @panic("OOM") };
        return h.fileHandle();
    }
    fn fileHandle(self: *BufferHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *BufferHandle, out: []u8) FsError!usize {
        const start = @min(self.pos, self.data.len);
        const n = @min(out.len, self.data.len - start);
        if (n != 0) @memcpy(out[0..n], self.data[start .. start + n]);
        self.pos = start + n;
        return n;
    }
    fn write(_: *BufferHandle, _: []const u8) FsError!usize {
        return FsError.PermissionDenied;
    }
    fn seek(self: *BufferHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.pos)) + n,
            .end => |n| @as(i64, @intCast(self.data.len)) + n,
        };
        if (next < 0 or next > @as(i64, @intCast(self.data.len))) return FsError.InvalidPath;
        self.pos = @intCast(next);
        return @intCast(self.pos);
    }
    fn stat(self: *BufferHandle) FsError!Metadata {
        return Metadata.file(self.data.len);
    }
    fn truncate(_: *BufferHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }
    fn close(self: *BufferHandle) void {
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
    fn self_(p: *anyopaque) *BufferHandle {
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

const CtlHandle = struct {
    gpa: std.mem.Allocator,
    sched: *scheduler.Scheduler,
    target: u32,
    line: std.ArrayList(u8) = .empty,

    fn fileHandle(self: *CtlHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn exec(self: *CtlHandle, cmd: []const u8) bool {
        const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
        if (trimmed.len == 0) return true;
        if (std.mem.eql(u8, trimmed, "kill")) {
            self.sched.killTask(self.target, 137);
            return true;
        }
        if (std.mem.eql(u8, trimmed, "stop")) {
            self.sched.setFrozen(self.target, true);
            return true;
        }
        if (std.mem.eql(u8, trimmed, "cont")) {
            self.sched.setFrozen(self.target, false);
            return true;
        }
        return false;
    }
    fn read(_: *CtlHandle, _: []u8) FsError!usize {
        return 0;
    }
    fn write(self: *CtlHandle, bytes: []const u8) FsError!usize {
        self.line.appendSlice(self.gpa, bytes) catch @panic("OOM");
        var ok = true;
        while (std.mem.indexOfScalar(u8, self.line.items, '\n')) |pos| {
            const cmd = self.gpa.dupe(u8, self.line.items[0..pos]) catch @panic("OOM");
            defer self.gpa.free(cmd);
            const rest = self.line.items[pos + 1 ..];
            std.mem.copyForwards(u8, self.line.items[0..rest.len], rest);
            self.line.items.len = rest.len;
            if (!self.exec(cmd)) ok = false;
        }
        return if (ok) bytes.len else FsError.InvalidPath;
    }
    fn seek(_: *CtlHandle, _: SeekFrom) FsError!u64 {
        return FsError.NotImplemented;
    }
    fn stat(_: *CtlHandle) FsError!Metadata {
        return Metadata.file(0);
    }
    fn truncate(_: *CtlHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }
    fn close(self: *CtlHandle) void {
        if (self.line.items.len != 0) _ = self.exec(self.line.items);
        self.line.deinit(self.gpa);
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
    fn self_(p: *anyopaque) *CtlHandle {
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
