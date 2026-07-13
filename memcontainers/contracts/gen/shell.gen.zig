// @generated from contracts/shell.kdl by //contracts/codegen:projector — do not edit.

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

pub const CANDIDATE_MSG_ID: u16 = 1;
pub const CANDIDATE_VERSION: u8 = 1;
pub const Candidate = struct {
    value: []const u8,
    kind: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, CANDIDATE_MSG_ID);
        try ctlPutU8(&out, allocator, CANDIDATE_VERSION);
        try ctlPutBytes(&out, allocator, self.value);
        try ctlPutBytes(&out, allocator, self.kind);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != CANDIDATE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != CANDIDATE_VERSION) return WireError.UnsupportedVersion;
        const value = try ctlReadStr(bytes, &off);
        const kind = try ctlReadStr(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .value = value,
            .kind = kind,
        };
    }
};

pub const PROBE_REQUEST_MSG_ID: u16 = 2;
pub const PROBE_REQUEST_VERSION: u8 = 1;
pub const ProbeRequest = struct {
    source: []const u8,
    cursor: u32,
    interactive: bool,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, PROBE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, PROBE_REQUEST_VERSION);
        try ctlPutBytes(&out, allocator, self.source);
        try ctlPutU32(&out, allocator, self.cursor);
        try ctlPutBool(&out, allocator, self.interactive);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != PROBE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != PROBE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const source = try ctlReadBytes(bytes, &off);
        const cursor = try ctlReadU32(bytes, &off);
        const interactive = try ctlReadBool(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .source = source,
            .cursor = cursor,
            .interactive = interactive,
        };
    }
};

pub const PROBE_RESPONSE_MSG_ID: u16 = 3;
pub const PROBE_RESPONSE_VERSION: u8 = 1;
pub const ProbeResponse = struct {
    replace_start: u32,
    replace_end: u32,
    prefix: []const u8,
    context: []const u8,
    quote: []const u8,
    shell_candidates: []const Candidate,
    truncated: bool,
    continuation: bool,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, PROBE_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, PROBE_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.replace_start);
        try ctlPutU32(&out, allocator, self.replace_end);
        try ctlPutBytes(&out, allocator, self.prefix);
        try ctlPutBytes(&out, allocator, self.context);
        try ctlPutBytes(&out, allocator, self.quote);
        try ctlPutMessageList(Candidate, &out, allocator, self.shell_candidates);
        try ctlPutBool(&out, allocator, self.truncated);
        try ctlPutBool(&out, allocator, self.continuation);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != PROBE_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != PROBE_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const replace_start = try ctlReadU32(bytes, &off);
        const replace_end = try ctlReadU32(bytes, &off);
        const prefix = try ctlReadStr(bytes, &off);
        const context = try ctlReadStr(bytes, &off);
        const quote = try ctlReadStr(bytes, &off);
        const shell_candidates = try ctlReadMessageList(Candidate, allocator, bytes, &off);
        const truncated = try ctlReadBool(bytes, &off);
        const continuation = try ctlReadBool(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .replace_start = replace_start,
            .replace_end = replace_end,
            .prefix = prefix,
            .context = context,
            .quote = quote,
            .shell_candidates = shell_candidates,
            .truncated = truncated,
            .continuation = continuation,
        };
    }
};

pub const RENDER_REQUEST_MSG_ID: u16 = 4;
pub const RENDER_REQUEST_VERSION: u8 = 1;
pub const RenderRequest = struct {
    replace_start: u32,
    replace_end: u32,
    quote: []const u8,
    candidates: []const Candidate,
    truncated: bool,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RENDER_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, RENDER_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.replace_start);
        try ctlPutU32(&out, allocator, self.replace_end);
        try ctlPutBytes(&out, allocator, self.quote);
        try ctlPutMessageList(Candidate, &out, allocator, self.candidates);
        try ctlPutBool(&out, allocator, self.truncated);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != RENDER_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RENDER_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const replace_start = try ctlReadU32(bytes, &off);
        const replace_end = try ctlReadU32(bytes, &off);
        const quote = try ctlReadStr(bytes, &off);
        const candidates = try ctlReadMessageList(Candidate, allocator, bytes, &off);
        const truncated = try ctlReadBool(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .replace_start = replace_start,
            .replace_end = replace_end,
            .quote = quote,
            .candidates = candidates,
            .truncated = truncated,
        };
    }
};

pub const ITEM_MSG_ID: u16 = 5;
pub const ITEM_VERSION: u8 = 1;
pub const Item = struct {
    label: []const u8,
    value: []const u8,
    kind: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, ITEM_MSG_ID);
        try ctlPutU8(&out, allocator, ITEM_VERSION);
        try ctlPutBytes(&out, allocator, self.label);
        try ctlPutBytes(&out, allocator, self.value);
        try ctlPutBytes(&out, allocator, self.kind);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != ITEM_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != ITEM_VERSION) return WireError.UnsupportedVersion;
        const label = try ctlReadStr(bytes, &off);
        const value = try ctlReadStr(bytes, &off);
        const kind = try ctlReadStr(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .label = label,
            .value = value,
            .kind = kind,
        };
    }
};

pub const COMPLETION_RESULT_MSG_ID: u16 = 6;
pub const COMPLETION_RESULT_VERSION: u8 = 1;
pub const CompletionResult = struct {
    replace_start: u32,
    replace_end: u32,
    common_prefix: []const u8,
    items: []const Item,
    truncated: bool,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, COMPLETION_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, COMPLETION_RESULT_VERSION);
        try ctlPutU32(&out, allocator, self.replace_start);
        try ctlPutU32(&out, allocator, self.replace_end);
        try ctlPutBytes(&out, allocator, self.common_prefix);
        try ctlPutMessageList(Item, &out, allocator, self.items);
        try ctlPutBool(&out, allocator, self.truncated);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != COMPLETION_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != COMPLETION_RESULT_VERSION) return WireError.UnsupportedVersion;
        const replace_start = try ctlReadU32(bytes, &off);
        const replace_end = try ctlReadU32(bytes, &off);
        const common_prefix = try ctlReadStr(bytes, &off);
        const items = try ctlReadMessageList(Item, allocator, bytes, &off);
        const truncated = try ctlReadBool(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .replace_start = replace_start,
            .replace_end = replace_end,
            .common_prefix = common_prefix,
            .items = items,
            .truncated = truncated,
        };
    }
};


pub const Arg = struct { name: []const u8, ty: []const u8 };
pub const Desc = struct { name: []const u8, variant: []const u8, args: []const Arg, ret: []const u8 };

pub const EXPORTS = [_]Desc{
    .{ .name = "mc_sh_buf", .variant = "ShBuf", .args = &.{ .{ .name = "len", .ty = "u32" } }, .ret = "u32" },
    .{ .name = "mc_sh_autocomplete", .variant = "ShAutocomplete", .args = &.{ .{ .name = "request_len", .ty = "u32" } }, .ret = "i32" },
};
pub const CONTEXT_COMMAND: []const u8 = "command";
pub const CONTEXT_PATH: []const u8 = "path";
pub const CONTEXT_DIRECTORY: []const u8 = "directory";
pub const CONTEXT_VARIABLE: []const u8 = "variable";
pub const QUOTE_BARE: []const u8 = "bare";
pub const QUOTE_SINGLE: []const u8 = "single";
pub const QUOTE_DOUBLE: []const u8 = "double";
