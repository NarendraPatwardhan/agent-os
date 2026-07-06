//! wasm3/raw.zig — the `m3ApiRawFunction` handlers that record a generated
//! `Pending` and dispatch it shallowly (ZIG_KERNEL §2.7, §7.1, §4.1).
//!
//! Owns: the single raw trampoline registered for every `mc_sys_*` import. It
//!   recovers the guest context from wasm3 userdata, decodes the generated
//!   `Pending` from wasm3's raw stack slots, records it, and delegates fulfillment
//!   to syscall.zig. Blocking/yielding outcomes call back into guest.zig's driver
//!   entrypoint to start Asyncify; policy stays out of this file.
//! Invariants: the raw trampoline is on the Asyncify only-list; syscall.zig and
//!   the guest driver frame are not.

const constants = @import("constants_zig");
const mc = @import("mc_zig");
const syscall = @import("../syscall.zig");
const task = @import("../task.zig");
const wasm3 = @import("bindings.zig");

const exit_result_message: [*:0]const u8 = "agent-os-exit";
const fuel_yield_result_message: [*:0]const u8 = "agent-os-fuel-yield";

pub fn exitResult() wasm3.Result {
    return @ptrCast(exit_result_message);
}

pub fn fuelYieldResult() wasm3.Result {
    return @ptrCast(fuel_yield_result_message);
}

pub fn i32Slot(value: i32) u64 {
    return @as(u64, @as(u32, @bitCast(value)));
}

fn slotI32(slot: u64) i32 {
    return @bitCast(@as(u32, @truncate(slot)));
}

pub const Context = struct {
    guest: syscall.Guest,
    record_pending: *const fn (*anyopaque, mc.Pending) void,
    park_blocked: *const fn (*anyopaque, mc.Pending, task.BlockReason) bool,
    park_ready: *const fn (*anyopaque, mc.Pending) bool,
    start_syscall_suspend: *const fn (*anyopaque) bool,
    finish_rewind: *const fn (*anyopaque) void,
    resume_result: *const fn (*anyopaque) i32,
    mark_exited: *const fn (*anyopaque, i32) void,
    pcall_run_fn: *const fn (*anyopaque) ?*wasm3.Function,
    pcall_unwind_active: *const fn (*anyopaque) bool,
    pcall_rewind_active: *const fn (*anyopaque) bool,
    pcall_depth: *const fn (*anyopaque) usize,
    pcall_push_frame: *const fn (*anyopaque) i32,
    pcall_pop_restore: *const fn (*anyopaque) i32,
    pcall_record_throw: *const fn (*anyopaque, i32) void,
    pcall_take_throw: *const fn (*anyopaque) ?i32,

    fn recordPending(self: *Context, pending: mc.Pending) void {
        self.record_pending(self.guest.ptr, pending);
    }

    fn parkBlocked(self: *Context, pending: mc.Pending, reason: task.BlockReason) bool {
        return self.park_blocked(self.guest.ptr, pending, reason);
    }

    fn parkReady(self: *Context, pending: mc.Pending) bool {
        return self.park_ready(self.guest.ptr, pending);
    }

    fn startSyscallSuspend(self: *Context) bool {
        return self.start_syscall_suspend(self.guest.ptr);
    }

    fn finishRewind(self: *Context) void {
        self.finish_rewind(self.guest.ptr);
    }

    fn resumeResult(self: *Context) i32 {
        return self.resume_result(self.guest.ptr);
    }

    fn markExited(self: *Context, code: i32) void {
        self.mark_exited(self.guest.ptr, code);
    }

    fn pcallRunFn(self: *Context) ?*wasm3.Function {
        return self.pcall_run_fn(self.guest.ptr);
    }

    fn pcallUnwindActive(self: *Context) bool {
        return self.pcall_unwind_active(self.guest.ptr);
    }

    fn pcallRewindActive(self: *Context) bool {
        return self.pcall_rewind_active(self.guest.ptr);
    }

    fn pcallDepth(self: *Context) usize {
        return self.pcall_depth(self.guest.ptr);
    }

    fn pcallPushFrame(self: *Context) i32 {
        return self.pcall_push_frame(self.guest.ptr);
    }

    fn pcallPopRestore(self: *Context) i32 {
        return self.pcall_pop_restore(self.guest.ptr);
    }

    fn pcallRecordThrow(self: *Context, code: i32) void {
        self.pcall_record_throw(self.guest.ptr, code);
    }

    fn pcallTakeThrow(self: *Context) ?i32 {
        return self.pcall_take_throw(self.guest.ptr);
    }
};

