const std = @import("std");
const contract = @import("git_zig");
const gitignore = @import("gitignore");
const object = @import("object");
const plumbing = @import("plumbing");
const paths_mod = @import("paths.zig");

const validatePath = paths_mod.validate;

pub fn pathWithinAny(path: []const u8, roots: []const []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, path, root)) return true;
        if (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return true;
    }
    return false;
}

pub fn joinU64(low: u32, high: u32) u64 {
    return @as(u64, low) | (@as(u64, high) << 32);
}
pub fn lowU32(value: anytype) u32 {
    return @truncate(@as(u64, @intCast(value)));
}
pub fn highU32(value: anytype) u32 {
    return @truncate(@as(u64, @intCast(value)) >> 32);
}

pub fn pairsToPaths(allocator: std.mem.Allocator, pairs: []const contract.StringPair) ![]const []const u8 {
    const paths = try allocator.alloc([]const u8, pairs.len);
    for (pairs, 0..) |pair, i| {
        try validatePath(pair.key);
        paths[i] = pair.key;
    }
    return paths;
}

pub fn decisiveIgnorePattern(patterns: []const gitignore.Pattern, path: []const []const u8, is_dir: bool) ?*const gitignore.Pattern {
    var index = patterns.len;
    while (index > 0) {
        index -= 1;
        const result = patterns[index].match(path, is_dir);
        if (!result.isDecisive()) continue;
        return if (result == .exclude) &patterns[index] else null;
    }
    return null;
}

pub fn formatIgnorePattern(allocator: std.mem.Allocator, pattern: *const gitignore.Pattern) ![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    errdefer allocating.deinit();
    if (pattern.inclusion) try allocating.writer.writeByte('!');
    for (pattern.pattern, 0..) |segment, index| {
        if (index != 0) try allocating.writer.writeByte('/');
        try allocating.writer.writeAll(segment);
    }
    if (pattern.dir_only) try allocating.writer.writeByte('/');
    return allocating.toOwnedSlice();
}

pub fn hashFromObjectId(value: contract.ObjectId) !plumbing.Hash {
    const wanted: usize = switch (value.algorithm) {
        1 => 20,
        2 => 32,
        else => return error.UnsupportedObjectAlgorithm,
    };
    if (value.bytes.len != wanted) return error.InvalidObjectId;
    return plumbing.Hash.fromBytes(value.bytes);
}

pub fn objectIdsToHashes(allocator: std.mem.Allocator, values: []const contract.ObjectId) ![]plumbing.Hash {
    const hashes = try allocator.alloc(plumbing.Hash, values.len);
    errdefer allocator.free(hashes);
    for (values, 0..) |value, i| hashes[i] = try hashFromObjectId(value);
    return hashes;
}

pub fn objectKind(kind: plumbing.ObjectType) u16 {
    return switch (kind) {
        .commit => 1,
        .tree => 2,
        .blob => 3,
        .tag => 4,
        else => 0,
    };
}

pub fn referenceValue(ref: *const plumbing.Reference) contract.ReferenceResult {
    return switch (ref.type) {
        .hash => .{ .name = ref.name.raw, .kind = 1, .object_id = objectId(&ref.hash) },
        .symbolic => .{ .name = ref.name.raw, .kind = 2, .target = ref.target.raw },
        .invalid => .{ .name = ref.name.raw, .kind = 0 },
    };
}

pub fn encodeReference(allocator: std.mem.Allocator, ref: *const plumbing.Reference) ![]u8 {
    return referenceValue(ref).encode(allocator);
}

pub fn removeStoredReference(store: anytype, name: plumbing.ReferenceName) !void {
    const result = store.removeReference(name);
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) try result;
}

pub fn bumpGeneration(session: anytype) void {
    session.mutation_generation +%= 1;
    if (session.mutation_generation == 0) session.mutation_generation = 1;
}

pub fn signature(value: contract.Signature) object.Signature {
    return .{
        .name = value.name,
        .email = value.email,
        .when = value.unix_seconds,
        .tz_offset_minutes = @intCast(value.timezone_minutes),
    };
}

pub fn objectId(hash: *const plumbing.Hash) contract.ObjectId {
    return .{ .algorithm = if (hash.slice().len == 20) 1 else 2, .bytes = hash.slice() };
}

pub fn readBoundedFile(allocator: std.mem.Allocator, filesystem: anytype, path: []const u8, limit: usize) ![]u8 {
    const info = try filesystem.lstat(path);
    if (info.isDir() or info.isSymlink() or info.size < 0) return error.InvalidFile;
    const size: usize = @intCast(info.size);
    if (size > limit) return error.FileTooLarge;
    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);
    var file = try filesystem.open(path);
    defer file.close() catch {};
    var read: usize = 0;
    while (read < data.len) {
        const amount = try file.readAt(data[read..], @intCast(read));
        if (amount == 0) return error.UnexpectedEndOfFile;
        read += amount;
    }
    return data;
}

pub fn statusEntryLess(_: void, left: contract.StatusEntry, right: contract.StatusEntry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}

pub fn submoduleEntryLess(_: void, left: contract.SubmoduleEntry, right: contract.SubmoduleEntry) bool {
    return std.mem.lessThan(u8, left.path, right.path);
}
