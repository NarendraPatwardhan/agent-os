//! `diff` — compare two files or directories line by line (the external-crate `similar` Myers
//! engine, SYSTEMS.md). A clap CLI; unified (`-u`/`-U N`), context (`-c`/`-C N`), normal, and
//! brief (`-q`) output; `-r` recursive; `-i`/`-w`/`-B` ignore flags. std I/O → the WASI→mc adapter.
//!
//! Exit 0 (identical) / 1 (differ) / 2 (error). Deviations from GNU diff (inherited from the
//! memcontainers port): no -e/--ed, -n/--rcs, -y/--side-by-side, -N/--new-file, --color, --label,
//! -a/--text, -b/--ignore-space-change, -p/--show-c-function. Read-only. Ported from
//! memcontainers' `wasi::diff`.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use clap::{Arg, ArgAction, Command};
use similar::{ChangeTag, DiffOp, TextDiff};

struct Options {
    unified: bool,
    context_fmt: bool,
    context_lines: usize,
    recursive: bool,
    brief: bool,
    ignore_case: bool,
    ignore_whitespace: bool,
    ignore_blank_lines: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            unified: false,
            context_fmt: false,
            context_lines: 3,
            recursive: false,
            brief: false,
            ignore_case: false,
            ignore_whitespace: false,
            ignore_blank_lines: false,
        }
    }
}

/// The clap command — diff's flag surface AND its `--help`.
fn command() -> Command {
    Command::new("diff")
        .about("Compare two files (or directories with -r) line by line.")
        .override_usage("diff [OPTION]... FILE1 FILE2\n       diff [OPTION]... -r DIR1 DIR2")
        .arg(Arg::new("unified").short('u').long("unified").action(ArgAction::SetTrue).help("unified format (the default), 3 lines of context"))
        .arg(Arg::new("unified-n").short('U').value_name("N").value_parser(clap::value_parser!(usize)).help("unified format with N lines of context"))
        .arg(Arg::new("context").short('c').long("context").action(ArgAction::SetTrue).help("context format"))
        .arg(Arg::new("context-n").short('C').value_name("N").value_parser(clap::value_parser!(usize)).help("context format with N lines of context"))
        .arg(Arg::new("recursive").short('r').visible_short_alias('R').long("recursive").action(ArgAction::SetTrue).help("recursively compare any subdirectories"))
        .arg(Arg::new("brief").short('q').long("brief").action(ArgAction::SetTrue).help("report only whether files differ, not the changes"))
        .arg(Arg::new("ignore-case").short('i').long("ignore-case").action(ArgAction::SetTrue).help("treat upper- and lower-case as equal"))
        .arg(Arg::new("ignore-all-space").short('w').long("ignore-all-space").action(ArgAction::SetTrue).help("ignore all white space"))
        .arg(Arg::new("ignore-blank-lines").short('B').long("ignore-blank-lines").action(ArgAction::SetTrue).help("ignore changes whose lines are all blank"))
        .arg(Arg::new("FILES").action(ArgAction::Append).help("the two files or directories to compare (- for standard input)"))
        .after_help("Use - for a FILE to read standard input. Backed by the Myers algorithm (the pure-Rust similar crate).")
}

/// `diff [OPTION]... FILE1 FILE2`. Exit: 0 identical, 1 differ, 2 error.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };
    let mut opts = Options::default();
    opts.unified = m.get_flag("unified");
    opts.context_fmt = m.get_flag("context");
    if let Some(n) = m.get_one::<usize>("unified-n") {
        opts.unified = true;
        opts.context_lines = *n;
    }
    if let Some(n) = m.get_one::<usize>("context-n") {
        opts.context_fmt = true;
        opts.context_lines = *n;
    }
    opts.recursive = m.get_flag("recursive");
    opts.brief = m.get_flag("brief");
    opts.ignore_case = m.get_flag("ignore-case");
    opts.ignore_whitespace = m.get_flag("ignore-all-space");
    opts.ignore_blank_lines = m.get_flag("ignore-blank-lines");

    let files: Vec<String> =
        m.get_many::<String>("FILES").map(|v| v.cloned().collect()).unwrap_or_default();
    if files.len() != 2 {
        eprintln!("diff: requires exactly two file or directory arguments");
        return 2;
    }

    let code = match diff_paths(Path::new(&files[0]), Path::new(&files[1]), &opts) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(e) => {
            eprintln!("diff: {e}");
            2
        }
    };
    let _ = io::stdout().flush();
    code
}

