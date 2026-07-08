//! guest.zig - WAMR guest driver and mc_sys_* native bridge.
//!
//! Owns one WAMR module instance and exec_env per task, backed by one shared WAMR
//! runtime initialized from Kernel state. The scheduler sees the same small
//! GuestRuntime interface as before: init, step, deinit, and exitCode.

const std = @import("std");
const constants = @import("constants_zig");
const mc = @import("mc_zig");
const state = @import("state.zig");
const syscall = @import("syscall.zig");
const task_mod = @import("task.zig");
const wamr = @import("wamr/bindings.zig");
const wamr_alloc = @import("wamr/alloc.zig");
const sections = @import("wasm_sections.zig");
const pcall = @import("guest/pcall.zig");
const instrument = @import("instrument.zig");

const TaskId = task_mod.TaskId;
const PCALL_STACK_MAX = pcall.PCALL_STACK_MAX;
const PcallFrame = pcall.PcallFrame;
const NativeBoundary = pcall.NativeBoundary;

const STACK_SIZE: u32 = 512 * 1024;
const HOST_HEAP_SIZE: u32 = 0;
const ERROR_BUF_SIZE: u32 = 256;
const FUEL_QUANTUM: u64 = 2_000_000;
const DEFAULT_FUEL_LIFETIME: u64 = 50_000_000_000;
const HARD_FUEL_LIFETIME: u64 = 4_000_000_000_000;
const EXIT_CODE_FUEL_EXHAUSTED: i32 = 137;
const MAX_RAW_CELLS: usize = 16;

const MC_MODULE: [:0]const u8 = "mc";
const ERR_NATIVE_CONTEXT: [:0]const u8 = "mc native bridge missing guest context";
const ERR_RETURN_SLOT: [:0]const u8 = "mc native bridge missing return slot";
const ERR_PCALL_YIELD: [:0]const u8 = "mc pcall yielded";

fn declaredFuel(bytes: []const u8) u64 {
    const payload = sections.uniqueCustom(bytes, "mc_budget") orelse return DEFAULT_FUEL_LIFETIME;
    if (payload.len < 24) return DEFAULT_FUEL_LIFETIME;
    if (std.mem.readInt(u32, payload[0..4], .little) != 1) return DEFAULT_FUEL_LIFETIME;
    const fuel = std.mem.readInt(u64, payload[12..20], .little);
    if (fuel == 0) return DEFAULT_FUEL_LIFETIME;
    return @min(fuel, HARD_FUEL_LIFETIME);
}

const SuspendKind = enum {
    none,
    syscall_blocked,
    syscall_pending,
    fuel_yield,
};

pub const Step = enum { ran, suspended, exited, faulted };

/// A content-addressed, never-evicted cache of loaded WAMR modules (§4.3: each distinct program is
/// preprocessed exactly once). Keyed by a 64-bit content hash; the value is a list to disambiguate
/// the (astronomically rare) hash collision by exact bytes. Both the module and its backing bytes
/// live in kernel linear memory (WAMR + gpa allocations), so they are captured by a snapshot and are
/// owned by the cache for the VM's lifetime — a GuestRuntime borrows a `*Module` and never unloads it.
pub const ModuleCacheEntry = struct { key: []u8, load_buf: []u8, module: *wamr.Module };
pub const ModuleCache = std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(ModuleCacheEntry));

