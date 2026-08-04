const std = @import("std");
const snapshot_v1 = @import("frontend_snapshot_v1");

extern fn __wasm_call_ctors() void;

var constructors_ran = false;

fn ensureConstructors() void {
    if (constructors_ran)
        return;
    constructors_ran = true;
    __wasm_call_ctors();
}

export fn mc_luau_frontend_v1_init() void {
    ensureConstructors();
}

export fn mc_luau_frontend_v1_alloc(size: u32) u32 {
    ensureConstructors();
    if (size == 0)
        return 0;
    const allocation = std.heap.c_allocator.alloc(u8, size) catch return 0;
    return @intCast(@intFromPtr(allocation.ptr));
}

export fn mc_luau_frontend_v1_dealloc(pointer: u32, size: u32) void {
    if (pointer == 0 or size == 0)
        return;
    const bytes: [*]u8 = @ptrFromInt(pointer);
    std.heap.c_allocator.free(bytes[0..size]);
}

export fn mc_luau_frontend_v1_validate_snapshot(pointer: u32, size: u32) u32 {
    if (pointer == 0 or size == 0)
        return 1;
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    const snapshot = snapshot_v1.parse(bytes[0..size], snapshot_v1.production_identity) catch return 2;
    snapshot_v1.validateModel(snapshot) catch return 3;
    return 0;
}
