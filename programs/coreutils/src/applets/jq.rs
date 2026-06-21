//! `jq` — command-line JSON processor (the external-crate `jaq` engine, VISION §16.3). A clap CLI
//! over jaq's `Loader`/`Compiler`/`Ctx`; reads JSON from stdin or files, applies the FILTER, prints
//! each result. std I/O → the WASI→mc adapter.
//!
//! Deviations from jq 1.7 (inherited from the memcontainers port): only -c/-r/-n; no -s/--slurp,
//! -a, -S/--sort-keys, -e/--exit-status, --arg/--argjson, --tab/--indent, -j/--join-output; the
//! FILTER must be on the command line (no -f/--from-file). Read-only (stdin/files → stdout). Ported
//! from memcontainers' `wasi::jq`.

use std::io::Read;

use clap::{Arg, ArgAction, Command};
use jaq_core::load::{Arena, File, Loader};
use jaq_core::{Compiler, Ctx, Native, RcIter};
use jaq_json::Val;

/// The clap command — jq's flag surface AND its `--help`.
fn command() -> Command {
    Command::new("jq")
        .about("Command-line JSON processor (jaq engine).")
        .override_usage("jq [OPTION]... FILTER [FILE]...")
        .arg(
            Arg::new("compact")
                .short('c')
                .action(ArgAction::SetTrue)
                .help("compact output (one JSON value per line, not pretty-printed)"),
        )
        .arg(
            Arg::new("raw")
                .short('r')
                .action(ArgAction::SetTrue)
                .help("raw output: print string results without surrounding quotes"),
        )
        .arg(
            Arg::new("null-input")
                .short('n')
                .action(ArgAction::SetTrue)
                .help("null input: do not read input; run FILTER once against `null`"),
        )
        .arg(
            Arg::new("FILTER_AND_FILES")
                .action(ArgAction::Append)
                .help("the jq FILTER, then input FILEs (- for standard input)"),
        )
        .after_help(
            "FILTER is a jq program, e.g. `.`, `.foo`, `.[] | .name`, `map(.x)`. With no FILE, or\n\
             when FILE is -, read JSON from standard input. Backed by the pure-Rust jaq engine.",
        )
}

fn print_val(v: &Val, compact: bool, raw: bool) {
    let json: serde_json::Value = v.clone().into();
    if raw {
        if let serde_json::Value::String(s) = &json {
            println!("{s}");
            return;
        }
    }
    let s = if compact {
        serde_json::to_string(&json)
    } else {
        serde_json::to_string_pretty(&json)
    }
    .unwrap_or_default();
    println!("{s}");
}

/// `jq [OPTION]... FILTER [FILE]...`. Exit: 0 ok, 2 usage/file, 3 compile error, 5 filter/runtime.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };
    let compact = m.get_flag("compact");
    let raw = m.get_flag("raw");
    let null_input = m.get_flag("null-input");
    let mut operands: Vec<String> =
        m.get_many::<String>("FILTER_AND_FILES").map(|v| v.cloned().collect()).unwrap_or_default();
    if operands.is_empty() {
        eprintln!("usage: jq [-c] [-r] [-n] FILTER [FILE...]");
        return 2;
    }
    let filter_src = operands.remove(0);
    let files = operands;

    // Compile the filter against the jaq + json definitions.
    let program = File { code: filter_src.as_str(), path: () };
    let loader = Loader::new(jaq_std::defs().chain(jaq_json::defs()));
    let arena = Arena::default();
    let modules = match loader.load(&arena, program) {
        Ok(m) => m,
        Err(errs) => {
            eprintln!("jq: compile error: {errs:?}");
            return 3;
        }
    };
    let filter = match Compiler::<_, Native<Val>>::default()
        .with_funs(jaq_std::funs().chain(jaq_json::funs()))
        .compile(modules)
    {
        Ok(f) => f,
        Err(errs) => {
            eprintln!("jq: compile error: {errs:?}");
            return 3;
        }
    };

    // Gather input text (stdin, or the files concatenated).
    let input_text = if files.is_empty() {
        let mut s = String::new();
        let _ = std::io::stdin().read_to_string(&mut s);
        s
    } else {
        let mut s = String::new();
        for f in &files {
            match std::fs::read_to_string(f) {
                Ok(c) => s.push_str(&c),
                Err(e) => {
                    eprintln!("jq: {f}: {e}");
                    return 2;
                }
            }
        }
        s
    };

    let inputs = RcIter::new(core::iter::empty());
    let mut had_error = false;
    let run_one = |val: Val, had_error: &mut bool| {
        let ctx = Ctx::new([], &inputs);
        for out in filter.run((ctx, val)) {
            match out {
                Ok(v) => print_val(&v, compact, raw),
                Err(e) => {
                    eprintln!("jq: error: {e}");
                    *had_error = true;
                }
            }
        }
    };

    if null_input {
        run_one(Val::from(serde_json::Value::Null), &mut had_error);
    } else {
        let stream =
            serde_json::Deserializer::from_str(&input_text).into_iter::<serde_json::Value>();
        for item in stream {
            match item {
                Ok(v) => run_one(Val::from(v), &mut had_error),
                Err(e) => {
                    eprintln!("jq: parse error: {e}");
                    had_error = true;
                }
            }
        }
    }

    if had_error {
        5
    } else {
        0
    }
}
