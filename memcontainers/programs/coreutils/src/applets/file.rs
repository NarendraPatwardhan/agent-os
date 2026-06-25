//! `file` — determine file type (the external-crate `infer` magic-byte crate + a text/binary +
//! shebang/JSON/XML/HTML heuristic, VISION §16.3). A clap CLI; `-b` (brief, no name prefix), `-i`/
//! `--mime-type` (MIME output). std I/O → the WASI→mc adapter.
//!
//! Deviations from BSD/GNU file (inherited from the memcontainers port): only -b and -i; no -z
//! (compressed), -f/--files-from, -s (special files), -e, or symlink control; no libmagic database
//! or charset detection — types are coarse. Read-only. Ported from memcontainers' `wasi::file`.

use std::fs;
use std::io::{self, Read, Write};

use clap::{Arg, ArgAction, Command};

/// The clap command — file's flag surface AND its `--help`.
fn command() -> Command {
    Command::new("file")
        .about("Determine file type by content (the infer crate + a text/script heuristic).")
        .override_usage("file [-b] [-i] FILE...")
        .arg(
            Arg::new("brief")
                .short('b')
                .long("brief")
                .action(ArgAction::SetTrue)
                .help("do not prepend the filename to the output line"),
        )
        .arg(
            Arg::new("mime-type")
                .short('i')
                .long("mime-type")
                .visible_alias("mime")
                .action(ArgAction::SetTrue)
                .help("print the MIME type instead of a human description"),
        )
        .arg(
            Arg::new("FILE")
                .action(ArgAction::Append)
                .help("files to identify (- for standard input)"),
        )
        .after_help(
            "Detects type by content: magic bytes (the pure-Rust infer crate) plus a text/binary\n\
             and shebang/JSON/XML/HTML heuristic. Use - to read standard input.",
        )
}

/// `file [-b] [-i] FILE...`. Exit: 0 success, 1 a usage error or an unreadable file.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 1 };
        }
    };
    let brief = m.get_flag("brief");
    let mime = m.get_flag("mime-type");
    let filenames: Vec<String> =
        m.get_many::<String>("FILE").map(|v| v.cloned().collect()).unwrap_or_default();
    if filenames.is_empty() {
        eprintln!("Usage: file [-bi] FILE...");
        return 1;
    }

    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut exit_code = 0;

    for filename in &filenames {
        let data = if filename == "-" {
            let mut buf = Vec::new();
            match io::stdin().lock().read_to_end(&mut buf) {
                Ok(_) => buf,
                Err(e) => {
                    eprintln!("file: stdin: {e}");
                    exit_code = 1;
                    continue;
                }
            }
        } else {
            match fs::symlink_metadata(filename) {
                Ok(meta) => {
                    // Order matters: a symlink's metadata also reports is_dir for its target, so
                    // check symlink first.
                    if meta.file_type().is_symlink() {
                        print_result(&mut out, filename, brief, "symbolic link", "inode/symlink", mime);
                        continue;
                    }
                    if meta.is_dir() {
                        print_result(&mut out, filename, brief, "directory", "inode/directory", mime);
                        continue;
                    }
                    if meta.len() == 0 {
                        print_result(&mut out, filename, brief, "empty", "inode/x-empty", mime);
                        continue;
                    }
                    match read_head(filename, 8192) {
                        Ok(data) => data,
                        Err(e) => {
                            eprintln!("file: {filename}: {e}");
                            exit_code = 1;
                            continue;
                        }
                    }
                }
                Err(e) => {
                    eprintln!("file: {filename}: {e}");
                    exit_code = 1;
                    continue;
                }
            }
        };

        let (desc, mime_type) = identify(&data);
        print_result(&mut out, filename, brief, &desc, &mime_type, mime);
    }

    exit_code
}

fn read_head(path: &str, max: usize) -> io::Result<Vec<u8>> {
    let mut f = fs::File::open(path)?;
    let mut buf = vec![0u8; max];
    let n = f.read(&mut buf)?;
    buf.truncate(n);
    Ok(buf)
}

fn print_result<W: Write>(out: &mut W, filename: &str, brief: bool, desc: &str, mime_type: &str, use_mime: bool) {
    let body = if use_mime && !mime_type.is_empty() { mime_type } else { desc };
    if brief {
        let _ = writeln!(out, "{body}");
    } else {
        let _ = writeln!(out, "{filename}: {body}");
    }
}

