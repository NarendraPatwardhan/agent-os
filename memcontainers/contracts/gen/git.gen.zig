// @generated from contracts/git.kdl by //contracts/codegen:projector — do not edit.
pub const PROTOCOL_VERSION: u32 = 1;
pub const REQUEST_MAGIC: []const u8 = "AOGQ";
pub const RESPONSE_MAGIC: []const u8 = "AOGR";
pub const PROTOCOL_MINOR: u32 = 0;
pub const BACKEND_BROWSER: u32 = 1;
pub const BACKEND_NATIVE: u32 = 2;
pub const CAPABILITY_CORE: u32 = 1;
pub const ENVELOPE_HEADER_BYTES: u32 = 20;
pub const MAX_FRAME_BYTES: u32 = 1048576;
pub const MAX_FIELD_BYTES: u32 = 262144;
pub const MAX_PATH_BYTES: u32 = 4096;
pub const MAX_REF_BYTES: u32 = 1024;
pub const MAX_HANDLES: u32 = 4096;
pub const MAX_PACK_BYTES: u32 = 67108864;
pub const MAX_PACK_OBJECTS: u32 = 1000000;
pub const MAX_RESULT_BYTES: u32 = 16777216;
pub const OP_ENGINE_DESCRIBE: u32 = 1;
pub const OP_SESSION_OPEN: u32 = 2;
pub const OP_SESSION_CLOSE: u32 = 3;
pub const OP_REPOSITORY_INIT: u32 = 16;
pub const OP_REPOSITORY_OPEN: u32 = 17;
pub const OP_FILE_STAT: u32 = 256;
pub const OP_FILE_READ: u32 = 257;
pub const OP_FILE_WRITE: u32 = 258;
pub const OP_FILE_REMOVE: u32 = 259;
pub const OP_FILE_RENAME: u32 = 260;
pub const OP_FILE_READDIR: u32 = 261;
pub const OP_STATUS: u32 = 272;
pub const OP_ADD: u32 = 273;
pub const OP_REMOVE: u32 = 274;
pub const OP_COMMIT: u32 = 275;
pub const OP_LOG: u32 = 276;
pub const OP_RESOLVE_REVISION: u32 = 277;
pub const OP_DIFF: u32 = 278;
pub const OP_SHOW: u32 = 279;
pub const OP_CHECKOUT: u32 = 280;
pub const OP_RESET: u32 = 281;
pub const OP_BRANCH: u32 = 282;
pub const OP_TAG: u32 = 283;
pub const OP_CONFIG: u32 = 284;
pub const OP_REMOTE_METADATA: u32 = 285;
pub const OP_IGNORE_QUERY: u32 = 286;
pub const OP_SPARSE: u32 = 287;
pub const OP_SUBMODULE: u32 = 288;
pub const OP_OBJECT: u32 = 512;
pub const OP_REF: u32 = 528;
pub const OP_REF_TRANSACTION: u32 = 529;
pub const OP_PACK_IMPORT: u32 = 544;
pub const OP_PACK_BUILD: u32 = 545;
pub const OP_SHALLOW: u32 = 546;
pub const OP_MOUNT: u32 = 768;
pub const OP_STREAM: u32 = 784;
pub const OP_CLONE: u32 = 1024;
pub const OP_FETCH: u32 = 1025;
pub const OP_PULL: u32 = 1026;
pub const OP_PUSH: u32 = 1027;
pub const OP_HTTP_EFFECT: u32 = 1040;
pub const OP_REMOTE_CANCEL: u32 = 1041;
pub const OP_CHECKPOINT: u32 = 1280;
pub const OP_RESTORE: u32 = 1281;
pub const ACTION_LIST: u32 = 1;
pub const ACTION_GET: u32 = 2;
pub const ACTION_CREATE: u32 = 3;
pub const ACTION_UPDATE: u32 = 4;
pub const ACTION_DELETE: u32 = 5;
pub const ACTION_BEGIN: u32 = 6;
pub const ACTION_WRITE: u32 = 7;
pub const ACTION_FINISH: u32 = 8;
pub const ACTION_ABORT: u32 = 9;
pub const ACTION_READ: u32 = 10;
pub const ACTION_CLOSE: u32 = 11;
pub const HTTP_RESPONSE_BEGIN: u32 = 1;
pub const HTTP_RESPONSE_CHUNK: u32 = 2;
pub const HTTP_RESPONSE_END: u32 = 3;
pub const HTTP_RESPONSE_ABORT: u32 = 4;
pub const STREAM_READ: u32 = 1;
pub const STREAM_WRITE: u32 = 2;
pub const STREAM_FINISH: u32 = 3;
pub const STREAM_ABORT: u32 = 4;
pub const STREAM_CLOSE: u32 = 5;
pub const MOUNT_ATTACH: u32 = 1;
pub const MOUNT_DETACH: u32 = 2;
pub const MOUNT_STAT: u32 = 3;
pub const MOUNT_READ: u32 = 4;
pub const MOUNT_WRITE: u32 = 5;
pub const MOUNT_CREATE: u32 = 6;
pub const MOUNT_REMOVE: u32 = 7;
pub const MOUNT_RENAME: u32 = 8;
pub const MOUNT_READDIR: u32 = 9;
pub const MOUNT_CHMOD: u32 = 10;
pub const RESET_SOFT: u32 = 1;
pub const RESET_MIXED: u32 = 2;
pub const RESET_HARD: u32 = 3;
pub const RESET_MERGE: u32 = 4;
pub const STATUS_OK: u32 = 0;
pub const STATUS_EFFECT: u32 = 1;
pub const STATUS_ERROR: u32 = 2;
pub const RETRY_NEVER: u32 = 0;
pub const RETRY_AFTER_INPUT: u32 = 1;
pub const RETRY_AFTER_REFRESH: u32 = 2;
pub const RETRY_TRANSIENT_HOST: u32 = 3;
pub const ERROR_PROTOCOL: u32 = 1;
pub const ERROR_USAGE: u32 = 2;
pub const ERROR_PATH: u32 = 3;
pub const ERROR_REPOSITORY: u32 = 4;
pub const ERROR_OBJECT: u32 = 5;
pub const ERROR_REFERENCE: u32 = 6;
pub const ERROR_INDEX: u32 = 7;
pub const ERROR_WORKTREE: u32 = 8;
pub const ERROR_PACK: u32 = 9;
pub const ERROR_REMOTE: u32 = 10;
pub const ERROR_TRANSPORT_EFFECT: u32 = 11;
pub const ERROR_PERSISTENCE: u32 = 12;
pub const ERROR_LIMIT: u32 = 13;
pub const ERROR_CANCELLED: u32 = 14;
pub const ERROR_INTERNAL: u32 = 15;


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

