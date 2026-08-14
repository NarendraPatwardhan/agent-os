// @generated from contracts/syntax.kdl by //contracts/codegen:projector — do not edit.
pub const PROTOCOL_VERSION: u32 = 1;
pub const VOCABULARY_VERSION: u32 = 1;
pub const GRAMMAR_IR_VERSION: u32 = 2;
pub const SEMANTIC_KIND_MODULE: u32 = 1;
pub const SEMANTIC_KIND_DECLARATION: u32 = 2;
pub const SEMANTIC_KIND_FUNCTION: u32 = 3;
pub const SEMANTIC_KIND_PARAMETER: u32 = 4;
pub const SEMANTIC_KIND_CALL: u32 = 5;
pub const SEMANTIC_KIND_MEMBER: u32 = 6;
pub const SEMANTIC_KIND_IDENTIFIER: u32 = 7;
pub const SEMANTIC_KIND_LITERAL: u32 = 8;
pub const SEMANTIC_KIND_TYPE: u32 = 9;
pub const SEMANTIC_KIND_BLOCK: u32 = 10;
pub const SEMANTIC_KIND_ASSIGNMENT: u32 = 11;
pub const SEMANTIC_KIND_BRANCH: u32 = 12;
pub const SEMANTIC_KIND_LOOP: u32 = 13;
pub const SEMANTIC_KIND_RETURN: u32 = 14;
pub const SEMANTIC_KIND_IMPORT: u32 = 15;
pub const SEMANTIC_KIND_TABLE: u32 = 16;
pub const SEMANTIC_KIND_FIELD: u32 = 17;
pub const SEMANTIC_KIND_OPERATOR: u32 = 18;
pub const SEMANTIC_KIND_COMMENT: u32 = 19;
pub const SEMANTIC_ROLE_NAME: u32 = 1;
pub const SEMANTIC_ROLE_BODY: u32 = 2;
pub const SEMANTIC_ROLE_PARAMETERS: u32 = 3;
pub const SEMANTIC_ROLE_RECEIVER: u32 = 4;
pub const SEMANTIC_ROLE_ARGUMENTS: u32 = 5;
pub const SEMANTIC_ROLE_CALLEE: u32 = 6;
pub const SEMANTIC_ROLE_LEFT: u32 = 7;
pub const SEMANTIC_ROLE_RIGHT: u32 = 8;
pub const SEMANTIC_ROLE_CONDITION: u32 = 9;
pub const SEMANTIC_ROLE_RETURN_TYPE: u32 = 10;
pub const SEMANTIC_ROLE_VALUE: u32 = 11;
pub const SEMANTIC_ROLE_SOURCE: u32 = 12;
pub const SEMANTIC_TRAIT_DECLARATION: u32 = 1;
pub const SEMANTIC_TRAIT_SCOPE: u32 = 2;


const std = @import("std");
pub const WireError = error{ WrongMessage, UnsupportedVersion, Truncated, InvalidUtf8, NonCanonicalMap, InvalidPresence, TrailingBytes, LimitExceeded };
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

pub const POINT_MSG_ID: u16 = 1;
pub const POINT_VERSION: u8 = 1;
pub const Point = struct {
    row: u32,
    column: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, POINT_MSG_ID);
        try ctlPutU8(&out, allocator, POINT_VERSION);
        try ctlPutU32(&out, allocator, self.row);
        try ctlPutU32(&out, allocator, self.column);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != POINT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != POINT_VERSION) return WireError.UnsupportedVersion;
        const decoded_row = try ctlReadU32(bytes, &off);
        const decoded_column = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .row = decoded_row,
            .column = decoded_column,
        };
    }
};

pub const RANGE_MSG_ID: u16 = 2;
pub const RANGE_VERSION: u8 = 1;
pub const Range = struct {
    start_byte: u32,
    end_byte: u32,
    start_point: Point,
    end_point: Point,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RANGE_MSG_ID);
        try ctlPutU8(&out, allocator, RANGE_VERSION);
        try ctlPutU32(&out, allocator, self.start_byte);
        try ctlPutU32(&out, allocator, self.end_byte);
        {
            const frame = try self.start_point.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        {
            const frame = try self.end_point.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != RANGE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RANGE_VERSION) return WireError.UnsupportedVersion;
        const decoded_start_byte = try ctlReadU32(bytes, &off);
        const decoded_end_byte = try ctlReadU32(bytes, &off);
        const decoded_start_point = try Point.decode(allocator, try ctlReadBytes(bytes, &off));
        const decoded_end_point = try Point.decode(allocator, try ctlReadBytes(bytes, &off));
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .start_byte = decoded_start_byte,
            .end_byte = decoded_end_byte,
            .start_point = decoded_start_point,
            .end_point = decoded_end_point,
        };
    }
};

