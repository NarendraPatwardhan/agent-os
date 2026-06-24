// The safe-wrapper skin over the generated `mc_sys_*` imports, plus the
// `entry!` / `declare_tier!` / `declare_budget!` glue and the `#[panic_handler]`.
//
// The raw imports cross the wire as `(…i32) -> i32`: every argument — including
// guest pointers and lengths — is a wasm `i32`, and every call returns an `i32`
// (an errno; `0` = success). A guest pointer is an offset into the guest's OWN
// linear memory, never a host object (A6 guest-pointer containment): these
// wrappers do the `as i32` casts at the boundary and hand the kernel only
// offsets it then bounds-checks. The ergonomic surface a Rust guest actually
// calls — `read`/`write_all`/`open`/`spawn`/… returning `Result<T, errno>` — is
// all hand-written here.
//
// `use crate::*` pulls in BOTH the `pub(crate)` raw `mc_sys_*` imports declared
// in `lib.rs` AND the re-exported constants (`ENOENT`, `O_READ`, `TIER_FULL`,
// `WNOHANG`, the `SERVE_OP_*`/`SEEK_*`/`SIG*` families, …). This module never
// redeclares the extern block or any constant — it consumes them.
use crate::*;

#[cfg(not(target_os = "wasi"))]
use core::panic::PanicInfo;

// Standard fds — a guest convention, not part of the marshaled syscall ABI.
pub const STDIN: i32 = 0;
pub const STDOUT: i32 = 1;
pub const STDERR: i32 = 2;

/// A file's metadata, as returned by [`stat`] / [`lstat`].
#[derive(Clone, Copy)]
pub struct Stat {
    pub size: u64,
    pub is_dir: bool,
    pub is_symlink: bool,
    /// Hard-link count (POSIX `st_nlink`).
    pub nlink: u32,
    /// POSIX permission bits (the low 9 rwx bits are meaningful; single subject,
    /// so the owner triad governs).
    pub mode: u16,
    /// Modify / access / change times, ms since the Unix epoch (`0` = unknown).
    pub mtime: i64,
    pub atime: i64,
    pub ctime: i64,
}

impl Stat {
    /// Owner-triad permission predicates (single subject = owner) — back `test`'s
    /// `-r`/`-w`/`-x`.
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

/// Create a pipe, returning `(read_fd, write_fd)`.
pub fn pipe() -> Result<(i32, i32), i32> {
    let mut r: u32 = 0;
    let mut w: u32 = 0;
    let errno = unsafe { mc_sys_pipe((&mut r as *mut u32) as i32, (&mut w as *mut u32) as i32) };
    if errno != 0 {
        Err(errno)
    } else {
        Ok((r as i32, w as i32))
    }
}

/// Duplicate a file descriptor onto the lowest free descriptor.
pub fn dup(fd: i32) -> Result<i32, i32> {
    let mut n: u32 = 0;
    let errno = unsafe { mc_sys_dup(fd, (&mut n as *mut u32) as i32) };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(n as i32)
    }
}

/// This process's pid.
pub fn getpid() -> u32 {
    let mut p: u32 = 0;
    unsafe {
        mc_sys_getpid((&mut p as *mut u32) as i32);
    }
    p
}

/// This process's parent pid.
pub fn getppid() -> u32 {
    let mut p: u32 = 0;
    unsafe {
        mc_sys_getppid((&mut p as *mut u32) as i32);
    }
    p
}

/// Spawn a child program inheriting the caller's capabilities. `argv` is a
/// NUL-separated blob (`argv[0]` = name).
pub fn spawn(argv: &[u8], in_fd: i32, out_fd: i32, err_fd: i32) -> Result<u32, i32> {
    spawn_tiered(argv, in_fd, out_fd, err_fd, TIER_INHERIT)
}

