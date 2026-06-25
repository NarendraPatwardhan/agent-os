//! `unzip` — extract or list a `.zip` (the external-crate `zip` crate, SYSTEMS.md). A clap CLI;
//! the central directory at the file's end is read via the adapter's `fd_seek` (SEEK_END). Members
//! may be selected/excluded by shell glob. std I/O → the WASI→mc adapter.
//!
//! Deviations from Info-ZIP unzip (inherited from the memcontainers port): no interactive overwrite
//! prompt (no TTY) — `-o` (overwrite) is the default, `-n` opts out; no -P password, -a/-aa text
//! conversion, -C case-insensitive match, or -Z zipinfo mode. Read-write (the read-only `-l`/`-t`
//! are a subset). Ported from memcontainers' `wasi::unzip`.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use clap::{Arg, ArgAction, Command};

#[derive(Default)]
struct Opts {
    list: bool,
    verbose: bool,
    test: bool,
    never: bool, // -n
    junk: bool,  // -j
    pipe: bool,  // -p
    quiet: bool,
    dir: Option<String>, // -d
    archive: String,
    members: Vec<String>,
    excludes: Vec<String>,
}

/// The clap command — unzip's flag surface AND its `--help`.
fn command() -> Command {
    Command::new("unzip")
        .about("List, test, and extract from a ZIP archive (the pure-Rust zip crate).")
        .override_usage("unzip [OPTION]... ARCHIVE [MEMBER...] [-x PATTERN...]")
        .arg(Arg::new("list").short('l').action(ArgAction::SetTrue).help("list archive contents (short form)"))
        .arg(Arg::new("verbose").short('v').action(ArgAction::SetTrue).help("verbose listing (implies -l)"))
        .arg(Arg::new("test").short('t').action(ArgAction::SetTrue).help("test archive integrity without extracting"))
        .arg(Arg::new("overwrite").short('o').action(ArgAction::SetTrue).help("overwrite existing files without prompting (the default)"))
        .arg(Arg::new("never").short('n').action(ArgAction::SetTrue).help("never overwrite existing files"))
        .arg(Arg::new("junk").short('j').action(ArgAction::SetTrue).help("junk paths: extract all members into one directory"))
        .arg(Arg::new("pipe").short('p').action(ArgAction::SetTrue).help("extract to standard output (quietly)"))
        .arg(Arg::new("quiet").short('q').action(ArgAction::SetTrue).help("quiet"))
        .arg(Arg::new("dir").short('d').value_name("DIR").help("extract into DIR"))
        .arg(Arg::new("exclude").short('x').value_name("PATTERN").action(ArgAction::Append).num_args(1..).help("exclude members matching PATTERN (a * / ? glob)"))
        .arg(Arg::new("OPERANDS").action(ArgAction::Append).help("the ARCHIVE (first) then optional MEMBERs to extract"))
        .after_help("With MEMBER... only those archive members are processed. -o (overwrite) is the default (there is no TTY prompt); pass -n to refuse overwrites.")
}

/// `unzip [OPTION]... ARCHIVE [MEMBER...]`. Exit: 0 success, 1 an I/O failure, 2 a usage error.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let mut o = Opts::default();
    o.verbose = m.get_flag("verbose");
    o.list = m.get_flag("list") || o.verbose;
    o.test = m.get_flag("test");
    o.never = m.get_flag("never");
    o.junk = m.get_flag("junk");
    o.pipe = m.get_flag("pipe");
    o.quiet = m.get_flag("quiet") || o.pipe;
    if let Some(d) = m.get_one::<String>("dir") {
        o.dir = Some(d.clone());
    }
    o.excludes = m.get_many::<String>("exclude").map(|v| v.cloned().collect()).unwrap_or_default();
    let operands: Vec<String> =
        m.get_many::<String>("OPERANDS").map(|v| v.cloned().collect()).unwrap_or_default();
    if operands.is_empty() {
        eprintln!("usage: unzip [-lvtopnjq] [-d DIR] ARCHIVE [MEMBER...] [-x PATTERN...]");
        return 2;
    }
    o.archive = operands[0].clone();
    o.members = operands[1..].to_vec();

    match run(&o) {
        Ok(false) => 0,
        Ok(true) => 1,
        Err(e) => {
            eprintln!("unzip: {e}");
            1
        }
    }
}

