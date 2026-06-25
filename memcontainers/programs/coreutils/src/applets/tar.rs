//! `tar` — create, list, and extract tar archives (the external-crate `tar` crate, SYSTEMS.md).
//! A clap CLI; modes `-c`/`-x`/`-t`, compression `-z` (gzip, both ways) and `-j`/`-J` (bzip2/xz,
//! DECOMPRESS-ONLY — no viable pure-Rust encoder). Extract honors `-C`, `-O`, `-k`,
//! `--strip-components`, `--exclude`. std I/O → the WASI→mc adapter (no mmap on wasip1).
//!
//! Deviations (inherited from the memcontainers port): -h is help (not GNU's --dereference);
//! bzip2/xz are decompress-only; -p/-m are no-ops (no metadata model — owner/perms/mtime are not
//! restored); links are skipped on wasi; no -A/--delete/-W. The old form `tar cf a.tar ...` is
//! accepted (a pre-pass dashes it for clap). Read-write. Ported from memcontainers' `wasi::tar`.

use std::ffi::OsString;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

use clap::{Arg, ArgAction, Command};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use tar::{Builder, EntryType, Header};

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    None,
    Create,
    Extract,
    List,
    Append,
}

#[derive(Clone, Copy, PartialEq)]
enum Comp {
    None,
    Gzip,
    Bzip2,
    Xz,
}

struct Opts {
    mode: Mode,
    comp: Comp,
    archive: String, // "-" = stdio
    cdir: String,    // -C (default ".")
    files: Vec<String>,
    verbose: bool,
    to_stdout: bool, // -O
    keep_old: bool,  // -k
    strip: usize,    // --strip-components
    exclude: Vec<String>,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            mode: Mode::None,
            comp: Comp::None,
            archive: "-".to_string(),
            cdir: ".".to_string(),
            files: Vec::new(),
            verbose: false,
            to_stdout: false,
            keep_old: false,
            strip: 0,
            exclude: Vec::new(),
        }
    }
}

/// All single-letter flags `tar` understands — used to detect the old bare-cluster form
/// `tar cf a.tar ...` (a first operand that is entirely flag letters).
fn is_flag_letter(c: char) -> bool {
    matches!(
        c,
        'c' | 'x' | 't' | 'r' | 'u' | 'z' | 'j' | 'J' | 'v' | 'p' | 'm' | 'k' | 'O' | 'f' | 'C'
    )
}

/// The clap command — tar's flag surface AND its `--help`.
fn command() -> Command {
    Command::new("tar")
        .about("Create, list, and extract tar archives (the pure-Rust tar crate).")
        .override_usage("tar -c|-x|-t [-zjJvpmkO] [-f ARCHIVE] [-C DIR] [FILE]...")
        .arg(Arg::new("create").short('c').long("create").action(ArgAction::SetTrue).help("create a new archive from FILEs"))
        .arg(Arg::new("extract").short('x').long("extract").visible_alias("get").action(ArgAction::SetTrue).help("extract files from an archive"))
        .arg(Arg::new("list").short('t').long("list").action(ArgAction::SetTrue).help("list the contents of an archive"))
        .arg(Arg::new("append").short('r').visible_short_alias('u').long("append").action(ArgAction::SetTrue).help("append FILEs to the end of an archive (unsupported in this build)"))
        .arg(Arg::new("file").short('f').long("file").value_name("ARCHIVE").help("use ARCHIVE instead of stdin/stdout"))
        .arg(Arg::new("directory").short('C').long("directory").value_name("DIR").help("change to DIR before processing"))
        .arg(Arg::new("gzip").short('z').long("gzip").action(ArgAction::SetTrue).help("filter the archive through gzip"))
        .arg(Arg::new("bzip2").short('j').long("bzip2").action(ArgAction::SetTrue).help("filter through bzip2 (decompress only)"))
        .arg(Arg::new("xz").short('J').long("xz").action(ArgAction::SetTrue).help("filter through xz (decompress only)"))
        .arg(Arg::new("verbose").short('v').long("verbose").action(ArgAction::SetTrue).help("list each file as it is processed"))
        .arg(Arg::new("keep-old").short('k').long("keep-old-files").action(ArgAction::SetTrue).help("keep existing files; do not overwrite"))
        .arg(Arg::new("to-stdout").short('O').long("to-stdout").action(ArgAction::SetTrue).help("extract files to standard output"))
        .arg(Arg::new("preserve").short('p').long("preserve-permissions").visible_alias("same-permissions").action(ArgAction::SetTrue).hide(true))
        .arg(Arg::new("touch").short('m').long("touch").action(ArgAction::SetTrue).hide(true))
        .arg(Arg::new("strip-components").long("strip-components").value_name("N").value_parser(clap::value_parser!(usize)).help("strip N leading path components on extract"))
        .arg(Arg::new("exclude").long("exclude").value_name("PATTERN").action(ArgAction::Append).help("skip files matching PATTERN (a * / ? glob over the path)"))
        .arg(Arg::new("FILE").action(ArgAction::Append).help("files to archive (with -c), else operands"))
        .after_help(
            "-h is help here, not GNU tar's --dereference. bzip2/xz are decompress-only; create\n\
             supports no compression or -z (gzip). -p/-m are no-ops. The old form `tar cf a.tar ...`\n\
             (no leading dash) is also accepted.",
        )
}