/// Spawn a child program narrowed to `tier` (one of the `TIER_*` constants): the
/// child runs at `caller_caps ∩ tier` — never more. Capabilities only ever narrow
/// down the process tree (A9 default-deny), so this is how you run untrusted or
/// AI-authored code at strictly lower privilege.
pub fn spawn_tiered(
    argv: &[u8],
    in_fd: i32,
    out_fd: i32,
    err_fd: i32,
    tier: i32,
) -> Result<u32, i32> {
    let mut pid: u32 = 0;
    let errno = unsafe {
        mc_sys_spawn(
            argv.as_ptr() as i32,
            argv.len() as i32,
            in_fd,
            out_fd,
            err_fd,
            tier,
            (&mut pid as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(pid)
    }
}

/// Wait (blocking) for child `pid` (or any child if `pid == -1`); returns the
/// exit status.
pub fn waitpid(pid: i32) -> Result<i32, i32> {
    waitpid_opts(pid, 0).map(|(status, _)| status)
}

/// Non-blocking wait: `Ok(None)` if no child has exited yet, else
/// `Ok(Some((status, reaped_pid)))`.
pub fn waitpid_nohang(pid: i32) -> Result<Option<(i32, u32)>, i32> {
    let (status, got) = waitpid_opts(pid, WNOHANG)?;
    if got == 0 {
        Ok(None)
    } else {
        Ok(Some((status, got)))
    }
}

fn waitpid_opts(pid: i32, opts: i32) -> Result<(i32, u32), i32> {
    let mut status: u32 = 0;
    let mut got: u32 = 0;
    let errno = unsafe {
        mc_sys_waitpid(
            pid,
            opts,
            (&mut status as *mut u32) as i32,
            (&mut got as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok((status as i32, got))
    }
}

/// Byte length of the stat record shared by `mc_sys_stat`, `mc_sys_lstat`, and
/// served-filesystem `SERVE_OP_STAT` responses.
pub const STAT_RECORD_LEN: usize = 44;

/// Encode a stat record (little-endian). MUST match the kernel's `write_stat_buf`:
/// `size@0 u64`, `kind@8 u32` (0=file/1=dir/2=symlink), `nlink@12 u32`,
/// `mode@16 u32`, `mtime@20 i64`, `atime@28 i64`, `ctime@36 i64` (times = ms since
/// the Unix epoch). A guest file server uses this to answer `SERVE_OP_STAT`.
pub fn encode_stat(stat: &Stat, buf: &mut [u8; STAT_RECORD_LEN]) {
    buf[..8].copy_from_slice(&stat.size.to_le_bytes());
    let kind: u32 = if stat.is_dir {
        1
    } else if stat.is_symlink {
        2
    } else {
        0
    };
    buf[8..12].copy_from_slice(&kind.to_le_bytes());
    buf[12..16].copy_from_slice(&stat.nlink.to_le_bytes());
    buf[16..20].copy_from_slice(&(stat.mode as u32).to_le_bytes());
    buf[20..28].copy_from_slice(&stat.mtime.to_le_bytes());
    buf[28..36].copy_from_slice(&stat.atime.to_le_bytes());
    buf[36..44].copy_from_slice(&stat.ctime.to_le_bytes());
}

/// Append one typed served-filesystem directory entry to `buf` at `off`. The wire
/// record is `[kind:u32][name_len:u32][name bytes...]`; `kind` is one of
/// `SERVE_DIRENT_*`. Returns the new offset, or `None` if the record would not fit
/// or the name is not a legal path component.
pub fn push_serve_dirent(buf: &mut [u8], off: usize, kind: u32, name: &str) -> Option<usize> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.as_bytes().iter().any(|&b| b == 0 || b == b'/')
    {
        return None;
    }
    let n = name.len();
    let end = off.checked_add(8)?.checked_add(n)?;
    if end > buf.len() {
        return None;
    }
    buf[off..off + 4].copy_from_slice(&kind.to_le_bytes());
    buf[off + 4..off + 8].copy_from_slice(&(n as u32).to_le_bytes());
    buf[off + 8..end].copy_from_slice(name.as_bytes());
    Some(end)
}

/// Decode the kernel's 44-byte stat record (little-endian). MUST match
/// `write_stat_buf` in the kernel: `size@0 u64`, `kind@8 u32` (0=file/1=dir/
/// 2=symlink), `nlink@12 u32`, `mode@16 u32`, `mtime@20 i64`, `atime@28 i64`,
/// `ctime@36 i64` (times = ms since the Unix epoch).
fn parse_stat(buf: &[u8; STAT_RECORD_LEN]) -> Stat {
    let u64_at = |o: usize| u64::from_le_bytes(buf[o..o + 8].try_into().unwrap());
    let u32_at = |o: usize| u32::from_le_bytes(buf[o..o + 4].try_into().unwrap());
    let i64_at = |o: usize| i64::from_le_bytes(buf[o..o + 8].try_into().unwrap());
    let kind = u32_at(8);
    Stat {
        size: u64_at(0),
        is_dir: kind == 1,
        is_symlink: kind == 2,
        nlink: u32_at(12),
        mode: u32_at(16) as u16,
        mtime: i64_at(20),
        atime: i64_at(28),
        ctime: i64_at(36),
    }
}

/// Stat `path`, following a trailing symlink. `Err(errno)` if it does not exist or
/// is unreadable.
pub fn stat(path: &str) -> Result<Stat, i32> {
    let mut buf = [0u8; STAT_RECORD_LEN];
    let errno = unsafe {
        mc_sys_stat(
            path.as_ptr() as i32,
            path.len() as i32,
            buf.as_mut_ptr() as i32,
        )
    };
    if errno != 0 {
        return Err(errno);
    }
    Ok(parse_stat(&buf))
}

/// Stat `path` WITHOUT following a trailing symlink (reports the link itself).
pub fn lstat(path: &str) -> Result<Stat, i32> {
    let mut buf = [0u8; STAT_RECORD_LEN];
    let errno = unsafe {
        mc_sys_lstat(
            path.as_ptr() as i32,
            path.len() as i32,
            buf.as_mut_ptr() as i32,
        )
    };
    if errno != 0 {
        return Err(errno);
    }
    Ok(parse_stat(&buf))
}

/// Create a symbolic link at `link` whose target text is `target` (stored
/// verbatim; not resolved by the call).
pub fn symlink(target: &str, link: &str) -> Result<(), i32> {
    errno_to_result(unsafe {
        mc_sys_symlink(
            target.as_ptr() as i32,
            target.len() as i32,
            link.as_ptr() as i32,
            link.len() as i32,
        )
    })
}

/// Set the permission bits of `path` (POSIX `chmod`). Single subject, so only the
/// owner triad is enforced; `mode` is the usual octal (e.g. `0o755`). Requires the
/// write capability (`Err(EPERM)` otherwise); `Err(EACCES)` if a directory in the
/// path denies it.
pub fn chmod(path: &str, mode: u16) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_chmod(path.as_ptr() as i32, path.len() as i32, mode as i32) })
}