pub const SESSION_CONFIG_MSG_ID: u16 = 1;
pub const SESSION_CONFIG_VERSION: u8 = 1;
pub const SessionConfig = struct {
    backend: u16,
    read_only: bool,
    root: []const u8,
    restore: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SESSION_CONFIG_MSG_ID);
        try ctlPutU8(&out, allocator, SESSION_CONFIG_VERSION);
        try ctlPutU16(&out, allocator, self.backend);
        try ctlPutBool(&out, allocator, self.read_only);
        try ctlPutBytes(&out, allocator, self.root);
        if (self.restore) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != SESSION_CONFIG_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SESSION_CONFIG_VERSION) return WireError.UnsupportedVersion;
        const decoded_backend = try ctlReadU16(bytes, &off);
        const decoded_read_only = try ctlReadBool(bytes, &off);
        const decoded_root = try ctlReadStr(bytes, &off);
        const decoded_restore = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .backend = decoded_backend,
            .read_only = decoded_read_only,
            .root = decoded_root,
            .restore = decoded_restore,
        };
    }
};

pub const ENGINE_DESCRIPTION_MSG_ID: u16 = 2;
pub const ENGINE_DESCRIPTION_VERSION: u8 = 1;
pub const EngineDescription = struct {
    abi_major: u16,
    abi_minor: u16,
    build_id: []const u8,
    gitz_commit: []const u8,
    backend: u16,
    capabilities_low: u32,
    capabilities_high: u32,
    max_frame_bytes: u32,
    max_pack_bytes: u32,
    max_handles: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, ENGINE_DESCRIPTION_MSG_ID);
        try ctlPutU8(&out, allocator, ENGINE_DESCRIPTION_VERSION);
        try ctlPutU16(&out, allocator, self.abi_major);
        try ctlPutU16(&out, allocator, self.abi_minor);
        try ctlPutBytes(&out, allocator, self.build_id);
        try ctlPutBytes(&out, allocator, self.gitz_commit);
        try ctlPutU16(&out, allocator, self.backend);
        try ctlPutU32(&out, allocator, self.capabilities_low);
        try ctlPutU32(&out, allocator, self.capabilities_high);
        try ctlPutU32(&out, allocator, self.max_frame_bytes);
        try ctlPutU32(&out, allocator, self.max_pack_bytes);
        try ctlPutU32(&out, allocator, self.max_handles);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != ENGINE_DESCRIPTION_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != ENGINE_DESCRIPTION_VERSION) return WireError.UnsupportedVersion;
        const decoded_abi_major = try ctlReadU16(bytes, &off);
        const decoded_abi_minor = try ctlReadU16(bytes, &off);
        const decoded_build_id = try ctlReadStr(bytes, &off);
        const decoded_gitz_commit = try ctlReadStr(bytes, &off);
        const decoded_backend = try ctlReadU16(bytes, &off);
        const decoded_capabilities_low = try ctlReadU32(bytes, &off);
        const decoded_capabilities_high = try ctlReadU32(bytes, &off);
        const decoded_max_frame_bytes = try ctlReadU32(bytes, &off);
        const decoded_max_pack_bytes = try ctlReadU32(bytes, &off);
        const decoded_max_handles = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .abi_major = decoded_abi_major,
            .abi_minor = decoded_abi_minor,
            .build_id = decoded_build_id,
            .gitz_commit = decoded_gitz_commit,
            .backend = decoded_backend,
            .capabilities_low = decoded_capabilities_low,
            .capabilities_high = decoded_capabilities_high,
            .max_frame_bytes = decoded_max_frame_bytes,
            .max_pack_bytes = decoded_max_pack_bytes,
            .max_handles = decoded_max_handles,
        };
    }
};

pub const OBJECT_ID_MSG_ID: u16 = 3;
pub const OBJECT_ID_VERSION: u8 = 1;
pub const ObjectId = struct {
    algorithm: u16,
    bytes: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, OBJECT_ID_MSG_ID);
        try ctlPutU8(&out, allocator, OBJECT_ID_VERSION);
        try ctlPutU16(&out, allocator, self.algorithm);
        try ctlPutBytes(&out, allocator, self.bytes);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != OBJECT_ID_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != OBJECT_ID_VERSION) return WireError.UnsupportedVersion;
        const decoded_algorithm = try ctlReadU16(bytes, &off);
        const decoded_bytes = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .algorithm = decoded_algorithm,
            .bytes = decoded_bytes,
        };
    }
};

pub const SIGNATURE_MSG_ID: u16 = 4;
pub const SIGNATURE_VERSION: u8 = 1;
pub const Signature = struct {
    name: []const u8,
    email: []const u8,
    unix_seconds: i64,
    timezone_minutes: i32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SIGNATURE_MSG_ID);
        try ctlPutU8(&out, allocator, SIGNATURE_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        try ctlPutBytes(&out, allocator, self.email);
        try ctlPutI64(&out, allocator, self.unix_seconds);
        try ctlPutI32(&out, allocator, self.timezone_minutes);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SIGNATURE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SIGNATURE_VERSION) return WireError.UnsupportedVersion;
        const decoded_name = try ctlReadStr(bytes, &off);
        const decoded_email = try ctlReadStr(bytes, &off);
        const decoded_unix_seconds = try ctlReadI64(bytes, &off);
        const decoded_timezone_minutes = try ctlReadI32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = decoded_name,
            .email = decoded_email,
            .unix_seconds = decoded_unix_seconds,
            .timezone_minutes = decoded_timezone_minutes,
        };
    }
};

