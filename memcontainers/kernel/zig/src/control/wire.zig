//! wire.zig - host-control frame codecs (a thin adapter over the generated ctl_zig codecs).
//!
//! Owns: the mapping between the kernel's types (vfs.Metadata, vfs.DirEntry, the exec/svc frames)
//!   and the message codecs GENERATED from control.kdl (ctl_zig). The wire format therefore has ONE
//!   source shared with the host and the TS client, and the decoders are the generator's fail-closed
//!   ones (WrongMessage / UnsupportedVersion / Truncated / InvalidUtf8 / NonCanonicalMap / ...).
//! Invariants: the wire format IS control.kdl; drift is a contracts diff-test failure, never a silent
//!   host<->kernel mismatch. Encoders return arena-owned slices (the caller passes an arena).
//! Consumes: ctl_zig (the generated message types + codecs), the vfs metadata/dirent shapes.
//! Not here: scratch-buffer ownership, namespace mutation, exec scheduling, service-call progression.

const std = @import("std");
const vfs = @import("../vfs.zig");
const ctl = @import("ctl_zig");

pub const StringPair = ctl.StringPair;
pub const ExecRequest = ctl.ExecRequest;
pub const SvcRequest = ctl.SvcRequest;

pub fn decodeExecRequest(arena: std.mem.Allocator, bytes: []const u8) ?ExecRequest {
    return ctl.ExecRequest.decode(arena, bytes) catch null;
}

pub fn decodeSvcRequest(arena: std.mem.Allocator, bytes: []const u8) ?SvcRequest {
    return ctl.SvcRequest.decode(arena, bytes) catch null;
}

pub fn encodeExecOutcome(a: std.mem.Allocator, exit_code: i32, stdout: []const u8, stderr: []const u8) []u8 {
    const msg: ctl.ExecOutcome = .{ .exit_code = exit_code, .stdout = stdout, .stderr = stderr };
    return msg.encode(a) catch @panic("OOM");
}

pub fn encodeSvcResponse(a: std.mem.Allocator, status: i32, body: []const u8) []u8 {
    const msg: ctl.SvcResponse = .{ .status = status, .body = body };
    return msg.encode(a) catch @panic("OOM");
}

pub fn encodeFileStat(a: std.mem.Allocator, md: vfs.Metadata) []u8 {
    const msg: ctl.FileStat = .{
        .size = @intCast(md.size),
        .is_dir = md.node_type == .dir,
        .is_symlink = md.node_type == .symlink,
        .nlink = md.nlink,
        .mode = md.mode,
    };
    return msg.encode(a) catch @panic("OOM");
}

pub fn encodeDirEntries(a: std.mem.Allocator, entries: []const vfs.DirEntry) []u8 {
    const items = a.alloc(ctl.DirEntry, entries.len) catch @panic("OOM");
    for (entries, 0..) |e, i| items[i] = .{
        .name = e.name,
        .is_dir = e.node_type == .dir,
        .is_symlink = e.node_type == .symlink,
    };
    const msg: ctl.DirEntries = .{ .entries = items };
    return msg.encode(a) catch @panic("OOM");
}
