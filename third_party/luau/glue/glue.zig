//! glue.zig — the Luau glue library root. Force-references EVERY glue module the luau binary compiles
//! (kept in lockstep with :luau_obj's srcs) so the :glue_build_test compile-gate is honest: it builds
//! exactly the Zig the binary builds, catching errors in `bazel test //...` without the (manual,
//! expensive) full C++ link. Its `export fn`s (mc_protected_call, mc_open_sys, mc_open_json, …) are
//! what the patched Luau C++ + entry.zig link against. See third_party/luau/SYSTEM.md.

comptime {
    _ = @import("trap.zig"); // mc_protected_call / mc_raise / __mc_pcall_run (patched ldo.cpp)
    _ = @import("sys.zig"); // mc_open_sys
    _ = @import("stdlib.zig"); // mc_open_stdlib + require
    _ = @import("json.zig"); // mc_open_json
    _ = @import("hash.zig"); // mc_open_hash
    _ = @import("encoding.zig"); // mc_open_encoding
    _ = @import("deflate.zig"); // mc_open_deflate
    _ = @import("re.zig"); // mc_open_re
    _ = @import("wasi_shim.zig"); // the residual wasi import forwarders
}