/// `tar -c|-x|-t [OPTION]... [FILE]...`. Exit: 0 success, 2 a usage error or an I/O failure.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let mut argv: Vec<OsString> = args.collect();
    // Old bare-cluster form `tar cf a.tar`: if the first operand is entirely tar flag-letters and
    // has no leading dash, rewrite it to `-cf` so clap can parse it.
    if argv.len() > 1 {
        let s = argv[1].to_string_lossy();
        if !s.is_empty() && !s.starts_with('-') && s.chars().all(is_flag_letter) {
            argv[1] = OsString::from(format!("-{s}"));
        }
    }

    let m = match command().try_get_matches_from(argv) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let mut o = Opts::default();
    if m.get_flag("create") {
        o.mode = Mode::Create;
    }
    if m.get_flag("extract") {
        o.mode = Mode::Extract;
    }
    if m.get_flag("list") {
        o.mode = Mode::List;
    }
    if m.get_flag("append") {
        o.mode = Mode::Append;
    }
    if m.get_flag("gzip") {
        o.comp = Comp::Gzip;
    }
    if m.get_flag("bzip2") {
        o.comp = Comp::Bzip2;
    }
    if m.get_flag("xz") {
        o.comp = Comp::Xz;
    }
    o.verbose = m.get_flag("verbose");
    o.to_stdout = m.get_flag("to-stdout");
    o.keep_old = m.get_flag("keep-old");
    if let Some(f) = m.get_one::<String>("file") {
        o.archive = f.clone();
    }
    if let Some(c) = m.get_one::<String>("directory") {
        o.cdir = c.clone();
    }
    if let Some(n) = m.get_one::<usize>("strip-components") {
        o.strip = *n;
    }
    o.exclude = m.get_many::<String>("exclude").map(|v| v.cloned().collect()).unwrap_or_default();
    o.files = m.get_many::<String>("FILE").map(|v| v.cloned().collect()).unwrap_or_default();

    let result = match o.mode {
        Mode::Create => create(&o),
        Mode::Extract => extract(&o),
        Mode::List => list(&o),
        Mode::Append => Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "append/update (-r/-u) is not supported in this build",
        )),
        Mode::None => {
            eprintln!("tar: you must choose one of -c, -x, or -t");
            return 2;
        }
    };
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("tar: {e}");
            2
        }
    }
}

/// Simple `*`/`?` glob over the whole path string (for `--exclude`).
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