/// Return the loaded `*Module` for `wasm_bytes`, loading + caching it on first sight (§4.3: each
/// distinct program is preprocessed exactly once). Returns null only on a genuine load failure;
/// `error_buf` receives WAMR's message. Never evicts.
///
/// Two copies are kept per module, on purpose: `wasm_runtime_load` WRITES INTO its input buffer during
/// preprocessing, so the buffer we hand it can no longer serve as the content-address key. We therefore
/// keep a PRISTINE `key` copy for the collision-safe byte comparison, and a separate `load_buf` that
/// WAMR mutates and continues to reference for the module's lifetime. (Keying on the pristine bytes is
/// what makes the cache actually hit across repeated spawns of the same binary.)
fn cachedModule(k: *state.Kernel, wasm_bytes: []const u8, error_buf: [*]u8) ?*wamr.Module {
    const h = std.hash.Wyhash.hash(0, wasm_bytes);
    const gop = k.module_cache.getOrPut(k.gpa, h) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    for (gop.value_ptr.items) |e| {
        if (std.mem.eql(u8, e.key, wasm_bytes)) return e.module;
    }
    const key = k.gpa.dupe(u8, wasm_bytes) catch return null;
    const load_buf = k.gpa.dupe(u8, wasm_bytes) catch {
        k.gpa.free(key);
        return null;
    };
    instrument.begin(.loadmiss);
    const module = wamr.wasm_runtime_load(load_buf.ptr, @intCast(load_buf.len), error_buf, ERROR_BUF_SIZE) orelse {
        k.gpa.free(key);
        k.gpa.free(load_buf);
        return null;
    };
    instrument.end(.loadmiss);
    gop.value_ptr.append(k.gpa, .{ .key = key, .load_buf = load_buf, .module = module }) catch {
        // Could not record the module; unload + free so we neither leak nor cache an untracked module.
        wamr.wasm_runtime_unload(module);
        k.gpa.free(key);
        k.gpa.free(load_buf);
        return null;
    };
    return module;
}

