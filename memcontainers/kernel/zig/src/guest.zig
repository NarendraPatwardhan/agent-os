//! guest.zig — the wasm3 guest driver AND the Asyncify unwind-stop / rewind-start
//! boundary (ZIG_KERNEL §2.7, §7.4). This is the most load-bearing file in the port.
//!
//! Owns: one wasm3 runtime per guest (its own stack + linear memory), eager compile
//!   (`m3_CompileModule` at load), generated `mc_sys_*` raw import registration,
//!   native fuel, and the Zig-owned suspend/resume driver.
//!
//! THE BOUNDARY (§7.4, §7.7, §15.2 — read before touching Asyncify):
//!   mc_tick                    ← NOT instrumented
//!    └ guest driver (this file) ← NOT instrumented ← unwind STOPS here / rewind STARTS here
//!       └ m3_Call ─┐
//!         wasm3 op chain        ← INSTRUMENTED (only-list)
//!          └ mc_sys_* trampoline ← INSTRUMENTED (thin: records Pending, returns)
//!             └ kernel_suspend() → asyncify_start_unwind(buf)
//!   A blocking syscall or quantum yield starts Asyncify in the raw/fuel path;
//!   instrumented wasm3 frames spill and return to THIS driver frame, which calls
//!   `asyncify_stop_unwind()` and returns normally to the scheduler. Resume calls
//!   `asyncify_start_rewind(buf)` here and re-enters `m3_Call`. The host never sees
//!   a suspend and there is no host-facing rewind export.

const std = @import("std");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const raw = @import("wasm3/raw.zig");
const state = @import("state.zig");
const syscall = @import("syscall.zig");
const task_mod = @import("task.zig");

/// The thin wasm3 C-API bindings (§7.2). No policy here — the driver owns policy (§7.1).
pub const wasm3 = @import("wasm3/bindings.zig");

comptime {
    // The wasm3 allocator hooks (the d_m3AgentOsAllocator patch calls agent_os_wasm3_alloc/
    // free/realloc) must be compiled into the kernel so wasm3's C links against them (A6).
    _ = @import("wasm3/alloc.zig");
}

const TaskId = task_mod.TaskId;

const STACK_SIZE: u32 = 64 * 1024;
const ASYNCIFY_STACK_BYTES: usize = 256 * 1024;
const FUEL_QUANTUM: u64 = 2_000_000;
const FUEL_LIFETIME: u64 = 50_000_000_000;
const EXIT_CODE_FUEL_EXHAUSTED: i32 = 137;

extern "asyncify" fn start_unwind(data: u32) void;
extern "asyncify" fn stop_unwind() void;
extern "asyncify" fn start_rewind(data: u32) void;
extern "asyncify" fn stop_rewind() void;

var shared_environment: ?*wasm3.Environment = null;

inline fn ok(result: wasm3.Result) bool {
    return result == null;
}

fn ptr32(ptr: anytype) u32 {
    return @intCast(@intFromPtr(ptr));
}

pub fn environment() ?*wasm3.Environment {
    if (shared_environment == null) shared_environment = wasm3.m3_NewEnvironment();
    return shared_environment;
}

const SuspendKind = enum {
    none,
    syscall_blocked,
    syscall_pending,
    fuel_yield,
};

pub const Step = enum { ran, suspended, exited, faulted };

