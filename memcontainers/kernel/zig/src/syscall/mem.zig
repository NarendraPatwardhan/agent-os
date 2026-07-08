//! mem.zig - shared syscall memory and result primitives.
//!
//! Owns: the guest-runtime interface, linear-memory range checks, little-endian
//!   codecs, and the common fulfillment/errno helpers used by syscall families.
//! Invariants: guest pointers are checked before every access, and guest faults
//!   become errno-valued fulfillment results instead of host traps.
//! Consumes: task state, errno mapping, and constants needed by shared helpers.
//! Not here: domain syscall policy, fd ownership, or the dispatcher switch.

const std = @import("std");
const constants = @import("constants_zig");
const state = @import("../state.zig");
const task_mod = @import("../task.zig");
const vfs = @import("../vfs.zig");

const Task = task_mod.Task;
const TaskId = task_mod.TaskId;
const BlockReason = task_mod.BlockReason;

pub const Guest = struct {
    ptr: *anyopaque,
    task_id: *const fn (*anyopaque) TaskId,
    /// Instantiate a runtime for an already-created child task (spawn). Lives in
    /// guest.zig — which imports this file, so the call crosses the layer as a callback
    /// (the same pattern as `task_id`), never a circular import. Returns false if the
    /// child's program could not be parsed/compiled/linked.
    create_child: *const fn (child_id: TaskId, bytes: []const u8, cwd: []const u8) bool,

    pub fn taskId(self: *const Guest) TaskId {
        return self.task_id(self.ptr);
    }

    /// Instantiate the child guest for `child_id` (its Task must already exist).
    pub fn createChild(self: *const Guest, child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
        return self.create_child(child_id, bytes, cwd);
    }
};

pub const Fulfillment = union(enum) {
    Resume: i32,
    Block: BlockReason,
    Pending,
    Exit: i32,
};


pub fn finish(code: i32) Fulfillment {
    return .{ .Resume = code };
}

pub fn neg(errno: i32) i32 {
    // Historical Zig scaffolding named this helper after the host-side trap
    // convention, but the mc syscall ABI returns positive WASI errno values:
    // 0 on success, nonzero errno on failure. Keep the helper name so the
    // broad call-site surface stays stable while matching the oracle ABI.
    return errno;
}

/// FsError -> errno (positive WASI). Single source in errno.zig; re-exported so the syscall
/// call sites keep the bare `errnoFromFs` spelling.
pub const errnoFromFs = @import("../errno.zig").errnoFromFs;

pub const GuestMemory = struct {
    base: [*]u8,
    len: usize,

    pub fn from(base_any: ?*anyopaque, len: usize) ?GuestMemory {
        const base: [*]u8 = @ptrCast(base_any orelse return null);
        return .{ .base = base, .len = len };
    }

    pub fn range(self: GuestMemory, ptr: u32, len: u32) ?[]u8 {
        const start: usize = @intCast(ptr);
        const n: usize = @intCast(len);
        const end = std.math.add(usize, start, n) catch return null;
        if (end > self.len) return null;
        return self.base[start..end];
    }
};

pub fn guestRange(memory: GuestMemory, ptr: u32, len: u32) ?[]u8 {
    return memory.range(ptr, len);
}

pub fn writeGuestBytes(memory: GuestMemory, ptr: u32, bytes: []const u8) bool {
    if (bytes.len > std.math.maxInt(u32)) return false;
    const out = guestRange(memory, ptr, @intCast(bytes.len)) orelse return false;
    if (bytes.len != 0) @memcpy(out, bytes);
    return true;
}

pub fn writeGuestU32(memory: GuestMemory, ptr: u32, value: u32) bool {
    const out = guestRange(memory, ptr, 4) orelse return false;
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
    out[3] = @truncate(value >> 24);
    return true;
}

pub fn writeGuestI64(memory: GuestMemory, ptr: u32, value: i64) bool {
    const out = guestRange(memory, ptr, 8) orelse return false;
    const raw: u64 = @bitCast(value);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[i] = @truncate(raw >> @as(u6, @intCast(i * 8)));
    }
    return true;
}

pub fn readGuestI64(memory: GuestMemory, ptr: u32) ?i64 {
    const in = guestRange(memory, ptr, 8) orelse return null;
    var raw: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        raw |= @as(u64, in[i]) << @as(u6, @intCast(i * 8));
    }
    return @bitCast(raw);
}

pub fn readLeI32(bytes: []const u8, off: usize) i32 {
    const raw = @as(u32, bytes[off]) |
        (@as(u32, bytes[off + 1]) << 8) |
        (@as(u32, bytes[off + 2]) << 16) |
        (@as(u32, bytes[off + 3]) << 24);
    return @bitCast(raw);
}

pub fn readLeI16(bytes: []const u8, off: usize) i16 {
    const raw = @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
    return @bitCast(raw);
}

pub fn writeLeI16(bytes: []u8, off: usize, value: i16) void {
    const raw: u16 = @bitCast(value);
    bytes[off] = @truncate(raw);
    bytes[off + 1] = @truncate(raw >> 8);
}

pub fn writeLeU32(bytes: []u8, off: i32, value: u32) void {
    const i: usize = @intCast(off);
    bytes[i] = @truncate(value);
    bytes[i + 1] = @truncate(value >> 8);
    bytes[i + 2] = @truncate(value >> 16);
    bytes[i + 3] = @truncate(value >> 24);
}

pub fn writeLeU64(bytes: []u8, off: i32, value: u64) void {
    const start: usize = @intCast(off);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        bytes[start + i] = @truncate(value >> @as(u6, @intCast(i * 8)));
    }
}

pub fn writeLeI64(bytes: []u8, off: i32, value: i64) void {
    writeLeU64(bytes, off, @bitCast(value));
}

pub fn currentTask(guest: *const Guest) ?*Task {
    return state.kernel().sched.getTask(guest.taskId());
}

pub fn fdIndex(fd: i32) ?usize {
    if (fd < 0) return null;
    return @intCast(fd);
}

pub fn fsErr(e: vfs.FsError) i32 {
    return neg(errnoFromFs(e));
}

pub fn readGuestUtf8(memory: GuestMemory, ptr: u32, len: u32) ?[]const u8 {
    const bytes = guestRange(memory, ptr, len) orelse return null;
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    return bytes;
}

pub fn appendU32(out: *std.ArrayList(u8), a: std.mem.Allocator, value: u32) void {
    out.append(a, @truncate(value)) catch @panic("OOM");
    out.append(a, @truncate(value >> 8)) catch @panic("OOM");
    out.append(a, @truncate(value >> 16)) catch @panic("OOM");
    out.append(a, @truncate(value >> 24)) catch @panic("OOM");
}