pub const SEMANTIC_TRAIT_MSG_ID: u16 = 3;
pub const SEMANTIC_TRAIT_VERSION: u8 = 1;
pub const SemanticTrait = struct {
    id: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SEMANTIC_TRAIT_MSG_ID);
        try ctlPutU8(&out, allocator, SEMANTIC_TRAIT_VERSION);
        try ctlPutU32(&out, allocator, self.id);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SEMANTIC_TRAIT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SEMANTIC_TRAIT_VERSION) return WireError.UnsupportedVersion;
        const decoded_id = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .id = decoded_id,
        };
    }
};

pub const DIAGNOSTIC_MSG_ID: u16 = 4;
pub const DIAGNOSTIC_VERSION: u8 = 1;
pub const Diagnostic = struct {
    severity: []const u8,
    code: []const u8,
    message: []const u8,
    range: ?Range = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIAGNOSTIC_MSG_ID);
        try ctlPutU8(&out, allocator, DIAGNOSTIC_VERSION);
        try ctlPutBytes(&out, allocator, self.severity);
        try ctlPutBytes(&out, allocator, self.code);
        try ctlPutBytes(&out, allocator, self.message);
        if (self.range) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIAGNOSTIC_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIAGNOSTIC_VERSION) return WireError.UnsupportedVersion;
        const decoded_severity = try ctlReadStr(bytes, &off);
        const decoded_code = try ctlReadStr(bytes, &off);
        const decoded_message = try ctlReadStr(bytes, &off);
        const decoded_range = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try Range.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .severity = decoded_severity,
            .code = decoded_code,
            .message = decoded_message,
            .range = decoded_range,
        };
    }
};

pub const LANGUAGE_DESCRIPTOR_MSG_ID: u16 = 5;
pub const LANGUAGE_DESCRIPTOR_VERSION: u8 = 1;
pub const LanguageDescriptor = struct {
    name: []const u8,
    language_version: []const u8,
    grammar_version: []const u8,
    grammar_ir_version: u32,
    vocabulary_version: u32,
    tree_sitter_abi: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, LANGUAGE_DESCRIPTOR_MSG_ID);
        try ctlPutU8(&out, allocator, LANGUAGE_DESCRIPTOR_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        try ctlPutBytes(&out, allocator, self.language_version);
        try ctlPutBytes(&out, allocator, self.grammar_version);
        try ctlPutU32(&out, allocator, self.grammar_ir_version);
        try ctlPutU32(&out, allocator, self.vocabulary_version);
        try ctlPutU32(&out, allocator, self.tree_sitter_abi);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != LANGUAGE_DESCRIPTOR_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != LANGUAGE_DESCRIPTOR_VERSION) return WireError.UnsupportedVersion;
        const decoded_name = try ctlReadStr(bytes, &off);
        const decoded_language_version = try ctlReadStr(bytes, &off);
        const decoded_grammar_version = try ctlReadStr(bytes, &off);
        const decoded_grammar_ir_version = try ctlReadU32(bytes, &off);
        const decoded_vocabulary_version = try ctlReadU32(bytes, &off);
        const decoded_tree_sitter_abi = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = decoded_name,
            .language_version = decoded_language_version,
            .grammar_version = decoded_grammar_version,
            .grammar_ir_version = decoded_grammar_ir_version,
            .vocabulary_version = decoded_vocabulary_version,
            .tree_sitter_abi = decoded_tree_sitter_abi,
        };
    }
};

