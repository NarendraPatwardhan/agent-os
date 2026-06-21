//! `awk` — pattern-directed scanning and processing (the external-crate `awk-rs` tree-walking
//! interpreter, VISION §16.3). A clap CLI over awk-rs's `Lexer`/`Parser`/`Interpreter`; std I/O →
//! the WASI→mc adapter. Supports -F (field separator), -v (variable assignment), -f (program
//! file), and a PROGRAM + FILE/stdin operands with ARGC/ARGV.
//!
//! Deviations: awk-rs is an early POSIX subset — some printf/gsub/function corners may be missing;
//! no --version, no gawk extensions (gensub/asort/…). `print > "file"` writes, so awk is read-write.
//! Ported from memcontainers' `wasi::awk` (the hand-rolled getopt → clap).

use std::io::{self, BufRead, BufReader, Write};

use awk_rs::{Interpreter, Lexer, Parser};
use clap::{Arg, ArgAction, Command};

/// The clap command — awk's flag surface AND its `--help`.
fn command() -> Command {
    Command::new("awk")
        .about("Pattern-directed scanning and processing language (awk-rs engine).")
        .override_usage("awk [-F SEP] [-v VAR=VALUE]... {PROGRAM | -f FILE} [FILE]...")
        .arg(
            Arg::new("field-separator")
                .short('F')
                .value_name("SEP")
                .help("set the input field separator FS (-FSEP is also accepted)"),
        )
        .arg(
            Arg::new("assign")
                .short('v')
                .value_name("VAR=VALUE")
                .action(ArgAction::Append)
                .help("assign VAR before the program runs (repeatable)"),
        )
        .arg(
            Arg::new("program-file")
                .short('f')
                .value_name("FILE")
                .action(ArgAction::Append)
                .help("read the awk program from FILE instead of the command line"),
        )
        .arg(
            Arg::new("PROGRAM_OR_FILE")
                .action(ArgAction::Append)
                .help("the awk PROGRAM (unless -f is given), then input FILEs (- for standard input)"),
        )
        .after_help(
            "PROGRAM is an awk script, e.g. `{ print $1 }`, `/re/ { ... }`, `END { ... }`. With no\n\
             input FILE, or when FILE is -, read standard input; ARGC/ARGV are set. awk-rs is an\n\
             early POSIX subset — some printf/gsub/function corners may be missing.",
        )
}

/// `awk [OPTION]... {PROGRAM | -f FILE} [FILE]...`. Exit: 0 success, 2 a usage/parse/runtime error.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };
    match run(&m) {
        Ok(code) => {
            let _ = io::stdout().flush();
            code
        }
        Err(msg) => {
            eprintln!("awk: {msg}");
            2
        }
    }
}

fn run(m: &clap::ArgMatches) -> Result<i32, String> {
    let field_separator =
        m.get_one::<String>("field-separator").cloned().unwrap_or_else(|| " ".to_string());

    let mut variables: Vec<(String, String)> = Vec::new();
    if let Some(assigns) = m.get_many::<String>("assign") {
        for a in assigns {
            let (name, value) =
                a.split_once('=').ok_or_else(|| format!("invalid variable assignment: {a}"))?;
            variables.push((name.to_string(), value.to_string()));
        }
    }

    let program_files: Vec<String> =
        m.get_many::<String>("program-file").map(|v| v.cloned().collect()).unwrap_or_default();
    let mut operands: Vec<String> =
        m.get_many::<String>("PROGRAM_OR_FILE").map(|v| v.cloned().collect()).unwrap_or_default();

    // The program: the -f FILE(s) concatenated, else the first operand. The rest are input files.
    let source = if !program_files.is_empty() {
        let mut s = String::new();
        for f in &program_files {
            s.push_str(&std::fs::read_to_string(f).map_err(|e| format!("{f}: {e}"))?);
            s.push('\n');
        }
        s
    } else {
        if operands.is_empty() {
            return Err("no program provided".to_string());
        }
        operands.remove(0)
    };
    let input_files = operands;

    let mut lexer = Lexer::new(&source);
    let tokens = lexer.tokenize().map_err(|e| format!("{e}"))?;
    let mut parser = Parser::new(tokens);
    let program = parser.parse().map_err(|e| format!("{e}"))?;

    let mut interpreter = Interpreter::new(&program);
    interpreter.set_fs(&field_separator);
    let mut argv = vec!["awk".to_string()];
    argv.extend(input_files.iter().cloned());
    interpreter.set_args(argv);
    for (name, value) in &variables {
        interpreter.set_variable(name, value);
    }

    let stdout = io::stdout();
    let mut output = stdout.lock();
    let stdin = io::stdin();
    let mut inputs: Vec<Box<dyn BufRead + '_>> = Vec::new();
    if input_files.is_empty() {
        interpreter.set_filename("");
        inputs.push(Box::new(BufReader::new(stdin.lock())));
    } else {
        // awk-rs runs BEGIN/END once around the whole invocation, so feed all files together and
        // keep the first operand as FILENAME (rather than re-running BEGIN/END per file).
        interpreter.set_filename(if input_files[0] == "-" { "" } else { &input_files[0] });
        for filename in &input_files {
            if filename == "-" {
                inputs.push(Box::new(BufReader::new(stdin.lock())));
            } else {
                let file =
                    std::fs::File::open(filename).map_err(|e| format!("{filename}: {e}"))?;
                inputs.push(Box::new(BufReader::new(file)));
            }
        }
    }
    interpreter.run(inputs, &mut output).map_err(|e| format!("{e}"))
}
