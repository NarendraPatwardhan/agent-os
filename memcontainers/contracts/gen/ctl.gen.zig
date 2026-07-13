// @generated from contracts/control.kdl by //contracts/codegen:projector — do not edit.

const std = @import("std");
pub const WireError = error{ WrongMessage, UnsupportedVersion, Truncated, InvalidUtf8, NonCanonicalMap, InvalidPresence, TrailingBytes };
pub const StringPair = struct { key: []const u8, value: []const u8 };

fn ctlPutU8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u8) !void { try out.append(allocator, v); }
fn ctlPutU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void { try out.append(allocator, @as(u8, @truncate(v))); try out.append(allocator, @as(u8, @truncate(v >> 8))); }
fn ctlPutU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void { try out.append(allocator, @as(u8, @truncate(v))); try out.append(allocator, @as(u8, @truncate(v >> 8))); try out.append(allocator, @as(u8, @truncate(v >> 16))); try out.append(allocator, @as(u8, @truncate(v >> 24))); }
fn ctlPutU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void { var i: u6 = 0; while (i < 8) : (i += 1) try out.append(allocator, @as(u8, @truncate(v >> (i * 8)))); }
fn ctlPutI32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i32) !void { try ctlPutU32(out, allocator, @as(u32, @bitCast(v))); }
fn ctlPutI64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i64) !void { try ctlPutU64(out, allocator, @as(u64, @bitCast(v))); }
fn ctlPutBool(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: bool) !void { try ctlPutU8(out, allocator, if (v) 1 else 0); }
fn ctlPutBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: []const u8) !void { try ctlPutU32(out, allocator, @intCast(v.len)); try out.appendSlice(allocator, v); }
fn ctlPairLess(_: void, a: StringPair, b: StringPair) bool { return std.mem.lessThan(u8, a.key, b.key); }
fn ctlPutStrMap(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: []const StringPair) !void { const pairs = try allocator.dupe(StringPair, v); defer allocator.free(pairs); std.mem.sort(StringPair, pairs, {}, ctlPairLess); try ctlPutU32(out, allocator, @intCast(pairs.len)); var prev: ?[]const u8 = null; for (pairs) |p| { if (prev) |last| { if (std.mem.eql(u8, last, p.key)) return WireError.NonCanonicalMap; } try ctlPutBytes(out, allocator, p.key); try ctlPutBytes(out, allocator, p.value); prev = p.key; } }
fn ctlPutMessageList(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const T) !void { try ctlPutU32(out, allocator, @intCast(values.len)); for (values) |value| { const frame = try value.encode(allocator); defer allocator.free(frame); try ctlPutBytes(out, allocator, frame); } }
fn ctlNeed(bytes: []const u8, off: *usize, len: usize) WireError![]const u8 { const end = off.* + len; if (end < off.* or end > bytes.len) return WireError.Truncated; const out = bytes[off.*..end]; off.* = end; return out; }
fn ctlReadU8(bytes: []const u8, off: *usize) WireError!u8 { return (try ctlNeed(bytes, off, 1))[0]; }
fn ctlReadU16(bytes: []const u8, off: *usize) WireError!u16 { const b = try ctlNeed(bytes, off, 2); return @as(u16, b[0]) | (@as(u16, b[1]) << 8); }
fn ctlReadU32(bytes: []const u8, off: *usize) WireError!u32 { const b = try ctlNeed(bytes, off, 4); return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24); }
fn ctlReadU64(bytes: []const u8, off: *usize) WireError!u64 { const b = try ctlNeed(bytes, off, 8); var out: u64 = 0; var i: u6 = 0; while (i < 8) : (i += 1) out |= @as(u64, b[i]) << (i * 8); return out; }
fn ctlReadI32(bytes: []const u8, off: *usize) WireError!i32 { return @as(i32, @bitCast(try ctlReadU32(bytes, off))); }
fn ctlReadI64(bytes: []const u8, off: *usize) WireError!i64 { return @as(i64, @bitCast(try ctlReadU64(bytes, off))); }
fn ctlReadBool(bytes: []const u8, off: *usize) WireError!bool { return switch (try ctlReadU8(bytes, off)) { 0 => false, 1 => true, else => WireError.InvalidPresence }; }
fn ctlReadBytes(bytes: []const u8, off: *usize) WireError![]const u8 { const len = try ctlReadU32(bytes, off); return ctlNeed(bytes, off, @intCast(len)); }
fn ctlReadStr(bytes: []const u8, off: *usize) WireError![]const u8 { const out = try ctlReadBytes(bytes, off); _ = std.unicode.Utf8View.init(out) catch return WireError.InvalidUtf8; return out; }
fn ctlReadStrMap(allocator: std.mem.Allocator, bytes: []const u8, off: *usize) ![]const StringPair { const n = try ctlReadU32(bytes, off); var out = try allocator.alloc(StringPair, @intCast(n)); errdefer allocator.free(out); var prev: ?[]const u8 = null; var i: usize = 0; while (i < out.len) : (i += 1) { const k = try ctlReadStr(bytes, off); if (prev) |last| { if (!std.mem.lessThan(u8, last, k)) return WireError.NonCanonicalMap; } const v = try ctlReadStr(bytes, off); out[i] = .{ .key = k, .value = v }; prev = k; } return out; }

