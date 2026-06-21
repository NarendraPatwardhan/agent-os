//! `mc-roster <box.wasm> <target> <out.tar>` — read a box's `mc_applets` roster and emit a
//! deterministic tar of `/bin/<applet>` → `<target>` symlinks.
//!
//! The roster (an `mc_applets` custom section) is the SINGLE source for a box's applet set: the
//! `mcbox!` macro builds it from the very list it builds the dispatch from, so the staged `/bin`
//! symlinks cannot drift from what the box actually runs (VISION §16.3 — generated, never a hand
//! list). The tar is content-addressed: names are sorted, owner/mtime are zero, so its bytes are a
//! pure function of the roster (it layers into a flavor image by `pkg_tar`, A8/§10).

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

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: mc-roster <box.wasm> <target> <out.tar>");
        return ExitCode::from(2);
    }
    let wasm = match std::fs::read(&args[1]) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("mc-roster: reading {}: {e}", args[1]);
            return ExitCode::from(2);
        }
    };
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        eprintln!("mc-roster: {} is not a wasm module", args[1]);
        return ExitCode::from(2);
    }

    let roster = custom_section(&wasm, "mc_applets").unwrap_or_default();
    let mut names: Vec<&str> = std::str::from_utf8(&roster)
        .unwrap_or("")
        .split('\n')
        .filter(|s| !s.is_empty())
        .collect();
    names.sort_unstable(); // content-addressed: independent of link order
    names.dedup();

    let mut tar = Vec::new();
    for n in &names {
        tar.extend_from_slice(&symlink_header(n, &args[2]));
    }
    tar.extend_from_slice(&[0u8; 1024]); // two zero blocks terminate the archive

    if let Err(e) = std::fs::write(&args[3], &tar) {
        eprintln!("mc-roster: writing {}: {e}", args[3]);
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}
