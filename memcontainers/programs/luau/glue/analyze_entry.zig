//! analyze_entry.zig — the zig_binary root for /bin/luau-analyze. The logic is analyze_main.cpp's
//! C++ mc_analyze_run; this owns the wasi entry (forwards __main_argc_argv to it, as entry.zig does
//! for /bin/luau) and force-references the glue whose symbols the patched C++ links: the trap (the
//! Ast Parser routes parse errors through luauc's neutral protected-call/raise ABI) and the
//! wasi_shim (the fd_close forwarder). The Analysis engine's OWN error path is the force-included
//! Luau/AnalysisEhShim.h's luauc_analysis_abort, not the trap.

extern fn mc_analyze_run(argc: c_int, argv: [*][*:0]u8) c_int;

export fn __main_argc_argv(argc: c_int, argv: [*][*:0]u8) c_int {
    return mc_analyze_run(argc, argv);
}

comptime {
    _ = @import("trap.zig"); // neutral runtime ABI + AgentOS __mc_pcall_run dispatcher
    _ = @import("wasi_shim.zig"); // fd_close forwarder
}
