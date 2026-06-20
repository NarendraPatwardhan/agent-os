//! Virtual filesystem traits — the interface every filesystem implements.
//!
//! This is the contract layer the whole VFS rests on: [`FileSystem`] (a mountable
//! backend) and [`FileHandle`] (an open file), plus the shared vocabulary —
//! [`FsError`], [`NodeType`], [`Metadata`], [`OpenFlags`], [`SeekFrom`], and the
//! kernel path type [`KPath`]. It depends on nothing else in the kernel (only `alloc`/
//! `core`), so it is the dependency root for `fs/*` and the namespace.
//!
//! Design notes worth keeping: a `caller` id is threaded through the mutating ops
//! so identity-aware filesystems (procfs, netfs, guest file servers) can check who is
//! acting without the VFS depending on `task`; [`FsError::WouldBlock`] lets a handle
//! backed by an in-flight resource ask the cooperative scheduler to re-poll it later;
//! and the default-`NotImplemented` methods let read-only/synthetic filesystems opt out
//! of the writable surface without any edit.

#![allow(dead_code)]

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;

pub type Result<T> = core::result::Result<T, FsError>;

/// The acting task's id, threaded into [`FileSystem::open`] so identity-aware
/// filesystems can check the caller: procfs (`/proc/[pid]/ctl` permission), netfs
/// (`CAP_NET` gating), and guest file servers (the 9P caller). Plain filesystems
/// (memfs/tarfs/cowfs/devfs/persistfs) ignore it. `u32` rather than `task::TaskId`, so
/// `vfs` need not depend on `task` (they are the same integer).
pub type CallerId = u32;

