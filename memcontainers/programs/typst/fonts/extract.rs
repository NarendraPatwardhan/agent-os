//! `typst-extract-fonts <out.tar>` — materialize the `typst_assets` baseline faces into a deterministic
//! tar carrying `usr/`, `usr/share/`, `usr/share/fonts/`, and each face at
//! `usr/share/fonts/face_<NN>.ttf` (SYSTEMS.md). The engine does NOT embed fonts; it scans
//! `/usr/share/fonts` at startup, so this layer (merged into the paper flavor via `pkg_tar` deps)
//! supplies the default faces — derived from the SAME `typst_assets` the engine was designed around,
//! so the shipped faces and the engine can never drift. Built for the HOST (the font bytes ride in via
//! `typst_assets`, an `include_bytes!` crate); the only dep. The ustar writer is hand-rolled, mirroring
//! mc-svc-manifest / mc-roster (dependency-free, fixed owner/mtime → reproducible).
//!
//! Faces are all named `.ttf` regardless of their real format: the engine's scan gates only on the
//! extension, and `Font::iter` parses TrueType *and* OpenType faces by their sfnt magic, not by name.

use std::process::ExitCode;

/// A 512-byte ustar header for `path` (octal `mode`, owner 0, mtime 0 — fixed for reproducibility).
fn header(path: &str, size: usize, mode: &[u8; 8], typeflag: u8) -> [u8; 512] {
    let mut h = [0u8; 512];
    h[0..path.len()].copy_from_slice(path.as_bytes()); // name[100]
    h[100..108].copy_from_slice(mode); // mode (7 octal digits + NUL)
    h[108..116].copy_from_slice(b"0000000\0"); // uid
    h[116..124].copy_from_slice(b"0000000\0"); // gid
    h[124..136].copy_from_slice(format!("{size:011o}\0").as_bytes()); // size (octal, 11 digits + NUL)
    h[136..148].copy_from_slice(b"00000000000\0"); // mtime = 0
    h[148..156].copy_from_slice(b"        "); // chksum: spaces during computation
    h[156] = typeflag;
    h[257..263].copy_from_slice(b"ustar\0"); // magic
    h[263..265].copy_from_slice(b"00"); // version
    let sum: u32 = h.iter().map(|&b| b as u32).sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    h
}

/// A regular-file header. Mirrors mc-svc-manifest's `file_header`.
fn file_header(path: &str, size: usize, mode: &[u8; 8]) -> [u8; 512] {
    header(path, size, mode, b'0')
}

/// Append a directory entry. The font layer owns the path it expects the engine to scan.
fn append_dir(tar: &mut Vec<u8>, path: &str) {
    tar.extend_from_slice(&header(path, 0, b"0000755\0", b'5'));
}

/// Append a regular-file entry (header + content + NUL pad to the next 512-byte boundary).
fn append_file(tar: &mut Vec<u8>, path: &str, data: &[u8], mode: &[u8; 8]) {
    tar.extend_from_slice(&file_header(path, data.len(), mode));
    tar.extend_from_slice(data);
    let pad = (512 - data.len() % 512) % 512;
    tar.resize(tar.len() + pad, 0);
}

fn main() -> ExitCode {
    let out = match std::env::args().nth(1) {
        Some(p) => p,
        None => {
            eprintln!("usage: typst-extract-fonts <out.tar>");
            return ExitCode::from(2);
        }
    };

    let mut tar = Vec::new();
    for dir in ["usr", "usr/share", "usr/share/fonts"] {
        append_dir(&mut tar, dir);
    }
    let mut count = 0usize;
    for (i, data) in typst_assets::fonts().enumerate() {
        // 0644: plain data the engine reads at startup (not executable).
        append_file(
            &mut tar,
            &format!("usr/share/fonts/face_{i:02}.ttf"),
            data,
            b"0000644\0",
        );
        count += 1;
    }
    if count == 0 {
        eprintln!("typst-extract-fonts: typst_assets yielded no fonts (the `fonts` feature off?)");
        return ExitCode::from(1);
    }
    tar.extend_from_slice(&[0u8; 1024]); // two zero blocks terminate the archive

    if let Err(e) = std::fs::write(&out, &tar) {
        eprintln!("typst-extract-fonts: writing {out}: {e}");
        return ExitCode::from(2);
    }
    ExitCode::SUCCESS
}
