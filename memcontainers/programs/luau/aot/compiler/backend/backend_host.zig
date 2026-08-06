const std = @import("std");
const lower = @import("luau_aot_backend");

const allocator = std.heap.wasm_allocator;

const CompileResult = extern struct {
    data: u32,
    size: u32,
    status: u32,
    reserved: u32,
};

const status_ok: u32 = 0;
const status_invalid_argument: u32 = 1;
const status_compile_failure: u32 = 2;
const status_resource_limit: u32 = 3;

export fn mc_luau_backend_v1_alloc(size: u32) u32 {
    if (size == 0)
        return 0;
    const allocation = allocator.alloc(u8, size) catch return 0;
    return @intCast(@intFromPtr(allocation.ptr));
}

export fn mc_luau_backend_v1_dealloc(pointer: u32, size: u32) void {
    if (pointer == 0 or size == 0)
        return;
    const bytes: [*]u8 = @ptrFromInt(pointer);
    allocator.free(bytes[0..size]);
}

fn publishObject(result: *CompileResult, object_result: lower.Error![]u8) u32 {
    result.* = .{ .data = 0, .size = 0, .status = status_compile_failure, .reserved = 0 };
    const object = object_result catch |err| {
        const status: u32 = switch (err) {
            error.OutOfMemory, error.ResourceLimit => status_resource_limit,
            else => status_compile_failure,
        };
        result.status = status;
        return status;
    };
    if (object.len > std.math.maxInt(u32)) {
        allocator.free(object);
        result.status = status_resource_limit;
        return status_resource_limit;
    }

    result.data = @intCast(@intFromPtr(object.ptr));
    result.size = @intCast(object.len);
    result.status = status_ok;
    return status_ok;
}

export fn mc_luau_backend_v1_compile(snapshot_pointer: u32, snapshot_size: u32, function_id: u32, result_pointer: u32) u32 {
    if (snapshot_pointer == 0 or snapshot_size == 0 or result_pointer == 0)
        return status_invalid_argument;

    const result: *CompileResult = @ptrFromInt(result_pointer);
    const snapshot_bytes: [*]const u8 = @ptrFromInt(snapshot_pointer);
    return publishObject(result, lower.build(allocator, snapshot_bytes[0..snapshot_size], function_id));
}

export fn mc_luau_backend_v1_compile_package(snapshot_pointer: u32, snapshot_size: u32, result_pointer: u32) u32 {
    if (snapshot_pointer == 0 or snapshot_size == 0 or result_pointer == 0)
        return status_invalid_argument;

    const result: *CompileResult = @ptrFromInt(result_pointer);
    const snapshot_bytes: [*]const u8 = @ptrFromInt(snapshot_pointer);
    return publishObject(result, lower.buildPackage(allocator, snapshot_bytes[0..snapshot_size]));
}

export fn mc_luau_backend_v1_compile_static_package(package_pointer: u32, package_size: u32, result_pointer: u32) u32 {
    if (package_pointer == 0 or package_size == 0 or result_pointer == 0)
        return status_invalid_argument;

    const result: *CompileResult = @ptrFromInt(result_pointer);
    const package_bytes: [*]const u8 = @ptrFromInt(package_pointer);
    return publishObject(result, lower.buildStaticPackage(allocator, package_bytes[0..package_size]));
}

export fn mc_luau_backend_v1_free(result_pointer: u32) void {
    if (result_pointer == 0)
        return;
    const result: *CompileResult = @ptrFromInt(result_pointer);
    if (result.data != 0 and result.size != 0) {
        const bytes: [*]u8 = @ptrFromInt(result.data);
        allocator.free(bytes[0..result.size]);
    }
    result.* = .{ .data = 0, .size = 0, .status = status_ok, .reserved = 0 };
}
