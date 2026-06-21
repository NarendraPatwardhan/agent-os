//! `sort [OPTION]... [FILE]...` — sort lines of text from FILE(s) (or stdin) to stdout.
//!
//! Ordering: `-n`/`--numeric-sort` (leading numeric), `-g`/`--general-numeric-sort`
//! (general/float with exponent), `-h`/`--human-numeric-sort` (1024-suffix sizes like 2K,
//! 1G — NOT a help flag), `-V`/`--version-sort` (natural/version), or the default byte
//! order; `-f`/`--ignore-case` folds case, `-d`/`--dictionary-order` keeps only blanks and
//! alphanumerics, `-i`/`--ignore-nonprinting` drops non-printing bytes, `-b`/
//! `--ignore-leading-blanks` skips leading blanks, `-r`/`--reverse` reverses the result.
//! Keys: `-k`/`--key F1[.C1][opts][,F2[.C2][opts]]` (repeatable) selects sort keys, with
//! per-key ordering letters (`nghVfdirb`, and `M`/`R` accepted as default order); `-t`/
//! `--field-separator SEP` sets the field separator (else fields are blank-separated,
//! GNU-style). `-u`/`--unique` drops lines equal on the keys; `-s`/`--stable` is a stable
//! sort (disables the whole-line last-resort tie-break). `-o`/`--output FILE` writes to a
//! file; `-c`/`--check` and `-C`/`--check-silent` only check whether the input is sorted;
//! `-m`/`--merge` merges already-sorted inputs. `-S`/`--buffer-size SIZE` sets the in-memory
//! batch budget (default 1 MiB; accepts a `k`/`m`/`g` suffix).
//!
//! External merge-sort: input is read in bounded batches (`-S`, default 1 MiB), each sorted
//! and spilled to the private `/scratch` tmpfs (`CAP_SCRATCH`) as a "run", then runs are
//! multi-pass merged with a bounded fan-in. Peak guest memory is the batch budget,
//! independent of input size; an input that fits one batch never touches scratch. Stable
//! throughout. Declared `read-write`: ordinary sorting only reads inputs and spills to
//! `/scratch`, but `-o FILE` is a real write performed by this process. The tier still denies
//! spawn, network, persistence, and namespace mutation.
//!
//! GNU deviations: `-h`/`--human-numeric-sort` means human-numeric ordering, so the bare
//! `-h` is NOT a help flag — use `--help`. No `-z`/`--zero-terminated`, `-R`/`--random-sort`,
//! `--parallel`, `--files0-from`, `--compress-program`, or `--batch-size`; `-c`/`-C` are
//! exposed as `--check`/`--check-silent` (rather than GNU's `--check[=quiet|...]` value
//! form). `-M`/month-name ordering is accepted in a `-k` spec but treated as default order
//! (no month parsing).
//!
//! Exit status: 0 success (with `-c`/`-C`: the input was already sorted); 1 with `-c`/`-C`
//! when the input was not sorted; 2 on an error (bad option/key, file open failure, write
//! error).
//!
//! Ported from memcontainers' `programs::sort`.

use alloc::vec::Vec;
use core::cmp::Ordering;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use crate::spool::{Run, SpoolFile};
use crate::textio::LineReader;
use sysroot as rt;

const BUDGET_DEFAULT: usize = 1 << 20; // 1 MiB
const FANIN: usize = 16;
const WRITE_CHUNK: usize = 1 << 14; // 16 KiB

