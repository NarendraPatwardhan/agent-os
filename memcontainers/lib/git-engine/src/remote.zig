const std = @import("std");
const contract = @import("git_zig");
const plumbing = @import("plumbing");

pub fn validRemoteUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > contract.MAX_PATH_BYTES or std.mem.indexOfScalar(u8, url, 0) != null) return false;
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}

pub fn validRemoteName(name: []const u8) bool {
    if (name.len == 0 or name.len > contract.MAX_REF_BYTES or name[0] == '-' or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, 0) != null) return false;
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    return !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

pub fn validFullRef(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "refs/") or name.len > contract.MAX_REF_BYTES or std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOf(u8, name, "..") != null or std.mem.endsWith(u8, name, ".lock")) return false;
    const ref_name = plumbing.ReferenceName.init(name);
    ref_name.validate() catch return false;
    return true;
}

pub fn remoteTrackingDestination(name: []const u8, remote_name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "refs/remotes/")) return false;
    const suffix = name["refs/remotes/".len..];
    return std.mem.startsWith(u8, suffix, remote_name) and suffix.len > remote_name.len and suffix[remote_name.len] == '/';
}

pub fn defaultRemoteDestination(allocator: std.mem.Allocator, opcode: u16, remote_name: []const u8, source: []const u8) ![]u8 {
    const source_name = plumbing.ReferenceName.init(source);
    if (!source_name.isBranch()) return error.DefaultRefMustBeBranch;
    if (opcode == contract.OP_CLONE) return allocator.dupe(u8, source);
    return std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote_name, source_name.short() });
}

pub fn remoteBaseLen(url: []const u8) usize {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    return end;
}

pub fn infoRefsUrl(allocator: std.mem.Allocator, url: []const u8, service: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/info/refs?service={s}", .{ url[0..remoteBaseLen(url)], service });
}

pub fn serviceUrl(allocator: std.mem.Allocator, url: []const u8, service: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ url[0..remoteBaseLen(url)], service });
}

pub fn resolveSubmoduleHttpUrl(allocator: std.mem.Allocator, parent_url: ?[]const u8, raw: []const u8) ![]u8 {
    if (validRemoteUrl(raw)) return allocator.dupe(u8, raw);
    if (raw.len == 0 or raw[0] == '/' or std.mem.indexOfScalar(u8, raw, '\\') != null or std.mem.indexOfScalar(u8, raw, 0) != null or std.mem.indexOfAny(u8, raw, "?#") != null)
        return error.InvalidSubmoduleUrl;
    const parent = parent_url orelse return error.RelativeSubmoduleWithoutOrigin;
    if (!validRemoteUrl(parent) or std.mem.indexOfAny(u8, parent, "?#") != null) return error.InvalidParentUrl;
    const scheme_end = std.mem.indexOf(u8, parent, "://") orelse return error.InvalidParentUrl;
    const authority_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, parent, authority_start, '/') orelse parent.len;
    if (path_start == authority_start) return error.InvalidParentUrl;
    const parent_path_end = remoteBaseLen(parent);
    const combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent[path_start..parent_path_end], raw });
    defer allocator.free(combined);
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, combined, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len == 0) return error.SubmoduleUrlEscapesOrigin;
            _ = segments.pop();
            continue;
        }
        try segments.append(allocator, segment);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(parent[0..path_start]);
    for (segments.items) |segment| {
        try out.writer.writeByte('/');
        try out.writer.writeAll(segment);
    }
    return out.toOwnedSlice();
}
