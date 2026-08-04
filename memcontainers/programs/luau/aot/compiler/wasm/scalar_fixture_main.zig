const std = @import("std");
const scalar_fixture = @import("scalar_fixture.zig");

pub fn main(init: std.process.Init) !void {
    const bytes = try scalar_fixture.build(std.heap.page_allocator);
    defer std.heap.page_allocator.free(bytes);
    try std.Io.File.writeStreamingAll(.stdout(), init.io, bytes);
}
