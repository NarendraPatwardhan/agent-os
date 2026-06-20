//! Filesystem-integral builtins. The POSIX coreutils (cat/ls/mkdir/rm/cp/mv/
//! touch/head/pwd/…) are wasm guests on `$PATH` — `pwd` itself became a guest
//! once `mc_sys_getcwd` existed. What remains here is `umount` (a privileged
//! mount-table operation — guests must not unmount). It uses the shared
//! `OneShot` "produce all output up front, then exit" shape and the
//! `resolve_path` helper the rest of the kernel relies on.

use alloc::boxed::Box;
use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use crate::vfs::KPath;

use super::{Builtin, BuiltinCtx, BuiltinStep, OutBuf, push_str};

// ---------- shared utilities ----------

pub fn resolve_path(cwd: &str, path: &str) -> KPath {
    let normalized_path = path.strip_prefix("./").unwrap_or(path);
    // "." (or "./") denotes the cwd itself — resolve to it exactly rather than
    // appending a trailing "/." the VFS cannot resolve.
    if normalized_path == "." || normalized_path.is_empty() {
        return KPath::new(cwd);
    }
    if normalized_path.starts_with('/') {
        KPath::new(normalized_path)
    } else {
        let s: String = if cwd.ends_with('/') {
            format!("{}{}", cwd, normalized_path)
        } else {
            format!("{}/{}", cwd, normalized_path)
        };
        KPath::new(&s)
    }
}

/// Try to drain `stdout` and `stderr` buffers in that order. Returns
/// `Some(step)` if the builtin should yield (blocked or hard error).
/// Returns `None` if both buffers are empty and the builtin may continue.
fn flush_buffers(
    stdout_buf: &mut OutBuf,
    stderr_buf: &mut OutBuf,
    ctx: &mut BuiltinCtx<'_>,
) -> Option<BuiltinStep> {
    match stderr_buf.flush(ctx.stderr) {
        Ok(false) => return Some(BuiltinStep::BlockedOnStdout), // stderr is sticky
        Ok(true) => {}
        Err(_) => {
            stderr_buf.queue(b""); // reset
        }
    }
    match stdout_buf.flush(ctx.stdout) {
        Ok(false) => Some(BuiltinStep::BlockedOnStdout),
        Ok(true) => None,
        Err(_) => Some(BuiltinStep::Exit(1)), // broken pipe etc.
    }
}

/// Simple buffered builtin: produces all its output up front into the stdout
/// buffer, then exits. Users: `pwd` (ignores args) and `umount` (reads args).
struct OneShot {
    out: OutBuf,
    err: OutBuf,
    work_done: bool,
    exit: i32,
    body: Option<fn(&mut Self, &mut BuiltinCtx<'_>)>,
    args: Vec<String>,
}

impl OneShot {
    fn new(body: fn(&mut Self, &mut BuiltinCtx<'_>), args: Vec<String>) -> Box<dyn Builtin> {
        Box::new(Self {
            out: OutBuf::new(),
            err: OutBuf::new(),
            work_done: false,
            exit: 0,
            body: Some(body),
            args,
        })
    }
}

impl Builtin for OneShot {
    fn step(&mut self, ctx: &mut BuiltinCtx<'_>) -> BuiltinStep {
        if !self.work_done {
            let body = self.body.take().expect("body present once");
            body(self, ctx);
            self.work_done = true;
        }
        if let Some(s) = flush_buffers(&mut self.out, &mut self.err, ctx) {
            return s;
        }
        BuiltinStep::Exit(self.exit)
    }
}

// ---------- umount ----------
//
// A privileged mount-table operation (guests must not unmount filesystems, so
// it stays a builtin, run by the pid-1 shell). `umount /tmp` detaches the
// mount; unmounting a mount that still has a child mount under it is busy.

pub fn umount_factory(args: Vec<String>) -> Box<dyn Builtin> {
    OneShot::new(umount_body, args)
}

fn umount_body(s: &mut OneShot, ctx: &mut BuiltinCtx<'_>) {
    let target = match s.args.first() {
        Some(t) => t.clone(),
        None => {
            push_str(&mut s.err, "umount: missing operand\n");
            s.exit = 1;
            return;
        }
    };
    let path = resolve_path(ctx.cwd, &target);
    // `umount` is the agent's tool for the SHARED mount table: it targets the
    // root namespace so the effect persists, unlike a guest's per-process
    // `mc_sys_unmount`.
    if let Err(e) = ctx.root_ns.unmount(path.as_str()) {
        let reason = match e {
            crate::vfs::FsError::NotEmpty => "target is busy",
            crate::vfs::FsError::NotFound => "not mounted",
            _ => super::fs_error_str(e),
        };
        push_str(
            &mut s.err,
            &format!("umount: {}: {}\n", path.as_str(), reason),
        );
        s.exit = 1;
    }
}
