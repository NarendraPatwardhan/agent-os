const std = @import("std");
const contract = @import("git_zig");
const fs = @import("fs");
const paths = @import("paths.zig");

pub fn stat(allocator: std.mem.Allocator, session: anytype, request: contract.MountRequest) ![]u8 {
    const path = request.path orelse ".";
    try paths.validateDirectory(path);
    const info = try session.filesystem.lstat(path);
    return (contract.FileResult{ .path = path, .mode = info.mode, .size_low = lowU32(info.size), .size_high = highU32(info.size) }).encode(allocator);
}

pub fn read(allocator: std.mem.Allocator, session: anytype, request: contract.MountRequest) ![]u8 {
    const path = request.path orelse return error.MissingPath;
    try paths.validate(path);
    const info = try session.filesystem.lstat(path);
    const offset = joinU64(request.offset_low orelse 0, request.offset_high orelse 0);
    if (offset > @as(u64, @intCast(info.size))) return error.InvalidOffset;
    const wanted: usize = @intCast(@min(@as(u64, request.limit orelse contract.MAX_FIELD_BYTES), @as(u64, contract.MAX_FIELD_BYTES)));
    const count = @min(wanted, @as(usize, @intCast(@as(u64, @intCast(info.size)) - offset)));
    const data = try allocator.alloc(u8, count);
    defer allocator.free(data);
    var file = try session.filesystem.open(path);
    defer file.close() catch {};
    var bytes_read: usize = 0;
    while (bytes_read < data.len) {
        const amount = try file.readAt(data[bytes_read..], @intCast(offset + bytes_read));
        if (amount == 0) break;
        bytes_read += amount;
    }
    return (contract.FileResult{ .path = path, .mode = info.mode, .size_low = lowU32(info.size), .size_high = highU32(info.size), .data = data[0..bytes_read] }).encode(allocator);
}

pub fn write(allocator: std.mem.Allocator, backend: anytype, session: anytype, request: contract.MountRequest) ![]u8 {
    if (backend.isReadOnly(session)) return error.ReadOnly;
    const path = request.path orelse return error.MissingPath;
    try paths.validate(path);
    const data = request.data orelse return error.MissingData;
    if (std.fs.path.dirname(path)) |parent| try session.filesystem.mkdirAll(parent, 0o040755);
    const offset = joinU64(request.offset_low orelse 0, request.offset_high orelse 0);
    var file = try session.filesystem.openFile(path, fs.O.RDWR | fs.O.CREATE, request.mode orelse 0o666);
    defer file.close() catch {};
    var written: usize = 0;
    while (written < data.len) written += try file.writeAt(data[written..], @intCast(offset + written));
    if (request.mode) |mode| try session.filesystem.chmod(path, mode);
    bumpGeneration(session);
    const info = try session.filesystem.lstat(path);
    return (contract.FileResult{ .path = path, .mode = info.mode, .size_low = lowU32(info.size), .size_high = highU32(info.size) }).encode(allocator);
}

pub fn create(allocator: std.mem.Allocator, backend: anytype, session: anytype, request: contract.MountRequest) ![]u8 {
    if (backend.isReadOnly(session)) return error.ReadOnly;
    const path = request.path orelse return error.MissingPath;
    try paths.validate(path);
    if (request.flags & ~@as(u32, 1) != 0) return error.InvalidFlags;
    if (request.flags & 1 != 0) {
        const requested_mode = request.mode orelse 0o040755;
        const directory_mode = if (requested_mode & 0o777 == 0) requested_mode | 0o755 else requested_mode;
        try session.filesystem.mkdirAll(path, directory_mode);
    } else {
        if (std.fs.path.dirname(path)) |parent| try session.filesystem.mkdirAll(parent, 0o040755);
        var file = try session.filesystem.create(path);
        defer file.close() catch {};
        if (request.data) |data| {
            var written: usize = 0;
            while (written < data.len) written += try file.writeAt(data[written..], @intCast(written));
        }
        if (request.mode) |mode| try session.filesystem.chmod(path, mode);
    }
    bumpGeneration(session);
    return stat(allocator, session, request);
}

pub fn remove(allocator: std.mem.Allocator, backend: anytype, session: anytype, request: contract.MountRequest) ![]u8 {
    if (backend.isReadOnly(session)) return error.ReadOnly;
    const path = request.path orelse return error.MissingPath;
    try paths.validate(path);
    try session.filesystem.remove(path);
    bumpGeneration(session);
    return mutationResult(allocator, session, 1);
}

pub fn rename(allocator: std.mem.Allocator, backend: anytype, session: anytype, request: contract.MountRequest) ![]u8 {
    if (backend.isReadOnly(session)) return error.ReadOnly;
    const path = request.path orelse return error.MissingPath;
    const other = request.other_path orelse return error.MissingTarget;
    try paths.validate(path);
    try paths.validate(other);
    try session.filesystem.rename(path, other);
    bumpGeneration(session);
    return mutationResult(allocator, session, 1);
}

pub fn readDir(allocator: std.mem.Allocator, session: anytype, request: contract.MountRequest) ![]u8 {
    const path = request.path orelse ".";
    try paths.validateDirectory(path);
    const infos = try session.filesystem.readDir(path);
    defer session.filesystem.freeReadDir(infos);
    const limit = @min(infos.len, @as(usize, request.limit orelse 256));
    const entries = try allocator.alloc(contract.DirectoryEntry, limit);
    defer allocator.free(entries);
    for (infos[0..limit], 0..) |info, i| entries[i] = .{ .name = info.name, .mode = info.mode, .size_low = lowU32(info.size), .size_high = highU32(info.size) };
    return (contract.DirectoryResult{ .entries = entries }).encode(allocator);
}

pub fn chmod(allocator: std.mem.Allocator, backend: anytype, session: anytype, request: contract.MountRequest) ![]u8 {
    if (backend.isReadOnly(session)) return error.ReadOnly;
    const path = request.path orelse return error.MissingPath;
    const mode = request.mode orelse return error.MissingMode;
    try paths.validate(path);
    if (mode & ~@as(u32, 0o100755) != 0) return error.InvalidMode;
    try session.filesystem.chmod(path, mode);
    bumpGeneration(session);
    return stat(allocator, session, request);
}

fn mutationResult(allocator: std.mem.Allocator, session: anytype, count: u32) ![]u8 {
    return (contract.Result{ .kind = 3, .generation = session.mutation_generation, .count = count }).encode(allocator);
}

fn bumpGeneration(session: anytype) void {
    session.mutation_generation +%= 1;
    if (session.mutation_generation == 0) session.mutation_generation = 1;
}

fn joinU64(low: u32, high: u32) u64 {
    return @as(u64, low) | (@as(u64, high) << 32);
}

fn lowU32(value: anytype) u32 {
    return @truncate(@as(u64, @intCast(value)));
}

fn highU32(value: anytype) u32 {
    return @truncate(@as(u64, @intCast(value)) >> 32);
}
