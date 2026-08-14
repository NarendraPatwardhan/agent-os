//! Stamp deterministic AgentOS distribution tars with typed provenance and file digests.

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::env;
use std::fs;

const BLOCK: usize = 512;

fn main() {
    if let Err(error) = run(env::args().skip(1).collect()) {
        eprintln!("distribution-manifest: {error}");
        std::process::exit(1);
    }
}

fn run(args: Vec<String>) -> Result<(), String> {
    let kind = args
        .first()
        .map(String::as_str)
        .ok_or("missing distribution kind")?;
    match kind {
        "server" if args.len() == 14 => stamp_server(&args[1..]),
        "firecracker" if args.len() == 7 => stamp_firecracker(&args[1..]),
        "server" => Err(format!(
            "server expects 13 arguments, got {}",
            args.len() - 1
        )),
        "firecracker" => Err(format!(
            "firecracker expects 6 arguments, got {}",
            args.len() - 1
        )),
        other => Err(format!("unknown distribution kind {other:?}")),
    }
}

fn stamp_server(args: &[String]) -> Result<(), String> {
    let input = fs::read(&args[0]).map_err(|e| format!("read payload: {e}"))?;
    let commit = stable_commit(&args[2])?;
    let module = fs::read_to_string(&args[3]).map_err(|e| format!("read MODULE.bazel: {e}"))?;
    let gitz = module_pin(&module, "archive_override", "module_name", "gitz")?;
    let gitz_commit = gitz
        .url
        .rsplit_once("/archive/")
        .and_then(|(_, tail)| tail.strip_suffix(".tar.gz"))
        .filter(|value| is_hex(value, 40))
        .ok_or("Gitz archive URL does not contain a 40-hex commit")?;
    let integrity = gitz
        .integrity
        .ok_or("Gitz archive_override has no integrity")?;
    if !integrity.starts_with("sha256-") {
        return Err("Gitz integrity is not sha256 SRI".into());
    }

    let files = tar_files(&input, "agent_os")?;
    let artifact_paths = [
        "priv/browser-ctl.tar",
        "priv/git-engine",
        "priv/kernel/kernel.wasm",
        "priv/libhost_nif.so",
    ];
    let mut artifacts = BTreeMap::new();
    for path in artifact_paths {
        artifacts.insert(
            path,
            files
                .get(path)
                .ok_or_else(|| format!("payload omits {path}"))?,
        );
    }

    let manifest = json!({
        "schema": 2,
        "agent_os_commit": commit,
        "gitz_commit": gitz_commit,
        "gitz_archive_integrity": integrity,
        "git_contract_major": parse_u64(&args[4], "git contract major")?,
        "git_contract_minor": parse_u64(&args[5], "git contract minor")?,
        "git_capabilities": parse_u64(&args[6], "git capabilities")?,
        "build_mode": args[7],
        "platform": {"os": args[8], "arch": args[9], "abi": args[10]},
        "runtime": {"otp": args[11], "elixir": args[12]},
        "artifacts": artifacts,
        "required_licenses": ["share/licenses/gitz/LICENSE"],
        "files": files,
    });
    let bytes = pretty_json(manifest)?;
    let output = append_files(&input, &[("agent_os/priv/package-manifest.json", &bytes)])?;
    fs::write(&args[1], output).map_err(|e| format!("write output: {e}"))
}

fn stamp_firecracker(args: &[String]) -> Result<(), String> {
    let input = fs::read(&args[0]).map_err(|e| format!("read payload: {e}"))?;
    let commit = stable_commit(&args[2])?;
    let module = fs::read_to_string(&args[3]).map_err(|e| format!("read MODULE.bazel: {e}"))?;
    let firecracker = module_pin(&module, "http_archive", "name", "firecracker")?;
    let kernel = module_pin(&module, "http_file", "name", "firecracker_kernel")?;
    let files = tar_files(&input, "agent-os-firecracker-runner")?;
    let sums = files
        .iter()
        .map(|(path, digest)| format!("{digest}  {path}\n"))
        .collect::<String>()
        .into_bytes();
    let manifest = json!({
        "schema": 1,
        "agent_os_commit": commit,
        "platform": {"os": args[4], "arch": args[5]},
        "inputs": {
            "firecracker": {"url": firecracker.url, "sha256": firecracker.sha256},
            "kernel": {"url": kernel.url, "sha256": kernel.sha256},
        },
        "required_licenses": [
            "share/licenses/firecracker/LICENSE",
            "share/licenses/firecracker/NOTICE",
            "share/licenses/firecracker/THIRD-PARTY",
        ],
        "files": files,
    });
    let manifest = pretty_json(manifest)?;
    let output = append_files(
        &input,
        &[
            ("agent-os-firecracker-runner/SHA256SUMS", &sums),
            ("agent-os-firecracker-runner/manifest.json", &manifest),
        ],
    )?;
    fs::write(&args[1], output).map_err(|e| format!("write output: {e}"))
}

