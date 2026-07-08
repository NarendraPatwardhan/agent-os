//! control.zig - thin facade for the `mc_ctl_*` control plane.
//!
//! Owns: the public control facade imported by main.zig and the stable
//!   `control.<name>` surface that delegates to domain modules.
//! Invariants: every exported control entry point remains reachable at the
//!   same name, and each facade binding forwards without changing behavior.
//! Consumes: scratch-buffer, VFS, exec-job, and service-call domain modules.
//! Not here: wire codecs, scratch-buffer internals, VFS policy, exec lifecycle,
//!   or service-call progression.

const buf_mod = @import("control/buf.zig");
const fs = @import("control/fs.zig");
const exec = @import("control/exec.zig");
const svc = @import("control/svc.zig");

pub const buf = buf_mod.buf;

pub const read = fs.read;
pub const readlink = fs.readlink;
pub const write = fs.write;
pub const readdir = fs.readdir;
pub const stat = fs.stat;
pub const mkdir = fs.mkdir;
pub const unlink = fs.unlink;
pub const chmod = fs.chmod;
pub const symlink = fs.symlink;
pub const mount = fs.mount;
pub const unmount = fs.unmount;

pub const execStart = exec.execStart;
pub const execPoll = exec.execPoll;
pub const execPeek = exec.execPeek;
pub const execClose = exec.execClose;

pub const svcCallStart = svc.svcCallStart;
pub const svcCallPoll = svc.svcCallPoll;
pub const svcCallClose = svc.svcCallClose;
