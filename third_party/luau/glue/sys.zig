//! sys.zig — the `sys` system library (was loom/src/sys_bindings.cpp): file / process / time / net
//! over the `mc` syscalls + the Lua C API. STUB for now — the first build runs the core interpreter
//! (print + compute, via wasi-libc); the real `sys.*` table lands next. See third_party/luau/PLAN.md.

const c = @cImport({
    @cInclude("lua.h");
});

pub export fn mc_open_sys(L: ?*c.lua_State) void {
    _ = L;
}
