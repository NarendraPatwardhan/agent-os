const std = @import("std");
const linux = std.os.linux;
const runner = @import("runner_zig");

pub fn main() !void {
    const listener = try fd(linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    var address: linux.sockaddr.vm = .{
        .port = runner.RUNNER_DEFAULT_VSOCK_PORT,
        .cid = std.math.maxInt(u32),
        .flags = 0,
    };
    try ok(linux.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))));
    try ok(linux.listen(listener, 16));

    while (true) {
        reap();
        const connection = fd(linux.accept4(listener, null, null, linux.SOCK.CLOEXEC)) catch continue;
        const child = linux.fork();
        switch (linux.errno(child)) {
            .SUCCESS => {},
            else => {
                _ = linux.close(connection);
                continue;
            },
        }
        if (child == 0) runService(listener, connection);
        _ = linux.close(connection);
    }
}

fn runService(listener: i32, connection: i32) noreturn {
    _ = linux.close(listener);
    var input_pipe: [2]i32 = undefined;
    var output_pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&input_pipe, .{ .CLOEXEC = true })) != .SUCCESS or
        linux.errno(linux.pipe2(&output_pipe, .{ .CLOEXEC = true })) != .SUCCESS)
    {
        fatal("agentos-browser: failed to create runner pipes\n");
    }

    const child = linux.fork();
    if (linux.errno(child) != .SUCCESS) fatal("agentos-browser: failed to fork runner service\n");
    if (child != 0) proxy(connection, input_pipe, output_pipe, @intCast(child));

    _ = linux.close(connection);
    _ = linux.close(input_pipe[1]);
    _ = linux.close(output_pipe[0]);
    if (linux.errno(linux.dup2(input_pipe[0], 0)) != .SUCCESS or
        linux.errno(linux.dup2(output_pipe[1], 1)) != .SUCCESS)
    {
        fatal("agentos-browser: failed to attach runner pipes\n");
    }
    _ = linux.close(input_pipe[0]);
    _ = linux.close(output_pipe[1]);

    const path: [*:0]const u8 = "/usr/bin/setpriv";
    const argv = [_:null]?[*:0]const u8{
        path,
        "--reuid",
        "65533",
        "--regid",
        "65533",
        "--clear-groups",
        "/usr/bin/bun",
        "/opt/browser/service.ts",
        null,
    };
    const env = [_:null]?[*:0]const u8{
        "HOME=/run/browser-service",
        "PATH=/usr/bin:/bin",
        null,
    };
    _ = linux.execve(path, &argv, &env);
    fatal("agentos-browser: failed to execute runner service\n");
}

fn proxy(connection: i32, input_pipe: [2]i32, output_pipe: [2]i32, child: i32) noreturn {
    _ = linux.close(input_pipe[0]);
    _ = linux.close(output_pipe[1]);

    var sources = [_]linux.pollfd{
        .{ .fd = connection, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = output_pipe[0], .events = linux.POLL.IN, .revents = 0 },
    };
    while (true) {
        const result = linux.poll(&sources, sources.len, -1);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => break,
        }
        if (sources[0].revents & linux.POLL.IN != 0) {
            transfer(connection, input_pipe[1]) catch break;
        }
        if (sources[1].revents & linux.POLL.IN != 0) {
            transfer(output_pipe[0], connection) catch break;
        }
        if (sources[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0 or
            sources[1].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
        {
            break;
        }
    }

    _ = linux.close(connection);
    _ = linux.close(input_pipe[1]);
    _ = linux.close(output_pipe[0]);
    _ = linux.kill(child, linux.SIG.KILL);
    var status: u32 = 0;
    _ = linux.waitpid(child, &status, 0);
    linux.exit(0);
}

fn transfer(source: i32, destination: i32) !void {
    var buffer: [64 * 1024]u8 = undefined;
    const result = while (true) {
        const read = linux.read(source, &buffer, buffer.len);
        switch (linux.errno(read)) {
            .SUCCESS => break read,
            .INTR => continue,
            else => return error.StreamClosed,
        }
    };
    if (result == 0) return error.StreamClosed;

    var offset: usize = 0;
    while (offset < result) {
        const written = linux.write(destination, buffer[offset..].ptr, result - offset);
        switch (linux.errno(written)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.StreamClosed,
        }
        if (written == 0) return error.StreamClosed;
        offset += written;
    }
}

fn fatal(message: []const u8) noreturn {
    diagnostic(message);
    linux.exit(125);
}

fn diagnostic(message: []const u8) void {
    _ = linux.write(2, message.ptr, message.len);
}

fn reap() void {
    var status: u32 = 0;
    while (true) {
        const result = linux.waitpid(-1, &status, 1);
        if (linux.errno(result) != .SUCCESS or result == 0) return;
    }
}

fn fd(result: usize) !i32 {
    if (linux.errno(result) != .SUCCESS or result > std.math.maxInt(i32)) return error.SyscallFailed;
    return @intCast(result);
}

fn ok(result: usize) !void {
    if (linux.errno(result) != .SUCCESS) return error.SyscallFailed;
}
