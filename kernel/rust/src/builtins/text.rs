//! Text builtins. The POSIX text coreutils (echo/head/wc/…) are wasm guests on
//! `$PATH` now. `tail` remains a builtin: emitting the LAST N lines requires
//! buffering the whole input, which the no_std, no-alloc guest sysroot cannot
//! do — so it stays here, where it has `alloc`, until the guest runtime gains a
//! heap.

use alloc::boxed::Box;
use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use crate::vfs::{FsError, KPath, OpenFlags};

use super::fs::resolve_path;
use super::{Builtin, BuiltinCtx, BuiltinStep, OutBuf, fs_error_str, push_str};

const CHUNK: usize = 4096;

// ---------- input gathering ----------
//
// `tail` must read its entire input before it can emit the last N lines, so it
// accumulates into a buffer. Reads are chunked and cooperative (yield while a
// pipe has more to come); a pathological never-EOF stream is capped so tail can
// still terminate.

enum InputSource {
    Stdin,
    File { path: KPath },
}

struct InputGather {
    source: InputSource,
    file: Option<Box<dyn crate::vfs::FileHandle>>,
    buf: Vec<u8>,
    done: bool,
    error: Option<FsError>,
}

impl InputGather {
    fn from_args(cwd: &str, args: &[String]) -> Self {
        // Walk args skipping the `-n N` flag pair so the count isn't mistaken
        // for a path.
        let mut i = 0;
        while i < args.len() {
            let a = &args[i];
            if a == "-n" {
                i += 2;
                continue;
            }
            if a.starts_with('-') {
                i += 1;
                continue;
            }
            return InputGather {
                source: InputSource::File {
                    path: resolve_path(cwd, a),
                },
                file: None,
                buf: Vec::new(),
                done: false,
                error: None,
            };
        }
        InputGather {
            source: InputSource::Stdin,
            file: None,
            buf: Vec::new(),
            done: false,
            error: None,
        }
    }

    /// Read one chunk. `Ok(true)` at EOF, `Ok(false)` when more is expected
    /// (caller may yield), `Err(())` when a hard error set `self.error`.
    fn pump(&mut self, ctx: &mut BuiltinCtx<'_>) -> Result<bool, ()> {
        if self.done {
            return Ok(true);
        }
        if let InputSource::File { path } = &self.source {
            if self.file.is_none() {
                match ctx.ns.open(path, OpenFlags::READ) {
                    Ok(h) => self.file = Some(h),
                    Err(e) => {
                        self.error = Some(e);
                        self.done = true;
                        return Err(());
                    }
                }
            }
        }
        let mut buf = [0u8; CHUNK];
        let read = match &mut self.source {
            InputSource::Stdin => ctx.stdin.read(&mut buf),
            InputSource::File { .. } => self.file.as_mut().expect("opened").read(&mut buf),
        };
        match read {
            Ok(0) => {
                let eof = match &self.source {
                    InputSource::Stdin => ctx.stdin.is_eof(),
                    InputSource::File { .. } => true,
                };
                if eof {
                    self.done = true;
                    return Ok(true);
                }
                Ok(false)
            }
            Ok(n) => {
                self.buf.extend_from_slice(&buf[..n]);
                Ok(false)
            }
            Err(e) => {
                self.error = Some(e);
                self.done = true;
                Err(())
            }
        }
    }
}

// ---------- tail ----------

pub fn tail_factory(args: Vec<String>) -> Box<dyn Builtin> {
    let n = parse_n(&args).unwrap_or(10);
    Box::new(TailBuiltin {
        n,
        input: None,
        produced: false,
        cwd_args: args,
        out: OutBuf::new(),
        err: OutBuf::new(),
        exit: 0,
    })
}

struct TailBuiltin {
    n: usize,
    input: Option<InputGather>,
    produced: bool,
    cwd_args: Vec<String>,
    out: OutBuf,
    err: OutBuf,
    exit: i32,
}

impl TailBuiltin {
    fn emit_last_lines(&mut self, buf: &[u8]) {
        let text = String::from_utf8_lossy(buf);
        let lines: Vec<&str> = text.lines().collect();
        let start = if lines.len() > self.n {
            lines.len() - self.n
        } else {
            0
        };
        for line in &lines[start..] {
            push_str(&mut self.out, line);
            push_str(&mut self.out, "\n");
        }
        self.produced = true;
    }
}

impl Builtin for TailBuiltin {
    fn step(&mut self, ctx: &mut BuiltinCtx<'_>) -> BuiltinStep {
        if let Some(s) = flush_both(&mut self.out, &mut self.err, ctx) {
            return s;
        }
        if self.produced {
            return BuiltinStep::Exit(self.exit);
        }
        if self.input.is_none() {
            self.input = Some(InputGather::from_args(ctx.cwd, &self.cwd_args));
        }
        let inp = self.input.as_mut().unwrap();
        match inp.pump(ctx) {
            Ok(true) => {
                let buf = core::mem::take(&mut inp.buf);
                self.emit_last_lines(&buf);
                BuiltinStep::BlockedOnStdout
            }
            Ok(false) => {
                // A never-EOF stream (e.g. /dev/zero) would grow without
                // bound; cap the buffer at 1 MiB and emit what we have so
                // tail can exit.
                const MAX_TAIL_BUF: usize = 1024 * 1024;
                if inp.buf.len() >= MAX_TAIL_BUF {
                    let buf = core::mem::take(&mut inp.buf);
                    self.emit_last_lines(&buf);
                    return BuiltinStep::BlockedOnStdout;
                }
                if matches!(inp.source, InputSource::Stdin) {
                    BuiltinStep::BlockedOnStdin
                } else {
                    BuiltinStep::BlockedOnStdout
                }
            }
            Err(()) => {
                if let Some(e) = inp.error {
                    let label = label_of(&inp.source);
                    push_str(
                        &mut self.err,
                        &format!("tail: {}: {}\n", label, fs_error_str(e)),
                    );
                }
                self.exit = 1;
                self.produced = true;
                BuiltinStep::BlockedOnStdout
            }
        }
    }
}

// ---------- helpers ----------

/// Parse `tail`'s `-n N` flag (lines). Absent → caller defaults to 10.
fn parse_n(args: &[String]) -> Option<usize> {
    let mut i = 0;
    while i < args.len() {
        if args[i] == "-n" && i + 1 < args.len() {
            return args[i + 1].parse::<usize>().ok();
        }
        i += 1;
    }
    None
}

fn label_of(src: &InputSource) -> String {
    match src {
        InputSource::Stdin => String::from("stdin"),
        InputSource::File { path } => String::from(path.as_str()),
    }
}

fn flush_both(out: &mut OutBuf, err: &mut OutBuf, ctx: &mut BuiltinCtx<'_>) -> Option<BuiltinStep> {
    match err.flush(ctx.stderr) {
        Ok(false) => return Some(BuiltinStep::BlockedOnStdout),
        Ok(true) => {}
        Err(_) => {}
    }
    match out.flush(ctx.stdout) {
        Ok(false) => Some(BuiltinStep::BlockedOnStdout),
        Ok(true) => None,
        Err(_) => Some(BuiltinStep::Exit(1)),
    }
}