pub const GuestRuntime = struct {
    gpa: std.mem.Allocator = undefined,
    module: ?*wamr.Module = null,
    module_inst: ?*wamr.ModuleInst = null,
    exec_env: ?*wamr.ExecEnv = null,
    function: ?*wamr.Function = null,
    pcall_run_fn: ?*wamr.Function = null,
    stack_pointer: ?*u32 = null,
    raw_guest: syscall.Guest = undefined,
    task_id: TaskId = 0,
    pending: ?mc.Pending = null,
    suspended_pending: ?mc.Pending = null,
    suspended_return_slot: ?*u32 = null,
    suspend_kind: SuspendKind = .none,
    syscall_yield_requested: bool = false,
    suspended: bool = false,
    requeued_this_boundary: bool = false,
    exited: bool = false,
    faulted: bool = false,
    exit_code: i32 = 0,
    active: bool = false,
    resume_result: i32 = 0,
    lifetime_remaining: u64 = DEFAULT_FUEL_LIFETIME,
    current_slice: u64 = 0,
    pcall_stack: [PCALL_STACK_MAX]PcallFrame = undefined,
    pcall_depth: usize = 0,
    recorded_throw: ?i32 = null,
    error_buf: [ERROR_BUF_SIZE]u8 = undefined,

    /// Initialize a GuestRuntime from raw (uninitialized) memory: dup the module bytes, load and
    /// instantiate the WAMR module, create the exec_env, resolve the entry + pcall exports. On any
    /// error the partially-built runtime is torn down exactly once by `errdefer self.deinit()` (the
    /// single, idempotent cleanup path); the caller then frees the struct. Never call on a live
    /// runtime — deinit it first.
    pub fn init(self: *GuestRuntime, gpa: std.mem.Allocator, wasm_bytes: []const u8, entry: [*:0]const u8, task_id: TaskId, cwd: []const u8) !void {
        self.* = .{
            .gpa = gpa,
            .task_id = task_id,
            .lifetime_remaining = declaredFuel(wasm_bytes),
        };
        errdefer self.deinit();
        self.raw_guest = .{ .ptr = @ptrCast(self), .task_id = cbTaskId, .create_child = cbCreateChild };

        if (state.isInitialized()) {
            if (state.kernel().sched.getTask(task_id)) |t| {
                t.guest = @ptrCast(self);
                t.setCwd(gpa, cwd);
            }
        }

        if (!ensureWamrInitialized()) return error.WamrInit;

        // Load-once/instantiate-many (§4.3): the preprocessed module is shared, content-addressed, and
        // owned by the kernel's module cache; this runtime only creates a fresh instance + exec_env.
        @memset(self.error_buf[0..], 0);
        instrument.begin(.load);
        self.module = cachedModule(state.kernel(), wasm_bytes, self.error_buf[0..].ptr) orelse {
            syscall.termWrite("wamr load failed\n", true);
            syscall.termWrite(std.mem.sliceTo(self.error_buf[0..].ptr, 0), true);
            syscall.termWrite("\n", true);
            return error.WamrLoad;
        };
        instrument.end(.load);
        instrument.begin(.instantiate);
        self.module_inst = wamr.wasm_runtime_instantiate(self.module, STACK_SIZE, HOST_HEAP_SIZE, self.error_buf[0..].ptr, ERROR_BUF_SIZE) orelse {
            syscall.termWrite("wamr instantiate failed\n", true);
            syscall.termWrite(std.mem.sliceTo(self.error_buf[0..].ptr, 0), true);
            syscall.termWrite("\n", true);
            return error.WamrInstantiate;
        };
        instrument.end(.instantiate);
        wamr.wasm_runtime_set_custom_data(self.module_inst, @ptrCast(self));

        instrument.begin(.execenv);
        self.exec_env = wamr.wasm_runtime_create_exec_env(self.module_inst, STACK_SIZE) orelse {
            syscall.termWrite("wamr exec env failed\n", true);
            return error.WamrExecEnv;
        };
        instrument.end(.execenv);
        self.function = wamr.wasm_runtime_lookup_function(self.module_inst, entry) orelse {
            syscall.termWrite("wamr lookup failed\n", true);
            return error.WamrLookup;
        };
        self.initPcallExports() orelse return error.PcallExports;

        self.active = true;
    }

    pub fn step(self: *GuestRuntime) Step {
        if (!self.active) return if (self.exited) .exited else .faulted;
        const exec_env = self.exec_env orelse return self.markFault();
        const function = self.function orelse return self.markFault();

        self.requeued_this_boundary = false;
        var should_resume = false;

        if (self.suspended) {
            switch (self.suspend_kind) {
                .syscall_blocked => {
                    if (self.taskIsBlocked()) return .suspended;
                    if (!self.fulfillSuspendedSyscall()) return .suspended;
                    if (self.exited) return self.exitNow(self.exit_code);
                    should_resume = true;
                },
                .syscall_pending => {
                    if (!self.fulfillSuspendedSyscall()) return .ran;
                    if (self.exited) return self.exitNow(self.exit_code);
                    should_resume = true;
                },
                .fuel_yield => {
                    should_resume = true;
                },
                .none => return self.markFault(),
            }
        }

        if (!self.prepareNextFuelSlice()) return self.exitNow(EXIT_CODE_FUEL_EXHAUSTED);
        if (should_resume) self.finishSuspensionForResume();
        self.clearWamrBlockingFlag();

        var argv = [_]u32{0};
        instrument.begin(.run);
        const status = if (should_resume)
            wamr.wasm_runtime_resume(exec_env, 1, argv[0..].ptr)
        else
            wamr.wasm_runtime_call_wasm_status(exec_env, function, 0, argv[0..].ptr);
        instrument.end(.run);
        return self.handleStatus(status, argv[0]);
    }

    pub fn deinit(self: *GuestRuntime) void {
        instrument.begin(.teardown);
        if (self.exec_env) |exec_env| wamr.wasm_runtime_destroy_exec_env(exec_env);
        self.exec_env = null;
        if (self.module_inst) |module_inst| {
            wamr.wasm_runtime_set_custom_data(module_inst, null);
            wamr.wasm_runtime_deinstantiate(module_inst);
        }
        self.module_inst = null;
        instrument.end(.teardown);
        // The module itself is NOT unloaded: it is owned by the kernel's content-addressed module
        // cache (§4.3, never evicted) and may be shared by other live instances.
        self.module = null;
        if (state.isInitialized() and self.task_id != 0) {
            if (state.kernel().sched.getTask(self.task_id)) |t| {
                if (t.guest == @as(*anyopaque, @ptrCast(self))) t.guest = null;
            }
        }
        self.function = null;
        self.pcall_run_fn = null;
        self.stack_pointer = null;
        self.pcall_depth = 0;
        self.recorded_throw = null;
        self.pending = null;
        self.suspended_pending = null;
        self.suspended_return_slot = null;
        self.suspend_kind = .none;
        self.suspended = false;
        self.syscall_yield_requested = false;
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

    fn memoryView(self: *GuestRuntime) ?syscall.GuestMemory {
        const module_inst = self.module_inst orelse return null;
        const memory = wamr.wasm_runtime_get_memory(module_inst, 0) orelse return null;
        const base = wamr.wasm_memory_get_base_address(memory) orelse return null;
        const pages = wamr.wasm_memory_get_cur_page_count(memory);
        const page_bytes = wamr.wasm_memory_get_bytes_per_page(memory);
        const len64 = std.math.mul(u64, pages, page_bytes) catch return null;
        if (len64 > std.math.maxInt(usize)) return null;
        return syscall.GuestMemory.from(base, @intCast(len64));
    }

    fn initPcallExports(self: *GuestRuntime) ?void {
        const module_inst = self.module_inst orelse return null;
        const pcall_run_name: [:0]const u8 = "__mc_pcall_run";
        self.pcall_run_fn = wamr.wasm_runtime_lookup_function(module_inst, pcall_run_name.ptr);
        if (self.pcall_run_fn == null) wamr.wasm_runtime_clear_exception(module_inst);

        const stack_pointer_name: [:0]const u8 = "__stack_pointer";
        var global = std.mem.zeroes(wamr.GlobalInst);
        if (wamr.wasm_runtime_get_export_global_inst(module_inst, stack_pointer_name.ptr, &global)) {
            if (global.kind != .i32 or !global.is_mutable) return null;
            self.stack_pointer = @ptrCast(@alignCast(global.global_data orelse return null));
        } else {
            self.stack_pointer = null;
            wamr.wasm_runtime_clear_exception(module_inst);
        }

        if ((self.pcall_run_fn == null) != (self.stack_pointer == null)) return null;
        return {};
    }

    fn readStackPointer(self: *GuestRuntime) ?i32 {
        const ptr = self.stack_pointer orelse return null;
        return @bitCast(ptr.*);
    }

    fn writeStackPointer(self: *GuestRuntime, value: i32) bool {
        const ptr = self.stack_pointer orelse return false;
        ptr.* = @bitCast(value);
        return true;
    }

    fn pushPcallFrame(self: *GuestRuntime, index: *usize) i32 {
        if (self.pcall_run_fn == null or self.stack_pointer == null) return -constants.EINVAL;
        if (self.pcall_depth >= self.pcall_stack.len) return -constants.EIO;
        const saved_sp = self.readStackPointer() orelse return -constants.EIO;
        index.* = self.pcall_depth;
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

    fn markPcallWaiting(self: *GuestRuntime, index: usize, boundary: NativeBoundary) bool {
        if (index >= self.pcall_depth) return false;
        self.pcall_stack[index].return_slot = boundary.return_slot;
        self.pcall_stack[index].native_frame = boundary.native_frame;
        self.pcall_stack[index].caller_frame = boundary.caller_frame;
        self.pcall_stack[index].waiting = true;
        return true;
    }

    fn hasWaitingPcall(self: *const GuestRuntime) bool {
        return self.pcall_depth != 0 and self.pcall_stack[self.pcall_depth - 1].waiting;
    }

    fn completeWaitingPcall(self: *GuestRuntime, code: i32) bool {
        if (!self.hasWaitingPcall()) return false;
        self.pcall_depth -= 1;
        const frame = self.pcall_stack[self.pcall_depth];
        if (!self.writeStackPointer(frame.saved_sp)) return false;
        const slot = frame.return_slot orelse return false;
        slot.* = @as(u32, @bitCast(code));
        if (!self.finishWaitingPcallNativeFrame(frame)) return false;
        return true;
    }

    fn finishWaitingPcallNativeFrame(self: *GuestRuntime, frame: PcallFrame) bool {
        const exec_env = self.exec_env orelse return false;
        const native_frame = frame.native_frame orelse return false;
        exec_env.cur_frame = frame.caller_frame orelse return false;
        exec_env.wasm_stack.top = @ptrCast(native_frame);
        exec_env.wasm_call_status = @intFromEnum(wamr.CallStatus.done);
        if (self.module_inst) |module_inst| wamr.wasm_runtime_clear_exception(module_inst);
        return true;
    }

    fn recordThrow(self: *GuestRuntime, code: i32) void {
        self.recorded_throw = code;
    }

    fn takeThrow(self: *GuestRuntime) ?i32 {
        const code = self.recorded_throw orelse return null;
        self.recorded_throw = null;
        return code;
    }

    fn prepareNextFuelSlice(self: *GuestRuntime) bool {
        if (self.lifetime_remaining == 0) return false;
        const slice = @min(self.lifetime_remaining, FUEL_QUANTUM);
        if (slice == 0 or slice > @as(u64, @intCast(std.math.maxInt(c_int)))) return false;
        self.current_slice = slice;
        wamr.wasm_runtime_set_instruction_count_limit(self.exec_env, @intCast(slice));
        return true;
    }

    fn clearWamrBlockingFlag(self: *GuestRuntime) void {
        const exec_env = self.exec_env orelse return;
        exec_env.suspend_flags.flags &= ~wamr.WASM_SUSPEND_FLAG_BLOCKING;
    }

    fn requestSyscallYield(self: *GuestRuntime, exec_env: ?*wamr.ExecEnv) void {
        self.syscall_yield_requested = true;
        const env = exec_env orelse return;
        env.suspend_flags.flags |= wamr.WASM_SUSPEND_FLAG_BLOCKING;
        env.instructions_to_execute = 0;
    }

    fn recordPending(self: *GuestRuntime, pending: mc.Pending) void {
        self.pending = pending;
    }

    fn parkBlocked(self: *GuestRuntime, pending: mc.Pending, reason: task_mod.BlockReason, return_slot: *u32) void {
        self.suspended = true;
        self.suspend_kind = .syscall_blocked;
        self.suspended_pending = pending;
        self.suspended_return_slot = return_slot;
        self.current_slice = 0;
        if (state.isInitialized()) state.kernel().sched.blockTask(self.task_id, reason);
    }

    fn requeueOnce(self: *GuestRuntime) void {
        if (self.requeued_this_boundary) return;
        self.requeued_this_boundary = true;
        if (state.isInitialized()) state.kernel().sched.requeue(self.task_id);
    }

    fn parkReady(self: *GuestRuntime, pending: mc.Pending, return_slot: *u32) void {
        self.suspended = true;
        self.suspend_kind = .syscall_pending;
        self.suspended_pending = pending;
        self.suspended_return_slot = return_slot;
        self.current_slice = 0;
        self.requeueOnce();
    }

    fn parkFuelYield(self: *GuestRuntime) void {
        self.suspended = true;
        self.suspend_kind = .fuel_yield;
        self.suspended_pending = null;
        self.suspended_return_slot = null;
        self.current_slice = 0;
        self.requeueOnce();
    }

    fn finishSuspensionForResume(self: *GuestRuntime) void {
        self.suspended = false;
        self.suspend_kind = .none;
        self.suspended_pending = null;
        self.suspended_return_slot = null;
        self.syscall_yield_requested = false;
    }

    fn writeSuspendedReturn(self: *GuestRuntime, code: i32) bool {
        const slot = self.suspended_return_slot orelse return false;
        slot.* = @as(u32, @bitCast(code));
        self.resume_result = code;
        return true;
    }

    fn fulfillSuspendedSyscall(self: *GuestRuntime) bool {
        const pending = self.suspended_pending orelse return false;
        const return_slot = self.suspended_return_slot orelse return false;
        const memory = self.memoryView() orelse return false;
        switch (syscall.fulfillOutcome(memory, &self.raw_guest, pending)) {
            .Resume => |code| return self.writeSuspendedReturn(code),
            .Exit => |code| {
                _ = self.writeSuspendedReturn(code);
                self.markExited(code);
                return true;
            },
            .Block => |reason| {
                self.parkBlocked(pending, reason, return_slot);
                return false;
            },
            .Pending => {
                self.parkReady(pending, return_slot);
                return false;
            },
        }
    }

    fn handleStatus(self: *GuestRuntime, status: wamr.CallStatus, result_cell: u32) Step {
        return switch (status) {
            .done => blk: {
                if (self.hasWaitingPcall()) {
                    if (!self.completeWaitingPcall(constants.ESUCCESS)) break :blk self.markFault();
                    break :blk self.resumeAfterPcallCompletion();
                }
                self.current_slice = 0;
                if (self.exited) break :blk self.exitNow(self.exit_code);
                break :blk self.exitNow(@as(i32, @bitCast(result_cell)));
            },
            .yielded => blk: {
                if (self.hasWaitingPcall()) {
                    if (self.module_inst) |module_inst| wamr.wasm_runtime_clear_exception(module_inst);
                }
                if (self.exited) break :blk self.exitNow(self.exit_code);
                if (self.syscall_yield_requested or self.suspend_kind == .syscall_blocked or self.suspend_kind == .syscall_pending) {
                    self.syscall_yield_requested = false;
                    break :blk switch (self.suspend_kind) {
                        .syscall_blocked => .suspended,
                        .syscall_pending => .ran,
                        else => self.markFault(),
                    };
                }
                if (self.current_slice == 0) {
                    self.lifetime_remaining = 0;
                    break :blk self.exitNow(EXIT_CODE_FUEL_EXHAUSTED);
                }
                self.lifetime_remaining -|= self.current_slice;
                self.parkFuelYield();
                break :blk .ran;
            },
            .trap => blk: {
                if (self.hasWaitingPcall()) {
                    const code = self.takeThrow() orelse {
                        self.reportWamrTrap();
                        break :blk self.markFault();
                    };
                    if (self.module_inst) |module_inst| wamr.wasm_runtime_clear_exception(module_inst);
                    if (self.exec_env) |exec_env| exec_env.wasm_call_status = @intFromEnum(wamr.CallStatus.done);
                    if (!self.completeWaitingPcall(code)) break :blk self.markFault();
                    break :blk self.resumeAfterPcallCompletion();
                }
                self.reportWamrTrap();
                break :blk self.markFault();
            },
        };
    }

    fn resumeAfterPcallCompletion(self: *GuestRuntime) Step {
        const exec_env = self.exec_env orelse return self.markFault();
        self.clearWamrBlockingFlag();
        var argv = [_]u32{0};
        const status = wamr.wasm_runtime_resume(exec_env, 1, argv[0..].ptr);
        return self.handleStatus(status, argv[0]);
    }

    fn reportWamrTrap(self: *GuestRuntime) void {
        if (self.module_inst) |module_inst| {
            if (wamr.wasm_runtime_get_exception(module_inst)) |message| {
                syscall.termWrite("wamr trap: ", true);
                syscall.termWrite(std.mem.sliceTo(message, 0), true);
                syscall.termWrite("\n", true);
            } else {
                syscall.termWrite("wamr trap: <no exception>\n", true);
            }
        }
    }
};

fn cbTaskId(ptr: *anyopaque) TaskId {
    const guest: *GuestRuntime = @ptrCast(@alignCast(ptr));
    return guest.task_id;
}

fn cbCreateChild(child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
    return createChildGuest(child_id, bytes, cwd);
}

fn guestFromExecEnv(exec_env: ?*wamr.ExecEnv) ?*GuestRuntime {
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env) orelse return null;
    const custom = wamr.wasm_runtime_get_custom_data(module_inst) orelse return null;
    return @ptrCast(@alignCast(custom));
}

fn setRawReturn(raw_args: [*]u64, code: i32) void {
    raw_args[0] = @as(u32, @bitCast(code));
}

fn setException(exec_env: ?*wamr.ExecEnv, message: [*:0]const u8) void {
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env) orelse return;
    wamr.wasm_runtime_set_exception(module_inst, message);
}

