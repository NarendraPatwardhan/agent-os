//! mc-stamp — append the kernel's load-time `mc_tier` + `mc_budget` (+ optional `mc_service`) WASM
//! custom sections to a guest.
//!
//! Usage: mc-stamp <in.wasm> <out.wasm> <tier> <mem_bytes> <fuel> <table> [service]
//!
//! A WASM custom section is `0x00 <uleb body_len> <uleb name_len> <name> <payload>`, appended to the
//! module (the kernel's parser walks every top-level section, so trailing sections are found). The
//! payload layouts are the load-time contract with the kernel (mirrors the sysroot's
//! declare_tier!/declare_budget!/declare_service!): mc_tier = the raw UTF-8 tier; mc_budget =
//! [u32 version=1][u64 mem][u64 fuel][u32 table], little-endian (24 bytes); mc_service = the raw
//! UTF-8 service name (present only for a resident service, SYSTEMS.md).

use std::process::exit;

fn uleb(mut n: u64, out: &mut Vec<u8>) {
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n != 0 {
            out.push(b | 0x80);
        } else {
            out.push(b);
            break;
        }
    }
}

fn append_custom(name: &[u8], payload: &[u8], out: &mut Vec<u8>) {
    let mut body = Vec::new();
    uleb(name.len() as u64, &mut body);
    body.extend_from_slice(name);
    body.extend_from_slice(payload);
    out.push(0); // custom section id
    uleb(body.len() as u64, out);
    out.extend_from_slice(&body);
}

fn read_uleb(b: &[u8], at: usize) -> (u64, usize) {
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

/// Rebuild the module dropping any custom section whose name is in `names`. Run before appending so
/// stamping is IDEMPOTENT — re-stamping (or stamping an already-stamped wasm) can never leave a
/// duplicate or stale mc_tier/mc_budget for the kernel to choose from. Malformed length → stop,
/// copying the remainder verbatim (the input is a valid wasm from the linker; this is belt-and-braces).
fn strip_custom_sections(wasm: &[u8], names: &[&[u8]]) -> Vec<u8> {
    let mut out = wasm[..8].to_vec(); // \0asm + version
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        let (size, adv) = read_uleb(wasm, i + 1);
        let body = i + 1 + adv;
        let end = body + size as usize;
        if end > wasm.len() {
            out.extend_from_slice(&wasm[i..]);
            break;
        }
        let drop = id == 0 && {
            let (nlen, a) = read_uleb(wasm, body);
            let nstart = body + a;
            let nend = nstart + nlen as usize;
            nend <= end && names.iter().any(|n| *n == &wasm[nstart..nend])
        };
        if !drop {
            out.extend_from_slice(&wasm[i..end]);
        }
        i = end;
    }
    out
}

