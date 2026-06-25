//! `grep` — the "from wasi / external-crate" representative (SYSTEMS.md): ripgrep's engine
//! (`grep-regex` + `grep-searcher`), pure **std** I/O (→ `wasi_snapshot_preview1` → `mc` via the
//! `//wasi-adapter`), `walkdir` for `-r`. The engine is ported verbatim from memcontainers'
//! grep; only two things change — the hand-rolled getopt becomes **clap** (reused),
//! and `main`→`uumain` (the multicall stamps the tier, so its `mc_tier!` is dropped). Files are
//! searched in memory (`search_slice`) because wasip1 has no mmap.
//!
//! Deviations from GNU (inherited from the memcontainers port): help is `--help` only because
//! `-h` keeps its POSIX/BSD meaning (suppress filenames); no -E/-G/-P, -o, context, -q/-s/-z,
//! or --include/--exclude; --color is accepted and ignored.

use std::io::Read;

use clap::{Arg, ArgAction, Command};
use grep_regex::RegexMatcherBuilder;
use grep_searcher::sinks::UTF8;
use grep_searcher::{BinaryDetection, SearcherBuilder};
use walkdir::WalkDir;

/// The clap command — grep's flag surface AND `--help`. `-h` is suppress-filenames (POSIX), so
/// clap's default `-h`/`--help` is disabled and a long-only `--help` added.
fn command() -> Command {
    Command::new("grep")
        .about("Search for PATTERN in each FILE or standard input.")
        .override_usage("grep [OPTION]... PATTERN [FILE]...\n       grep [OPTION]... -e PATTERN... [FILE]...")
        .disable_help_flag(true)
        .arg(Arg::new("help").long("help").action(ArgAction::Help).help("display this help and exit"))
        .arg(Arg::new("ignore-case").short('i').action(ArgAction::SetTrue).help("ignore case distinctions"))
        .arg(Arg::new("line-number").short('n').action(ArgAction::SetTrue).help("prefix each output line with its 1-based line number"))
        .arg(Arg::new("invert-match").short('v').action(ArgAction::SetTrue).help("select non-matching lines"))
        .arg(Arg::new("count").short('c').action(ArgAction::SetTrue).help("print only a count of matching lines per file"))
        .arg(Arg::new("files-with-matches").short('l').action(ArgAction::SetTrue).help("print only the names of files that contain a match"))
        .arg(Arg::new("recursive").short('r').visible_short_alias('R').action(ArgAction::SetTrue).help("search directories recursively"))
        .arg(Arg::new("fixed-strings").short('F').action(ArgAction::SetTrue).help("treat PATTERN as a fixed string, not a regular expression"))
        .arg(Arg::new("word-regexp").short('w').action(ArgAction::SetTrue).help("match only whole words"))
        .arg(Arg::new("with-filename").short('H').action(ArgAction::SetTrue).help("print the filename with each match"))
        .arg(Arg::new("no-filename").short('h').action(ArgAction::SetTrue).help("suppress filenames in output (NOT a help flag)"))
        .arg(Arg::new("color").long("color").num_args(0..=1).require_equals(true).default_missing_value("auto").help("accepted and ignored"))
        .arg(Arg::new("regexp").short('e').long("regexp").action(ArgAction::Append).help("match PATTERN (repeatable; lets a PATTERN begin with -)"))
        .arg(Arg::new("PATTERN_OR_FILE").action(ArgAction::Append).help("the PATTERN (unless -e is given) followed by FILEs"))
}

/// `grep [OPTION]... PATTERN [FILE]...`. Exit: 0 matched, 1 none matched, 2 error.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let ignore_case = m.get_flag("ignore-case");
    let line_number = m.get_flag("line-number");
    let invert = m.get_flag("invert-match");
    let count = m.get_flag("count");
    let files_with_matches = m.get_flag("files-with-matches");
    let recursive = m.get_flag("recursive");
    let fixed = m.get_flag("fixed-strings");
    let word = m.get_flag("word-regexp");
    let force_filename = m.get_flag("with-filename");
    let no_filename = m.get_flag("no-filename");

    let mut patterns: Vec<String> =
        m.get_many::<String>("regexp").map(|v| v.cloned().collect()).unwrap_or_default();
    let mut operands: Vec<String> = m
        .get_many::<String>("PATTERN_OR_FILE")
        .map(|v| v.cloned().collect())
        .unwrap_or_default();

    // Without -e, the first positional is the PATTERN; the rest are files.
    if patterns.is_empty() {
        if operands.is_empty() {
            eprintln!("usage: grep [OPTION]... PATTERN [FILE]...");
            return 2;
        }
        patterns.push(operands.remove(0));
    }
    let files = operands;

    let matcher = match RegexMatcherBuilder::new()
        .case_insensitive(ignore_case)
        .word(word)
        .fixed_strings(fixed)
        .build_many(&patterns)
    {
        Ok(matcher) => matcher,
        Err(e) => {
            eprintln!("grep: invalid pattern: {e}");
            return 2;
        }
    };

    let mut searcher = SearcherBuilder::new()
        // The UTF8 sink needs line numbers tracked; we only PRINT them when -n was given.
        .line_number(true)
        .invert_match(invert)
        .binary_detection(BinaryDetection::quit(b'\x00'))
        .memory_map(grep_searcher::MmapChoice::never())
        .build();

    // The file work-list: stdin if none; with -r, expand directories via walkdir.
    let targets: Vec<String> = if files.is_empty() {
        vec!["-".to_string()]
    } else if recursive {
        let mut t = Vec::new();
        for f in &files {
            if std::fs::metadata(f).map(|md| md.is_dir()).unwrap_or(false) {
                for entry in WalkDir::new(f).into_iter().flatten() {
                    if entry.file_type().is_file() {
                        t.push(entry.path().to_string_lossy().into_owned());
                    }
                }
            } else {
                t.push(f.clone());
            }
        }
        t
    } else {
        files.clone()
    };

    let show_name = !no_filename && (force_filename || recursive || targets.len() > 1);
    let mut any_match = false;
    let mut had_error = false;

    for path in &targets {
        // Read the whole input (no mmap on wasip1).
        let data = if path == "-" {
            let mut buf = Vec::new();
            if std::io::stdin().read_to_end(&mut buf).is_err() {
                had_error = true;
                continue;
            }
            buf
        } else {
            match std::fs::read(path) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("grep: {path}: {e}");
                    had_error = true;
                    continue;
                }
            }
        };

        let name = if path == "-" { "(standard input)" } else { path };
        let mut count_n: u64 = 0;
        let mut file_matched = false;

        let sink = UTF8(|lnum, line| {
            file_matched = true;
            count_n += 1;
            if !count && !files_with_matches {
                if show_name {
                    print!("{name}:");
                }
                if line_number {
                    print!("{lnum}:");
                }
                print!("{line}");
            }
            Ok(true)
        });

        if let Err(e) = searcher.search_slice(&matcher, &data, sink) {
            eprintln!("grep: {name}: {e}");
            had_error = true;
            continue;
        }

        if file_matched {
            any_match = true;
        }
        if files_with_matches {
            if file_matched {
                println!("{name}");
            }
        } else if count {
            if show_name {
                println!("{name}:{count_n}");
            } else {
                println!("{count_n}");
            }
        }
    }

    if had_error {
        2
    } else if any_match {
        0
    } else {
        1
    }
}
