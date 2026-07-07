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

const STACK_SIZE: u32 = 512 * 1024;
const ASYNCIFY_STACK_BYTES: usize = 1024 * 1024;
const PCALL_STACK_MAX: usize = 32;
const FUEL_QUANTUM: u64 = 2_000_000;
const DEFAULT_FUEL_LIFETIME: u64 = 50_000_000_000;
const HARD_FUEL_LIFETIME: u64 = 4_000_000_000_000;
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

fn readUleb(bytes: []const u8, at: usize) ?struct { value: u32, adv: usize } {
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

fn uniqueCustom(bytes: []const u8, name: []const u8) ?[]const u8 {
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

fn declaredFuel(bytes: []const u8) u64 {
    const payload = uniqueCustom(bytes, "mc_budget") orelse return DEFAULT_FUEL_LIFETIME;
    if (payload.len < 24) return DEFAULT_FUEL_LIFETIME;
    if (std.mem.readInt(u32, payload[0..4], .little) != 1) return DEFAULT_FUEL_LIFETIME;
    const fuel = std.mem.readInt(u64, payload[12..20], .little);
    if (fuel == 0) return DEFAULT_FUEL_LIFETIME;
    return @min(fuel, HARD_FUEL_LIFETIME);
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

const PcallFrame = struct {
    saved_sp: i32,
};

pub const Step = enum { ran, suspended, exited, faulted };

pub const GuestRuntime = struct {
    gpa: std.mem.Allocator = undefined,
    runtime: ?*wasm3.Runtime = null,
    /// The guest's wasm image, OWNED (duped in `init`). wasm3's `m3_ParseModule` REFERENCES
    /// this buffer rather than copying it, so it must outlive the module; `deinit` frees it.
    /// (pid 1 leaked it harmlessly before; a per-command spawn would dangle without this.)
    owned_bytes: ?[]u8 = null,
    function: ?*wasm3.Function = null,
    raw_context: raw.Context = undefined,
    task_id: TaskId = 0,
    pending: ?mc.Pending = null,
    suspended_pending: ?mc.Pending = null,
    suspend_kind: SuspendKind = .none,
    unwind_active: bool = false,
    rewind_active: bool = false,
    suspended: bool = false,
    requeued_this_boundary: bool = false,
    exited: bool = false,
    faulted: bool = false,
    exit_code: i32 = 0,
    active: bool = false,
    resume_result: i32 = 0,
    lifetime_remaining: u64 = DEFAULT_FUEL_LIFETIME,
    current_slice: u64 = 0,
    asyncify_stack: [ASYNCIFY_STACK_BYTES]u8 align(16) = undefined,
    asyncify_data: [2]u32 align(4) = .{ 0, 0 },
    pcall_stack: [PCALL_STACK_MAX]PcallFrame = undefined,
    pcall_depth: usize = 0,
    recorded_throw: ?i32 = null,
    pcall_run_fn: ?*wasm3.Function = null,
    sp_global: ?*wasm3.Global = null,

    pub fn init(self: *GuestRuntime, gpa: std.mem.Allocator, wasm_bytes: []const u8, entry: [*:0]const u8, task_id: TaskId, cwd: []const u8) bool {
        self.deinit();
        self.* = .{
            .gpa = gpa,
            .task_id = task_id,
            .lifetime_remaining = declaredFuel(wasm_bytes),
        };
        // Own the wasm image: wasm3 references it for the runtime's lifetime (see field doc).
        self.owned_bytes = gpa.dupe(u8, wasm_bytes) catch return false;
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
        const bytes = self.owned_bytes orelse return false;
        const parse_result = wasm3.m3_ParseModule(env, &module, bytes.ptr, @intCast(bytes.len));
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
        const find_result = wasm3.m3_FindFunction(&self.function, self.runtime, entry);
        if (!ok(find_result) or self.function == null) {
            self.deinit();
            return false;
        }

        const pcall_run_name: [:0]const u8 = "__mc_pcall_run";
        var pcall_run: ?*wasm3.Function = null;
        const pcall_find_result = wasm3.m3_FindFunction(&pcall_run, self.runtime, pcall_run_name.ptr);
        if (ok(pcall_find_result)) {
            self.pcall_run_fn = pcall_run;
        } else if (pcall_find_result == wasm3.m3Err_functionLookupFailed) {
            self.pcall_run_fn = null;
        } else {
            self.deinit();
            return false;
        }

        const stack_pointer_name: [:0]const u8 = "__stack_pointer";
        self.sp_global = wasm3.m3_FindGlobal(loaded_module, stack_pointer_name.ptr);
        if ((self.pcall_run_fn == null) != (self.sp_global == null)) {
            self.deinit();
            return false;
        }
        if (self.sp_global) |global| {
            if (wasm3.m3_GetGlobalType(global) != .i32) {
                self.deinit();
                return false;
            }
        }

        self.active = true;
        return true;
    }

    pub fn step(self: *GuestRuntime) Step {
        if (!self.active) return if (self.exited) .exited else .faulted;
        const runtime = self.runtime orelse return self.markFault();
        const function = self.function orelse return self.markFault();
        self.requeued_this_boundary = false;

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
                    if (!self.prepareNextFuelSlice(runtime)) {
                        return self.exitNow(EXIT_CODE_FUEL_EXHAUSTED);
                    }
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
        // Free the owned image AFTER the runtime (the module referenced it). Safe on a
        // fresh `.{}` runtime: owned_bytes is null there, so `self.gpa` (undefined until
        // `init`) is never touched — owned_bytes non-null implies `init` ran and set gpa.
        if (self.owned_bytes) |b| {
            self.gpa.free(b);
            self.owned_bytes = null;
        }
        self.runtime = null;
        self.function = null;
        self.pcall_run_fn = null;
        self.sp_global = null;
        self.pcall_depth = 0;
        self.recorded_throw = null;
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

    fn readStackPointer(self: *GuestRuntime) ?i32 {
        const global = self.sp_global orelse return null;
        var value = wasm3.TaggedValue{
            .type = .none,
            .value = .{ .i32_value = 0 },
        };
        if (!ok(wasm3.m3_GetGlobal(global, &value))) return null;
        if (value.type != .i32) return null;
        return @as(i32, @bitCast(value.value.i32_value));
    }

    fn writeStackPointer(self: *GuestRuntime, value: i32) bool {
        const global = self.sp_global orelse return false;
        const tagged = wasm3.TaggedValue{
            .type = .i32,
            .value = .{ .i32_value = @bitCast(value) },
        };
        return ok(wasm3.m3_SetGlobal(global, &tagged));
    }

    fn pushPcallFrame(self: *GuestRuntime) i32 {
        if (self.pcall_run_fn == null or self.sp_global == null) return -constants.EINVAL;
        if (self.pcall_depth >= self.pcall_stack.len) return -constants.EIO;
        const saved_sp = self.readStackPointer() orelse return -constants.EIO;
        self.pcall_stack[self.pcall_depth] = .{ .saved_sp = saved_sp };
        self.pcall_depth += 1;
        return constants.ESUCCESS;
    }

    fn popPcallFrameRestore(self: *GuestRuntime) i32 {
        if (self.pcall_depth == 0) return -constants.EIO;
        self.pcall_depth -= 1;
        const frame = self.pcall_stack[self.pcall_depth];
        if (!self.writeStackPointer(frame.saved_sp)) return -constants.EIO;
        return constants.ESUCCESS;
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

    fn requeueOnce(self: *GuestRuntime) void {
        if (self.requeued_this_boundary) return;
        self.requeued_this_boundary = true;
        if (state.isInitialized()) state.kernel().sched.requeue(self.task_id);
    }

    fn parkReady(self: *GuestRuntime, pending: mc.Pending) bool {
        self.suspended = true;
        self.suspend_kind = .syscall_pending;
        self.suspended_pending = pending;
        self.unwind_active = false;
        self.rewind_active = false;
        self.requeueOnce();
        return true;
    }

    fn parkFuelYield(self: *GuestRuntime) bool {
        self.suspended = true;
        self.suspend_kind = .fuel_yield;
        self.suspended_pending = null;
        self.unwind_active = false;
        self.rewind_active = false;
        self.requeueOnce();
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
        if (self.rewind_active) {
            _ = self.startFuelYieldSuspend();
            return null;
        }
        if (self.current_slice == 0) {
            self.lifetime_remaining = 0;
            self.current_slice = 0;
            return wasm3.m3Err_trapOutOfFuel;
        }
        self.lifetime_remaining -|= self.current_slice;
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

fn cbPcallRunFn(ptr: *anyopaque) ?*wasm3.Function {
    return guestFromAny(ptr).pcall_run_fn;
}

fn cbPcallUnwindActive(ptr: *anyopaque) bool {
    return guestFromAny(ptr).unwind_active;
}

fn cbPcallRewindActive(ptr: *anyopaque) bool {
    return guestFromAny(ptr).rewind_active;
}

fn cbPcallDepth(ptr: *anyopaque) usize {
    return guestFromAny(ptr).pcall_depth;
}

fn cbPcallPushFrame(ptr: *anyopaque) i32 {
    return guestFromAny(ptr).pushPcallFrame();
}

fn cbPcallPopRestore(ptr: *anyopaque) i32 {
    return guestFromAny(ptr).popPcallFrameRestore();
}

fn cbPcallRecordThrow(ptr: *anyopaque, code: i32) void {
    guestFromAny(ptr).recorded_throw = code;
}

fn cbPcallTakeThrow(ptr: *anyopaque) ?i32 {
    const guest = guestFromAny(ptr);
    const code = guest.recorded_throw orelse return null;
    guest.recorded_throw = null;
    return code;
}

/// Instantiate a child guest for an already-created child task (`spawn`). Heap-allocates a
/// GuestRuntime with a STABLE address (the raw trampoline recovers it via `m3_GetUserData`),
/// loads `bytes` eagerly, and — through `init` — points `child_id`'s `Task.guest` at it. The
/// tick loop drives it thereafter and frees it on exit via `destroyGuest`. False on load
/// failure (the caller resumes the parent's `spawn` with an errno). Owned via `Task.guest`,
/// not a module global (§4.2). Called through the `create_child` context hook (syscall.zig).
pub fn createChildGuest(child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
    const gpa = state.kernel().gpa;
    const g = gpa.create(GuestRuntime) catch return false;
    g.* = .{};
    if (!g.init(gpa, bytes, "_start", child_id, cwd)) {
        gpa.destroy(g);
        return false;
    }
    return true;
}

fn cbCreateChild(child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
    return createChildGuest(child_id, bytes, cwd);
}

/// Tear down and free a heap-allocated child GuestRuntime. The tick loop calls this when a
/// guest step reports `.exited`/`.faulted`: `deinit` frees the wasm3 runtime + owned image
/// and clears the `Task.guest` back-pointer; then the GuestRuntime allocation is released.
pub fn destroyGuest(g: *GuestRuntime) void {
    const gpa = g.gpa;
    g.deinit();
    gpa.destroy(g);
}

fn makeRawContext(self: *GuestRuntime) raw.Context {
    return .{
        .guest = .{ .ptr = @ptrCast(self), .task_id = cbTaskId, .create_child = cbCreateChild },
        .record_pending = cbRecordPending,
        .park_blocked = cbParkBlocked,
        .park_ready = cbParkReady,
        .start_syscall_suspend = cbStartSyscallSuspend,
        .finish_rewind = cbFinishRewind,
        .resume_result = cbResumeResult,
        .mark_exited = cbMarkExited,
        .pcall_run_fn = cbPcallRunFn,
        .pcall_unwind_active = cbPcallUnwindActive,
        .pcall_rewind_active = cbPcallRewindActive,
        .pcall_depth = cbPcallDepth,
        .pcall_push_frame = cbPcallPushFrame,
        .pcall_pop_restore = cbPcallPopRestore,
        .pcall_record_throw = cbPcallRecordThrow,
        .pcall_take_throw = cbPcallTakeThrow,
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
        const is_pcall = std.mem.eql(u8, desc.name, "mc_sys_pcall");
        const is_set_throw = std.mem.eql(u8, desc.name, "mc_sys_set_throw");
        const handler: wasm3.RawCall = if (is_pcall) raw.rawPcall else if (is_set_throw) raw.rawSetThrow else raw.rawSyscall;
        const userdata: ?*const anyopaque = if (is_pcall or is_set_throw) null else @ptrCast(desc);
        const result = wasm3.m3_LinkRawFunctionEx(
            module,
            mc_module.ptr,
            desc.name.ptr,
            desc.signature.ptr,
            handler,
            userdata,
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
