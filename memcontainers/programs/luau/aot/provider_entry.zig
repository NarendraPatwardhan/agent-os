//! AgentOS command provider for luauc-generated packages.
//!
//! The command entry and the retained context API share one execution path: install real arguments,
//! publish the compiler-generated package, force a full collection while it is rooted, and call it
//! through Luau's protected boundary. The provider owns AgentOS capabilities; luauc owns all VM and
//! generated-code semantics.

const std = @import("std");
const abi = @import("luauc_runtime_abi");
const mc = @import("mc");

extern fn malloc(size: usize) ?*anyopaque;
extern fn free(pointer: ?*anyopaque) void;
extern fn luaL_newstate() ?*abi.State;
extern fn luaL_openlibs(state: ?*abi.State) void;
extern fn luaL_sandbox(state: ?*abi.State) void;
extern fn lua_close(state: ?*abi.State) void;
extern fn lua_createtable(state: ?*abi.State, array_size: c_int, record_size: c_int) void;
extern fn lua_gc(state: ?*abi.State, operation: c_int, argument: c_int) c_int;
extern fn lua_pcall(state: ?*abi.State, argument_count: c_int, result_count: c_int, error_function: c_int) c_int;
extern fn lua_pushlstring(state: ?*abi.State, string: [*]const u8, length: usize) void;
extern fn lua_rawseti(state: ?*abi.State, index: c_int, item: c_int) void;
extern fn lua_setfield(state: ?*abi.State, index: c_int, key: [*:0]const u8) void;
extern fn lua_settop(state: ?*abi.State, index: c_int) void;
extern fn lua_tolstring(state: ?*abi.State, index: c_int, length: *usize) ?[*]const u8;
extern fn mc_open_aot_host(state: ?*abi.State) void;
extern var luauc_runtime_v1_program_pointer: *const abi.AotProgram;

const lua_globals_index: c_int = -10002;
const lua_gc_collect: c_int = 2;
const request_version: u32 = 1;
const context_magic: u32 = 0x41534c43;
const maximum_arguments: usize = 64;
const maximum_argument_bytes: usize = 64 * 1024;

const Context = extern struct {
    magic: u32,
    state: ?*abi.State,
    used: u32,
};

const ArgumentV1 = extern struct {
    pointer: u32,
    size: u32,
};

const InvokeRequestV1 = extern struct {
    version: u32,
    struct_size: u32,
    argument_count: u32,
    arguments_pointer: u32,
    output_pointer: u32,
    output_capacity: u32,
};

const InvokeResultV1 = extern struct {
    status: u32 = 0,
    flags: u32 = 0,
    output_size: u32 = 0,
    reserved0: u32 = 0,
    reserved1: u64 = 0,
};

fn writeAll(fd: i32, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: u32 = 0;
        if (mc.mc_sys_write(fd, mc.addr(bytes.ptr + offset), @intCast(bytes.len - offset), mc.addr(&written)) != 0 or written == 0)
            return false;
        offset += written;
    }
    return true;
}

fn memoryRange(address: u32, size: usize) bool {
    if (address == 0) return false;
    const memory_size = @as(u64, @intCast(@wasmMemorySize(0))) * 65536;
    const finish = @as(u64, address) + @as(u64, @intCast(size));
    return finish >= address and finish <= memory_size;
}

fn memoryRangesOverlap(first: u32, first_size: usize, second: u32, second_size: usize) bool {
    const first_start = @as(u64, first);
    const second_start = @as(u64, second);
    const first_finish = first_start + @as(u64, @intCast(first_size));
    const second_finish = second_start + @as(u64, @intCast(second_size));
    return first_start < second_finish and second_start < first_finish;
}

fn contextFromHandle(handle: u32) ?*Context {
    if (!memoryRange(handle, @sizeOf(Context)) or handle % @alignOf(Context) != 0) return null;
    const context: *Context = @ptrFromInt(handle);
    return if (context.magic == context_magic and context.state != null) context else null;
}

fn installArguments(state: ?*abi.State, arguments: []const []const u8) void {
    lua_createtable(state, @intCast(arguments.len), 0);
    for (arguments, 0..) |argument, index| {
        lua_pushlstring(state, argument.ptr, argument.len);
        lua_rawseti(state, -2, @intCast(index));
    }
    lua_setfield(state, lua_globals_index, "arg");
}

fn createState() ?*abi.State {
    const state = luaL_newstate() orelse return null;
    luaL_openlibs(state);
    mc_open_aot_host(state);
    return state;
}

fn publishError(state: ?*abi.State, message: []const u8) void {
    lua_settop(state, 0);
    lua_pushlstring(state, message.ptr, message.len);
}

fn execute(context: *Context, arguments: []const []const u8) u32 {
    // A static package publishes a state-global, one-shot module registry. A retained provider
    // handle therefore owns the most recent result/error state, but each command invocation gets a
    // fresh VM so package initialization and its writable sandbox environment cannot leak between
    // requests.
    if (context.used != 0) {
        const replacement = createState() orelse {
            publishError(context.state, "AgentOS Luau state allocation failed");
            return 1;
        };
        lua_close(context.state);
        context.state = replacement;
    }
    context.used = 1;
    const state = context.state;
    lua_settop(state, 0);
    installArguments(state, arguments);
    luaL_sandbox(state);

    const source_name = arguments[0];
    if (abi.luauc_runtime_v1_push_program(state, luauc_runtime_v1_program_pointer, source_name.ptr, source_name.len) != 0) {
        publishError(state, "strict AOT program publication failed");
        return 1;
    }
    _ = lua_gc(state, lua_gc_collect, 0);
    return if (lua_pcall(state, 0, 0, 0) == 0) 0 else 1;
}