pub const PATH_LIST_MSG_ID: u16 = 5;
pub const PATH_LIST_VERSION: u8 = 1;
pub const PathList = struct {
    paths: []const StringPair,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, PATH_LIST_MSG_ID);
        try ctlPutU8(&out, allocator, PATH_LIST_VERSION);
        try ctlPutStrMap(&out, allocator, self.paths);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != PATH_LIST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != PATH_LIST_VERSION) return WireError.UnsupportedVersion;
        const decoded_paths = try ctlReadStrMap(allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .paths = decoded_paths,
        };
    }
};

pub const FILE_REQUEST_MSG_ID: u16 = 6;
pub const FILE_REQUEST_VERSION: u8 = 1;
pub const FileRequest = struct {
    path: []const u8,
    other_path: ?[]const u8 = null,
    mode: ?u32 = null,
    offset_low: ?u32 = null,
    offset_high: ?u32 = null,
    data: ?[]const u8 = null,
    handle: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, FILE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, FILE_REQUEST_VERSION);
        try ctlPutBytes(&out, allocator, self.path);
        if (self.other_path) |v| {
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
        if (self.offset_low) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.offset_high) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.data) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.handle) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != FILE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != FILE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_path = try ctlReadStr(bytes, &off);
        const decoded_other_path = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_mode = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_offset_low = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_offset_high = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .path = decoded_path,
            .other_path = decoded_other_path,
            .mode = decoded_mode,
            .offset_low = decoded_offset_low,
            .offset_high = decoded_offset_high,
            .data = decoded_data,
            .handle = decoded_handle,
        };
    }
};

pub const PORCELAIN_REQUEST_MSG_ID: u16 = 7;
pub const PORCELAIN_REQUEST_VERSION: u8 = 1;
pub const PorcelainRequest = struct {
    action: u16,
    flags: u32,
    revision: ?[]const u8 = null,
    target: ?[]const u8 = null,
    message: ?[]const u8 = null,
    paths: []const StringPair,
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    author: ?Signature = null,
    committer: ?Signature = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, PORCELAIN_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, PORCELAIN_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        try ctlPutU32(&out, allocator, self.flags);
        if (self.revision) |v| {
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
        if (self.message) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutStrMap(&out, allocator, self.paths);
        if (self.limit) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.author) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.committer) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != PORCELAIN_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != PORCELAIN_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_flags = try ctlReadU32(bytes, &off);
        const decoded_revision = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_target = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_message = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_paths = try ctlReadStrMap(allocator, bytes, &off);
        const decoded_limit = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_author = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try Signature.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_committer = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try Signature.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .flags = decoded_flags,
            .revision = decoded_revision,
            .target = decoded_target,
            .message = decoded_message,
            .paths = decoded_paths,
            .limit = decoded_limit,
            .cursor = decoded_cursor,
            .author = decoded_author,
            .committer = decoded_committer,
        };
    }
};

pub const REF_UPDATE_MSG_ID: u16 = 8;
pub const REF_UPDATE_VERSION: u8 = 1;
pub const RefUpdate = struct {
    name: []const u8,
    new_value: ?ObjectId = null,
    expected_value: ?ObjectId = null,
    require_absent: bool,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REF_UPDATE_MSG_ID);
        try ctlPutU8(&out, allocator, REF_UPDATE_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        if (self.new_value) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.expected_value) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutBool(&out, allocator, self.require_absent);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REF_UPDATE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REF_UPDATE_VERSION) return WireError.UnsupportedVersion;
        const decoded_name = try ctlReadStr(bytes, &off);
        const decoded_new_value = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_expected_value = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_require_absent = try ctlReadBool(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = decoded_name,
            .new_value = decoded_new_value,
            .expected_value = decoded_expected_value,
            .require_absent = decoded_require_absent,
        };
    }
};

pub const STREAM_REQUEST_MSG_ID: u16 = 10;
pub const STREAM_REQUEST_VERSION: u8 = 1;
pub const StreamRequest = struct {
    action: u16,
    handle: ?u32 = null,
    offset_low: ?u32 = null,
    offset_high: ?u32 = null,
    data: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, STREAM_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, STREAM_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        if (self.handle) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.offset_low) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.offset_high) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.data) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != STREAM_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != STREAM_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_offset_low = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_offset_high = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .handle = decoded_handle,
            .offset_low = decoded_offset_low,
            .offset_high = decoded_offset_high,
            .data = decoded_data,
        };
    }
};

pub const REMOTE_REQUEST_MSG_ID: u16 = 11;
pub const REMOTE_REQUEST_VERSION: u8 = 1;
pub const RemoteRequest = struct {
    action: u16,
    url: []const u8,
    remote: ?[]const u8 = null,
    refspecs: []const StringPair,
    depth: ?u32 = null,
    flags: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REMOTE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, REMOTE_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        try ctlPutBytes(&out, allocator, self.url);
        if (self.remote) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutStrMap(&out, allocator, self.refspecs);
        if (self.depth) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutU32(&out, allocator, self.flags);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REMOTE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REMOTE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_url = try ctlReadStr(bytes, &off);
        const decoded_remote = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_refspecs = try ctlReadStrMap(allocator, bytes, &off);
        const decoded_depth = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_flags = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .url = decoded_url,
            .remote = decoded_remote,
            .refspecs = decoded_refspecs,
            .depth = decoded_depth,
            .flags = decoded_flags,
        };
    }
};

