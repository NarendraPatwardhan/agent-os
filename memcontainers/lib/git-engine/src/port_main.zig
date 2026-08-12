const std = @import("std");
const contract = @import("git_zig");
const core = @import("core");
const Native = @import("native_backend").Native;
const gitz_sync = @import("utils/sync");

pub fn main(init: std.process.Init) !void {
    defer gitz_sync.deinitPools(init.gpa);
    var engine = core.Engine(Native).init(init.gpa, .{ .io = init.io });
    defer engine.deinit();

    var input_buffer: [8192]u8 = undefined;
    var output_buffer: [8192]u8 = undefined;
    var input_file = std.Io.File.stdin().reader(init.io, &input_buffer);
    var output_file = std.Io.File.stdout().writer(init.io, &output_buffer);
    const input = &input_file.interface;
    const output = &output_file.interface;
    var active_session: u32 = 0;

    while (true) {
        var length_bytes: [4]u8 = undefined;
        input.readSliceAll(&length_bytes) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const frame_length = readU32(&length_bytes);
        if (frame_length > contract.MAX_FRAME_BYTES) return error.FrameTooLarge;
        const frame = try init.gpa.alloc(u8, frame_length);
        defer init.gpa.free(frame);
        try input.readSliceAll(frame);

        const envelope = contract.decodeRequestEnvelope(frame) catch return error.InvalidEnvelope;
        const result_handle = if (envelope.opcode == contract.OP_SESSION_OPEN)
            engine.sessionOpen(envelope.payload, envelope.request_id)
        else if (envelope.opcode == contract.OP_SESSION_CLOSE) close: {
            if (active_session == 0) return error.NoActiveSession;
            _ = engine.sessionClose(active_session);
            active_session = 0;
            break :close 0;
        } else execute: {
            if (active_session == 0) return error.NoActiveSession;
            break :execute engine.execute(active_session, frame);
        };

        if (result_handle == 0) continue;
        if (envelope.opcode == contract.OP_SESSION_OPEN) {
            active_session = sessionHandleFromOpenResult(init.gpa, &engine, result_handle, envelope.request_id) catch return error.InvalidSessionResult;
        }
        const result_length = engine.resultLen(result_handle);
        var prefix: [4]u8 = undefined;
        writeU32(&prefix, result_length);
        try output.writeAll(&prefix);
        var offset: u32 = 0;
        var chunk: [4096]u8 = undefined;
        while (offset < result_length) {
            const count = engine.resultRead(result_handle, offset, chunk[0..@min(chunk.len, result_length - offset)]);
            if (count == 0) return error.ResultReadFailed;
            try output.writeAll(chunk[0..count]);
            offset += count;
        }
        try output.flush();
        _ = engine.resultFree(result_handle);
    }
}

fn sessionHandleFromOpenResult(allocator: std.mem.Allocator, engine: anytype, result_handle: u32, request_id: u32) !u32 {
    const length = engine.resultLen(result_handle);
    if (length == 0 or length > contract.MAX_RESULT_BYTES) return error.Truncated;
    const bytes = try allocator.alloc(u8, length);
    defer allocator.free(bytes);
    if (engine.resultRead(result_handle, 0, bytes) != length) return error.Truncated;
    const envelope = try contract.decodeResponseEnvelope(bytes);
    if (envelope.opcode != contract.OP_SESSION_OPEN or envelope.status != contract.STATUS_OK or envelope.request_id != request_id) return error.WrongResult;
    const result = try contract.Result.decode(allocator, envelope.payload);
    return result.handle orelse error.MissingSessionHandle;
}

fn readU32(bytes: []const u8) u32 { return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24); }
fn writeU32(bytes: *[4]u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}