fn is_blank(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

// ---------- key definitions ----------

/// One sort key: a `(field.char)` start/end span plus its effective comparison flags
/// (already merged with the global options).
#[derive(Clone, Copy)]
struct KeyDef {
    sfield: usize, // 1-based start field
    schar: usize,  // 1-based char within the start field (default 1)
    efield: usize, // 0 = to end of line, else 1-based end field
    echar: usize,  // 0 = end of the end field, else char count from its start
    bstart: bool,
    bend: bool,
    numeric: bool,
    general: bool,
    human: bool,
    version: bool,
    fold: bool,
    dict: bool,
    ignore: bool,
    reverse: bool,
}

struct Opts {
    keys: Vec<KeyDef>,
    sep: Option<u8>,
    unique: bool,
    stable: bool,
    global_reverse: bool,
}

// ---------- field extraction ----------

/// The `[start, end)` of field `f` (1-based) when split on `sep`. A missing field yields an
/// empty span at the line end.
fn field_sep(line: &[u8], sep: u8, f: usize) -> (usize, usize) {
    let mut idx = 1;
    let mut start = 0usize;
    let mut i = 0usize;
    while idx < f && i < line.len() {
        if line[i] == sep {
            idx += 1;
            start = i + 1;
        }
        i += 1;
    }
    if idx < f {
        return (line.len(), line.len()); // fewer fields than requested
    }
    let mut e = start;
    while e < line.len() && line[e] != sep {
        e += 1;
    }
    (start, e)
}

/// Start of a key (blank-separated model): skip `sfield-1` fields, then optional
/// leading-blank skip and the char offset.
fn begfield_blank(line: &[u8], key: &KeyDef) -> usize {
    let lim = line.len();
    let mut ptr = 0usize;
    let mut skip = key.sfield - 1;
    while ptr < lim && skip > 0 {
        while ptr < lim && is_blank(line[ptr]) {
            ptr += 1;
        }
        while ptr < lim && !is_blank(line[ptr]) {
            ptr += 1;
        }
        skip -= 1;
    }
    if key.bstart {
        while ptr < lim && is_blank(line[ptr]) {
            ptr += 1;
        }
    }
    (ptr + key.schar.saturating_sub(1)).min(lim)
}

/// End of a key (blank-separated model).
fn limfield_blank(line: &[u8], key: &KeyDef) -> usize {
    let lim = line.len();
    if key.efield == 0 {
        return lim;
    }
    let mut ptr = 0usize;
    let mut skip = key.efield - 1;
    while ptr < lim && skip > 0 {
        while ptr < lim && is_blank(line[ptr]) {
            ptr += 1;
        }
        while ptr < lim && !is_blank(line[ptr]) {
            ptr += 1;
        }
        skip -= 1;
    }
    if key.echar == 0 {
        while ptr < lim && is_blank(line[ptr]) {
            ptr += 1;
        }
        while ptr < lim && !is_blank(line[ptr]) {
            ptr += 1;
        }
        ptr
    } else {
        if key.bend {
            while ptr < lim && is_blank(line[ptr]) {
                ptr += 1;
            }
        }
        (ptr + key.echar).min(lim)
    }
}

/// Extract the key's byte slice from `line`.
fn extract<'a>(line: &'a [u8], key: &KeyDef, o: &Opts) -> &'a [u8] {
    let (s, e) = match o.sep {
        Some(sep) => {
            let (fs, fe) = field_sep(line, sep, key.sfield);
            let mut start = fs;
            if key.bstart {
                while start < fe && is_blank(line[start]) {
                    start += 1;
                }
            }
            start = (start + key.schar.saturating_sub(1)).min(line.len());
            let end = if key.efield == 0 {
                line.len()
            } else {
                let (es, ee) = field_sep(line, sep, key.efield);
                if key.echar == 0 {
                    ee
                } else {
                    let mut b = es;
                    if key.bend {
                        while b < ee && is_blank(line[b]) {
                            b += 1;
                        }
                    }
                    (b + key.echar).min(line.len())
                }
            };
            (start, end)
        }
        None => (begfield_blank(line, key), limfield_blank(line, key)),
    };
    let s = s.min(line.len());
    let e = e.min(line.len()).max(s);
    &line[s..e]
}

// ---------- numeric / version comparison ----------

/// Parse a leading number from `s` to f64 (0.0 if none). `general` allows an exponent
/// (`-g`/strtod); plain `-n` stops before any `e`.
fn parse_num(s: &[u8], general: bool) -> f64 {
    let mut i = 0;
    while i < s.len() && is_blank(s[i]) {
        i += 1;
    }
    let start = i;
    if i < s.len() && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
    }
    let mut saw = false;
    while i < s.len() && s[i].is_ascii_digit() {
        i += 1;
        saw = true;
    }
    if i < s.len() && s[i] == b'.' {
        i += 1;
        while i < s.len() && s[i].is_ascii_digit() {
            i += 1;
            saw = true;
        }
    }
    if general && saw && i < s.len() && (s[i] == b'e' || s[i] == b'E') {
        let mut j = i + 1;
        if j < s.len() && (s[j] == b'+' || s[j] == b'-') {
            j += 1;
        }
        let mut e = false;
        while j < s.len() && s[j].is_ascii_digit() {
            j += 1;
            e = true;
        }
        if e {
            i = j;
        }
    }
    if !saw {
        return 0.0;
    }
    core::str::from_utf8(&s[start..i])
        .ok()
        .and_then(|t| t.parse::<f64>().ok())
        .unwrap_or(0.0)
}

