//! `wasi-trampoline` — emit the Rust source of a **trampoline** that resolves a wasm module's
//! residual `wasi_snapshot_preview1` imports to the `//wasi-adapter`'s `__imported_*` functions.
//!
//! Most WASI imports bind to the stable `__imported_wasi_snapshot_preview1_*` symbols the adapter
//! defines, so link-injecting the adapter object resolves them in one shot. But Rust std/deps
//! bind a few calls (`args_*`, `random_get`, …) to HASH-MANGLED symbols from std's bundled `wasi`
//! crate, which the adapter's stable symbols do not match. So: read every remaining
//! `wasi_snapshot_preview1` import straight off the binary — WITH its exact wasm signature and its
//! linker symbol (from the name section) — and emit a forwarder that `#[export_name]`s the mangled
//! symbol and calls the adapter's `__imported_*`. No hardcoded hashes, no signature table.
//!
//! One trampoline+relink usually clears it, but a relink can reveal a DEEPER binding (e.g.
//! getrandom's wrapper resolving to the `wasi`-crate `random_get` only on the next link), so the
//! Bazel conversion (see //wasi-adapter:defs.bzl `mc_box`) drives this to a FIXPOINT: each round
//! links the adapter + every trampoline so far, then this tool reads the round's residue into the
//! next trampoline, until a box imports only `mc`. Post-convergence rounds read zero residue, so
//! their trampolines are empty and the rounds are byte-identical (Bazel caches them — the fixpoint
//! is free past convergence). Ported from memcontainers' `conformance::func_imports_full` +
//! `xtask::generate_trampoline`.
//!
//! Usage: `wasi-trampoline <in.wasm> <out.rs>`.

use std::collections::BTreeMap;
use std::process::ExitCode;

/// A function import with everything the trampoline needs: its name, its linker symbol, and its
/// exact wasm signature (so the forwarder's types match — no hardcoded signature table).
struct FuncImport {
    module: String,
    name: String,
    symbol: String, // linker symbol from the name section; empty if stripped
    params: Vec<u8>,
    results: Vec<u8>,
}

/// Minimal unsigned-LEB128 decode: `(value, bytes_consumed)`.
fn uleb(b: &[u8], at: usize) -> (u64, usize) {
    let (mut res, mut shift, mut n) = (0u64, 0u32, 0usize);
    loop {
        let byte = b[at + n];
        n += 1;
        res |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            break;
        }
        shift += 7;
    }
    (res, n)
}

/// Advance past a `limits` (used by table/memory imports).
fn skip_limits(b: &[u8], at: usize) -> usize {
    let flag = b[at];
    let mut p = at + 1;
    let (_min, a) = uleb(b, p);
    p += a;
    if flag & 1 != 0 {
        let (_max, a) = uleb(b, p);
        p += a;
    }
    p
}

/// `funcidx → name` from the name section's function-name subsection (sub-id 1). Imported
/// functions occupy the low indices, so this recovers their linker symbols.
fn function_name_map(wasm: &[u8]) -> BTreeMap<u32, String> {
    let mut map = BTreeMap::new();
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let (size, adv) = uleb(wasm, i);
        i += adv;
        let body = i;
        let end = body + size as usize;
        if id == 0 {
            // Custom section: a name-length-prefixed name, then the payload.
            let (nlen, a) = uleb(wasm, body);
            let nstart = body + a;
            if &wasm[nstart..nstart + nlen as usize] == b"name" {
                let mut p = nstart + nlen as usize;
                while p < end {
                    let sub_id = wasm[p];
                    p += 1;
                    let (sub_size, a) = uleb(wasm, p);
                    p += a;
                    let sub_end = p + sub_size as usize;
                    if sub_id == 1 {
                        let (count, a) = uleb(wasm, p);
                        let mut q = p + a;
                        for _ in 0..count {
                            let (idx, a) = uleb(wasm, q);
                            q += a;
                            let (l, a) = uleb(wasm, q);
                            q += a;
                            let nm = String::from_utf8_lossy(&wasm[q..q + l as usize]).into_owned();
                            q += l as usize;
                            map.insert(idx as u32, nm);
                        }
                    }
                    p = sub_end;
                }
            }
        }
        i = end;
    }
    map
}

/// The type section (id 1) as `(params, results)` value-type byte vectors, indexed by typeidx.
fn func_types(wasm: &[u8]) -> Vec<(Vec<u8>, Vec<u8>)> {
    let mut types = Vec::new();
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let (size, adv) = uleb(wasm, i);
        i += adv;
        let body = i;
        let end = body + size as usize;
        if id == 1 {
            let mut p = body;
            let (count, a) = uleb(wasm, p);
            p += a;
            for _ in 0..count {
                // functype: 0x60, vec(param valtype), vec(result valtype)
                assert_eq!(wasm[p], 0x60, "malformed functype");
                p += 1;
                let (nparams, a) = uleb(wasm, p);
                p += a;
                let params = wasm[p..p + nparams as usize].to_vec();
                p += nparams as usize;
                let (nresults, a) = uleb(wasm, p);
                p += a;
                let results = wasm[p..p + nresults as usize].to_vec();
                p += nresults as usize;
                types.push((params, results));
            }
        }
        i = end;
    }
    types
}