pub const HTTP_EFFECT_MSG_ID: u16 = 12;
pub const HTTP_EFFECT_VERSION: u8 = 1;
pub const HttpEffect = struct {
    exchange: u32,
    method: []const u8,
    path: []const u8,
    headers: []const StringPair,
    body: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, HTTP_EFFECT_MSG_ID);
        try ctlPutU8(&out, allocator, HTTP_EFFECT_VERSION);
        try ctlPutU32(&out, allocator, self.exchange);
        try ctlPutBytes(&out, allocator, self.method);
        try ctlPutBytes(&out, allocator, self.path);
        try ctlPutStrMap(&out, allocator, self.headers);
        if (self.body) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != HTTP_EFFECT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != HTTP_EFFECT_VERSION) return WireError.UnsupportedVersion;
        const decoded_exchange = try ctlReadU32(bytes, &off);
        const decoded_method = try ctlReadStr(bytes, &off);
        const decoded_path = try ctlReadStr(bytes, &off);
        const decoded_headers = try ctlReadStrMap(allocator, bytes, &off);
        const decoded_body = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .exchange = decoded_exchange,
            .method = decoded_method,
            .path = decoded_path,
            .headers = decoded_headers,
            .body = decoded_body,
        };
    }
};

pub const HTTP_RESPONSE_MSG_ID: u16 = 13;
pub const HTTP_RESPONSE_VERSION: u8 = 1;
pub const HttpResponse = struct {
    exchange: u32,
    action: u16,
    status: ?u16 = null,
    headers: []const StringPair,
    data: ?[]const u8 = null,
    error_code: ?u16 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, HTTP_RESPONSE_MSG_ID);
        try ctlPutU8(&out, allocator, HTTP_RESPONSE_VERSION);
        try ctlPutU32(&out, allocator, self.exchange);
        try ctlPutU16(&out, allocator, self.action);
        if (self.status) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU16(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutStrMap(&out, allocator, self.headers);
        if (self.data) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.error_code) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU16(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != HTTP_RESPONSE_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != HTTP_RESPONSE_VERSION) return WireError.UnsupportedVersion;
        const decoded_exchange = try ctlReadU32(bytes, &off);
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_status = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU16(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_headers = try ctlReadStrMap(allocator, bytes, &off);
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_error_code = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU16(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .exchange = decoded_exchange,
            .action = decoded_action,
            .status = decoded_status,
            .headers = decoded_headers,
            .data = decoded_data,
            .error_code = decoded_error_code,
        };
    }
};

pub const ENGINE_ERROR_MSG_ID: u16 = 14;
pub const ENGINE_ERROR_VERSION: u8 = 1;
pub const EngineError = struct {
    domain: u16,
    code: u16,
    operation: u16,
    retry: u16,
    message: ?[]const u8 = null,
    detail_kind: ?u16 = null,
    detail: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, ENGINE_ERROR_MSG_ID);
        try ctlPutU8(&out, allocator, ENGINE_ERROR_VERSION);
        try ctlPutU16(&out, allocator, self.domain);
        try ctlPutU16(&out, allocator, self.code);
        try ctlPutU16(&out, allocator, self.operation);
        try ctlPutU16(&out, allocator, self.retry);
        if (self.message) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.detail_kind) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU16(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.detail) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != ENGINE_ERROR_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != ENGINE_ERROR_VERSION) return WireError.UnsupportedVersion;
        const decoded_domain = try ctlReadU16(bytes, &off);
        const decoded_code = try ctlReadU16(bytes, &off);
        const decoded_operation = try ctlReadU16(bytes, &off);
        const decoded_retry = try ctlReadU16(bytes, &off);
        const decoded_message = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_detail_kind = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU16(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_detail = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .domain = decoded_domain,
            .code = decoded_code,
            .operation = decoded_operation,
            .retry = decoded_retry,
            .message = decoded_message,
            .detail_kind = decoded_detail_kind,
            .detail = decoded_detail,
        };
    }
};

pub const RESULT_MSG_ID: u16 = 15;
pub const RESULT_VERSION: u8 = 1;
pub const Result = struct {
    kind: u16,
    generation: u32,
    handle: ?u32 = null,
    count: ?u32 = null,
    data: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, RESULT_VERSION);
        try ctlPutU16(&out, allocator, self.kind);
        try ctlPutU32(&out, allocator, self.generation);
        if (self.handle) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.count) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.data) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_kind = try ctlReadU16(bytes, &off);
        const decoded_generation = try ctlReadU32(bytes, &off);
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_count = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .kind = decoded_kind,
            .generation = decoded_generation,
            .handle = decoded_handle,
            .count = decoded_count,
            .data = decoded_data,
        };
    }
};

pub const FILE_RESULT_MSG_ID: u16 = 16;
pub const FILE_RESULT_VERSION: u8 = 1;
pub const FileResult = struct {
    path: []const u8,
    mode: u32,
    size_low: u32,
    size_high: u32,
    data: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, FILE_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, FILE_RESULT_VERSION);
        try ctlPutBytes(&out, allocator, self.path);
        try ctlPutU32(&out, allocator, self.mode);
        try ctlPutU32(&out, allocator, self.size_low);
        try ctlPutU32(&out, allocator, self.size_high);
        if (self.data) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != FILE_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != FILE_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_path = try ctlReadStr(bytes, &off);
        const decoded_mode = try ctlReadU32(bytes, &off);
        const decoded_size_low = try ctlReadU32(bytes, &off);
        const decoded_size_high = try ctlReadU32(bytes, &off);
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .path = decoded_path,
            .mode = decoded_mode,
            .size_low = decoded_size_low,
            .size_high = decoded_size_high,
            .data = decoded_data,
        };
    }
};

pub const STATUS_ENTRY_MSG_ID: u16 = 17;
pub const STATUS_ENTRY_VERSION: u8 = 1;
pub const StatusEntry = struct {
    path: []const u8,
    index: u16,
    worktree: u16,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, STATUS_ENTRY_MSG_ID);
        try ctlPutU8(&out, allocator, STATUS_ENTRY_VERSION);
        try ctlPutBytes(&out, allocator, self.path);
        try ctlPutU16(&out, allocator, self.index);
        try ctlPutU16(&out, allocator, self.worktree);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != STATUS_ENTRY_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != STATUS_ENTRY_VERSION) return WireError.UnsupportedVersion;
        const decoded_path = try ctlReadStr(bytes, &off);
        const decoded_index = try ctlReadU16(bytes, &off);
        const decoded_worktree = try ctlReadU16(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .path = decoded_path,
            .index = decoded_index,
            .worktree = decoded_worktree,
        };
    }
};

