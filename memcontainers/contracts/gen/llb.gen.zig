// @generated from contracts/llb.kdl by //contracts/codegen:projector — do not edit.

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

// One integer edge into a Definition's topologically ordered op array.
pub const BUILD_INPUT_MSG_ID: u16 = 1;
pub const BUILD_INPUT_VERSION: u8 = 1;
pub const BuildInput = struct {
    index: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, BUILD_INPUT_MSG_ID);
        try ctlPutU8(&out, allocator, BUILD_INPUT_VERSION);
        try ctlPutU32(&out, allocator, self.index);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != BUILD_INPUT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != BUILD_INPUT_VERSION) return WireError.UnsupportedVersion;
        const index = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .index = index,
        };
    }
};

// One exact path mapping for a multi-stage copy op.
pub const COPY_PATH_MSG_ID: u16 = 4;
pub const COPY_PATH_VERSION: u8 = 1;
pub const CopyPath = struct {
    src_path: []const u8,
    dest_path: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, COPY_PATH_MSG_ID);
        try ctlPutU8(&out, allocator, COPY_PATH_VERSION);
        try ctlPutBytes(&out, allocator, self.src_path);
        try ctlPutBytes(&out, allocator, self.dest_path);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != COPY_PATH_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != COPY_PATH_VERSION) return WireError.UnsupportedVersion;
        const src_path = try ctlReadStr(bytes, &off);
        const dest_path = try ctlReadStr(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .src_path = src_path,
            .dest_path = dest_path,
        };
    }
};

// One portable LLB op. `kind` is the SDK's closed op enum; unused fields must be absent or empty.
pub const BUILD_OP_MSG_ID: u16 = 2;
pub const BUILD_OP_VERSION: u8 = 1;
pub const BuildOp = struct {
    kind: u32,
    source_ref: ?[]const u8 = null,
    input: ?u32 = null,
    src: ?u32 = null,
    dest: ?u32 = null,
    a: ?u32 = null,
    b: ?u32 = null,
    lower: ?u32 = null,
    upper: ?u32 = null,
    parts: []const BuildInput,
    copy_paths: []const CopyPath,
    path: ?[]const u8 = null,
    local_path: ?[]const u8 = null,
    http_url: ?[]const u8 = null,
    expected_digest: ?[]const u8 = null,
    git_repo: ?[]const u8 = null,
    git_ref: ?[]const u8 = null,
    dest_path: ?[]const u8 = null,
    data_digest: ?[]const u8 = null,
    target: ?[]const u8 = null,
    link: ?[]const u8 = null,
    mode: ?u32 = null,
    cmd: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: []const StringPair,
    stdin: ?[]const u8 = null,
    tier: ?[]const u8 = null,
    budget_mib: ?u32 = null,
    fuel: ?u32 = null,
    deterministic: ?bool = null,
    net: ?bool = null,
    mounts: []const BuildInput,
    config_tier: ?[]const u8 = null,
    config_budget_mib: ?u32 = null,
    config_fuel: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, BUILD_OP_MSG_ID);
        try ctlPutU8(&out, allocator, BUILD_OP_VERSION);
        try ctlPutU32(&out, allocator, self.kind);
        if (self.source_ref) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.input) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.src) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.dest) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.a) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.b) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.lower) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.upper) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutMessageList(BuildInput, &out, allocator, self.parts);
        try ctlPutMessageList(CopyPath, &out, allocator, self.copy_paths);
        if (self.path) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.local_path) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.http_url) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.expected_digest) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.git_repo) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.git_ref) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.dest_path) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.data_digest) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.target) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.link) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.mode) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.cmd) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
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
        if (self.tier) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.budget_mib) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.fuel) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.deterministic) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBool(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.net) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBool(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutMessageList(BuildInput, &out, allocator, self.mounts);
        if (self.config_tier) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.config_budget_mib) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.config_fuel) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != BUILD_OP_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != BUILD_OP_VERSION) return WireError.UnsupportedVersion;
        const kind = try ctlReadU32(bytes, &off);
        const source_ref = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const input = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const src = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const dest = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const a = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const b = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const lower = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const upper = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const parts = try ctlReadMessageList(BuildInput, allocator, bytes, &off);
        const copy_paths = try ctlReadMessageList(CopyPath, allocator, bytes, &off);
        const path = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const local_path = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const http_url = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const expected_digest = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const git_repo = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const git_ref = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const dest_path = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const data_digest = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const target = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const link = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const mode = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const cmd = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
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
        const tier = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const budget_mib = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const fuel = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const deterministic = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBool(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const net = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBool(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const mounts = try ctlReadMessageList(BuildInput, allocator, bytes, &off);
        const config_tier = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const config_budget_mib = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const config_fuel = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .kind = kind,
            .source_ref = source_ref,
            .input = input,
            .src = src,
            .dest = dest,
            .a = a,
            .b = b,
            .lower = lower,
            .upper = upper,
            .parts = parts,
            .copy_paths = copy_paths,
            .path = path,
            .local_path = local_path,
            .http_url = http_url,
            .expected_digest = expected_digest,
            .git_repo = git_repo,
            .git_ref = git_ref,
            .dest_path = dest_path,
            .data_digest = data_digest,
            .target = target,
            .link = link,
            .mode = mode,
            .cmd = cmd,
            .cwd = cwd,
            .env = env,
            .stdin = stdin,
            .tier = tier,
            .budget_mib = budget_mib,
            .fuel = fuel,
            .deterministic = deterministic,
            .net = net,
            .mounts = mounts,
            .config_tier = config_tier,
            .config_budget_mib = config_budget_mib,
            .config_fuel = config_fuel,
        };
    }
};

