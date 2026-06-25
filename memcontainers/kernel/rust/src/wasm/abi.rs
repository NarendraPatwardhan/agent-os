//! Kernel-side glue over the `mc` syscall ABI.
//!
//! The ABI surface — errno, open flags, tiers, signals, the syscall list, and the
//! canonical `mc_syscall_table!` macro — is the single source of truth in `contracts/`,
//! PROJECTED into the `constants_rust` and `mc_rust` crates (B2). This module is the
//! kernel's `abi`: it re-exports those projections and adds the two helpers that depend
//! on kernel-internal types (`OpenFlags`, `FsError`) and so cannot live in the
//! projection. Every kernel file refers to the ABI through `crate::wasm::abi`, so nothing
//! hand-writes a constant or a syscall name.
//!
//! Convention: a syscall returns `0` (ESUCCESS) on success or a positive errno; any value
//! it produces is written through a guest pointer argument.

#![allow(dead_code)]

pub use constants_rust::*;
// `mc_syscall_table!` is `#[macro_export]` in the projection, so it is re-exported by
// name (a glob would skip it). The kernel hands it its own `$emit` callbacks (the
// `Pending` enum and the wasmi registration) in `wasm/mod.rs`. (`SYSCALL_NAMES` is the
// host/sysroot's; the kernel reaches it through `mc_rust` directly if ever needed.)
pub use mc_rust::mc_syscall_table;

/// WASI-style errno; `0` is never an error.
pub type Errno = i32;

/// Translate guest open flags to kernel [`crate::vfs::OpenFlags`].
pub fn open_flags(flags: i32) -> crate::vfs::OpenFlags {
    crate::vfs::OpenFlags {
        read: flags & O_READ != 0,
        write: flags & O_WRITE != 0,
        create: flags & O_CREATE != 0,
        truncate: flags & O_TRUNC != 0,
        append: flags & O_APPEND != 0,
        // The syscall layer raises this for clock-less (isolated) tasks; the raw flag
        // word has no noatime bit.
        noatime: false,
    }
}

// The single `FsError` ↔ errno table. `errno_from_fs` (kernel → guest) and
// `fs_result_from_errno` (a served guest's reply → kernel) are exact inverses, so both
// are GENERATED from one list of pairs below — neither can drift from the other, and a
// new `FsError` variant fails to compile until it is mapped here. `ESUCCESS` is the
// success sentinel (never an `FsError`); an errno we don't recognize on the way back
// collapses to `IoError`, so a misbehaving server cannot smuggle an undefined outcome
// into the VFS.
macro_rules! fs_errno_table {
    ($($variant:ident => $errno:ident),+ $(,)?) => {
        /// Map a VFS error to an errno.
        pub fn errno_from_fs(e: crate::vfs::FsError) -> Errno {
            use crate::vfs::FsError::*;
            match e { $($variant => $errno),+ }
        }

        /// Decode a response `status` (a WASI-style errno, e.g. a [`crate::fs::servedfs`]
        /// server's reply) back into a `Result` — the exact inverse of [`errno_from_fs`].
        pub fn fs_result_from_errno(status: i32) -> crate::vfs::Result<()> {
            use crate::vfs::FsError::*;
            if status == ESUCCESS {
                return Ok(());
            }
            Err(match status {
                $($errno => $variant,)+
                _ => IoError,
            })
        }
    };
}

fs_errno_table! {
    NotFound => ENOENT,
    AlreadyExists => EEXIST,
    NotDir => ENOTDIR,
    IsDir => EISDIR,
    PermissionDenied => EPERM,
    AccessDenied => EACCES,
    InvalidPath => EINVAL,
    NotEmpty => ENOTEMPTY,
    IoError => EIO,
    BadFileDescriptor => EBADF,
    NotImplemented => ENOSYS,
    CrossDevice => EXDEV,
    Loop => ELOOP,
    // `WouldBlock` is normally intercepted as a yield before errno mapping; if it ever
    // escapes a non-yielding op it surfaces as EAGAIN.
    WouldBlock => EAGAIN,
}