pub const STATUS_RESULT_MSG_ID: u16 = 18;
pub const STATUS_RESULT_VERSION: u8 = 1;
pub const StatusResult = struct {
    generation: u32,
    entries: []const StatusEntry,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, STATUS_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, STATUS_RESULT_VERSION);
        try ctlPutU32(&out, allocator, self.generation);
        try ctlPutMessageList(StatusEntry, &out, allocator, self.entries);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != STATUS_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != STATUS_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_generation = try ctlReadU32(bytes, &off);
        const decoded_entries = try ctlReadMessageList(StatusEntry, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .generation = decoded_generation,
            .entries = decoded_entries,
        };
    }
};

pub const COMMIT_RESULT_MSG_ID: u16 = 19;
pub const COMMIT_RESULT_VERSION: u8 = 1;
pub const CommitResult = struct {
    generation: u32,
    object_id: ObjectId,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, COMMIT_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, COMMIT_RESULT_VERSION);
        try ctlPutU32(&out, allocator, self.generation);
        {
            const frame = try self.object_id.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != COMMIT_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != COMMIT_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_generation = try ctlReadU32(bytes, &off);
        const decoded_object_id = try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off));
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .generation = decoded_generation,
            .object_id = decoded_object_id,
        };
    }
};

pub const RESOLVE_RESULT_MSG_ID: u16 = 20;
pub const RESOLVE_RESULT_VERSION: u8 = 1;
pub const ResolveResult = struct {
    object_id: ObjectId,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, RESOLVE_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, RESOLVE_RESULT_VERSION);
        {
            const frame = try self.object_id.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != RESOLVE_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != RESOLVE_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_object_id = try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off));
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .object_id = decoded_object_id,
        };
    }
};

pub const DIRECTORY_ENTRY_MSG_ID: u16 = 21;
pub const DIRECTORY_ENTRY_VERSION: u8 = 1;
pub const DirectoryEntry = struct {
    name: []const u8,
    mode: u32,
    size_low: u32,
    size_high: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIRECTORY_ENTRY_MSG_ID);
        try ctlPutU8(&out, allocator, DIRECTORY_ENTRY_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        try ctlPutU32(&out, allocator, self.mode);
        try ctlPutU32(&out, allocator, self.size_low);
        try ctlPutU32(&out, allocator, self.size_high);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIRECTORY_ENTRY_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIRECTORY_ENTRY_VERSION) return WireError.UnsupportedVersion;
        const decoded_name = try ctlReadStr(bytes, &off);
        const decoded_mode = try ctlReadU32(bytes, &off);
        const decoded_size_low = try ctlReadU32(bytes, &off);
        const decoded_size_high = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = decoded_name,
            .mode = decoded_mode,
            .size_low = decoded_size_low,
            .size_high = decoded_size_high,
        };
    }
};

pub const DIRECTORY_RESULT_MSG_ID: u16 = 22;
pub const DIRECTORY_RESULT_VERSION: u8 = 1;
pub const DirectoryResult = struct {
    entries: []const DirectoryEntry,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, DIRECTORY_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, DIRECTORY_RESULT_VERSION);
        try ctlPutMessageList(DirectoryEntry, &out, allocator, self.entries);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != DIRECTORY_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != DIRECTORY_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_entries = try ctlReadMessageList(DirectoryEntry, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .entries = decoded_entries,
        };
    }
};

pub const REFERENCE_RESULT_MSG_ID: u16 = 23;
pub const REFERENCE_RESULT_VERSION: u8 = 1;
pub const ReferenceResult = struct {
    name: []const u8,
    kind: u16,
    object_id: ?ObjectId = null,
    target: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REFERENCE_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, REFERENCE_RESULT_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        try ctlPutU16(&out, allocator, self.kind);
        if (self.object_id) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.target) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REFERENCE_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REFERENCE_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_name = try ctlReadStr(bytes, &off);
        const decoded_kind = try ctlReadU16(bytes, &off);
        const decoded_object_id = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_target = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = decoded_name,
            .kind = decoded_kind,
            .object_id = decoded_object_id,
            .target = decoded_target,
        };
    }
};

pub const REFERENCE_LIST_MSG_ID: u16 = 24;
pub const REFERENCE_LIST_VERSION: u8 = 1;
pub const ReferenceList = struct {
    references: []const ReferenceResult,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REFERENCE_LIST_MSG_ID);
        try ctlPutU8(&out, allocator, REFERENCE_LIST_VERSION);
        try ctlPutMessageList(ReferenceResult, &out, allocator, self.references);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REFERENCE_LIST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REFERENCE_LIST_VERSION) return WireError.UnsupportedVersion;
        const decoded_references = try ctlReadMessageList(ReferenceResult, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .references = decoded_references,
        };
    }
};

pub const OBJECT_REQUEST_MSG_ID: u16 = 25;
pub const OBJECT_REQUEST_VERSION: u8 = 1;
pub const ObjectRequest = struct {
    action: u16,
    kind: u16,
    object_id: ?ObjectId = null,
    data: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, OBJECT_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, OBJECT_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        try ctlPutU16(&out, allocator, self.kind);
        if (self.object_id) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.data) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != OBJECT_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != OBJECT_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_kind = try ctlReadU16(bytes, &off);
        const decoded_object_id = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .kind = decoded_kind,
            .object_id = decoded_object_id,
            .data = decoded_data,
        };
    }
};

pub const OBJECT_RESULT_MSG_ID: u16 = 26;
pub const OBJECT_RESULT_VERSION: u8 = 1;
pub const ObjectResult = struct {
    kind: u16,
    object_id: ObjectId,
    size_low: u32,
    size_high: u32,
    data: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, OBJECT_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, OBJECT_RESULT_VERSION);
        try ctlPutU16(&out, allocator, self.kind);
        {
            const frame = try self.object_id.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        try ctlPutU32(&out, allocator, self.size_low);
        try ctlPutU32(&out, allocator, self.size_high);
        if (self.data) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != OBJECT_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != OBJECT_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_kind = try ctlReadU16(bytes, &off);
        const decoded_object_id = try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off));
        const decoded_size_low = try ctlReadU32(bytes, &off);
        const decoded_size_high = try ctlReadU32(bytes, &off);
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .kind = decoded_kind,
            .object_id = decoded_object_id,
            .size_low = decoded_size_low,
            .size_high = decoded_size_high,
            .data = decoded_data,
        };
    }
};

