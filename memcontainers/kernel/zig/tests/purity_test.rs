//! Phase-1 purity gates for the Zig kernel artifact (ZIG_KERNEL §8 Phase 1, §1.2).
//!
//! These tests inspect the REAL Bazel-built, post-Asyncify `kernel.wasm`. They prove the
//! first artifact obeys the unchanged host boundary (A4: imports only declared `env`
//! symbols) and exposes exactly the generated control surface plus the OPTIONAL Asyncify
//! exports — nothing else. They do not claim subsystem parity; that is the e2e suite.

use std::collections::BTreeSet;

use anyhow::{Context, Result};
use wasm_imports::imported_function_symbols_by_module;
use wasmparser::{ExternalKind, Parser, Payload};

fn zig_kernel_wasm() -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation("_main/memcontainers/kernel/zig/kernel.wasm")
        .expect("zig kernel.wasm not found in runfiles");
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

fn exported_functions(wasm: &[u8]) -> Result<BTreeSet<String>> {
    let mut out = BTreeSet::new();
    for payload in Parser::new(0).parse_all(wasm) {
        let payload = payload.context("parsing wasm payload")?;
        if let Payload::ExportSection(reader) = payload {
            for export in reader.into_iter() {
                let export = export.context("reading export entry")?;
                if matches!(export.kind, ExternalKind::Func) {
                    out.insert(export.name.to_string());
                }
            }
            break;
        }
    }
    Ok(out)
}

/// A4: the kernel imports only symbols from `env`, and only ones the bridge contract
/// declares. wasm3's libc must be satisfied in-module, never as a new host import (§1.1).
#[test]
fn zig_kernel_imports_only_declared_env_symbols() {
    let wasm = zig_kernel_wasm();
    let imports = imported_function_symbols_by_module(&wasm).expect("walk imports by module");

    for module in imports.keys() {
        assert_eq!(
            module, "env",
            "Zig kernel imported functions from forbidden module `{module}`: {:?}",
            imports[module],
        );
    }

    let env = imports.get("env").cloned().unwrap_or_default();
    let allowed: BTreeSet<&str> = env_rust::BRIDGE_IMPORTS.iter().copied().collect();
    let undeclared: BTreeSet<_> = env
        .iter()
        .filter(|name| !allowed.contains(name.as_str()))
        .cloned()
        .collect();

    assert!(
        undeclared.is_empty(),
        "Zig kernel imports `env` symbols the bridge contract never declared: {undeclared:?}",
    );
}

/// §1.2: exports are exactly the generated control surface plus the OPTIONAL `asyncify_*`
/// set — and crucially NOT a host-callable suspend-driving export (no mc_prepare_rewind).
/// This is the gate that mechanically rejects the first attempt's host-driven Asyncify.
#[test]
fn zig_kernel_exports_the_generated_control_surface() {
    let exports = exported_functions(&zig_kernel_wasm()).expect("walk function exports");

    for name in ctl_rust::CONTROL_EXPORTS {
        assert!(
            exports.contains(*name),
            "Zig kernel is missing generated control export `{name}`",
        );
    }

    // The ONLY non-contract exports permitted are the internal Asyncify API that Binaryen
    // emits (no host calls them, §7.4). Anything else — especially an mc_prepare_rewind-style
    // suspend-driving export — fails here (§15.2).
    let allowed_optional = [
        "asyncify_get_state",
        "asyncify_start_unwind",
        "asyncify_stop_unwind",
        "asyncify_start_rewind",
        "asyncify_stop_rewind",
    ];
    let allowed: BTreeSet<&str> = ctl_rust::CONTROL_EXPORTS
        .iter()
        .copied()
        .chain(allowed_optional)
        .collect();
    let extra: BTreeSet<_> = exports
        .iter()
        .filter(|name| name.as_str() != "_initialize")
        .filter(|name| !allowed.contains(name.as_str()))
        .cloned()
        .collect();

    assert!(
        extra.is_empty(),
        "Zig kernel exports non-contract functions beyond the optional Asyncify symbols: {extra:?}",
    );
}
