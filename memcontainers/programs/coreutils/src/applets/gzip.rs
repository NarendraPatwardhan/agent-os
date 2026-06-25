//! `gzip` — DEFLATE (de)compression (the external-crate `flate2`/miniz_oxide backend, VISION
//! §16.3). A clap CLI; compress turns `foo` into `foo.gz` and removes `foo`, `-d` does the inverse,
//! `-c` streams to stdout, `-l`/`-t` list/test. std I/O → the WASI→mc adapter (no mmap on wasip1).
//!
//! Deviations from GNU gzip (inherited from the memcontainers port): -n/-N (no-name/name) are
//! accepted but no-ops (the original name+timestamp are never stored/restored); no --rsyncable /
//! --synchronous. Read-write (writes/removes files). Ported from memcontainers' `wasi::gzip`.

use std::fs;
use std::io::{self, Read, Write};

use clap::{Arg, ArgAction, Command};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;

#[derive(Clone)]
struct Opts {
    decompress: bool,
    keep: bool,
    stdout: bool,
    force: bool,
    level: u32,
    recursive: bool,
    list: bool,
    test: bool,
    quiet: bool,
    verbose: bool,
    suffix: String,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            decompress: false,
            keep: false,
            stdout: false,
            force: false,
            level: 6,
            recursive: false,
            list: false,
            test: false,
            quiet: false,
            verbose: false,
            suffix: ".gz".to_string(),
        }
    }
}

/// Static ids for the `-0..-9` level digit args (clap's `Arg::new` needs a static id, not a
/// `format!` String).
const LEVEL_IDS: [&str; 10] = ["l0", "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9"];

/// The clap command — gzip's flag surface AND its `--help`. The `-1..-9` level digits are hidden
/// args so a cluster like `-dk9` parses (clap splits it into -d -k -9).
fn command() -> Command {
    let mut cmd = Command::new("gzip")
        .about("Compress or decompress files with gzip (flate2/miniz_oxide backend).")
        .override_usage("gzip [OPTION]... [FILE]...")
        .version("gzip (agent-os) — flate2/miniz_oxide")
        .disable_version_flag(true)
        .arg(Arg::new("version").short('V').long("version").action(ArgAction::Version).help("print version and exit"))
        .arg(Arg::new("decompress").short('d').long("decompress").visible_alias("uncompress").action(ArgAction::SetTrue).help("decompress instead of compress"))
        .arg(Arg::new("stdout").short('c').long("stdout").visible_alias("to-stdout").action(ArgAction::SetTrue).help("write to standard output; keep the original files"))
        .arg(Arg::new("keep").short('k').long("keep").action(ArgAction::SetTrue).help("keep (do not delete) the input files"))
        .arg(Arg::new("force").short('f').long("force").action(ArgAction::SetTrue).help("force overwrite of output and compress non-.gz input"))
        .arg(Arg::new("recursive").short('r').long("recursive").action(ArgAction::SetTrue).help("operate recursively on directories"))
        .arg(Arg::new("list").short('l').long("list").action(ArgAction::SetTrue).help("list the contents/sizes of compressed files"))
        .arg(Arg::new("test").short('t').long("test").action(ArgAction::SetTrue).help("test the integrity of compressed files"))
        .arg(Arg::new("quiet").short('q').long("quiet").action(ArgAction::SetTrue).help("suppress warnings"))
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::SetTrue).help("be verbose"))
        .arg(Arg::new("suffix").short('S').long("suffix").value_name("SUF").help("use suffix SUF on compressed files (default .gz)"))
        .arg(Arg::new("fast").long("fast").action(ArgAction::SetTrue).help("compress faster (level 1)"))
        .arg(Arg::new("best").long("best").action(ArgAction::SetTrue).help("compress better (level 9)"))
        .arg(Arg::new("no-name").short('n').long("no-name").action(ArgAction::SetTrue).hide(true))
        .arg(Arg::new("name-opt").short('N').long("name").action(ArgAction::SetTrue).hide(true))
        .arg(Arg::new("FILE").action(ArgAction::Append).help("files to (de)compress (- or none for stdin→stdout)"))
        .after_help(
            "-1 .. -9 set the compression level (1 = fastest, 9 = best; default 6). With no FILE,\n\
             or when FILE is -, read standard input and write standard output. Otherwise each FILE\n\
             becomes FILE.gz (or is restored from FILE.gz with -d).",
        );
    for d in 1..=9u8 {
        cmd = cmd.arg(
            Arg::new(LEVEL_IDS[d as usize]).short((b'0' + d) as char).action(ArgAction::SetTrue).hide(true),
        );
    }
    cmd
}

