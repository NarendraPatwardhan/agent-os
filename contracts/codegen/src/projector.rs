//! `projector` — reads one contract (`contracts/*.kdl`) and emits one target
//! language's binding to stdout (VISION §6.2). The single tool behind every
//! projection: `abi_library` invokes it once per (contract, language) pair.
//!
//! This is the SEED, not the finished tool (Phase A step 3). The kernel's table
//! logic in memcontainers `crates/abi` is the reference to port: it already proves
//! that a name/signature table can drive a Rust kernel's `Pending` enum, the wasmi
//! registration, and the guest `extern` block from one source. Here that logic is
//! lifted out of Rust into data (the `.kdl`) and projected into Rust + Zig + TS, so
//! the polyglot system (Rust kernel, Zig shims, TS client — and a Zig kernel later)
//! cannot drift.
//!
//! Design notes for the implementor (why this shape):
//!   - DETERMINISM (A7/B2): same inputs → byte-identical output. No clock, no env,
//!     stable iteration order. The drift gate (write_source_files + diff_test) only
//!     works if the output is reproducible.
//!   - ONE PARSER: parse the .kdl into a small in-memory model (Contract { consts,
//!     rows }), then have a per-language emitter walk that model. Adding a language
//!     is a new emitter, never a new parser.
//!   - LITERATE OUTPUT (C1): generated files carry a "// @generated from
//!     contracts/<file> — do not edit" banner and the per-row `doc` as a doc comment,
//!     so a reader of the projection still gets the "why".

use std::process::ExitCode;

/// Target language for a projection (mirrors `_EXT` in codegen/defs.bzl).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Lang {
    Rust,
    Zig,
    Ts,
    AsyncApi,
    Md,
}

impl Lang {
    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "rust" => Lang::Rust,
            "zig" => Lang::Zig,
            "ts" => Lang::Ts,
            "asyncapi" => Lang::AsyncApi,
            "md" => Lang::Md,
            _ => return None,
        })
    }
}

fn main() -> ExitCode {
    // Minimal arg parse: --lang <l> --contract <path>. Kept dependency-light on
    // purpose; this binary is on the critical build path for every projection.
    let args: Vec<String> = std::env::args().collect();
    let (mut lang, mut contract) = (None, None);
    let mut i = 1;
    while i + 1 < args.len() {
        match args[i].as_str() {
            "--lang" => lang = Lang::parse(&args[i + 1]),
            "--contract" => contract = Some(args[i + 1].clone()),
            _ => {}
        }
        i += 2;
    }

    let (Some(lang), Some(contract)) = (lang, contract) else {
        eprintln!("usage: projector --lang <rust|zig|ts|asyncapi|md> --contract <path.kdl>");
        return ExitCode::FAILURE;
    };

    // TODO(Phase A step 3): read `contract`, parse the KDL into the Contract model,
    // and emit `lang`. Until then the projector is a documented stub so the codegen
    // package is a real home with a precise interface, not an empty directory.
    eprintln!(
        "projector: not yet implemented — would emit {lang:?} from {contract}. \
         Port memcontainers crates/abi table logic (VISION §6, §11 Phase A step 3)."
    );
    let _ = (lang, contract);
    ExitCode::FAILURE
}