fn diff_paths(path_a: &Path, path_b: &Path, opts: &Options) -> Result<bool, String> {
    let a_is_dir = path_a.is_dir();
    let b_is_dir = path_b.is_dir();

    if a_is_dir && b_is_dir {
        if opts.recursive {
            diff_dirs(path_a, path_b, opts)
        } else {
            Err(format!("{} is a directory", path_a.display()))
        }
    } else if a_is_dir {
        let name = path_b.file_name().ok_or("invalid filename")?;
        diff_files(&path_a.join(name), path_b, opts)
    } else if b_is_dir {
        let name = path_a.file_name().ok_or("invalid filename")?;
        diff_files(path_a, &path_b.join(name), opts)
    } else {
        diff_files(path_a, path_b, opts)
    }
}

fn diff_dirs(dir_a: &Path, dir_b: &Path, opts: &Options) -> Result<bool, String> {
    let entries_a = list_dir(dir_a)?;
    let entries_b = list_dir(dir_b)?;
    let mut all_names: Vec<String> = entries_a.clone();
    for name in &entries_b {
        if !entries_a.contains(name) {
            all_names.push(name.clone());
        }
    }
    all_names.sort();

    let mut has_diff = false;
    for name in &all_names {
        let pa = dir_a.join(name);
        let pb = dir_b.join(name);
        let a_exists = entries_a.contains(name);
        let b_exists = entries_b.contains(name);
        if a_exists && !b_exists {
            println!("Only in {}: {}", dir_a.display(), name);
            has_diff = true;
        } else if !a_exists && b_exists {
            println!("Only in {}: {}", dir_b.display(), name);
            has_diff = true;
        } else {
            match diff_paths(&pa, &pb, opts) {
                Ok(d) => has_diff |= d,
                Err(e) => {
                    eprintln!("diff: {e}");
                    has_diff = true;
                }
            }
        }
    }
    Ok(has_diff)
}

fn list_dir(dir: &Path) -> Result<Vec<String>, String> {
    let entries = fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let mut names = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("{}: {e}", dir.display()))?;
        if let Some(name) = entry.file_name().to_str() {
            names.push(name.to_string());
        }
    }
    names.sort();
    Ok(names)
}

fn preprocess(text: &str, opts: &Options) -> String {
    let mut s = text.to_string();
    if opts.ignore_blank_lines {
        let trailing = s.ends_with('\n');
        s = s.lines().filter(|line| !line.trim().is_empty()).collect::<Vec<_>>().join("\n");
        if trailing {
            s.push('\n');
        }
    }
    if opts.ignore_case {
        s = s.to_lowercase();
    }
    if opts.ignore_whitespace {
        let trailing = s.ends_with('\n');
        s = s
            .lines()
            .map(|line| {
                let mut result = String::new();
                let mut in_ws = false;
                for ch in line.chars() {
                    if ch.is_whitespace() {
                        if !in_ws {
                            result.push(' ');
                            in_ws = true;
                        }
                    } else {
                        result.push(ch);
                        in_ws = false;
                    }
                }
                result.trim().to_string()
            })
            .collect::<Vec<_>>()
            .join("\n");
        if trailing {
            s.push('\n');
        }
    }
    s
}

