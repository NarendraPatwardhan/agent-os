//! wamr/alloc.zig - WAMR runtime allocator hooks.
//!
//! Owns: the allocator callbacks registered with WAMR's C runtime.
//! Invariants: every returned payload has a checked header, and allocation
//!   traffic goes through the kernel GPA only while state is initialized.
//! Consumes: kernel state and the standard allocator/math primitives.
//! Not here: WAMR module loading, native registration, or guest scheduling.

const std = @import("std");
const state = @import("../state.zig");

pub const WAMR_ALLOC_ALIGN: usize = 16;

// Sentinel stamped into every wamrAlloc'd block's header. wamrFree/wamrRealloc assert it before
// trusting base_addr/total_len — a free or realloc of a pointer WAMR did not get from wamrAlloc would
// otherwise read a garbage header and free a wild base (heap corruption). Catches the class loudly.
pub const WAMR_ALLOC_MAGIC: u64 = 0x6d63_776d_725f_6821; // "mcwmr_h!" (u64: usize is 32-bit on wasm32)

pub const WamrAllocHeader = extern struct {
    magic: u64,
    base_addr: usize,
    total_len: usize,
    requested_len: usize,
};

pub fn alignForward(value: usize, comptime alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

pub fn wamrAlloc(size_raw: c_uint) callconv(.c) ?*anyopaque {
    if (!state.isInitialized()) return null;
    const size: usize = @max(@as(usize, @intCast(size_raw)), 1);
    const header_len = @sizeOf(WamrAllocHeader);
    const total = std.math.add(usize, size, header_len + WAMR_ALLOC_ALIGN - 1) catch return null;
    const raw = state.kernel().gpa.alloc(u8, total) catch return null;
    const payload_addr = alignForward(@intFromPtr(raw.ptr) + header_len, WAMR_ALLOC_ALIGN);
    const header: *WamrAllocHeader = @ptrFromInt(payload_addr - header_len);
    header.* = .{
        .magic = WAMR_ALLOC_MAGIC,
        .base_addr = @intFromPtr(raw.ptr),
        .total_len = total,
        .requested_len = size,
    };
    return @ptrFromInt(payload_addr);
}

pub fn wamrFree(ptr: ?*anyopaque) callconv(.c) void {
    const payload = ptr orelse return;
    if (!state.isInitialized()) return; // kernel torn down — the whole heap is going away
    const header: *WamrAllocHeader = @ptrFromInt(@intFromPtr(payload) - @sizeOf(WamrAllocHeader));
    if (header.magic != WAMR_ALLOC_MAGIC) @panic("wamrFree: pointer not from wamrAlloc (bad allocation header)");
    const base: [*]u8 = @ptrFromInt(header.base_addr);
    state.kernel().gpa.free(base[0..header.total_len]);
}

pub fn wamrRealloc(ptr: ?*anyopaque, size_raw: c_uint) callconv(.c) ?*anyopaque {
    const size: usize = @max(@as(usize, @intCast(size_raw)), 1);
    const old = ptr orelse return wamrAlloc(size_raw);
    if (!state.isInitialized()) return null; // symmetry with wamrAlloc's guard
    const old_header: *WamrAllocHeader = @ptrFromInt(@intFromPtr(old) - @sizeOf(WamrAllocHeader));
    if (old_header.magic != WAMR_ALLOC_MAGIC) @panic("wamrRealloc: pointer not from wamrAlloc (bad allocation header)");
    const next = wamrAlloc(size_raw) orelse return null;
    const copy_len = @min(old_header.requested_len, size);
    if (copy_len != 0) {
        const old_bytes: [*]const u8 = @ptrCast(old);
        const new_bytes: [*]u8 = @ptrCast(next);
        @memcpy(new_bytes[0..copy_len], old_bytes[0..copy_len]);
    }
    wamrFree(old);
    return next;
}
