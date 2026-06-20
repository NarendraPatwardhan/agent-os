//! Reusable wasmtime host for the agent-os kernel — loads `kernel.wasm`, implements the
//! `env` bridge (the host half of that contract), and drives the `mc_ctl_*` control
//! channel (VISION §4.1, A3). Both the interactive CLI and the e2e suite drive the kernel
//! through this one library — A2 means the kernel only ever runs as wasm, so every
//! behavior test boots the real artifact through here, never a mock (B6).
//!
//! Build-foundation slice: this links wasmtime to prove it compiles natively under
//! crate_universe before the ~3k-line transplant — the host analog of the kernel's
//! wasmi-to-wasm de-risk. The real `HostState` / `register_bridge` / `KernelHost`
//! transplant in once the toolchain is proven.

use wasmtime::Engine;

/// Touch the wasmtime engine so the build links it (foundation de-risk).
pub fn engine() -> Engine {
    Engine::default()
}