pub const GuestRuntime = struct {
    gpa: std.mem.Allocator = undefined,
    runtime: ?*wasm3.Runtime = null,
    function: ?*wasm3.Function = null,
    raw_context: raw.Context = undefined,
    task_id: TaskId = 0,
    pending: ?mc.Pending = null,
    suspended_pending: ?mc.Pending = null,
    suspend_kind: SuspendKind = .none,
    unwind_active: bool = false,
    rewind_active: bool = false,
    suspended: bool = false,
    exited: bool = false,
    faulted: bool = false,
    exit_code: i32 = 0,
    active: bool = false,
    resume_result: i32 = 0,
    lifetime_remaining: u64 = FUEL_LIFETIME,
    current_slice: u64 = 0,
    asyncify_stack: [ASYNCIFY_STACK_BYTES]u8 align(16) = undefined,
    asyncify_data: [2]u32 align(4) = .{ 0, 0 },

    pub fn init(self: *GuestRuntime, gpa: std.mem.Allocator, wasm_bytes: []const u8, entry: [*:0]const u8, task_id: TaskId, cwd: []const u8) bool {
        self.deinit();
        self.* = .{
            .gpa = gpa,
            .task_id = task_id,
        };
        self.raw_context = makeRawContext(self);
        self.resetAsyncifyData();

        if (state.isInitialized()) {
            if (state.kernel().sched.getTask(task_id)) |t| {
                t.guest = @ptrCast(self);
                t.setCwd(gpa, cwd);
            }
        }

        const env = environment() orelse return false;
        self.runtime = wasm3.m3_NewRuntime(env, STACK_SIZE, @ptrCast(&self.raw_context)) orelse {
            self.deinit();
            return false;
        };
        wasm3.m3_ClearFuel(self.runtime);

        var module: ?*wasm3.Module = null;
        const parse_result = wasm3.m3_ParseModule(env, &module, wasm_bytes.ptr, @intCast(wasm_bytes.len));
        if (!ok(parse_result)) {
            self.deinit();
            return false;
        }
        const loaded_module = module orelse {
            self.deinit();
            return false;
        };

        const load_result = wasm3.m3_LoadModule(self.runtime, loaded_module);
        if (!ok(load_result)) {
            wasm3.m3_FreeModule(loaded_module);
            self.deinit();
            return false;
        }
        if (!linkRawSyscalls(loaded_module)) {
            self.deinit();
            return false;
        }
        const compile_result = wasm3.m3_CompileModule(loaded_module);
        if (!ok(compile_result)) {
            self.deinit();
            return false;
        }

        const find_result = wasm3.m3_FindFunction(&self.function, self.runtime, entry);
        if (!ok(find_result) or self.function == null) {
            self.deinit();
            return false;
        }

        self.active = true;
        return true;
    }

    pub fn step(self: *GuestRuntime) Step {
        if (!self.active) return if (self.exited) .exited else .faulted;
        const runtime = self.runtime orelse return self.markFault();
        const function = self.function orelse return self.markFault();

        if (self.suspended) {
            switch (self.suspend_kind) {
                .syscall_blocked => {
                    if (self.taskIsBlocked()) return .suspended;
                    if (!self.fulfillSuspendedSyscall(runtime)) return .suspended;
                },
                .syscall_pending => {
                    if (!self.fulfillSuspendedSyscall(runtime)) return .ran;
                },
                .fuel_yield => {
                    if (!self.prepareNextFuelSlice(runtime)) return self.exitNow(EXIT_CODE_FUEL_EXHAUSTED);
                },
                .none => return self.markFault(),
            }
            self.startSuspendedRewind();
        } else if (!self.prepareNextFuelSlice(runtime)) {
            return self.exitNow(EXIT_CODE_FUEL_EXHAUSTED);
        }

        const call_result = callGuestBoundary(function);
        if (call_result == raw.fuelYieldResult()) {
            if (!self.suspended) return self.markFault();
            self.stopSuspendedUnwind();
            return .ran;
        }
        if (call_result == raw.exitResult() or self.exited) {
            self.stopSuspendedUnwind();
            return self.exitNow(self.exit_code);
        }
        if (call_result == wasm3.m3Err_trapOutOfFuel) {
            return self.exitNow(EXIT_CODE_FUEL_EXHAUSTED);
        }
        if (!ok(call_result)) {
            return self.markFault();
        }
        if (self.suspended) {
            self.stopSuspendedUnwind();
            return switch (self.suspend_kind) {
                .syscall_blocked => .suspended,
                .syscall_pending, .fuel_yield => .ran,
                .none => self.markFault(),
            };
        }

        var result_value: u32 = 0;
        var ret_ptrs = [_]?*anyopaque{@ptrCast(&result_value)};
        if (ok(wasm3.m3_GetResults(function, 1, &ret_ptrs))) {
            self.exit_code = @bitCast(result_value);
        } else {
            self.exit_code = 0;
        }
        return self.exitNow(self.exit_code);
    }

    pub fn deinit(self: *GuestRuntime) void {
        if (self.runtime) |runtime| wasm3.m3_FreeRuntime(runtime);
        if (state.isInitialized() and self.task_id != 0) {
            if (state.kernel().sched.getTask(self.task_id)) |t| {
                if (t.guest == @as(*anyopaque, @ptrCast(self))) t.guest = null;
            }
        }
        self.runtime = null;
        self.function = null;
        self.active = false;
    }

    pub fn exitCode(self: *GuestRuntime) i32 {
        return self.exit_code;
    }

    fn markFault(self: *GuestRuntime) Step {
        self.faulted = true;
        self.active = false;
        return .faulted;
    }

    fn exitNow(self: *GuestRuntime, code: i32) Step {
        self.exit_code = code;
        self.exited = true;
        self.active = false;
        if (state.isInitialized()) {
            if (state.kernel().sched.getTask(self.task_id)) |t| {
                if (t.state != .zombie) state.kernel().sched.exitTask(self.task_id, code);
            }
        }
        return .exited;
    }

    fn markExited(self: *GuestRuntime, code: i32) void {
        self.exit_code = code;
        self.exited = true;
    }

    fn taskIsBlocked(self: *GuestRuntime) bool {
        if (!state.isInitialized()) return false;
        const t = state.kernel().sched.getTask(self.task_id) orelse return false;
        return t.state == .blocked;
    }

    fn resetAsyncifyData(self: *GuestRuntime) void {
        const stack_start = ptr32(&self.asyncify_stack);
        self.asyncify_data[0] = stack_start;
        self.asyncify_data[1] = stack_start + self.asyncify_stack.len;
    }

    fn asyncifyDataPtr(self: *GuestRuntime) u32 {
        return ptr32(&self.asyncify_data);
    }

    fn recordPending(self: *GuestRuntime, pending: mc.Pending) void {
        self.pending = pending;
    }

    fn parkBlocked(self: *GuestRuntime, pending: mc.Pending, reason: task_mod.BlockReason) bool {
        self.suspended = true;
        self.suspend_kind = .syscall_blocked;
        self.suspended_pending = pending;
        self.unwind_active = false;
        self.rewind_active = false;
        if (state.isInitialized()) state.kernel().sched.blockTask(self.task_id, reason);
        return true;
    }

    fn parkReady(self: *GuestRuntime, pending: mc.Pending) bool {
        self.suspended = true;
        self.suspend_kind = .syscall_pending;
        self.suspended_pending = pending;
        self.unwind_active = false;
        self.rewind_active = false;
        if (state.isInitialized()) state.kernel().sched.requeue(self.task_id);
        return true;
    }

    fn parkFuelYield(self: *GuestRuntime) bool {
        self.suspended = true;
        self.suspend_kind = .fuel_yield;
        self.suspended_pending = null;
        self.unwind_active = false;
        self.rewind_active = false;
        if (state.isInitialized()) state.kernel().sched.requeue(self.task_id);
        return true;
    }

    fn startSyscallSuspend(self: *GuestRuntime) bool {
        if (self.rewind_active) {
            stop_rewind();
            self.unwind_active = false;
            return true;
        }
        self.resetAsyncifyData();
        self.unwind_active = true;
        start_unwind(self.asyncifyDataPtr());
        return false;
    }

    fn startFuelYieldSuspend(self: *GuestRuntime) bool {
        if (self.rewind_active) {
            stop_rewind();
            self.finishRewind();
            return true;
        }
        self.resetAsyncifyData();
        self.unwind_active = true;
        start_unwind(self.asyncifyDataPtr());
        return false;
    }

    fn stopSuspendedUnwind(self: *GuestRuntime) void {
        if (!self.unwind_active) return;
        stop_unwind();
        self.unwind_active = false;
    }

    fn startSuspendedRewind(self: *GuestRuntime) void {
        self.rewind_active = true;
        start_rewind(self.asyncifyDataPtr());
    }

    fn finishRewind(self: *GuestRuntime) void {
        self.unwind_active = false;
        self.rewind_active = false;
        self.suspended = false;
        self.suspend_kind = .none;
        self.suspended_pending = null;
    }

    fn prepareNextFuelSlice(self: *GuestRuntime, runtime: ?*wasm3.Runtime) bool {
        if (self.lifetime_remaining == 0) return false;
        const slice = @min(self.lifetime_remaining, FUEL_QUANTUM);
        if (slice == 0) return false;
        self.current_slice = slice;
        wasm3.m3_SetFuel(runtime, slice);
        return true;
    }

    fn fuelExhausted(self: *GuestRuntime) wasm3.Result {
        if (self.current_slice == 0 or self.current_slice >= self.lifetime_remaining) {
            self.lifetime_remaining = 0;
            self.current_slice = 0;
            return wasm3.m3Err_trapOutOfFuel;
        }
        self.lifetime_remaining -= self.current_slice;
        self.current_slice = 0;
        if (!self.parkFuelYield()) return wasm3.m3Err_trapOutOfFuel;
        if (self.startFuelYieldSuspend()) return null;
        return raw.fuelYieldResult();
    }

    fn fulfillSuspendedSyscall(self: *GuestRuntime, runtime: ?*wasm3.Runtime) bool {
        const pending = self.suspended_pending orelse return false;
        var memory_size: u32 = 0;
        const mem = wasm3.m3_GetMemory(runtime, &memory_size, 0) orelse return false;
        if (memory_size == 0) return false;

        switch (syscall.fulfillOutcome(runtime, mem, &self.raw_context.guest, pending)) {
            .Resume => |code| {
                self.resume_result = code;
                return true;
            },
            .Exit => |code| {
                self.resume_result = code;
                self.markExited(code);
                return true;
            },
            .Block => |reason| {
                _ = self.parkBlocked(pending, reason);
                return false;
            },
            .Pending => {
                _ = self.parkReady(pending);
                return false;
            },
        }
    }
};