fn rawContext(runtime: ?*wasm3.Runtime) ?*Context {
    const userdata = wasm3.m3_GetUserData(runtime) orelse return null;
    return @ptrCast(@alignCast(userdata));
}

fn suspendOrResume(ctx: *Context, sp: [*]u64) void {
    if (ctx.startSyscallSuspend()) {
        sp[0] = i32Slot(ctx.resumeResult());
        ctx.finishRewind();
    }
}

pub fn rawSyscall(runtime: ?*wasm3.Runtime, import_ctx: wasm3.ImportContext, sp: [*]u64, mem: ?*anyopaque) callconv(.c) wasm3.Result {
    const desc_userdata = import_ctx.userdata orelse {
        sp[0] = i32Slot(-constants.ENOSYS);
        return null;
    };
    const desc: *const mc.Desc = @ptrCast(@alignCast(desc_userdata));
    const pending = mc.pendingFromRaw(desc, sp) orelse {
        sp[0] = i32Slot(-constants.ENOSYS);
        return null;
    };
    const ctx = rawContext(runtime) orelse {
        sp[0] = i32Slot(-constants.EIO);
        return null;
    };

    ctx.recordPending(pending);
    switch (syscall.fulfillOutcome(runtime, mem, &ctx.guest, pending)) {
        .Resume => |code| sp[0] = i32Slot(code),
        .Exit => |code| {
            ctx.markExited(code);
            return exitResult();
        },
        .Block => |reason| {
            if (!ctx.parkBlocked(pending, reason)) {
                sp[0] = i32Slot(-constants.EIO);
                return null;
            }
            suspendOrResume(ctx, sp);
        },
        .Pending => {
            if (!ctx.parkReady(pending)) {
                sp[0] = i32Slot(-constants.EIO);
                return null;
            }
            suspendOrResume(ctx, sp);
        },
    }
    return null;
}

pub fn rawSetThrow(runtime: ?*wasm3.Runtime, import_ctx: wasm3.ImportContext, sp: [*]u64, mem: ?*anyopaque) callconv(.c) wasm3.Result {
    _ = import_ctx;
    _ = mem;

    const ctx = rawContext(runtime) orelse {
        sp[0] = i32Slot(-constants.EIO);
        return null;
    };
    ctx.pcallRecordThrow(slotI32(sp[1]));
    sp[0] = i32Slot(constants.ESUCCESS);
    return null;
}

pub fn rawPcall(runtime: ?*wasm3.Runtime, import_ctx: wasm3.ImportContext, sp: [*]u64, mem: ?*anyopaque) callconv(.c) wasm3.Result {
    _ = import_ctx;
    _ = mem;

    const ctx = rawContext(runtime) orelse {
        sp[0] = i32Slot(-constants.EIO);
        return null;
    };
    const child = ctx.pcallRunFn() orelse {
        sp[0] = i32Slot(-constants.EINVAL);
        return null;
    };

    if (!(ctx.pcallRewindActive() and ctx.pcallDepth() != 0)) {
        const push_result = ctx.pcallPushFrame();
        if (push_result != constants.ESUCCESS) {
            sp[0] = i32Slot(push_result);
            return null;
        }
    }

    const child_result = wasm3.m3_Call(child, 0, null);
    if (ctx.pcallUnwindActive()) return null;

    const pop_result = ctx.pcallPopRestore();
    if (pop_result != constants.ESUCCESS) {
        sp[0] = i32Slot(pop_result);
        return null;
    }

    if (child_result == wasm3.m3Err_trapUnreachable) {
        const code = ctx.pcallTakeThrow() orelse return child_result;
        sp[0] = i32Slot(code);
        return null;
    }
    if (child_result != null) return child_result;

    sp[0] = i32Slot(constants.ESUCCESS);
    return null;
}