fn pretty_json(value: Value) -> Result<Vec<u8>, String> {
    let mut bytes =
        serde_json::to_vec_pretty(&value).map_err(|e| format!("encode manifest: {e}"))?;
    bytes.push(b'\n');
    Ok(bytes)
}

fn parse_u64(value: &str, name: &str) -> Result<u64, String> {
    value.parse().map_err(|e| format!("invalid {name}: {e}"))
}

fn stable_commit(path: &str) -> Result<String, String> {
    let status = fs::read_to_string(path).map_err(|e| format!("read workspace status: {e}"))?;
    let commit = status
        .lines()
        .find_map(|line| line.strip_prefix("STABLE_AGENT_OS_COMMIT "))
        .ok_or("workspace status omits STABLE_AGENT_OS_COMMIT")?;
    if !is_hex(commit, 40) {
        return Err("distribution requires a clean 40-hex AgentOS revision".into());
    }
    Ok(commit.into())
}

fn is_hex(value: &str, len: usize) -> bool {
    value.len() == len && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

struct Pin {
    url: String,
    sha256: Option<String>,
    integrity: Option<String>,
}

fn module_pin(text: &str, function: &str, key: &str, wanted: &str) -> Result<Pin, String> {
    let mut in_block = false;
    let mut matched = false;
    let mut url = None;
    let mut sha256 = None;
    let mut integrity = None;
    for line in text.lines() {
        if line.trim() == format!("{function}(") {
            in_block = true;
            matched = false;
            url = None;
            sha256 = None;
            integrity = None;
            continue;
        }
        if !in_block {
            continue;
        }
        let trimmed = line.trim();
        if let Some(value) = assignment(trimmed, key) {
            matched = value == wanted;
        } else if let Some(value) = assignment(trimmed, "integrity") {
            integrity = Some(value.into());
        } else if let Some(value) = assignment(trimmed, "sha256") {
            sha256 = Some(value.into());
        } else if trimmed.starts_with("url = ") || trimmed.starts_with("urls = ") {
            url = quoted_value(trimmed).map(str::to_owned);
        } else if trimmed == ")" {
            if matched {
                return Ok(Pin {
                    url: url.ok_or_else(|| format!("{function} {wanted} has no URL"))?,
                    sha256,
                    integrity,
                });
            }
            in_block = false;
        }
    }
    Err(format!(
        "MODULE.bazel has no {function} for {key}={wanted:?}"
    ))
}

fn assignment<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    line.strip_prefix(key)
        .and_then(|rest| rest.strip_prefix(" = "))
        .and_then(quoted_value)
}

fn quoted_value(line: &str) -> Option<&str> {
    let start = line.find('"')? + 1;
    let end = line[start..].find('"')? + start;
    Some(&line[start..end])
}

fn tar_files(bytes: &[u8], root: &str) -> Result<BTreeMap<String, String>, String> {
    let mut files = BTreeMap::new();
    let mut offset = 0;
    while offset + BLOCK <= bytes.len() {
        let header = &bytes[offset..offset + BLOCK];
        if header.iter().all(|byte| *byte == 0) {
            return Ok(files);
        }
        let size = parse_octal(&header[124..136])?;
        let data_start = offset + BLOCK;
        let data_end = data_start.checked_add(size).ok_or("tar size overflow")?;
        if data_end > bytes.len() {
            return Err("truncated tar entry".into());
        }
        let kind = header[156];
        if kind == 0 || kind == b'0' {
            let path = tar_path(header)?;
            let relative = path
                .strip_prefix(root)
                .and_then(|path| path.strip_prefix('/'))
                .ok_or_else(|| format!("tar entry is outside {root}/: {path}"))?;
            files.insert(relative.into(), sha256_hex(&bytes[data_start..data_end]));
        } else if kind != b'5' {
            return Err(format!(
                "unsupported tar entry type {kind} at offset {offset}"
            ));
        }
        offset = data_start + size.div_ceil(BLOCK) * BLOCK;
    }
    Err("tar has no zero terminator".into())
}

