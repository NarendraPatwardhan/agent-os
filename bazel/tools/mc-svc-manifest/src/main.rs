//! `mc-svc-manifest <out.tar> <name> <eager|lazy> <service.wasm> [<name> <eager|lazy> <service.wasm>]...`
//! — build the resident-service LAYER: a deterministic tar carrying each service binary at `/bin/<name>`
//! AND the `/etc/services.json` that activates them. Emitting BOTH the install and the manifest from one
//! place (codex #2) is the point: `/bin/<name>` is derived ONCE, so the install path and the manifest's
//! `binary` field can never drift apart. The per-service NAME is the caller's — `mc_service_layer` reads
//! it from each target's `McProgramInfo.service` (the build graph, not a wasm re-parse) — and this
//! asserts the binary's own stamped `mc_service` section matches, so the graph's truth and the shipped
//! artifact must agree. Dependency-free; the ustar writer mirrors mc-roster.

use std::collections::BTreeMap;
use std::process::ExitCode;

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

/// A custom section's payload by name, or `None`.
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
            if nend <= end && &wasm[nstart..nend] == want.as_bytes() {
                return Some(wasm[nend..end].to_vec());
            }
        }
        i = end;
    }
    None
}

/// The grammar-valid `mc_service` name stamped into `wasm` — the artifact's own claim of which name it
/// serves, checked against the name the graph (`McProgramInfo.service`) passed for the same binary. `Err`
/// if the module carries no `mc_service` (not a resident service) or stamps an invalid name.
fn stamped_service(wasm: &[u8]) -> Result<String, String> {
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        return Err("not a wasm module".into());
    }
    let payload =
        custom_section(wasm, "mc_service").ok_or("no mc_service section (not a resident service)")?;
    let name = String::from_utf8(payload).map_err(|_| "mc_service is not UTF-8")?;
    if !valid_service_name(&name) {
        return Err(format!(
            "stamped mc_service `{name}` is not a valid service name ([a-z][a-z0-9-]*, <=31 bytes)"
        ));
    }
    Ok(name)
}