pub const PACK_REQUEST_MSG_ID: u16 = 27;
pub const PACK_REQUEST_VERSION: u8 = 1;
pub const PackRequest = struct {
    action: u16,
    handle: ?u32 = null,
    wants: []const ObjectId,
    haves: []const ObjectId,
    updates: []const RefUpdate,
    data: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, PACK_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, PACK_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        if (self.handle) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutMessageList(ObjectId, &out, allocator, self.wants);
        try ctlPutMessageList(ObjectId, &out, allocator, self.haves);
        try ctlPutMessageList(RefUpdate, &out, allocator, self.updates);
        if (self.data) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != PACK_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != PACK_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_wants = try ctlReadMessageList(ObjectId, allocator, bytes, &off);
        const decoded_haves = try ctlReadMessageList(ObjectId, allocator, bytes, &off);
        const decoded_updates = try ctlReadMessageList(RefUpdate, allocator, bytes, &off);
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .handle = decoded_handle,
            .wants = decoded_wants,
            .haves = decoded_haves,
            .updates = decoded_updates,
            .data = decoded_data,
        };
    }
};

pub const PACK_RESULT_MSG_ID: u16 = 28;
pub const PACK_RESULT_VERSION: u8 = 1;
pub const PackResult = struct {
    handle: ?u32 = null,
    object_count: u32,
    reference_count: u32,
    data: ?[]const u8 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, PACK_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, PACK_RESULT_VERSION);
        if (self.handle) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutU32(&out, allocator, self.object_count);
        try ctlPutU32(&out, allocator, self.reference_count);
        if (self.data) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != PACK_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != PACK_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_object_count = try ctlReadU32(bytes, &off);
        const decoded_reference_count = try ctlReadU32(bytes, &off);
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .handle = decoded_handle,
            .object_count = decoded_object_count,
            .reference_count = decoded_reference_count,
            .data = decoded_data,
        };
    }
};

pub const SNAPSHOT_RESULT_MSG_ID: u16 = 29;
pub const SNAPSHOT_RESULT_VERSION: u8 = 1;
pub const SnapshotResult = struct {
    generation: u32,
    image: []const u8,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SNAPSHOT_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, SNAPSHOT_RESULT_VERSION);
        try ctlPutU32(&out, allocator, self.generation);
        try ctlPutBytes(&out, allocator, self.image);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SNAPSHOT_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SNAPSHOT_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_generation = try ctlReadU32(bytes, &off);
        const decoded_image = try ctlReadBytes(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .generation = decoded_generation,
            .image = decoded_image,
        };
    }
};

pub const STREAM_CHUNK_MSG_ID: u16 = 30;
pub const STREAM_CHUNK_VERSION: u8 = 1;
pub const StreamChunk = struct {
    handle: u32,
    offset_low: u32,
    offset_high: u32,
    data: []const u8,
    done: bool,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, STREAM_CHUNK_MSG_ID);
        try ctlPutU8(&out, allocator, STREAM_CHUNK_VERSION);
        try ctlPutU32(&out, allocator, self.handle);
        try ctlPutU32(&out, allocator, self.offset_low);
        try ctlPutU32(&out, allocator, self.offset_high);
        try ctlPutBytes(&out, allocator, self.data);
        try ctlPutBool(&out, allocator, self.done);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != STREAM_CHUNK_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != STREAM_CHUNK_VERSION) return WireError.UnsupportedVersion;
        const decoded_handle = try ctlReadU32(bytes, &off);
        const decoded_offset_low = try ctlReadU32(bytes, &off);
        const decoded_offset_high = try ctlReadU32(bytes, &off);
        const decoded_data = try ctlReadBytes(bytes, &off);
        const decoded_done = try ctlReadBool(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .handle = decoded_handle,
            .offset_low = decoded_offset_low,
            .offset_high = decoded_offset_high,
            .data = decoded_data,
            .done = decoded_done,
        };
    }
};

pub const MOUNT_REQUEST_MSG_ID: u16 = 31;
pub const MOUNT_REQUEST_VERSION: u8 = 1;
pub const MountRequest = struct {
    action: u16,
    path: ?[]const u8 = null,
    other_path: ?[]const u8 = null,
    handle: ?u32 = null,
    flags: u32,
    mode: ?u32 = null,
    offset_low: ?u32 = null,
    offset_high: ?u32 = null,
    data: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    limit: ?u32 = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, MOUNT_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, MOUNT_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        if (self.path) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.other_path) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.handle) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutU32(&out, allocator, self.flags);
        if (self.mode) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.offset_low) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.offset_high) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.data) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.cursor) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.limit) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != MOUNT_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != MOUNT_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_path = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_other_path = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_flags = try ctlReadU32(bytes, &off);
        const decoded_mode = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_offset_low = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_offset_high = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_data = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_cursor = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadBytes(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_limit = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .path = decoded_path,
            .other_path = decoded_other_path,
            .handle = decoded_handle,
            .flags = decoded_flags,
            .mode = decoded_mode,
            .offset_low = decoded_offset_low,
            .offset_high = decoded_offset_high,
            .data = decoded_data,
            .cursor = decoded_cursor,
            .limit = decoded_limit,
        };
    }
};

