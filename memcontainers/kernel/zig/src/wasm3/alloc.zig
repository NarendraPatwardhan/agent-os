//! Kernel-owned allocation hooks for the embedded wasm3 C library.
//!
//! wasm3 calls these through the `d_m3AgentOsAllocator` patch. The arena is
//! deliberately inside Zig/kernel linear memory, not a C fixed heap or host
//! import. It is a deterministic bootstrap allocator; later guest-runtime work
//! should hang it off the root Kernel state with per-runtime accounting.

const std = @import("std");

const HEAP_BYTES = 64 * 1024 * 1024;
const ALIGN = 16;

const Header = extern struct {
    requested_len: usize,
    block_len: usize,
};

const HEADER_BYTES = @sizeOf(Header);

var heap: [HEAP_BYTES]u8 align(ALIGN) = undefined;
var cursor: usize = 0;
var last_payload: usize = 0;
var has_last_payload: bool = false;

fn alignForward(value: usize) ?usize {
    const mask = ALIGN - 1;
    const adjusted = std.math.add(usize, value, mask) catch return null;
    return adjusted & ~@as(usize, mask);
}

fn headerAt(offset: usize) *Header {
    return @ptrCast(@alignCast(&heap[offset]));
}

fn offsetOf(ptr: *anyopaque) ?usize {
    const base = @intFromPtr(&heap[0]);
    const addr = @intFromPtr(ptr);
    if (addr < base) return null;
    const offset = addr - base;
    if (offset >= heap.len) return null;
    return offset;
}

pub fn reset() void {
    cursor = 0;
    last_payload = 0;
    has_last_payload = false;
}

pub fn usedBytes() usize {
    return cursor;
}

fn agentOsWasm3Alloc(size: usize) callconv(.c) ?*anyopaque {
    const requested_len = if (size == 0) 1 else size;
    const block_len = alignForward(HEADER_BYTES + requested_len) orelse return null;
    const end = std.math.add(usize, cursor, block_len) catch return null;
    if (end > heap.len) return null;

    const header_offset = cursor;
    const payload_offset = header_offset + HEADER_BYTES;
    const header = headerAt(header_offset);
    header.* = .{
        .requested_len = requested_len,
        .block_len = block_len,
    };
    @memset(heap[payload_offset..][0..requested_len], 0);

    cursor = end;
    last_payload = payload_offset;
    has_last_payload = true;
    return @ptrCast(&heap[payload_offset]);
}

fn agentOsWasm3Free(ptr: ?*anyopaque) callconv(.c) void {
    const raw = ptr orelse return;
    const payload_offset = offsetOf(raw) orelse return;
    if (!has_last_payload or payload_offset != last_payload or payload_offset < HEADER_BYTES) return;

    const header_offset = payload_offset - HEADER_BYTES;
    cursor = header_offset;
    last_payload = 0;
    has_last_payload = false;
}

fn agentOsWasm3Realloc(ptr: ?*anyopaque, new_size: usize, old_size: usize) callconv(.c) ?*anyopaque {
    if (ptr == null) return agentOsWasm3Alloc(new_size);
    if (new_size == 0) {
        agentOsWasm3Free(ptr);
        return null;
    }

    const raw = ptr.?;
    const payload_offset = offsetOf(raw) orelse return null;
    if (payload_offset < HEADER_BYTES) return null;
    const header_offset = payload_offset - HEADER_BYTES;
    const header = headerAt(header_offset);
    const requested_len = if (new_size == 0) 1 else new_size;
    const block_len = alignForward(HEADER_BYTES + requested_len) orelse return null;

    if (has_last_payload and payload_offset == last_payload) {
        const end = std.math.add(usize, header_offset, block_len) catch return null;
        if (end > heap.len) return null;
        if (requested_len > header.requested_len) {
            @memset(heap[payload_offset + header.requested_len ..][0 .. requested_len - header.requested_len], 0);
        }
        header.* = .{
            .requested_len = requested_len,
            .block_len = block_len,
        };
        cursor = end;
        return raw;
    }

    const new_raw = agentOsWasm3Alloc(new_size) orelse return null;
    const copy_len = @min(@min(old_size, header.requested_len), new_size);
    if (copy_len != 0) {
        const src: [*]const u8 = @ptrCast(raw);
        const dst: [*]u8 = @ptrCast(new_raw);
        @memcpy(dst[0..copy_len], src[0..copy_len]);
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