pub const NODE_SUMMARY_MSG_ID: u16 = 6;
pub const NODE_SUMMARY_VERSION: u8 = 1;
pub const NodeSummary = struct {
    handle: u32,
    concrete_kind: []const u8,
    semantic_kind: ?u32 = null,
    field_role: ?u32 = null,
    range: Range,
    named: bool,
    missing: bool,
    @"error": bool,
    child_count: u32,
    traits: []const SemanticTrait,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, NODE_SUMMARY_MSG_ID);
        try ctlPutU8(&out, allocator, NODE_SUMMARY_VERSION);
        try ctlPutU32(&out, allocator, self.handle);
        try ctlPutBytes(&out, allocator, self.concrete_kind);
        if (self.semantic_kind) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.field_role) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        {
            const frame = try self.range.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        try ctlPutBool(&out, allocator, self.named);
        try ctlPutBool(&out, allocator, self.missing);
        try ctlPutBool(&out, allocator, self.@"error");
        try ctlPutU32(&out, allocator, self.child_count);
        try ctlPutMessageList(SemanticTrait, &out, allocator, self.traits);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != NODE_SUMMARY_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != NODE_SUMMARY_VERSION) return WireError.UnsupportedVersion;
        const decoded_handle = try ctlReadU32(bytes, &off);
        const decoded_concrete_kind = try ctlReadStr(bytes, &off);
        const decoded_semantic_kind = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_field_role = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_range = try Range.decode(allocator, try ctlReadBytes(bytes, &off));
        const decoded_named = try ctlReadBool(bytes, &off);
        const decoded_missing = try ctlReadBool(bytes, &off);
        const decoded_error_value = try ctlReadBool(bytes, &off);
        const decoded_child_count = try ctlReadU32(bytes, &off);
        const decoded_traits = try ctlReadMessageList(SemanticTrait, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .handle = decoded_handle,
            .concrete_kind = decoded_concrete_kind,
            .semantic_kind = decoded_semantic_kind,
            .field_role = decoded_field_role,
            .range = decoded_range,
            .named = decoded_named,
            .missing = decoded_missing,
            .@"error" = decoded_error_value,
            .child_count = decoded_child_count,
            .traits = decoded_traits,
        };
    }
};

pub const CHANGED_RANGE_MSG_ID: u16 = 7;
pub const CHANGED_RANGE_VERSION: u8 = 1;
pub const ChangedRange = struct {
    range: Range,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, CHANGED_RANGE_MSG_ID);
        try ctlPutU8(&out, allocator, CHANGED_RANGE_VERSION);
        {
            const frame = try self.range.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != CHANGED_RANGE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != CHANGED_RANGE_VERSION) return WireError.UnsupportedVersion;
        const decoded_range = try Range.decode(allocator, try ctlReadBytes(bytes, &off));
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .range = decoded_range,
        };
    }
};

pub const EDIT_MSG_ID: u16 = 8;
pub const EDIT_VERSION: u8 = 1;
pub const Edit = struct {
    start_byte: u32,
    old_end_byte: u32,
    replacement: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, EDIT_MSG_ID);
        try ctlPutU8(&out, allocator, EDIT_VERSION);
        try ctlPutU32(&out, allocator, self.start_byte);
        try ctlPutU32(&out, allocator, self.old_end_byte);
        try ctlPutBytes(&out, allocator, self.replacement);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != EDIT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != EDIT_VERSION) return WireError.UnsupportedVersion;
        const decoded_start_byte = try ctlReadU32(bytes, &off);
        const decoded_old_end_byte = try ctlReadU32(bytes, &off);
        const decoded_replacement = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .start_byte = decoded_start_byte,
            .old_end_byte = decoded_old_end_byte,
            .replacement = decoded_replacement,
        };
    }
};

pub const REWRITE_EDIT_MSG_ID: u16 = 9;
pub const REWRITE_EDIT_VERSION: u8 = 1;
pub const RewriteEdit = struct {
    start_byte: u32,
    old_end_byte: u32,
    expected_sha256: []const u8,
    replacement: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REWRITE_EDIT_MSG_ID);
        try ctlPutU8(&out, allocator, REWRITE_EDIT_VERSION);
        try ctlPutU32(&out, allocator, self.start_byte);
        try ctlPutU32(&out, allocator, self.old_end_byte);
        try ctlPutBytes(&out, allocator, self.expected_sha256);
        try ctlPutBytes(&out, allocator, self.replacement);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REWRITE_EDIT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REWRITE_EDIT_VERSION) return WireError.UnsupportedVersion;
        const decoded_start_byte = try ctlReadU32(bytes, &off);
        const decoded_old_end_byte = try ctlReadU32(bytes, &off);
        const decoded_expected_sha256 = try ctlReadBytes(bytes, &off);
        const decoded_replacement = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .start_byte = decoded_start_byte,
            .old_end_byte = decoded_old_end_byte,
            .expected_sha256 = decoded_expected_sha256,
            .replacement = decoded_replacement,
        };
    }
};