/// The kernel/system caller identity — boot-time and internal opens (profile sourcing,
/// program loading) that act on no task's behalf.
pub const SYSTEM_CALLER: CallerId = 0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FsError {
    NotFound,
    AlreadyExists,
    NotDir,
    IsDir,
    /// A capability/mount/identity denial — maps to `EPERM`.
    PermissionDenied,
    /// A file-**mode** bit check failed (owner r/w/x) — maps to `EACCES`. Distinct from
    /// `PermissionDenied` so mode denial reads as POSIX `EACCES`, not the capability
    /// `EPERM`.
    AccessDenied,
    InvalidPath,
    NotEmpty,
    IoError,
    BadFileDescriptor,
    NotImplemented,
    /// `rename` across two different mounts — POSIX `EXDEV`. The caller (`mv`) falls
    /// back to copy + remove.
    CrossDevice,
    /// The operation cannot complete synchronously and the caller should yield and
    /// retry. Returned by file handles backed by an in-flight resource — a network
    /// connection (`netfs`) or a guest file server — so the cooperative scheduler can
    /// re-poll them on a later tick. Ordinary in-memory/storage filesystems never
    /// produce it.
    WouldBlock,
    /// Path resolution exceeded the symlink-following depth limit — POSIX `ELOOP`.
    /// Produced only by the namespace canonicalizer, never by a leaf filesystem.
    Loop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeType {
    File,
    Dir,
    /// A symbolic link. [`Metadata::size`] is the byte length of its target text; the
    /// target itself is read with [`FileSystem::readlink`]. Following the link is the
    /// namespace's job (path canonicalization), never the filesystem's.
    Symlink,
}

/// Default permission bits for newly created nodes (the conventional umask-022 result).
/// Single subject, so only the owner triad is ever enforced.
pub const MODE_FILE_DEFAULT: u16 = 0o644;
pub const MODE_DIR_DEFAULT: u16 = 0o755;
/// Symlinks ignore their own mode (the target's mode governs); we report `lrwxrwxrwx`.
pub const MODE_SYMLINK: u16 = 0o777;

#[derive(Debug, Clone)]
pub struct Metadata {
    pub node_type: NodeType,
    pub size: u64,
    /// Hard-link count (POSIX `st_nlink`). Synthetic/read-only filesystems report the
    /// natural defaults via the constructors; only `memfs` tracks a real count, since
    /// it is the one place names and nodes are many-to-one.
    pub nlink: u32,
    /// POSIX permission bits — the low 9 rwx bits. Single subject, so only the owner
    /// triad (`& 0o400`/`0o200`/`0o100`) is ever enforced.
    pub mode: u16,
    /// Modify / access / change times in **milliseconds since the Unix epoch** (matching
    /// `mc_sys_time_realtime`). `0` = unknown (synthetic filesystems).
    pub mtime: i64,
    pub atime: i64,
    pub ctime: i64,
}

impl Metadata {
    /// A regular file of `size` bytes with one link.
    pub fn file(size: u64) -> Self {
        Self {
            node_type: NodeType::File,
            size,
            nlink: 1,
            mode: MODE_FILE_DEFAULT,
            mtime: 0,
            atime: 0,
            ctime: 0,
        }
    }
    /// A regular file with an explicit hard-link count (`memfs`).
    pub fn file_with_nlink(size: u64, nlink: u32) -> Self {
        Self {
            nlink,
            ..Self::file(size)
        }
    }
    /// A directory. `nlink` defaults to the POSIX minimum of 2 (`.` and its name).
    pub fn dir() -> Self {
        Self {
            node_type: NodeType::Dir,
            size: 0,
            nlink: 2,
            mode: MODE_DIR_DEFAULT,
            mtime: 0,
            atime: 0,
            ctime: 0,
        }
    }
    /// A directory with an explicit link count (`2 + subdirectory count`, memfs).
    pub fn dir_with_nlink(nlink: u32) -> Self {
        Self {
            nlink,
            ..Self::dir()
        }
    }
    /// A symbolic link whose target text is `target_len` bytes.
    pub fn symlink(target_len: u64) -> Self {
        Self {
            node_type: NodeType::Symlink,
            size: target_len,
            nlink: 1,
            mode: MODE_SYMLINK,
            mtime: 0,
            atime: 0,
            ctime: 0,
        }
    }
    /// A symbolic link with an explicit hard-link count (`memfs`).
    pub fn symlink_with_nlink(target_len: u64, nlink: u32) -> Self {
        Self {
            nlink,
            ..Self::symlink(target_len)
        }
    }

    /// Override the permission bits (chainable) — used by backends that track a real
    /// mode (`memfs`, `tarfs`).
    pub fn with_mode(mut self, mode: u16) -> Self {
        self.mode = mode;
        self
    }
    /// Set all three timestamps at once (chainable). Read-only backends pass the same
    /// value for all three (e.g. tarfs `atime = ctime = mtime`).
    pub fn with_times(mut self, atime: i64, mtime: i64, ctime: i64) -> Self {
        self.atime = atime;
        self.mtime = mtime;
        self.ctime = ctime;
        self
    }

    /// Owner-triad permission predicates (single subject = owner).
    pub fn owner_readable(&self) -> bool {
        self.mode & 0o400 != 0
    }
    pub fn owner_writable(&self) -> bool {
        self.mode & 0o200 != 0
    }
    pub fn owner_executable(&self) -> bool {
        self.mode & 0o100 != 0
    }
}

#[derive(Debug, Clone)]
pub struct DirEntry {
    pub name: String,
    pub node_type: NodeType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenFlags {
    pub read: bool,
    pub write: bool,
    pub create: bool,
    pub truncate: bool,
    pub append: bool,
    /// Suppress atime updates on read. Set by the syscall layer for tasks without
    /// `CAP_AMBIENT` (the deterministic `isolated` tier) so a read can't leak the wall
    /// clock into the file's access time. The named constructors default it off;
    /// internal opens (boot, copy-up) never track atime anyway.
    pub noatime: bool,
}

impl OpenFlags {
    pub const READ: Self = Self {
        read: true,
        write: false,
        create: false,
        truncate: false,
        append: false,
        noatime: false,
    };
    pub const WRITE: Self = Self {
        read: false,
        write: true,
        create: false,
        truncate: false,
        append: false,
        noatime: false,
    };
    pub const CREATE: Self = Self {
        read: false,
        write: true,
        create: true,
        truncate: false,
        append: false,
        noatime: false,
    };
    pub const TRUNCATE: Self = Self {
        read: false,
        write: true,
        create: true,
        truncate: true,
        append: false,
        noatime: false,
    };
    pub const APPEND: Self = Self {
        read: false,
        write: true,
        create: true,
        truncate: false,
        append: true,
        noatime: false,
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeekFrom {
    Start(u64),
    Current(i64),
    End(i64),
}

/// A kernel path — a simple owned string wrapper, `no_std`-friendly. The namespace
/// canonicalizes before handing one to a filesystem, so backends see clean paths.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct KPath(pub String);

impl KPath {
    pub fn new(path: &str) -> Self {
        KPath(String::from(path))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn parent(&self) -> Option<KPath> {
        let s = self.0.trim_end_matches('/');
        match s.rfind('/') {
            Some(0) => Some(KPath::new("/")),
            Some(idx) => Some(KPath::new(&s[..idx])),
            None => None,
        }
    }

    pub fn name(&self) -> &str {
        let s = self.0.trim_end_matches('/');
        match s.rfind('/') {
            Some(idx) => &s[idx + 1..],
            None => s,
        }
    }

    pub fn join(&self, other: &str) -> KPath {
        if other.starts_with('/') {
            KPath::new(other)
        } else if self.0.ends_with('/') {
            KPath::new(&alloc::format!("{}{}", self.0, other))
        } else {
            KPath::new(&alloc::format!("{}/{}", self.0, other))
        }
    }
}

pub trait FileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize>;
    fn write(&mut self, buf: &[u8]) -> Result<usize>;
    fn seek(&mut self, pos: SeekFrom) -> Result<u64>;
    fn stat(&self) -> Result<Metadata>;

    /// Set the file's length to `size` (zero-extending on grow, dropping on shrink).
    /// Defaults to `NotImplemented` so read-only filesystems (tarfs/procfs/devfs) need
    /// no change; the writable handles override it.
    fn truncate(&mut self, _size: u64) -> Result<()> {
        Err(FsError::NotImplemented)
    }

    /// `mc_sys_poll` readiness for a handle behind a regular fd. Default `true` —
    /// ordinary files are always readable/writable (a read returns data or EOF, a write
    /// always lands). A handle backed by an in-flight resource (`netfs`, a guest file
    /// server) overrides these to report when a `read`/`write` would make progress
    /// without returning `WouldBlock`. Mirrors the `ReadSource`/`WriteSink` poll methods.
    fn poll_readable(&self) -> bool {
        true
    }
    fn poll_writable(&self) -> bool {
        true
    }
}

pub trait FileSystem {
    /// Open `path`. `caller` is the acting task's id; plain filesystems ignore it,
    /// identity-aware ones (procfs/netfs/served) check it.
    fn open(
        &mut self,
        path: &KPath,
        flags: OpenFlags,
        caller: CallerId,
    ) -> Result<Box<dyn FileHandle>>;
    /// Synchronous metadata used by namespace path resolution and permission checks.
    /// Implementations must not yield from this path.
    fn stat(&self, path: &KPath) -> Result<Metadata>;
    /// User-visible terminal metadata. Plain filesystems use the synchronous metadata
    /// path; identity-aware filesystems such as `ServedFs` may use `caller` to route a
    /// request and return `WouldBlock` for cooperative retry.
    fn stat_as(&self, path: &KPath, _caller: CallerId) -> Result<Metadata> {
        self.stat(path)
    }
    /// List `path`. `caller` is threaded like [`FileSystem::open`]'s: plain filesystems
    /// ignore it, identity-aware ones (a guest file server) key their request/response
    /// state on it so a cooperative re-poll after [`FsError::WouldBlock`] is not
    /// mistaken for a second request. The mutating ops below carry it for the same
    /// reason.
    fn readdir(&self, path: &KPath, caller: CallerId) -> Result<Vec<DirEntry>>;
    fn mkdir(&mut self, path: &KPath, caller: CallerId) -> Result<()>;
    fn unlink(&mut self, path: &KPath, caller: CallerId) -> Result<()>;
    fn rename(&mut self, from: &KPath, to: &KPath, caller: CallerId) -> Result<()>;

    /// Create a symbolic link at `link` whose stored target text is `target` (verbatim
    /// — symlinks are never resolved by the filesystem). Defaults to `NotImplemented`,
    /// so read-only and synthetic filesystems refuse without any edit.
    fn symlink(&mut self, _target: &str, _link: &KPath) -> Result<()> {
        Err(FsError::NotImplemented)
    }

    /// Create a hard link `new` referring to the same underlying node as `existing`
    /// (POSIX `link`). Defaults to `NotImplemented`.
    fn link(&mut self, _existing: &KPath, _new: &KPath) -> Result<()> {
        Err(FsError::NotImplemented)
    }

    /// Return the target text of the symbolic link at `path`. Errs with `InvalidPath`
    /// when `path` is not a symlink, `NotImplemented` by default.
    fn readlink(&self, _path: &KPath) -> Result<String> {
        Err(FsError::NotImplemented)
    }

    /// Set the permission bits of `path` (POSIX `chmod`). Bumps `ctime`. Defaults to
    /// `NotImplemented`, so read-only/synthetic filesystems refuse without any edit.
    /// `memfs` overrides it; the overlay (`cowfs`) copies up first.
    fn set_mode(&mut self, _path: &KPath, _mode: u16) -> Result<()> {
        Err(FsError::NotImplemented)
    }

    /// Set the access and modify times of `path` in ms since the epoch (POSIX
    /// `utimes`). Bumps `ctime`. `NotImplemented` by default.
    fn set_times(&mut self, _path: &KPath, _atime: i64, _mtime: i64) -> Result<()> {
        Err(FsError::NotImplemented)
    }

    /// Serialize this filesystem's writable diff — the CoW overlay (live writes since
    /// boot) plus deletions as OCI `.wh.` whiteouts — into a POSIX-ustar `.tar` layer
    /// (the `commit` primitive; inverse of `TarFs`). Only `CowFs` produces one;
    /// everything else has no diff concept (`None`).
    fn commit_layer(&mut self) -> Option<Vec<u8>> {
        None
    }
}