/// Human-readable numeric value: mantissa scaled by a 1024-based K/M/G/… suffix.
fn human_val(s: &[u8]) -> f64 {
    let mut i = 0;
    while i < s.len() && is_blank(s[i]) {
        i += 1;
    }
    let start = i;
    if i < s.len() && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
    }
    while i < s.len() && s[i].is_ascii_digit() {
        i += 1;
    }
    if i < s.len() && s[i] == b'.' {
        i += 1;
        while i < s.len() && s[i].is_ascii_digit() {
            i += 1;
        }
    }
    let mant = core::str::from_utf8(&s[start..i])
        .ok()
        .and_then(|t| t.parse::<f64>().ok())
        .unwrap_or(0.0);
    // 1024-based suffixes (f64 `powi` is std-only, so use explicit products).
    const K: f64 = 1024.0;
    let scale = match s.get(i).copied() {
        Some(b'K') | Some(b'k') => K,
        Some(b'M') => K * K,
        Some(b'G') => K * K * K,
        Some(b'T') => K * K * K * K,
        Some(b'P') => K * K * K * K * K,
        Some(b'E') => K * K * K * K * K * K,
        _ => 1.0,
    };
    mant * scale
}

fn fcmp(a: f64, b: f64) -> Ordering {
    a.partial_cmp(&b).unwrap_or(Ordering::Equal)
}

/// Read a run of digits at `i`; returns (slice, next index).
fn digit_run(s: &[u8], i: usize) -> (&[u8], usize) {
    let mut j = i;
    while j < s.len() && s[j].is_ascii_digit() {
        j += 1;
    }
    (&s[i..j], j)
}

/// Compare two digit runs as magnitudes (leading zeros ignored).
fn cmp_digit_runs(a: &[u8], b: &[u8]) -> Ordering {
    let az: &[u8] = {
        let k = a.iter().take_while(|&&c| c == b'0').count();
        &a[k..]
    };
    let bz: &[u8] = {
        let k = b.iter().take_while(|&&c| c == b'0').count();
        &b[k..]
    };
    match az.len().cmp(&bz.len()) {
        Ordering::Equal => az.cmp(bz),
        other => other,
    }
}

/// Natural/version comparison: numeric runs by value, other bytes lexically.
fn version_cmp(a: &[u8], b: &[u8]) -> Ordering {
    let (mut i, mut j) = (0usize, 0usize);
    loop {
        if i >= a.len() && j >= b.len() {
            return Ordering::Equal;
        }
        if i >= a.len() {
            return Ordering::Less;
        }
        if j >= b.len() {
            return Ordering::Greater;
        }
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let (ra, ni) = digit_run(a, i);
            let (rb, nj) = digit_run(b, j);
            let c = cmp_digit_runs(ra, rb);
            if c != Ordering::Equal {
                return c;
            }
            i = ni;
            j = nj;
        } else {
            if a[i] != b[j] {
                return a[i].cmp(&b[j]);
            }
            i += 1;
            j += 1;
        }
    }
}

fn keep(c: u8, dict: bool, ignore: bool) -> bool {
    if dict && !(is_blank(c) || c.is_ascii_alphanumeric()) {
        return false;
    }
    if ignore && !(c == b'\t' || (b' '..=b'~').contains(&c)) {
        return false;
    }
    true
}

/// Bytewise compare with `-f`/`-d`/`-i` transforms applied on the fly.
fn str_cmp(a: &[u8], b: &[u8], fold: bool, dict: bool, ignore: bool) -> Ordering {
    let ia = a
        .iter()
        .copied()
        .filter(|&c| keep(c, dict, ignore))
        .map(|c| if fold { c.to_ascii_uppercase() } else { c });
    let ib = b
        .iter()
        .copied()
        .filter(|&c| keep(c, dict, ignore))
        .map(|c| if fold { c.to_ascii_uppercase() } else { c });
    ia.cmp(ib)
}

/// Compare two key slices under a key's flags (reverse applied by the caller).
fn compare_slices(ka: &[u8], kb: &[u8], key: &KeyDef) -> Ordering {
    if key.numeric || key.general {
        fcmp(parse_num(ka, key.general), parse_num(kb, key.general))
    } else if key.human {
        fcmp(human_val(ka), human_val(kb))
    } else if key.version {
        version_cmp(ka, kb)
    } else {
        str_cmp(ka, kb, key.fold, key.dict, key.ignore)
    }
}

/// Compare by the sort keys only (no last-resort tie-break). Used for ordering and, via
/// `Equal`, for `-u` duplicate detection.
fn keys_cmp(a: &[u8], b: &[u8], o: &Opts) -> Ordering {
    for key in &o.keys {
        let c = compare_slices(extract(a, key, o), extract(b, key, o), key);
        let c = if key.reverse { c.reverse() } else { c };
        if c != Ordering::Equal {
            return c;
        }
    }
    Ordering::Equal
}

