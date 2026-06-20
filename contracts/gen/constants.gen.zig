// @generated from contracts/constants.kdl by //contracts/codegen:projector — do not edit.

// syscall ABI version: (major << 16) | minor
pub const SYS_ABI_MAJOR: i64 = 1;
pub const SYS_ABI_MINOR: i64 = 3;
pub fn abi_version() i64 { return (SYS_ABI_MAJOR << 16) | SYS_ABI_MINOR; }

// errno
pub const ESUCCESS: i32 = 0;
pub const EACCES: i32 = 2;
pub const EAGAIN: i32 = 6;
pub const EBADF: i32 = 8;
pub const ECHILD: i32 = 10;
pub const EEXIST: i32 = 20;
pub const EINTR: i32 = 27;
pub const EINVAL: i32 = 28;
pub const EIO: i32 = 29;
pub const EISDIR: i32 = 31;
pub const ELOOP: i32 = 32;
pub const EMFILE: i32 = 33;
pub const ENOENT: i32 = 44;
pub const ENOSYS: i32 = 52;
pub const ENOTDIR: i32 = 54;
pub const ENOTEMPTY: i32 = 55;
pub const EPERM: i32 = 63;
pub const EPIPE: i32 = 64;
pub const ESRCH: i32 = 71;
pub const EXDEV: i32 = 75;

// tier
pub const TIER_INHERIT: i32 = 0;
pub const TIER_FULL: i32 = 1;
pub const TIER_READ_WRITE: i32 = 2;
pub const TIER_READ_ONLY: i32 = 3;
pub const TIER_ISOLATED: i32 = 4;

// capability
pub const CAP_FS_READ: u8 = 1;
pub const CAP_FS_WRITE: u8 = 2;
pub const CAP_SPAWN: u8 = 4;
pub const CAP_NET: u8 = 8;
pub const CAP_PERSIST: u8 = 16;
pub const CAP_AMBIENT: u8 = 32;
pub const CAP_SCRATCH: u8 = 64;
pub const CAP_MOUNT: u8 = 128;

// open-flags
pub const O_READ: i32 = 1;
pub const O_WRITE: i32 = 2;
pub const O_CREATE: i32 = 4;
pub const O_TRUNC: i32 = 8;
pub const O_APPEND: i32 = 16;

// seek
pub const SEEK_SET: i32 = 0;
pub const SEEK_CUR: i32 = 1;
pub const SEEK_END: i32 = 2;

// waitpid
pub const WNOHANG: i32 = 1;

// poll
pub const POLLIN: i32 = 1;
pub const POLLOUT: i32 = 4;
pub const POLLERR: i32 = 8;
pub const POLLHUP: i32 = 16;
pub const POLL_BLOCK: i32 = -1;

// signal
pub const SIGHUP: i32 = 1;
pub const SIGINT: i32 = 2;
pub const SIGKILL: i32 = 9;
pub const SIGTERM: i32 = 15;
pub const SIGCHLD: i32 = 17;
pub const SIGCONT: i32 = 18;
pub const SIGTSTP: i32 = 20;
pub const SIG_DFL: i32 = 0;
pub const SIG_IGN: i32 = 1;
pub const STOPPED_STATUS_BASE: i32 = 65536;

// serve-op
pub const SERVE_OP_OPEN: u32 = 0;
pub const SERVE_OP_READDIR: u32 = 1;
pub const SERVE_OP_MKDIR: u32 = 2;
pub const SERVE_OP_UNLINK: u32 = 3;
pub const SERVE_OP_RENAME: u32 = 4;
pub const SERVE_OP_STAT: u32 = 5;
pub const SERVE_DIRENT_FILE: u32 = 0;
pub const SERVE_DIRENT_DIR: u32 = 1;
pub const SERVE_DIRENT_SYMLINK: u32 = 2;

// mount-op
pub const MOUNT_OP_OPEN: u32 = 0;
pub const MOUNT_OP_READDIR: u32 = 1;
pub const MOUNT_OP_MKDIR: u32 = 2;
pub const MOUNT_OP_UNLINK: u32 = 3;
pub const MOUNT_OP_RENAME: u32 = 4;
pub const MOUNT_OP_STAT: u32 = 5;
pub const MOUNT_OP_WRITE: u32 = 6;
pub const WIRE_VERSION: u32 = 1;