fn guestFromAny(ptr: *anyopaque) *GuestRuntime {
    return @ptrCast(@alignCast(ptr));
}

fn cbTaskId(ptr: *anyopaque) TaskId {
    return guestFromAny(ptr).task_id;
}

fn cbRecordPending(ptr: *anyopaque, pending: mc.Pending) void {
    guestFromAny(ptr).recordPending(pending);
}

fn cbParkBlocked(ptr: *anyopaque, pending: mc.Pending, reason: task_mod.BlockReason) bool {
    return guestFromAny(ptr).parkBlocked(pending, reason);
}

fn cbParkReady(ptr: *anyopaque, pending: mc.Pending) bool {
    return guestFromAny(ptr).parkReady(pending);
}

fn cbStartSyscallSuspend(ptr: *anyopaque) bool {
    return guestFromAny(ptr).startSyscallSuspend();
}

fn cbFinishRewind(ptr: *anyopaque) void {
    guestFromAny(ptr).finishRewind();
}

fn cbResumeResult(ptr: *anyopaque) i32 {
    return guestFromAny(ptr).resume_result;
}

fn cbMarkExited(ptr: *anyopaque, code: i32) void {
    guestFromAny(ptr).markExited(code);
}

fn makeRawContext(self: *GuestRuntime) raw.Context {
    return .{
        .guest = .{ .ptr = @ptrCast(self), .task_id = cbTaskId },
        .record_pending = cbRecordPending,
        .park_blocked = cbParkBlocked,
        .park_ready = cbParkReady,
        .start_syscall_suspend = cbStartSyscallSuspend,
        .finish_rewind = cbFinishRewind,
        .resume_result = cbResumeResult,
        .mark_exited = cbMarkExited,
    };
}