/// The total order: keys, then (unless `-s`) the whole line bytewise as a last-resort
/// tie-break, honoring the global reverse.
fn total_cmp(a: &[u8], b: &[u8], o: &Opts) -> Ordering {
    let c = keys_cmp(a, b, o);
    if c != Ordering::Equal || o.stable {
        return c;
    }
    let w = a.cmp(b);
    if o.global_reverse {
        w.reverse()
    } else {
        w
    }
}

// ---------- batches & runs ----------

struct Batch {
    data: Vec<u8>,
    lines: Vec<(u32, u32)>,
}

impl Batch {
    fn new() -> Batch {
        Batch {
            data: Vec::new(),
            lines: Vec::new(),
        }
    }
    fn push(&mut self, line: &[u8]) {
        let start = self.data.len() as u32;
        self.data.extend_from_slice(line);
        self.lines.push((start, line.len() as u32));
    }
    fn bytes(&self) -> usize {
        self.data.len()
    }
    fn line_count(&self) -> usize {
        self.lines.len()
    }
    fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }
    fn clear(&mut self) {
        self.data.clear();
        self.lines.clear();
    }
    fn slice(&self, i: usize) -> &[u8] {
        let (s, l) = self.lines[i];
        &self.data[s as usize..s as usize + l as usize]
    }
    fn sort(&mut self, o: &Opts) {
        let data = &self.data;
        self.lines.sort_by(|&(s1, l1), &(s2, l2)| {
            let a = &data[s1 as usize..s1 as usize + l1 as usize];
            let b = &data[s2 as usize..s2 as usize + l2 as usize];
            total_cmp(a, b, o)
        });
    }
}

fn write_run(b: &Batch) -> Result<Run, i32> {
    let run = Run::create()?;
    let mut buf: Vec<u8> = Vec::new();
    for i in 0..b.line_count() {
        buf.extend_from_slice(b.slice(i));
        buf.push(b'\n');
        if buf.len() >= WRITE_CHUNK {
            run.write_all(&buf)?;
            buf.clear();
        }
    }
    if !buf.is_empty() {
        run.write_all(&buf)?;
    }
    Ok(run)
}

/// Pick the lowest-ordered non-exhausted head (ties keep the lower index → stable).
fn pick_best(cur: &[Option<Vec<u8>>], o: &Opts) -> Option<usize> {
    let mut best: Option<usize> = None;
    for (i, slot) in cur.iter().enumerate() {
        if slot.is_none() {
            continue;
        }
        best = Some(match best {
            None => i,
            Some(b) => {
                if total_cmp(cur[i].as_deref().unwrap(), cur[b].as_deref().unwrap(), o)
                    == Ordering::Less
                {
                    i
                } else {
                    b
                }
            }
        });
    }
    best
}

/// K-way merge of sorted `runs` into `emit`, in total order. Stable.
fn merge(
    runs: &mut [Run],
    o: &Opts,
    emit: &mut impl FnMut(&[u8]) -> Result<(), i32>,
) -> Result<(), i32> {
    let mut cur: Vec<Option<Vec<u8>>> = Vec::with_capacity(runs.len());
    for r in runs.iter_mut() {
        r.rewind_for_read()?;
        cur.push(r.next_line()?.map(|l| l.to_vec()));
    }
    while let Some(b) = pick_best(&cur, o) {
        let line = cur[b].take().unwrap();
        emit(&line)?;
        cur[b] = runs[b].next_line()?.map(|l| l.to_vec());
    }
    Ok(())
}

fn merge_group(mut group: Vec<Run>, o: &Opts) -> Result<Run, i32> {
    let out = Run::create()?;
    let mut buf: Vec<u8> = Vec::new();
    merge(&mut group, o, &mut |line| {
        buf.extend_from_slice(line);
        buf.push(b'\n');
        if buf.len() >= WRITE_CHUNK {
            let r = out.write_all(&buf);
            buf.clear();
            return r;
        }
        Ok(())
    })?;
    if !buf.is_empty() {
        out.write_all(&buf)?;
    }
    Ok(out)
}

fn reduce_runs(mut runs: Vec<Run>, o: &Opts) -> Result<Vec<Run>, i32> {
    while runs.len() > FANIN {
        let mut next: Vec<Run> = Vec::new();
        let mut group: Vec<Run> = Vec::new();
        for r in runs {
            group.push(r);
            if group.len() == FANIN {
                next.push(merge_group(core::mem::take(&mut group), o)?);
            }
        }
        match group.len() {
            0 => {}
            1 => next.push(group.into_iter().next().unwrap()),
            _ => next.push(merge_group(group, o)?),
        }
        runs = next;
    }
    Ok(runs)
}

// ---------- output sink ----------