/// Iterative `*`/`?` glob over the whole entry name.
fn glob_match(pat: &[u8], text: &[u8]) -> bool {
    let (mut p, mut t) = (0usize, 0usize);
    let (mut star, mut mark) = (None::<usize>, 0usize);
    while t < text.len() {
        if p < pat.len() && (pat[p] == b'?' || pat[p] == text[t]) {
            p += 1;
            t += 1;
        } else if p < pat.len() && pat[p] == b'*' {
            star = Some(p);
            mark = t;
            p += 1;
        } else if let Some(sp) = star {
            p = sp + 1;
            mark += 1;
            t = mark;
        } else {
            return false;
        }
    }
    while p < pat.len() && pat[p] == b'*' {
        p += 1;
    }
    p == pat.len()
}

fn wanted(name: &str, o: &Opts) -> bool {
    if !o.members.is_empty()
        && !o.members.iter().any(|m| glob_match(m.as_bytes(), name.as_bytes()))
    {
        return false;
    }
    if o.excludes.iter().any(|x| glob_match(x.as_bytes(), name.as_bytes())) {
        return false;
    }
    true
}

fn run(o: &Opts) -> io::Result<bool> {
    let f = fs::File::open(&o.archive)?;
    let mut za = zip::ZipArchive::new(f)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{e}")))?;

    let mut had_error = false;
    let base = Path::new(o.dir.as_deref().unwrap_or("."));

    if o.list {
        println!("Archive:  {}", o.archive);
        println!("  Length      Name");
        println!("---------  ----------------");
        let mut total: u64 = 0;
        let mut count = 0u64;
        for i in 0..za.len() {
            let zf = za
                .by_index(i)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{e}")))?;
            if !wanted(zf.name(), o) {
                continue;
            }
            println!("{:>9}  {}", zf.size(), zf.name());
            total += zf.size();
            count += 1;
        }
        println!("---------  ----------------");
        println!("{total:>9}  {count} file(s)");
        return Ok(false);
    }

    let mut stdout = io::stdout();
    for i in 0..za.len() {
        let mut zf = za
            .by_index(i)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{e}")))?;
        let name = zf.name().to_string();
        if !wanted(&name, o) {
            continue;
        }

        if o.test {
            match io::copy(&mut zf, &mut io::sink()) {
                Ok(_) => {
                    if !o.quiet {
                        println!("    testing: {name}   OK");
                    }
                }
                Err(e) => {
                    eprintln!("unzip: {name}: {e}");
                    had_error = true;
                }
            }
            continue;
        }

        if o.pipe {
            if !name.ends_with('/') {
                io::copy(&mut zf, &mut stdout)?;
            }
            continue;
        }

        // Sanitized relative path (rejects absolute / `..` traversal). Owned, so the borrow of zf
        // ends before we read its body.
        let rel: PathBuf = match zf.enclosed_name() {
            Some(p) => p.to_path_buf(),
            None => {
                eprintln!("unzip: skipping unsafe path: {name}");
                had_error = true;
                continue;
            }
        };

        if name.ends_with('/') {
            let dest = base.join(&rel);
            fs::create_dir_all(&dest)?;
            continue;
        }

        let dest = if o.junk {
            match rel.file_name() {
                Some(f) => base.join(f),
                None => continue,
            }
        } else {
            base.join(&rel)
        };

        if o.never && fs::symlink_metadata(&dest).is_ok() {
            if !o.quiet {
                println!("  skipping: {name} (exists)");
            }
            continue;
        }
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)?;
        }
        if !o.quiet {
            println!("  inflating: {}", dest.display());
        }
        let mut out = fs::File::create(&dest)?;
        io::copy(&mut zf, &mut out)?;
    }
    let _ = stdout.flush();
    Ok(had_error)
}
