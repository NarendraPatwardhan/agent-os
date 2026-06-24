//! `mc-svc-manifest <eager|lazy> <service.wasm> [<eager|lazy> <service.wasm>]... <out.json>` — read
//! each service binary's `mc_service` name and emit the kernel's `/etc/services.json`, so the manifest
//! is DERIVED from the stamped binaries and can never drift from them (codex #6): the service name is
//! read from the binary, not hand-typed beside it. The activation policy (`eager` = start at boot,
//! `lazy` = start on first `svc_connect`) is the per-image argument; the binary path follows the
//! `/bin/<name>` convention the images install at. Both lanes stamp the same `mc_service` section
//! (Rust `declare_service!`, Zig `mc-stamp`), so this is lane-agnostic. Dependency-free hand-rolled
//! wasm parse + JSON, like mc-roster.

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

/// The `mc_service` name a service binary declares — the single source of truth, stamped into the wasm
/// by `declare_service!` (Rust) or `mc-stamp` (Zig). `Err` if the binary is not a resident service.
fn read_service_name(path: &str) -> Result<String, String> {
    let wasm = std::fs::read(path).map_err(|e| format!("reading {path}: {e}"))?;
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        return Err(format!("{path} is not a wasm module"));
    }
    let payload = custom_section(&wasm, "mc_service")
        .ok_or_else(|| format!("{path} has no mc_service section (not a resident service)"))?;
    let name = String::from_utf8(payload).map_err(|_| format!("{path}: mc_service is not UTF-8"))?;
    if !valid_service_name(&name) {
        return Err(format!(
            "{path}: mc_service name `{name}` is not a valid service name ([a-z][a-z0-9-]*, <=31 bytes)"
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

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    // <eager|lazy> <wasm> [<eager|lazy> <wasm>]... <out.json>: an even argc (pairs + out + argv0).
    if args.len() < 4 || args.len() % 2 != 0 {
        eprintln!("usage: mc-svc-manifest <eager|lazy> <service.wasm> [...] <out.json>");
        return ExitCode::from(2);
    }
    let out = &args[args.len() - 1];

    // name -> (binary, eager); BTreeMap keeps it name-sorted, so the output is deterministic.
    let mut services: BTreeMap<String, (String, bool)> = BTreeMap::new();
    let mut i = 1;
    while i + 1 < args.len() {
        let (policy, path) = (&args[i], &args[i + 1]);
        i += 2;
        let eager = match policy.as_str() {
            "eager" => true,
            "lazy" => false,
            other => {
                eprintln!("mc-svc-manifest: policy must be eager|lazy, got `{other}`");
                return ExitCode::from(2);
            }
        };
        let name = match read_service_name(path) {
            Ok(n) => n,
            Err(e) => {
                eprintln!("mc-svc-manifest: {e}");
                return ExitCode::from(2);
            }
        };
        if services.insert(name.clone(), (format!("/bin/{name}"), eager)).is_some() {
            eprintln!("mc-svc-manifest: duplicate service `{name}`");
            return ExitCode::from(2);
        }
    }

    // Emit { "<name>": { "binary": "/bin/<name>"[, "eager": true] } }, sorted (BTreeMap), deterministic.
    let mut json = String::from("{\n");
    let n = services.len();
    for (idx, (name, (binary, eager))) in services.iter().enumerate() {
        json.push_str("  ");
        json.push_str(&json_str(name));
        json.push_str(": { \"binary\": ");
        json.push_str(&json_str(binary));
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

    if let Err(e) = std::fs::write(out, &json) {
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
