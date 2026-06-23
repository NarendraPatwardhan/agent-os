//! analyze_entry.zig — the zig_binary root for /bin/luau-analyze. The logic is analyze_main.cpp's
//! C++ mc_analyze_run; this owns the wasi entry (forwards __main_argc_argv to it, as entry.zig does
//! for /bin/luau) and force-references the glue whose symbols the patched C++ links: the trap (the
//! Ast Parser routes parse errors through mc_protected_call/mc_raise — same as luau) and the
//! wasi_shim (the fd_close forwarder). The Analysis engine's OWN error path is the force-included
//! analysis_eh_shim.h's mc_analysis_abort, not the trap. See third_party/luau/SYSTEM.md.

extern fn mc_analyze_run(argc: c_int, argv: [*][*:0]u8) c_int;

export fn __main_argc_argv(argc: c_int, argv: [*][*:0]u8) c_int {
    return mc_analyze_run(argc, argv);
}

comptime {
    _ = @import("trap.zig"); // mc_protected_call / mc_raise / __mc_pcall_run (patched Ast/Parser.cpp)
    _ = @import("wasi_shim.zig"); // fd_close forwarder
}
