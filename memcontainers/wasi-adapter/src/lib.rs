//! `wasi` — a guest-side **WASI preview1 adapter** implemented over the `mc_sys_*`
//! syscall ABI.
//!
//! ## Why this exists
//!
//! We want the `wasm32-wasip1` tool ecosystem (grep, jq, … eventually git) without
//! teaching the kernel a second ABI. The leverage move is to **convert** each WASI
//! binary into a pure-`mc` guest: this crate **defines** the `wasi_snapshot_preview1`
//! functions, and the build pipeline **link-injects** it into a tool so its
//! definitions override wasi-libc's imports. The converted module then imports only
//! `mc.*` and is indistinguishable from a hand-written guest — the kernel,
//! conformance checker, and capability/tier model are untouched. See
//! `project_wasi_conversion_architecture`.
//!
//! ## How it works
//!
//! The adapter is linked *into* the tool, so it runs in the tool's own linear
//! memory: a guest pointer (a wasm `i32`) is a real, dereferenceable address here.
//! That removes all marshalling — `fd_write`'s iovecs are read straight from memory.
//!
//! WASI is capability-oriented (no ambient cwd; paths are opened relative to a
//! *preopened* directory fd). We advertise ONE preopen that Rust std discovers at
//! startup: fd 3 = `"/"` — it covers the whole mc filesystem, so wasi-libc resolves
//! every path (absolute, or relative to its cwd) against it. (fd 4 / PRE_CWD is handled
//! by `base_for`/`resolve` for an explicit cwd-relative dirfd, but is NOT advertised via
//! `fd_prestat` — a "." preopen breaks wasi-libc's path resolution for std guests.)
//! `path_open` resolves the WASI (dirfd, relative-path) pair to an absolute mc path and
//! calls `mc_sys_open` /
//! `mc_sys_mkdir` / … The mc errno table is itself WASI-style (`abi` was seeded from
//! wasi-ext), so errnos pass straight through.
//!
//! `args_*` are the one outlier: Rust std binds them to a hash-mangled symbol from
//! its bundled `wasi` crate rather than the stable `__imported_*` convention used by
//! everything else. So the real implementation lives here as the canonical
//! [`mc_wasi_args_get`] / [`mc_wasi_args_sizes_get`], and the build pipeline emits a
//! tiny trampoline that binds whatever mangled symbol a given toolchain uses to
//! these. (We also define the `__imported_*` form, in case a toolchain uses it.)

#![no_std]
#![allow(clippy::missing_safety_doc)]

// Pull in the mc constants (errnos, O_*/SEEK_* flags) + the canonical `mc_sys_*` import block,
// both projected from the one contract the kernel and sysroot also derive from — so names and
// arities can't drift (B2). We depend on the dependency-free generated bindings
// (//contracts:constants_rust for the constants, //contracts:mc_rust for the syscall table)
// rather than //sysroot, whose `#[panic_handler]` would collide with the tool's std at link
// time. The local WASI `O_TRUNC` bit (an oflag we detect) deliberately shadows the unused mc
// `O_TRUNC` this glob also brings.
use constants_rust::*;

// In the `standalone` build (the C/Zig conversion lane — e.g. `sqlite3` — links
// the adapter as a self-contained staticlib with no surrounding Rust runtime) the
// adapter must supply the panic handler itself. The default object-injection lane
// leaves this OFF: the host Rust tool's std already provides one, and a second
// would collide at link time (see the note above and the `standalone` feature).
#[cfg(feature = "standalone")]
#[panic_handler]
fn mc_adapter_panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

