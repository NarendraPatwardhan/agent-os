//! buf.zig - host-control scratch-buffer protocol.
//!
//! Owns: the shared control buffer, host-visible buffer pointer export, checked
//!   reads from host-written regions, and replacement of operation results.
//! Invariants: every host-provided region is bounds-checked before use, and
//!   result-producing operations replace the buffer the host re-queries.
//! Consumes: kernel global state and the kernel allocator.
//! Not here: control-frame encoding, VFS policy, exec jobs, or service calls.

const std = @import("std");
const state = @import("../state.zig");

/// Copy `len` bytes out of the control buffer at `ptr` (bounds-checked), duped into `a`.
pub fn ctlBytes(a: std.mem.Allocator, ptr: u32, len: u32) ?[]u8 {
    const k = state.kernel();
    const start: usize = ptr;
    const end = start +% @as(usize, len);
    if (end < start or end > k.ctl_buffer.items.len) return null;
    return a.dupe(u8, k.ctl_buffer.items[start..end]) catch @panic("OOM");
}

/// Read a UTF-8 path/string out of the control buffer.
pub fn ctlStr(a: std.mem.Allocator, ptr: u32, len: u32) ?[]u8 {
    const b = ctlBytes(a, ptr, len) orelse return null;
    if (!std.unicode.utf8ValidateSlice(b)) return null;
    return b;
}

/// Replace the scratch buffer with `bytes` (an op result the host reads via mc_ctl_buf(0)).
pub fn replaceBuffer(bytes: []const u8) void {
    const k = state.kernel();
    k.ctl_buffer.clearRetainingCapacity();
    k.ctl_buffer.appendSlice(k.gpa, bytes) catch @panic("OOM");
}

/// Ensure the control buffer is at least `len` bytes and return its address. mc_ctl_buf(0)
/// returns the current pointer for reading a result.
pub fn buf(len: usize) ?[*]u8 {
    const k = state.kernel();
    if (k.ctl_buffer.items.len < len) {
        k.ctl_buffer.resize(k.gpa, len) catch return null;
    }
    return k.ctl_buffer.items.ptr;
}