pub const REMOTE_RESULT_MSG_ID: u16 = 32;
pub const REMOTE_RESULT_VERSION: u8 = 1;
pub const RemoteResult = struct {
    handle: u32,
    state: u16,
    generation: u32,
    updated: []const ReferenceResult,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REMOTE_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, REMOTE_RESULT_VERSION);
        try ctlPutU32(&out, allocator, self.handle);
        try ctlPutU16(&out, allocator, self.state);
        try ctlPutU32(&out, allocator, self.generation);
        try ctlPutMessageList(ReferenceResult, &out, allocator, self.updated);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REMOTE_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REMOTE_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_handle = try ctlReadU32(bytes, &off);
        const decoded_state = try ctlReadU16(bytes, &off);
        const decoded_generation = try ctlReadU32(bytes, &off);
        const decoded_updated = try ctlReadMessageList(ReferenceResult, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .handle = decoded_handle,
            .state = decoded_state,
            .generation = decoded_generation,
            .updated = decoded_updated,
        };
    }
};

pub const PATH_QUERY_MSG_ID: u16 = 33;
pub const PATH_QUERY_VERSION: u8 = 1;
pub const PathQuery = struct {
    paths: []const StringPair,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, PATH_QUERY_MSG_ID);
        try ctlPutU8(&out, allocator, PATH_QUERY_VERSION);
        try ctlPutStrMap(&out, allocator, self.paths);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != PATH_QUERY_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != PATH_QUERY_VERSION) return WireError.UnsupportedVersion;
        const decoded_paths = try ctlReadStrMap(allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .paths = decoded_paths,
        };
    }
};

pub const IGNORE_RESULT_MSG_ID: u16 = 34;
pub const IGNORE_RESULT_VERSION: u8 = 1;
pub const IgnoreResult = struct {
    paths: []const StringPair,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, IGNORE_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, IGNORE_RESULT_VERSION);
        try ctlPutStrMap(&out, allocator, self.paths);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != IGNORE_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != IGNORE_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_paths = try ctlReadStrMap(allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .paths = decoded_paths,
        };
    }
};

pub const REF_TRANSACTION_REQUEST_MSG_ID: u16 = 35;
pub const REF_TRANSACTION_REQUEST_VERSION: u8 = 1;
pub const RefTransactionRequest = struct {
    action: u16,
    handle: ?u32 = null,
    updates: []const RefUpdate,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REF_TRANSACTION_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, REF_TRANSACTION_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        if (self.handle) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutMessageList(RefUpdate, &out, allocator, self.updates);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REF_TRANSACTION_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REF_TRANSACTION_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_updates = try ctlReadMessageList(RefUpdate, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .handle = decoded_handle,
            .updates = decoded_updates,
        };
    }
};

pub const REF_TRANSACTION_RESULT_MSG_ID: u16 = 36;
pub const REF_TRANSACTION_RESULT_VERSION: u8 = 1;
pub const RefTransactionResult = struct {
    handle: ?u32 = null,
    generation: u32,
    count: u32,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, REF_TRANSACTION_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, REF_TRANSACTION_RESULT_VERSION);
        if (self.handle) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutU32(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutU32(&out, allocator, self.generation);
        try ctlPutU32(&out, allocator, self.count);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        _ = allocator;
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != REF_TRANSACTION_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != REF_TRANSACTION_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_handle = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadU32(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_generation = try ctlReadU32(bytes, &off);
        const decoded_count = try ctlReadU32(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .handle = decoded_handle,
            .generation = decoded_generation,
            .count = decoded_count,
        };
    }
};

pub const SHALLOW_REQUEST_MSG_ID: u16 = 37;
pub const SHALLOW_REQUEST_VERSION: u8 = 1;
pub const ShallowRequest = struct {
    action: u16,
    commits: []const ObjectId,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SHALLOW_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, SHALLOW_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        try ctlPutMessageList(ObjectId, &out, allocator, self.commits);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SHALLOW_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SHALLOW_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_commits = try ctlReadMessageList(ObjectId, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .commits = decoded_commits,
        };
    }
};

pub const SHALLOW_RESULT_MSG_ID: u16 = 38;
pub const SHALLOW_RESULT_VERSION: u8 = 1;
pub const ShallowResult = struct {
    commits: []const ObjectId,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SHALLOW_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, SHALLOW_RESULT_VERSION);
        try ctlPutMessageList(ObjectId, &out, allocator, self.commits);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SHALLOW_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SHALLOW_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_commits = try ctlReadMessageList(ObjectId, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .commits = decoded_commits,
        };
    }
};

pub const SUBMODULE_REQUEST_MSG_ID: u16 = 39;
pub const SUBMODULE_REQUEST_VERSION: u8 = 1;
pub const SubmoduleRequest = struct {
    action: u16,
    path: ?[]const u8 = null,
    object_id: ?ObjectId = null,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SUBMODULE_REQUEST_MSG_ID);
        try ctlPutU8(&out, allocator, SUBMODULE_REQUEST_VERSION);
        try ctlPutU16(&out, allocator, self.action);
        if (self.path) |v| {
            try ctlPutU8(&out, allocator, 1);
        try ctlPutBytes(&out, allocator, v);
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.object_id) |v| {
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
        if ((try ctlReadU16(bytes, &off)) != SUBMODULE_REQUEST_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SUBMODULE_REQUEST_VERSION) return WireError.UnsupportedVersion;
        const decoded_action = try ctlReadU16(bytes, &off);
        const decoded_path = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ctlReadStr(bytes, &off),
            else => return WireError.InvalidPresence,
        };
        const decoded_object_id = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .action = decoded_action,
            .path = decoded_path,
            .object_id = decoded_object_id,
        };
    }
};