pub const CAPTURE_MSG_ID: u16 = 10;
pub const CAPTURE_VERSION: u8 = 1;
pub const Capture = struct {
    name: []const u8,
    node: NodeSummary,
    text: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, CAPTURE_MSG_ID);
        try ctlPutU8(&out, allocator, CAPTURE_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        {
            const frame = try self.node.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        if (self.text) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != CAPTURE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != CAPTURE_VERSION) return WireError.UnsupportedVersion;
        const decoded_name = try ctlReadStr(bytes, &off);
        const decoded_node = try NodeSummary.decode(allocator, try ctlReadBytes(bytes, &off));
        const decoded_text = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = decoded_name,
            .node = decoded_node,
            .text = decoded_text,
        };
    }
};

pub const LANGUAGES_REQUEST_MSG_ID: u16 = 100;
pub const LANGUAGES_REQUEST_VERSION: u8 = 1;
pub const LanguagesRequest = struct {
    reserved: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, LANGUAGES_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, LANGUAGES_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.reserved);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != LANGUAGES_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != LANGUAGES_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_reserved = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .reserved = decoded_reserved,
        };
    }
};

pub const OPEN_REQUEST_MSG_ID: u16 = 101;
pub const OPEN_REQUEST_VERSION: u8 = 1;
pub const OpenRequest = struct {
    language: []const u8,
    source: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, OPEN_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, OPEN_REQUEST_VERSION);
        try ctlPutBytes(&out, allocator, self.language);
        try ctlPutBytes(&out, allocator, self.source);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != OPEN_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != OPEN_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_language = try ctlReadStr(bytes, &off);
        const decoded_source = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .language = decoded_language,
            .source = decoded_source,
        };
    }
};

pub const CLOSE_REQUEST_MSG_ID: u16 = 102;
pub const CLOSE_REQUEST_VERSION: u8 = 1;
pub const CloseRequest = struct {
    document: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, CLOSE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, CLOSE_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != CLOSE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != CLOSE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
        };
    }
};

pub const TREE_REQUEST_MSG_ID: u16 = 103;
pub const TREE_REQUEST_VERSION: u8 = 1;
pub const TreeRequest = struct {
    document: u32,
    revision: u32,
    view: []const u8,
    max_depth: u32,
    limit: u32,
    cursor: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, TREE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, TREE_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutBytes(&out, allocator, self.view);
        try ctlPutU32(&out, allocator, self.max_depth);
        try ctlPutU32(&out, allocator, self.limit);
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != TREE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != TREE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_view = try ctlReadStr(bytes, &off);
        const decoded_max_depth = try ctlReadU32(bytes, &off);
        const decoded_limit = try ctlReadU32(bytes, &off);
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .view = decoded_view,
            .max_depth = decoded_max_depth,
            .limit = decoded_limit,
            .cursor = decoded_cursor,
        };
    }
};

pub const NODE_REQUEST_MSG_ID: u16 = 104;
pub const NODE_REQUEST_VERSION: u8 = 1;
pub const NodeRequest = struct {
    document: u32,
    revision: u32,
    node: u32,
    view: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, NODE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, NODE_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutU32(&out, allocator, self.node);
        try ctlPutBytes(&out, allocator, self.view);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != NODE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != NODE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_node = try ctlReadU32(bytes, &off);
        const decoded_view = try ctlReadStr(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .node = decoded_node,
            .view = decoded_view,
        };
    }
};

pub const CHILDREN_REQUEST_MSG_ID: u16 = 105;
pub const CHILDREN_REQUEST_VERSION: u8 = 1;
pub const ChildrenRequest = struct {
    document: u32,
    revision: u32,
    node: u32,
    view: []const u8,
    named_only: bool,
    limit: u32,
    cursor: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, CHILDREN_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, CHILDREN_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutU32(&out, allocator, self.node);
        try ctlPutBytes(&out, allocator, self.view);
        try ctlPutBool(&out, allocator, self.named_only);
        try ctlPutU32(&out, allocator, self.limit);
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != CHILDREN_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != CHILDREN_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_node = try ctlReadU32(bytes, &off);
        const decoded_view = try ctlReadStr(bytes, &off);
        const decoded_named_only = try ctlReadBool(bytes, &off);
        const decoded_limit = try ctlReadU32(bytes, &off);
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .node = decoded_node,
            .view = decoded_view,
            .named_only = decoded_named_only,
            .limit = decoded_limit,
            .cursor = decoded_cursor,
        };
    }
};