/// Chunked writer to the chosen output fd, with `-u` dedup over the sort keys.
struct Sink {
    fd: i32,
    buf: Vec<u8>,
    last: Option<Vec<u8>>,
    unique: bool,
}

impl Sink {
    fn new(fd: i32, unique: bool) -> Sink {
        Sink {
            fd,
            buf: Vec::new(),
            last: None,
            unique,
        }
    }
    fn emit(&mut self, line: &[u8], o: &Opts) -> Result<(), i32> {
        if self.unique {
            if let Some(p) = self.last.as_deref() {
                if keys_cmp(p, line, o) == Ordering::Equal {
                    return Ok(());
                }
            }
            self.last = Some(line.to_vec());
        }
        self.buf.extend_from_slice(line);
        self.buf.push(b'\n');
        if self.buf.len() >= WRITE_CHUNK {
            rt::write_all(self.fd, &self.buf)?;
            self.buf.clear();
        }
        Ok(())
    }
    fn finish(&mut self) -> Result<(), i32> {
        if !self.buf.is_empty() {
            rt::write_all(self.fd, &self.buf)?;
            self.buf.clear();
        }
        Ok(())
    }
}

fn emit_batch(b: &Batch, o: &Opts, sink: &mut Sink) -> Result<(), i32> {
    for i in 0..b.line_count() {
        sink.emit(b.slice(i), o)?;
    }
    sink.finish()
}

fn final_merge(mut runs: Vec<Run>, o: &Opts, sink: &mut Sink) -> Result<(), i32> {
    merge(&mut runs, o, &mut |line| sink.emit(line, o))?;
    sink.finish()
}

fn finalize(mut batch: Batch, mut runs: Vec<Run>, o: &Opts, sink: &mut Sink) -> Result<(), i32> {
    if runs.is_empty() {
        batch.sort(o);
        return emit_batch(&batch, o, sink);
    }
    if !batch.is_empty() {
        batch.sort(o);
        runs.push(write_run(&batch)?);
    }
    let reduced = reduce_runs(runs, o)?;
    final_merge(reduced, o, sink)
}

// ---------- -m merge mode ----------

struct FileSource {
    reader: LineReader,
    fd: i32,
    stdin: bool,
}

fn merge_mode(prog: &str, files: &[&[u8]], o: &Opts, sink: &mut Sink) -> i32 {
    let mut srcs: Vec<FileSource> = Vec::new();
    let mut rc = 0;
    if files.is_empty() {
        srcs.push(FileSource {
            reader: LineReader::new(rt::STDIN),
            fd: rt::STDIN,
            stdin: true,
        });
    }
    for &f in files {
        if f == b"-" {
            srcs.push(FileSource {
                reader: LineReader::new(rt::STDIN),
                fd: rt::STDIN,
                stdin: true,
            });
            continue;
        }
        match core::str::from_utf8(f)
            .ok()
            .map(|p| rt::open(p, rt::O_READ))
        {
            Some(Ok(fd)) => srcs.push(FileSource {
                reader: LineReader::new(fd),
                fd,
                stdin: false,
            }),
            Some(Err(e)) => {
                eprintln!("{}: {}: {}", prog, String::from_utf8_lossy(f), rt::strerror(e));
                rc = 1;
            }
            None => {
                eprintln!("{}: {}: invalid path", prog, String::from_utf8_lossy(f));
                rc = 1;
            }
        }
    }

    let mut cur: Vec<Option<Vec<u8>>> = Vec::with_capacity(srcs.len());
    for s in srcs.iter_mut() {
        let head = match s.reader.next_line() {
            Ok(line) => line.map(|l| l.to_vec()),
            Err(_) => {
                rc = 1;
                None
            }
        };
        cur.push(head);
    }
    let mut write_err = false;
    while let Some(b) = pick_best(&cur, o) {
        let line = cur[b].take().unwrap();
        if sink.emit(&line, o).is_err() {
            write_err = true;
            break;
        }
        cur[b] = match srcs[b].reader.next_line() {
            Ok(line) => line.map(|l| l.to_vec()),
            Err(_) => {
                rc = 1;
                None
            }
        };
    }
    if sink.finish().is_err() {
        write_err = true;
    }
    for s in &srcs {
        if !s.stdin {
            rt::close(s.fd);
        }
    }
    if write_err {
        rc = 1;
    }
    rc
}

fn copy_fd(src: i32, dst: i32) -> Result<(), i32> {
    let mut buf = [0u8; 8192];
    loop {
        let n = rt::read(src, &mut buf)?;
        if n == 0 {
            return Ok(());
        }
        rt::write_all(dst, &buf[..n])?;
    }
}

