//! ambient.zig - ambient time, entropy, and ABI syscall fulfillment.
//!
//! Owns: ABI version reporting, monotonic/realtime clocks, cached wall time,
//!   and guest-visible random bytes.
//! Invariants: ambient syscalls require ambient capability where applicable, and
//!   guest result pointers are checked before writes.
//! Consumes: the bridge clock/entropy imports, scheduler task state, constants,
//!   and shared memory codecs.
//! Not here: sleeping, process state, file descriptors, or network egress.

const bridge = @import("../bridge.zig");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("../state.zig");
const mem = @import("mem.zig");

const Guest = mem.Guest;
const GuestMemory = mem.GuestMemory;
const currentTask = mem.currentTask;
const neg = mem.neg;
const guestRange = mem.guestRange;
const writeGuestU32 = mem.writeGuestU32;
const writeGuestI64 = mem.writeGuestI64;

pub fn fulfillAbiVersion(memory: GuestMemory, args: mc.AbiVersionArgs) i32 {
    if (!writeGuestU32(memory, args.ret, @intCast(constants.abi_version()))) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

pub fn fulfillTimeMonotonic(guest: *const Guest, memory: GuestMemory, args: mc.TimeMonotonicArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_AMBIENT)) return neg(constants.EPERM);
    if (!writeGuestI64(memory, args.ret, bridge.mc_time_monotonic())) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

pub fn fulfillTimeRealtime(guest: *const Guest, memory: GuestMemory, args: mc.TimeRealtimeArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_AMBIENT)) return neg(constants.EPERM);
    const now = bridge.mc_time_now();
    state.kernel().wall_ms = now;
    if (!writeGuestI64(memory, args.ret, now)) return neg(constants.EINVAL);
    return constants.ESUCCESS;
}

pub fn fulfillRandom(guest: *const Guest, memory: GuestMemory, args: mc.RandomArgs) i32 {
    const t = currentTask(guest) orelse return neg(constants.EIO);
    if (!t.caps.has(constants.CAP_AMBIENT)) return neg(constants.EPERM);
    const out = guestRange(memory, args.ptr, args.len) orelse return neg(constants.EINVAL);
    if (out.len != 0) bridge.mc_random(out.ptr, out.len);
    return constants.ESUCCESS;
}
