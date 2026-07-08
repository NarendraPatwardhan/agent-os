//! errno.zig — the single FsError <-> errno mapping.
//!
//! One forward map (`FsError` -> WASI errno) and its exact inverse (`errno` -> `FsError`),
//! kept adjacent so they cannot drift. Consumed by the syscall ABI (`syscall.zig`), the control
//! channel (`control.zig`), and the served/mount proxy filesystems (`fs/servedfs.zig`,
//! `fs/mountfs.zig`) — each of which previously hand-copied one direction, reintroducing the
//! drift hazard the Rust oracle's `fs_errno_table!` macro designed away (it generates both
//! directions from one pair-list).
//!
//! Invariant: A9 — a capability/policy denial must surface as a *specific* errno, never a host
//!   trap; a security-relevant table like this must therefore have exactly one source. The two
//!   functions here are exact inverses by construction: every forward arm has a matching reverse
//!   arm, and any errno with no reverse arm folds to `IoError` (mirroring how the forward map's
//!   `IoError` is the residual `EIO`).
//! Not here: the sign convention. The syscall ABI returns *positive* WASI errno; the control
//!   channel negates (see each file's local `neg`). This table is sign-agnostic — it maps names.

const constants = @import("constants_zig");
const vfs = @import("vfs.zig");
const FsError = vfs.FsError;

/// FsError -> WASI errno (positive). Callers apply their own sign convention.
pub fn errnoFromFs(e: FsError) i32 {
    return switch (e) {
        FsError.NotFound => constants.ENOENT,
        FsError.AlreadyExists => constants.EEXIST,
        FsError.NotDir => constants.ENOTDIR,
        FsError.IsDir => constants.EISDIR,
        FsError.PermissionDenied => constants.EPERM,
        FsError.AccessDenied => constants.EACCES,
        FsError.InvalidPath => constants.EINVAL,
        FsError.NotEmpty => constants.ENOTEMPTY,
        FsError.IoError => constants.EIO,
        FsError.BadFileDescriptor => constants.EBADF,
        FsError.NotImplemented => constants.ENOSYS,
        FsError.CrossDevice => constants.EXDEV,
        FsError.WouldBlock => constants.EAGAIN,
        FsError.MessageTooBig => constants.EMSGSIZE,
        FsError.Loop => constants.ELOOP,
    };
}

/// errno -> FsError, the exact inverse of `errnoFromFs`. `0` is success (returns void); any errno
/// with no forward arm folds to `IoError` (the residual, matching `errnoFromFs`'s `EIO`).
pub fn fsResultFromErrno(errno: i32) FsError!void {
    if (errno == 0) return;
    return switch (errno) {
        constants.ENOENT => FsError.NotFound,
        constants.EEXIST => FsError.AlreadyExists,
        constants.ENOTDIR => FsError.NotDir,
        constants.EISDIR => FsError.IsDir,
        constants.EPERM => FsError.PermissionDenied,
        constants.EACCES => FsError.AccessDenied,
        constants.EINVAL => FsError.InvalidPath,
        constants.ENOTEMPTY => FsError.NotEmpty,
        constants.EBADF => FsError.BadFileDescriptor,
        constants.ENOSYS => FsError.NotImplemented,
        constants.EXDEV => FsError.CrossDevice,
        constants.EAGAIN => FsError.WouldBlock,
        constants.EMSGSIZE => FsError.MessageTooBig,
        constants.ELOOP => FsError.Loop,
        else => FsError.IoError,
    };
}