fn stackError(state: ?*abi.State) []const u8 {
    var length: usize = 0;
    const pointer = lua_tolstring(state, -1, &length) orelse return "non-string Luau error";
    return pointer[0..length];
}

pub export fn agent_os_luauc_v1_alloc(size: u32) u32 {
    if (size == 0) return 0;
    const pointer = malloc(size) orelse return 0;
    return @intCast(@intFromPtr(pointer));
}

pub export fn agent_os_luauc_v1_dealloc(address: u32) void {
    if (address != 0) free(@ptrFromInt(address));
}

pub export fn agent_os_luauc_v1_context_create() u32 {
    const allocation = malloc(@sizeOf(Context)) orelse return 0;
    const context: *Context = @ptrCast(@alignCast(allocation));
    context.* = .{ .magic = context_magic, .state = createState(), .used = 0 };
    if (context.state == null) {
        context.magic = 0;
        free(allocation);
        return 0;
    }
    return @intCast(@intFromPtr(context));
}

pub export fn agent_os_luauc_v1_context_destroy(handle: u32) void {
    const context = contextFromHandle(handle) orelse return;
    const state = context.state;
    context.magic = 0;
    context.state = null;
    lua_close(state);
    free(context);
}

pub export fn agent_os_luauc_v1_invoke(handle: u32, request_address: u32, request_size: u32, result_address: u32) u32 {
    const context = contextFromHandle(handle) orelse return 1;
    if (request_size != @sizeOf(InvokeRequestV1) or
        !memoryRange(request_address, @sizeOf(InvokeRequestV1)) or
        !memoryRange(result_address, @sizeOf(InvokeResultV1))) return 1;

    const request_pointer: *const InvokeRequestV1 = @ptrFromInt(request_address);
    const request = request_pointer.*;
    const result: *InvokeResultV1 = @ptrFromInt(result_address);
    if (memoryRangesOverlap(result_address, @sizeOf(InvokeResultV1), request_address, @sizeOf(InvokeRequestV1)) or
        memoryRangesOverlap(result_address, @sizeOf(InvokeResultV1), handle, @sizeOf(Context)))
        return 1;
    if (request.version != request_version or request.struct_size != @sizeOf(InvokeRequestV1) or
        request.argument_count == 0 or request.argument_count > maximum_arguments or
        !memoryRange(request.arguments_pointer, @as(usize, request.argument_count) * @sizeOf(ArgumentV1)) or
        (request.output_capacity != 0 and !memoryRange(request.output_pointer, request.output_capacity)))
    {
        result.* = .{};
        result.status = 1;
        return 1;
    }

    const arguments_size = @as(usize, request.argument_count) * @sizeOf(ArgumentV1);
    if (memoryRangesOverlap(result_address, @sizeOf(InvokeResultV1), request.arguments_pointer, arguments_size) or
        (request.output_capacity != 0 and memoryRangesOverlap(result_address, @sizeOf(InvokeResultV1), request.output_pointer, request.output_capacity)))
        return 1;
    result.* = .{};

    const raw_arguments: [*]const ArgumentV1 = @ptrFromInt(request.arguments_pointer);
    var arguments_storage: [maximum_arguments][]const u8 = undefined;
    var total_bytes: usize = 0;
    for (0..request.argument_count) |index| {
        const raw = raw_arguments[index];
        total_bytes = std.math.add(usize, total_bytes, raw.size) catch {
            result.status = 1;
            return 1;
        };
        if (total_bytes > maximum_argument_bytes or !memoryRange(raw.pointer, raw.size)) {
            result.status = 1;
            return 1;
        }
        const pointer: [*]const u8 = @ptrFromInt(raw.pointer);
        arguments_storage[index] = pointer[0..raw.size];
    }

    const status = execute(context, arguments_storage[0..request.argument_count]);
    if (status != 0) {
        const message = stackError(context.state);
        if (message.len > request.output_capacity) {
            result.status = 2;
            return 2;
        }
        if (message.len != 0) {
            const output: [*]u8 = @ptrFromInt(request.output_pointer);
            @memcpy(output[0..message.len], message);
        }
        result.flags = 1;
        result.output_size = @intCast(message.len);
        result.status = 3;
        return 3;
    }
    result.status = 0;
    return 0;
}

pub export fn __main_argc_argv(argc: c_int, argv: [*][*:0]u8) c_int {
    if (argc < 1 or argc > maximum_arguments) return 2;
    const handle = agent_os_luauc_v1_context_create();
    if (handle == 0) {
        _ = writeAll(2, "agent-plan: state allocation failed\n");
        return 1;
    }
    defer agent_os_luauc_v1_context_destroy(handle);
    const context = contextFromHandle(handle) orelse return 1;

    var arguments_storage: [maximum_arguments][]const u8 = undefined;
    for (0..@as(usize, @intCast(argc))) |index|
        arguments_storage[index] = std.mem.span(argv[index]);

    if (execute(context, arguments_storage[0..@intCast(argc)]) != 0) {
        _ = writeAll(2, arguments_storage[0]);
        _ = writeAll(2, ": ");
        _ = writeAll(2, stackError(context.state));
        _ = writeAll(2, "\n");
        return 1;
    }
    return 0;
}
