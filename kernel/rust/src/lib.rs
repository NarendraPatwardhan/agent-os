//! `kernel/rust` — agent-os's Phase-A kernel (ported from memcontainers crates/kernel).
//!
//! The OS itself: it compiles to and runs only as `wasm32-unknown-unknown` (A2), driven
//! by a host that loads `kernel.wasm`, implements the `env` bridge, and ticks it. The
//! runtime nesting is `host → kernel.wasm → wasmi → guest.wasm`: the kernel embeds a
//! `wasmi` interpreter to run guest programs as cooperative tasks, so wasmi itself must
//! compile *to* wasm.
//!
//! Port status: this is the build-foundation slice. It establishes the crate's spine —
//! `no_std`/`no_main`, the `talc` linear-memory allocator, the trap-style panic handler,
//! and a `wasmi::Engine` touch — which proves the load-bearing toolchain fact that wasmi
//! and talc compile to wasm32 under crate_universe. The real modules (scheduler, VFS,
//! the syscall dispatch, the boot in `mc_init`/`mc_tick`) transplant onto it.
#![no_std]
#![no_main]
// Port-time scaffold: while the kernel is transplanted module-by-module, a not-yet-wired
// module's items and re-exports read as dead/unused. Removed once the crate is whole and
// every module has its consumer.
#![allow(dead_code, unused_imports)]

extern crate alloc;

// Modules transplant in dependency order; each is added here as it lands so the crate
// stays compiling at every step. (vfs is the dependency root: the FS trait layer.)
mod vfs;

use alloc::format;

// The `env` bridge — the ONLY surface the kernel imports (A4: no WASI, no bindgen). The
// full set is ported as the bridge module lands; the panic handler needs just this one.
#[link(wasm_import_module = "env")]
unsafe extern "C" {
    fn mc_stderr_write(ptr: *const u8, len: usize);
}

/// Fail closed: a kernel panic writes a line to the host's stderr and traps. It never
/// unwinds into the host (A9) and never corrupts a snapshot — the trap is observable to
/// the host as an error, which is exactly how booting becomes a test (§9.1).
#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    let msg = format!("kernel panic: {}\r\n", info.message());
    unsafe {
        mc_stderr_write(msg.as_ptr(), msg.len());
        core::arch::wasm32::unreachable();
    }
}

/// All kernel state lives in wasm linear memory (A8); talc's wasm allocator grows that
/// memory on demand. The cooperative (non-atomics) build is the C8 baseline.
#[global_allocator]
static ALLOCATOR: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

/// Boot the kernel. STUB — the real boot (load the base image, set up the VFS, spawn
/// pid 1) transplants here. Touching `wasmi::Engine` forces the interpreter through the
/// build: the load-bearing proof that wasmi compiles to wasm32 under crate_universe.
#[unsafe(no_mangle)]
pub extern "C" fn mc_init() -> i32 {
    let _engine = wasmi::Engine::default();
    0
}

/// Run one bounded slice of kernel work — the heartbeat the host drives (§4.4). STUB.
#[unsafe(no_mangle)]
pub extern "C" fn mc_tick() -> i32 {
    0
}