macro_rules! mc_externs {
    ( $( $ident:ident => $Variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        // The block mirrors the WHOLE contract for fidelity with the kernel; the adapter calls
        // only a subset, and the wasm ABI passes every arg/result as i32 — so the arg types and
        // the [$ret] tag are matched but ignored (matches the sysroot's `mc_guest_externs`).
        #[link(wasm_import_module = "mc")]
        unsafe extern "C" {
            $( #[allow(dead_code)] fn $ident($($arg: i32),*) -> i32; )*
        }
    };
}
mc_rust::mc_syscall_table!(mc_externs);

// ---------------------------------------------------------------------------
// Guest-memory access. The adapter shares the tool's linear memory, so a WASI
// pointer argument (`u32`/`i32`) is a native address.
// ---------------------------------------------------------------------------

#[inline]
unsafe fn wr_u8(p: i32, v: u8) {
    *(p as *mut u8) = v;
}
#[inline]
unsafe fn wr_u16(p: i32, v: u16) {
    (p as *mut u16).write_unaligned(v);
}
#[inline]
unsafe fn wr_u32(p: i32, v: u32) {
    (p as *mut u32).write_unaligned(v);
}
#[inline]
unsafe fn wr_u64(p: i32, v: u64) {
    (p as *mut u64).write_unaligned(v);
}
#[inline]
unsafe fn rd_u32(p: i32) -> u32 {
    (p as *const u32).read_unaligned()
}
#[inline]
unsafe fn rd_u64(p: i32) -> u64 {
    (p as *const u64).read_unaligned()
}
#[inline]
unsafe fn rd_u8(p: i32) -> u8 {
    *(p as *const u8)
}
#[inline]
unsafe fn bytes<'a>(ptr: i32, len: i32) -> &'a [u8] {
    core::slice::from_raw_parts(ptr as *const u8, len as usize)
}

// ---------------------------------------------------------------------------
// WASI preview1 constants we need (kept local; the crate is otherwise just `abi`).
// ---------------------------------------------------------------------------

// filetype
const FT_UNKNOWN: u8 = 0;
const FT_CHAR_DEVICE: u8 = 2;
const FT_DIRECTORY: u8 = 3;
const FT_REGULAR_FILE: u8 = 4;
const FT_SYMBOLIC_LINK: u8 = 7;

// lookupflags
const LOOKUP_SYMLINK_FOLLOW: i32 = 1 << 0;

// oflags (path_open)
const O_CREAT: i32 = 1 << 0;
const O_DIRECTORY: i32 = 1 << 1;
const O_EXCL: i32 = 1 << 2;
const O_TRUNC: i32 = 1 << 3;

// fdflags
const FD_APPEND: i32 = 1 << 0;

// rights bits we care about (to infer write intent from std's request)
const RIGHT_FD_WRITE: u64 = 1 << 6;
const RIGHT_FD_READ: u64 = 1 << 1;

// whence matches abi SEEK_*: 0=set,1=cur,2=end.

// prestat tag
const PREOPENTYPE_DIR: u8 = 0;

// subscription / event (poll_oneoff)
const EVENTTYPE_CLOCK: u8 = 0;
const EVENTTYPE_FD_READ: u8 = 1;
const EVENTTYPE_FD_WRITE: u8 = 2;

// struct sizes (preview1 ABI)
const DIRENT_SIZE: usize = 24; // d_next u64, d_ino u64, d_namlen u32, d_type u8 (+pad)
const FILESTAT_SIZE: usize = 64;
const FDSTAT_SIZE: usize = 24;

// Preopen fds. Rust std scans upward from 3 via `fd_prestat_get` until EBADF.
const PRE_ROOT: i32 = 3; // "/"
const PRE_CWD: i32 = 4; // "."
const FD_TABLE_BASE: i32 = 5; // adapter-allocated fds start here

const PATH_MAX: usize = 1024;
const MAX_FDS: usize = 96;

// ---------------------------------------------------------------------------
// FD table. WASI fds 0/1/2 are stdio (mapped to mc 0/1/2 directly); 3/4 are the
// preopens; >=5 index this table. A directory fd stores only its resolved path
// (mc readdir/open are path-based); a file fd also stores the live mc fd.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
struct Entry {
    used: bool,
    is_dir: bool,
    append: bool,
    mc_fd: i32,
    path: [u8; PATH_MAX],
    path_len: u16,
}

const EMPTY: Entry = Entry {
    used: false,
    is_dir: false,
    append: false,
    mc_fd: -1,
    path: [0; PATH_MAX],
    path_len: 0,
};

struct State {
    table: [Entry; MAX_FDS],
}

static mut STATE: State = State {
    table: [EMPTY; MAX_FDS],
};

#[inline]
fn state() -> &'static mut State {
    // Single-threaded wasm guest: no concurrent access.
    unsafe { &mut *core::ptr::addr_of_mut!(STATE) }
}

impl State {
    fn alloc(&mut self) -> Option<i32> {
        for (i, e) in self.table.iter_mut().enumerate() {
            if !e.used {
                *e = EMPTY;
                e.used = true;
                return Some(FD_TABLE_BASE + i as i32);
            }
        }
        None
    }
    fn get(&mut self, fd: i32) -> Option<&mut Entry> {
        let idx = (fd - FD_TABLE_BASE) as usize;
        if fd >= FD_TABLE_BASE && idx < MAX_FDS && self.table[idx].used {
            Some(&mut self.table[idx])
        } else {
            None
        }
    }
    fn free(&mut self, fd: i32) {
        let idx = (fd - FD_TABLE_BASE) as usize;
        if fd >= FD_TABLE_BASE && idx < MAX_FDS {
            self.table[idx].used = false;
        }
    }
}

fn set_path(e: &mut Entry, p: &[u8]) {
    let n = p.len().min(PATH_MAX);
    e.path[..n].copy_from_slice(&p[..n]);
    e.path_len = n as u16;
}

// ---------------------------------------------------------------------------
// Thin mc_sys_* helpers (errno-returning).
// ---------------------------------------------------------------------------

unsafe fn mc_open(path: &[u8], flags: i32) -> Result<i32, i32> {
    let mut fd: u32 = 0;
    let e = mc_sys_open(
        path.as_ptr() as i32,
        path.len() as i32,
        flags,
        (&mut fd as *mut u32) as i32,
    );
    if e != 0 {
        Err(e)
    } else {
        Ok(fd as i32)
    }
}

#[derive(Clone, Copy)]
struct McStat {
    size: u64,
    filetype: u8,
    nlink: u64,
    /// Times in **nanoseconds** (WASI `timestamp`), converted from the kernel's
    /// ms-since-epoch. `0` = unknown.
    atim: u64,
    mtim: u64,
    ctim: u64,
}

impl McStat {
    fn is_dir(self) -> bool {
        self.filetype == FT_DIRECTORY
    }
}

/// Decode the generated stat-record contract. WASI filestat carries no mode, and the record's
/// millisecond timestamps become nanoseconds.
fn parse_mc_stat(buf: &[u8; STAT_REC_LEN as usize]) -> McStat {
    let size_off = STAT_REC_SIZE_OFF as usize;
    let kind_off = STAT_REC_NODE_TYPE_OFF as usize;
    let nlink_off = STAT_REC_NLINK_OFF as usize;
    let size = u64::from_le_bytes(buf[size_off..size_off + 8].try_into().unwrap());
    let kind = u32::from_le_bytes(buf[kind_off..kind_off + 4].try_into().unwrap());
    let nlink = u32::from_le_bytes(buf[nlink_off..nlink_off + 4].try_into().unwrap());
    let ms_to_ns = |o: usize| {
        (i64::from_le_bytes(buf[o..o + 8].try_into().unwrap()).max(0) as u64)
            .saturating_mul(1_000_000)
    };
    let filetype = match kind {
        value if value == STAT_NODE_DIR as u32 => FT_DIRECTORY,
        value if value == STAT_NODE_SYMLINK as u32 => FT_SYMBOLIC_LINK,
        _ => FT_REGULAR_FILE,
    };
    McStat {
        size,
        filetype,
        nlink: nlink as u64,
        mtim: ms_to_ns(STAT_REC_MTIME_OFF as usize),
        atim: ms_to_ns(STAT_REC_ATIME_OFF as usize),
        ctim: ms_to_ns(STAT_REC_CTIME_OFF as usize),
    }
}

/// Metadata for a path, following a trailing symlink.
unsafe fn mc_stat(path: &[u8]) -> Result<McStat, i32> {
    let mut buf = [0u8; STAT_REC_LEN as usize];
    let e = mc_sys_stat(
        path.as_ptr() as i32,
        path.len() as i32,
        buf.as_mut_ptr() as i32,
    );
    if e != 0 {
        return Err(e);
    }
    Ok(parse_mc_stat(&buf))
}

/// Metadata for a path, without following a trailing symlink.
unsafe fn mc_lstat(path: &[u8]) -> Result<McStat, i32> {
    let mut buf = [0u8; STAT_REC_LEN as usize];
    let e = mc_sys_lstat(
        path.as_ptr() as i32,
        path.len() as i32,
        buf.as_mut_ptr() as i32,
    );
    if e != 0 {
        return Err(e);
    }
    Ok(parse_mc_stat(&buf))
}

unsafe fn mc_getcwd(buf: &mut [u8]) -> Result<usize, i32> {
    let mut n: u32 = 0;
    let e = mc_sys_getcwd(
        buf.as_mut_ptr() as i32,
        buf.len() as i32,
        (&mut n as *mut u32) as i32,
    );
    if e != 0 {
        Err(e)
    } else {
        Ok((n as usize).min(buf.len()))
    }
}

// WASI rights bits whose ABSENCE (together with a CHARACTER_DEVICE filetype)
// makes wasi-libc's `isatty()` report a tty — a terminal cannot seek or tell.
const RIGHTS_FD_SEEK: u64 = 1 << 2;
const RIGHTS_FD_TELL: u64 = 1 << 5;

/// Ask the kernel whether `fd` is the controlling terminal (`mc_sys_isatty`):
/// true for the interactive console (and its inheritors), false for a pipe,
/// file, or redirected stream. Used by `fd_fdstat_get` to shape the std-stream
/// rights so a guest's `isatty()` is correct.
unsafe fn mc_isatty(fd: i32) -> bool {
    let mut r: u32 = 0;
    let e = mc_sys_isatty(fd, (&mut r as *mut u32) as i32);
    e == 0 && r != 0
}

unsafe fn mc_readdir(path: &[u8], buf: &mut [u8]) -> Result<usize, i32> {
    let mut n: u32 = 0;
    let e = mc_sys_readdir(
        path.as_ptr() as i32,
        path.len() as i32,
        buf.as_mut_ptr() as i32,
        buf.len() as i32,
        (&mut n as *mut u32) as i32,
    );
    if e != 0 {
        Err(e)
    } else {
        Ok((n as usize).min(buf.len()))
    }
}

// ---------------------------------------------------------------------------
// Path resolution: turn a WASI (dirfd, relative path) into an absolute,
// normalized mc path. `.`/`..`/duplicate-slash segments are collapsed so the
// path-keyed kernel filesystems see clean keys.
// ---------------------------------------------------------------------------

/// Write the preopen/dir base for `dirfd` into `out`; returns its length.
unsafe fn base_for(dirfd: i32, out: &mut [u8]) -> Result<usize, i32> {
    match dirfd {
        PRE_ROOT => {
            out[0] = b'/';
            Ok(1)
        }
        PRE_CWD => mc_getcwd(out),
        _ => {
            let st = state();
            let e = st.get(dirfd).ok_or(EBADF)?;
            if !e.is_dir {
                return Err(ENOTDIR);
            }
            let n = e.path_len as usize;
            out[..n].copy_from_slice(&e.path[..n]);
            Ok(n)
        }
    }
}

/// Normalize `base` + "/" + `rel` into an absolute path in `out`. Returns length,
/// or `EINVAL`/`ENAMETOOLONG`-style errors as errnos on overflow.
fn normalize_join(base: &[u8], rel: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    // Segment-start offsets within `out` (one per surviving path component) so a
    // `..` can pop the previous one. Each component is written as "/name", so the
    // output is naturally absolute; an empty result (root, or popped to nothing)
    // is normalized to "/" at the end.
    let mut seg_starts = [0usize; 128];
    let mut nseg = 0usize;
    let mut len = 0usize;

    let mut push_segment = |seg: &[u8], len: &mut usize, nseg: &mut usize| -> Result<(), i32> {
        if seg.is_empty() || seg == b"." {
            return Ok(());
        }
        if seg == b".." {
            if *nseg > 0 {
                *nseg -= 1;
                *len = seg_starts[*nseg]; // truncate back to this component's '/'
            }
            return Ok(());
        }
        if *nseg >= seg_starts.len() {
            return Err(EINVAL);
        }
        seg_starts[*nseg] = *len; // points at the '/' we're about to write
        *nseg += 1;
        if *len + 1 + seg.len() > out.len() {
            return Err(EINVAL);
        }
        out[*len] = b'/';
        *len += 1;
        out[*len..*len + seg.len()].copy_from_slice(seg);
        *len += seg.len();
        Ok(())
    };

    for chunk in [base, rel] {
        for seg in chunk.split(|&b| b == b'/') {
            push_segment(seg, &mut len, &mut nseg)?;
        }
    }
    if len == 0 {
        // Root, or everything popped away.
        if out.is_empty() {
            return Err(EINVAL);
        }
        out[0] = b'/';
        len = 1;
    }
    Ok(len)
}

/// Resolve (dirfd, path) → absolute mc path bytes in `out`; returns length.
unsafe fn resolve(dirfd: i32, path_ptr: i32, path_len: i32, out: &mut [u8]) -> Result<usize, i32> {
    let mut base = [0u8; PATH_MAX];
    let bl = base_for(dirfd, &mut base)?;
    let rel = bytes(path_ptr, path_len);
    normalize_join(&base[..bl], rel, out)
}

// ---------------------------------------------------------------------------
// process / args / env
// ---------------------------------------------------------------------------

// WASI has no ambient cwd; wasi-libc keeps an emulated one (default "/") and
// resolves relative paths against it. The kernel, however, gives each task a real
// cwd. Bridge them: at startup — after wasi-libc has populated its preopens —
// `chdir` the tool to the kernel's cwd, so a relative path the shell passes (e.g.
// `grep foo bar.txt` from /home/user) resolves where the user expects. Registered
// in `.init_array` so `__wasm_call_ctors` runs it before `main`; plain (lowest)
// priority puts it after wasi-libc's own preopen constructor.
extern "C" {
    fn chdir(path: *const u8) -> i32;
}

extern "C" fn mc_wasi_sync_cwd() {
    unsafe {
        let mut buf = [0u8; PATH_MAX];
        if let Ok(n) = mc_getcwd(&mut buf) {
            if n > 0 && n < PATH_MAX {
                buf[n] = 0; // NUL-terminate for the C `chdir`
                chdir(buf.as_ptr());
            }
        }
    }
}

#[used]
#[link_section = ".init_array"]
static MC_WASI_INIT: extern "C" fn() = mc_wasi_sync_cwd;

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_proc_exit(code: i32) -> ! {
    mc_sys_exit(code);
    loop {}
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_proc_raise(_sig: i32) -> i32 {
    ENOSYS
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_sched_yield() -> i32 {
    // Cooperative scheduler; a zero-length sleep is a yield point.
    mc_sys_sleep_ms(0);
    0
}

/// Canonical args implementation. `args_*` is the one WASI call Rust std binds to
/// a hash-mangled symbol (its bundled `wasi` crate) rather than `__imported_*`;
/// the build pipeline emits a trampoline from that symbol to this. We also export
/// the `__imported_*` form below for toolchains that use it.
#[no_mangle]
pub unsafe extern "C" fn mc_wasi_args_sizes_get(ret_argc: i32, ret_buf_size: i32) -> i32 {
    let mut buf = [0u8; 16384];
    let mut total: u32 = 0;
    mc_sys_args(
        buf.as_mut_ptr() as i32,
        buf.len() as i32,
        (&mut total as *mut u32) as i32,
    );
    let n = (total as usize).min(buf.len());
    let blob = &buf[..n];
    // argc = number of NUL-terminated segments (ignore a trailing empty).
    let mut argc = 0u32;
    let mut buf_size = 0u32;
    for seg in blob.split(|&b| b == 0) {
        if !seg.is_empty() {
            argc += 1;
            buf_size += seg.len() as u32 + 1; // +1 for NUL
        }
    }
    wr_u32(ret_argc, argc);
    wr_u32(ret_buf_size, buf_size);
    0
}

#[no_mangle]
pub unsafe extern "C" fn mc_wasi_args_get(argv: i32, argv_buf: i32) -> i32 {
    let mut buf = [0u8; 16384];
    let mut total: u32 = 0;
    mc_sys_args(
        buf.as_mut_ptr() as i32,
        buf.len() as i32,
        (&mut total as *mut u32) as i32,
    );
    let n = (total as usize).min(buf.len());
    let blob = &buf[..n];
    let mut argv_p = argv;
    let mut out = argv_buf;
    for seg in blob.split(|&b| b == 0) {
        if seg.is_empty() {
            continue;
        }
        wr_u32(argv_p, out as u32);
        argv_p += 4;
        for &b in seg {
            wr_u8(out, b);
            out += 1;
        }
        wr_u8(out, 0);
        out += 1;
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_args_sizes_get(
    ret_argc: i32,
    ret_buf_size: i32,
) -> i32 {
    mc_wasi_args_sizes_get(ret_argc, ret_buf_size)
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_args_get(
    argv: i32,
    argv_buf: i32,
) -> i32 {
    mc_wasi_args_get(argv, argv_buf)
}

/// Iterate `/env` (name files), invoking `f(name, value)` for each. mc has no
/// `getenv` syscall — the environment is files under `/env` (envfs).
unsafe fn for_each_env(mut f: impl FnMut(&[u8], &[u8])) {
    let mut names = [0u8; 8192];
    let n = match mc_readdir(b"/env", &mut names) {
        Ok(n) => n,
        Err(_) => return, // no /env ⇒ empty environment
    };
    for name in names[..n].split(|&b| b == 0) {
        if name.is_empty() {
            continue;
        }
        // path = "/env/" + name
        let mut path = [0u8; PATH_MAX];
        let prefix = b"/env/";
        if prefix.len() + name.len() > PATH_MAX {
            continue;
        }
        path[..prefix.len()].copy_from_slice(prefix);
        path[prefix.len()..prefix.len() + name.len()].copy_from_slice(name);
        let plen = prefix.len() + name.len();
        let fd = match mc_open(&path[..plen], O_READ) {
            Ok(fd) => fd,
            Err(_) => continue,
        };
        let mut val = [0u8; 4096];
        let mut vlen = 0usize;
        loop {
            let mut got: u32 = 0;
            let e = mc_sys_read(
                fd,
                val[vlen..].as_mut_ptr() as i32,
                (val.len() - vlen) as i32,
                (&mut got as *mut u32) as i32,
            );
            if e != 0 || got == 0 {
                break;
            }
            vlen += got as usize;
            if vlen >= val.len() {
                break;
            }
        }
        mc_sys_close(fd);
        f(name, &val[..vlen]);
    }
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_environ_sizes_get(
    ret_count: i32,
    ret_buf_size: i32,
) -> i32 {
    let mut count = 0u32;
    let mut size = 0u32;
    for_each_env(|name, val| {
        count += 1;
        size += name.len() as u32 + 1 + val.len() as u32 + 1; // "NAME=VAL\0"
    });
    wr_u32(ret_count, count);
    wr_u32(ret_buf_size, size);
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_environ_get(
    environ: i32,
    environ_buf: i32,
) -> i32 {
    let mut ptr_p = environ;
    let mut out = environ_buf;
    for_each_env(|name, val| {
        wr_u32(ptr_p, out as u32);
        ptr_p += 4;
        for &b in name {
            wr_u8(out, b);
            out += 1;
        }
        wr_u8(out, b'=');
        out += 1;
        for &b in val {
            wr_u8(out, b);
            out += 1;
        }
        wr_u8(out, 0);
        out += 1;
    });
    0
}

// ---------------------------------------------------------------------------
// stdio + file io (iovec scatter/gather, in the tool's own memory)
// ---------------------------------------------------------------------------

/// Map a WASI fd to the mc fd to read/write: 0/1/2 are stdio; >=5 is a table file.
fn io_fd(fd: i32) -> Result<i32, i32> {
    if (0..=2).contains(&fd) {
        return Ok(fd);
    }
    let e = state().get(fd).ok_or(EBADF)?;
    if e.is_dir {
        return Err(EISDIR);
    }
    Ok(e.mc_fd)
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_write(
    fd: i32,
    iovs: i32,
    iovs_len: i32,
    ret: i32,
) -> i32 {
    let mcfd = match io_fd(fd) {
        Ok(f) => f,
        Err(e) => return e,
    };
    let mut total: u32 = 0;
    for i in 0..iovs_len {
        let iov = iovs + i * 8;
        let buf = rd_u32(iov) as i32;
        let len = rd_u32(iov + 4) as i32;
        if len == 0 {
            continue;
        }
        // mc_sys_write may short-write; drain the segment fully.
        let mut off = 0i32;
        while off < len {
            let mut n: u32 = 0;
            let e = mc_sys_write(mcfd, buf + off, len - off, (&mut n as *mut u32) as i32);
            if e != 0 {
                if total > 0 {
                    break;
                }
                return e;
            }
            if n == 0 {
                break;
            }
            off += n as i32;
            total += n;
        }
    }
    wr_u32(ret, total);
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_read(
    fd: i32,
    iovs: i32,
    iovs_len: i32,
    ret: i32,
) -> i32 {
    let mcfd = match io_fd(fd) {
        Ok(f) => f,
        Err(e) => return e,
    };
    let mut total: u32 = 0;
    for i in 0..iovs_len {
        let iov = iovs + i * 8;
        let buf = rd_u32(iov) as i32;
        let len = rd_u32(iov + 4) as i32;
        if len == 0 {
            continue;
        }
        let mut n: u32 = 0;
        let e = mc_sys_read(mcfd, buf, len, (&mut n as *mut u32) as i32);
        if e != 0 {
            if total > 0 {
                break;
            }
            return e;
        }
        total += n;
        if (n as i32) < len {
            break; // short read / EOF: stop gathering
        }
    }
    wr_u32(ret, total);
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_close(fd: i32) -> i32 {
    if let Some(e) = state().get(fd) {
        if !e.is_dir && e.mc_fd >= 0 {
            mc_sys_close(e.mc_fd);
        }
        state().free(fd);
        0
    } else if (0..=2).contains(&fd) || fd == PRE_ROOT || fd == PRE_CWD {
        0 // closing stdio / preopens is a no-op
    } else {
        EBADF
    }
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_seek(
    fd: i32,
    offset: i64,
    whence: i32,
    ret: i32,
) -> i32 {
    let mcfd = match io_fd(fd) {
        Ok(f) => f,
        Err(e) => return e,
    };
    let mut off = offset; // in/out i64 the kernel reads then writes the result into
    let e = mc_sys_lseek(mcfd, (&mut off as *mut i64) as i32, whence);
    if e != 0 {
        return e;
    }
    wr_u64(ret, off as u64);
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_tell(fd: i32, ret: i32) -> i32 {
    __imported_wasi_snapshot_preview1_fd_seek(fd, 0, SEEK_CUR, ret)
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_fdstat_get(fd: i32, ret: i32) -> i32 {
    let (filetype, flags, rights) = if (0..=2).contains(&fd) {
        // Std streams are character devices. wasi-libc's `isatty()` requires the
        // device to ALSO lack the SEEK/TELL rights (a real tty can't seek), so
        // reflect the kernel's verdict: clear those bits only when this fd is the
        // controlling terminal, and leave them set for a pipe/file/redirected
        // stream so `isatty(fd)` stays false there. This is what lets an
        // interactive guest REPL (luau, sqlite3) tell a live prompt apart from
        // `echo … | luau` without guessing. See `mc_sys_isatty`.
        let rights = if mc_isatty(fd) {
            u64::MAX & !(RIGHTS_FD_SEEK | RIGHTS_FD_TELL)
        } else {
            u64::MAX
        };
        (FT_CHAR_DEVICE, 0u16, rights)
    } else if fd == PRE_ROOT || fd == PRE_CWD {
        (FT_DIRECTORY, 0, u64::MAX)
    } else if let Some(e) = state().get(fd) {
        let ft = if e.is_dir {
            FT_DIRECTORY
        } else {
            FT_REGULAR_FILE
        };
        (ft, if e.append { FD_APPEND as u16 } else { 0 }, u64::MAX)
    } else {
        return EBADF;
    };
    // fdstat: fs_filetype u8 @0, fs_flags u16 @2, rights_base u64 @8, inheriting @16
    wr_u8(ret, filetype);
    wr_u16(ret + 2, flags);
    wr_u64(ret + 8, rights); // the kernel still enforces real perms on each call
    wr_u64(ret + 16, u64::MAX);
    let _ = FDSTAT_SIZE;
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_fdstat_set_flags(
    _fd: i32,
    _flags: i32,
) -> i32 {
    0 // accepted; mc fds don't carry independent O_NONBLOCK/etc.
}

unsafe fn write_filestat(
    ret: i32,
    size: u64,
    filetype: u8,
    nlink: u64,
    atim: u64,
    mtim: u64,
    ctim: u64,
) {
    // filestat: dev@0 ino@8 filetype@16 nlink@24 size@32 atim@40 mtim@48 ctim@56
    wr_u64(ret, 0);
    wr_u64(ret + 8, 0);
    wr_u8(ret + 16, filetype);
    wr_u64(ret + 24, nlink);
    wr_u64(ret + 32, size);
    wr_u64(ret + 40, atim);
    wr_u64(ret + 48, mtim);
    wr_u64(ret + 56, ctim);
    let _ = FILESTAT_SIZE;
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_filestat_get(
    fd: i32,
    ret: i32,
) -> i32 {
    if (0..=2).contains(&fd) {
        write_filestat(ret, 0, FT_CHAR_DEVICE, 1, 0, 0, 0);
        return 0;
    }
    // The preopen dir fds (3 = "/", 4 = cwd) are real directories — stat their resolved base.
    // Without this, fstat on a preopen returned EBADF, contradicting fd_prestat advertising it.
    if fd == PRE_ROOT || fd == PRE_CWD {
        let mut base = [0u8; PATH_MAX];
        let n = match base_for(fd, &mut base) {
            Ok(n) => n,
            Err(e) => return e,
        };
        return match mc_stat(&base[..n]) {
            Ok(st) => {
                write_filestat(ret, st.size, FT_DIRECTORY, st.nlink, st.atim, st.mtim, st.ctim);
                0
            }
            Err(e) => e,
        };
    }
    let path: [u8; PATH_MAX];
    let plen: usize;
    let is_dir;
    {
        let e = match state().get(fd) {
            Some(e) => e,
            None => return EBADF,
        };
        path = e.path;
        plen = e.path_len as usize;
        is_dir = e.is_dir;
    }
    match mc_stat(&path[..plen]) {
        Ok(st) => {
            let filetype = if is_dir { FT_DIRECTORY } else { st.filetype };
            write_filestat(ret, st.size, filetype, st.nlink, st.atim, st.mtim, st.ctim);
            0
        }
        Err(e) => e,
    }
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_filestat_set_size(
    fd: i32,
    size: i64,
) -> i32 {
    let mcfd = match io_fd(fd) {
        Ok(f) => f,
        Err(e) => return e,
    };
    let lo = (size as u64 & 0xffff_ffff) as i32;
    let hi = ((size as u64) >> 32) as i32;
    mc_sys_ftruncate(mcfd, lo, hi)
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_sync(_fd: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_datasync(_fd: i32) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_advise(
    _fd: i32,
    _off: i64,
    _len: i64,
    _advice: i32,
) -> i32 {
    0
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_allocate(
    _fd: i32,
    _off: i64,
    _len: i64,
) -> i32 {
    0
}
/// Map a WASI `*_set_times` request to `mc_sys_utimes`. `atim`/`mtim` are WASI
/// nanoseconds. WASI flags are per-field: an unset field is preserved, `*_NOW`
/// samples the current wall clock for that field, and `*_SET` uses the explicit
/// timestamp. If both fields are NOW, delegate to the kernel NULL-times fast path
/// so it samples both atomically.
unsafe fn mc_set_times(path: &[u8], atim: i64, mtim: i64, fst_flags: i32) -> i32 {
    const ATIM: i32 = 1;
    const ATIM_NOW: i32 = 2;
    const MTIM: i32 = 4;
    const MTIM_NOW: i32 = 8;

    if (fst_flags & ATIM != 0 && fst_flags & ATIM_NOW != 0)
        || (fst_flags & MTIM != 0 && fst_flags & MTIM_NOW != 0)
    {
        return EINVAL;
    }
    if fst_flags & (ATIM | ATIM_NOW | MTIM | MTIM_NOW) == 0 {
        return 0;
    }
    if fst_flags & ATIM_NOW != 0 && fst_flags & MTIM_NOW != 0 {
        mc_sys_utimes(path.as_ptr() as i32, path.len() as i32, 0)
    } else {
        let current = match mc_stat(path) {
            Ok(st) => st,
            Err(e) => return e,
        };
        let mut now_ms = 0i64;
        if fst_flags & (ATIM_NOW | MTIM_NOW) != 0 {
            let e = mc_sys_time_realtime((&mut now_ms as *mut i64) as i32);
            if e != 0 {
                return e;
            }
        }
        let ns_to_ms = |ns: i64| ns / 1_000_000;
        let atime = if fst_flags & ATIM_NOW != 0 {
            now_ms
        } else if fst_flags & ATIM != 0 {
            ns_to_ms(atim)
        } else {
            (current.atim / 1_000_000) as i64
        };
        let mtime = if fst_flags & MTIM_NOW != 0 {
            now_ms
        } else if fst_flags & MTIM != 0 {
            ns_to_ms(mtim)
        } else {
            (current.mtim / 1_000_000) as i64
        };
        let mut buf = [0u8; 16];
        buf[0..8].copy_from_slice(&atime.to_le_bytes());
        buf[8..16].copy_from_slice(&mtime.to_le_bytes());
        mc_sys_utimes(path.as_ptr() as i32, path.len() as i32, buf.as_ptr() as i32)
    }
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_filestat_set_times(
    fd: i32,
    atim: i64,
    mtim: i64,
    fst_flags: i32,
) -> i32 {
    if (0..=2).contains(&fd) {
        return 0; // streams have no persistent times
    }
    let path: [u8; PATH_MAX];
    let plen: usize;
    {
        let e = match state().get(fd) {
            Some(e) => e,
            None => return EBADF,
        };
        path = e.path;
        plen = e.path_len as usize;
    }
    mc_set_times(&path[..plen], atim, mtim, fst_flags)
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_renumber(from: i32, to: i32) -> i32 {
    // dup2 semantics over the adapter's fd table: `to` comes to refer to what `from` did, and `from`
    // is closed. Only table fds (>= FD_TABLE_BASE) are movable — stdio (0..=2) and the preopens
    // (3/4) are fixed kernel/preopen handles with no slot to receive the move.
    let in_table = |fd: i32| fd >= FD_TABLE_BASE && ((fd - FD_TABLE_BASE) as usize) < MAX_FDS;
    if !in_table(from) || state().get(from).is_none() {
        return EBADF;
    }
    if from == to {
        return 0;
    }
    if !in_table(to) {
        return ENOSYS; // cannot renumber onto stdio or a preopen
    }
    let from_idx = (from - FD_TABLE_BASE) as usize;
    let to_idx = (to - FD_TABLE_BASE) as usize;
    let st = state();
    // dup2 closes whatever `to` held before it takes on `from`.
    if st.table[to_idx].used && !st.table[to_idx].is_dir && st.table[to_idx].mc_fd >= 0 {
        mc_sys_close(st.table[to_idx].mc_fd);
    }
    st.table[to_idx] = st.table[from_idx];
    st.table[from_idx].used = false;
    0
}

// ---------------------------------------------------------------------------
// preopens: how Rust std discovers the filesystem at startup.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_prestat_get(
    fd: i32,
    ret: i32,
) -> i32 {
    // prestat: tag u8 @0, then (for dir) pr_name_len u32 @4.
    // We advertise EXACTLY ONE preopen — fd 3 = "/" — which covers the whole mc filesystem; wasi-libc
    // resolves every path (absolute, or relative to its cwd) against it. PRE_CWD (fd 4) is NOT
    // advertised on purpose: a "." preopen makes wasi-libc's longest-prefix path matching ambiguous
    // and breaks path resolution for std guests. fd 4 stays handled by base_for/resolve only for a
    // guest that passes it as an explicit dirfd; the discovery scan stops at fd 4's EBADF.
    let name_len: u32 = match fd {
        PRE_ROOT => 1, // "/"
        _ => return EBADF,
    };
    wr_u8(ret, PREOPENTYPE_DIR);
    wr_u32(ret + 4, name_len);
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_prestat_dir_name(
    fd: i32,
    path: i32,
    path_len: i32,
) -> i32 {
    let name: &[u8] = match fd {
        PRE_ROOT => b"/",
        _ => return EBADF, // fd 4 (PRE_CWD) deliberately not advertised — see fd_prestat_get
    };
    if (path_len as usize) < name.len() {
        return EINVAL;
    }
    for (i, &b) in name.iter().enumerate() {
        wr_u8(path + i as i32, b);
    }
    0
}

// ---------------------------------------------------------------------------
// path operations
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_open(
    dirfd: i32,
    _dirflags: i32,
    path: i32,
    path_len: i32,
    oflags: i32,
    fs_rights_base: i64,
    _fs_rights_inheriting: i64,
    fdflags: i32,
    ret_fd: i32,
) -> i32 {
    let mut abuf = [0u8; PATH_MAX];
    let alen = match resolve(dirfd, path, path_len, &mut abuf) {
        Ok(n) => n,
        Err(e) => return e,
    };
    let abs = &abuf[..alen];

    let rights = fs_rights_base as u64;
    let want_write = oflags & (O_CREAT | O_TRUNC) != 0 || rights & RIGHT_FD_WRITE != 0;
    let want_dir = oflags & O_DIRECTORY != 0;

    // Decide file vs dir. Stat first; honor O_EXCL/O_DIRECTORY.
    let existing = mc_stat(abs);
    let is_dir = match existing {
        Ok(st) => st.is_dir(),
        Err(_) => want_dir, // doesn't exist yet
    };
    if want_dir && matches!(existing, Ok(st) if !st.is_dir()) {
        return ENOTDIR;
    }
    if oflags & O_EXCL != 0 && existing.is_ok() {
        return EEXIST;
    }

    let st = state();
    let wfd = match st.alloc() {
        Some(f) => f,
        None => return EMFILE,
    };

    if is_dir {
        let e = st.get(wfd).unwrap();
        e.is_dir = true;
        e.mc_fd = -1;
        set_path(e, abs);
        wr_u32(ret_fd, wfd as u32);
        return 0;
    }

    // Regular file: translate WASI oflags/fdflags/rights → mc O_*.
    let mut flags = 0i32;
    let reading = rights & RIGHT_FD_READ != 0 || !want_write;
    if reading {
        flags |= O_READ;
    }
    if want_write {
        flags |= O_WRITE;
    }
    if oflags & O_CREAT != 0 {
        flags |= O_CREATE;
    }
    if oflags & O_TRUNC != 0 {
        flags |= O_TRUNC;
    }
    if fdflags & FD_APPEND != 0 {
        flags |= O_APPEND;
    }
    if flags & (O_READ | O_WRITE) == 0 {
        flags |= O_READ;
    }

    match mc_open(abs, flags) {
        Ok(mcfd) => {
            let e = st.get(wfd).unwrap();
            e.is_dir = false;
            e.mc_fd = mcfd;
            e.append = fdflags & FD_APPEND != 0;
            set_path(e, abs);
            wr_u32(ret_fd, wfd as u32);
            0
        }
        Err(err) => {
            st.free(wfd);
            err
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_filestat_get(
    dirfd: i32,
    flags: i32,
    path: i32,
    path_len: i32,
    ret: i32,
) -> i32 {
    let mut abuf = [0u8; PATH_MAX];
    let alen = match resolve(dirfd, path, path_len, &mut abuf) {
        Ok(n) => n,
        Err(e) => return e,
    };
    let st = if flags & LOOKUP_SYMLINK_FOLLOW != 0 {
        mc_stat(&abuf[..alen])
    } else {
        mc_lstat(&abuf[..alen])
    };
    match st {
        Ok(st) => {
            write_filestat(
                ret,
                st.size,
                st.filetype,
                st.nlink,
                st.atim,
                st.mtim,
                st.ctim,
            );
            0
        }
        Err(e) => e,
    }
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_create_directory(
    dirfd: i32,
    path: i32,
    path_len: i32,
) -> i32 {
    let mut abuf = [0u8; PATH_MAX];
    let alen = match resolve(dirfd, path, path_len, &mut abuf) {
        Ok(n) => n,
        Err(e) => return e,
    };
    let abs = &abuf[..alen];
    mc_sys_mkdir(abs.as_ptr() as i32, abs.len() as i32)
}

unsafe fn path_unlink_common(dirfd: i32, path: i32, path_len: i32) -> i32 {
    let mut abuf = [0u8; PATH_MAX];
    let alen = match resolve(dirfd, path, path_len, &mut abuf) {
        Ok(n) => n,
        Err(e) => return e,
    };
    let abs = &abuf[..alen];
    mc_sys_unlink(abs.as_ptr() as i32, abs.len() as i32)
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_unlink_file(
    dirfd: i32,
    path: i32,
    path_len: i32,
) -> i32 {
    path_unlink_common(dirfd, path, path_len)
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_remove_directory(
    dirfd: i32,
    path: i32,
    path_len: i32,
) -> i32 {
    path_unlink_common(dirfd, path, path_len)
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_rename(
    old_fd: i32,
    old_path: i32,
    old_path_len: i32,
    new_fd: i32,
    new_path: i32,
    new_path_len: i32,
) -> i32 {
    let mut ob = [0u8; PATH_MAX];
    let ol = match resolve(old_fd, old_path, old_path_len, &mut ob) {
        Ok(n) => n,
        Err(e) => return e,
    };
    let mut nb = [0u8; PATH_MAX];
    let nl = match resolve(new_fd, new_path, new_path_len, &mut nb) {
        Ok(n) => n,
        Err(e) => return e,
    };
    mc_sys_rename(ob.as_ptr() as i32, ol as i32, nb.as_ptr() as i32, nl as i32)
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_filestat_set_times(
    dirfd: i32,
    _flags: i32,
    path: i32,
    path_len: i32,
    atim: i64,
    mtim: i64,
    fst_flags: i32,
) -> i32 {
    let mut abuf = [0u8; PATH_MAX];
    let alen = match resolve(dirfd, path, path_len, &mut abuf) {
        Ok(n) => n,
        Err(e) => return e,
    };
    mc_set_times(&abuf[..alen], atim, mtim, fst_flags)
}

// Symbolic and hard links map onto the mc syscalls.
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_symlink(
    op: i32,
    ol: i32,
    fd: i32,
    np: i32,
    nl: i32,
) -> i32 {
    // `old_path` is the link's verbatim target text (not fd-relative); only the
    // new path is resolved against `fd`.
    let mut nb = [0u8; PATH_MAX];
    let nlen = match resolve(fd, np, nl, &mut nb) {
        Ok(n) => n,
        Err(e) => return e,
    };
    mc_sys_symlink(op, ol, nb.as_ptr() as i32, nlen as i32)
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_link(
    ofd: i32,
    _of: i32,
    op: i32,
    ol: i32,
    nfd: i32,
    np: i32,
    nl: i32,
) -> i32 {
    let mut ob = [0u8; PATH_MAX];
    let olen = match resolve(ofd, op, ol, &mut ob) {
        Ok(n) => n,
        Err(e) => return e,
    };
    let mut nb = [0u8; PATH_MAX];
    let nlen = match resolve(nfd, np, nl, &mut nb) {
        Ok(n) => n,
        Err(e) => return e,
    };
    mc_sys_link(
        ob.as_ptr() as i32,
        olen as i32,
        nb.as_ptr() as i32,
        nlen as i32,
    )
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_path_readlink(
    fd: i32,
    p: i32,
    pl: i32,
    buf: i32,
    buf_len: i32,
    ret: i32,
) -> i32 {
    let mut pb = [0u8; PATH_MAX];
    let plen = match resolve(fd, p, pl, &mut pb) {
        Ok(n) => n,
        Err(e) => return e,
    };
    // mc writes the FULL target length into `total`; WASI's `ret` is the number
    // of bytes actually placed in `buf` (clamped to `buf_len`).
    let mut total: u32 = 0;
    let e = mc_sys_readlink(
        pb.as_ptr() as i32,
        plen as i32,
        buf,
        buf_len,
        (&mut total as *mut u32) as i32,
    );
    if e != 0 {
        return e;
    }
    wr_u32(ret, total.min(buf_len as u32));
    0
}

// ---------------------------------------------------------------------------
// directory reading (WASI dirent paging)
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_fd_readdir(
    fd: i32,
    buf: i32,
    buf_len: i32,
    cookie: i64,
    ret_bufused: i32,
) -> i32 {
    // Resolve the directory's path.
    let mut dpath = [0u8; PATH_MAX];
    let dlen;
    if fd == PRE_ROOT {
        dpath[0] = b'/';
        dlen = 1;
    } else if fd == PRE_CWD {
        match mc_getcwd(&mut dpath) {
            Ok(n) => dlen = n,
            Err(e) => return e,
        }
    } else {
        match state().get(fd) {
            Some(e) if e.is_dir => {
                dlen = e.path_len as usize;
                dpath[..dlen].copy_from_slice(&e.path[..dlen]);
            }
            Some(_) => return ENOTDIR,
            None => return EBADF,
        }
    }
    let dir = &dpath[..dlen];

    let mut names = [0u8; 32768];
    let n = match mc_readdir(dir, &mut names) {
        Ok(n) => n,
        Err(e) => return e,
    };

    let start = cookie as usize;
    let mut written = 0usize;
    let mut idx = 0usize;
    'outer: for name in names[..n].split(|&b| b == 0) {
        if name.is_empty() {
            continue;
        }
        let this = idx;
        idx += 1;
        if this < start {
            continue;
        }

        // d_type describes the directory entry itself; do not follow symlinks.
        let d_type = {
            let mut cp = [0u8; PATH_MAX];
            if let Ok(cl) = normalize_join(dir, name, &mut cp) {
                match mc_lstat(&cp[..cl]) {
                    Ok(st) => st.filetype,
                    Err(_) => FT_UNKNOWN,
                }
            } else {
                FT_UNKNOWN
            }
        };

        let recbase = buf + written as i32;
        let namlen = name.len();
        // Always write the fixed dirent header (even if the name won't fit, WASI
        // expects a partial final record so the caller knows to grow its buffer).
        if written + DIRENT_SIZE > buf_len as usize {
            // No room for even the header → stop; caller re-calls with more space.
            break;
        }
        wr_u64(recbase, (this + 1) as u64); // d_next (cookie for the entry after this)
        wr_u64(recbase + 8, (this + 1) as u64); // d_ino (synthetic, nonzero)
        wr_u32(recbase + 16, namlen as u32); // d_namlen
        wr_u8(recbase + 20, d_type); // d_type
        written += DIRENT_SIZE;

        // Name bytes (possibly truncated to fill the buffer exactly).
        let name_room = (buf_len as usize).saturating_sub(written);
        let copy = namlen.min(name_room);
        for (i, &b) in name[..copy].iter().enumerate() {
            wr_u8(buf + written as i32 + i as i32, b);
        }
        written += copy;
        if copy < namlen {
            break 'outer; // buffer full mid-name; caller will re-read
        }
    }
    wr_u32(ret_bufused, written as u32);
    0
}

// ---------------------------------------------------------------------------
// clock / random / poll
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_clock_time_get(
    id: i32,
    _precision: i64,
    ret: i32,
) -> i32 {
    // mc exposes milliseconds; WASI wants nanoseconds. CLOCKID_REALTIME (0) maps
    // to the wall clock (`mc_sys_time_realtime`) — what `date` reads; every other
    // id (MONOTONIC=1, process/thread cputime) maps to the monotonic source.
    const CLOCKID_REALTIME: i32 = 0;
    let mut ms: i64 = 0;
    let e = if id == CLOCKID_REALTIME {
        mc_sys_time_realtime((&mut ms as *mut i64) as i32)
    } else {
        mc_sys_time_monotonic((&mut ms as *mut i64) as i32)
    };
    if e != 0 {
        return e;
    }
    wr_u64(ret, (ms as u64).saturating_mul(1_000_000));
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_clock_res_get(
    _id: i32,
    ret: i32,
) -> i32 {
    wr_u64(ret, 1_000_000); // 1ms resolution
    0
}

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_random_get(
    buf: i32,
    buf_len: i32,
) -> i32 {
    mc_sys_random(buf, buf_len)
}

/// Minimal `poll_oneoff`: supports clock timeouts and fd read/write readiness
/// (the common cases). Each 48-byte subscription carries an 8-byte userdata, a
/// tag at +8, and a union at +16; each 32-byte event echoes userdata + type.
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_poll_oneoff(
    subs: i32,
    out: i32,
    nsubs: i32,
    ret_nevents: i32,
) -> i32 {
    if nsubs <= 0 {
        wr_u32(ret_nevents, 0);
        return 0;
    }
    // Find the smallest clock timeout (ns) and collect fd subscriptions.
    let mut min_timeout_ms: i64 = -1; // -1 ⇒ no clock sub (block)
    let mut clock_sub: i32 = -1; // index of the chosen clock sub
    let mut nevents = 0i32;

    // First pass: clocks.
    for i in 0..nsubs {
        let s = subs + i * 48;
        let tag = rd_u8(s + 8);
        if tag == EVENTTYPE_CLOCK {
            let timeout_ns = rd_u64(s + 24);
            let ms = (timeout_ns / 1_000_000) as i64;
            if min_timeout_ms < 0 || ms < min_timeout_ms {
                min_timeout_ms = ms;
                clock_sub = i;
            }
        }
    }

    // Second pass: fd readiness via mc_sys_poll.
    let mut pollfds = [0u8; 8 * 32]; // up to 32 fd subs: {fd i32, events i16, revents i16}
    let mut sub_of_pfd = [0i32; 32];
    let mut npfd = 0usize;
    for i in 0..nsubs {
        let s = subs + i * 48;
        let tag = rd_u8(s + 8);
        if (tag == EVENTTYPE_FD_READ || tag == EVENTTYPE_FD_WRITE) && npfd < 32 {
            let wfd = rd_u32(s + 16) as i32;
            let mcfd = io_fd(wfd).unwrap_or(-1);
            let ev: i16 = if tag == EVENTTYPE_FD_READ {
                POLLIN as i16
            } else {
                POLLOUT as i16
            };
            let base = npfd * 8;
            pollfds[base..base + 4].copy_from_slice(&mcfd.to_le_bytes());
            pollfds[base + 4..base + 6].copy_from_slice(&ev.to_le_bytes());
            pollfds[base + 6..base + 8].copy_from_slice(&0i16.to_le_bytes());
            sub_of_pfd[npfd] = i;
            npfd += 1;
        }
    }

    if npfd > 0 {
        let timeout = if min_timeout_ms < 0 {
            POLL_BLOCK
        } else {
            min_timeout_ms as i32
        };
        let mut ready: u32 = 0;
        mc_sys_poll(
            pollfds.as_mut_ptr() as i32,
            npfd as i32,
            timeout,
            (&mut ready as *mut u32) as i32,
        );
        for k in 0..npfd {
            let base = k * 8;
            let revents = i16::from_le_bytes([pollfds[base + 6], pollfds[base + 7]]);
            if revents != 0 {
                let i = sub_of_pfd[k];
                let s = subs + i * 48;
                let tag = rd_u8(s + 8);
                let ev = out + nevents * 32;
                wr_u64(ev, rd_u64(s)); // userdata
                wr_u16(ev + 8, 0); // error
                wr_u8(ev + 10, tag); // type
                wr_u64(ev + 16, 0); // nbytes (unknown)
                wr_u16(ev + 24, 0); // flags
                nevents += 1;
            }
        }
    } else if min_timeout_ms >= 0 {
        // Clock-only: sleep, then report the clock event as fired.
        mc_sys_sleep_ms(min_timeout_ms as i32);
    }

    // If nothing fd-ready but a clock was requested, report the clock expiry.
    if nevents == 0 && clock_sub >= 0 {
        let s = subs + clock_sub * 48;
        let ev = out;
        wr_u64(ev, rd_u64(s));
        wr_u16(ev + 8, 0);
        wr_u8(ev + 10, EVENTTYPE_CLOCK);
        wr_u64(ev + 16, 0);
        wr_u16(ev + 24, 0);
        nevents = 1;
    }

    wr_u32(ret_nevents, nevents as u32);
    0
}

// ---------------------------------------------------------------------------
// sockets: denied (host-terminated networking is a separate mc capability).
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_sock_accept(
    _fd: i32,
    _flags: i32,
    _ret: i32,
) -> i32 {
    ENOSYS
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_sock_recv(
    _fd: i32,
    _a: i32,
    _b: i32,
    _c: i32,
    _d: i32,
    _e: i32,
) -> i32 {
    ENOSYS
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_sock_send(
    _fd: i32,
    _a: i32,
    _b: i32,
    _c: i32,
    _d: i32,
) -> i32 {
    ENOSYS
}
#[no_mangle]
pub unsafe extern "C" fn __imported_wasi_snapshot_preview1_sock_shutdown(
    _fd: i32,
    _how: i32,
) -> i32 {
    ENOSYS
}
