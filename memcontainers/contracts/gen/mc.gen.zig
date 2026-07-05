// @generated from contracts/syscalls.kdl by //contracts/codegen:projector — do not edit.

pub const Arg = struct { name: []const u8, ty: []const u8 };
pub const Desc = struct { name: [:0]const u8, variant: []const u8, args: []const Arg, ret: []const u8, signature: [:0]const u8 };

pub const SYSCALLS = [_]Desc{
    .{ .name = "mc_sys_write", .variant = "Write", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "ptr", .ty = "u32" }, .{ .name = "len", .ty = "u32" }, .{ .name = "ret_n", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_read", .variant = "Read", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "ptr", .ty = "u32" }, .{ .name = "len", .ty = "u32" }, .{ .name = "ret_n", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_open", .variant = "Open", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "flags", .ty = "i32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_close", .variant = "Close", .args = &.{ .{ .name = "fd", .ty = "i32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_args", .variant = "Args", .args = &.{ .{ .name = "ptr", .ty = "u32" }, .{ .name = "len", .ty = "u32" }, .{ .name = "ret_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_stat", .variant = "Stat", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "ret_stat", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_readdir", .variant = "Readdir", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "buf", .ty = "u32" }, .{ .name = "buf_len", .ty = "u32" }, .{ .name = "ret_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiiii)" },
    .{ .name = "mc_sys_mkdir", .variant = "Mkdir", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_unlink", .variant = "Unlink", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_rename", .variant = "Rename", .args = &.{ .{ .name = "from_ptr", .ty = "u32" }, .{ .name = "from_len", .ty = "u32" }, .{ .name = "to_ptr", .ty = "u32" }, .{ .name = "to_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_symlink", .variant = "Symlink", .args = &.{ .{ .name = "target_ptr", .ty = "u32" }, .{ .name = "target_len", .ty = "u32" }, .{ .name = "link_ptr", .ty = "u32" }, .{ .name = "link_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_link", .variant = "Link", .args = &.{ .{ .name = "old_ptr", .ty = "u32" }, .{ .name = "old_len", .ty = "u32" }, .{ .name = "new_ptr", .ty = "u32" }, .{ .name = "new_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_readlink", .variant = "Readlink", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "buf", .ty = "u32" }, .{ .name = "buf_len", .ty = "u32" }, .{ .name = "ret_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiiii)" },
    .{ .name = "mc_sys_lstat", .variant = "Lstat", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "ret_stat", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_chmod", .variant = "Chmod", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "mode", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_utimes", .variant = "Utimes", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "times_ptr", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_getcwd", .variant = "Getcwd", .args = &.{ .{ .name = "buf", .ty = "u32" }, .{ .name = "buf_len", .ty = "u32" }, .{ .name = "ret_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_chdir", .variant = "Chdir", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_lseek", .variant = "Lseek", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "off_ptr", .ty = "u32" }, .{ .name = "whence", .ty = "i32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_ftruncate", .variant = "Ftruncate", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "size_lo", .ty = "u32" }, .{ .name = "size_hi", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_poll", .variant = "Poll", .args = &.{ .{ .name = "fds_ptr", .ty = "u32" }, .{ .name = "nfds", .ty = "u32" }, .{ .name = "timeout_ms", .ty = "i32" }, .{ .name = "ret_ready", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_bind", .variant = "Bind", .args = &.{ .{ .name = "old_ptr", .ty = "u32" }, .{ .name = "old_len", .ty = "u32" }, .{ .name = "new_ptr", .ty = "u32" }, .{ .name = "new_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_unmount", .variant = "Unmount", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_serve", .variant = "Serve", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_serve_recv", .variant = "ServeRecv", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "buf", .ty = "u32" }, .{ .name = "buf_len", .ty = "u32" }, .{ .name = "ret_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_serve_respond", .variant = "ServeRespond", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "req_id", .ty = "u32" }, .{ .name = "status", .ty = "i32" }, .{ .name = "data_ptr", .ty = "u32" }, .{ .name = "data_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiiii)" },
    .{ .name = "mc_sys_svc_serve", .variant = "SvcServe", .args = &.{ .{ .name = "name_ptr", .ty = "u32" }, .{ .name = "name_len", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_svc_recv", .variant = "SvcRecv", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "buf", .ty = "u32" }, .{ .name = "buf_len", .ty = "u32" }, .{ .name = "hbuf", .ty = "u32" }, .{ .name = "hbuf_len", .ty = "u32" }, .{ .name = "ret_len", .ty = "u32" } }, .ret = "i32", .signature = "i(iiiiii)" },
    .{ .name = "mc_sys_svc_respond", .variant = "SvcRespond", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "session", .ty = "u32" }, .{ .name = "req_id", .ty = "u32" }, .{ .name = "status", .ty = "i32" }, .{ .name = "data_ptr", .ty = "u32" }, .{ .name = "data_len", .ty = "u32" }, .{ .name = "last", .ty = "u32" } }, .ret = "i32", .signature = "i(iiiiiii)" },
    .{ .name = "mc_sys_svc_connect", .variant = "SvcConnect", .args = &.{ .{ .name = "name_ptr", .ty = "u32" }, .{ .name = "name_len", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_svc_call", .variant = "SvcCall", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "req_ptr", .ty = "u32" }, .{ .name = "req_len", .ty = "u32" }, .{ .name = "handles_ptr", .ty = "u32" }, .{ .name = "nhandles", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iiiiii)" },
    .{ .name = "mc_sys_pipe", .variant = "Pipe", .args = &.{ .{ .name = "ret_r", .ty = "u32" }, .{ .name = "ret_w", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_dup", .variant = "Dup", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_dup2", .variant = "Dup2", .args = &.{ .{ .name = "old_fd", .ty = "i32" }, .{ .name = "new_fd", .ty = "i32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_isatty", .variant = "Isatty", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "ret", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_getpid", .variant = "Getpid", .args = &.{ .{ .name = "ret", .ty = "u32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_getppid", .variant = "Getppid", .args = &.{ .{ .name = "ret", .ty = "u32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_spawn", .variant = "Spawn", .args = &.{ .{ .name = "argv_ptr", .ty = "u32" }, .{ .name = "argv_len", .ty = "u32" }, .{ .name = "in_fd", .ty = "i32" }, .{ .name = "out_fd", .ty = "i32" }, .{ .name = "err_fd", .ty = "i32" }, .{ .name = "tier", .ty = "i32" }, .{ .name = "ret_pid", .ty = "u32" } }, .ret = "i32", .signature = "i(iiiiiii)" },
    .{ .name = "mc_sys_waitpid", .variant = "Waitpid", .args = &.{ .{ .name = "pid", .ty = "i32" }, .{ .name = "opts", .ty = "i32" }, .{ .name = "ret_status", .ty = "u32" }, .{ .name = "ret_pid", .ty = "u32" } }, .ret = "i32", .signature = "i(iiii)" },
    .{ .name = "mc_sys_nice", .variant = "Nice", .args = &.{ .{ .name = "inc", .ty = "i32" }, .{ .name = "ret", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_kill", .variant = "Kill", .args = &.{ .{ .name = "pid", .ty = "i32" }, .{ .name = "sig", .ty = "i32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_sigdisp", .variant = "Sigdisp", .args = &.{ .{ .name = "sig", .ty = "i32" }, .{ .name = "disp", .ty = "i32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_setpgid", .variant = "Setpgid", .args = &.{ .{ .name = "pid", .ty = "i32" }, .{ .name = "pgid", .ty = "i32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_tcsetpgrp", .variant = "Tcsetpgrp", .args = &.{ .{ .name = "pgid", .ty = "i32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_http_get", .variant = "HttpGet", .args = &.{ .{ .name = "url_ptr", .ty = "u32" }, .{ .name = "url_len", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_http_request", .variant = "HttpRequest", .args = &.{ .{ .name = "req_ptr", .ty = "u32" }, .{ .name = "req_len", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_http_status", .variant = "HttpStatus", .args = &.{ .{ .name = "fd", .ty = "i32" }, .{ .name = "ret_status", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_ws_open", .variant = "WsOpen", .args = &.{ .{ .name = "url_ptr", .ty = "u32" }, .{ .name = "url_len", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_host_call", .variant = "HostCall", .args = &.{ .{ .name = "req_ptr", .ty = "u32" }, .{ .name = "req_len", .ty = "u32" }, .{ .name = "ret_fd", .ty = "u32" } }, .ret = "i32", .signature = "i(iii)" },
    .{ .name = "mc_sys_time_monotonic", .variant = "TimeMonotonic", .args = &.{ .{ .name = "ret", .ty = "u32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_time_realtime", .variant = "TimeRealtime", .args = &.{ .{ .name = "ret", .ty = "u32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_sleep_ms", .variant = "SleepMs", .args = &.{ .{ .name = "ms", .ty = "i32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_random", .variant = "Random", .args = &.{ .{ .name = "ptr", .ty = "u32" }, .{ .name = "len", .ty = "u32" } }, .ret = "i32", .signature = "i(ii)" },
    .{ .name = "mc_sys_abi_version", .variant = "AbiVersion", .args = &.{ .{ .name = "ret", .ty = "u32" } }, .ret = "i32", .signature = "i(i)" },
    .{ .name = "mc_sys_exit", .variant = "Exit", .args = &.{ .{ .name = "code", .ty = "i32" } }, .ret = "noreturn", .signature = "i(i)" },
    .{ .name = "mc_sys_pcall", .variant = "Pcall", .args = &.{  }, .ret = "i32", .signature = "i()" },
    .{ .name = "mc_sys_set_throw", .variant = "SetThrow", .args = &.{ .{ .name = "code", .ty = "i32" } }, .ret = "i32", .signature = "i(i)" },
};

pub const Syscall = enum {
    Write,
    Read,
    Open,
    Close,
    Args,
    Stat,
    Readdir,
    Mkdir,
    Unlink,
    Rename,
    Symlink,
    Link,
    Readlink,
    Lstat,
    Chmod,
    Utimes,
    Getcwd,
    Chdir,
    Lseek,
    Ftruncate,
    Poll,
    Bind,
    Unmount,
    Serve,
    ServeRecv,
    ServeRespond,
    SvcServe,
    SvcRecv,
    SvcRespond,
    SvcConnect,
    SvcCall,
    Pipe,
    Dup,
    Dup2,
    Isatty,
    Getpid,
    Getppid,
    Spawn,
    Waitpid,
    Nice,
    Kill,
    Sigdisp,
    Setpgid,
    Tcsetpgrp,
    HttpGet,
    HttpRequest,
    HttpStatus,
    WsOpen,
    HostCall,
    TimeMonotonic,
    TimeRealtime,
    SleepMs,
    Random,
    AbiVersion,
    Exit,
    Pcall,
    SetThrow,
};

pub const WriteArgs = struct {
    fd: i32,
    ptr: u32,
    len: u32,
    ret_n: u32,
};

pub const ReadArgs = struct {
    fd: i32,
    ptr: u32,
    len: u32,
    ret_n: u32,
};

pub const OpenArgs = struct {
    path_ptr: u32,
    path_len: u32,
    flags: i32,
    ret_fd: u32,
};

pub const CloseArgs = struct {
    fd: i32,
};

pub const ArgsArgs = struct {
    ptr: u32,
    len: u32,
    ret_len: u32,
};

pub const StatArgs = struct {
    path_ptr: u32,
    path_len: u32,
    ret_stat: u32,
};

pub const ReaddirArgs = struct {
    path_ptr: u32,
    path_len: u32,
    buf: u32,
    buf_len: u32,
    ret_len: u32,
};

pub const MkdirArgs = struct {
    path_ptr: u32,
    path_len: u32,
};

pub const UnlinkArgs = struct {
    path_ptr: u32,
    path_len: u32,
};

pub const RenameArgs = struct {
    from_ptr: u32,
    from_len: u32,
    to_ptr: u32,
    to_len: u32,
};

pub const SymlinkArgs = struct {
    target_ptr: u32,
    target_len: u32,
    link_ptr: u32,
    link_len: u32,
};

pub const LinkArgs = struct {
    old_ptr: u32,
    old_len: u32,
    new_ptr: u32,
    new_len: u32,
};

pub const ReadlinkArgs = struct {
    path_ptr: u32,
    path_len: u32,
    buf: u32,
    buf_len: u32,
    ret_len: u32,
};

pub const LstatArgs = struct {
    path_ptr: u32,
    path_len: u32,
    ret_stat: u32,
};

pub const ChmodArgs = struct {
    path_ptr: u32,
    path_len: u32,
    mode: u32,
};

pub const UtimesArgs = struct {
    path_ptr: u32,
    path_len: u32,
    times_ptr: u32,
};

pub const GetcwdArgs = struct {
    buf: u32,
    buf_len: u32,
    ret_len: u32,
};

pub const ChdirArgs = struct {
    path_ptr: u32,
    path_len: u32,
};

pub const LseekArgs = struct {
    fd: i32,
    off_ptr: u32,
    whence: i32,
};

pub const FtruncateArgs = struct {
    fd: i32,
    size_lo: u32,
    size_hi: u32,
};

pub const PollArgs = struct {
    fds_ptr: u32,
    nfds: u32,
    timeout_ms: i32,
    ret_ready: u32,
};

pub const BindArgs = struct {
    old_ptr: u32,
    old_len: u32,
    new_ptr: u32,
    new_len: u32,
};

pub const UnmountArgs = struct {
    path_ptr: u32,
    path_len: u32,
};

pub const ServeArgs = struct {
    path_ptr: u32,
    path_len: u32,
    ret_fd: u32,
};

pub const ServeRecvArgs = struct {
    fd: i32,
    buf: u32,
    buf_len: u32,
    ret_len: u32,
};

pub const ServeRespondArgs = struct {
    fd: i32,
    req_id: u32,
    status: i32,
    data_ptr: u32,
    data_len: u32,
};

pub const SvcServeArgs = struct {
    name_ptr: u32,
    name_len: u32,
    ret_fd: u32,
};

pub const SvcRecvArgs = struct {
    fd: i32,
    buf: u32,
    buf_len: u32,
    hbuf: u32,
    hbuf_len: u32,
    ret_len: u32,
};

pub const SvcRespondArgs = struct {
    fd: i32,
    session: u32,
    req_id: u32,
    status: i32,
    data_ptr: u32,
    data_len: u32,
    last: u32,
};

pub const SvcConnectArgs = struct {
    name_ptr: u32,
    name_len: u32,
    ret_fd: u32,
};

pub const SvcCallArgs = struct {
    fd: i32,
    req_ptr: u32,
    req_len: u32,
    handles_ptr: u32,
    nhandles: u32,
    ret_fd: u32,
};

pub const PipeArgs = struct {
    ret_r: u32,
    ret_w: u32,
};

pub const DupArgs = struct {
    fd: i32,
    ret_fd: u32,
};

pub const Dup2Args = struct {
    old_fd: i32,
    new_fd: i32,
};

pub const IsattyArgs = struct {
    fd: i32,
    ret: u32,
};

pub const GetpidArgs = struct {
    ret: u32,
};

pub const GetppidArgs = struct {
    ret: u32,
};

pub const SpawnArgs = struct {
    argv_ptr: u32,
    argv_len: u32,
    in_fd: i32,
    out_fd: i32,
    err_fd: i32,
    tier: i32,
    ret_pid: u32,
};

pub const WaitpidArgs = struct {
    pid: i32,
    opts: i32,
    ret_status: u32,
    ret_pid: u32,
};

pub const NiceArgs = struct {
    inc: i32,
    ret: u32,
};

pub const KillArgs = struct {
    pid: i32,
    sig: i32,
};

pub const SigdispArgs = struct {
    sig: i32,
    disp: i32,
};

pub const SetpgidArgs = struct {
    pid: i32,
    pgid: i32,
};

pub const TcsetpgrpArgs = struct {
    pgid: i32,
};

pub const HttpGetArgs = struct {
    url_ptr: u32,
    url_len: u32,
    ret_fd: u32,
};

pub const HttpRequestArgs = struct {
    req_ptr: u32,
    req_len: u32,
    ret_fd: u32,
};

pub const HttpStatusArgs = struct {
    fd: i32,
    ret_status: u32,
};

pub const WsOpenArgs = struct {
    url_ptr: u32,
    url_len: u32,
    ret_fd: u32,
};

pub const HostCallArgs = struct {
    req_ptr: u32,
    req_len: u32,
    ret_fd: u32,
};

pub const TimeMonotonicArgs = struct {
    ret: u32,
};

pub const TimeRealtimeArgs = struct {
    ret: u32,
};

pub const SleepMsArgs = struct {
    ms: i32,
};

pub const RandomArgs = struct {
    ptr: u32,
    len: u32,
};

pub const AbiVersionArgs = struct {
    ret: u32,
};

pub const ExitArgs = struct {
    code: i32,
};

pub const PcallArgs = struct {
};

pub const SetThrowArgs = struct {
    code: i32,
};

pub const Pending = union(Syscall) {
    Write: WriteArgs,
    Read: ReadArgs,
    Open: OpenArgs,
    Close: CloseArgs,
    Args: ArgsArgs,
    Stat: StatArgs,
    Readdir: ReaddirArgs,
    Mkdir: MkdirArgs,
    Unlink: UnlinkArgs,
    Rename: RenameArgs,
    Symlink: SymlinkArgs,
    Link: LinkArgs,
    Readlink: ReadlinkArgs,
    Lstat: LstatArgs,
    Chmod: ChmodArgs,
    Utimes: UtimesArgs,
    Getcwd: GetcwdArgs,
    Chdir: ChdirArgs,
    Lseek: LseekArgs,
    Ftruncate: FtruncateArgs,
    Poll: PollArgs,
    Bind: BindArgs,
    Unmount: UnmountArgs,
    Serve: ServeArgs,
    ServeRecv: ServeRecvArgs,
    ServeRespond: ServeRespondArgs,
    SvcServe: SvcServeArgs,
    SvcRecv: SvcRecvArgs,
    SvcRespond: SvcRespondArgs,
    SvcConnect: SvcConnectArgs,
    SvcCall: SvcCallArgs,
    Pipe: PipeArgs,
    Dup: DupArgs,
    Dup2: Dup2Args,
    Isatty: IsattyArgs,
    Getpid: GetpidArgs,
    Getppid: GetppidArgs,
    Spawn: SpawnArgs,
    Waitpid: WaitpidArgs,
    Nice: NiceArgs,
    Kill: KillArgs,
    Sigdisp: SigdispArgs,
    Setpgid: SetpgidArgs,
    Tcsetpgrp: TcsetpgrpArgs,
    HttpGet: HttpGetArgs,
    HttpRequest: HttpRequestArgs,
    HttpStatus: HttpStatusArgs,
    WsOpen: WsOpenArgs,
    HostCall: HostCallArgs,
    TimeMonotonic: TimeMonotonicArgs,
    TimeRealtime: TimeRealtimeArgs,
    SleepMs: SleepMsArgs,
    Random: RandomArgs,
    AbiVersion: AbiVersionArgs,
    Exit: ExitArgs,
    Pcall: PcallArgs,
    SetThrow: SetThrowArgs,
};

inline fn rawArgU32(sp: [*]const u64, idx: usize) u32 {
    return @truncate(sp[idx]);
}

inline fn rawArgI32(sp: [*]const u64, idx: usize) i32 {
    return @bitCast(rawArgU32(sp, idx));
}

pub fn pendingFromRaw(desc: *const Desc, sp: [*]const u64) ?Pending {
    if (desc == &SYSCALLS[0]) return Pending{ .Write = .{
        .fd = rawArgI32(sp, 1),
        .ptr = rawArgU32(sp, 2),
        .len = rawArgU32(sp, 3),
        .ret_n = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[1]) return Pending{ .Read = .{
        .fd = rawArgI32(sp, 1),
        .ptr = rawArgU32(sp, 2),
        .len = rawArgU32(sp, 3),
        .ret_n = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[2]) return Pending{ .Open = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .flags = rawArgI32(sp, 3),
        .ret_fd = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[3]) return Pending{ .Close = .{
        .fd = rawArgI32(sp, 1),
    } };
    if (desc == &SYSCALLS[4]) return Pending{ .Args = .{
        .ptr = rawArgU32(sp, 1),
        .len = rawArgU32(sp, 2),
        .ret_len = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[5]) return Pending{ .Stat = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .ret_stat = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[6]) return Pending{ .Readdir = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .buf = rawArgU32(sp, 3),
        .buf_len = rawArgU32(sp, 4),
        .ret_len = rawArgU32(sp, 5),
    } };
    if (desc == &SYSCALLS[7]) return Pending{ .Mkdir = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[8]) return Pending{ .Unlink = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[9]) return Pending{ .Rename = .{
        .from_ptr = rawArgU32(sp, 1),
        .from_len = rawArgU32(sp, 2),
        .to_ptr = rawArgU32(sp, 3),
        .to_len = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[10]) return Pending{ .Symlink = .{
        .target_ptr = rawArgU32(sp, 1),
        .target_len = rawArgU32(sp, 2),
        .link_ptr = rawArgU32(sp, 3),
        .link_len = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[11]) return Pending{ .Link = .{
        .old_ptr = rawArgU32(sp, 1),
        .old_len = rawArgU32(sp, 2),
        .new_ptr = rawArgU32(sp, 3),
        .new_len = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[12]) return Pending{ .Readlink = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .buf = rawArgU32(sp, 3),
        .buf_len = rawArgU32(sp, 4),
        .ret_len = rawArgU32(sp, 5),
    } };
    if (desc == &SYSCALLS[13]) return Pending{ .Lstat = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .ret_stat = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[14]) return Pending{ .Chmod = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .mode = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[15]) return Pending{ .Utimes = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .times_ptr = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[16]) return Pending{ .Getcwd = .{
        .buf = rawArgU32(sp, 1),
        .buf_len = rawArgU32(sp, 2),
        .ret_len = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[17]) return Pending{ .Chdir = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[18]) return Pending{ .Lseek = .{
        .fd = rawArgI32(sp, 1),
        .off_ptr = rawArgU32(sp, 2),
        .whence = rawArgI32(sp, 3),
    } };
    if (desc == &SYSCALLS[19]) return Pending{ .Ftruncate = .{
        .fd = rawArgI32(sp, 1),
        .size_lo = rawArgU32(sp, 2),
        .size_hi = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[20]) return Pending{ .Poll = .{
        .fds_ptr = rawArgU32(sp, 1),
        .nfds = rawArgU32(sp, 2),
        .timeout_ms = rawArgI32(sp, 3),
        .ret_ready = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[21]) return Pending{ .Bind = .{
        .old_ptr = rawArgU32(sp, 1),
        .old_len = rawArgU32(sp, 2),
        .new_ptr = rawArgU32(sp, 3),
        .new_len = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[22]) return Pending{ .Unmount = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[23]) return Pending{ .Serve = .{
        .path_ptr = rawArgU32(sp, 1),
        .path_len = rawArgU32(sp, 2),
        .ret_fd = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[24]) return Pending{ .ServeRecv = .{
        .fd = rawArgI32(sp, 1),
        .buf = rawArgU32(sp, 2),
        .buf_len = rawArgU32(sp, 3),
        .ret_len = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[25]) return Pending{ .ServeRespond = .{
        .fd = rawArgI32(sp, 1),
        .req_id = rawArgU32(sp, 2),
        .status = rawArgI32(sp, 3),
        .data_ptr = rawArgU32(sp, 4),
        .data_len = rawArgU32(sp, 5),
    } };
    if (desc == &SYSCALLS[26]) return Pending{ .SvcServe = .{
        .name_ptr = rawArgU32(sp, 1),
        .name_len = rawArgU32(sp, 2),
        .ret_fd = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[27]) return Pending{ .SvcRecv = .{
        .fd = rawArgI32(sp, 1),
        .buf = rawArgU32(sp, 2),
        .buf_len = rawArgU32(sp, 3),
        .hbuf = rawArgU32(sp, 4),
        .hbuf_len = rawArgU32(sp, 5),
        .ret_len = rawArgU32(sp, 6),
    } };
    if (desc == &SYSCALLS[28]) return Pending{ .SvcRespond = .{
        .fd = rawArgI32(sp, 1),
        .session = rawArgU32(sp, 2),
        .req_id = rawArgU32(sp, 3),
        .status = rawArgI32(sp, 4),
        .data_ptr = rawArgU32(sp, 5),
        .data_len = rawArgU32(sp, 6),
        .last = rawArgU32(sp, 7),
    } };
    if (desc == &SYSCALLS[29]) return Pending{ .SvcConnect = .{
        .name_ptr = rawArgU32(sp, 1),
        .name_len = rawArgU32(sp, 2),
        .ret_fd = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[30]) return Pending{ .SvcCall = .{
        .fd = rawArgI32(sp, 1),
        .req_ptr = rawArgU32(sp, 2),
        .req_len = rawArgU32(sp, 3),
        .handles_ptr = rawArgU32(sp, 4),
        .nhandles = rawArgU32(sp, 5),
        .ret_fd = rawArgU32(sp, 6),
    } };
    if (desc == &SYSCALLS[31]) return Pending{ .Pipe = .{
        .ret_r = rawArgU32(sp, 1),
        .ret_w = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[32]) return Pending{ .Dup = .{
        .fd = rawArgI32(sp, 1),
        .ret_fd = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[33]) return Pending{ .Dup2 = .{
        .old_fd = rawArgI32(sp, 1),
        .new_fd = rawArgI32(sp, 2),
    } };
    if (desc == &SYSCALLS[34]) return Pending{ .Isatty = .{
        .fd = rawArgI32(sp, 1),
        .ret = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[35]) return Pending{ .Getpid = .{
        .ret = rawArgU32(sp, 1),
    } };
    if (desc == &SYSCALLS[36]) return Pending{ .Getppid = .{
        .ret = rawArgU32(sp, 1),
    } };
    if (desc == &SYSCALLS[37]) return Pending{ .Spawn = .{
        .argv_ptr = rawArgU32(sp, 1),
        .argv_len = rawArgU32(sp, 2),
        .in_fd = rawArgI32(sp, 3),
        .out_fd = rawArgI32(sp, 4),
        .err_fd = rawArgI32(sp, 5),
        .tier = rawArgI32(sp, 6),
        .ret_pid = rawArgU32(sp, 7),
    } };
    if (desc == &SYSCALLS[38]) return Pending{ .Waitpid = .{
        .pid = rawArgI32(sp, 1),
        .opts = rawArgI32(sp, 2),
        .ret_status = rawArgU32(sp, 3),
        .ret_pid = rawArgU32(sp, 4),
    } };
    if (desc == &SYSCALLS[39]) return Pending{ .Nice = .{
        .inc = rawArgI32(sp, 1),
        .ret = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[40]) return Pending{ .Kill = .{
        .pid = rawArgI32(sp, 1),
        .sig = rawArgI32(sp, 2),
    } };
    if (desc == &SYSCALLS[41]) return Pending{ .Sigdisp = .{
        .sig = rawArgI32(sp, 1),
        .disp = rawArgI32(sp, 2),
    } };
    if (desc == &SYSCALLS[42]) return Pending{ .Setpgid = .{
        .pid = rawArgI32(sp, 1),
        .pgid = rawArgI32(sp, 2),
    } };
    if (desc == &SYSCALLS[43]) return Pending{ .Tcsetpgrp = .{
        .pgid = rawArgI32(sp, 1),
    } };
    if (desc == &SYSCALLS[44]) return Pending{ .HttpGet = .{
        .url_ptr = rawArgU32(sp, 1),
        .url_len = rawArgU32(sp, 2),
        .ret_fd = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[45]) return Pending{ .HttpRequest = .{
        .req_ptr = rawArgU32(sp, 1),
        .req_len = rawArgU32(sp, 2),
        .ret_fd = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[46]) return Pending{ .HttpStatus = .{
        .fd = rawArgI32(sp, 1),
        .ret_status = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[47]) return Pending{ .WsOpen = .{
        .url_ptr = rawArgU32(sp, 1),
        .url_len = rawArgU32(sp, 2),
        .ret_fd = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[48]) return Pending{ .HostCall = .{
        .req_ptr = rawArgU32(sp, 1),
        .req_len = rawArgU32(sp, 2),
        .ret_fd = rawArgU32(sp, 3),
    } };
    if (desc == &SYSCALLS[49]) return Pending{ .TimeMonotonic = .{
        .ret = rawArgU32(sp, 1),
    } };
    if (desc == &SYSCALLS[50]) return Pending{ .TimeRealtime = .{
        .ret = rawArgU32(sp, 1),
    } };
    if (desc == &SYSCALLS[51]) return Pending{ .SleepMs = .{
        .ms = rawArgI32(sp, 1),
    } };
    if (desc == &SYSCALLS[52]) return Pending{ .Random = .{
        .ptr = rawArgU32(sp, 1),
        .len = rawArgU32(sp, 2),
    } };
    if (desc == &SYSCALLS[53]) return Pending{ .AbiVersion = .{
        .ret = rawArgU32(sp, 1),
    } };
    if (desc == &SYSCALLS[54]) return Pending{ .Exit = .{
        .code = rawArgI32(sp, 1),
    } };
    if (desc == &SYSCALLS[55]) return Pending{ .Pcall = .{ } };
    if (desc == &SYSCALLS[56]) return Pending{ .SetThrow = .{
        .code = rawArgI32(sp, 1),
    } };
    return null;
}

// The guest-side `mc` import block: every syscall the kernel serves, callable as
// `mc.mc_sys_<name>(...)`. wasm32 — pointer/length args are u32 offsets into the guest's
// own linear memory; each returns i32 (0 / negative errno).
pub extern "mc" fn mc_sys_write(fd: i32, ptr: u32, len: u32, ret_n: u32) i32;
pub extern "mc" fn mc_sys_read(fd: i32, ptr: u32, len: u32, ret_n: u32) i32;
pub extern "mc" fn mc_sys_open(path_ptr: u32, path_len: u32, flags: i32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_close(fd: i32) i32;
pub extern "mc" fn mc_sys_args(ptr: u32, len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_stat(path_ptr: u32, path_len: u32, ret_stat: u32) i32;
pub extern "mc" fn mc_sys_readdir(path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_mkdir(path_ptr: u32, path_len: u32) i32;
pub extern "mc" fn mc_sys_unlink(path_ptr: u32, path_len: u32) i32;
pub extern "mc" fn mc_sys_rename(from_ptr: u32, from_len: u32, to_ptr: u32, to_len: u32) i32;
pub extern "mc" fn mc_sys_symlink(target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) i32;
pub extern "mc" fn mc_sys_link(old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32) i32;
pub extern "mc" fn mc_sys_readlink(path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_lstat(path_ptr: u32, path_len: u32, ret_stat: u32) i32;
pub extern "mc" fn mc_sys_chmod(path_ptr: u32, path_len: u32, mode: u32) i32;
pub extern "mc" fn mc_sys_utimes(path_ptr: u32, path_len: u32, times_ptr: u32) i32;
pub extern "mc" fn mc_sys_getcwd(buf: u32, buf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_chdir(path_ptr: u32, path_len: u32) i32;
pub extern "mc" fn mc_sys_lseek(fd: i32, off_ptr: u32, whence: i32) i32;
pub extern "mc" fn mc_sys_ftruncate(fd: i32, size_lo: u32, size_hi: u32) i32;
pub extern "mc" fn mc_sys_poll(fds_ptr: u32, nfds: u32, timeout_ms: i32, ret_ready: u32) i32;
pub extern "mc" fn mc_sys_bind(old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32) i32;
pub extern "mc" fn mc_sys_unmount(path_ptr: u32, path_len: u32) i32;
pub extern "mc" fn mc_sys_serve(path_ptr: u32, path_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_serve_recv(fd: i32, buf: u32, buf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_serve_respond(fd: i32, req_id: u32, status: i32, data_ptr: u32, data_len: u32) i32;
pub extern "mc" fn mc_sys_svc_serve(name_ptr: u32, name_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_svc_recv(fd: i32, buf: u32, buf_len: u32, hbuf: u32, hbuf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_svc_respond(fd: i32, session: u32, req_id: u32, status: i32, data_ptr: u32, data_len: u32, last: u32) i32;
pub extern "mc" fn mc_sys_svc_connect(name_ptr: u32, name_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_svc_call(fd: i32, req_ptr: u32, req_len: u32, handles_ptr: u32, nhandles: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_pipe(ret_r: u32, ret_w: u32) i32;
pub extern "mc" fn mc_sys_dup(fd: i32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_dup2(old_fd: i32, new_fd: i32) i32;
pub extern "mc" fn mc_sys_isatty(fd: i32, ret: u32) i32;
pub extern "mc" fn mc_sys_getpid(ret: u32) i32;
pub extern "mc" fn mc_sys_getppid(ret: u32) i32;
pub extern "mc" fn mc_sys_spawn(argv_ptr: u32, argv_len: u32, in_fd: i32, out_fd: i32, err_fd: i32, tier: i32, ret_pid: u32) i32;
pub extern "mc" fn mc_sys_waitpid(pid: i32, opts: i32, ret_status: u32, ret_pid: u32) i32;
pub extern "mc" fn mc_sys_nice(inc: i32, ret: u32) i32;
pub extern "mc" fn mc_sys_kill(pid: i32, sig: i32) i32;
pub extern "mc" fn mc_sys_sigdisp(sig: i32, disp: i32) i32;
pub extern "mc" fn mc_sys_setpgid(pid: i32, pgid: i32) i32;
pub extern "mc" fn mc_sys_tcsetpgrp(pgid: i32) i32;
pub extern "mc" fn mc_sys_http_get(url_ptr: u32, url_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_http_request(req_ptr: u32, req_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_http_status(fd: i32, ret_status: u32) i32;
pub extern "mc" fn mc_sys_ws_open(url_ptr: u32, url_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_host_call(req_ptr: u32, req_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_time_monotonic(ret: u32) i32;
pub extern "mc" fn mc_sys_time_realtime(ret: u32) i32;
pub extern "mc" fn mc_sys_sleep_ms(ms: i32) i32;
pub extern "mc" fn mc_sys_random(ptr: u32, len: u32) i32;
pub extern "mc" fn mc_sys_abi_version(ret: u32) i32;
pub extern "mc" fn mc_sys_exit(code: i32) i32;  // contract: noreturn; the kernel serves it as (…)->i32
pub extern "mc" fn mc_sys_pcall() i32;
pub extern "mc" fn mc_sys_set_throw(code: i32) i32;

/// A Zig pointer as a wasm linear-memory address (the u32 the mc ABI takes).
pub inline fn addr(p: anytype) u32 {
    return @intCast(@intFromPtr(p));
}