fn tar_end(bytes: &[u8]) -> Result<usize, String> {
    let mut offset = 0;
    while offset + BLOCK <= bytes.len() {
        let header = &bytes[offset..offset + BLOCK];
        if header.iter().all(|byte| *byte == 0) {
            return Ok(offset);
        }
        let size = parse_octal(&header[124..136])?;
        offset = offset
            .checked_add(BLOCK + size.div_ceil(BLOCK) * BLOCK)
            .ok_or("tar offset overflow")?;
    }
    Err("tar has no zero terminator".into())
}

fn parse_octal(field: &[u8]) -> Result<usize, String> {
    let text = std::str::from_utf8(field).map_err(|_| "tar octal field is not ASCII")?;
    let text = text.trim_matches(['\0', ' ']);
    usize::from_str_radix(if text.is_empty() { "0" } else { text }, 8)
        .map_err(|e| format!("invalid tar octal field: {e}"))
}

fn tar_path(header: &[u8]) -> Result<String, String> {
    let name = nul_text(&header[0..100])?;
    let prefix = nul_text(&header[345..500])?;
    Ok(if prefix.is_empty() {
        name.into()
    } else {
        format!("{prefix}/{name}")
    })
}

fn nul_text(bytes: &[u8]) -> Result<&str, String> {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    std::str::from_utf8(&bytes[..end]).map_err(|_| "tar path is not UTF-8".into())
}

fn append_files(input: &[u8], files: &[(&str, &[u8])]) -> Result<Vec<u8>, String> {
    let end = tar_end(input)?;
    let mut output = input[..end].to_vec();
    for (path, data) in files {
        output.extend_from_slice(&tar_header(path, data.len(), 0o644)?);
        output.extend_from_slice(data);
        output.resize(output.len().next_multiple_of(BLOCK), 0);
    }
    output.resize(output.len() + BLOCK * 2, 0);
    Ok(output)
}

fn tar_header(path: &str, size: usize, mode: u32) -> Result<[u8; BLOCK], String> {
    if path.len() > 100 || !path.is_ascii() {
        return Err(format!(
            "manifest tar path does not fit ustar name field: {path}"
        ));
    }
    let mut header = [0u8; BLOCK];
    header[..path.len()].copy_from_slice(path.as_bytes());
    put_octal(&mut header[100..108], mode as usize)?;
    put_octal(&mut header[108..116], 0)?;
    put_octal(&mut header[116..124], 0)?;
    put_octal(&mut header[124..136], size)?;
    put_octal(&mut header[136..148], 946_684_800)?; // UTC 2000-01-01
    header[148..156].fill(b' ');
    header[156] = b'0';
    header[257..263].copy_from_slice(b"ustar\0");
    header[263..265].copy_from_slice(b"00");
    let checksum: usize = header.iter().map(|byte| *byte as usize).sum();
    let encoded = format!("{checksum:06o}\0 ");
    header[148..156].copy_from_slice(encoded.as_bytes());
    Ok(header)
}

fn put_octal(field: &mut [u8], value: usize) -> Result<(), String> {
    let encoded = format!("{:0width$o}\0", value, width = field.len() - 1);
    if encoded.len() != field.len() {
        return Err("value does not fit tar octal field".into());
    }
    field.copy_from_slice(encoded.as_bytes());
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODULE: &str = r#"
archive_override(
    module_name = "gitz",
    integrity = "sha256-abc=",
    url = "https://github.com/OpytAI/gitz/archive/0123456789abcdef0123456789abcdef01234567.tar.gz",
)
http_archive(
    name = "firecracker",
    sha256 = "aaaa",
    urls = ["https://example.test/firecracker.tgz"],
)
"#;

    #[test]
    fn reads_module_pins() {
        let gitz = module_pin(MODULE, "archive_override", "module_name", "gitz").unwrap();
        assert_eq!(gitz.integrity.as_deref(), Some("sha256-abc="));
        assert!(gitz.url.ends_with(".tar.gz"));
        let firecracker = module_pin(MODULE, "http_archive", "name", "firecracker").unwrap();
        assert_eq!(firecracker.sha256.as_deref(), Some("aaaa"));
    }

    #[test]
    fn appends_and_indexes_tar_files() {
        let mut tar = Vec::new();
        tar.extend_from_slice(&tar_header("root/a", 3, 0o644).unwrap());
        tar.extend_from_slice(b"abc");
        tar.resize(tar.len().next_multiple_of(BLOCK), 0);
        tar.resize(tar.len() + BLOCK * 2, 0);
        let indexed = tar_files(&tar, "root").unwrap();
        assert_eq!(indexed.get("a"), Some(&sha256_hex(b"abc")));
        let next = append_files(&tar, &[("root/manifest.json", b"{}\n")]).unwrap();
        let indexed = tar_files(&next, "root").unwrap();
        assert!(indexed.contains_key("manifest.json"));
    }
}
