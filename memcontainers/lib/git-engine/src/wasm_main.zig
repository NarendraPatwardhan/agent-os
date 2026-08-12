const std = @import("std");
const contract = @import("git_zig");
const core = @import("core");
const Browser = @import("browser_backend").Browser;

const allocator = std.heap.wasm_allocator;
var runtime = core.Engine(Browser).init(allocator, .{});

export fn ao_git_abi_version() u32 { return (@as(u32, contract.PROTOCOL_VERSION) << 16) | @as(u32, contract.PROTOCOL_MINOR); }
export fn ao_git_capabilities() u64 { return @intCast(contract.CAPABILITY_CORE); }
export fn ao_git_buffer_alloc(len: u32) u32 {
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(bytes.ptr));
}
export fn ao_git_buffer_free(ptr: u32, len: u32) u32 {
    if (ptr == 0) return 1;
    allocator.free(@as([*]u8, @ptrFromInt(ptr))[0..len]);
    return 0;
}
export fn ao_git_session_open(ptr: u32, len: u32) u32 { return runtime.sessionOpen(@as([*]const u8, @ptrFromInt(ptr))[0..len], 0); }
export fn ao_git_session_close(handle: u32) u32 { return runtime.sessionClose(handle); }
export fn ao_git_execute(session: u32, ptr: u32, len: u32) u32 { return runtime.execute(session, @as([*]const u8, @ptrFromInt(ptr))[0..len]); }
export fn ao_git_result_len(handle: u32) u32 { return runtime.resultLen(handle); }
export fn ao_git_result_read(handle: u32, offset: u32, ptr: u32, cap: u32) u32 { return runtime.resultRead(handle, offset, @as([*]u8, @ptrFromInt(ptr))[0..cap]); }
export fn ao_git_result_free(handle: u32) u32 { return runtime.resultFree(handle); }