/// Drop the first `n` normal path components; `None` if there are fewer (skip).
fn strip_components(path: &Path, n: usize) -> Option<PathBuf> {
    if n == 0 {
        return Some(path.to_path_buf());
    }
    let comps: Vec<Component> =
        path.components().filter(|c| matches!(c, Component::Normal(_))).collect();
    if comps.len() <= n {
        return None;
    }
    Some(comps[n..].iter().collect())
}

fn fill(r: &mut dyn Read, buf: &mut [u8]) -> usize {
    let mut got = 0;
    while got < buf.len() {
        match r.read(&mut buf[got..]) {
            Ok(0) => break,
            Ok(k) => got += k,
            Err(_) => break,
        }
    }
    got
}

/// Open the archive (file or stdin) and wrap it in the right decompressor; auto-detects
/// gzip/bzip2/xz by magic when no `-z/-j/-J` is given.
fn open_reader(o: &Opts) -> io::Result<Box<dyn Read>> {
    let wrap = |comp: Comp, raw: Box<dyn Read>| -> io::Result<Box<dyn Read>> {
        Ok(match comp {
            Comp::None => Box::new(io::BufReader::new(raw)),
            Comp::Gzip => Box::new(GzDecoder::new(raw)),
            Comp::Bzip2 => Box::new(bzip2_rs::DecoderReader::new(raw)),
            Comp::Xz => {
                let mut buf = Vec::new();
                lzma_rs::xz_decompress(&mut io::BufReader::new(raw), &mut buf)
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("xz: {e:?}")))?;
                Box::new(io::Cursor::new(buf))
            }
        })
    };

    if o.archive == "-" {
        return wrap(o.comp, Box::new(io::stdin()));
    }
    let mut f = fs::File::open(&o.archive)?;
    let mut magic = [0u8; 6];
    let n = fill(&mut f, &mut magic);
    let comp = if o.comp != Comp::None {
        o.comp
    } else if n >= 2 && magic[0] == 0x1f && magic[1] == 0x8b {
        Comp::Gzip
    } else if n >= 3 && &magic[..3] == b"BZh" {
        Comp::Bzip2
    } else if n >= 6 && magic[..6] == [0xfd, b'7', b'z', b'X', b'Z', 0x00] {
        Comp::Xz
    } else {
        Comp::None
    };
    let head = io::Cursor::new(magic[..n].to_vec());
    wrap(comp, Box::new(head.chain(f)))
}

fn create(o: &Opts) -> io::Result<()> {
    if matches!(o.comp, Comp::Bzip2 | Comp::Xz) {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "creating bzip2/xz archives is not supported (gzip only)",
        ));
    }
    let sink: Box<dyn Write> = if o.archive == "-" {
        Box::new(io::stdout())
    } else {
        Box::new(fs::File::create(&o.archive)?)
    };
    match o.comp {
        Comp::Gzip => {
            let enc = GzEncoder::new(sink, Compression::default());
            let mut b = Builder::new(enc);
            append_all(&mut b, o)?;
            b.finish()?;
            b.into_inner()?.finish()?;
        }
        _ => {
            let mut b = Builder::new(sink);
            append_all(&mut b, o)?;
            b.finish()?;
        }
    }
    Ok(())
}

fn append_all<W: Write>(b: &mut Builder<W>, o: &Opts) -> io::Result<()> {
    let base = Path::new(&o.cdir);
    for name in &o.files {
        let member = name.trim_start_matches('/');
        append_path(b, &base.join(name), if member.is_empty() { name } else { member }, o)?;
    }
    Ok(())
}