// One resolved input edge for a cache-key node digest. Roles are stable names such as input, src, dest, or part:0.
pub const DIGEST_EDGE_MSG_ID: u16 = 5;
pub const DIGEST_EDGE_VERSION: u8 = 1;
pub const DigestEdge = struct {
    role: []const u8,
    digest: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIGEST_EDGE_MSG_ID);
        try ctlPutU8(&out, allocator, DIGEST_EDGE_VERSION);
        try ctlPutBytes(&out, allocator, self.role);
        try ctlPutBytes(&out, allocator, self.digest);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIGEST_EDGE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIGEST_EDGE_VERSION) return WireError.UnsupportedVersion;
        const role = try ctlReadStr(bytes, &off);
        const digest = try ctlReadStr(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .role = role,
            .digest = digest,
        };
    }
};

// Resolved layer metadata folded into source-node cache keys.
pub const LAYER_REF_MSG_ID: u16 = 6;
pub const LAYER_REF_VERSION: u8 = 1;
pub const LayerRef = struct {
    producer: []const u8,
    digest: []const u8,
    size: i64,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, LAYER_REF_MSG_ID);
        try ctlPutU8(&out, allocator, LAYER_REF_VERSION);
        try ctlPutBytes(&out, allocator, self.producer);
        try ctlPutBytes(&out, allocator, self.digest);
        try ctlPutI64(&out, allocator, self.size);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != LAYER_REF_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != LAYER_REF_VERSION) return WireError.UnsupportedVersion;
        const producer = try ctlReadStr(bytes, &off);
        const digest = try ctlReadStr(bytes, &off);
        const size = try ctlReadI64(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .producer = producer,
            .digest = digest,
            .size = size,
        };
    }
};

// Canonical cache-key input for one solved LLB vertex: op args, child digests, resolved mutable-source facts, source layers, and kernel identity when a VM is booted.
pub const NODE_DIGEST_MSG_ID: u16 = 7;
pub const NODE_DIGEST_VERSION: u8 = 1;
pub const NodeDigest = struct {
    op: BuildOp,
    edges: []const DigestEdge,
    resolved: []const StringPair,
    layers: []const LayerRef,
    kernel_digest: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, NODE_DIGEST_MSG_ID);
        try ctlPutU8(&out, allocator, NODE_DIGEST_VERSION);
        {
            const frame = try self.op.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        try ctlPutMessageList(DigestEdge, &out, allocator, self.edges);
        try ctlPutStrMap(&out, allocator, self.resolved);
        try ctlPutMessageList(LayerRef, &out, allocator, self.layers);
        if (self.kernel_digest) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != NODE_DIGEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != NODE_DIGEST_VERSION) return WireError.UnsupportedVersion;
        const op = try BuildOp.decode(allocator, try ctlReadBytes(bytes, &off));
        const edges = try ctlReadMessageList(DigestEdge, allocator, bytes, &off);
        const resolved = try ctlReadStrMap(allocator, bytes, &off);
        const layers = try ctlReadMessageList(LayerRef, allocator, bytes, &off);
        const kernel_digest = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .op = op,
            .edges = edges,
            .resolved = resolved,
            .layers = layers,
            .kernel_digest = kernel_digest,
        };
    }
};

// A portable LLB build graph. `root` indexes into `ops`; edges only point at earlier ops.
pub const DEFINITION_MSG_ID: u16 = 3;
pub const DEFINITION_VERSION: u8 = 1;
pub const Definition = struct {
    version: u32,
    ops: []const BuildOp,
    root: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DEFINITION_MSG_ID);
        try ctlPutU8(&out, allocator, DEFINITION_VERSION);
        try ctlPutU32(&out, allocator, self.version);
        try ctlPutMessageList(BuildOp, &out, allocator, self.ops);
        try ctlPutU32(&out, allocator, self.root);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DEFINITION_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DEFINITION_VERSION) return WireError.UnsupportedVersion;
        const version = try ctlReadU32(bytes, &off);
        const ops = try ctlReadMessageList(BuildOp, allocator, bytes, &off);
        const root = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .version = version,
            .ops = ops,
            .root = root,
        };
    }
};
