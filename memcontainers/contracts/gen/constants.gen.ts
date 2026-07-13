// @generated from contracts/constants.kdl by //contracts/codegen:projector — do not edit.

// syscall ABI version: (major << 16) | minor
export const SYS_ABI_MAJOR = 1;
export const SYS_ABI_MINOR = 7;
export function abiVersion(): number { return (SYS_ABI_MAJOR << 16) | SYS_ABI_MINOR; }

// errno
export const ESUCCESS = 0;
export const EACCES = 2;
export const EAGAIN = 6;
export const EBADF = 8;
export const ECHILD = 10;
export const EEXIST = 20;
export const EINTR = 27;
export const EINVAL = 28;
export const EIO = 29;
export const EISDIR = 31;
export const ELOOP = 32;
export const EMFILE = 33;
export const ENOENT = 44;
export const ENOSYS = 52;
export const EMSGSIZE = 53;
export const ENOTDIR = 54;
export const ENOTEMPTY = 55;
export const EPERM = 63;
export const EPIPE = 64;
export const ESRCH = 71;
export const ETIMEDOUT = 73;
export const EXDEV = 75;

// tier
export const TIER_INHERIT = 0;
export const TIER_FULL = 1;
export const TIER_READ_WRITE = 2;
export const TIER_READ_ONLY = 3;
export const TIER_ISOLATED = 4;

// capability
export const CAP_FS_READ = 1;
export const CAP_FS_WRITE = 2;
export const CAP_SPAWN = 4;
export const CAP_NET = 8;
export const CAP_PERSIST = 16;
export const CAP_AMBIENT = 32;
export const CAP_SCRATCH = 64;
export const CAP_MOUNT = 128;

// tier → capability ceiling — the kernel's Tier::caps() consumes this (single source)
export function tierCaps(tier: number): number {
  switch (tier) {
    case TIER_INHERIT: return 0;
    case TIER_FULL: return CAP_FS_READ | CAP_FS_WRITE | CAP_SPAWN | CAP_NET | CAP_PERSIST | CAP_AMBIENT | CAP_SCRATCH | CAP_MOUNT;
    case TIER_READ_WRITE: return CAP_FS_READ | CAP_FS_WRITE | CAP_AMBIENT | CAP_SCRATCH;
    case TIER_READ_ONLY: return CAP_FS_READ | CAP_AMBIENT | CAP_SCRATCH;
    case TIER_ISOLATED: return CAP_FS_READ;
    default: return 0;
  }
}

// open-flags
export const O_READ = 1;
export const O_WRITE = 2;
export const O_CREATE = 4;
export const O_TRUNC = 8;
export const O_APPEND = 16;

// seek
export const SEEK_SET = 0;
export const SEEK_CUR = 1;
export const SEEK_END = 2;

// waitpid
export const WNOHANG = 1;

// worker
export const MAX_WORKERS = 4;

// poll
export const POLLIN = 1;
export const POLLOUT = 4;
export const POLLERR = 8;
export const POLLHUP = 16;
export const POLL_BLOCK = -1;

// signal
export const SIGHUP = 1;
export const SIGINT = 2;
export const SIGQUIT = 3;
export const SIGKILL = 9;
export const SIGUSR1 = 10;
export const SIGUSR2 = 12;
export const SIGTERM = 15;
export const SIGCHLD = 17;
export const SIGCONT = 18;
export const SIGSTOP = 19;
export const SIGTSTP = 20;
export const SIG_DFL = 0;
export const SIG_IGN = 1;
export const STOPPED_STATUS_BASE = 65536;

// serve-op
export const SERVE_OP_OPEN = 0;
export const SERVE_OP_READDIR = 1;
export const SERVE_OP_MKDIR = 2;
export const SERVE_OP_UNLINK = 3;
export const SERVE_OP_RENAME = 4;
export const SERVE_OP_STAT = 5;
export const SERVE_DIRENT_FILE = 0;
export const SERVE_DIRENT_DIR = 1;
export const SERVE_DIRENT_SYMLINK = 2;

// mount-op
export const MOUNT_OP_OPEN = 0;
export const MOUNT_OP_READDIR = 1;
export const MOUNT_OP_MKDIR = 2;
export const MOUNT_OP_UNLINK = 3;
export const MOUNT_OP_RENAME = 4;
export const MOUNT_OP_STAT = 5;
export const MOUNT_OP_WRITE = 6;

// persist-op
export const PERSIST_OP_GET = 1;
export const PERSIST_OP_PUT = 2;
export const PERSIST_OP_DELETE = 3;
export const PERSIST_OP_LIST = 4;
export const PERSIST_GET_ABSENT = 0;
export const PERSIST_GET_PRESENT = 1;

// stat-record
export const STAT_NODE_FILE = 0;
export const STAT_NODE_DIR = 1;
export const STAT_NODE_SYMLINK = 2;
export const STAT_REC_SIZE_OFF = 0;
export const STAT_REC_NODE_TYPE_OFF = 8;
export const STAT_REC_NLINK_OFF = 12;
export const STAT_REC_MODE_OFF = 16;
export const STAT_REC_MTIME_OFF = 20;
export const STAT_REC_ATIME_OFF = 28;
export const STAT_REC_CTIME_OFF = 36;
export const STAT_REC_LEN = 44;
export const WIRE_VERSION = 2;

// the argv[1] marker the kernel passes to spawn a binary in SERVICE mode (SYSTEMS.md)
export const SERVICE_MARKER = "--mc-serve";