/// Set the access and modify times of `path` (POSIX `utimes`), each in ms since
/// the Unix epoch. `None` sets both to the current wall-clock time.
pub fn utimes(path: &str, times: Option<(i64, i64)>) -> Result<(), i32> {
    match times {
        None => {
            errno_to_result(unsafe { mc_sys_utimes(path.as_ptr() as i32, path.len() as i32, 0) })
        }
        Some((atime, mtime)) => {
            let mut buf = [0u8; 16];
            buf[0..8].copy_from_slice(&atime.to_le_bytes());
            buf[8..16].copy_from_slice(&mtime.to_le_bytes());
            errno_to_result(unsafe {
                mc_sys_utimes(path.as_ptr() as i32, path.len() as i32, buf.as_ptr() as i32)
            })
        }
    }
}

/// Create a hard link `new` referring to the same node as `existing`.
pub fn link(existing: &str, new: &str) -> Result<(), i32> {
    errno_to_result(unsafe {
        mc_sys_link(
            existing.as_ptr() as i32,
            existing.len() as i32,
            new.as_ptr() as i32,
            new.len() as i32,
        )
    })
}

/// Read the target text of the symlink at `path` into `buf` (no trailing NUL);
/// returns the target's full length (which may exceed `buf.len()`). `EINVAL` when
/// `path` is not a symlink.
pub fn readlink(path: &str, buf: &mut [u8]) -> Result<usize, i32> {
    let mut total: u32 = 0;
    let errno = unsafe {
        mc_sys_readlink(
            path.as_ptr() as i32,
            path.len() as i32,
            buf.as_mut_ptr() as i32,
            buf.len() as i32,
            (&mut total as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(total as usize)
    }
}

/// List `path`'s entries into `buf` as NUL-separated names; returns the number of
/// bytes written (clamped to `buf.len()`). Iterate with
/// `buf[..n].split(|&b| b == 0)`.
pub fn readdir(path: &str, buf: &mut [u8]) -> Result<usize, i32> {
    let mut total: u32 = 0;
    let errno = unsafe {
        mc_sys_readdir(
            path.as_ptr() as i32,
            path.len() as i32,
            buf.as_mut_ptr() as i32,
            buf.len() as i32,
            (&mut total as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok((total as usize).min(buf.len()))
    }
}

/// Create directory `path`.
pub fn mkdir(path: &str) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_mkdir(path.as_ptr() as i32, path.len() as i32) })
}

/// Remove file or empty directory `path`.
pub fn unlink(path: &str) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_unlink(path.as_ptr() as i32, path.len() as i32) })
}

/// Rename `from` → `to`.
pub fn rename(from: &str, to: &str) -> Result<(), i32> {
    errno_to_result(unsafe {
        mc_sys_rename(
            from.as_ptr() as i32,
            from.len() as i32,
            to.as_ptr() as i32,
            to.len() as i32,
        )
    })
}

/// Remove directory `path` (must be empty). A convenience over [`unlink`], which
/// already removes empty directories.
pub fn rmdir(path: &str) -> Result<(), i32> {
    unlink(path)
}

/// Duplicate `old_fd` onto `new_fd` (closing `new_fd` first).
pub fn dup2(old_fd: i32, new_fd: i32) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_dup2(old_fd, new_fd) })
}

/// Copy this task's current working directory into `buf`; returns the byte length
/// written. `EINVAL` if `buf` is too small for the full path.
pub fn getcwd(buf: &mut [u8]) -> Result<usize, i32> {
    let mut ret_len: u32 = 0;
    let errno = unsafe {
        mc_sys_getcwd(
            buf.as_mut_ptr() as i32,
            buf.len() as i32,
            (&mut ret_len as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok((ret_len as usize).min(buf.len()))
    }
}

/// Change this task's current working directory to `path` (must be a directory; an
/// isolated task may not escape its confinement root).
pub fn chdir(path: &str) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_chdir(path.as_ptr() as i32, path.len() as i32) })
}

/// Bind (alias) the `old` path subtree onto `new` in THIS process's namespace
/// (Plan 9 `bind`). The change is private to this process and its future children.
/// An isolated task may not bind across its confinement root.
pub fn bind(old: &str, new: &str) -> Result<(), i32> {
    errno_to_result(unsafe {
        mc_sys_bind(
            old.as_ptr() as i32,
            old.len() as i32,
            new.as_ptr() as i32,
            new.len() as i32,
        )
    })
}

/// Detach a mount/bind at `path` from THIS process's namespace. Busy if a child
/// mount exists under it.
pub fn unmount(path: &str) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_unmount(path.as_ptr() as i32, path.len() as i32) })
}

// ---- signals / job control ----

/// Send signal `sig` to `pid` (`> 0`), to process group `|pid|` (`< 0`), or to the
/// caller's own group (`0`). `sig == 0` is an existence probe. Numbers are the
/// `SIG*` constants re-exported from the shared constants.
pub fn kill(pid: i32, sig: i32) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_kill(pid, sig) })
}

/// Set this process's disposition for `sig` to default (`SIG_DFL`) or ignore
/// (`SIG_IGN`). There are no async handlers — these are the two dispositions.
pub fn sigdisp(sig: i32, disp: i32) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_sigdisp(sig, disp) })
}