pub const QUERY_COMPILE_REQUEST_MSG_ID: u16 = 106;
pub const QUERY_COMPILE_REQUEST_VERSION: u8 = 1;
pub const QueryCompileRequest = struct {
    language: []const u8,
    source: []const u8,
    view: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, QUERY_COMPILE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, QUERY_COMPILE_REQUEST_VERSION);
        try ctlPutBytes(&out, allocator, self.language);
        try ctlPutBytes(&out, allocator, self.source);
        try ctlPutBytes(&out, allocator, self.view);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != QUERY_COMPILE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != QUERY_COMPILE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_language = try ctlReadStr(bytes, &off);
        const decoded_source = try ctlReadStr(bytes, &off);
        const decoded_view = try ctlReadStr(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .language = decoded_language,
            .source = decoded_source,
            .view = decoded_view,
        };
    }
};

pub const QUERY_REQUEST_MSG_ID: u16 = 107;
pub const QUERY_REQUEST_VERSION: u8 = 1;
pub const QueryRequest = struct {
    document: u32,
    revision: u32,
    query: u32,
    range: ?Range = null,
    include_text: bool,
    limit: u32,
    cursor: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, QUERY_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, QUERY_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutU32(&out, allocator, self.query);
        if (self.range) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutBool(&out, allocator, self.include_text);
        try ctlPutU32(&out, allocator, self.limit);
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != QUERY_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != QUERY_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_query = try ctlReadU32(bytes, &off);
        const decoded_range = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try Range.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_include_text = try ctlReadBool(bytes, &off);
        const decoded_limit = try ctlReadU32(bytes, &off);
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .query = decoded_query,
            .range = decoded_range,
            .include_text = decoded_include_text,
            .limit = decoded_limit,
            .cursor = decoded_cursor,
        };
    }
};

pub const EDIT_REQUEST_MSG_ID: u16 = 108;
pub const EDIT_REQUEST_VERSION: u8 = 1;
pub const EditRequest = struct {
    document: u32,
    revision: u32,
    edits: []const Edit,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, EDIT_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, EDIT_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutMessageList(Edit, &out, allocator, self.edits);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != EDIT_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != EDIT_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_edits = try ctlReadMessageList(Edit, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .edits = decoded_edits,
        };
    }
};

pub const REWRITE_REQUEST_MSG_ID: u16 = 109;
pub const REWRITE_REQUEST_VERSION: u8 = 1;
pub const RewriteRequest = struct {
    document: u32,
    revision: u32,
    validation: []const u8,
    edits: []const RewriteEdit,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REWRITE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, REWRITE_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutBytes(&out, allocator, self.validation);
        try ctlPutMessageList(RewriteEdit, &out, allocator, self.edits);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REWRITE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REWRITE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_validation = try ctlReadStr(bytes, &off);
        const decoded_edits = try ctlReadMessageList(RewriteEdit, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .validation = decoded_validation,
            .edits = decoded_edits,
        };
    }
};

pub const TEXT_REQUEST_MSG_ID: u16 = 110;
pub const TEXT_REQUEST_VERSION: u8 = 1;
pub const TextRequest = struct {
    document: u32,
    revision: u32,
    range: ?Range = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, TEXT_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, TEXT_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        if (self.range) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != TEXT_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != TEXT_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_range = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try Range.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .range = decoded_range,
        };
    }
};

pub const DIAGNOSTICS_REQUEST_MSG_ID: u16 = 111;
pub const DIAGNOSTICS_REQUEST_VERSION: u8 = 1;
pub const DiagnosticsRequest = struct {
    document: u32,
    revision: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIAGNOSTICS_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, DIAGNOSTICS_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIAGNOSTICS_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIAGNOSTICS_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
        };
    }
};

pub const QUERY_CLOSE_REQUEST_MSG_ID: u16 = 112;
pub const QUERY_CLOSE_REQUEST_VERSION: u8 = 1;
pub const QueryCloseRequest = struct {
    query: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, QUERY_CLOSE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, QUERY_CLOSE_REQUEST_VERSION);
        try ctlPutU32(&out, allocator, self.query);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != QUERY_CLOSE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != QUERY_CLOSE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_query = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .query = decoded_query,
        };
    }
};

