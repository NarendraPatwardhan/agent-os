//! bridge.zig — the ONLY window to the host: checked wrappers over the generated `env`
//! imports, plus guest/kernel memory helpers (ZIG_KERNEL §1.1 A4, §4.1).
//!
//! Owns: the typed Zig wrappers around every `extern "env"` symbol from
//!   contracts/bridge.kdl (terminal, clock, entropy, HTTP/WS, host-call, persistence,
//!   base-image, boot-contract), and the bounds-checked helpers that move bytes between
//!   guest linear memory and kernel buffers.
//! Invariants: A4 (the compiled kernel imports ONLY `env` symbols — no WASI, no libc,
//!   no allocator hooks, no Component-Model adapter; wasm3's libc needs are satisfied
//!   in-module, never as a new import — proven by the import-purity gate), A5 (every
//!   native side effect flows through exactly these calls).
//! Consumes: :env_zig (the generated extern declarations + descriptor table).
//! Not here: the syscalls guests call (that is guest→kernel; see syscall.zig); control
//!   exports (main.zig/control.zig). This file is kernel→host only.
//!
//! Scaffold status: header-only. Fill as subsystems need host effects.

// (intentionally empty — wraps :env_zig when the first host effect is needed.)
