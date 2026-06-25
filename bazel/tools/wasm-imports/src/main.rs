//! `wasm-imports <wasm> <module>` — the CLI surface over the import-section oracle
//! ([`wasm_imports::imported_function_symbols`]), the primitive behind conformance
//! (SYSTEMS.md) and capability attestation (SYSTEMS.md).
//!
//! Default: print the sorted FUNCTION symbols `<wasm>` imports from `<module>`, one per
//! line — the shape a Bazel `genrule` captures or a golden file diffs.
//!
//! Two optional check modes layer the set comparison the gates need on top of that walk,
//! without thickening the library:
//!
//!   --require <symbol>…      every listed symbol MUST be imported (coverage
//!                            direction). Exit 1 listing any that are missing.
//!   --allowed-file <path>    imports ⊆ the symbols in <path> (one per line; blanks and
//!                            `#` comments ignored) — the safety / attestation direction.
//!                            Exit 1 listing any disallowed import.
//!
//! With neither flag the symbols are printed and the process exits 0 (or errors on a
//! malformed/missing wasm — never panics).

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result};
use clap::Parser as ClapParser;

use wasm_imports::ImportedSymbols;

#[derive(ClapParser, Debug)]
#[command(
    name = "wasm-imports",
    about = "List the function symbols a wasm imports from a module (conformance/attestation oracle)"
)]
struct Args {
    /// Path to the guest `.wasm` to inspect.
    wasm: PathBuf,

    /// The import module to scope to (e.g. `mc` or `env`).
    module: String,

    /// Require each of these symbols to be imported; exit non-zero if any is missing.
    #[arg(long, value_name = "SYMBOL", num_args = 1..)]
    require: Vec<String>,

    /// Assert imports ⊆ the symbols listed in this file (one per line, `#` comments ok).
    #[arg(long, value_name = "PATH")]
    allowed_file: Option<PathBuf>,
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(e) => {
            // `{:#}` chains the anyhow context (e.g. "reading <path>: No such file").
            eprintln!("wasm-imports: error: {e:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<ExitCode> {
    let args = Args::parse();

    let wasm = std::fs::read(&args.wasm)
        .with_context(|| format!("reading wasm `{}`", args.wasm.display()))?;
    let symbols = ImportedSymbols::from_wasm(&wasm, &args.module)
        .with_context(|| format!("walking imports of `{}`", args.wasm.display()))?;

    let mut failed = false;

    // --require: every named symbol must be imported (coverage / mandatory set).
    if !args.require.is_empty() {
        let missing = symbols.missing(&args.require);
        if !missing.is_empty() {
            failed = true;
            eprintln!(
                "wasm-imports: `{}` does not import required {} symbol(s) from `{}`:",
                args.wasm.display(),
                missing.len(),
                args.module
            );
            for s in &missing {
                eprintln!("  missing: {s}");
            }
        }
    }

    // --allowed-file: imports ⊆ allowed (safety / attestation).
    if let Some(path) = &args.allowed_file {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading allowed-file `{}`", path.display()))?;
        let allowed: Vec<String> = text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .map(str::to_string)
            .collect();
        let disallowed = symbols.disallowed(&allowed);
        if !disallowed.is_empty() {
            failed = true;
            eprintln!(
                "wasm-imports: `{}` imports {} symbol(s) from `{}` not in `{}`:",
                args.wasm.display(),
                disallowed.len(),
                args.module,
                path.display()
            );
            for s in &disallowed {
                eprintln!("  disallowed: {s}");
            }
        }
    }

    // Default surface: the sorted symbols, one per line, on stdout.
    for name in symbols.iter() {
        println!("{name}");
    }

    Ok(if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    })
}