/// Put `pid` (`0` ⇒ self) into process group `pgid` (`0` ⇒ a new group led by
/// `pid`). Used by the shell to place a job in its own group for job control.
pub fn setpgid(pid: i32, pgid: i32) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_setpgid(pid, pgid) })
}

/// Make `pgid` the terminal's foreground process group, so Ctrl-C / Ctrl-Z reach
/// it instead of the shell.
pub fn tcsetpgrp(pgid: i32) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_tcsetpgrp(pgid) })
}

/// Adjust this process's scheduling niceness by `inc` (clamped to `-20..=19`);
/// returns the resulting value. Higher = lower priority; inherited across spawn.
pub fn nice(inc: i32) -> Result<i32, i32> {
    let mut val: u32 = 0;
    let errno = unsafe { mc_sys_nice(inc, (&mut val as *mut u32) as i32) };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(val as i32)
    }
}

/// True iff `fd` is connected to the terminal (not a pipe or file).
pub fn isatty(fd: i32) -> bool {
    let mut r: u32 = 0;
    unsafe {
        mc_sys_isatty(fd, (&mut r as *mut u32) as i32);
    }
    r != 0
}

/// Become the file server for the subtree `path` (Plan 9 mount-a-guest). Returns a
/// control fd to drive with [`serve_recv`] / [`serve_respond`]. Tasks this process
/// later spawns reach the served tree.
pub fn serve(path: &str) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_serve(
            path.as_ptr() as i32,
            path.len() as i32,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

/// Receive the next request for a served filesystem (blocks until one arrives).
/// Writes the request into `buf` as `[req_id: u32][caller: u32][op: u32]
/// [path_len: u32][path…][arg_len: u32][arg…]` (little-endian) and returns its byte
/// length. Decode it with [`parse_serve_request`]; answer with [`serve_respond`].
pub fn serve_recv(fd: i32, buf: &mut [u8]) -> Result<usize, i32> {
    let mut len: u32 = 0;
    let errno = unsafe {
        mc_sys_serve_recv(
            fd,
            buf.as_mut_ptr() as i32,
            buf.len() as i32,
            (&mut len as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(len as usize)
    }
}

/// Answer a served-filesystem request. `status` is a WASI-style errno (`0` = ok,
/// e.g. [`ENOENT`] to report a missing path); `data` is op-specific payload: the
/// file content for [`SERVE_OP_OPEN`], typed `[kind][len][name]` records for
/// [`SERVE_OP_READDIR`] (see [`push_serve_dirent`]), one [`STAT_RECORD_LEN`] stat
/// record for [`SERVE_OP_STAT`] (see [`encode_stat`]), and unused (`&[]`) for the
/// mutating ops.
pub fn serve_respond(fd: i32, req_id: u32, status: i32, data: &[u8]) -> Result<(), i32> {
    errno_to_result(unsafe {
        mc_sys_serve_respond(
            fd,
            req_id as i32,
            status,
            data.as_ptr() as i32,
            data.len() as i32,
        )
    })
}

/// A request delivered to a file server, parsed from a [`serve_recv`] buffer by
/// [`parse_serve_request`]. `op` is one of the `SERVE_OP_*` constants; `arg` is the
/// secondary path (the [`SERVE_OP_RENAME`] target), empty for every other op.
pub struct ServeRequest<'a> {
    pub id: u32,
    pub caller: u32,
    pub op: u32,
    pub path: &'a str,
    pub arg: &'a str,
}

/// Parse a [`serve_recv`] buffer — `[req_id: u32][caller: u32][op: u32]
/// [path_len: u32][path…][arg_len: u32][arg…]` (little-endian) — into a
/// [`ServeRequest`] borrowing from `buf`. Returns `None` if the bytes are
/// truncated/malformed or a path is not valid UTF-8.
pub fn parse_serve_request(buf: &[u8]) -> Option<ServeRequest<'_>> {
    let u32_at = |off: usize| -> Option<u32> {
        let end = off.checked_add(4)?;
        buf.get(off..end)
            .map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    };
    let id = u32_at(0)?;
    let caller = u32_at(4)?;
    let op = u32_at(8)?;
    let path_len = u32_at(12)? as usize;
    let path_end = 16usize.checked_add(path_len)?;
    let path = core::str::from_utf8(buf.get(16..path_end)?).ok()?;
    let arg_len = u32_at(path_end)? as usize;
    let arg_start = path_end.checked_add(4)?;
    let arg_end = arg_start.checked_add(arg_len)?;
    let arg = core::str::from_utf8(buf.get(arg_start..arg_end)?).ok()?;
    Some(ServeRequest {
        id,
        caller,
        op,
        path,
        arg,
    })
}

/// Reposition `fd`'s offset. `whence` is [`SEEK_SET`], [`SEEK_CUR`], or
/// [`SEEK_END`]; returns the resulting absolute offset. Only regular file fds are
/// seekable.
pub fn lseek(fd: i32, offset: i64, whence: i32) -> Result<u64, i32> {
    // `off` is the in/out i64 the kernel reads the request from and writes the
    // result back into (keeps the wire ABI all-i32).
    let mut off = offset;
    let errno = unsafe { mc_sys_lseek(fd, (&mut off as *mut i64) as i32, whence) };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(off as u64)
    }
}

