const std = @import("std");
const linux = std.os.linux;
const runner = @import("runner_zig");

const max_frame_bytes: usize = runner.RUNNER_MAX_FRAME_BYTES;

pub fn main() !void {
    const listener = try syscallFd(linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    defer close(listener);

    var address: linux.sockaddr.vm = .{
        .port = runner.RUNNER_DEFAULT_VSOCK_PORT,
        .cid = std.math.maxInt(u32),
        .flags = 0,
    };
    try syscallOk(linux.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))));
    try syscallOk(linux.listen(listener, 16));

    while (true) {
        const connection = syscallFd(linux.accept4(listener, null, null, linux.SOCK.CLOEXEC)) catch continue;
        serve(connection) catch {};
        close(connection);
    }
}

fn serve(fd: i32) !void {
    const allocator = std.heap.page_allocator;
    const hello = try (runner.RunnerHello{
        .protocol_version = runner.PROTOCOL_VERSION,
        .agent = "agentos-health",
        .kind = runner.RUNNER_HEALTH_KIND,
        .version = 1,
        .contract_digest = runner.RUNNER_HEALTH_CONTRACT_DIGEST,
    }).encode(allocator);
    defer allocator.free(hello);
    try writeFrame(fd, hello);

    while (true) {
        const frame = try readFrame(allocator, fd);
        defer allocator.free(frame);
        if (frame.len < 2) return error.InvalidFrame;

        const message_id = @as(u16, frame[0]) | (@as(u16, frame[1]) << 8);
        switch (message_id) {
            runner.RUNNER_REQUEST_MSG_ID => try handleRequest(allocator, fd, frame),
            else => return error.InvalidFrame,
        }
    }
}

fn handleRequest(allocator: std.mem.Allocator, fd: i32, frame: []const u8) !void {
    const request = runner.RunnerRequest.decode(allocator, frame) catch return error.InvalidFrame;
    const supported = std.mem.eql(u8, request.kind, runner.RUNNER_HEALTH_KIND) and
        std.mem.eql(u8, request.operation, "echo");

    const response = try (runner.RunnerResponse{
        .request_id = request.request_id,
        .ok = supported,
        .body = if (supported) request.body else "",
        .error_code = if (supported) null else "runner_unsupported_operation",
        .error_message = if (supported) null else "the health runner supports only its declared kind and echo operation",
    }).encode(allocator);
    defer allocator.free(response);
    try writeFrame(fd, response);
}

fn readFrame(allocator: std.mem.Allocator, fd: i32) ![]u8 {
    var length_bytes: [4]u8 = undefined;
    try readExact(fd, &length_bytes);
    const length = std.mem.readInt(u32, &length_bytes, .big);
    if (length == 0 or length > max_frame_bytes) return error.InvalidFrame;
    const frame = try allocator.alloc(u8, length);
    errdefer allocator.free(frame);
    try readExact(fd, frame);
    return frame;
}

fn writeFrame(fd: i32, frame: []const u8) !void {
    if (frame.len == 0 or frame.len > max_frame_bytes) return error.InvalidFrame;
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(frame.len), .big);
    try writeAll(fd, &length_bytes);
    try writeAll(fd, frame);
}

fn readExact(fd: i32, out: []u8) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const result = linux.read(fd, out[offset..].ptr, out.len - offset);
        if (linux.errno(result) != .SUCCESS) return error.ReadFailed;
        if (result == 0) return error.EndOfStream;
        offset += result;
    }
}

fn writeAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        if (result == 0) return error.EndOfStream;
        offset += result;
    }
}

fn syscallFd(result: usize) !i32 {
    if (linux.errno(result) != .SUCCESS or result > std.math.maxInt(i32)) return error.SyscallFailed;
    return @intCast(result);
}

fn syscallOk(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.SyscallFailed;
}

fn close(fd: i32) void {
    _ = linux.close(fd);
}
