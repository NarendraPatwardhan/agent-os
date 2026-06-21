//! `mc-roster <box.wasm> <target> [<box.wasm> <target>]... <out.tar>` — read each box's
//! `mc_applets` roster and emit a deterministic tar of `/bin/<applet>` → `<target>` symlinks.
//!
//! The (box, target) pairs are given in ASCENDING tier order; each applet symlinks to the FIRST
//! (lowest-tier) box that carries it. Because a box is stamped its own tier and runs every applet
//! at that tier, this routes each command to its least-privilege box — `echo`→isolated,
//! `cat`→readonly, `rm`→readwrite, `find`→full — even though a higher box's cumulative roster also
//! lists the lower applets. With one pair it degenerates to "all of this box's applets → it".
//!
//! The roster is the SINGLE source for a box's applet set: the `mcbox!` macro builds it from the
//! very list it builds the dispatch from, so the staged `/bin` cannot drift from what the boxes
//! actually run (VISION §16.3 — generated, never a hand list). The tar is content-addressed:
//! entries are name-sorted, owner/mtime zero, so its bytes are a pure function of the rosters.

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
            if &wasm[nstart..nend] == want.as_bytes() {
                return Some(wasm[nend..end].to_vec());
            }
        }
        i = end;
    }
    None
}

/// A 512-byte ustar header for the relative symlink `bin/<name>` → `target` (mode 0777, owner 0,
/// mtime 0 — all fixed for reproducibility).
fn symlink_header(name: &str, target: &str) -> [u8; 512] {
    let mut h = [0u8; 512];
    let path = format!("bin/{name}");
    h[0..path.len()].copy_from_slice(path.as_bytes()); // name[100]
    h[100..108].copy_from_slice(b"0000777\0"); // mode
    h[108..116].copy_from_slice(b"0000000\0"); // uid
    h[116..124].copy_from_slice(b"0000000\0"); // gid
    h[124..136].copy_from_slice(b"00000000000\0"); // size = 0
    h[136..148].copy_from_slice(b"00000000000\0"); // mtime = 0
    h[148..156].copy_from_slice(b"        "); // chksum: spaces during computation
    h[156] = b'2'; // typeflag: symlink
    h[157..157 + target.len()].copy_from_slice(target.as_bytes()); // linkname[100]
    h[257..263].copy_from_slice(b"ustar\0"); // magic
    h[263..265].copy_from_slice(b"00"); // version
    let sum: u32 = h.iter().map(|&b| b as u32).sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    h
}

fn read_roster(path: &str) -> Result<Vec<String>, String> {
    let wasm = std::fs::read(path).map_err(|e| format!("reading {path}: {e}"))?;
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        return Err(format!("{path} is not a wasm module"));
    }
    let roster = custom_section(&wasm, "mc_applets").unwrap_or_default();
    Ok(String::from_utf8_lossy(&roster)
        .split('\n')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    // <box.wasm> <target> [<box.wasm> <target>]... <out.tar>: an even argc (pairs + out + argv0).
    if args.len() < 4 || args.len() % 2 != 0 {
        eprintln!("usage: mc-roster <box.wasm> <target> [<box.wasm> <target>]... <out.tar>");
        return ExitCode::from(2);
    }
    let out = &args[args.len() - 1];

    // applet -> target, FIRST (lowest-tier) box wins; BTreeMap keeps it name-sorted (deterministic).
    let mut links: BTreeMap<String, String> = BTreeMap::new();
    let mut i = 1;
    while i + 1 < args.len() {
        let (path, target) = (&args[i], &args[i + 1]);
        i += 2;
        match read_roster(path) {
            Ok(applets) => {
                for a in applets {
                    links.entry(a).or_insert_with(|| target.clone());
                }
            }
            Err(e) => {
                eprintln!("mc-roster: {e}");
                return ExitCode::from(2);
            }
        }
    }

    let mut tar = Vec::new();
    for (name, target) in &links {
        tar.extend_from_slice(&symlink_header(name, target));
    }
    tar.extend_from_slice(&[0u8; 1024]); // two zero blocks terminate the archive

    if let Err(e) = std::fs::write(out, &tar) {
        eprintln!("mc-roster: writing {out}: {e}");
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}