fn ctlReadMessageList(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, off: *usize) ![]const T { const n = try ctlReadU32(bytes, off); var out = try allocator.alloc(T, @intCast(n)); errdefer allocator.free(out); var i: usize = 0; while (i < out.len) : (i += 1) out[i] = try T.decode(allocator, try ctlReadBytes(bytes, off)); return out; }

// Structured host-control exec request. `cmd` still runs under /bin/sh -c; cwd/env/stdin are applied by the kernel at spawn.
pub const EXEC_REQUEST_MSG_ID: u16 = 1;
pub const EXEC_REQUEST_VERSION: u8 = 1;
pub const ExecRequest = struct {
    cmd: []const u8,
    cwd: ?[]const u8 = null,
    env: []const StringPair,
    stdin: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, EXEC_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, EXEC_REQUEST_VERSION);
        try ctlPutBytes(&out, allocator, self.cmd);
        if (self.cwd) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutStrMap(&out, allocator, self.env);
        if (self.stdin) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != EXEC_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != EXEC_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const cmd = try ctlReadStr(bytes, &off);
        const cwd = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const env = try ctlReadStrMap(allocator, bytes, &off);
        const stdin = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .cmd = cmd,
            .cwd = cwd,
            .env = env,
            .stdin = stdin,
        };
    }
};

// Structured host-control exec result: process exit code plus captured stdout/stderr bytes.
pub const EXEC_OUTCOME_MSG_ID: u16 = 2;
pub const EXEC_OUTCOME_VERSION: u8 = 1;
pub const ExecOutcome = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, EXEC_OUTCOME_MSG_ID);
        try ctlPutU8(&out, allocator, EXEC_OUTCOME_VERSION);
        try ctlPutI32(&out, allocator, self.exit_code);
        try ctlPutBytes(&out, allocator, self.stdout);
        try ctlPutBytes(&out, allocator, self.stderr);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != EXEC_OUTCOME_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != EXEC_OUTCOME_VERSION) return WireError.UnsupportedVersion;
        const exit_code = try ctlReadI32(bytes, &off);
        const stdout = try ctlReadBytes(bytes, &off);
        const stderr = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .exit_code = exit_code,
            .stdout = stdout,
            .stderr = stderr,
        };
    }
};