fn diff_files(path_a: &Path, path_b: &Path, opts: &Options) -> Result<bool, String> {
    let text_a = read_file(path_a)?;
    let text_b = read_file(path_b)?;

    let needs_pp = opts.ignore_case || opts.ignore_whitespace || opts.ignore_blank_lines;
    let has_changes = if needs_pp {
        preprocess(&text_a, opts) != preprocess(&text_b, opts)
    } else {
        text_a != text_b
    };
    if !has_changes {
        return Ok(false);
    }
    if opts.brief {
        println!("Files {} and {} differ", path_a.display(), path_b.display());
        return Ok(true);
    }

    let diff = TextDiff::from_lines(&text_a, &text_b);
    let label_a = format!("{}", path_a.display());
    let label_b = format!("{}", path_b.display());
    let stdout = io::stdout();
    let mut out = stdout.lock();

    if opts.unified {
        let _ = writeln!(out, "--- {label_a}");
        let _ = writeln!(out, "+++ {label_b}");
        for hunk in diff.unified_diff().context_radius(opts.context_lines).iter_hunks() {
            let _ = write!(out, "{hunk}");
        }
    } else if opts.context_fmt {
        let _ = writeln!(out, "*** {label_a}");
        let _ = writeln!(out, "--- {label_b}");
        for hunk in diff.unified_diff().context_radius(opts.context_lines).iter_hunks() {
            let mut old_lines: Vec<(ChangeTag, String)> = Vec::new();
            let mut new_lines: Vec<(ChangeTag, String)> = Vec::new();
            let mut old_start = 0usize;
            let mut new_start = 0usize;
            let mut first = true;
            for change in hunk.iter_changes() {
                if first {
                    old_start = change.old_index().unwrap_or(0) + 1;
                    new_start = change.new_index().unwrap_or(0) + 1;
                    first = false;
                }
                match change.tag() {
                    ChangeTag::Equal => {
                        old_lines.push((ChangeTag::Equal, change.value().to_string()));
                        new_lines.push((ChangeTag::Equal, change.value().to_string()));
                    }
                    ChangeTag::Delete => old_lines.push((ChangeTag::Delete, change.value().to_string())),
                    ChangeTag::Insert => new_lines.push((ChangeTag::Insert, change.value().to_string())),
                }
            }
            let old_end = old_start + old_lines.len().saturating_sub(1);
            let new_end = new_start + new_lines.len().saturating_sub(1);
            let _ = writeln!(out, "***************");
            let _ = writeln!(out, "*** {old_start},{old_end} ****");
            for (tag, line) in &old_lines {
                let prefix = match tag {
                    ChangeTag::Delete => "- ",
                    ChangeTag::Equal => "  ",
                    _ => continue,
                };
                let _ = write!(out, "{prefix}{line}");
                if !line.ends_with('\n') {
                    let _ = writeln!(out);
                }
            }
            let _ = writeln!(out, "--- {new_start},{new_end} ----");
            for (tag, line) in &new_lines {
                let prefix = match tag {
                    ChangeTag::Insert => "+ ",
                    ChangeTag::Equal => "  ",
                    _ => continue,
                };
                let _ = write!(out, "{prefix}{line}");
                if !line.ends_with('\n') {
                    let _ = writeln!(out);
                }
            }
        }
    } else {
        // Normal diff format.
        let old_text: String = diff.old_slices().concat();
        let new_text: String = diff.new_slices().concat();
        let old_lines: Vec<&str> = old_text.lines().collect();
        let new_lines: Vec<&str> = new_text.lines().collect();
        for op in diff.ops() {
            match op {
                DiffOp::Equal { .. } => {}
                DiffOp::Delete { old_index, old_len, new_index } => {
                    let _ = writeln!(out, "{}d{}", format_range(*old_index + 1, *old_len), new_index);
                    for l in old_lines.iter().skip(*old_index).take(*old_len) {
                        let _ = writeln!(out, "< {l}");
                    }
                }
                DiffOp::Insert { old_index, new_index, new_len } => {
                    let _ = writeln!(out, "{}a{}", old_index, format_range(*new_index + 1, *new_len));
                    for l in new_lines.iter().skip(*new_index).take(*new_len) {
                        let _ = writeln!(out, "> {l}");
                    }
                }
                DiffOp::Replace { old_index, old_len, new_index, new_len } => {
                    let _ = writeln!(
                        out,
                        "{}c{}",
                        format_range(*old_index + 1, *old_len),
                        format_range(*new_index + 1, *new_len)
                    );
                    for l in old_lines.iter().skip(*old_index).take(*old_len) {
                        let _ = writeln!(out, "< {l}");
                    }
                    let _ = writeln!(out, "---");
                    for l in new_lines.iter().skip(*new_index).take(*new_len) {
                        let _ = writeln!(out, "> {l}");
                    }
                }
            }
        }
    }
    Ok(true)
}

fn read_file(path: &Path) -> Result<String, String> {
    if path.to_str() == Some("-") {
        use std::io::Read;
        let mut buf = String::new();
        io::stdin().read_to_string(&mut buf).map_err(|e| format!("stdin: {e}"))?;
        Ok(buf)
    } else {
        fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
    }
}

fn format_range(start: usize, len: usize) -> String {
    if len == 1 {
        format!("{start}")
    } else {
        format!("{},{}", start, start + len - 1)
    }
}
