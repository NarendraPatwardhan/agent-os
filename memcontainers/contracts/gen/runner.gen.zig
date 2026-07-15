// @generated from contracts/runner.kdl by //contracts/codegen:projector — do not edit.
pub const PROTOCOL_VERSION: u32 = 1;
pub const RUNNER_MAX_FRAME_BYTES: u32 = 8392704;
pub const RUNNER_DEFAULT_VSOCK_PORT: u32 = 52;
pub const RUNNER_HEALTH_KIND: []const u8 = "agentos.health.v1";
pub const RUNNER_HEALTH_CONTRACT_DIGEST: []const u8 = "sha256:515a069b3ebe4d7e6fbb23496b4e71908ad2b5046b00345b3cfe833c4ea82339";


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

pub const RUNNER_HELLO_MSG_ID: u16 = 1;
pub const RUNNER_HELLO_VERSION: u8 = 1;
pub const RunnerHello = struct {
    protocol_version: u32,
    agent: []const u8,
    kind: []const u8,
    version: u32,
    contract_digest: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RUNNER_HELLO_MSG_ID);
        try ctlPutU8(&out, allocator, RUNNER_HELLO_VERSION);
        try ctlPutU32(&out, allocator, self.protocol_version);
        try ctlPutBytes(&out, allocator, self.agent);
        try ctlPutBytes(&out, allocator, self.kind);
        try ctlPutU32(&out, allocator, self.version);
        try ctlPutBytes(&out, allocator, self.contract_digest);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != RUNNER_HELLO_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RUNNER_HELLO_VERSION) return WireError.UnsupportedVersion;
        const protocol_version = try ctlReadU32(bytes, &off);
        const agent = try ctlReadStr(bytes, &off);
        const kind = try ctlReadStr(bytes, &off);
        const version = try ctlReadU32(bytes, &off);
        const contract_digest = try ctlReadStr(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .protocol_version = protocol_version,
            .agent = agent,
            .kind = kind,
            .version = version,
            .contract_digest = contract_digest,
        };
    }
};

pub const RUNNER_REQUEST_MSG_ID: u16 = 2;
pub const RUNNER_REQUEST_VERSION: u8 = 1;
pub const RunnerRequest = struct {
    request_id: []const u8,
    kind: []const u8,
    operation: []const u8,
    body: []const u8,
    timeout_ms: i64,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RUNNER_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, RUNNER_REQUEST_VERSION);
        try ctlPutBytes(&out, allocator, self.request_id);
        try ctlPutBytes(&out, allocator, self.kind);
        try ctlPutBytes(&out, allocator, self.operation);
        try ctlPutBytes(&out, allocator, self.body);
        try ctlPutI64(&out, allocator, self.timeout_ms);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != RUNNER_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RUNNER_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const request_id = try ctlReadStr(bytes, &off);
        const kind = try ctlReadStr(bytes, &off);
        const operation = try ctlReadStr(bytes, &off);
        const body = try ctlReadBytes(bytes, &off);
        const timeout_ms = try ctlReadI64(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .request_id = request_id,
            .kind = kind,
            .operation = operation,
            .body = body,
            .timeout_ms = timeout_ms,
        };
    }
};

pub const RUNNER_RESPONSE_MSG_ID: u16 = 3;
pub const RUNNER_RESPONSE_VERSION: u8 = 1;
pub const RunnerResponse = struct {
    request_id: []const u8,
    ok: bool,
    body: []const u8,
    error_code: ?[]const u8 = null,
    error_message: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RUNNER_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, RUNNER_RESPONSE_VERSION);
        try ctlPutBytes(&out, allocator, self.request_id);
        try ctlPutBool(&out, allocator, self.ok);
        try ctlPutBytes(&out, allocator, self.body);
        if (self.error_code) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.error_message) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != RUNNER_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RUNNER_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const request_id = try ctlReadStr(bytes, &off);
        const ok = try ctlReadBool(bytes, &off);
        const body = try ctlReadBytes(bytes, &off);
        const error_code = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const error_message = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .request_id = request_id,
            .ok = ok,
            .body = body,
            .error_code = error_code,
            .error_message = error_message,
        };
    }
};