/// `gzip [OPTION]... [FILE]...`. Exit: 0 success, 1 a warning, 2 a usage error.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let mut o = Opts::default();
    o.decompress = m.get_flag("decompress");
    o.keep = m.get_flag("keep");
    o.stdout = m.get_flag("stdout");
    o.force = m.get_flag("force");
    o.recursive = m.get_flag("recursive");
    o.list = m.get_flag("list");
    o.test = m.get_flag("test");
    o.quiet = m.get_flag("quiet");
    o.verbose = m.get_flag("verbose");
    if let Some(s) = m.get_one::<String>("suffix") {
        o.suffix = s.clone();
    }
    for d in 1..=9u8 {
        if m.get_flag(LEVEL_IDS[d as usize]) {
            o.level = d as u32;
        }
    }
    if m.get_flag("fast") {
        o.level = 1;
    }
    if m.get_flag("best") {
        o.level = 9;
    }
    let _ = o.quiet; // accepted; warnings are already terse

    let files: Vec<String> =
        m.get_many::<String>("FILE").map(|v| v.cloned().collect()).unwrap_or_default();
    let mut had_error = false;

    // No operands → stream stdin to stdout (one logical "file").
    if files.is_empty() {
        if o.list {
            let mut buf = Vec::new();
            if io::stdin().read_to_end(&mut buf).is_err() {
                eprintln!("gzip: stdin: read error");
                return 1;
            }
            print_list_header();
            if list_one("stdin", &buf).is_err() {
                had_error = true;
            }
            return code(had_error);
        }
        if process_stream(&o).is_err() {
            had_error = true;
        }
        return code(had_error);
    }

    let targets: Vec<String> = if o.recursive {
        let mut t = Vec::new();
        for f in &files {
            collect_recursive(f, &mut t);
        }
        t
    } else {
        files
    };

    if o.list {
        print_list_header();
        for path in &targets {
            match fs::read(path) {
                Ok(data) => {
                    if list_one(path, &data).is_err() {
                        had_error = true;
                    }
                }
                Err(e) => {
                    eprintln!("gzip: {path}: {e}");
                    had_error = true;
                }
            }
        }
        return code(had_error);
    }

    for path in &targets {
        if let Err(e) = process_file(&o, path) {
            eprintln!("gzip: {path}: {e}");
            had_error = true;
        }
    }
    code(had_error)
}

fn code(had_error: bool) -> i32 {
    if had_error {
        1
    } else {
        0
    }
}

/// Expand a `-r` operand: a directory yields every regular file beneath it; a non-directory is
/// taken verbatim.
fn collect_recursive(path: &str, out: &mut Vec<String>) {
    match fs::metadata(path) {
        Ok(m) if m.is_dir() => match fs::read_dir(path) {
            Ok(rd) => {
                for ent in rd.flatten() {
                    let child = ent.path().to_string_lossy().into_owned();
                    collect_recursive(&child, out);
                }
            }
            Err(e) => eprintln!("gzip: {path}: {e}"),
        },
        _ => out.push(path.to_string()),
    }
}

/// stdin → stdout (compress, or decompress with `-d`).
fn process_stream(o: &Opts) -> io::Result<()> {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();
    if o.test {
        let mut dec = GzDecoder::new(stdin.lock());
        io::copy(&mut dec, &mut io::sink())?;
        return Ok(());
    }
    if o.decompress {
        let mut dec = GzDecoder::new(stdin.lock());
        io::copy(&mut dec, &mut out)?;
    } else {
        let mut enc = GzEncoder::new(&mut out, Compression::new(o.level));
        io::copy(&mut stdin.lock(), &mut enc)?;
        enc.finish()?;
    }
    out.flush()
}

/// Process one named file. Honors `-c`, `-t`, `-k`, suffix handling, and the `-f` overwrite guard.
fn process_file(o: &Opts, path: &str) -> io::Result<()> {
    if o.test {
        let f = fs::File::open(path)?;
        let mut dec = GzDecoder::new(f);
        io::copy(&mut dec, &mut io::sink())?;
        if o.verbose {
            eprintln!("gzip: {path}: OK");
        }
        return Ok(());
    }

    if o.stdout {
        let stdout = io::stdout();
        let mut out = stdout.lock();
        let f = fs::File::open(path)?;
        if o.decompress {
            let mut dec = GzDecoder::new(f);
            io::copy(&mut dec, &mut out)?;
        } else {
            let mut enc = GzEncoder::new(&mut out, Compression::new(o.level));
            io::copy(&mut io::BufReader::new(f), &mut enc)?;
            enc.finish()?;
        }
        return out.flush();
    }

    let out_path = if o.decompress {
        match path.strip_suffix(&o.suffix) {
            Some(stem) if !stem.is_empty() => stem.to_string(),
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown suffix (expected {})", o.suffix),
                ));
            }
        }
    } else {
        if path.ends_with(&o.suffix) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("already has {} suffix -- unchanged", o.suffix),
            ));
        }
        format!("{path}{}", o.suffix)
    };

    if fs::metadata(&out_path).is_ok() && !o.force {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("{out_path} already exists; use -f to overwrite"),
        ));
    }

    let f = fs::File::open(path)?;
    let out = fs::File::create(&out_path)?;
    if o.decompress {
        let mut dec = GzDecoder::new(io::BufReader::new(f));
        let mut w = io::BufWriter::new(out);
        io::copy(&mut dec, &mut w)?;
        w.flush()?;
    } else {
        let mut enc = GzEncoder::new(io::BufWriter::new(out), Compression::new(o.level));
        io::copy(&mut io::BufReader::new(f), &mut enc)?;
        enc.finish()?.flush()?;
    }

    if o.verbose {
        eprintln!("gzip: {path} -> {out_path}");
    }
    if !o.keep {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn print_list_header() {
    println!("{:>12} {:>12} {:>6} {}", "compressed", "uncompressed", "ratio", "name");
}

/// `-l` for one gzip member: compressed = file size, uncompressed = the gzip trailer's ISIZE.
fn list_one(name: &str, data: &[u8]) -> io::Result<()> {
    if data.len() < 18 || data[0] != 0x1f || data[1] != 0x8b {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not in gzip format"));
    }
    let comp = data.len() as u64;
    let isize_le = &data[data.len() - 4..];
    let uncomp = u32::from_le_bytes([isize_le[0], isize_le[1], isize_le[2], isize_le[3]]) as u64;
    let ratio = if uncomp > 0 { 100.0 * (1.0 - (comp as f64) / (uncomp as f64)) } else { 0.0 };
    let shown = name.strip_suffix(".gz").unwrap_or(name);
    println!("{comp:>12} {uncomp:>12} {ratio:>5.1}% {shown}");
    Ok(())
}
