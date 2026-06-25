//! `zip` — create or update a `.zip` (the external-crate `zip` crate, SYSTEMS.md). A clap CLI;
//! compression Deflate (default) or Store (`-0`); add/update/delete is a full rewrite (read the old
//! central directory, merge, write a fresh archive). std I/O → the WASI→mc adapter; the writer
//! back-patches the central directory via Seek (adapter `fd_seek`).
//!
//! Deviations from Info-ZIP (inherited from the memcontainers port): no -e encryption, -s split,
//! -@ names-from-stdin, -T test, -y symlinks. `-x PATTERN` is repeatable (clap-native); the
//! Info-ZIP "everything after -x" form takes its patterns greedily. Read-write. Ported from
//! memcontainers' `wasi::zip`.

use std::fs;
use std::io::{self, Read, Write};
use std::path::Path;

use clap::{Arg, ArgAction, Command};
use zip::write::FileOptions;
use zip::CompressionMethod;

struct Opts {
    recurse: bool,
    junk: bool,
    move_: bool,
    delete: bool,
    update: bool,
    quiet: bool,
    level: Option<i32>, // None = default deflate; Some(0) = store; 1..9 = deflate level
    exclude: Vec<String>,
    archive: String,
    inputs: Vec<String>,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            recurse: false,
            junk: false,
            move_: false,
            delete: false,
            update: false,
            quiet: false,
            level: None,
            exclude: Vec::new(),
            archive: String::new(),
            inputs: Vec::new(),
        }
    }
}

/// Static ids for the `-0..-9` level digit args (clap's `Arg::new` needs a static id, not a
/// `format!` String).
const LEVEL_IDS: [&str; 10] = ["l0", "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9"];

/// The clap command — zip's flag surface AND its `--help`. The `-0..-9` level digits are hidden so
/// a cluster like `-rj9` parses.
fn command() -> Command {
    let mut cmd = Command::new("zip")
        .about("Create or update a ZIP archive (the pure-Rust zip crate).")
        .override_usage("zip [OPTION]... ARCHIVE FILE... [-x PATTERN...]")
        .arg(Arg::new("recurse").short('r').visible_short_alias('R').action(ArgAction::SetTrue).help("recurse into directories"))
        .arg(Arg::new("junk").short('j').action(ArgAction::SetTrue).help("junk paths: store just the file name, not its directory"))
        .arg(Arg::new("move").short('m').action(ArgAction::SetTrue).help("move: delete the source files after archiving them"))
        .arg(Arg::new("delete").short('d').action(ArgAction::SetTrue).help("delete the named entries from ARCHIVE"))
        .arg(Arg::new("update").short('u').action(ArgAction::SetTrue).help("update: add new files and replace changed ones"))
        .arg(Arg::new("quiet").short('q').action(ArgAction::SetTrue).help("quiet"))
        .arg(Arg::new("exclude").short('x').value_name("PATTERN").action(ArgAction::Append).num_args(1..).help("exclude files matching PATTERN (a * / ? glob)"))
        .arg(Arg::new("OPERANDS").action(ArgAction::Append).help("the ARCHIVE (first) then the input FILEs"))
        .after_help("-0 stores (no compression); -1 .. -9 set the deflate level (1 = fastest, 9 = best). Backed by the pure-Rust zip crate.");
    for d in 0..=9u8 {
        cmd = cmd.arg(
            Arg::new(LEVEL_IDS[d as usize]).short((b'0' + d) as char).action(ArgAction::SetTrue).hide(true),
        );
    }
    cmd
}

/// `zip [OPTION]... ARCHIVE FILE...`. Exit: 0 success, 1 an I/O failure, 2 a usage error.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let mut o = Opts::default();
    o.recurse = m.get_flag("recurse");
    o.junk = m.get_flag("junk");
    o.move_ = m.get_flag("move");
    o.delete = m.get_flag("delete");
    o.update = m.get_flag("update");
    o.quiet = m.get_flag("quiet");
    for d in 0..=9u8 {
        if m.get_flag(LEVEL_IDS[d as usize]) {
            o.level = Some(d as i32);
        }
    }
    o.exclude = m.get_many::<String>("exclude").map(|v| v.cloned().collect()).unwrap_or_default();
    let operands: Vec<String> =
        m.get_many::<String>("OPERANDS").map(|v| v.cloned().collect()).unwrap_or_default();
    if operands.is_empty() {
        eprintln!("usage: zip [-rjmduq0-9] [-x PATTERN...] ARCHIVE FILE...");
        return 2;
    }
    o.archive = operands[0].clone();
    o.inputs = operands[1..].to_vec();
    let _ = o.update; // update is treated as add/replace, which the merge already does

    match run(&o) {
        Ok(false) => 0,
        Ok(true) => 1,
        Err(e) => {
            eprintln!("zip: {e}");
            1
        }
    }
}

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

struct Entry {
    name: String,
    data: Vec<u8>,
    is_dir: bool,
}

