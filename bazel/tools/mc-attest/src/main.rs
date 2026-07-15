//! `mc-attest <box.wasm>` — capability attestation, run at build (drift = build error).
//!
//! A box DECLARES its tier (the `mc_tier` custom section); this checks its ACTUAL `mc` imports fit
//! that tier. For each imported syscall, `SYSCALL_CAPS` (projected from syscalls.kdl) gives the
//! cap-FLOOR — the caps ANY of which authorizes it — and `tier_caps(tier)` (projected from
//! constants.kdl) is the tier's cap bitmask; the syscall is permitted iff the tier holds at least
//! one floor cap. Importing a syscall the tier cannot use AT ALL (spawn/bind/net/persist in a
//! read-only box, …) fails the build — enforcing the extension of conformance from
//! `imports ⊆ declared syscalls` to `imports ⊆ the tier's syscalls`, enforcing default-deny (A9)
//! at authoring time. Both matrices come straight from the contract (B2): no hardcoded caps here,
//! only the projected `SYSCALL_CAPS` + `tier_caps` + `CAP_*`/`TIER_*`.
//!
//! Exit 0 = attested. Exit 1 = a violation (listed). Exit 2 = a usage/parse error.

use std::process::ExitCode;

use constants_rust::{
    tier_caps, CAP_AMBIENT, CAP_FS_READ, CAP_FS_WRITE, CAP_MOUNT, CAP_NET, CAP_PERSIST,
    CAP_SCRATCH, CAP_SPAWN, TIER_FULL, TIER_ISOLATED, TIER_READ_ONLY, TIER_READ_WRITE,
};
use mc_rust::{SYSCALL_CAPS, SYSCALL_NAMES};

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

/// Every import's `(module, name)` (kinds other than func are walked-over for the offset).
fn imports(wasm: &[u8]) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let (size, adv) = uleb(wasm, i);
        i += adv;
        let end = i + size as usize;
        if id == 2 {
            let mut p = i;
            let (count, a) = uleb(wasm, p);
            p += a;
            for _ in 0..count {
                let (ml, a) = uleb(wasm, p);
                p += a;
                let module = String::from_utf8_lossy(&wasm[p..p + ml as usize]).into_owned();
                p += ml as usize;
                let (nl, a) = uleb(wasm, p);
                p += a;
                let name = String::from_utf8_lossy(&wasm[p..p + nl as usize]).into_owned();
                p += nl as usize;
                let kind = wasm[p];
                p += 1;
                match kind {
                    0 => {
                        let (_t, a) = uleb(wasm, p);
                        p += a;
                    }
                    1 => {
                        p += 1;
                        let (_min, a) = uleb(wasm, p);
                        p += a;
                        if wasm[p - a - 1] & 1 != 0 {
                            let (_max, a) = uleb(wasm, p);
                            p += a;
                        }
                    }
                    2 => {
                        let flag = wasm[p];
                        p += 1;
                        let (_min, a) = uleb(wasm, p);
                        p += a;
                        if flag & 1 != 0 {
                            let (_max, a) = uleb(wasm, p);
                            p += a;
                        }
                    }
                    3 => p += 2,
                    other => panic!("unexpected import kind {other}"),
                }
                out.push((module, name));
            }
        }
        i = end;
    }
    out
}

/// A custom section's payload by name (`mc_tier` here), or `None`.
fn custom_section(wasm: &[u8], want: &str) -> Option<Vec<u8>> {
    let mut i = 8;
    while i < wasm.len() {
        let id = wasm[i];
        i += 1;
        let (size, adv) = uleb(wasm, i);
        i += adv;
        let body = i;
        let end = body + size as usize;
        if id == 0 {
            let (nlen, a) = uleb(wasm, body);
            let nstart = body + a;
            let nend = nstart + nlen as usize;
            if &wasm[nstart..nend] == want.as_bytes() {
                return Some(wasm[nend..end].to_vec());
            }
        }
        i = end;
    }
    None
}