pub const ERROR_RESPONSE_MSG_ID: u16 = 200;
pub const ERROR_RESPONSE_VERSION: u8 = 1;
pub const ErrorResponse = struct {
    code: []const u8,
    message: []const u8,
    current_revision: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, ERROR_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, ERROR_RESPONSE_VERSION);
        try ctlPutBytes(&out, allocator, self.code);
        try ctlPutBytes(&out, allocator, self.message);
        if (self.current_revision) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != ERROR_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != ERROR_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_code = try ctlReadStr(bytes, &off);
        const decoded_message = try ctlReadStr(bytes, &off);
        const decoded_current_revision = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .code = decoded_code,
            .message = decoded_message,
            .current_revision = decoded_current_revision,
        };
    }
};

pub const LANGUAGES_RESPONSE_MSG_ID: u16 = 201;
pub const LANGUAGES_RESPONSE_VERSION: u8 = 1;
pub const LanguagesResponse = struct {
    languages: []const LanguageDescriptor,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, LANGUAGES_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, LANGUAGES_RESPONSE_VERSION);
        try ctlPutMessageList(LanguageDescriptor, &out, allocator, self.languages);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != LANGUAGES_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != LANGUAGES_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_languages = try ctlReadMessageList(LanguageDescriptor, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .languages = decoded_languages,
        };
    }
};

pub const OPEN_RESPONSE_MSG_ID: u16 = 202;
pub const OPEN_RESPONSE_VERSION: u8 = 1;
pub const OpenResponse = struct {
    document: u32,
    revision: u32,
    root: NodeSummary,
    diagnostics: []const Diagnostic,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, OPEN_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, OPEN_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.document);
        try ctlPutU32(&out, allocator, self.revision);
        {
            const frame = try self.root.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        try ctlPutMessageList(Diagnostic, &out, allocator, self.diagnostics);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != OPEN_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != OPEN_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_document = try ctlReadU32(bytes, &off);
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_root = try NodeSummary.decode(allocator, try ctlReadBytes(bytes, &off));
        const decoded_diagnostics = try ctlReadMessageList(Diagnostic, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .document = decoded_document,
            .revision = decoded_revision,
            .root = decoded_root,
            .diagnostics = decoded_diagnostics,
        };
    }
};

pub const CLOSE_RESPONSE_MSG_ID: u16 = 203;
pub const CLOSE_RESPONSE_VERSION: u8 = 1;
pub const CloseResponse = struct {
    reserved: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, CLOSE_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, CLOSE_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.reserved);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != CLOSE_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != CLOSE_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_reserved = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .reserved = decoded_reserved,
        };
    }
};

pub const TREE_RESPONSE_MSG_ID: u16 = 204;
pub const TREE_RESPONSE_VERSION: u8 = 1;
pub const TreeResponse = struct {
    nodes: []const NodeSummary,
    cursor: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, TREE_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, TREE_RESPONSE_VERSION);
        try ctlPutMessageList(NodeSummary, &out, allocator, self.nodes);
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != TREE_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != TREE_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_nodes = try ctlReadMessageList(NodeSummary, allocator, bytes, &off);
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .nodes = decoded_nodes,
            .cursor = decoded_cursor,
        };
    }
};

pub const NODE_RESPONSE_MSG_ID: u16 = 205;
pub const NODE_RESPONSE_VERSION: u8 = 1;
pub const NodeResponse = struct {
    node: NodeSummary,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, NODE_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, NODE_RESPONSE_VERSION);
        {
            const frame = try self.node.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != NODE_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != NODE_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_node = try NodeSummary.decode(allocator, try ctlReadBytes(bytes, &off));
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .node = decoded_node,
        };
    }
};

pub const CHILDREN_RESPONSE_MSG_ID: u16 = 206;
pub const CHILDREN_RESPONSE_VERSION: u8 = 1;
pub const ChildrenResponse = struct {
    nodes: []const NodeSummary,
    cursor: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, CHILDREN_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, CHILDREN_RESPONSE_VERSION);
        try ctlPutMessageList(NodeSummary, &out, allocator, self.nodes);
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != CHILDREN_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != CHILDREN_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_nodes = try ctlReadMessageList(NodeSummary, allocator, bytes, &off);
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .nodes = decoded_nodes,
            .cursor = decoded_cursor,
        };
    }
};

