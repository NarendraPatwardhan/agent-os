//! End-to-end suite — CORE (B6, §9.1). The testing constitution every test here obeys:
//!
//! 1. **No mocks.** Each test boots the REAL `kernel.wasm` inside the REAL wasmtime host and
//!    asserts on REAL bytes. Booting is itself the first assertion: a kernel trap or a
//!    generated-bridge mismatch surfaces as a host error, never a silent skip.
//! 2. **Load-bearing data edge (B1, §7.2).** The kernel + images are `data` deps, so a test always
//!    runs the artifact its sources produce — the death of the memcontainers staleness class.
//! 3. **Deterministic.** Fixed clock + seeded rng (`.deterministic()`), so bytes are reproducible.
//! 4. **One invariant per test**, named `<subject>_<behavior>`, with a WHY/GUARANTEES note.
//! 5. **One binary** (kernel compiled once, ~1.6 ms per boot), grouped into modules by layer.
//!
//! This crate is the CORE suite: boot, line discipline, the shell, the coreutils, the kernel control
//! channel, the flavors, the resident-service primitives, and the Luau loom boot — all sub-second.
//! The heavy DOMAIN services (sqlite, typst — real compiles that run for millions of fuel slices) live
//! in the sibling `extended` suite (`src/extended.rs`), which shares this exact harness ([`harness`])
//! but is a SEPARATE target so the core suite stays fast and CI can gate the two independently.
//!
//! TWO output paths, tested where each is correct (the [`harness`] documents the CRLF vs LF split).

mod harness;
pub use harness::*;

mod boot;
mod coreutils;
mod flavors;
mod kernel;
mod loom;
mod shell;
mod svc;
mod system;
mod tty;