/// A floor cap NAME → its projected bit (values from the contract; only the name match lives
/// here, and an unknown name is a hard error so a contract rename can't silently pass).
fn cap_bit(name: &str) -> u8 {
    match name {
        "CAP_FS_READ" => CAP_FS_READ,
        "CAP_FS_WRITE" => CAP_FS_WRITE,
        "CAP_SPAWN" => CAP_SPAWN,
        "CAP_NET" => CAP_NET,
        "CAP_PERSIST" => CAP_PERSIST,
        "CAP_AMBIENT" => CAP_AMBIENT,
        "CAP_SCRATCH" => CAP_SCRATCH,
        "CAP_MOUNT" => CAP_MOUNT,
        other => panic!("mc-attest: unknown cap `{other}` in SYSCALL_CAPS"),
    }
}

/// The declared tier string (`mc_tier` payload) → its projected tier id.
fn tier_id(s: &str) -> Option<i32> {
    Some(match s {
        "isolated" => TIER_ISOLATED,
        "read-only" => TIER_READ_ONLY,
        "read-write" => TIER_READ_WRITE,
        "full" => TIER_FULL,
        _ => return None,
    })
}

/// Whether `name` is a valid service name — a byte-identical copy of the kernel's grammar
/// (`kernel/rust/src/fs/servicefs.rs::valid_service_name`): `[a-z][a-z0-9-]{0,30}`, 1..=31 bytes.
fn valid_service_name(name: &str) -> bool {
    let b = name.as_bytes();
    if b.is_empty() || b.len() > 31 || !b[0].is_ascii_lowercase() {
        return false;
    }
    b.iter()
        .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 2 {
        eprintln!("usage: mc-attest <box.wasm>");
        return ExitCode::from(2);
    }
    let wasm = match std::fs::read(&args[1]) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("mc-attest: reading {}: {e}", args[1]);
            return ExitCode::from(2);
        }
    };
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        eprintln!("mc-attest: {} is not a wasm module", args[1]);
        return ExitCode::from(2);
    }

    match attest(&wasm) {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("mc-attest: {} — {msg}", args[1]);
            eprintln!("  fix the applet's tier or its syscalls (A9 default-deny).");
            ExitCode::from(1)
        }
    }
}