// Structured host-control stat result. Size is non-negative; hosts reject negative values.
pub const FILE_STAT_MSG_ID: u16 = 3;
pub const FILE_STAT_VERSION: u8 = 1;
pub const FileStat = struct {
    size: i64,
    is_dir: bool,
    is_symlink: bool,
    nlink: u32,
    mode: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, FILE_STAT_MSG_ID);
        try ctlPutU8(&out, allocator, FILE_STAT_VERSION);
        try ctlPutI64(&out, allocator, self.size);
        try ctlPutBool(&out, allocator, self.is_dir);
        try ctlPutBool(&out, allocator, self.is_symlink);
        try ctlPutU32(&out, allocator, self.nlink);
        try ctlPutU32(&out, allocator, self.mode);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != FILE_STAT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != FILE_STAT_VERSION) return WireError.UnsupportedVersion;
        const size = try ctlReadI64(bytes, &off);
        const is_dir = try ctlReadBool(bytes, &off);
        const is_symlink = try ctlReadBool(bytes, &off);
        const nlink = try ctlReadU32(bytes, &off);
        const mode = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .size = size,
            .is_dir = is_dir,
            .is_symlink = is_symlink,
            .nlink = nlink,
            .mode = mode,
        };
    }
};

// One structured host-control directory entry.
pub const DIR_ENTRY_MSG_ID: u16 = 4;
pub const DIR_ENTRY_VERSION: u8 = 1;
pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
    is_symlink: bool,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIR_ENTRY_MSG_ID);
        try ctlPutU8(&out, allocator, DIR_ENTRY_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        try ctlPutBool(&out, allocator, self.is_dir);
        try ctlPutBool(&out, allocator, self.is_symlink);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIR_ENTRY_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIR_ENTRY_VERSION) return WireError.UnsupportedVersion;
        const name = try ctlReadStr(bytes, &off);
        const is_dir = try ctlReadBool(bytes, &off);
        const is_symlink = try ctlReadBool(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = name,
            .is_dir = is_dir,
            .is_symlink = is_symlink,
        };
    }
};

// Structured host-control directory listing.
pub const DIR_ENTRIES_MSG_ID: u16 = 5;
pub const DIR_ENTRIES_VERSION: u8 = 1;
pub const DirEntries = struct {
    entries: []const DirEntry,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIR_ENTRIES_MSG_ID);
        try ctlPutU8(&out, allocator, DIR_ENTRIES_VERSION);
        try ctlPutMessageList(DirEntry, &out, allocator, self.entries);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIR_ENTRIES_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIR_ENTRIES_VERSION) return WireError.UnsupportedVersion;
        const entries = try ctlReadMessageList(DirEntry, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .entries = entries,
        };
    }
};

// Structured host-control resident-service request.
pub const SVC_REQUEST_MSG_ID: u16 = 6;
pub const SVC_REQUEST_VERSION: u8 = 1;
pub const SvcRequest = struct {
    service: []const u8,
    request: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SVC_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, SVC_REQUEST_VERSION);
        try ctlPutBytes(&out, allocator, self.service);
        try ctlPutBytes(&out, allocator, self.request);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SVC_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SVC_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const service = try ctlReadStr(bytes, &off);
        const request = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .service = service,
            .request = request,
        };
    }
};

// Structured host-control resident-service response. Status 0 means the service handled the call; nonzero is a transport errno.
pub const SVC_RESPONSE_MSG_ID: u16 = 7;
pub const SVC_RESPONSE_VERSION: u8 = 1;
pub const SvcResponse = struct {
    status: i32,
    body: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SVC_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, SVC_RESPONSE_VERSION);
        try ctlPutI32(&out, allocator, self.status);
        try ctlPutBytes(&out, allocator, self.body);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SVC_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SVC_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const status = try ctlReadI32(bytes, &off);
        const body = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .status = status,
            .body = body,
        };
    }
};