fn identify(data: &[u8]) -> (String, String) {
    if data.is_empty() {
        return ("empty".to_string(), "inode/x-empty".to_string());
    }

    if let Some(kind) = infer::get(data) {
        let desc = match kind.mime_type() {
            "image/png" => "PNG image data",
            "image/jpeg" => "JPEG image data",
            "image/gif" => "GIF image data",
            "image/webp" => "WebP image data",
            "image/bmp" => "BMP image data",
            "image/tiff" => "TIFF image data",
            "image/x-icon" => "ICO image data",
            "application/pdf" => "PDF document",
            "application/zip" => "Zip archive data",
            "application/gzip" => "gzip compressed data",
            "application/x-bzip2" => "bzip2 compressed data",
            "application/x-xz" => "XZ compressed data",
            "application/x-tar" => "POSIX tar archive",
            "application/x-rar-compressed" => "RAR archive data",
            "application/x-7z-compressed" => "7-zip archive data",
            "application/x-executable" | "application/x-elf" => "ELF executable",
            "application/wasm" => "WebAssembly (wasm) binary module",
            "application/x-mach-binary" => "Mach-O binary",
            "audio/mpeg" => "MPEG audio",
            "audio/ogg" => "Ogg audio",
            "audio/x-flac" => "FLAC audio",
            "audio/x-wav" => "RIFF WAVE audio",
            "video/mp4" => "MPEG-4 video",
            "video/webm" => "WebM video",
            "video/x-matroska" => "Matroska video",
            "application/vnd.sqlite3" | "application/x-sqlite3" => "SQLite 3.x database",
            "font/woff" => "Web Open Font Format",
            "font/woff2" => "Web Open Font Format 2",
            other => other,
        };
        return (desc.to_string(), kind.mime_type().to_string());
    }

    // Shebang scripts.
    if data.len() >= 2 && data[0] == b'#' && data[1] == b'!' {
        let first_line: Vec<u8> = data.iter().take(128).take_while(|&&b| b != b'\n').copied().collect();
        if let Ok(line) = std::str::from_utf8(&first_line) {
            let interp = line.trim_start_matches("#!").trim();
            let name = interp.split_whitespace().next().unwrap_or(interp);
            let basename = name.rsplit('/').next().unwrap_or(name);
            let prog = if basename == "env" {
                interp.split_whitespace().nth(1).unwrap_or("script")
            } else {
                basename
            };
            return (format!("{prog} script, ASCII text executable"), "text/x-script".to_string());
        }
    }

    if is_json(data) {
        return ("JSON text data".to_string(), "application/json".to_string());
    }
    if is_xml(data) {
        return ("XML document".to_string(), "text/xml".to_string());
    }
    if is_html(data) {
        return ("HTML document".to_string(), "text/html".to_string());
    }
    if is_text(data) {
        return ("ASCII text".to_string(), "text/plain".to_string());
    }
    ("data".to_string(), "application/octet-stream".to_string())
}

fn is_text(data: &[u8]) -> bool {
    let check_len = data.len().min(8192);
    for &b in &data[..check_len] {
        if b == 0 {
            return false;
        }
        // Allow common control chars (tab, LF, CR, FF, BS, ESC); reject other low control bytes.
        if b < 0x08 || (b > 0x0D && b < 0x20 && b != 0x1B) {
            return false;
        }
    }
    true
}

fn is_json(data: &[u8]) -> bool {
    let t = skip_ws(data);
    !t.is_empty() && (t[0] == b'{' || t[0] == b'[')
}

fn is_xml(data: &[u8]) -> bool {
    let t = skip_ws(data);
    t.starts_with(b"<?xml") || t.starts_with(b"<!DOCTYPE")
}

fn is_html(data: &[u8]) -> bool {
    let t = skip_ws(data);
    let lower: Vec<u8> = t.iter().take(64).map(|b| b.to_ascii_lowercase()).collect();
    lower.starts_with(b"<!doctype html") || lower.starts_with(b"<html")
}

fn skip_ws(data: &[u8]) -> &[u8] {
    let mut i = 0;
    while i < data.len() && matches!(data[i], b' ' | b'\t' | b'\n' | b'\r') {
        i += 1;
    }
    &data[i..]
}