/// Open OUTPUT for writing (truncate/create); on failure print the error and return `Err`.
fn open_output(prog: &str, path: &str) -> Result<i32, ()> {
    match rt::open(path, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC) {
        Ok(fd) => Ok(fd),
        Err(e) => {
            eprintln!("{}: {}: {}", prog, path, rt::strerror(e));
            Err(())
        }
    }
}

/// Merge mode streams input and output at the same time. If `-o` names one of the input
/// files, opening it before the merge would truncate data that still needs to be read, so
/// stage the merge result through scratch and open the destination only after all sources
/// are consumed.
fn merge_mode_to_output(prog: &str, files: &[&[u8]], o: &Opts, out_path: Option<&str>) -> i32 {
    match out_path {
        None => {
            let mut sink = Sink::new(rt::STDOUT, o.unique);
            merge_mode(prog, files, o, &mut sink)
        }
        Some(path) => {
            let sf = match SpoolFile::create() {
                Ok(sf) => sf,
                Err(e) => {
                    eprintln!("{}: {}: {}", prog, path, rt::strerror(e));
                    return 2;
                }
            };
            let mut tmp = Sink::new(sf.fd(), o.unique);
            let mut rc = merge_mode(prog, files, o, &mut tmp);
            if sf.rewind().is_err() {
                rc = 1;
            }
            let out_fd = match open_output(prog, path) {
                Ok(fd) => fd,
                Err(()) => return 2,
            };
            if copy_fd(sf.fd(), out_fd).is_err() {
                eprintln!("sort: write error");
                rc = 1;
            }
            rt::close(out_fd);
            rc
        }
    }
}

// ---------- -c / -C check mode ----------

fn check_mode(prog: &str, files: &[&[u8]], o: &Opts, quiet: bool) -> i32 {
    let mut prev: Option<Vec<u8>> = None;
    let mut disorder: Option<Vec<u8>> = None;
    let rc = textio::stream_lines(prog, files, |line| {
        if let Some(p) = &prev {
            let c = total_cmp(p, line, o);
            let bad = if o.unique {
                c != Ordering::Less // duplicates count as disorder under -u
            } else {
                c == Ordering::Greater
            };
            if bad {
                disorder = Some(line.to_vec());
                return Err(0); // stop at the first offending line
            }
        }
        prev = Some(line.to_vec());
        Ok(())
    });
    if rc != 0 {
        return rc;
    }
    match disorder {
        Some(l) => {
            if !quiet {
                eprintln!("{}: disorder detected", prog);
                let _ = rt::write_all(rt::STDERR, &l);
                let _ = rt::write_all(rt::STDERR, b"\n");
            }
            1
        }
        None => 0,
    }
}

// ---------- option parsing ----------

fn parse_size(b: &[u8]) -> Option<usize> {
    if b.is_empty() {
        return None;
    }
    let (digits, mult): (&[u8], usize) = match b[b.len() - 1] {
        b'k' | b'K' => (&b[..b.len() - 1], 1024),
        b'm' | b'M' => (&b[..b.len() - 1], 1024 * 1024),
        b'g' | b'G' => (&b[..b.len() - 1], 1024 * 1024 * 1024),
        _ => (b, 1),
    };
    if digits.is_empty() {
        return None;
    }
    let mut v: usize = 0;
    for &ch in digits {
        if !ch.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((ch - b'0') as usize)?;
    }
    v.checked_mul(mult)
}

/// Per-end raw flags parsed from a `-k` position's trailing letters.
#[derive(Default, Clone, Copy)]
struct RawFlags {
    numeric: bool,
    general: bool,
    human: bool,
    version: bool,
    fold: bool,
    dict: bool,
    ignore: bool,
    reverse: bool,
    blank: bool,
}

impl RawFlags {
    fn typed(&self) -> bool {
        self.numeric || self.general || self.human || self.version
    }
}

/// Parse one `-k` position `F[.C][flags]`, returning (field, char, flags).
fn parse_pos(s: &[u8]) -> Option<(usize, usize, RawFlags)> {
    let mut i = 0;
    let mut field = 0usize;
    let mut seen = false;
    while i < s.len() && s[i].is_ascii_digit() {
        field = field.checked_mul(10)?.checked_add((s[i] - b'0') as usize)?;
        i += 1;
        seen = true;
    }
    if !seen {
        return None;
    }
    let mut chr = 0usize;
    if i < s.len() && s[i] == b'.' {
        i += 1;
        let mut c = 0usize;
        let mut cseen = false;
        while i < s.len() && s[i].is_ascii_digit() {
            c = c.checked_mul(10)?.checked_add((s[i] - b'0') as usize)?;
            i += 1;
            cseen = true;
        }
        if !cseen {
            return None;
        }
        chr = c;
    }
    let mut f = RawFlags::default();
    while i < s.len() {
        match s[i] {
            b'n' => f.numeric = true,
            b'g' => f.general = true,
            b'h' => f.human = true,
            b'V' => f.version = true,
            b'f' => f.fold = true,
            b'd' => f.dict = true,
            b'i' => f.ignore = true,
            b'r' => f.reverse = true,
            b'b' => f.blank = true,
            b'M' | b'R' => {} // month/random: accepted, treated as default order
            _ => return None,
        }
        i += 1;
    }
    Some((field, chr, f))
}

