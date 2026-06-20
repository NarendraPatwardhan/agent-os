//! Bootstrap Rust→wasm smoke — proves rules_rust compiles a `no_std` cdylib to
//! wasm32-unknown-unknown, the exact shape kernel/rust will take in Step 2 (the
//! kernel is a `rust_shared_library` → kernel.wasm, no_std, a wasm "reactor" of
//! exported `mc_*` functions with no `_start`). Not part of the system; delete once
//! kernel/rust provides a real wasm target to anchor the spine.
#![no_std]

// no_std needs an explicit panic handler; the kernel never unwinds in the host (it
// fails closed), so a trap-style loop is the right shape (A9-adjacent).
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

/// An exported reactor function — the minimal stand-in for the kernel's mc_init/mc_tick
/// control exports. `#[no_mangle] extern "C"` is how the wasm module surfaces it.
#[no_mangle]
pub extern "C" fn mc_smoke_add(a: i32, b: i32) -> i32 {
    a.wrapping_add(b)
}
