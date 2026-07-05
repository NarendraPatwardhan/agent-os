//! The `/env` file-backed environment (DESIGN.md §4.3): there is no envp -- each
//! variable is a file `/env/<NAME>` holding its value, trailing `\n`/`\r` trimmed on
//! read. `printenv`, `env`, `which` (`/env/PATH`), `pwd -L` (`/env/PWD`) all go through
//! this module.

const std = @import("std");
const sys = @import("../sys/root.zig");
const textio = @import("textio.zig");
const fsutil = @import("fsutil.zig");

const Allocator = std.mem.Allocator;

fn envPath(buf: []u8, name: []const u8) ?[]const u8 {
    const prefix = "/env/";
    if (prefix.len + name.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..name.len], name);
    return buf[0 .. prefix.len + name.len];
}

/// Reads `/env/<name>`, trimming one trailing `\n` then one trailing `\r`
/// (`textio.chomp`). `null` if the file doesn't exist or can't be read.
pub fn get(gpa: Allocator, name: []const u8) ?[]u8 {
    var buf: [300]u8 = undefined;
    const path = envPath(&buf, name) orelse return null;
    const fd = sys.open(path, .{ .read = true }) catch return null;
    defer sys.close(fd);
    const raw = textio.readAll(gpa, fd) catch return null;
    defer gpa.free(raw);
    const trimmed = textio.chomp(raw);
    return gpa.dupe(u8, trimmed) catch null;
}

/// Writes `value` verbatim to `/env/<name>` (create+truncate).
pub fn set(name: []const u8, value: []const u8) sys.Error!void {
    var buf: [300]u8 = undefined;
    const path = envPath(&buf, name) orelse return error.EINVAL;
    const fd = try sys.open(path, .{ .write = true, .create = true, .trunc = true });
    defer sys.close(fd);
    try sys.writeAll(fd, value);
}

/// Removes `/env/<name>`; a missing file is not an error.
pub fn unset(name: []const u8) sys.Error!void {
    var buf: [300]u8 = undefined;
    const path = envPath(&buf, name) orelse return error.EINVAL;
    sys.unlink(path) catch |e| if (e != error.ENOENT) return e;
}

/// Sorted (byte-wise) list of every variable name currently set.
pub fn list(gpa: Allocator) sys.Error![][]const u8 {
    const names = try fsutil.list(gpa, "/env");
    std.mem.sort([]const u8, names, {}, lessThan);
    return names;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Splits a `PATH`-shaped value on `:` (used by `which`/`PATH` lookups). Slices
/// reference `value` -- no allocation beyond the returned index slice.
pub fn pathDirs(gpa: Allocator, value: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, value, ':');
    while (it.next()) |d| try out.append(gpa, d);
    return out.toOwnedSlice(gpa);
}
