//! Shared logical-path policy for browser and native Git backends.

const std = @import("std");
const contract = @import("git_zig");

pub fn validate(path: []const u8) !void {
    if (path.len == 0 or path.len > contract.MAX_PATH_BYTES or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidPath;
        if (first and std.mem.eql(u8, component, ".git")) return error.ReservedPath;
        first = false;
    }
}

pub fn validateDirectory(path: []const u8) !void {
    if (path.len == 0 or std.mem.eql(u8, path, ".")) return;
    try validate(path);
}

test "path policy rejects traversal reserved metadata and host separators" {
    try validate("dir/file");
    try validateDirectory("");
    try std.testing.expectError(error.InvalidPath, validate("../escape"));
    try std.testing.expectError(error.ReservedPath, validate(".git/config"));
    try std.testing.expectError(error.InvalidPath, validate("dir\\file"));
}