/// Every function import with module, name, linker symbol, and signature.
fn func_imports_full(wasm: &[u8]) -> Vec<FuncImport> {
    let names = function_name_map(wasm);
    let types = func_types(wasm);
    let mut out = Vec::new();
    let mut funcidx = 0u32;
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let (size, adv) = uleb(wasm, i);
        i += adv;
        let body = i;
        let end = body + size as usize;
        if id == 2 {
            let mut p = body;
            let (count, a) = uleb(wasm, p);
            p += a;
            for _ in 0..count {
                let (mlen, a) = uleb(wasm, p);
                p += a;
                let module = String::from_utf8_lossy(&wasm[p..p + mlen as usize]).into_owned();
                p += mlen as usize;
                let (nlen, a) = uleb(wasm, p);
                p += a;
                let name = String::from_utf8_lossy(&wasm[p..p + nlen as usize]).into_owned();
                p += nlen as usize;
                let kind = wasm[p];
                p += 1;
                match kind {
                    0 => {
                        let (typeidx, a) = uleb(wasm, p);
                        p += a;
                        let (params, results) =
                            types.get(typeidx as usize).cloned().unwrap_or_default();
                        out.push(FuncImport {
                            module,
                            name,
                            symbol: names.get(&funcidx).cloned().unwrap_or_default(),
                            params,
                            results,
                        });
                        funcidx += 1;
                    }
                    1 => {
                        p += 1;
                        p = skip_limits(wasm, p);
                    }
                    2 => p = skip_limits(wasm, p),
                    3 => p += 2,
                    other => panic!("unexpected import kind {other}"),
                }
            }
        }
        i = end;
    }
    out
}

/// One wasm value-type byte → its Rust/ABI type name.
fn valty(b: u8) -> &'static str {
    match b {
        0x7f => "i32",
        0x7e => "i64",
        0x7d => "f32",
        0x7c => "f64",
        _ => "i32",
    }
}

/// `(params, call_args, ret)` source fragments for an import's signature.
fn sig(imp: &FuncImport) -> (String, String, String) {
    let ps: Vec<String> = imp
        .params
        .iter()
        .enumerate()
        .map(|(j, &b)| format!("p{j}: {}", valty(b)))
        .collect();
    let args: Vec<String> = (0..imp.params.len()).map(|j| format!("p{j}")).collect();
    let ret = match imp.results.first() {
        Some(&b) => format!(" -> {}", valty(b)),
        None => String::new(),
    };
    (ps.join(", "), args.join(", "), ret)
}

/// Generate the trampoline source for a wasm's residual `wasi_snapshot_preview1` imports. Empty
/// (header-only) when there are none — a valid no_std lib that links to nothing.
fn generate_trampoline(wasm: &[u8]) -> Result<String, String> {
    let imports: Vec<FuncImport> = func_imports_full(wasm)
        .into_iter()
        .filter(|imp| imp.module == "wasi_snapshot_preview1")
        .collect();

    let mut src = String::from("#![no_std]\n#![allow(clippy::all)]\n");

    // Declare each adapter import (`__imported_*`) ONCE, keyed by wasi name: two distinct mangled
    // symbols can forward to the same import (e.g. getrandom's and the wasi crate's `random_get`),
    // and a duplicate `extern` decl won't compile.
    let mut declared: Vec<String> = Vec::new();
    for imp in &imports {
        if imp.symbol.is_empty() {
            return Err(format!(
                "import {}::{} has no linker symbol (name section stripped?) — cannot trampoline",
                imp.module, imp.name
            ));
        }
        let target = format!("__imported_wasi_snapshot_preview1_{}", imp.name);
        if declared.iter().any(|d| d == &target) {
            continue;
        }
        let (ps, _, ret) = sig(imp);
        src.push_str(&format!("extern \"C\" {{ fn {target}({ps}){ret}; }}\n"));
        declared.push(target);
    }

    // One forwarder per distinct mangled symbol → its adapter import.
    for (idx, imp) in imports.iter().enumerate() {
        let (ps, args, ret) = sig(imp);
        let target = format!("__imported_wasi_snapshot_preview1_{}", imp.name);
        src.push_str(&format!(
            "#[export_name = \"{}\"]\npub unsafe extern \"C\" fn __mc_tramp_{idx}({ps}){ret} {{ {target}({args}) }}\n",
            imp.symbol,
        ));
    }

    Ok(src)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: wasi-trampoline <in.wasm> <out.rs>");
        return ExitCode::from(2);
    }
    let wasm = match std::fs::read(&args[1]) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("wasi-trampoline: reading {}: {e}", args[1]);
            return ExitCode::from(2);
        }
    };
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        eprintln!("wasi-trampoline: {} is not a wasm module", args[1]);
        return ExitCode::from(2);
    }
    let src = match generate_trampoline(&wasm) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("wasi-trampoline: {e}");
            return ExitCode::from(2);
        }
    };
    if let Err(e) = std::fs::write(&args[2], src) {
        eprintln!("wasi-trampoline: writing {}: {e}", args[2]);
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}
