//! Proof on a REAL artifact — and, in the same breath, the conformance check (SYSTEMS.md
//! section 9.3) on the kernel↔host `env` boundary. The kernel's `env` extern block is generated from
//! `bridge.kdl`, the SAME contract `env_rust::BRIDGE_IMPORTS` is projected from. So walking
//! the genuine `//kernel/rust:kernel` wasm and checking its `env` imports against the
//! DECLARED bridge proves three things at once: the oracle parses real wasm, the projection
//! and the artifact agree, and the kernel calls nothing the contract didn't declare. No
//! bridge symbol is hand-listed here — a copy of the surface in the test is the very drift
//! B2 exists to forbid, so the declared set comes from the projection, never a literal.
//!
//! kernel.wasm is a `data` dep (B1, SYSTEMS.md section 14.1), located via the runfiles crate as //memcontainers/tests/e2e does.

use env_rust::BRIDGE_IMPORTS;
use wasm_imports::{imported_function_symbols, ImportedSymbols};

/// Resolve a `data`-dep artifact by its workspace-relative runfiles path (same helper shape
/// as //memcontainers/tests/e2e). The kernel lands at `_main/memcontainers/kernel/rust/kernel.wasm` in runfiles.
fn kernel_wasm() -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation("_main/memcontainers/kernel/rust/kernel.wasm")
        .expect("kernel.wasm not found in runfiles");
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

/// WHY: the conformance safety property (SYSTEMS.md section 9.3) on the live kernel — every `env` symbol the
/// kernel imports must be in the DECLARED bridge surface projected from the contract; a host
/// call the contract never declared is drift the build must reject. GUARANTEES: the oracle
/// pulls the kernel's real `env` surface out of a megabyte of release wasm, that surface ⊆
/// `env_rust::BRIDGE_IMPORTS` (no undeclared bridge import), and it is non-empty — the walk
/// found the genuine surface, not nothing.
#[test]
fn kernel_env_imports_conform_to_the_declared_bridge() {
    let env = ImportedSymbols::from_wasm(&kernel_wasm(), "env").expect("walk kernel env imports");

    let undeclared = env.disallowed(BRIDGE_IMPORTS);
    assert!(
        undeclared.is_empty(),
        "kernel.wasm imports `env` symbols the bridge contract never declared: {undeclared:?}",
    );
    assert!(
        !env.names.is_empty(),
        "the oracle found no `env` imports in kernel.wasm — it or the artifact is wrong",
    );
}

/// WHY: the oracle must scope strictly to the requested module and not invent symbols.
/// GUARANTEES: asking for a module the kernel does not import from returns an empty set (not
/// an error), and a plausible-but-absent name is reported absent — the negative space the
/// coverage check (SYSTEMS.md section 9.3) relies on is honest.
#[test]
fn unknown_module_is_empty_and_absent_symbols_are_absent() {
    let wasm = kernel_wasm();

    let nonexistent =
        imported_function_symbols(&wasm, "definitely_not_a_module").expect("walk is infallible");
    assert!(nonexistent.is_empty(), "no imports from a bogus module");

    let env = ImportedSymbols::from_wasm(&wasm, "env").expect("walk kernel env imports");
    assert!(
        !env.contains("mc_does_not_exist"),
        "the oracle must not report a symbol the kernel never imports",
    );
}