fn runtimeGuest(runtime: ?*wasm3.Runtime) ?*GuestRuntime {
    const userdata = wasm3.m3_GetUserData(runtime) orelse return null;
    const ctx: *raw.Context = @ptrCast(@alignCast(userdata));
    return guestFromAny(ctx.guest.ptr);
}

fn agentOsWasm3FuelExhausted(runtime: ?*wasm3.Runtime) callconv(.c) wasm3.Result {
    const guest = runtimeGuest(runtime) orelse return wasm3.m3Err_trapOutOfFuel;
    return guest.fuelExhausted();
}

noinline fn callGuestBoundary(function: ?*wasm3.Function) callconv(.c) wasm3.Result {
    return wasm3.m3_Call(function, 0, null);
}

pub fn linkRawSyscalls(module: ?*wasm3.Module) bool {
    const mc_module: [:0]const u8 = "mc";
    for (&mc.SYSCALLS) |*desc| {
        const result = wasm3.m3_LinkRawFunctionEx(
            module,
            mc_module.ptr,
            desc.name.ptr,
            desc.signature.ptr,
            raw.rawSyscall,
            @ptrCast(desc),
        );
        if (!ok(result) and result != wasm3.m3Err_functionLookupFailed) return false;
    }
    return true;
}

comptime {
    @export(&agentOsWasm3FuelExhausted, .{
        .name = "agent_os_wasm3_fuel_exhausted",
        .linkage = .strong,
        .visibility = .hidden,
    });
    @export(&callGuestBoundary, .{
        .name = "agent_os_guest_call_boundary",
        .linkage = .strong,
        .visibility = .hidden,
    });
}