pub const SUBMODULE_ENTRY_MSG_ID: u16 = 40;
pub const SUBMODULE_ENTRY_VERSION: u8 = 1;
pub const SubmoduleEntry = struct {
    name: []const u8,
    path: []const u8,
    url: []const u8,
    gitlink: ?ObjectId = null,
    head: ?ObjectId = null,
    state: u16,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SUBMODULE_ENTRY_MSG_ID);
        try ctlPutU8(&out, allocator, SUBMODULE_ENTRY_VERSION);
        try ctlPutBytes(&out, allocator, self.name);
        try ctlPutBytes(&out, allocator, self.path);
        try ctlPutBytes(&out, allocator, self.url);
        if (self.gitlink) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        if (self.head) |v| {
            try ctlPutU8(&out, allocator, 1);
        {
            const frame = try v.encode(allocator);
            defer allocator.free(frame);
            try ctlPutBytes(&out, allocator, frame);
        }
        } else {
            try ctlPutU8(&out, allocator, 0);
        }
        try ctlPutU16(&out, allocator, self.state);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SUBMODULE_ENTRY_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SUBMODULE_ENTRY_VERSION) return WireError.UnsupportedVersion;
        const decoded_name = try ctlReadStr(bytes, &off);
        const decoded_path = try ctlReadStr(bytes, &off);
        const decoded_url = try ctlReadStr(bytes, &off);
        const decoded_gitlink = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_head = switch (try ctlReadU8(bytes, &off)) {
            0 => null,
            1 => try ObjectId.decode(allocator, try ctlReadBytes(bytes, &off)),
            else => return WireError.InvalidPresence,
        };
        const decoded_state = try ctlReadU16(bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .name = decoded_name,
            .path = decoded_path,
            .url = decoded_url,
            .gitlink = decoded_gitlink,
            .head = decoded_head,
            .state = decoded_state,
        };
    }
};

pub const SUBMODULE_RESULT_MSG_ID: u16 = 41;
pub const SUBMODULE_RESULT_VERSION: u8 = 1;
pub const SubmoduleResult = struct {
    generation: u32,
    entries: []const SubmoduleEntry,

    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try ctlPutU16(&out, allocator, SUBMODULE_RESULT_MSG_ID);
        try ctlPutU8(&out, allocator, SUBMODULE_RESULT_VERSION);
        try ctlPutU32(&out, allocator, self.generation);
        try ctlPutMessageList(SubmoduleEntry, &out, allocator, self.entries);
        return out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {
        var off: usize = 0;
        if ((try ctlReadU16(bytes, &off)) != SUBMODULE_RESULT_MSG_ID) return WireError.WrongMessage;
        if ((try ctlReadU8(bytes, &off)) != SUBMODULE_RESULT_VERSION) return WireError.UnsupportedVersion;
        const decoded_generation = try ctlReadU32(bytes, &off);
        const decoded_entries = try ctlReadMessageList(SubmoduleEntry, allocator, bytes, &off);
        if (off != bytes.len) return WireError.TrailingBytes;
        return .{
            .generation = decoded_generation,
            .entries = decoded_entries,
        };
    }
};

pub const RequestEnvelope = struct { opcode: u16, flags: u16, request_id: u32, payload: []const u8 };
pub const ResponseEnvelope = struct { opcode: u16, status: u16, request_id: u32, payload: []const u8 };
pub fn decodeRequestEnvelope(bytes: []const u8) !RequestEnvelope {
if (bytes.len > MAX_FRAME_BYTES) return WireError.LimitExceeded;
if (bytes.len < ENVELOPE_HEADER_BYTES or !std.mem.eql(u8, bytes[0..4], REQUEST_MAGIC)) return WireError.WrongMessage;
var off: usize = 4;
if ((try ctlReadU16(bytes, &off)) != PROTOCOL_VERSION) return WireError.UnsupportedVersion;
if ((try ctlReadU16(bytes, &off)) > PROTOCOL_MINOR) return WireError.UnsupportedVersion;
const opcode = try ctlReadU16(bytes, &off);
const flags = try ctlReadU16(bytes, &off);
const request_id = try ctlReadU32(bytes, &off);
const payload_len = try ctlReadU32(bytes, &off);
if (payload_len > MAX_FRAME_BYTES - ENVELOPE_HEADER_BYTES) return WireError.LimitExceeded;
const payload = try ctlNeed(bytes, &off, @intCast(payload_len));
if (off != bytes.len) return WireError.TrailingBytes;
return .{ .opcode = opcode, .flags = flags, .request_id = request_id, .payload = payload };
}
pub fn encodeResponseEnvelope(allocator: std.mem.Allocator, opcode: u16, status: u16, request_id: u32, payload: []const u8) ![]u8 {
if (payload.len > MAX_RESULT_BYTES or payload.len > std.math.maxInt(u32)) return WireError.LimitExceeded;
var out: std.ArrayList(u8) = .empty;
errdefer out.deinit(allocator);
try out.ensureTotalCapacity(allocator, ENVELOPE_HEADER_BYTES + payload.len);
try out.appendSlice(allocator, RESPONSE_MAGIC);
try ctlPutU16(&out, allocator, PROTOCOL_VERSION);
try ctlPutU16(&out, allocator, PROTOCOL_MINOR);
try ctlPutU16(&out, allocator, opcode);
try ctlPutU16(&out, allocator, status);
try ctlPutU32(&out, allocator, request_id);
try ctlPutU32(&out, allocator, @intCast(payload.len));
try out.appendSlice(allocator, payload);
return out.toOwnedSlice(allocator);
}
pub fn decodeResponseEnvelope(bytes: []const u8) !ResponseEnvelope {
if (bytes.len > MAX_RESULT_BYTES) return WireError.LimitExceeded;
if (bytes.len < ENVELOPE_HEADER_BYTES or !std.mem.eql(u8, bytes[0..4], RESPONSE_MAGIC)) return WireError.WrongMessage;
var off: usize = 4;
if ((try ctlReadU16(bytes, &off)) != PROTOCOL_VERSION) return WireError.UnsupportedVersion;
if ((try ctlReadU16(bytes, &off)) > PROTOCOL_MINOR) return WireError.UnsupportedVersion;
const opcode = try ctlReadU16(bytes, &off);
const status = try ctlReadU16(bytes, &off);
const request_id = try ctlReadU32(bytes, &off);
const payload_len = try ctlReadU32(bytes, &off);
if (payload_len > MAX_RESULT_BYTES - ENVELOPE_HEADER_BYTES) return WireError.LimitExceeded;
const payload = try ctlNeed(bytes, &off, @intCast(payload_len));
if (off != bytes.len) return WireError.TrailingBytes;
return .{ .opcode = opcode, .status = status, .request_id = request_id, .payload = payload };
}
