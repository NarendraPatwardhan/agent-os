// @generated from contracts/syscalls.kdl by //contracts/codegen:projector — do not edit.
#![no_std]

pub const SYSCALL_NAMES: &[&str] = &[
    "mc_sys_write",
    "mc_sys_read",
    "mc_sys_open",
    "mc_sys_close",
    "mc_sys_args",
    "mc_sys_stat",
    "mc_sys_readdir",
    "mc_sys_mkdir",
    "mc_sys_unlink",
    "mc_sys_rename",
    "mc_sys_symlink",
    "mc_sys_link",
    "mc_sys_readlink",
    "mc_sys_lstat",
    "mc_sys_chmod",
    "mc_sys_utimes",
    "mc_sys_getcwd",
    "mc_sys_chdir",
    "mc_sys_lseek",
    "mc_sys_ftruncate",
    "mc_sys_poll",
    "mc_sys_bind",
    "mc_sys_unmount",
    "mc_sys_serve",
    "mc_sys_serve_recv",
    "mc_sys_serve_respond",
    "mc_sys_svc_serve",
    "mc_sys_svc_recv",
    "mc_sys_svc_respond",
    "mc_sys_svc_connect",
    "mc_sys_svc_call",
    "mc_sys_pipe",
    "mc_sys_dup",
    "mc_sys_dup2",
    "mc_sys_isatty",
    "mc_sys_getpid",
    "mc_sys_getppid",
    "mc_sys_spawn",
    "mc_sys_waitpid",
    "mc_sys_nice",
    "mc_sys_kill",
    "mc_sys_sigdisp",
    "mc_sys_setpgid",
    "mc_sys_tcsetpgrp",
    "mc_sys_http_get",
    "mc_sys_http_request",
    "mc_sys_http_status",
    "mc_sys_ws_open",
    "mc_sys_host_call",
    "mc_sys_time_monotonic",
    "mc_sys_time_realtime",
    "mc_sys_sleep_ms",
    "mc_sys_random",
    "mc_sys_abi_version",
    "mc_sys_exit",
    "mc_sys_pcall",
    "mc_sys_set_throw",
];