#[derive(Clone, Copy)]
struct Global {
    numeric: bool,
    general: bool,
    human: bool,
    version: bool,
    fold: bool,
    dict: bool,
    ignore: bool,
    reverse: bool,
    blank: bool,
}

/// Build a `KeyDef` from a `-k` value, folding in the global options for ends that specify
/// no flags of their own.
fn build_key(spec: &[u8], g: &Global) -> Option<KeyDef> {
    let mut parts = spec.splitn(2, |&b| b == b',');
    let start = parts.next()?;
    let (sfield, schar, sf) = parse_pos(start)?;
    let (efield, echar, ef) = match parts.next() {
        Some(end) => {
            let (f, c, ff) = parse_pos(end)?;
            (f, c, Some(ff))
        }
        None => (0, 0, None),
    };
    // A key's type flags can be written on either end; merge them, else global.
    let kt = if sf.typed() {
        sf
    } else if ef.map(|f| f.typed()).unwrap_or(false) {
        ef.unwrap()
    } else {
        RawFlags::default()
    };
    let typed = kt.typed();
    let other = |sv: bool, ev: bool, gv: bool| sv || ev || gv;
    let efr = ef.unwrap_or_default();
    Some(KeyDef {
        sfield: sfield.max(1),
        schar,
        efield,
        echar,
        bstart: sf.blank || g.blank,
        bend: efr.blank || g.blank,
        numeric: if typed { kt.numeric } else { g.numeric },
        general: if typed { kt.general } else { g.general },
        human: if typed { kt.human } else { g.human },
        version: if typed { kt.version } else { g.version },
        fold: other(sf.fold, efr.fold, g.fold),
        dict: other(sf.dict, efr.dict, g.dict),
        ignore: other(sf.ignore, efr.ignore, g.ignore),
        reverse: other(sf.reverse, efr.reverse, g.reverse),
    })
}

/// The clap command — the single source of `sort`'s flag surface AND its `--help`. `-h` is
/// human-numeric ordering (GNU), NOT help, so the auto help flag is disabled and an explicit
/// long-only `--help` is added.
fn command() -> Command {
    Command::new("sort")
        .about("Write sorted concatenation of all FILE(s) to standard output. With no FILE, or when FILE is -, read standard input.")
        .disable_help_flag(true)
        .arg(Arg::new("help").long("help").action(ArgAction::Help).help("display this help and exit"))
        .arg(Arg::new("numeric").short('n').long("numeric-sort").action(ArgAction::SetTrue).help("compare according to string numerical value"))
        .arg(Arg::new("general").short('g').long("general-numeric-sort").action(ArgAction::SetTrue).help("compare according to general numerical value (allows exponents)"))
        .arg(Arg::new("human").short('h').long("human-numeric-sort").action(ArgAction::SetTrue).help("compare human readable numbers (e.g., 2K 1G) — NOT a help flag"))
        .arg(Arg::new("version").short('V').long("version-sort").action(ArgAction::SetTrue).help("natural sort of (version) numbers within text"))
        .arg(Arg::new("fold").short('f').long("ignore-case").action(ArgAction::SetTrue).help("fold lower case to upper case characters"))
        .arg(Arg::new("dict").short('d').long("dictionary-order").action(ArgAction::SetTrue).help("consider only blanks and alphanumeric characters"))
        .arg(Arg::new("ignore").short('i').long("ignore-nonprinting").action(ArgAction::SetTrue).help("consider only printable characters"))
        .arg(Arg::new("blank").short('b').long("ignore-leading-blanks").action(ArgAction::SetTrue).help("ignore leading blanks"))
        .arg(Arg::new("reverse").short('r').long("reverse").action(ArgAction::SetTrue).help("reverse the result of comparisons"))
        .arg(Arg::new("key").short('k').long("key").action(ArgAction::Append).num_args(1).value_name("KEYDEF").help("sort via a key; KEYDEF gives location and type (repeatable)"))
        .arg(Arg::new("sep").short('t').long("field-separator").num_args(1).value_name("SEP").help("use SEP instead of blank-to-non-blank transition"))
        .arg(Arg::new("unique").short('u').long("unique").action(ArgAction::SetTrue).help("with default ordering, output only the first of an equal run"))
        .arg(Arg::new("stable").short('s').long("stable").action(ArgAction::SetTrue).help("stabilize sort by disabling last-resort comparison"))
        .arg(Arg::new("merge").short('m').long("merge").action(ArgAction::SetTrue).help("merge already sorted files; do not sort"))
        .arg(Arg::new("check").short('c').long("check").action(ArgAction::SetTrue).help("check for sorted input; do not sort; report first disorder"))
        .arg(Arg::new("check-silent").short('C').long("check-silent").action(ArgAction::SetTrue).help("like -c, but do not report first bad line"))
        .arg(Arg::new("output").short('o').long("output").num_args(1).value_name("FILE").help("write result to FILE instead of standard output"))
        .arg(Arg::new("buffer-size").short('S').long("buffer-size").num_args(1).value_name("SIZE").help("in-memory batch budget before spilling to /scratch (suffix k/m/g)"))
        .arg(Arg::new("FILE").action(ArgAction::Append).num_args(0..).help("files to sort (- for standard input)"))
}

