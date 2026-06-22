//! mc.zig — callable wrappers over the `mc` syscall imports the Luau glue uses. The signatures
//! MIRROR contracts/syscalls.kdl (the generated contracts/gen/mc.gen.zig is DESCRIPTOR data, not
//! callable externs). wasm32: pointers/lengths are `u32` offsets/sizes into linear memory; each
//! returns `i32` (0 / negative errno) unless noted. The bindings (sys.zig, …) extend this with the
//! fs/proc/time/net syscalls as they land.
//!
//! TODO: a projector `zig-extern` output would GENERATE these decls from the contract ("generate the
//! boundary", VISION §16.2). Hand-kept in sync for now; a signature mismatch surfaces at the e2e
//! (the kernel's `mc` provider would reject the call).

// vm — the trap-unwind boundary (used by trap.zig). `mc_sys_pcall` runs the stashed thunk as a
// nested guest call and returns the raised code (0 if none); `mc_sys_set_throw` records the code a
// subsequent trap hands back.
pub extern "mc" fn mc_sys_pcall() i32;
pub extern "mc" fn mc_sys_set_throw(code: i32) i32;