fn rawI32(slot: u64) i32 {
    return @bitCast(@as(u32, @truncate(slot)));
}

fn clearHandledTrap(exec_env: ?*wamr.ExecEnv) void {
    const env = exec_env orelse return;
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env) orelse return;
    wamr.wasm_runtime_clear_exception(module_inst);
    env.wasm_call_status = @intFromEnum(wamr.CallStatus.done);
}

fn rawSetThrow(exec_env: ?*wamr.ExecEnv, raw_args: [*]u64) void {
    const guest = guestFromExecEnv(exec_env) orelse {
        setRawReturn(raw_args, -constants.EIO);
        setException(exec_env, ERR_NATIVE_CONTEXT.ptr);
        return;
    };
    guest.recordThrow(rawI32(raw_args[0]));
    setRawReturn(raw_args, constants.ESUCCESS);
}

fn rawPcall(exec_env: ?*wamr.ExecEnv, raw_args: [*]u64) void {
    const guest = guestFromExecEnv(exec_env) orelse {
        setRawReturn(raw_args, -constants.EIO);
        setException(exec_env, ERR_NATIVE_CONTEXT.ptr);
        return;
    };
    const child = guest.pcall_run_fn orelse {
        setRawReturn(raw_args, -constants.EINVAL);
        return;
    };
    const boundary = pcall.captureNativeBoundary(exec_env) orelse {
        setException(exec_env, ERR_RETURN_SLOT.ptr);
        return;
    };

    var frame_index: usize = 0;
    const push_result = guest.pushPcallFrame(&frame_index);
    if (push_result != constants.ESUCCESS) {
        setRawReturn(raw_args, push_result);
        return;
    }

    var argv = [_]u32{0};
    const child_status = wamr.wasm_runtime_call_wasm_status(exec_env, child, 0, argv[0..].ptr);
    switch (child_status) {
        .done => {
            const pop_result = guest.popPcallFrameRestore();
            if (pop_result != constants.ESUCCESS) {
                setRawReturn(raw_args, pop_result);
                return;
            }
            setRawReturn(raw_args, constants.ESUCCESS);
        },
        .yielded => {
            if (!guest.markPcallWaiting(frame_index, boundary)) {
                setRawReturn(raw_args, -constants.EIO);
                return;
            }
            setRawReturn(raw_args, 0);
            setException(exec_env, ERR_PCALL_YIELD.ptr);
        },
        .trap => {
            const code = guest.takeThrow() orelse return;
            clearHandledTrap(exec_env);
            const pop_result = guest.popPcallFrameRestore();
            if (pop_result != constants.ESUCCESS) {
                setRawReturn(raw_args, pop_result);
                return;
            }
            setRawReturn(raw_args, code);
        },
    }
}

