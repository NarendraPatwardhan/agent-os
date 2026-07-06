//! src/fs/toolsfs.zig — the read-only tool/package tree (§2.5).
//!
//! Owns: package/tool visibility under the existing image model.
//! Invariants: A7, A9.
//! Oracle (behavior to match): kernel/rust/src/fs/toolsfs.rs.
//! Not here: package integrity/catalog parsing (shared with pkgcore/toolcore).
//!
//! Scaffold status: header-only. Fill Phase 3/6.

const std = @import("std");
const vfs = @import("../vfs.zig");

const FsError = vfs.FsError;
const FileHandle = vfs.FileHandle;
const FileSystem = vfs.FileSystem;
const Metadata = vfs.Metadata;
const OpenFlags = vfs.OpenFlags;
const SeekFrom = vfs.SeekFrom;

const CATALOG_INDEX_PATH = "/etc/tools/catalog/index.json";
const CATALOG_RECORDS_DIR = "/etc/tools/catalog/records";

const Entry = struct {
    address: []const u8,
    integration: []const u8,
    owner: []const u8,
    connection: []const u8,
    tool: []const u8,
    description: []const u8,
    sha: []const u8,
};

pub const ToolsFs = struct {
    gpa: std.mem.Allocator,
    ns: *vfs.Namespace,

    pub fn create(gpa: std.mem.Allocator, ns: *vfs.Namespace) *ToolsFs {
        const self = gpa.create(ToolsFs) catch @panic("OOM");
        self.* = .{ .gpa = gpa, .ns = ns };
        return self;
    }

    pub fn fileSystem(self: *ToolsFs) FileSystem {
        return .{ .ptr = self, .vtable = &fs_vtable };
    }

    fn readFile(self: *ToolsFs, arena: std.mem.Allocator, path: []const u8) ?[]u8 {
        var h = self.ns.openAs(arena, vfs.SYSTEM_CALLER, path, vfs.OpenFlags.READ) catch return null;
        defer h.close();
        var out: std.ArrayList(u8) = .empty;
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = h.read(&tmp) catch return null;
            if (n == 0) break;
            out.appendSlice(arena, tmp[0..n]) catch @panic("OOM");
        }
        return out.items;
    }

    fn parts(path: []const u8) struct { [4][]const u8, usize } {
        var out: [4][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, path, "/"), '/');
        while (it.next()) |p| {
            if (p.len == 0) continue;
            if (n >= out.len) return .{ out, out.len + 1 };
            out[n] = p;
            n += 1;
        }
        return .{ out, n };
    }

    fn validSegment(s: []const u8) bool {
        if (s.len == 0) return false;
        for (s) |b| {
            if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '-')) return false;
        }
        return true;
    }

    fn splitAddress(arena: std.mem.Allocator, address: []const u8) ?struct { []const u8, []const u8, []const u8, []const u8 } {
        var segs: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, address, '.');
        while (it.next()) |seg| {
            if (!validSegment(seg)) return null;
            segs.append(arena, seg) catch @panic("OOM");
        }
        if (segs.items.len < 4) return null;
        if (!std.mem.eql(u8, segs.items[1], "org") and !std.mem.eql(u8, segs.items[1], "user")) return null;
        var tool: std.ArrayList(u8) = .empty;
        for (segs.items[3..], 0..) |seg, i| {
            if (i != 0) tool.append(arena, '.') catch @panic("OOM");
            tool.appendSlice(arena, seg) catch @panic("OOM");
        }
        return .{ segs.items[0], segs.items[1], segs.items[2], tool.items };
    }

    fn loadEntries(self: *ToolsFs, arena: std.mem.Allocator, out: *std.ArrayList(Entry)) void {
        const bytes = self.readFile(arena, CATALOG_INDEX_PATH) orelse return;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, bytes, .{}) catch return;
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        const tools = switch (obj.get("tools") orelse return) {
            .array => |a| a,
            else => return,
        };
        for (tools.items) |item| {
            const tobj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const address = getStr(tobj, "address") orelse continue;
            const integration = getStr(tobj, "integration") orelse continue;
            const sha = getStr(tobj, "sha") orelse continue;
            const split = splitAddress(arena, address) orelse continue;
            if (!std.mem.eql(u8, integration, split[0])) continue;
            out.append(arena, .{
                .address = arena.dupe(u8, address) catch @panic("OOM"),
                .integration = arena.dupe(u8, integration) catch @panic("OOM"),
                .owner = arena.dupe(u8, split[1]) catch @panic("OOM"),
                .connection = arena.dupe(u8, split[2]) catch @panic("OOM"),
                .tool = arena.dupe(u8, split[3]) catch @panic("OOM"),
                .description = arena.dupe(u8, getStr(tobj, "description") orelse "") catch @panic("OOM"),
                .sha = arena.dupe(u8, sha) catch @panic("OOM"),
            }) catch @panic("OOM");
        }
    }

    fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        return switch (obj.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    fn keyMatches(e: Entry, p: [4][]const u8) bool {
        return std.mem.eql(u8, e.integration, p[0]) and
            std.mem.eql(u8, e.owner, p[1]) and
            std.mem.eql(u8, e.connection, p[2]) and
            std.mem.eql(u8, e.tool, p[3]);
    }

    fn findEntry(self: *ToolsFs, arena: std.mem.Allocator, path: []const u8) ?Entry {
        const ps = parts(path);
        if (ps[1] != 4) return null;
        var entries: std.ArrayList(Entry) = .empty;
        self.loadEntries(arena, &entries);
        for (entries.items) |e| if (keyMatches(e, ps[0])) return e;
        return null;
    }

    fn leafBytes(self: *ToolsFs, arena: std.mem.Allocator, entry: Entry) ?[]u8 {
        const shard_path = std.fmt.allocPrint(arena, "{s}/{s}", .{ CATALOG_RECORDS_DIR, entry.sha }) catch @panic("OOM");
        const shard = self.readFile(arena, shard_path) orelse return null;
        const inner = objectInner(shard) orelse return null;
        var out: std.ArrayList(u8) = .empty;
        out.append(arena, '{') catch @panic("OOM");
        appendField(&out, arena, "address", entry.address, true);
        appendField(&out, arena, "integration", entry.integration, false);
        appendField(&out, arena, "owner", entry.owner, false);
        appendField(&out, arena, "connection", entry.connection, false);
        appendField(&out, arena, "tool", entry.tool, false);
        appendField(&out, arena, "description", entry.description, false);
        appendShardFields(&out, arena, inner);
        out.appendSlice(arena, "}\n") catch @panic("OOM");
        return out.items;
    }

    fn objectInner(bytes: []const u8) ?[]const u8 {
        const t = std.mem.trim(u8, bytes, " \n\r\t");
        if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return null;
        return t[1 .. t.len - 1];
    }

    fn appendField(out: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, value: []const u8, first: bool) void {
        if (!first) out.append(a, ',') catch @panic("OOM");
        appendJsonString(out, a, name);
        out.append(a, ':') catch @panic("OOM");
        appendJsonString(out, a, value);
    }

    fn appendJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, value: []const u8) void {
        out.append(a, '"') catch @panic("OOM");
        for (value) |b| switch (b) {
            '"' => out.appendSlice(a, "\\\"") catch @panic("OOM"),
            '\\' => out.appendSlice(a, "\\\\") catch @panic("OOM"),
            '\n' => out.appendSlice(a, "\\n") catch @panic("OOM"),
            '\r' => out.appendSlice(a, "\\r") catch @panic("OOM"),
            '\t' => out.appendSlice(a, "\\t") catch @panic("OOM"),
            else => if (b < 0x20) {
                const escaped = std.fmt.allocPrint(a, "\\u00{x:0>2}", .{b}) catch @panic("OOM");
                out.appendSlice(a, escaped) catch @panic("OOM");
            } else {
                out.append(a, b) catch @panic("OOM");
            },
        };
        out.append(a, '"') catch @panic("OOM");
    }

    fn appendRawField(out: *std.ArrayList(u8), a: std.mem.Allocator, key: []const u8, raw_value: []const u8) void {
        out.append(a, ',') catch @panic("OOM");
        appendJsonString(out, a, key);
        out.append(a, ':') catch @panic("OOM");
        out.appendSlice(a, std.mem.trim(u8, raw_value, " \n\r\t")) catch @panic("OOM");
    }

    fn appendShardFields(out: *std.ArrayList(u8), a: std.mem.Allocator, inner: []const u8) void {
        var fields = ObjectFieldIter.init(inner);
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field.key, "binding")) {
                appendRawField(out, a, "binding", canonicalBinding(a, field.raw_value));
            } else {
                appendRawField(out, a, field.key, field.raw_value);
            }
        }
    }

    fn canonicalBinding(a: std.mem.Allocator, raw: []const u8) []const u8 {
        const t = std.mem.trim(u8, raw, " \n\r\t");
        if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return t;
        var ty: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        var args: ?[]const u8 = null;
        var others: std.ArrayList(ObjectField) = .empty;
        var it = ObjectFieldIter.init(t[1 .. t.len - 1]);
        while (it.next()) |field| {
            if (std.mem.eql(u8, field.key, "type")) {
                ty = field.raw_value;
            } else if (std.mem.eql(u8, field.key, "name")) {
                name = field.raw_value;
            } else if (std.mem.eql(u8, field.key, "args")) {
                args = field.raw_value;
            } else {
                others.append(a, field) catch @panic("OOM");
            }
        }
        var out: std.ArrayList(u8) = .empty;
        out.append(a, '{') catch @panic("OOM");
        var first = true;
        if (ty) |v| appendObjectField(&out, a, "type", v, &first);
        if (name) |v| appendObjectField(&out, a, "name", v, &first);
        if (args) |v| appendObjectField(&out, a, "args", v, &first);
        for (others.items) |field| appendObjectField(&out, a, field.key, field.raw_value, &first);
        out.append(a, '}') catch @panic("OOM");
        return out.items;
    }

    fn appendObjectField(out: *std.ArrayList(u8), a: std.mem.Allocator, key: []const u8, raw_value: []const u8, first: *bool) void {
        if (!first.*) out.append(a, ',') catch @panic("OOM");
        first.* = false;
        appendJsonString(out, a, key);
        out.append(a, ':') catch @panic("OOM");
        out.appendSlice(a, std.mem.trim(u8, raw_value, " \n\r\t")) catch @panic("OOM");
    }

    const ObjectField = struct {
        key: []const u8,
        raw_value: []const u8,
    };

    const ObjectFieldIter = struct {
        bytes: []const u8,
        pos: usize = 0,

        fn init(bytes: []const u8) ObjectFieldIter {
            return .{ .bytes = std.mem.trim(u8, bytes, " \n\r\t") };
        }

        fn skipWs(self: *ObjectFieldIter) void {
            while (self.pos < self.bytes.len and (self.bytes[self.pos] == ' ' or self.bytes[self.pos] == '\n' or self.bytes[self.pos] == '\r' or self.bytes[self.pos] == '\t' or self.bytes[self.pos] == ',')) self.pos += 1;
        }

        fn next(self: *ObjectFieldIter) ?ObjectField {
            self.skipWs();
            if (self.pos >= self.bytes.len or self.bytes[self.pos] != '"') return null;
            self.pos += 1;
            const key_start = self.pos;
            while (self.pos < self.bytes.len and self.bytes[self.pos] != '"') : (self.pos += 1) {
                if (self.bytes[self.pos] == '\\') return null;
            }
            if (self.pos >= self.bytes.len) return null;
            const key = self.bytes[key_start..self.pos];
            self.pos += 1;
            self.skipWs();
            if (self.pos >= self.bytes.len or self.bytes[self.pos] != ':') return null;
            self.pos += 1;
            self.skipWs();
            const value_start = self.pos;
            var depth: i32 = 0;
            var in_string = false;
            var escape = false;
            while (self.pos < self.bytes.len) : (self.pos += 1) {
                const b = self.bytes[self.pos];
                if (in_string) {
                    if (escape) {
                        escape = false;
                    } else if (b == '\\') {
                        escape = true;
                    } else if (b == '"') {
                        in_string = false;
                    }
                    continue;
                }
                switch (b) {
                    '"' => in_string = true,
                    '{', '[' => depth += 1,
                    '}', ']' => {
                        if (depth > 0) depth -= 1;
                    },
                    ',' => if (depth == 0) break,
                    else => {},
                }
            }
            return .{ .key = key, .raw_value = self.bytes[value_start..self.pos] };
        }
    };

    fn open(self: *ToolsFs, _: vfs.CallerId, path: []const u8, flags: OpenFlags) FsError!FileHandle {
        if (flags.write or flags.create or flags.truncate or flags.append) return FsError.PermissionDenied;
        const ps = parts(path);
        if (ps[1] <= 3) return FsError.IsDir;
        if (ps[1] != 4) return FsError.NotFound;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const entry = self.findEntry(arena, path) orelse return FsError.NotFound;
        const data = self.leafBytes(arena, entry) orelse return FsError.NotFound;
        return DataHandle.open(self.gpa, data);
    }

    fn stat(self: *ToolsFs, path: []const u8) FsError!Metadata {
        const ps = parts(path);
        if (ps[1] <= 3) {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            if (self.dirExists(arena_state.allocator(), ps[0], ps[1])) return Metadata.dir();
            return FsError.NotFound;
        }
        if (ps[1] == 4) {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const entry = self.findEntry(arena, path) orelse return FsError.NotFound;
            const data = self.leafBytes(arena, entry) orelse return FsError.NotFound;
            return Metadata.file(data.len);
        }
        return FsError.NotFound;
    }

    fn dirExists(self: *ToolsFs, arena: std.mem.Allocator, p: [4][]const u8, n: usize) bool {
        if (n == 0) return true;
        var entries: std.ArrayList(Entry) = .empty;
        self.loadEntries(arena, &entries);
        for (entries.items) |e| {
            if (n >= 1 and !std.mem.eql(u8, e.integration, p[0])) continue;
            if (n >= 2 and !std.mem.eql(u8, e.owner, p[1])) continue;
            if (n >= 3 and !std.mem.eql(u8, e.connection, p[2])) continue;
            return true;
        }
        return false;
    }

    fn readdir(self: *ToolsFs, _: vfs.CallerId, path: []const u8, arena: std.mem.Allocator, out: *std.ArrayList(vfs.DirEntry)) FsError!void {
        const ps = parts(path);
        if (ps[1] > 3) return if (ps[1] == 4) FsError.NotDir else FsError.NotFound;
        var entries: std.ArrayList(Entry) = .empty;
        self.loadEntries(arena, &entries);
        var seen: std.StringHashMapUnmanaged(vfs.NodeType) = .{};
        for (entries.items) |e| {
            const name: []const u8 = switch (ps[1]) {
                0 => e.integration,
                1 => blk: {
                    if (!std.mem.eql(u8, e.integration, ps[0][0])) continue;
                    break :blk e.owner;
                },
                2 => blk: {
                    if (!std.mem.eql(u8, e.integration, ps[0][0]) or !std.mem.eql(u8, e.owner, ps[0][1])) continue;
                    break :blk e.connection;
                },
                3 => blk: {
                    if (!std.mem.eql(u8, e.integration, ps[0][0]) or !std.mem.eql(u8, e.owner, ps[0][1]) or !std.mem.eql(u8, e.connection, ps[0][2])) continue;
                    break :blk e.tool;
                },
                else => unreachable,
            };
            const kind: vfs.NodeType = if (ps[1] == 3) .file else .dir;
            seen.put(arena, name, kind) catch @panic("OOM");
        }
        if (seen.count() == 0 and ps[1] != 0) return FsError.NotFound;
        var it = seen.iterator();
        while (it.next()) |kv| {
            out.append(arena, .{ .name = arena.dupe(u8, kv.key_ptr.*) catch @panic("OOM"), .node_type = kv.value_ptr.* }) catch @panic("OOM");
        }
    }

    fn deny(_: *ToolsFs, _: vfs.CallerId, _: []const u8) FsError!void {
        return FsError.PermissionDenied;
    }
    fn denyRename(_: *ToolsFs, _: vfs.CallerId, _: []const u8, _: []const u8) FsError!void {
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
    fn self_(p: *anyopaque) *ToolsFs {
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

const DataHandle = struct {
    gpa: std.mem.Allocator,
    data: []u8,
    pos: usize = 0,

    fn open(gpa: std.mem.Allocator, data: []const u8) FileHandle {
        const h = gpa.create(DataHandle) catch @panic("OOM");
        h.* = .{ .gpa = gpa, .data = gpa.dupe(u8, data) catch @panic("OOM") };
        return h.fileHandle();
    }
    fn fileHandle(self: *DataHandle) FileHandle {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn read(self: *DataHandle, out: []u8) FsError!usize {
        const start = @min(self.pos, self.data.len);
        const n = @min(out.len, self.data.len - start);
        if (n != 0) @memcpy(out[0..n], self.data[start .. start + n]);
        self.pos = start + n;
        return n;
    }
    fn write(_: *DataHandle, _: []const u8) FsError!usize {
        return FsError.PermissionDenied;
    }
    fn seek(self: *DataHandle, pos: SeekFrom) FsError!u64 {
        const next = switch (pos) {
            .start => |n| @as(i64, @intCast(n)),
            .current => |n| @as(i64, @intCast(self.pos)) + n,
            .end => |n| @as(i64, @intCast(self.data.len)) + n,
        };
        if (next < 0) return FsError.InvalidPath;
        self.pos = @intCast(next);
        return @intCast(self.pos);
    }
    fn stat(self: *DataHandle) FsError!Metadata {
        return Metadata.file(self.data.len);
    }
    fn truncate(_: *DataHandle, _: u64) FsError!void {
        return FsError.PermissionDenied;
    }
    fn close(self: *DataHandle) void {
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
    fn self_(p: *anyopaque) *DataHandle {
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
