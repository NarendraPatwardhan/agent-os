//! CLI mode: the thin client. `typst compile <input.typ> [output.pdf]` connects to the warm `typst`
//! service, sends the input's absolute path, drains the framed response, writes the PDF, and prints any
//! diagnostics — the §3.3 one-binary face over the same warm engine the Luau library reaches.

use std::path::{Path, PathBuf};

use sysroot as rt;

use crate::proto::{unframe, Header, PROTO_VERSION};
use crate::serve::TYPST_VERSION;

const SERVICE_NAME: &str = "typst";

const HELP: &str = "\
typst — compile a Typst source file to PDF

Usage: typst compile <input.typ> [output.pdf]

Arguments:
  <input.typ>   the Typst source to compile
  [output.pdf]  where to write the PDF (default: input with a .pdf extension)

Options:
  -h, --help     display this help and exit
      --version  print the compiler version and exit

Notes:
  - Fonts: the faces under /usr/share/fonts (the paper flavor's font layer), scanned at startup.
  - `@preview` packages need network access and are not supported in this build.

Exit status:
  0  the PDF was written
  1  a compilation error occurred (diagnostics go to stderr)
  2  a usage error (bad arguments)
";

/// Run the CLI over `args` (everything after argv[0]). Never returns.
pub fn run(args: &[String]) -> ! {
    if args.iter().any(|a| a == "-h" || a == "--help") {
        print!("{HELP}");
        std::process::exit(0);
    }
    if args.iter().any(|a| a == "--version") {
        // The embedded compiler version is the meaningful one; report it without a round-trip.
        println!("typst {TYPST_VERSION}");
        std::process::exit(0);
    }

    // Only the `compile` subcommand exists; accept a bare `typst <input>` too (memcontainers parity).
    let mut rest: &[String] = args;
    if rest.first().map(String::as_str) == Some("compile") {
        rest = &args[1..];
    }
    let input = match rest.first() {
        Some(p) => PathBuf::from(p),
        None => {
            eprint!("typst: missing input file\n\n{HELP}");
            std::process::exit(2);
        }
    };
    if rest.len() > 2 {
        eprint!("typst: too many arguments\n\n{HELP}");
        std::process::exit(2);
    }
    let output = match rest.get(1) {
        Some(p) => PathBuf::from(p),
        None => input.with_extension("pdf"),
    };

    // The service reads the source itself (it has CAP_FS_READ); hand it an absolute path so its cwd does
    // not matter.
    let abs = absolutize(&input);
    let request = serde_json::json!({
        "v": PROTO_VERSION,
        "op": "compile",
        "main": abs.to_string_lossy(),
    });
    let req_bytes = serde_json::to_vec(&request).unwrap_or_default();

    let conn = match rt::svc_connect(SERVICE_NAME) {
        Ok(fd) => fd,
        Err(_) => {
            eprintln!("typst: service unavailable");
            std::process::exit(1);
        }
    };
    let result = match rt::svc_call(conn, &req_bytes, &[]) {
        Ok(fd) => fd,
        Err(_) => {
            eprintln!("typst: call failed");
            std::process::exit(1);
        }
    };

    let data = match drain(result) {
        Ok(d) => d,
        Err(_) => {
            // The service died mid-stream (crash-only); the result read fails.
            eprintln!("typst: service error");
            std::process::exit(1);
        }
    };
    let (header, body) = match unframe(&data) {
        Some(pair) => pair,
        None => {
            eprintln!("typst: malformed response from service");
            std::process::exit(1);
        }
    };

    report(&header);
    if !header.ok {
        std::process::exit(1);
    }
    if let Err(e) = std::fs::write(&output, body) {
        eprintln!("typst: writing {}: {e}", output.display());
        std::process::exit(1);
    }
    std::process::exit(0);
}

/// Print each diagnostic to stderr as `severity: file:line:col: message` (+ hints), matching the
/// memcontainers tool's stderr format.
fn report(header: &Header) {
    for d in &header.diagnostics {
        match (&d.file, d.line, d.col) {
            (Some(file), Some(line), Some(col)) => {
                eprintln!("{}: {file}:{line}:{col}: {}", d.severity, d.message)
            }
            _ => eprintln!("{}: {}", d.severity, d.message),
        }
        for hint in &d.hints {
            eprintln!("  hint: {hint}");
        }
    }
}

/// Read the result fd to EOF. `Err` means the service failed mid-stream.
fn drain(fd: i32) -> Result<Vec<u8>, i32> {
    let mut out = Vec::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => return Ok(out),
            Ok(n) => out.extend_from_slice(&buf[..n]),
            Err(e) => return Err(e),
        }
    }
}

/// Make a path absolute against the cwd (the service's path resolution needs an absolute path).
fn absolutize(p: &Path) -> PathBuf {
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|d| d.join(p))
            .unwrap_or_else(|_| p.to_path_buf())
    }
}