pub const QUERY_COMPILE_RESPONSE_MSG_ID: u16 = 207;
pub const QUERY_COMPILE_RESPONSE_VERSION: u8 = 1;
pub const QueryCompileResponse = struct {
    query: u32,
    diagnostics: []const Diagnostic,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, QUERY_COMPILE_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, QUERY_COMPILE_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.query);
        try ctlPutMessageList(Diagnostic, &out, allocator, self.diagnostics);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != QUERY_COMPILE_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != QUERY_COMPILE_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_query = try ctlReadU32(bytes, &off);
        const decoded_diagnostics = try ctlReadMessageList(Diagnostic, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .query = decoded_query,
            .diagnostics = decoded_diagnostics,
        };
    }
};

pub const QUERY_RESPONSE_MSG_ID: u16 = 208;
pub const QUERY_RESPONSE_VERSION: u8 = 1;
pub const QueryResponse = struct {
    captures: []const Capture,
    cursor: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, QUERY_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, QUERY_RESPONSE_VERSION);
        try ctlPutMessageList(Capture, &out, allocator, self.captures);
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != QUERY_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != QUERY_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_captures = try ctlReadMessageList(Capture, allocator, bytes, &off);
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .captures = decoded_captures,
            .cursor = decoded_cursor,
        };
    }
};

pub const EDIT_RESPONSE_MSG_ID: u16 = 209;
pub const EDIT_RESPONSE_VERSION: u8 = 1;
pub const EditResponse = struct {
    revision: u32,
    changed: []const ChangedRange,
    diagnostics: []const Diagnostic,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, EDIT_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, EDIT_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutMessageList(ChangedRange, &out, allocator, self.changed);
        try ctlPutMessageList(Diagnostic, &out, allocator, self.diagnostics);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != EDIT_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != EDIT_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_changed = try ctlReadMessageList(ChangedRange, allocator, bytes, &off);
        const decoded_diagnostics = try ctlReadMessageList(Diagnostic, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .revision = decoded_revision,
            .changed = decoded_changed,
            .diagnostics = decoded_diagnostics,
        };
    }
};

pub const REWRITE_RESPONSE_MSG_ID: u16 = 210;
pub const REWRITE_RESPONSE_VERSION: u8 = 1;
pub const RewriteResponse = struct {
    revision: u32,
    changed: []const ChangedRange,
    diagnostics: []const Diagnostic,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REWRITE_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, REWRITE_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.revision);
        try ctlPutMessageList(ChangedRange, &out, allocator, self.changed);
        try ctlPutMessageList(Diagnostic, &out, allocator, self.diagnostics);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REWRITE_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REWRITE_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_revision = try ctlReadU32(bytes, &off);
        const decoded_changed = try ctlReadMessageList(ChangedRange, allocator, bytes, &off);
        const decoded_diagnostics = try ctlReadMessageList(Diagnostic, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .revision = decoded_revision,
            .changed = decoded_changed,
            .diagnostics = decoded_diagnostics,
        };
    }
};

pub const TEXT_RESPONSE_MSG_ID: u16 = 211;
pub const TEXT_RESPONSE_VERSION: u8 = 1;
pub const TextResponse = struct {
    text: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, TEXT_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, TEXT_RESPONSE_VERSION);
        try ctlPutBytes(&out, allocator, self.text);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != TEXT_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != TEXT_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_text = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .text = decoded_text,
        };
    }
};

pub const DIAGNOSTICS_RESPONSE_MSG_ID: u16 = 212;
pub const DIAGNOSTICS_RESPONSE_VERSION: u8 = 1;
pub const DiagnosticsResponse = struct {
    diagnostics: []const Diagnostic,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIAGNOSTICS_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, DIAGNOSTICS_RESPONSE_VERSION);
        try ctlPutMessageList(Diagnostic, &out, allocator, self.diagnostics);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIAGNOSTICS_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIAGNOSTICS_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_diagnostics = try ctlReadMessageList(Diagnostic, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .diagnostics = decoded_diagnostics,
        };
    }
};

pub const QUERY_CLOSE_RESPONSE_MSG_ID: u16 = 213;
pub const QUERY_CLOSE_RESPONSE_VERSION: u8 = 1;
pub const QueryCloseResponse = struct {
    reserved: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, QUERY_CLOSE_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, QUERY_CLOSE_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.reserved);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != QUERY_CLOSE_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != QUERY_CLOSE_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_reserved = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .reserved = decoded_reserved,
        };
    }
};
