//! AgentOS capabilities for strict native Luau packages.
//!
//! Luauc supplies the compiler, generated-code runtime, and pinned Luau VM. This downstream archive
//! publishes only the real AgentOS `sys` and `json` libraries used by compiled applications.

const lua = @import("lua.zig");
const State = lua.State;

extern fn mc_open_sys(state: ?*State) void;
extern fn mc_open_json(state: ?*State) c_int;

comptime {
    _ = @import("trap.zig");
    _ = @import("sys.zig");
    _ = @import("json.zig");
    _ = @import("wasi_shim.zig");
}

pub export fn mc_open_aot_host(state: ?*State) void {
    mc_open_sys(state);
    _ = mc_open_json(state);
    lua.setglobal(state, "json");
}