/// Append `src` to the archive under archive path `name`, recursing into directories. Headers are
/// built BY HAND because `tar`'s metadata-derived path is `unimplemented!()` on wasip1 (no unix
/// mode): files get 0o644, dirs 0o755, symlinks 0o777.
fn append_path<W: Write>(b: &mut Builder<W>, src: &Path, name: &str, o: &Opts) -> io::Result<()> {
    let meta = fs::symlink_metadata(src)?;
    let mtime = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let mut h = Header::new_gnu();
    h.set_mtime(mtime);
    h.set_uid(0);
    h.set_gid(0);

    if meta.is_dir() {
        let dir_name = if name.ends_with('/') { name.to_string() } else { format!("{name}/") };
        h.set_entry_type(EntryType::Directory);
        h.set_size(0);
        h.set_mode(0o755);
        b.append_data(&mut h, &dir_name, io::empty())?;
        if o.verbose {
            eprintln!("{dir_name}");
        }
        let mut children: Vec<_> = fs::read_dir(src)?.flatten().collect();
        children.sort_by_key(|e| e.file_name());
        for child in children {
            let cname =
                format!("{}/{}", name.trim_end_matches('/'), child.file_name().to_string_lossy());
            append_path(b, &child.path(), &cname, o)?;
        }
    } else if meta.file_type().is_symlink() {
        let target = fs::read_link(src)?;
        h.set_entry_type(EntryType::Symlink);
        h.set_size(0);
        h.set_mode(0o777);
        b.append_link(&mut h, name, &target)?;
        if o.verbose {
            eprintln!("{name}");
        }
    } else {
        let data = fs::read(src)?;
        h.set_entry_type(EntryType::Regular);
        h.set_size(data.len() as u64);
        h.set_mode(0o644);
        b.append_data(&mut h, name, data.as_slice())?;
        if o.verbose {
            eprintln!("{name}");
        }
    }
    Ok(())
}

fn extract(o: &Opts) -> io::Result<()> {
    let reader = open_reader(o)?;
    let mut ar = tar::Archive::new(reader);
    ar.set_preserve_permissions(false);
    ar.set_preserve_mtime(false);
    ar.set_unpack_xattrs(false);
    ar.set_overwrite(!o.keep_old);
    let base = Path::new(&o.cdir);
    let mut stdout = io::stdout();

    for entry in ar.entries()? {
        let mut entry = entry?;
        let raw_path = entry.path()?.into_owned();
        let raw_str = raw_path.to_string_lossy();
        if o.exclude.iter().any(|p| glob_match(p.as_bytes(), raw_str.as_bytes())) {
            continue;
        }
        let stripped = match strip_components(&raw_path, o.strip) {
            Some(p) if !p.as_os_str().is_empty() => p,
            _ => continue,
        };
        // Reject path-traversal in the (post-strip) entry path.
        if stripped.components().any(|c| matches!(c, Component::ParentDir | Component::RootDir)) {
            eprintln!("tar: skipping unsafe path: {}", stripped.display());
            continue;
        }
        let etype = entry.header().entry_type();

        if o.to_stdout {
            if etype.is_file() {
                io::copy(&mut entry, &mut stdout)?;
            }
            continue;
        }

        let dest = base.join(&stripped);
        if o.keep_old && fs::symlink_metadata(&dest).is_ok() {
            continue;
        }
        if o.verbose {
            eprintln!("{}", stripped.display());
        }
        if etype.is_dir() {
            fs::create_dir_all(&dest)?;
        } else if etype.is_file() || etype == EntryType::Continuous {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut f = fs::File::create(&dest)?;
            io::copy(&mut entry, &mut f)?;
        } else if etype.is_symlink() || etype.is_hard_link() {
            // wasip1's std has no portable link creation (tar's unpack path is unimplemented!()
            // there, which would abort the whole extraction), so links are skipped with a notice.
            eprintln!("tar: {}: skipping link (not supported on this platform)", stripped.display());
        }
    }
    Ok(())
}

fn list(o: &Opts) -> io::Result<()> {
    let reader = open_reader(o)?;
    let mut ar = tar::Archive::new(reader);
    for entry in ar.entries()? {
        let entry = entry?;
        println!("{}", entry.path()?.display());
    }
    Ok(())
}
