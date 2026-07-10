//! Shared types for the mc sys interface (DESIGN.md §4.1).

const errno = @import("errno.zig");

pub const Errno = errno.Errno;
pub const Error = errno.Error;

pub const Fd = i32;
pub const Pid = i32;

pub const Whence = enum { set, cur, end };

pub const Stat = struct {
    size: u64,
    mode: u32,
    nlink: u32,
    atime_ms: i64,
    mtime_ms: i64,
    ctime_ms: i64,
    is_dir: bool,
    is_symlink: bool,

    pub fn readable(s: Stat) bool {
        return s.mode & 0o400 != 0;
    }
    pub fn writable(s: Stat) bool {
        return s.mode & 0o200 != 0;
    }
    pub fn executable(s: Stat) bool {
        return s.mode & 0o100 != 0;
    }
};

pub const O = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    trunc: bool = false,
    append: bool = false,
    _pad: u3 = 0,
};

pub const Times = struct { atime_ms: i64, mtime_ms: i64 };

pub const Sig = enum { hup, int, quit, kill, term, usr1, usr2, cont, stop, chld, tstp };
pub const Disp = enum { default, ignore };

pub const PollFd = struct {
    fd: Fd,
    want_read: bool,
    want_write: bool,
    readable: bool = false,
    writable: bool = false,
};

/// A read/write fd pair from `pipe()` -- a non-seekable channel.
pub const Pipe = struct { r: Fd, w: Fd };
