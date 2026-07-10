//! mc-only syscall facade for coreutils.
//!
//! This keeps nutils' applet-facing `sys` API, but removes the native/WASI backend
//! selector. Shipped coreutils are pure mc guests; raw ABI imports come from
//! //memcontainers/sysroot/zig through `mc.zig`.

const errno = @import("errno.zig");
const types = @import("types.zig");
const impl = @import("mc.zig");

pub const Errno = errno.Errno;
pub const Error = errno.Error;
pub const fromErrno = errno.fromErrno;
pub const toErrno = errno.toErrno;

pub const Fd = types.Fd;
pub const Pid = types.Pid;
pub const Whence = types.Whence;
pub const Stat = types.Stat;
pub const O = types.O;
pub const Times = types.Times;
pub const Sig = types.Sig;
pub const Disp = types.Disp;
pub const PollFd = types.PollFd;
pub const Pipe = types.Pipe;

pub const STDIN: Fd = 0;
pub const STDOUT: Fd = 1;
pub const STDERR: Fd = 2;

pub const init = impl.init;

pub const open = impl.open;
pub const read = impl.read;
pub const writeAll = impl.writeAll;
pub const close = impl.close;
pub const lseek = impl.lseek;
pub const stat = impl.stat;
pub const lstat = impl.lstat;
pub const readlink = impl.readlink;
pub const symlink = impl.symlink;
pub const link = impl.link;
pub const unlink = impl.unlink;
pub const mkdir = impl.mkdir;
pub const readdir = impl.readdir;
pub const rename = impl.rename;
pub const chmod = impl.chmod;
pub const utimes = impl.utimes;
pub const ftruncate = impl.ftruncate;
pub const chdir = impl.chdir;
pub const getcwd = impl.getcwd;

pub const pipe = impl.pipe;
pub const spawn = impl.spawn;
pub const waitpid = impl.waitpid;
pub const waitpidNohang = impl.waitpidNohang;
pub const kill = impl.kill;
pub const getpid = impl.getpid;
pub const nice = impl.nice;
pub const sigdisp = impl.sigdisp;
pub const isatty = impl.isatty;

pub const timeRealtimeMs = impl.timeRealtimeMs;
pub const timeMonotonicMs = impl.timeMonotonicMs;
pub const sleepMs = impl.sleepMs;
pub const randomBytes = impl.randomBytes;

pub const httpGet = impl.httpGet;
pub const httpRequest = impl.httpRequest;
pub const httpStatus = impl.httpStatus;
pub const wsOpen = impl.wsOpen;
pub const poll = impl.poll;

pub fn strerror(e: Errno) []const u8 {
    return e.strerror();
}

pub const exit = impl.exit;
pub const argsAlloc = impl.argsAlloc;
