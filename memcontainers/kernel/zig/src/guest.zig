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

const TaskId = task_mod.TaskId;

const STACK_SIZE: u32 = 512 * 1024;
const HOST_HEAP_SIZE: u32 = 0;
const ERROR_BUF_SIZE: u32 = 256;
const FUEL_QUANTUM: u64 = 2_000_000;
const DEFAULT_FUEL_LIFETIME: u64 = 50_000_000_000;
const HARD_FUEL_LIFETIME: u64 = 4_000_000_000_000;
const EXIT_CODE_FUEL_EXHAUSTED: i32 = 137;
const MAX_RAW_CELLS: usize = 16;
const WAMR_POOL_BYTES: usize = 16 * 1024 * 1024;
const WAMR_POOL_WORDS: usize = WAMR_POOL_BYTES / @sizeOf(u64);

const MC_MODULE: [:0]const u8 = "mc";
const ERR_NATIVE_CONTEXT: [:0]const u8 = "mc native bridge missing guest context";
const ERR_RETURN_SLOT: [:0]const u8 = "mc native bridge missing return slot";

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

const SuspendKind = enum {
    none,
    syscall_blocked,
    syscall_pending,
    fuel_yield,
};

pub const Step = enum { ran, suspended, exited, faulted };

pub const GuestRuntime = struct {
    gpa: std.mem.Allocator = undefined,
    module: ?*wamr.Module = null,
    module_inst: ?*wamr.ModuleInst = null,
    exec_env: ?*wamr.ExecEnv = null,
    function: ?*wamr.Function = null,
    owned_bytes: ?[]u8 = null,
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
    error_buf: [ERROR_BUF_SIZE]u8 = undefined,

    pub fn init(self: *GuestRuntime, gpa: std.mem.Allocator, wasm_bytes: []const u8, entry: [*:0]const u8, task_id: TaskId, cwd: []const u8) bool {
        self.deinit();
        self.* = .{
            .gpa = gpa,
            .task_id = task_id,
            .lifetime_remaining = declaredFuel(wasm_bytes),
        };
        self.raw_guest = .{ .ptr = @ptrCast(self), .task_id = cbTaskId, .create_child = cbCreateChild };

        self.owned_bytes = gpa.dupe(u8, wasm_bytes) catch return false;
        if (state.isInitialized()) {
            if (state.kernel().sched.getTask(task_id)) |t| {
                t.guest = @ptrCast(self);
                t.setCwd(gpa, cwd);
            }
        }

        if (!ensureWamrInitialized()) {
            self.deinit();
            return false;
        }

        const bytes = self.owned_bytes orelse return false;
        @memset(self.error_buf[0..], 0);
        self.module = wamr.wasm_runtime_load(bytes.ptr, @intCast(bytes.len), self.error_buf[0..].ptr, ERROR_BUF_SIZE) orelse {
            syscall.termWrite("wamr load failed\n", true);
            syscall.termWrite(std.mem.sliceTo(self.error_buf[0..].ptr, 0), true);
            syscall.termWrite("\n", true);
            self.deinit();
            return false;
        };
        self.module_inst = wamr.wasm_runtime_instantiate(self.module, STACK_SIZE, HOST_HEAP_SIZE, self.error_buf[0..].ptr, ERROR_BUF_SIZE) orelse {
            syscall.termWrite("wamr instantiate failed\n", true);
            syscall.termWrite(std.mem.sliceTo(self.error_buf[0..].ptr, 0), true);
            syscall.termWrite("\n", true);
            self.deinit();
            return false;
        };
        wamr.wasm_runtime_set_custom_data(self.module_inst, @ptrCast(self));

        self.exec_env = wamr.wasm_runtime_create_exec_env(self.module_inst, STACK_SIZE) orelse {
            syscall.termWrite("wamr exec env failed\n", true);
            self.deinit();
            return false;
        };
        self.function = wamr.wasm_runtime_lookup_function(self.module_inst, entry) orelse {
            syscall.termWrite("wamr lookup failed\n", true);
            self.deinit();
            return false;
        };

        self.active = true;
        return true;
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
        const status = if (should_resume)
            wamr.wasm_runtime_resume(exec_env, 1, argv[0..].ptr)
        else
            wamr.wasm_runtime_call_wasm_status(exec_env, function, 0, argv[0..].ptr);
        return self.handleStatus(status, argv[0]);
    }

    pub fn deinit(self: *GuestRuntime) void {
        if (self.exec_env) |exec_env| wamr.wasm_runtime_destroy_exec_env(exec_env);
        self.exec_env = null;
        if (self.module_inst) |module_inst| {
            wamr.wasm_runtime_set_custom_data(module_inst, null);
            wamr.wasm_runtime_deinstantiate(module_inst);
        }
        self.module_inst = null;
        if (self.module) |module| wamr.wasm_runtime_unload(module);
        self.module = null;
        if (state.isInitialized() and self.task_id != 0) {
            if (state.kernel().sched.getTask(self.task_id)) |t| {
                if (t.guest == @as(*anyopaque, @ptrCast(self))) t.guest = null;
            }
        }
        if (self.owned_bytes) |b| {
            self.gpa.free(b);
            self.owned_bytes = null;
        }
        self.function = null;
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
                self.current_slice = 0;
                if (self.exited) break :blk self.exitNow(self.exit_code);
                break :blk self.exitNow(@as(i32, @bitCast(result_cell)));
            },
            .yielded => blk: {
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
                if (self.module_inst) |module_inst| {
                    if (wamr.wasm_runtime_get_exception(module_inst)) |message| {
                        syscall.termWrite("wamr trap: ", true);
                        syscall.termWrite(std.mem.sliceTo(message, 0), true);
                        syscall.termWrite("\n", true);
                    } else {
                        syscall.termWrite("wamr trap: <no exception>\n", true);
                    }
                }
                break :blk self.markFault();
            },
        };
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

