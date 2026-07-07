//! Phase-1 host-instantiate smoke (ZIG_KERNEL §8 Phase 1, §7.7).
//!
//! The STOCK wasmtime host — the exact one the Rust kernel boots, with NO Zig
//! special-casing and no guest-engine awareness — instantiates the Zig kernel object, runs
//! `mc_init`, and drives ticks without trapping. This is the concrete proof that "the host
//! loads Zig unchanged" (§7.7) and that `mc_init`/`mc_tick` return safely on the minimal
//! artifact. It does NOT assert boot behavior (the scaffold kernel boots nothing yet — that
//! is the Phase-3/4 burn-down via `core_zig`); it proves only instantiability + lifecycle.

use host::KernelHostBuilder;

fn zig_kernel_wasm() -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    for rel in [
        "_main/memcontainers/kernel/zig/kernel_obj",
        "_main/memcontainers/kernel/zig/kernel.wasm",
    ] {
        let Some(p) = r.rlocation(rel) else {
            continue;
        };
        if p.exists() {
            return std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()));
        }
    }
    panic!("zig kernel artifact not found in runfiles");
}

#[test]
fn stock_host_instantiates_zig_kernel_and_lifecycle_returns() {
    let mut host = KernelHostBuilder::new(zig_kernel_wasm())
        .deterministic()
        .build()
        .expect("the stock wasmtime host must instantiate the Zig kernel and mc_init must return");

    // Further ticks must also return safely (no trap) even though the stub does nothing.
    for _ in 0..4 {
        host.tick().expect("mc_tick must return safely");
    }
}