fn rawSyscall(exec_env: ?*wamr.ExecEnv, raw_args: [*]u64, desc: *const mc.Desc) void {
    const guest = guestFromExecEnv(exec_env) orelse {
        setRawReturn(raw_args, constants.EIO);
        setException(exec_env, ERR_NATIVE_CONTEXT.ptr);
        return;
    };

    if (std.mem.eql(u8, desc.variant, "Pcall")) {
        rawPcall(exec_env, raw_args);
        return;
    }
    if (std.mem.eql(u8, desc.variant, "SetThrow")) {
        rawSetThrow(exec_env, raw_args);
        return;
    }

    if (desc.args.len + 1 > MAX_RAW_CELLS) {
        setRawReturn(raw_args, syscall.neg(constants.EINVAL));
        return;
    }
    var shim = [_]u64{0} ** MAX_RAW_CELLS;
    for (desc.args, 0..) |_, i| shim[i + 1] = raw_args[i];
    const pending = mc.pendingFromRaw(desc, shim[0..].ptr) orelse {
        setRawReturn(raw_args, syscall.neg(constants.EINVAL));
        return;
    };
    guest.recordPending(pending);

    const memory = guest.memoryView() orelse {
        setRawReturn(raw_args, syscall.neg(constants.EINVAL));
        return;
    };
    switch (syscall.fulfillOutcome(memory, &guest.raw_guest, pending)) {
        .Resume => |code| setRawReturn(raw_args, code),
        .Exit => |code| {
            setRawReturn(raw_args, code);
            guest.markExited(code);
            guest.requestSyscallYield(exec_env);
        },
        .Block => |reason| {
            const return_slot = pcall.captureReturnSlot(exec_env) orelse {
                setException(exec_env, ERR_RETURN_SLOT.ptr);
                return;
            };
            setRawReturn(raw_args, 0);
            guest.parkBlocked(pending, reason, return_slot);
            guest.requestSyscallYield(exec_env);
        },
        .Pending => {
            const return_slot = pcall.captureReturnSlot(exec_env) orelse {
                setException(exec_env, ERR_RETURN_SLOT.ptr);
                return;
            };
            setRawReturn(raw_args, 0);
            guest.parkReady(pending, return_slot);
            guest.requestSyscallYield(exec_env);
        },
    }
}

