//! wasm_sections.zig — the one bounds-checked parser for wasm custom sections.
//!
//! `mc_budget` / `mc_tier` / `mc_service` ride in `\x00asm` custom sections the kernel reads off a
//! guest's own (untrusted) bytes at exec. This LEB128 + section walk was hand-copied three times
//! (guest.zig, state.zig, syscall.zig) — a security parser over attacker-controlled input where a
//! bounds bug fixed in one copy would silently persist in the others (the copies had already begun
//! to diverge cosmetically). One source now, mirroring the single copy in the Rust oracle.
//!
//! Depends on `std` only, so any consumer — including `Tier.fromModule` in task.zig — can import it
//! without a cycle. The typed readers that interpret a section's payload live with their types:
//! `Tier.fromModule` (task.zig), `declaredFuel` (guest.zig), `declaredService` (state.zig).

const std = @import("std");

/// Read an unsigned LEB128 at `bytes[at..]`; null on truncation or >32-bit overflow.
pub fn readUleb(bytes: []const u8, at: usize) ?struct { value: u32, adv: usize } {
    var result: u32 = 0;
    var shift: u32 = 0;
    var n: usize = 0;
    while (true) {
        if (at + n >= bytes.len) return null;
        if (shift >= 32) return null;
        const byte = bytes[at + n];
        n += 1;
        const low = @as(u32, byte & 0x7f);
        if (shift == 28 and low > 0x0f) return null;
        result |= low << @as(u5, @intCast(shift));
        if ((byte & 0x80) == 0) return .{ .value = result, .adv = n };
        shift += 7;
    }
}

/// Return the payload of the wasm custom section named `name`, or null if absent, malformed, or
/// defined more than once (a duplicate is rejected — a repeated `mc_tier` must never become a
/// privilege-escalation gate). Every offset is bounds-checked against `bytes`.
pub fn uniqueCustom(bytes: []const u8, name: []const u8) ?[]const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm")) return null;
    var found: ?[]const u8 = null;
    var i: usize = 8;
    while (i < bytes.len) {
        const id = bytes[i];
        i += 1;
        const size_info = readUleb(bytes, i) orelse return null;
        i += size_info.adv;
        const body_start = i;
        const body_end = std.math.add(usize, body_start, @intCast(size_info.value)) catch return null;
        if (body_end > bytes.len) return null;
        if (id == 0) {
            const name_info = readUleb(bytes, body_start) orelse return null;
            const name_start = body_start + name_info.adv;
            const name_end = std.math.add(usize, name_start, @intCast(name_info.value)) catch return null;
            if (name_end <= body_end and std.mem.eql(u8, bytes[name_start..name_end], name)) {
                if (found != null) return null;
                found = bytes[name_end..body_end];
            }
        }
        i = body_end;
    }
    return found;
}
