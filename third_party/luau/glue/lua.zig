//! lua.zig — the shared Lua C API for the Zig batteries: the @cImport of lua.h + lualib.h plus thin
//! wrappers for the lua_* convenience MACROS that translate-c does not expose (lua_newtable,
//! lua_pushcfunction, lua_pop, lua_setglobal, …). One @cImport so every binding shares the same
//! lua_State type. See third_party/luau/SYSTEM.md.

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
});

pub const State = c.lua_State;
pub const CFn = *const fn (?*State) callconv(.c) c_int;

// luau_compile lives in luacode.h, which translate-c can't parse (it pulls C++ <vector>). Declare
// the one C-ABI entry point by hand; the C++ TU that defines it compiles via zig c++.
pub extern fn luau_compile(source: [*]const u8, size: usize, options: ?*anyopaque, outsize: *usize) [*c]u8;

pub inline fn newtable(L: ?*State) void {
    c.lua_createtable(L, 0, 0);
}
pub inline fn pushcfunction(L: ?*State, f: CFn, name: [*:0]const u8) void {
    c.lua_pushcclosurek(L, f, name, 0, null);
}
pub inline fn pop(L: ?*State, n: c_int) void {
    c.lua_settop(L, -n - 1);
}
pub inline fn setglobal(L: ?*State, name: [*:0]const u8) void {
    c.lua_setfield(L, c.LUA_GLOBALSINDEX, name);
}
pub inline fn getglobal(L: ?*State, name: [*:0]const u8) void {
    _ = c.lua_getfield(L, c.LUA_GLOBALSINDEX, name);
}
pub inline fn isnil(L: ?*State, idx: c_int) bool {
    return c.lua_type(L, idx) == c.LUA_TNIL;
}
