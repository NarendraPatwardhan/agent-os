//! glue.zig — the Luau glue library root. Force-references every glue module so its `export fn`s
//! (the symbols the patched Luau C++ and entry.zig link against — mc_protected_call, mc_open_sys, …)
//! are emitted into the library. See third_party/luau/PLAN.md.

comptime {
    _ = @import("trap.zig"); // mc_protected_call / mc_raise / __mc_pcall_run (patched ldo.cpp)
    _ = @import("sys.zig"); // mc_open_sys (entry.zig)
    _ = @import("stdlib.zig"); // mc_open_stdlib (entry.zig)
}