/// Set `fd`'s file to `size` bytes (zero-extending on grow, dropping the tail on
/// shrink). The `u64` size is split into two `u32` halves on the wire.
pub fn ftruncate(fd: i32, size: u64) -> Result<(), i32> {
    let lo = (size & 0xffff_ffff) as i32;
    let hi = (size >> 32) as i32;
    errno_to_result(unsafe { mc_sys_ftruncate(fd, lo, hi) })
}

/// Cooperatively sleep for at least `ms` milliseconds (no-op for `ms <= 0`).
pub fn sleep_ms(ms: i32) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_sleep_ms(ms) })
}

/// One entry for [`poll`]. The layout (`fd` i32, `events`/`revents` i16) is the
/// exact 8-byte wire struct the kernel reads — `#[repr(C)]` pins it. Build with
/// [`PollFd::new`], set `events` to a mask of [`POLLIN`]/[`POLLOUT`] (cast to
/// `i16`), and read the satisfied mask back from `revents` after `poll`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PollFd {
    pub fd: i32,
    pub events: i16,
    pub revents: i16,
}

impl PollFd {
    pub fn new(fd: i32, events: i16) -> Self {
        Self {
            fd,
            events,
            revents: 0,
        }
    }
    /// Was `bit` (e.g. `POLLIN as i16`) set in the last `poll`'s result?
    pub fn ready(&self, bit: i16) -> bool {
        self.revents & bit != 0
    }
}

/// Wait until one or more `fds` is ready or `timeout_ms` elapses (`0` =
/// non-blocking, [`POLL_BLOCK`] = block indefinitely). Returns the number of fds
/// with a non-zero `revents`; inspect each entry's `revents` (or [`PollFd::ready`])
/// to see which events fired.
pub fn poll(fds: &mut [PollFd], timeout_ms: i32) -> Result<usize, i32> {
    let mut ready: u32 = 0;
    let errno = unsafe {
        mc_sys_poll(
            fds.as_mut_ptr() as i32,
            fds.len() as i32,
            timeout_ms,
            (&mut ready as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(ready as usize)
    }
}

/// Monotonic milliseconds since boot. `Err(EPERM)` if the ambient capability
/// (`CAP_AMBIENT`) was dropped at exec — a denied clock is reported, not silently
/// returned as `0` (A9 default-deny: absence of authority is an error, not a
/// fabricated zero).
pub fn time_monotonic() -> Result<i64, i32> {
    let mut v: i64 = 0;
    let errno = unsafe { mc_sys_time_monotonic((&mut v as *mut i64) as i32) };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(v)
    }
}

/// Wall-clock milliseconds since the Unix epoch (1970-01-01 UTC). Unlike
/// [`time_monotonic`] this is absolute and may jump (NTP) — it is what `date`
/// reports. Same `CAP_AMBIENT` gate: `Err(EPERM)` if the ambient capability was
/// dropped at exec.
pub fn time_realtime() -> Result<i64, i32> {
    let mut v: i64 = 0;
    let errno = unsafe { mc_sys_time_realtime((&mut v as *mut i64) as i32) };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(v)
    }
}

/// Fill `buf` with cryptographically secure random bytes. Requires `CAP_AMBIENT`
/// (entropy is a nondeterminism source).
pub fn random(buf: &mut [u8]) -> Result<(), i32> {
    errno_to_result(unsafe { mc_sys_random(buf.as_mut_ptr() as i32, buf.len() as i32) })
}

fn errno_to_result(errno: i32) -> Result<(), i32> {
    if errno != 0 {
        Err(errno)
    } else {
        Ok(())
    }
}

