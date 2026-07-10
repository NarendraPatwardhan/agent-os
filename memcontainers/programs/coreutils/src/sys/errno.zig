//! POSIX-classic errno surface for the mc syscall facade.
//! Everything above `sys/` only ever sees `Errno`.

pub const Errno = enum(i32) {
    SUCCESS = 0,
    ENOENT,
    EEXIST,
    EPERM,
    EINTR,
    EINVAL,
    EXDEV,
    ELOOP,
    ENOTDIR,
    ENOTEMPTY,
    EBADF,
    EIO,
    ENOSYS,
    EACCES,
    ENOMEM,
    ENOSPC,
    EISDIR,
    EMFILE,
    ENFILE,
    ERANGE,
    EPIPE,
    EAGAIN,
    ESPIPE,
    ESRCH,
    ECHILD,
    ENXIO,
    ETIMEDOUT,
    ECONNREFUSED,
    EMSGSIZE,
    ENAMETOOLONG,
    EUNKNOWN, // catch-all for anything not mapped above

    pub fn strerror(e: Errno) []const u8 {
        return switch (e) {
            .SUCCESS => "Success",
            .ENOENT => "No such file or directory",
            .EEXIST => "File exists",
            .EPERM => "Operation not permitted",
            .EINTR => "Interrupted system call",
            .EINVAL => "Invalid argument",
            .EXDEV => "Cross-device link",
            .ELOOP => "Too many levels of symbolic links",
            .ENOTDIR => "Not a directory",
            .ENOTEMPTY => "Directory not empty",
            .EBADF => "Bad file descriptor",
            .EIO => "Input/output error",
            .ENOSYS => "Function not implemented",
            .EACCES => "Permission denied",
            .ENOMEM => "Cannot allocate memory",
            .ENOSPC => "No space left on device",
            .EISDIR => "Is a directory",
            .EMFILE => "Too many open files",
            .ENFILE => "Too many open files in system",
            .ERANGE => "Result too large",
            .EPIPE => "Broken pipe",
            .EAGAIN => "Resource temporarily unavailable",
            .ESPIPE => "Illegal seek",
            .ESRCH => "No such process",
            .ECHILD => "No child processes",
            .ENXIO => "No such device or address",
            .ETIMEDOUT => "Connection timed out",
            .ECONNREFUSED => "Connection refused",
            .EMSGSIZE => "Message too long",
            .ENAMETOOLONG => "File name too long",
            .EUNKNOWN => "Unknown error",
        };
    }
};

/// The error set mirrored 1:1 against `Errno` (minus SUCCESS), used as `Error!T` return
/// types across `sys/root.zig`. `toErrno`/`fromErrno` convert between the two.
pub const Error = error{
    ENOENT,
    EEXIST,
    EPERM,
    EINTR,
    EINVAL,
    EXDEV,
    ELOOP,
    ENOTDIR,
    ENOTEMPTY,
    EBADF,
    EIO,
    ENOSYS,
    EACCES,
    ENOMEM,
    ENOSPC,
    EISDIR,
    EMFILE,
    ENFILE,
    ERANGE,
    EPIPE,
    EAGAIN,
    ESPIPE,
    ESRCH,
    ECHILD,
    ENXIO,
    ETIMEDOUT,
    ECONNREFUSED,
    EMSGSIZE,
    ENAMETOOLONG,
    EUNKNOWN,
};

pub fn fromErrno(e: Errno) Error {
    return switch (e) {
        .SUCCESS => unreachable,
        inline else => |tag| @field(Error, @tagName(tag)),
    };
}

pub fn toErrno(e: Error) Errno {
    return switch (e) {
        inline else => |tag| @field(Errno, @errorName(tag)),
    };
}