/// Read every member of an existing archive into memory (preserving order), so we can rewrite a
/// fresh archive with merges/deletions applied.
fn load_existing(path: &str) -> io::Result<Vec<Entry>> {
    if fs::metadata(path).is_err() {
        return Ok(Vec::new());
    }
    let f = fs::File::open(path)?;
    let mut za = match zip::ZipArchive::new(f) {
        Ok(z) => z,
        Err(_) => return Ok(Vec::new()), // not a zip yet / empty — start fresh
    };
    let mut out = Vec::new();
    for i in 0..za.len() {
        let mut zf = za
            .by_index(i)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("{e}")))?;
        let name = zf.name().to_string();
        let is_dir = name.ends_with('/');
        let mut data = Vec::new();
        if !is_dir {
            zf.read_to_end(&mut data)?;
        }
        out.push(Entry { name, data, is_dir });
    }
    Ok(out)
}

fn upsert(entries: &mut Vec<Entry>, e: Entry) {
    if let Some(slot) = entries.iter_mut().find(|x| x.name == e.name) {
        *slot = e;
    } else {
        entries.push(e);
    }
}

fn archive_name(path: &str, junk: bool) -> String {
    let p = path.trim_start_matches("./").replace('\\', "/");
    if junk {
        Path::new(&p).file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or(p)
    } else {
        p
    }
}

fn run(o: &Opts) -> io::Result<bool> {
    let mut entries = load_existing(&o.archive)?;
    let mut had_error = false;
    let mut to_remove: Vec<String> = Vec::new();

    if o.delete {
        let before = entries.len();
        entries.retain(|e| !o.inputs.iter().any(|pat| glob_match(pat.as_bytes(), e.name.as_bytes())));
        if !o.quiet {
            eprintln!("zip: deleted {} entr(ies)", before - entries.len());
        }
    } else {
        for input in &o.inputs {
            let meta = match fs::symlink_metadata(input) {
                Ok(m) => m,
                Err(e) => {
                    eprintln!("zip: {input}: {e}");
                    had_error = true;
                    continue;
                }
            };
            if meta.is_dir() {
                if !o.recurse {
                    add_dir_entry(&mut entries, input, o);
                    continue;
                }
                for ent in walkdir::WalkDir::new(input).into_iter().flatten() {
                    let path = ent.path().to_string_lossy().into_owned();
                    if o.exclude.iter().any(|x| glob_match(x.as_bytes(), path.as_bytes())) {
                        continue;
                    }
                    if ent.file_type().is_dir() {
                        add_dir_entry(&mut entries, &path, o);
                    } else if ent.file_type().is_file() {
                        add_file_entry(&mut entries, &path, o, &mut had_error, &mut to_remove);
                    }
                }
            } else {
                if o.exclude.iter().any(|x| glob_match(x.as_bytes(), input.as_bytes())) {
                    continue;
                }
                add_file_entry(&mut entries, input, o, &mut had_error, &mut to_remove);
            }
        }
    }

    // Rewrite the archive from the merged entry set.
    let method = if o.level == Some(0) { CompressionMethod::Stored } else { CompressionMethod::Deflated };
    let mut fopts = FileOptions::default().compression_method(method);
    if let Some(l) = o.level {
        if l > 0 {
            fopts = fopts.compression_level(Some(l));
        }
    }

    let file = fs::File::create(&o.archive)?;
    let mut zw = zip::ZipWriter::new(file);
    for e in &entries {
        if e.is_dir {
            zw.add_directory(&e.name, fopts)
                .map_err(|err| io::Error::new(io::ErrorKind::Other, format!("{err}")))?;
        } else {
            zw.start_file(&e.name, fopts)
                .map_err(|err| io::Error::new(io::ErrorKind::Other, format!("{err}")))?;
            zw.write_all(&e.data)?;
        }
    }
    zw.finish().map_err(|err| io::Error::new(io::ErrorKind::Other, format!("{err}")))?;

    if o.move_ {
        for src in &to_remove {
            let _ = fs::remove_file(src);
        }
    }
    Ok(had_error)
}

fn add_dir_entry(entries: &mut Vec<Entry>, path: &str, o: &Opts) {
    if o.junk {
        return; // junked dirs collapse away
    }
    let mut name = archive_name(path, false);
    if !name.ends_with('/') {
        name.push('/');
    }
    upsert(entries, Entry { name, data: Vec::new(), is_dir: true });
}

fn add_file_entry(entries: &mut Vec<Entry>, path: &str, o: &Opts, had_error: &mut bool, to_remove: &mut Vec<String>) {
    match fs::read(path) {
        Ok(data) => {
            let name = archive_name(path, o.junk);
            if !o.quiet {
                println!("  adding: {name}");
            }
            upsert(entries, Entry { name, data, is_dir: false });
            to_remove.push(path.to_string());
        }
        Err(e) => {
            eprintln!("zip: {path}: {e}");
            *had_error = true;
        }
    }
}