/// Open an HTTP GET for `url`, returning a readable fd for the response body.
/// `Err(EPERM)` if the network capability is unavailable.
pub fn http_get(url: &str) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_http_get(
            url.as_ptr() as i32,
            url.len() as i32,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

/// Open an arbitrary HTTP request, returning a readable fd for the response body.
/// `req` is the serialized blob `METHOD URL\n<headers>\n\n<body>` (the same format
/// the host parses). `Err(EPERM)` if the network capability is unavailable. This is
/// the general form of [`http_get`].
pub fn http_request(req: &[u8]) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_http_request(
            req.as_ptr() as i32,
            req.len() as i32,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

/// Invoke a host-resident function (`mc_sys_host_call`) — the `mc-tool` shim and
/// host-backed mounts. `req` is an opaque blob the host routes to a registered
/// handler; the returned fd streams the result back (read it like any file).
/// Requires `CAP_NET` (a host call is host-terminated egress).
pub fn host_call(req: &[u8]) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_host_call(
            req.as_ptr() as i32,
            req.len() as i32,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

// ── resident services (typed cross-guest calls) ──────────────────────────────

/// Register this guest as the resident service `name` (authorized by the kernel's
/// activation grant — the task it spawned for `name`). Returns a control fd to drive
/// with [`svc_recv`] / [`svc_respond`]. `Err(EPERM)` if not the granted task.
pub fn svc_serve(name: &str) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_svc_serve(
            name.as_ptr() as i32,
            name.len() as i32,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

/// Receive the next service inbound (blocks until one arrives). Writes the envelope
/// `[kind: u8][nhandles: u8][session: u32][req_id: u32][blob_len: u32][blob…]` (little-endian) into
/// `buf` and any delegated fd numbers into `hbuf`, returning the envelope byte length; decode with
/// [`parse_svc_request`], answer a call with [`svc_respond`]. Pass an empty `hbuf` if the service
/// accepts no delegated handles.
pub fn svc_recv(fd: i32, buf: &mut [u8], hbuf: &mut [i32]) -> Result<usize, i32> {
    let mut len: u32 = 0;
    let errno = unsafe {
        mc_sys_svc_recv(
            fd,
            buf.as_mut_ptr() as i32,
            buf.len() as i32,
            hbuf.as_mut_ptr() as i32,
            (hbuf.len() * 4) as i32,
            (&mut len as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(len as usize)
    }
}

/// Answer service call `(session, req_id)`. `status` 0 = ok (the client drains `data`
/// from its result fd); nonzero = a transport errno surfaced to the client read.
/// Application results (rows, errors) ride inside `data` per the service's protocol.
pub fn svc_respond(
    fd: i32,
    session: u32,
    req_id: u32,
    status: i32,
    data: &[u8],
) -> Result<(), i32> {
    errno_to_result(unsafe {
        mc_sys_svc_respond(
            fd,
            session as i32,
            req_id as i32,
            status,
            data.as_ptr() as i32,
            data.len() as i32,
        )
    })
}

/// Open a session to the resident service `name`. Returns a connection fd to drive
/// with [`svc_call`]. `Err(ENOENT)` if no such service is registered.
pub fn svc_connect(name: &str) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_svc_connect(
            name.as_ptr() as i32,
            name.len() as i32,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

/// Send a typed request on a service connection, optionally delegating `handles` (fd numbers — only
/// `File`/`PipeRead`/`PipeWrite` may travel; SERVICES.md §3.4). Pass `&[]` to delegate nothing. Returns
/// a readable result fd that streams the service's response — read it like any file, then [`close`] it.
pub fn svc_call(fd: i32, req: &[u8], handles: &[i32]) -> Result<i32, i32> {
    let mut ret: u32 = 0;
    let errno = unsafe {
        mc_sys_svc_call(
            fd,
            req.as_ptr() as i32,
            req.len() as i32,
            handles.as_ptr() as i32,
            handles.len() as i32,
            (&mut ret as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(ret as i32)
    }
}

/// The kind of inbound [`parse_svc_request`] decoded: a typed call to answer, or a notification that a
/// session closed (its client went away) so the service can free that session's own warm state.
#[derive(PartialEq, Eq, Clone, Copy)]
pub enum SvcKind {
    Call,
    SessionClosed,
}

/// An inbound delivered to a resident service, parsed from a [`svc_recv`] buffer by
/// [`parse_svc_request`]. A [`SvcKind::SessionClosed`] tombstone needs no answer; its `req_id`/`blob`
/// are empty.
pub struct SvcRequest<'a> {
    pub kind: SvcKind,
    pub session: u32,
    pub req_id: u32,
    pub blob: &'a [u8],
    /// Delegated fd numbers installed in this service's fd table (SERVICES.md §3.4), or empty.
    pub handles: &'a [i32],
}

/// Parse a [`svc_recv`] envelope —
/// `[kind: u8][nhandles: u8][session: u32][req_id: u32][blob_len: u32][blob…]` — plus the companion
/// handle buffer `hbuf`. `None` if too short, truncated, or an unknown kind.
pub fn parse_svc_request<'a>(buf: &'a [u8], hbuf: &'a [i32]) -> Option<SvcRequest<'a>> {
    if buf.len() < 14 {
        return None;
    }
    let kind = match buf[0] {
        0 => SvcKind::Call,
        1 => SvcKind::SessionClosed,
        _ => return None,
    };
    let nhandles = buf[1] as usize;
    let session = u32::from_le_bytes([buf[2], buf[3], buf[4], buf[5]]);
    let req_id = u32::from_le_bytes([buf[6], buf[7], buf[8], buf[9]]);
    let blob_len = u32::from_le_bytes([buf[10], buf[11], buf[12], buf[13]]) as usize;
    let blob = buf.get(14..14 + blob_len)?;
    let handles = hbuf.get(..nhandles)?;
    Some(SvcRequest {
        kind,
        session,
        req_id,
        blob,
        handles,
    })
}

/// Report the HTTP status of a response-body fd (from [`http_get`] or
/// [`http_request`]). Blocks until the response head has arrived. `Err(EIO)` on a
/// transport failure, `Err(EBADF)` if `fd` is not an HTTP fd.
pub fn http_status(fd: i32) -> Result<u16, i32> {
    let mut status: u32 = 0;
    let errno = unsafe { mc_sys_http_status(fd, (&mut status as *mut u32) as i32) };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(status as u16)
    }
}

/// Open a WebSocket to `url` (`ws://`/`wss://`), returning a bidirectional fd:
/// [`read`] receives one message, [`write_all`] sends one, [`poll`] reports
/// readiness. `Err(EPERM)` if the network capability is unavailable.
pub fn ws_open(url: &str) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_ws_open(
            url.as_ptr() as i32,
            url.len() as i32,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

/// The syscall ABI version as `(major, minor)`.
pub fn abi_version() -> (u16, u16) {
    let mut v: u32 = 0;
    unsafe {
        mc_sys_abi_version((&mut v as *mut u32) as i32);
    }
    ((v >> 16) as u16, (v & 0xffff) as u16)
}

/// Read up to `buf.len()` bytes from `fd`. `Ok(0)` is EOF.
pub fn read(fd: i32, buf: &mut [u8]) -> Result<usize, i32> {
    let mut n: u32 = 0;
    let errno = unsafe {
        mc_sys_read(
            fd,
            buf.as_mut_ptr() as i32,
            buf.len() as i32,
            (&mut n as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(n as usize)
    }
}

/// Write up to `buf.len()` bytes to `fd`, returning the count actually accepted
/// (which may be short). Prefer [`write_all`] when every byte must land.
pub fn write(fd: i32, buf: &[u8]) -> Result<usize, i32> {
    let mut n: u32 = 0;
    let errno = unsafe {
        mc_sys_write(
            fd,
            buf.as_ptr() as i32,
            buf.len() as i32,
            (&mut n as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(n as usize)
    }
}

/// Open `path`, returning a file descriptor.
pub fn open(path: &str, flags: i32) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let errno = unsafe {
        mc_sys_open(
            path.as_ptr() as i32,
            path.len() as i32,
            flags,
            (&mut fd as *mut u32) as i32,
        )
    };
    if errno != 0 {
        Err(errno)
    } else {
        Ok(fd as i32)
    }
}

/// Close a file descriptor.
pub fn close(fd: i32) {
    unsafe {
        mc_sys_close(fd);
    }
}

/// Fill `buf` with the NUL-separated argument vector; returns the number of bytes
/// written (clamped to `buf.len()`). Iterate with `buf[..n].split(|&b| b == 0)`.
pub fn args_into(buf: &mut [u8]) -> usize {
    let mut total: u32 = 0;
    let _ = unsafe {
        mc_sys_args(
            buf.as_mut_ptr() as i32,
            buf.len() as i32,
            (&mut total as *mut u32) as i32,
        )
    };
    (total as usize).min(buf.len())
}

/// Write all of `buf` to `fd`. `Err(errno)` on failure.
pub fn write_all(fd: i32, buf: &[u8]) -> Result<(), i32> {
    let mut off = 0usize;
    while off < buf.len() {
        let mut n: u32 = 0;
        let errno = unsafe {
            mc_sys_write(
                fd,
                buf[off..].as_ptr() as i32,
                (buf.len() - off) as i32,
                (&mut n as *mut u32) as i32,
            )
        };
        if errno != 0 {
            return Err(errno);
        }
        if n == 0 {
            return Err(1);
        }
        off += n as usize;
    }
    Ok(())
}

/// Write a string to stdout (best effort).
pub fn print(s: &str) {
    let _ = write_all(STDOUT, s.as_bytes());
}

/// Write a string to stderr (best effort).
pub fn eprint(s: &str) {
    let _ = write_all(STDERR, s.as_bytes());
}

/// Write raw bytes to stderr (best effort) — for echoing a path argument straight
/// from `argv` without a UTF-8 round-trip.
pub fn eprint_bytes(b: &[u8]) {
    let _ = write_all(STDERR, b);
}

/// Print `text` to stdout and exit 0 — the canonical answer to `--help`/`-h`. Help
/// is requested output, not an error, so it goes to **stdout** with a **success**
/// exit (mirroring clap and `--help` everywhere). Allocation-free, so even the
/// no-heap coreutils can use it. A guest wires this in as the very first thing
/// `main` does, before parsing or any I/O — so help is side-effect-free even for
/// tools like `agent`/`nohup`:
///
/// ```ignore
/// if rt::wants_help(&argbuf[..n], true) { rt::emit_help(HELP); }
/// ```
pub fn emit_help(text: &str) -> ! {
    print(text);
    exit(0)
}

/// Whether argv (a NUL-separated buffer from [`args_into`]) requests help: a long
/// `--help` (always), or a bare `-h` when `h_is_help` is true — pass `false` for
/// the few tools where `-h` is itself a real option (`sort`/`ls`, and `grep` among
/// the WASI tools). Scans the operands after argv[0] and stops at `--`, so
/// `rm -- --help` treats `--help` as a filename (POSIX). Allocation-free.
pub fn wants_help(argbuf: &[u8], h_is_help: bool) -> bool {
    for tok in argv_tokens(argbuf).skip(1) {
        if tok == b"--" {
            break;
        }
        if tok == b"--help" || (h_is_help && tok == b"-h") {
            return true;
        }
    }
    false
}

/// Like [`wants_help`] but only the FIRST operand (argv[1]) counts — for tools
/// whose other arguments are taken literally (`echo`, `printf`, `yes`, `test`/`[`),
/// so `echo --help` prints help while `echo x --help` prints `x --help` (matching
/// GNU `/bin/echo`). Allocation-free.
pub fn wants_help_first(argbuf: &[u8], h_is_help: bool) -> bool {
    match argv_tokens(argbuf).nth(1) {
        Some(tok) => tok == b"--help" || (h_is_help && tok == b"-h"),
        None => false,
    }
}

/// Iterate the NUL-separated args in `buf`, dropping the trailing terminator while
/// preserving interior empty operands (the kernel NUL-terminates every arg, so the
/// arg count equals the NUL count). Lets alloc-free guests scan argv without a
/// higher-level argv library.
fn argv_tokens(buf: &[u8]) -> impl Iterator<Item = &[u8]> + '_ {
    let nargs = buf.iter().filter(|&&b| b == 0).count();
    buf.split(|&b| b == 0).take(nargs)
}

/// A human message for a syscall errno, matching the kernel's filesystem wording so
/// guest coreutils report errors the way native builtins do.
pub fn strerror(errno: i32) -> &'static str {
    match errno {
        ENOENT => "No such file or directory",
        EEXIST => "File exists",
        ENOTDIR => "Not a directory",
        EISDIR => "Is a directory",
        EPERM => "Permission denied",
        EACCES => "Permission denied",
        EINVAL => "Invalid path",
        ENOTEMPTY => "Directory not empty",
        EIO => "I/O error",
        EBADF => "Bad file descriptor",
        ENOSYS => "Not implemented",
        EMFILE => "Too many open files",
        ELOOP => "Too many levels of symbolic links",
        _ => "error",
    }
}

/// Terminate with `code`. Never returns.
pub fn exit(code: i32) -> ! {
    // `mc_sys_exit` returns `i32` for ABI uniformity but never actually returns —
    // the kernel suspends the guest on exit and never resumes it.
    let _ = unsafe { mc_sys_exit(code) };
    loop {}
}

// A standalone no_std guest (wasm32-unknown) needs this panic handler. A coreutils box (§16.3)
// is std-on-wasi — std already provides `panic_impl` there — so suppress ours under wasi to
// avoid a duplicate lang item. The box still reaches the mc wrappers below; only the runtime
// item differs.
#[cfg(not(target_os = "wasi"))]
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    eprint("guest panic\n");
    exit(134)
}

/// Define a program: exports `_start`, runs `$main`, then exits 0.
#[macro_export]
macro_rules! entry {
    ($main:ident) => {
        #[no_mangle]
        pub extern "C" fn _start() {
            $main();
            $crate::exit(0);
        }
    };
}

/// Declare this program's **capability tier**. The kernel reads it from a `mc_tier`
/// custom section at load time and grants the program `parent_caps ∩ tier` — a
/// binary can only ever narrow, never widen, the privilege of whoever ran it (A9
/// default-deny). Valid values: `"full"`, `"read-write"`, `"read-only"`,
/// `"isolated"`. A program with no declaration inherits its parent's capabilities
/// unchanged.
///
/// The section name and payload (the raw UTF-8 tier string) are the load-time
/// contract: changing either here means changing what the kernel parses at exec.
#[macro_export]
macro_rules! declare_tier {
    ($tier:literal) => {
        #[link_section = "mc_tier"]
        #[used]
        static MC_TIER: [u8; $tier.len()] = {
            let src = $tier.as_bytes();
            let mut out = [0u8; $tier.len()];
            let mut i = 0;
            while i < out.len() {
                out[i] = src[i];
                i += 1;
            }
            out
        };
    };
}

/// Declare this program's **resource budget** (the `mc_budget` runtime contract):
/// `mem_bytes`, lifetime `fuel`, and `table` elements. The kernel reads it from an
/// `mc_budget` custom section at load time and confines the guest to
/// `min(declared, vm_ceiling, hard)`. A program with no declaration gets the
/// default budget. Payload: `[u32 version=1][u64 mem][u64 fuel][u32 table]`
/// (little-endian, 24 bytes) — this layout is the load-time contract with the
/// kernel's budget parser.
#[macro_export]
macro_rules! declare_budget {
    ($mem_bytes:expr, $fuel:expr, $table:expr) => {
        #[link_section = "mc_budget"]
        #[used]
        static MC_BUDGET: [u8; 24] = {
            let mem: u64 = $mem_bytes;
            let fuel: u64 = $fuel;
            let table: u32 = $table;
            let mut out = [0u8; 24];
            out[0] = 1; // version (LE u32, low byte)
            let mb = mem.to_le_bytes();
            let fb = fuel.to_le_bytes();
            let tb = table.to_le_bytes();
            let mut i = 0;
            while i < 8 {
                out[4 + i] = mb[i];
                out[12 + i] = fb[i];
                i += 1;
            }
            let mut k = 0;
            while k < 4 {
                out[20 + k] = tb[k];
                k += 1;
            }
            out
        };
    };
}

/// Declare this program's **service name** — that it is a resident service answering `svc_serve`
/// for this name. The kernel/attestor reads it from an `mc_service` custom section, stamped exactly
/// like `mc_tier`/`mc_budget` (VISION §6: service-capability is a *property*, not a second artifact).
/// A binary that imports `svc_serve` MUST declare this — `mc-attest` fails the build otherwise — and
/// the kernel grants it to serve only this name. The one-binary/two-modes service declares it
/// unconditionally; whether it enters the serve loop or the CLI path is decided at runtime by argv.
///
/// The section name and payload (the raw UTF-8 service name) are the load-time contract, mirroring
/// what `//tools/mc-stamp --service` appends for the zig/C++ service tools.
#[macro_export]
macro_rules! declare_service {
    ($name:literal) => {
        #[link_section = "mc_service"]
        #[used]
        static MC_SERVICE: [u8; $name.len()] = {
            let src = $name.as_bytes();
            let mut out = [0u8; $name.len()];
            let mut i = 0;
            while i < out.len() {
                out[i] = src[i];
                i += 1;
            }
            out
        };
    };
}