/// The canonical table. A consumer hands its own `$emit!` callback (the kernel's
/// dispatch, the sysroot's extern block, the host's import table) and cannot drift.
#[macro_export]
macro_rules! mc_syscall_table {
    ($emit:path) => { $emit! {
        mc_sys_write => Write (fd: i32, ptr: u32, len: u32, ret_n: u32) [i32];
        mc_sys_read => Read (fd: i32, ptr: u32, len: u32, ret_n: u32) [i32];
        mc_sys_open => Open (path_ptr: u32, path_len: u32, flags: i32, ret_fd: u32) [i32];
        mc_sys_close => Close (fd: i32) [i32];
        mc_sys_args => Args (ptr: u32, len: u32, ret_len: u32) [i32];
        mc_sys_stat => Stat (path_ptr: u32, path_len: u32, ret_stat: u32) [i32];
        mc_sys_readdir => Readdir (path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32) [i32];
        mc_sys_mkdir => Mkdir (path_ptr: u32, path_len: u32) [i32];
        mc_sys_unlink => Unlink (path_ptr: u32, path_len: u32) [i32];
        mc_sys_rename => Rename (from_ptr: u32, from_len: u32, to_ptr: u32, to_len: u32) [i32];
        mc_sys_symlink => Symlink (target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) [i32];
        mc_sys_link => Link (old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32) [i32];
        mc_sys_readlink => Readlink (path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32) [i32];
        mc_sys_lstat => Lstat (path_ptr: u32, path_len: u32, ret_stat: u32) [i32];
        mc_sys_chmod => Chmod (path_ptr: u32, path_len: u32, mode: u32) [i32];
        mc_sys_utimes => Utimes (path_ptr: u32, path_len: u32, times_ptr: u32) [i32];
        mc_sys_getcwd => Getcwd (buf: u32, buf_len: u32, ret_len: u32) [i32];
        mc_sys_chdir => Chdir (path_ptr: u32, path_len: u32) [i32];
        mc_sys_lseek => Lseek (fd: i32, off_ptr: u32, whence: i32) [i32];
        mc_sys_ftruncate => Ftruncate (fd: i32, size_lo: u32, size_hi: u32) [i32];
        mc_sys_poll => Poll (fds_ptr: u32, nfds: u32, timeout_ms: i32, ret_ready: u32) [i32];
        mc_sys_bind => Bind (old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32) [i32];
        mc_sys_unmount => Unmount (path_ptr: u32, path_len: u32) [i32];
        mc_sys_serve => Serve (path_ptr: u32, path_len: u32, ret_fd: u32) [i32];
        mc_sys_serve_recv => ServeRecv (fd: i32, buf: u32, buf_len: u32, ret_len: u32) [i32];
        mc_sys_serve_respond => ServeRespond (fd: i32, req_id: u32, status: i32, data_ptr: u32, data_len: u32) [i32];
        mc_sys_svc_serve => SvcServe (name_ptr: u32, name_len: u32, ret_fd: u32) [i32];
        mc_sys_svc_recv => SvcRecv (fd: i32, buf: u32, buf_len: u32, hbuf: u32, hbuf_len: u32, ret_len: u32) [i32];
        mc_sys_svc_respond => SvcRespond (fd: i32, session: u32, req_id: u32, status: i32, data_ptr: u32, data_len: u32, last: u32) [i32];
        mc_sys_svc_connect => SvcConnect (name_ptr: u32, name_len: u32, ret_fd: u32) [i32];
        mc_sys_svc_call => SvcCall (fd: i32, req_ptr: u32, req_len: u32, handles_ptr: u32, nhandles: u32, ret_fd: u32) [i32];
        mc_sys_pipe => Pipe (ret_r: u32, ret_w: u32) [i32];
        mc_sys_dup => Dup (fd: i32, ret_fd: u32) [i32];
        mc_sys_dup2 => Dup2 (old_fd: i32, new_fd: i32) [i32];
        mc_sys_isatty => Isatty (fd: i32, ret: u32) [i32];
        mc_sys_getpid => Getpid (ret: u32) [i32];
        mc_sys_getppid => Getppid (ret: u32) [i32];
        mc_sys_spawn => Spawn (argv_ptr: u32, argv_len: u32, in_fd: i32, out_fd: i32, err_fd: i32, tier: i32, ret_pid: u32) [i32];
        mc_sys_waitpid => Waitpid (pid: i32, opts: i32, ret_status: u32, ret_pid: u32) [i32];
        mc_sys_nice => Nice (inc: i32, ret: u32) [i32];
        mc_sys_kill => Kill (pid: i32, sig: i32) [i32];
        mc_sys_sigdisp => Sigdisp (sig: i32, disp: i32) [i32];
        mc_sys_setpgid => Setpgid (pid: i32, pgid: i32) [i32];
        mc_sys_tcsetpgrp => Tcsetpgrp (pgid: i32) [i32];
        mc_sys_http_get => HttpGet (url_ptr: u32, url_len: u32, ret_fd: u32) [i32];
        mc_sys_http_request => HttpRequest (req_ptr: u32, req_len: u32, ret_fd: u32) [i32];
        mc_sys_http_status => HttpStatus (fd: i32, ret_status: u32) [i32];
        mc_sys_ws_open => WsOpen (url_ptr: u32, url_len: u32, ret_fd: u32) [i32];
        mc_sys_host_call => HostCall (req_ptr: u32, req_len: u32, ret_fd: u32) [i32];
        mc_sys_time_monotonic => TimeMonotonic (ret: u32) [i32];
        mc_sys_time_realtime => TimeRealtime (ret: u32) [i32];
        mc_sys_sleep_ms => SleepMs (ms: i32) [i32];
        mc_sys_random => Random (ptr: u32, len: u32) [i32];
        mc_sys_abi_version => AbiVersion (ret: u32) [i32];
        mc_sys_exit => Exit (code: i32) [noreturn];
        mc_sys_pcall => Pcall () [i32];
        mc_sys_set_throw => SetThrow (code: i32) [i32];
    } };
}

pub const SYSCALL_CAPS: &[(&str, &[&str])] = &[
    ("mc_sys_open", &["CAP_FS_READ"]),
    ("mc_sys_stat", &["CAP_FS_READ"]),
    ("mc_sys_readdir", &["CAP_FS_READ"]),
    ("mc_sys_mkdir", &["CAP_FS_WRITE", "CAP_SCRATCH"]),
    ("mc_sys_unlink", &["CAP_FS_WRITE", "CAP_SCRATCH"]),
    ("mc_sys_rename", &["CAP_FS_WRITE", "CAP_SCRATCH"]),
    ("mc_sys_symlink", &["CAP_FS_WRITE", "CAP_SCRATCH"]),
    ("mc_sys_link", &["CAP_FS_WRITE", "CAP_SCRATCH"]),
    ("mc_sys_readlink", &["CAP_FS_READ"]),
    ("mc_sys_lstat", &["CAP_FS_READ"]),
    ("mc_sys_chmod", &["CAP_FS_WRITE", "CAP_SCRATCH"]),
    ("mc_sys_utimes", &["CAP_FS_WRITE", "CAP_SCRATCH"]),
    ("mc_sys_chdir", &["CAP_FS_READ"]),
    ("mc_sys_bind", &["CAP_MOUNT"]),
    ("mc_sys_unmount", &["CAP_MOUNT"]),
    ("mc_sys_serve", &["CAP_MOUNT"]),
    ("mc_sys_spawn", &["CAP_SPAWN"]),
    ("mc_sys_http_get", &["CAP_NET"]),
    ("mc_sys_http_request", &["CAP_NET"]),
    ("mc_sys_ws_open", &["CAP_NET"]),
    ("mc_sys_host_call", &["CAP_NET"]),
    ("mc_sys_time_monotonic", &["CAP_AMBIENT"]),
    ("mc_sys_time_realtime", &["CAP_AMBIENT"]),
    ("mc_sys_sleep_ms", &["CAP_AMBIENT"]),
    ("mc_sys_random", &["CAP_AMBIENT"]),
];