/// Whether `name` is a valid service name — a byte-identical copy of the kernel's grammar
/// (`kernel/rust/src/fs/servicefs.rs::valid_service_name`): `[a-z][a-z0-9-]{0,30}`, 1..=31 bytes. The
/// kernel's check is the boundary; stamping rejects a bad name early so the build fails, not boot.
fn valid_service_name(name: &str) -> bool {
    let b = name.as_bytes();
    if b.is_empty() || b.len() > 31 || !b[0].is_ascii_lowercase() {
        return false;
    }
    b.iter()
        .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 7 && a.len() != 8 {
        eprintln!("usage: mc-stamp <in.wasm> <out.wasm> <tier> <mem_bytes> <fuel> <table> [service]");
        exit(2);
    }
    let parse = |s: &str| -> u64 {
        s.parse().unwrap_or_else(|_| {
            eprintln!("mc-stamp: not a number: {s}");
            exit(2)
        })
    };
    let tier = a[3].as_bytes();
    let mem = parse(&a[4]);
    let fuel = parse(&a[5]);
    let table = parse(&a[6]) as u32;
    // The optional resident-service name (SYSTEMS.md) → an mc_service section. Absent/empty = a
    // one-shot tool, which carries no such section. A present name must fit the grammar.
    if let Some(svc) = a.get(7) {
        if !svc.is_empty() && !valid_service_name(svc) {
            eprintln!("mc-stamp: invalid service name `{svc}` (must be [a-z][a-z0-9-]*, <=31 bytes)");
            exit(2);
        }
    }
    let service: &[u8] = a.get(7).map(|s| s.as_bytes()).unwrap_or(b"");

    let wasm = std::fs::read(&a[1]).unwrap_or_else(|e| {
        eprintln!("mc-stamp: read {}: {e}", a[1]);
        exit(1)
    });
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        eprintln!("mc-stamp: {} is not a wasm module", a[1]);
        exit(1);
    }

    // Idempotent: drop any pre-existing mc_tier/mc_budget/mc_service so we never emit a duplicate.
    let mut wasm = strip_custom_sections(&wasm, &[b"mc_tier", b"mc_budget", b"mc_service"]);
    append_custom(b"mc_tier", tier, &mut wasm);

    // An all-zero budget means "no declared budget" — emit no mc_budget section so the guest gets the
    // kernel default, matching a program that declared none. (Real budgets are never all-zero.)
    if mem != 0 || fuel != 0 || table != 0 {
        let mut budget = Vec::with_capacity(24);
        budget.extend_from_slice(&1u32.to_le_bytes()); // version
        budget.extend_from_slice(&mem.to_le_bytes());
        budget.extend_from_slice(&fuel.to_le_bytes());
        budget.extend_from_slice(&table.to_le_bytes());
        append_custom(b"mc_budget", &budget, &mut wasm);
    }

    // A resident service also carries its identity (SYSTEMS.md); a one-shot tool does not.
    if !service.is_empty() {
        append_custom(b"mc_service", service, &mut wasm);
    }

    std::fs::write(&a[2], &wasm).unwrap_or_else(|e| {
        eprintln!("mc-stamp: write {}: {e}", a[2]);
        exit(1)
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn count(wasm: &[u8], name: &[u8]) -> usize {
        let (mut c, mut i) = (0usize, 8usize);
        while i < wasm.len() {
            let id = wasm[i];
            let (size, adv) = read_uleb(wasm, i + 1);
            let body = i + 1 + adv;
            let end = body + size as usize;
            if id == 0 {
                let (nlen, a) = read_uleb(wasm, body);
                let ns = body + a;
                if &wasm[ns..ns + nlen as usize] == name {
                    c += 1;
                }
            }
            i = end;
        }
        c
    }

    // strip-then-append never leaves a duplicate, even when re-stamping an already-stamped module.
    #[test]
    fn stamping_is_idempotent() {
        let header = [0u8, 0x61, 0x73, 0x6d, 1, 0, 0, 0]; // \0asm + version
        let strip: &[&[u8]] = &[b"mc_tier", b"mc_budget", b"mc_service"];
        let mut w = strip_custom_sections(&header, strip);
        append_custom(b"mc_tier", b"full", &mut w);
        append_custom(b"mc_budget", &[0u8; 24], &mut w);
        append_custom(b"mc_service", b"sqlite", &mut w);
        assert_eq!(count(&w, b"mc_tier"), 1);
        assert_eq!(count(&w, b"mc_budget"), 1);
        assert_eq!(count(&w, b"mc_service"), 1);

        // Re-stamp the already-stamped wasm — must replace, not duplicate.
        let mut w2 = strip_custom_sections(&w, strip);
        append_custom(b"mc_tier", b"read-only", &mut w2);
        append_custom(b"mc_budget", &[1u8; 24], &mut w2);
        append_custom(b"mc_service", b"kv", &mut w2);
        assert_eq!(count(&w2, b"mc_tier"), 1, "re-stamp duplicated mc_tier");
        assert_eq!(count(&w2, b"mc_budget"), 1, "re-stamp duplicated mc_budget");
        assert_eq!(count(&w2, b"mc_service"), 1, "re-stamp duplicated mc_service");
    }

    // The service-name grammar — the same vector lives in mc-attest and the kernel; keep them in sync.
    #[test]
    fn service_name_grammar() {
        for ok in ["kv", "sqlite", "typst", "a", "a-b", "x9", "svc-1"] {
            assert!(valid_service_name(ok), "should accept {ok}");
        }
        for bad in ["", "1kv", "-kv", "KV", "kv_test", "kv.test", "kv/x", "kv "] {
            assert!(!valid_service_name(bad), "should reject {bad:?}");
        }
        assert!(valid_service_name(&"a".repeat(31)));
        assert!(!valid_service_name(&"a".repeat(32)));
    }
}