/// Whether `name` is a valid service name — the same grammar enforced by the kernel, mc-stamp, and
/// mc-attest: `[a-z][a-z0-9-]{0,30}`, 1..=31 bytes.
fn valid_service_name(name: &str) -> bool {
    let b = name.as_bytes();
    if b.is_empty() || b.len() > 31 || !b[0].is_ascii_lowercase() {
        return false;
    }
    b.iter()
        .all(|&c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
}

/// JSON-escape a string (defensive: the service-name grammar forbids the characters that need
/// escaping, but a generator must never emit invalid JSON for an unexpected byte).
fn json_str(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A 512-byte ustar header for a regular file `path` (the given octal `mode`, owner 0, mtime 0 — fixed
/// for reproducibility), like mc-roster's symlink header but typeflag `0` with a real size.
fn file_header(path: &str, size: usize, mode: &[u8; 8]) -> [u8; 512] {
    let mut h = [0u8; 512];
    h[0..path.len()].copy_from_slice(path.as_bytes()); // name[100]
    h[100..108].copy_from_slice(mode); // mode (7 octal digits + NUL)
    h[108..116].copy_from_slice(b"0000000\0"); // uid
    h[116..124].copy_from_slice(b"0000000\0"); // gid
    h[124..136].copy_from_slice(format!("{size:011o}\0").as_bytes()); // size (octal, 11 digits + NUL)
    h[136..148].copy_from_slice(b"00000000000\0"); // mtime = 0
    h[148..156].copy_from_slice(b"        "); // chksum: spaces during computation
    h[156] = b'0'; // typeflag: regular file
    h[257..263].copy_from_slice(b"ustar\0"); // magic
    h[263..265].copy_from_slice(b"00"); // version
    let sum: u32 = h.iter().map(|&b| b as u32).sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    h
}

/// Append a regular-file entry (header + content + NUL pad to the next 512-byte boundary).
fn append_file(tar: &mut Vec<u8>, path: &str, data: &[u8], mode: &[u8; 8]) {
    tar.extend_from_slice(&file_header(path, data.len(), mode));
    tar.extend_from_slice(data);
    let pad = (512 - data.len() % 512) % 512;
    tar.resize(tar.len() + pad, 0);
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    // <out.tar> <name> <eager|lazy> <wasm> [...]: argv0 + out + N*(name,policy,wasm) → argc % 3 == 2, >= 5.
    if args.len() < 5 || args.len() % 3 != 2 {
        eprintln!("usage: mc-svc-manifest <out.tar> <name> <eager|lazy> <service.wasm> [...]");
        return ExitCode::from(2);
    }
    let out = &args[1];

    // name -> (eager, wasm bytes). BTreeMap keeps it name-sorted, so the manifest and the tar entries
    // are deterministic (a pure function of the inputs).
    let mut services: BTreeMap<String, (bool, Vec<u8>)> = BTreeMap::new();
    let mut i = 2;
    while i < args.len() {
        let (name, policy, path) = (&args[i], &args[i + 1], &args[i + 2]);
        i += 3;
        let eager = match policy.as_str() {
            "eager" => true,
            "lazy" => false,
            other => {
                eprintln!("mc-svc-manifest: policy must be eager|lazy, got `{other}`");
                return ExitCode::from(2);
            }
        };
        if !valid_service_name(name) {
            eprintln!("mc-svc-manifest: `{name}` is not a valid service name");
            return ExitCode::from(2);
        }
        let wasm = match std::fs::read(path) {
            Ok(w) => w,
            Err(e) => {
                eprintln!("mc-svc-manifest: reading {path}: {e}");
                return ExitCode::from(2);
            }
        };
        // The graph said this binary serves `name`; the binary itself must stamp the same mc_service.
        match stamped_service(&wasm) {
            Ok(ref stamped) if stamped == name => {}
            Ok(stamped) => {
                eprintln!("mc-svc-manifest: {path} stamps mc_service `{stamped}`, but the graph says `{name}`");
                return ExitCode::from(2);
            }
            Err(e) => {
                eprintln!("mc-svc-manifest: {path}: {e}");
                return ExitCode::from(2);
            }
        }
        if services.insert(name.clone(), (eager, wasm)).is_some() {
            eprintln!("mc-svc-manifest: duplicate service `{name}`");
            return ExitCode::from(2);
        }
    }

    // /etc/services.json — { "<name>": { "binary": "/bin/<name>"[, "eager": true] } }, sorted.
    let mut json = String::from("{\n");
    let n = services.len();
    for (idx, (name, (eager, _))) in services.iter().enumerate() {
        json.push_str("  ");
        json.push_str(&json_str(name));
        json.push_str(": { \"binary\": ");
        json.push_str(&json_str(&format!("/bin/{name}")));
        if *eager {
            json.push_str(", \"eager\": true");
        }
        json.push_str(" }");
        if idx + 1 < n {
            json.push(',');
        }
        json.push('\n');
    }
    json.push_str("}\n");

    // The layer tar: each binary at /bin/<name> (BTreeMap order, all sorting before "etc/"), then the
    // manifest at /etc/services.json — the SAME /bin/<name> the manifest names, so they cannot drift.
    let mut tar = Vec::new();
    for (name, (_, wasm)) in &services {
        // Executable (0555, like the rest of /bin) — the shell PATH-execs these as the service's CLI
        // face; the kernel also spawns them for activation.
        append_file(&mut tar, &format!("bin/{name}"), wasm, b"0000555\0");
    }
    append_file(&mut tar, "etc/services.json", json.as_bytes(), b"0000644\0"); // plain data
    tar.extend_from_slice(&[0u8; 1024]); // two zero blocks terminate the archive

    if let Err(e) = std::fs::write(out, &tar) {
        eprintln!("mc-svc-manifest: writing {out}: {e}");
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

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
