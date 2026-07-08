//! wire.zig - host-control frame codecs.
//!
//! Owns: the hand-rolled control-frame wire codec, frame identifiers, request
//!   decoders, and response encoders used by the host control plane.
//! Invariants: control frames keep their little-endian field layout, UTF-8
//!   validation, and sorted environment-map validation exactly as the host expects.
//! Consumes: the VFS metadata and directory-entry shapes encoded into control
//!   responses.
//! Not here: scratch-buffer ownership, namespace mutation, exec scheduling, or
//!   service-call progression.

const std = @import("std");
const vfs = @import("../vfs.zig");

// control.kdl scratch-buffer frame ids/versions (the two the VFS ops emit). Little-endian;
// bool = 1 byte; bytes = u32 length + payload; a message list = u32 count + length-prefixed
// frames. The e2e host decodes these via the same contract, so it is the drift oracle.
const FILE_STAT_MSG_ID: u16 = 3;
const FILE_STAT_VERSION: u8 = 1;
const DIR_ENTRY_MSG_ID: u16 = 4;
const DIR_ENTRY_VERSION: u8 = 1;
const DIR_ENTRIES_MSG_ID: u16 = 5;
const DIR_ENTRIES_VERSION: u8 = 1;
const EXEC_REQUEST_MSG_ID: u16 = 1;
const EXEC_REQUEST_VERSION: u8 = 1;
const EXEC_OUTCOME_MSG_ID: u16 = 2;
const EXEC_OUTCOME_VERSION: u8 = 1;
const SVC_REQUEST_MSG_ID: u16 = 6;
const SVC_REQUEST_VERSION: u8 = 1;
const SVC_RESPONSE_MSG_ID: u16 = 7;
const SVC_RESPONSE_VERSION: u8 = 1;

pub const StringPair = struct { key: []const u8, value: []const u8 };
pub const ExecRequest = struct {
    cmd: []const u8,
    cwd: ?[]const u8,
    env: []const StringPair,
    stdin: ?[]const u8,
};

pub const SvcRequest = struct {
    service: []const u8,
    request: []const u8,
};

fn putU8(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u8) void {
    o.append(a, v) catch @panic("OOM");
}
fn putU16(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, v))) catch @panic("OOM");
}
fn putU32(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, v))) catch @panic("OOM");
}
fn putI32(o: *std.ArrayList(u8), a: std.mem.Allocator, v: i32) void {
    putU32(o, a, @bitCast(v));
}
fn putI64(o: *std.ArrayList(u8), a: std.mem.Allocator, v: i64) void {
    o.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(v)))) catch @panic("OOM");
}
fn putBool(o: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) void {
    putU8(o, a, if (v) 1 else 0);
}
fn putBytes(o: *std.ArrayList(u8), a: std.mem.Allocator, v: []const u8) void {
    putU32(o, a, @intCast(v.len));
    o.appendSlice(a, v) catch @panic("OOM");
}

fn readNeed(bytes: []const u8, off: *usize, len: usize) ?[]const u8 {
    const end = std.math.add(usize, off.*, len) catch return null;
    if (end > bytes.len) return null;
    const out = bytes[off.*..end];
    off.* = end;
    return out;
}

fn readU8(bytes: []const u8, off: *usize) ?u8 {
    return (readNeed(bytes, off, 1) orelse return null)[0];
}