/// Attest a box's wasm bytes against its DECLARED tier (the `mc_tier` section): `Ok` if every `mc`
/// import's cap-floor (`SYSCALL_CAPS`) intersects `tier_caps(tier)`, else `Err` naming the
/// over-reach. Pure (no I/O), so the gate's logic is unit-tested below.
fn attest(wasm: &[u8]) -> Result<(), String> {
    let tier_str = match custom_section(wasm, "mc_tier") {
        Some(b) => String::from_utf8_lossy(&b).into_owned(),
        None => return Err("has no mc_tier section (undeclared tier)".to_string()),
    };
    let tier = tier_id(&tier_str).ok_or_else(|| format!("declares unknown tier `{tier_str}`"))?;
    let caps = tier_caps(tier);

    let imps = imports(wasm);

    // A binary that SERVES (imports svc_serve) is a resident service and MUST declare its
    // identity via an mc_service section — service-capability is a stamped property (SYSTEMS.md), and
    // the kernel grants it to serve only that name. A server without the section is malformed; a
    // section that is present (server or not) must carry a grammar-valid name, the same shape the
    // kernel's svc_serve/svc_connect gate enforces, so the build catches a bad name before boot.
    let serves = imps
        .iter()
        .any(|(m, n)| m == "mc" && n == "mc_sys_svc_serve");
    match custom_section(wasm, "mc_service") {
        None if serves => {
            return Err(
                "imports svc_serve but has no mc_service section (a resident service must \
                        declare its name, SYSTEMS.md)"
                    .to_string(),
            );
        }
        Some(p) => {
            let name = String::from_utf8_lossy(&p).into_owned();
            if !valid_service_name(&name) {
                return Err(format!(
                    "mc_service name `{name}` is not a valid service name ([a-z][a-z0-9-]*, <=31 bytes)"
                ));
            }
        }
        None => {}
    }

    let mut violations: Vec<String> = Vec::new();
    for (module, name) in imps {
        // A guest may import ONLY the `mc` syscall module (purity: the base conformance the tier check
        // extends). A stray wasi/env import means the boundary leaked — fail the build, don't silently
        // skip it (the gap that let mc_program ship un-attested).
        if module != "mc" {
            violations.push(format!(
                "non-mc import `{module}::{name}` (a guest imports only `mc`)"
            ));
            continue;
        }
        if !SYSCALL_NAMES.contains(&name.as_str()) {
            violations.push(format!(
                "unknown mc import `{name}` (imports must be declared syscalls)"
            ));
            continue;
        }
        let floor = match SYSCALL_CAPS.iter().find(|(s, _)| *s == name) {
            Some((_, f)) => *f,
            None => continue, // no cap floor → unconditionally permitted (read/write/args/exit/…)
        };
        if floor.is_empty() {
            continue;
        }
        let floor_bits = floor.iter().fold(0u8, |acc, c| acc | cap_bit(c));
        if caps & floor_bits == 0 {
            violations.push(format!("{name} (needs one of {floor:?})"));
        }
    }

    if violations.is_empty() {
        Ok(())
    } else {
        Err(format!(
            "tier `{tier_str}` cannot use: {}",
            violations.join(", ")
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal wasm importing `mc.<syscall>` and carrying an `mc_tier` section — exactly the two
    /// things `attest` reads (sizes stay < 128, so each LEB length is one byte).
    fn craft(syscall: &str, tier: &str) -> Vec<u8> {
        craft_import("mc", syscall, tier)
    }

    /// Like `craft`, but with an explicit import module — to exercise purity (a non-`mc` module).
    fn craft_import(module: &str, name: &str, tier: &str) -> Vec<u8> {
        let mut w = vec![0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]; // \0asm + version
        w.extend_from_slice(&[1, 4, 1, 0x60, 0, 0]); // type section: one () -> ()
        let mut imp = vec![1u8]; // import count
        imp.push(module.len() as u8);
        imp.extend_from_slice(module.as_bytes());
        imp.push(name.len() as u8);
        imp.extend_from_slice(name.as_bytes());
        imp.extend_from_slice(&[0x00, 0x00]); // func kind, type idx 0
        w.push(2);
        w.push(imp.len() as u8);
        w.extend_from_slice(&imp);
        let mut cust = vec![7u8]; // "mc_tier" name length
        cust.extend_from_slice(b"mc_tier");
        cust.extend_from_slice(tier.as_bytes());
        w.push(0);
        w.push(cust.len() as u8);
        w.extend_from_slice(&cust);
        w
    }

    #[test]
    fn read_only_box_importing_spawn_is_rejected() {
        // spawn needs CAP_SPAWN; read-only is FS_READ|AMBIENT|SCRATCH → the gate must bite.
        assert!(attest(&craft("mc_sys_spawn", "read-only")).is_err());
    }

    #[test]
    fn read_only_box_importing_net_is_rejected() {
        assert!(attest(&craft("mc_sys_http_get", "read-only")).is_err());
    }

    #[test]
    fn isolated_box_importing_ambient_is_rejected() {
        // isolated = FS_READ only; random needs CAP_AMBIENT.
        assert!(attest(&craft("mc_sys_random", "isolated")).is_err());
    }

    #[test]
    fn read_only_box_importing_read_paths_is_accepted() {
        assert!(attest(&craft("mc_sys_open", "read-only")).is_ok());
        assert!(attest(&craft("mc_sys_readdir", "read-only")).is_ok());
    }

    #[test]
    fn read_write_box_importing_unlink_is_accepted() {
        // unlink needs FS_WRITE|SCRATCH; read-write has FS_WRITE.
        assert!(attest(&craft("mc_sys_unlink", "read-write")).is_ok());
    }

    #[test]
    fn uncapped_syscall_is_always_accepted() {
        // write/read/args/exit have no cap floor → fine even at the most restrictive tier.
        assert!(attest(&craft("mc_sys_write", "isolated")).is_ok());
    }

    #[test]
    fn non_mc_import_is_rejected_even_at_full_tier() {
        // A stray wasi/env import fails regardless of tier — the boundary leaked (purity rule).
        assert!(attest(&craft_import("wasi_snapshot_preview1", "fd_write", "full")).is_err());
        assert!(attest(&craft_import("env", "memcpy", "full")).is_err());
    }

    #[test]
    fn unknown_mc_import_is_rejected() {
        // The module alone is not enough; the symbol must be in the contract (conformance rule).
        assert!(attest(&craft("mc_sys_not_a_real_call", "full")).is_err());
    }

    /// Append an `mc_service` custom section (the service name) to a crafted module — service names
    /// stay < 128 bytes so each LEB length is a single byte, like `craft`'s `mc_tier`.
    fn with_service(mut w: Vec<u8>, service: &str) -> Vec<u8> {
        let mut cust = vec![b"mc_service".len() as u8];
        cust.extend_from_slice(b"mc_service");
        cust.extend_from_slice(service.as_bytes());
        w.push(0);
        w.push(cust.len() as u8);
        w.extend_from_slice(&cust);
        w
    }

    #[test]
    fn service_binary_without_mc_service_is_rejected() {
        // Importing svc_serve marks a resident service, which MUST declare its name.
        assert!(attest(&craft("mc_sys_svc_serve", "full")).is_err());
    }

    #[test]
    fn service_binary_with_mc_service_is_accepted() {
        assert!(attest(&with_service(craft("mc_sys_svc_serve", "full"), "sqlite")).is_ok());
    }

    #[test]
    fn a_svc_client_needs_no_mc_service() {
        // svc_connect/svc_call are the CLIENT side (e.g. luau) — not a service, so no mc_service.
        assert!(attest(&craft("mc_sys_svc_connect", "full")).is_ok());
    }

    // The service-name grammar — the same vector lives in mc-stamp and the kernel; keep them in sync.
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

    #[test]
    fn service_binary_with_invalid_name_is_rejected() {
        // A stamped-but-ungrammatical service name fails attestation, even for a real server.
        assert!(attest(&with_service(craft("mc_sys_svc_serve", "full"), "KV")).is_err());
        assert!(attest(&with_service(craft("mc_sys_svc_serve", "full"), "1kv")).is_err());
    }

    /// A crafted module with NO `mc_tier` section (drops what `craft` appends) — to exercise the
    /// undeclared-tier rejection that backstops the kernel's fail-closed activation.
    fn craft_no_tier(module: &str, name: &str) -> Vec<u8> {
        let mut w = vec![0x00, 0x61, 0x73, 0x6d, 1, 0, 0, 0]; // \0asm + version
        w.extend_from_slice(&[1, 4, 1, 0x60, 0, 0]); // type section: one () -> ()
        let mut imp = vec![1u8];
        imp.push(module.len() as u8);
        imp.extend_from_slice(module.as_bytes());
        imp.push(name.len() as u8);
        imp.extend_from_slice(name.as_bytes());
        imp.extend_from_slice(&[0x00, 0x00]); // func kind, type idx 0
        w.push(2);
        w.push(imp.len() as u8);
        w.extend_from_slice(&imp);
        w // deliberately NO mc_tier section
    }

    #[test]
    fn service_binary_without_a_tier_is_rejected() {
        // A service binary that declares its NAME but no TIER has no ceiling to activate at. The build
        // rejects it (undeclared tier), so a tierless service can never be produced — the build-side half
        // of the fail-closed guard the kernel's spawn_service now enforces at activation (a missing tier
        // fails activation instead of defaulting to Full).
        assert!(attest(&with_service(craft_no_tier("mc", "mc_sys_svc_serve"), "kv")).is_err());
    }
}