fn nativeDispatch(exec_env: ?*wamr.ExecEnv, raw_args: [*]u64) callconv(.c) void {
    const env = exec_env orelse return;
    const desc_any = env.attachment orelse {
        setException(exec_env, ERR_NATIVE_CONTEXT.ptr);
        return;
    };
    const desc: *const mc.Desc = @ptrCast(@alignCast(desc_any));
    rawSyscall(exec_env, raw_args, desc);
}

fn buildNativeSymbols() [mc.SYSCALLS.len]wamr.NativeSymbol {
    var out: [mc.SYSCALLS.len]wamr.NativeSymbol = undefined;
    inline for (&mc.SYSCALLS, 0..) |*desc, i| {
        out[i] = .{
            .symbol = desc.name.ptr,
            .func_ptr = @ptrCast(&nativeDispatch),
            .signature = null,
            .attachment = @ptrCast(@constCast(desc)),
        };
    }
    return out;
}

var native_symbols = buildNativeSymbols();

fn ensureWamrInitialized() bool {
    if (!state.isInitialized()) return false;
    const k = state.kernel();
    if (!k.wamr_runtime_initialized) {
        var init_args = std.mem.zeroes(wamr.RuntimeInitArgs);
        init_args.mem_alloc_type = .allocator;
        init_args.mem_alloc_option = .{
            .allocator = .{
                .malloc_func = @ptrCast(@constCast(&wamr_alloc.wamrAlloc)),
                .realloc_func = @ptrCast(@constCast(&wamr_alloc.wamrRealloc)),
                .free_func = @ptrCast(@constCast(&wamr_alloc.wamrFree)),
                .user_data = null,
            },
        };
        init_args.running_mode = .interp;
        if (!wamr.wasm_runtime_full_init(&init_args)) return false;
        k.wamr_runtime_initialized = true;
    }
    if (!k.wamr_natives_registered) {
        if (!wamr.wasm_runtime_register_natives_raw(MC_MODULE.ptr, native_symbols[0..].ptr, @intCast(native_symbols.len))) {
            syscall.termWrite("wamr native register failed\n", true);
            return false;
        }
        k.wamr_natives_registered = true;
    }
    return true;
}

/// Instantiate a child guest for an already-created child task (`spawn`). Heap-allocates a
/// GuestRuntime with a stable address, loads `bytes` eagerly, and points `child_id`'s
/// Task.guest at it. The tick loop drives and frees it through destroyGuest.
pub fn createChildGuest(child_id: TaskId, bytes: []const u8, cwd: []const u8) bool {
    const gpa = state.kernel().gpa;
    const g = gpa.create(GuestRuntime) catch return false;
    g.init(gpa, bytes, "_start", child_id, cwd) catch {
        gpa.destroy(g);
        return false;
    };
    return true;
}

/// Tear down and free a heap-allocated child GuestRuntime.
pub fn destroyGuest(g: *GuestRuntime) void {
    const gpa = g.gpa;
    g.deinit();
    gpa.destroy(g);
}
