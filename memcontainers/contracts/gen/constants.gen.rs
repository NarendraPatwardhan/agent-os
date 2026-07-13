// @generated from contracts/constants.kdl by //contracts/codegen:projector — do not edit.
#![no_std]

// syscall ABI version: (major << 16) | minor
pub const SYS_ABI_MAJOR: i64 = 1;
pub const SYS_ABI_MINOR: i64 = 7;
pub const fn abi_version() -> i64 { (SYS_ABI_MAJOR << 16) | SYS_ABI_MINOR }

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
pub const EMSGSIZE: i32 = 53;
pub const ENOTDIR: i32 = 54;
pub const ENOTEMPTY: i32 = 55;
pub const EPERM: i32 = 63;
pub const EPIPE: i32 = 64;
pub const ESRCH: i32 = 71;
pub const ETIMEDOUT: i32 = 73;
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

// tier → capability ceiling — the kernel's Tier::caps() consumes this (single source)
pub const fn tier_caps(tier: i32) -> u8 {
    match tier {
        TIER_INHERIT => 0,
        TIER_FULL => CAP_FS_READ | CAP_FS_WRITE | CAP_SPAWN | CAP_NET | CAP_PERSIST | CAP_AMBIENT | CAP_SCRATCH | CAP_MOUNT,
        TIER_READ_WRITE => CAP_FS_READ | CAP_FS_WRITE | CAP_AMBIENT | CAP_SCRATCH,
        TIER_READ_ONLY => CAP_FS_READ | CAP_AMBIENT | CAP_SCRATCH,
        TIER_ISOLATED => CAP_FS_READ,
        _ => 0,
    }
}

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

// worker
pub const MAX_WORKERS: i32 = 4;

// poll
pub const POLLIN: i32 = 1;
pub const POLLOUT: i32 = 4;
pub const POLLERR: i32 = 8;
pub const POLLHUP: i32 = 16;
pub const POLL_BLOCK: i32 = -1;

// signal
pub const SIGHUP: i32 = 1;
pub const SIGINT: i32 = 2;
pub const SIGQUIT: i32 = 3;
pub const SIGKILL: i32 = 9;
pub const SIGUSR1: i32 = 10;
pub const SIGUSR2: i32 = 12;
pub const SIGTERM: i32 = 15;
pub const SIGCHLD: i32 = 17;
pub const SIGCONT: i32 = 18;
pub const SIGSTOP: i32 = 19;
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

// persist-op
pub const PERSIST_OP_GET: u32 = 1;
pub const PERSIST_OP_PUT: u32 = 2;
pub const PERSIST_OP_DELETE: u32 = 3;
pub const PERSIST_OP_LIST: u32 = 4;
pub const PERSIST_GET_ABSENT: u32 = 0;
pub const PERSIST_GET_PRESENT: u32 = 1;

// stat-record
pub const STAT_NODE_FILE: i32 = 0;
pub const STAT_NODE_DIR: i32 = 1;
pub const STAT_NODE_SYMLINK: i32 = 2;
pub const STAT_REC_SIZE_OFF: i32 = 0;
pub const STAT_REC_NODE_TYPE_OFF: i32 = 8;
pub const STAT_REC_NLINK_OFF: i32 = 12;
pub const STAT_REC_MODE_OFF: i32 = 16;
pub const STAT_REC_MTIME_OFF: i32 = 20;
pub const STAT_REC_ATIME_OFF: i32 = 28;
pub const STAT_REC_CTIME_OFF: i32 = 36;
pub const STAT_REC_LEN: i32 = 44;
pub const WIRE_VERSION: u32 = 2;

// the argv[1] marker the kernel passes to spawn a binary in SERVICE mode (SYSTEMS.md)
pub const SERVICE_MARKER: &str = "--mc-serve";