fn readU16(bytes: []const u8, off: *usize) ?u16 {
    const b = readNeed(bytes, off, 2) orelse return null;
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

fn readU32(bytes: []const u8, off: *usize) ?u32 {
    const b = readNeed(bytes, off, 4) orelse return null;
    return @as(u32, b[0]) |
        (@as(u32, b[1]) << 8) |
        (@as(u32, b[2]) << 16) |
        (@as(u32, b[3]) << 24);
}

fn readBytes(bytes: []const u8, off: *usize) ?[]const u8 {
    const len = readU32(bytes, off) orelse return null;
    return readNeed(bytes, off, @intCast(len));
}

fn readStr(bytes: []const u8, off: *usize) ?[]const u8 {
    const out = readBytes(bytes, off) orelse return null;
    if (!std.unicode.utf8ValidateSlice(out)) return null;
    return out;
}

fn readStrMap(arena: std.mem.Allocator, bytes: []const u8, off: *usize) ?[]const StringPair {
    const n = readU32(bytes, off) orelse return null;
    const pairs = arena.alloc(StringPair, @intCast(n)) catch @panic("OOM");
    var prev: ?[]const u8 = null;
    var i: usize = 0;
    while (i < pairs.len) : (i += 1) {
        const key = readStr(bytes, off) orelse return null;
        if (prev) |last| {
            if (!std.mem.lessThan(u8, last, key)) return null;
        }
        const value = readStr(bytes, off) orelse return null;
        pairs[i] = .{ .key = key, .value = value };
        prev = key;
    }
    return pairs;
}

pub fn decodeExecRequest(arena: std.mem.Allocator, bytes: []const u8) ?ExecRequest {
    var off: usize = 0;
    if ((readU16(bytes, &off) orelse return null) != EXEC_REQUEST_MSG_ID) return null;
    if ((readU8(bytes, &off) orelse return null) != EXEC_REQUEST_VERSION) return null;
    const cmd = readStr(bytes, &off) orelse return null;
    const cwd: ?[]const u8 = switch (readU8(bytes, &off) orelse return null) {
        0 => null,
        1 => readStr(bytes, &off) orelse return null,
        else => return null,
    };
    const env = readStrMap(arena, bytes, &off) orelse return null;
    const stdin: ?[]const u8 = switch (readU8(bytes, &off) orelse return null) {
        0 => null,
        1 => readBytes(bytes, &off) orelse return null,
        else => return null,
    };
    if (off != bytes.len) return null;
    return .{ .cmd = cmd, .cwd = cwd, .env = env, .stdin = stdin };
}

pub fn decodeSvcRequest(bytes: []const u8) ?SvcRequest {
    var off: usize = 0;
    if ((readU16(bytes, &off) orelse return null) != SVC_REQUEST_MSG_ID) return null;
    if ((readU8(bytes, &off) orelse return null) != SVC_REQUEST_VERSION) return null;
    const service = readStr(bytes, &off) orelse return null;
    const request = readBytes(bytes, &off) orelse return null;
    if (off != bytes.len) return null;
    return .{ .service = service, .request = request };
}

pub fn encodeExecOutcome(a: std.mem.Allocator, exit_code: i32, stdout: []const u8, stderr: []const u8) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, EXEC_OUTCOME_MSG_ID);
    putU8(&o, a, EXEC_OUTCOME_VERSION);
    putI32(&o, a, exit_code);
    putBytes(&o, a, stdout);
    putBytes(&o, a, stderr);
    return o.items;
}

pub fn encodeSvcResponse(a: std.mem.Allocator, status: i32, body: []const u8) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, SVC_RESPONSE_MSG_ID);
    putU8(&o, a, SVC_RESPONSE_VERSION);
    putI32(&o, a, status);
    putBytes(&o, a, body);
    return o.items;
}

pub fn encodeFileStat(a: std.mem.Allocator, md: vfs.Metadata) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, FILE_STAT_MSG_ID);
    putU8(&o, a, FILE_STAT_VERSION);
    putI64(&o, a, @intCast(md.size));
    putBool(&o, a, md.node_type == .dir);
    putBool(&o, a, md.node_type == .symlink);
    putU32(&o, a, md.nlink);
    putU32(&o, a, md.mode);
    return o.items;
}

fn encodeDirEntry(a: std.mem.Allocator, e: vfs.DirEntry) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, DIR_ENTRY_MSG_ID);
    putU8(&o, a, DIR_ENTRY_VERSION);
    putBytes(&o, a, e.name);
    putBool(&o, a, e.node_type == .dir);
    putBool(&o, a, e.node_type == .symlink);
    return o.items;
}

pub fn encodeDirEntries(a: std.mem.Allocator, entries: []const vfs.DirEntry) []u8 {
    var o: std.ArrayList(u8) = .empty;
    putU16(&o, a, DIR_ENTRIES_MSG_ID);
    putU8(&o, a, DIR_ENTRIES_VERSION);
    putU32(&o, a, @intCast(entries.len));
    for (entries) |e| putBytes(&o, a, encodeDirEntry(a, e));
    return o.items;
}