// Structured BEAM egress relay event. `kind` selects which optional payload fields are present.
pub const RELAY_EVENT_MSG_ID: u16 = 8;
pub const RELAY_EVENT_VERSION: u8 = 1;
pub const RelayEvent = struct {
    kind: []const u8,
    handle: i32,
    request: ?[]const u8 = null,
    name: ?[]const u8 = null,
    body: ?[]const u8 = null,
    key: ?[]const u8 = null,
    value: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    url: ?[]const u8 = null,
    data: ?[]const u8 = null,
    connection: ?[]const u8 = null,
    method: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    args_digest: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RELAY_EVENT_MSG_ID);
        try ctlPutU8(&out, allocator, RELAY_EVENT_VERSION);
        try ctlPutBytes(&out, allocator, self.kind);
        try ctlPutI32(&out, allocator, self.handle);
        if (self.request) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.name) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.body) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.key) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.value) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.prefix) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.url) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.data) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.connection) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.method) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.origin) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.args_digest) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != RELAY_EVENT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RELAY_EVENT_VERSION) return WireError.UnsupportedVersion;
        const kind = try ctlReadStr(bytes, &off);
        const handle = try ctlReadI32(bytes, &off);
        const request = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const name = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const body = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const key = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const value = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const prefix = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const url = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const connection = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const method = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const origin = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const args_digest = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .kind = kind,
            .handle = handle,
            .request = request,
            .name = name,
            .body = body,
            .key = key,
            .value = value,
            .prefix = prefix,
            .url = url,
            .data = data,
            .connection = connection,
            .method = method,
            .origin = origin,
            .args_digest = args_digest,
        };
    }
};


pub const Arg = struct { name: []const u8, ty: []const u8 };
pub const Desc = struct { name: []const u8, variant: []const u8, args: []const Arg, ret: []const u8 };

pub const EXPORTS = [_]Desc{
    .{ .name = "mc_init", .variant = "Init", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_tick", .variant = "Tick", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_input", .variant = "Input", .args = &.{ .{ .name = "ptr", .ty = "cptr" }, .{ .name = "len", .ty = "len" } }, .ret = "void" },
    .{ .name = "mc_resize", .variant = "Resize", .args = &.{ .{ .name = "cols", .ty = "i32" }, .{ .name = "rows", .ty = "i32" } }, .ret = "void" },
    .{ .name = "mc_ctl_buf", .variant = "Buf", .args = &.{ .{ .name = "len", .ty = "len" } }, .ret = "mptr" },
    .{ .name = "mc_ctl_read", .variant = "Read", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_readlink", .variant = "Readlink", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_write", .variant = "Write", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "data_ptr", .ty = "u32" }, .{ .name = "data_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_readdir", .variant = "Readdir", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_stat", .variant = "Stat", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_mkdir", .variant = "Mkdir", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_unlink", .variant = "Unlink", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_chmod", .variant = "Chmod", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "mode", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_symlink", .variant = "Symlink", .args = &.{ .{ .name = "target_ptr", .ty = "u32" }, .{ .name = "target_len", .ty = "u32" }, .{ .name = "link_ptr", .ty = "u32" }, .{ .name = "link_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_mount", .variant = "Mount", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "read_only", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_unmount", .variant = "Unmount", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_start", .variant = "ExecStart", .args = &.{ .{ .name = "request_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_poll", .variant = "ExecPoll", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_peek", .variant = "ExecPeek", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_close", .variant = "ExecClose", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_svc_call_start", .variant = "SvcCallStart", .args = &.{ .{ .name = "request_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_svc_call_poll", .variant = "SvcCallPoll", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_svc_call_close", .variant = "SvcCallClose", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_commit_layer", .variant = "CommitLayer", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_inflight_egress", .variant = "InflightEgress", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_pending_commits", .variant = "PendingCommits", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_quiesce_request", .variant = "QuiesceRequest", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_quiesce_release", .variant = "QuiesceRelease", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_worker_entry", .variant = "WorkerEntry", .args = &.{ .{ .name = "arg", .ty = "i32" } }, .ret = "i32" },
};
