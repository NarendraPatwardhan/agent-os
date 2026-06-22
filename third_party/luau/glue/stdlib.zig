//! stdlib.zig — the `require` loader + batteries installer (was loom/src/mc_stdlib.cpp): `@embedFile`
//! the 19 `.luau` modules, register `require`, install the prelude. STUB for now; lands with the
//! bindings (json/hash/re/encoding/deflate). See third_party/luau/PLAN.md.

const c = @cImport({
    @cInclude("lua.h");
});

pub export fn mc_open_stdlib(L: ?*c.lua_State) void {
    _ = L;
}
