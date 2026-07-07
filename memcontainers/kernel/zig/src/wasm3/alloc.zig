//! Kernel-owned allocation hooks for the embedded wasm3 C library.
//!
//! wasm3 calls these through the `d_m3AgentOsAllocator` patch. The storage is
//! deliberately inside Zig/kernel linear memory, not a C fixed heap or host
//! import. Use the same wasm allocator class as the kernel state so multiple
//! live runtimes can coexist. wasm3 keeps several internal pointers in compiled
//! runtime structures, so the hooks keep the prior conservative non-reuse
//! behavior while removing the fixed 64 MiB ceiling.

const std = @import("std");

const ALIGN = 16;
const HEADER_BYTES_ALIGNED = std.mem.alignForward(usize, @sizeOf(Header), ALIGN);

const Header = extern struct {
    requested_len: usize,
    block_len: usize,
};

const wasm_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &std.heap.WasmAllocator.vtable,
};

fn alignForward(value: usize) ?usize {
    const mask = ALIGN - 1;
    const adjusted = std.math.add(usize, value, mask) catch return null;
    return adjusted & ~@as(usize, mask);
}

fn headerFromPayload(ptr: *anyopaque) *Header {
    const base_addr = @intFromPtr(ptr) - HEADER_BYTES_ALIGNED;
    return @ptrFromInt(base_addr);
}

pub fn reset() void {
    // Kept for older diagnostics; wasm3 allocations now use the kernel allocator.
}

pub fn usedBytes() usize {
    return 0;
}

fn agentOsWasm3Alloc(size: usize) callconv(.c) ?*anyopaque {
    const requested_len = if (size == 0) 1 else size;
    const total_len = std.math.add(usize, HEADER_BYTES_ALIGNED, requested_len) catch return null;
    const block_len = alignForward(total_len) orelse return null;
    const block = wasm_allocator.alignedAlloc(u8, .fromByteUnits(ALIGN), block_len) catch return null;
    const payload = block.ptr + HEADER_BYTES_ALIGNED;

    const header: *Header = @ptrCast(@alignCast(block.ptr));
    header.* = .{
        .requested_len = requested_len,
        .block_len = block_len,
    };
    @memset(payload[0..requested_len], 0);
    return @ptrCast(payload);
}

fn agentOsWasm3Free(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
}

fn agentOsWasm3Realloc(ptr: ?*anyopaque, new_size: usize, old_size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return agentOsWasm3Alloc(new_size);
    if (new_size == 0) {
        agentOsWasm3Free(ptr);
        return null;
    }

    const raw = ptr.?;
    const header = headerFromPayload(raw);
    const requested_len = if (new_size == 0) 1 else new_size;

    const new_raw = agentOsWasm3Alloc(new_size) orelse return null;
    const copy_len = @min(@min(old_size, header.requested_len), new_size);
    if (copy_len != 0) {
        const src: [*]const u8 = @ptrCast(raw);
        const dst: [*]u8 = @ptrCast(new_raw);
        @memcpy(dst[0..copy_len], src[0..copy_len]);
    }
    if (requested_len > copy_len) {
        const dst: [*]u8 = @ptrCast(new_raw);
        @memset(dst[copy_len..requested_len], 0);
    }
    return new_raw;
}

comptime {
    @export(&agentOsWasm3Alloc, .{
        .name = "agent_os_wasm3_alloc",
        .linkage = .strong,
        .visibility = .hidden,
    });
    @export(&agentOsWasm3Free, .{
        .name = "agent_os_wasm3_free",
        .linkage = .strong,
        .visibility = .hidden,
    });
    @export(&agentOsWasm3Realloc, .{
        .name = "agent_os_wasm3_realloc",
        .linkage = .strong,
        .visibility = .hidden,
    });
}
