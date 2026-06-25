//! The single seam between the OS-agnostic shell and the world.
//!
//! The guest `/bin/sh` binds this trait to `sysroot` syscalls; native tests bind a
//! fake. Every method BLOCKS — the executor is straight-line code and relies on the
//! kernel turning a blocking syscall into cooperative suspension (SYSTEMS.md section 4.2), so the shell
//! needs no async coloring of its own.
//!
//! Signal numbers, the inherit tier, and the stopped-status floor come straight from
//! the generated contract (`//contracts:constants_rust`) — the single source of truth
//! (B2). Nothing is re-declared here, so these values cannot drift from the `mc` ABI.

use alloc::string::String;
use alloc::vec::Vec;

use constants_rust as abi;

pub type Fd = i32;
pub type Pid = u32;

/// A raw errno from the syscall ABI. 0 is never an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OsError(pub i32);

pub type OsResult<T> = Result<T, OsError>;

/// Minimal file metadata the shell needs (for `test`/`[` and globbing).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileStat {
    pub is_dir: bool,
    pub size: u64,
    /// Permission bits (owner triad) — for `test -r/-w/-x`.
    pub mode: u16,
    /// Modify time, ms since the epoch — for `test FILE1 -nt/-ot FILE2`.
    pub mtime: i64,
}

impl FileStat {
    pub fn readable(&self) -> bool {
        self.mode & 0o400 != 0
    }
    pub fn writable(&self) -> bool {
        self.mode & 0o200 != 0
    }
    pub fn executable(&self) -> bool {
        self.mode & 0o100 != 0
    }
}

/// Signal numbers the shell cares about. The discriminants ARE the contract's `mc`
/// signal constants (`//contracts:constants_rust`), so the enum can never disagree
/// with the kernel ABI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum Signal {
    Hup = abi::SIGHUP,
    Int = abi::SIGINT,
    Kill = abi::SIGKILL,
    Term = abi::SIGTERM,
    Cont = abi::SIGCONT,
    Tstp = abi::SIGTSTP,
    Chld = abi::SIGCHLD,
}

/// What to do with a signal. The shell sets `Int` to `Ignore` for itself and
/// restores `Default` in children before exec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SigDisp {
    Default,
    Ignore,
}

/// Standard fd numbers.
pub const STDIN: Fd = 0;
pub const STDOUT: Fd = 1;
pub const STDERR: Fd = 2;

/// Pass-through tier for `spawn`: inherit the parent's capabilities (from the contract).
pub use abi::TIER_INHERIT;

/// `waitpid` status floor meaning "the child stopped (SIGTSTP) rather than exited" —
/// a tiny stand-in for POSIX `WIFSTOPPED`. A status `>= STOPPED_STATUS` is a stop
/// notification, not an exit code. The value is the contract's `STOPPED_STATUS_BASE`.
pub const STOPPED_STATUS: i32 = abi::STOPPED_STATUS_BASE;

/// `open` flag bits (a bitmask) passed to [`ShellOs::open`] — straight from the
/// contract, so the executor's redirections speak the kernel's `mc` open flags.
pub use abi::{O_APPEND, O_CREATE, O_READ, O_TRUNC, O_WRITE};

/// The OS the shell runs on. All operations block; the kernel makes them
/// cooperative. Implementors keep any per-process bookkeeping behind `&mut self`.
pub trait ShellOs {
    // ---- process ---- (no fork; `spawn` loads a NEW program image)
    /// Spawn `argv[0]` (resolved by the caller or the kernel via $PATH) with the
    /// given std fds installed as the child's 0/1/2. Returns the child pid.
    fn spawn(
        &mut self,
        argv: &[String],
        in_fd: Fd,
        out_fd: Fd,
        err_fd: Fd,
        tier: i32,
    ) -> OsResult<Pid>;
    /// Block until `pid` exits; return its exit status (0..255). A return value
    /// `>= STOPPED_STATUS` means the child *stopped* (SIGTSTP) instead of
    /// exiting, so the shell can record a stopped job and reclaim the prompt.
    fn waitpid(&mut self, pid: Pid) -> OsResult<i32>;
    /// Non-blocking reap: `Some((pid,status))` if a child is ready, else `None`.
    fn try_wait_any(&mut self) -> OsResult<Option<(Pid, i32)>>;
    fn getpid(&self) -> Pid;

    // ---- fds / pipes / files ----
    fn pipe(&mut self) -> OsResult<(Fd, Fd)>; // (read, write)
    fn dup(&mut self, fd: Fd) -> OsResult<Fd>;
    fn dup2(&mut self, old: Fd, new: Fd) -> OsResult<()>;
    fn close(&mut self, fd: Fd);
    fn open(&mut self, path: &str, flags: i32) -> OsResult<Fd>;
    fn read(&mut self, fd: Fd, buf: &mut [u8]) -> OsResult<usize>;
    fn write_all(&mut self, fd: Fd, buf: &[u8]) -> OsResult<()>;

    // ---- fs queries ----
    fn readdir(&mut self, path: &str) -> OsResult<Vec<String>>;
    fn stat(&mut self, path: &str) -> OsResult<FileStat>;
    fn mkdir(&mut self, path: &str) -> OsResult<()>;
    fn unlink(&mut self, path: &str) -> OsResult<()>;
    fn getcwd(&mut self) -> OsResult<String>;
    fn chdir(&mut self, path: &str) -> OsResult<()>;
    /// Bind `old` onto `new` in this process's namespace (plan9 `bind`).
    fn bind(&mut self, old: &str, new: &str) -> OsResult<()>;
    /// Detach a mount/bind at `path` from this process's namespace.
    fn unmount(&mut self, path: &str) -> OsResult<()>;

    // ---- environment (files under /env) ----
    fn getenv(&mut self, name: &str) -> Option<String>;
    fn setenv(&mut self, name: &str, val: &str);
    fn unsetenv(&mut self, name: &str);
    fn environ(&mut self) -> Vec<String>; // names only

    // ---- signals / job control ----
    fn kill(&mut self, pid: i32, sig: Signal) -> OsResult<()>; // pid<0 ⇒ process group |pid|
    fn set_sigdisp(&mut self, sig: Signal, disp: SigDisp);
    /// Put a spawned child into its own process group (for job control).
    fn setpgid(&mut self, pid: Pid, pgid: Pid) -> OsResult<()>;
    /// Make `pgid` the foreground group (receives terminal signals).
    fn set_foreground_pgid(&mut self, pgid: Pid) -> OsResult<()>;

    // ---- interactive ----
    fn isatty(&self, fd: Fd) -> bool;
}