/// `sort [OPTION]... [FILE]...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };
    let prog = "sort";

    let g = Global {
        numeric: m.get_flag("numeric"),
        general: m.get_flag("general"),
        human: m.get_flag("human"),
        version: m.get_flag("version"),
        fold: m.get_flag("fold"),
        dict: m.get_flag("dict"),
        ignore: m.get_flag("ignore"),
        reverse: m.get_flag("reverse"),
        blank: m.get_flag("blank"),
    };
    let sep = m
        .get_one::<String>("sep")
        .and_then(|s| s.as_bytes().first().copied());

    // The operand list, as byte slices for the facade.
    let ops: Vec<&str> = m
        .get_many::<String>("FILE")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    let ops_b: Vec<&[u8]> = ops.iter().map(|s| s.as_bytes()).collect();

    // Build the key list; with no `-k`, a single whole-line key with the global options (so
    // `total_cmp`/`keys_cmp` work uniformly).
    let mut keys: Vec<KeyDef> = Vec::new();
    if let Some(specs) = m.get_many::<String>("key") {
        for spec in specs {
            match build_key(spec.as_bytes(), &g) {
                Some(k) => keys.push(k),
                None => {
                    eprintln!("{}: {}: invalid key specification", prog, spec);
                    return 2;
                }
            }
        }
    }
    if keys.is_empty() {
        keys.push(KeyDef {
            sfield: 1,
            schar: 1,
            efield: 0,
            echar: 0,
            bstart: g.blank,
            bend: g.blank,
            numeric: g.numeric,
            general: g.general,
            human: g.human,
            version: g.version,
            fold: g.fold,
            dict: g.dict,
            ignore: g.ignore,
            reverse: g.reverse,
        });
    }

    let o = Opts {
        keys,
        sep,
        unique: m.get_flag("unique"),
        stable: m.get_flag("stable"),
        global_reverse: g.reverse,
    };

    // Check mode short-circuits (no sorting, no output).
    if m.get_flag("check") || m.get_flag("check-silent") {
        return check_mode(prog, &ops_b, &o, m.get_flag("check-silent"));
    }

    let out_path: Option<&str> = m.get_one::<String>("output").map(String::as_str);

    // Merge mode: inputs are already sorted; just merge.
    if m.get_flag("merge") {
        return merge_mode_to_output(prog, &ops_b, &o, out_path);
    }

    let budget = m
        .get_one::<String>("buffer-size")
        .and_then(|s| parse_size(s.as_bytes()))
        .filter(|&v| v > 0)
        .unwrap_or(BUDGET_DEFAULT);

    let mut batch = Batch::new();
    let mut runs: Vec<Run> = Vec::new();
    let mut no_scratch = false;

    let rc = textio::stream_lines(prog, &ops_b, |line| {
        batch.push(line);
        if !no_scratch && batch.bytes() >= budget {
            batch.sort(&o);
            match write_run(&batch) {
                Ok(run) => {
                    runs.push(run);
                    batch.clear();
                }
                Err(_) => no_scratch = true,
            }
        }
        Ok(())
    });

    let out_fd = match out_path {
        None => rt::STDOUT,
        Some(path) => match open_output(prog, path) {
            Ok(fd) => fd,
            Err(()) => return 2,
        },
    };
    let mut sink = Sink::new(out_fd, o.unique);
    let werr = finalize(batch, runs, &o, &mut sink).is_err();
    if out_fd != rt::STDOUT {
        rt::close(out_fd);
    }
    if werr {
        eprintln!("sort: write error");
        return 1;
    }
    rc
}
