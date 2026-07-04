//! wasm3/bindings.zig — thin Zig bindings over the wasm3 C API (ZIG_KERNEL §7.2, §4.1).
//!
//! Owns: the `extern` declarations and small typed wrappers for exactly the wasm3 C
//!   surface the kernel uses — m3_NewEnvironment/Runtime, m3_ParseModule/CompileModule/
//!   LoadModule (EAGER compile), m3_LinkRawFunction, m3_FindFunction/Call, m3_GetMemory/
//!   Size, m3_GetUserData. Nothing more.
//! Invariants: A6 (wasm3 allocation routed to the kernel allocator via the freestanding
//!   build defines), A4 (no new host import — wasm3's libc is satisfied in-module).
//! Consumes: @wasm3 (vendored at //third_party/wasm3, http_archive + fuel patch — a
//!   §15.5 cherry-pick; NOT in this tree, B3).
//! Not here: ANY kernel policy (fuel, suspend, scheduling, snapshot) — that is the
//!   whole point (§7.1). wasm3 is a thin library; if it starts holding state that
//!   affects kernel policy, push it back into Zig (§12.1). Raw handlers live in raw.zig.
//!
//! Scaffold status: header-only until the wasm3 cherry-pick (§15.5) links the C library.

// (intentionally empty until //third_party/wasm3 is linked in Phase 5.)