fn captureReturnSlot(exec_env: ?*wamr.ExecEnv) ?*u32 {
    const env = exec_env orelse return null;
    const native_frame = env.cur_frame orelse return null;
    const caller = native_frame.prev_frame orelse return null;
    return &caller.lp[caller.ret_offset];
}

fn setRawReturn(raw_args: [*]u64, code: i32) void {
    raw_args[0] = @as(u32, @bitCast(code));
}

fn setException(exec_env: ?*wamr.ExecEnv, message: [*:0]const u8) void {
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env) orelse return;
    wamr.wasm_runtime_set_exception(module_inst, message);
}

fn rawSyscall(exec_env: ?*wamr.ExecEnv, raw_args: [*]u64, desc: *const mc.Desc) void {
    const guest = guestFromExecEnv(exec_env) orelse {
        setRawReturn(raw_args, constants.EIO);
        setException(exec_env, ERR_NATIVE_CONTEXT.ptr);
        return;
    };

    if (std.mem.eql(u8, desc.variant, "Pcall") or std.mem.eql(u8, desc.variant, "SetThrow")) {
        // TODO(Stage 3): WAMR guest-in-guest pcall needs its own frame/result protocol.
        setRawReturn(raw_args, syscall.neg(constants.ENOSYS));
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
            const return_slot = captureReturnSlot(exec_env) orelse {
                setException(exec_env, ERR_RETURN_SLOT.ptr);
                return;
            };
            setRawReturn(raw_args, 0);
            guest.parkBlocked(pending, reason, return_slot);
            guest.requestSyscallYield(exec_env);
        },
        .Pending => {
            const return_slot = captureReturnSlot(exec_env) orelse {
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
        if (k.wamr_runtime_pool == null) {
            k.wamr_runtime_pool = k.gpa.alloc(u64, WAMR_POOL_WORDS) catch return false;
        }
        const pool = k.wamr_runtime_pool orelse return false;
        var init_args = std.mem.zeroes(wamr.RuntimeInitArgs);
        init_args.mem_alloc_type = .pool;
        init_args.mem_alloc_option = .{
            .pool = .{
                .heap_buf = @ptrCast(pool.ptr),
                .heap_size = WAMR_POOL_BYTES,
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
    g.* = .{};
    if (!g.init(gpa, bytes, "_start", child_id, cwd)) {
        gpa.destroy(g);
        return false;
    }
    return true;
}

/// Tear down and free a heap-allocated child GuestRuntime.
pub fn destroyGuest(g: *GuestRuntime) void {
    const gpa = g.gpa;
    g.deinit();
    gpa.destroy(g);
}
