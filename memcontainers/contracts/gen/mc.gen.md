<!-- @generated from contracts/syscalls.kdl by //contracts/codegen:projector — do not edit.
 -->

# `mc_syscall_table` — generated reference

| # | symbol | variant | args | ret | doc |
|---|---|---|---|---|---|
| 1 | `mc_sys_write` | Write | fd: i32, ptr: u32, len: u32, ret_n: u32 | i32 | Write len bytes from guest ptr to fd; the count is written to ret_n. |
| 2 | `mc_sys_read` | Read | fd: i32, ptr: u32, len: u32, ret_n: u32 | i32 | Read up to len bytes from fd into guest ptr; the count is written to ret_n. |
| 3 | `mc_sys_open` | Open | path_ptr: u32, path_len: u32, flags: i32, ret_fd: u32 | i32 | Open path with O_* flags; the new fd is written to ret_fd. |
| 4 | `mc_sys_close` | Close | fd: i32 | i32 | Close fd. |
| 5 | `mc_sys_args` | Args | ptr: u32, len: u32, ret_len: u32 | i32 | Copy this task's NUL-separated argv into guest ptr; full length to ret_len. |
| 6 | `mc_sys_stat` | Stat | path_ptr: u32, path_len: u32, ret_stat: u32 | i32 | Write a stat record for path (follows symlinks) to ret_stat. |
| 7 | `mc_sys_readdir` | Readdir | path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32 | i32 | Write typed directory entries for path into buf; full length to ret_len. |
| 8 | `mc_sys_mkdir` | Mkdir | path_ptr: u32, path_len: u32 | i32 | Create directory path. |
| 9 | `mc_sys_unlink` | Unlink | path_ptr: u32, path_len: u32 | i32 | Remove the file (or empty directory) at path. |
| 10 | `mc_sys_rename` | Rename | from_ptr: u32, from_len: u32, to_ptr: u32, to_len: u32 | i32 | Rename from â to (EXDEV across mounts). |
| 11 | `mc_sys_symlink` | Symlink | target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32 | i32 | Create symlink `link` pointing at `target`. |
| 12 | `mc_sys_link` | Link | old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32 | i32 | Create hard link `new` referring to the same inode as `old`. |
| 13 | `mc_sys_readlink` | Readlink | path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32 | i32 | Write a symlink's target text into buf (no trailing NUL); full length to ret_len. |
| 14 | `mc_sys_lstat` | Lstat | path_ptr: u32, path_len: u32, ret_stat: u32 | i32 | Like stat, but does NOT follow a trailing symlink. |
| 15 | `mc_sys_chmod` | Chmod | path_ptr: u32, path_len: u32, mode: u32 | i32 | Set path's permission bits (CAP_FS_WRITE). |
| 16 | `mc_sys_utimes` | Utimes | path_ptr: u32, path_len: u32, times_ptr: u32 | i32 | Set path's atime+mtime (ms since epoch); NULL times_ptr means now (CAP_FS_WRITE). |
| 17 | `mc_sys_getcwd` | Getcwd | buf: u32, buf_len: u32, ret_len: u32 | i32 | Write the current working directory into buf; full length to ret_len. |
| 18 | `mc_sys_chdir` | Chdir | path_ptr: u32, path_len: u32 | i32 | Change the current working directory to path. |
| 19 | `mc_sys_lseek` | Lseek | fd: i32, off_ptr: u32, whence: i32 | i32 | Reposition fd by the i64 offset at off_ptr relative to SEEK_*; new offset back to off_ptr. |
| 20 | `mc_sys_ftruncate` | Ftruncate | fd: i32, size_lo: u32, size_hi: u32 | i32 | Truncate/extend fd to the 64-bit size (size_hi:size_lo). |
| 21 | `mc_sys_poll` | Poll | fds_ptr: u32, nfds: u32, timeout_ms: i32, ret_ready: u32 | i32 | Wait on nfds pollfd records for POLL* events; ready count to ret_ready (POLL_BLOCK = block). |
| 22 | `mc_sys_bind` | Bind | old_ptr: u32, old_len: u32, new_ptr: u32, new_len: u32 | i32 | Bind `old` onto `new` in this process's copy-on-write mount table. |
| 23 | `mc_sys_unmount` | Unmount | path_ptr: u32, path_len: u32 | i32 | Remove the binding at path from this process's namespace. |
| 24 | `mc_sys_serve` | Serve | path_ptr: u32, path_len: u32, ret_fd: u32 | i32 | Register this guest as the file server for the subtree at path; server fd to ret_fd. |
| 25 | `mc_sys_serve_recv` | ServeRecv | fd: i32, buf: u32, buf_len: u32, ret_len: u32 | i32 | Receive the next served VFS request on fd (SERVE_OP_* envelope) into buf; length to ret_len. |
| 26 | `mc_sys_serve_respond` | ServeRespond | fd: i32, req_id: u32, status: i32, data_ptr: u32, data_len: u32 | i32 | Answer request req_id with a WASI errno status plus op-specific data. |
| 27 | `mc_sys_svc_serve` | SvcServe | name_ptr: u32, name_len: u32, ret_fd: u32 | i32 | Register as the service `name` â authorized by the kernel's activation grant (the task it spawned for `name`), not a capability, so a service runs at its own narrow tier and names can't be squatted; server fd to ret_fd. |
| 28 | `mc_sys_svc_recv` | SvcRecv | fd: i32, buf: u32, buf_len: u32, hbuf: u32, hbuf_len: u32, ret_len: u32 | i32 | Receive the next inbound on server fd: the envelope ([kind][nhandles][session][req_id][caller][caller_caps][blob_len][blob]) into buf and any delegated fd numbers into hbuf; envelope length to ret_len. kind=0 is a call, kind=1 a session-closed tombstone. |
| 29 | `mc_sys_svc_respond` | SvcRespond | fd: i32, session: u32, req_id: u32, status: i32, data_ptr: u32, data_len: u32, last: u32 | i32 | Answer call (session, req_id) on server fd: a status plus a response-body CHUNK. last=1 marks the final chunk (the call completes); last=0 a partial chunk the client drains before the server sends the next â bounded-buffer streaming, so a large result never materializes whole (the kernel caps the un-drained buffer and a client that won't drain fails the call cleanly). |
| 30 | `mc_sys_svc_connect` | SvcConnect | name_ptr: u32, name_len: u32, ret_fd: u32 | i32 | Open a session to the service named `name`; the connection fd goes to ret_fd. |
| 31 | `mc_sys_svc_call` | SvcCall | fd: i32, req_ptr: u32, req_len: u32, handles_ptr: u32, nhandles: u32, ret_fd: u32 | i32 | Send a typed request on connection fd, optionally delegating nhandles fds (File/PipeRead/PipeWrite only) listed at handles_ptr into the service's fd table (SCM_RIGHTS-style); a readable result fd (the streamed response) to ret_fd. |
| 32 | `mc_sys_pipe` | Pipe | ret_r: u32, ret_w: u32 | i32 | Create a pipe; read end to ret_r, write end to ret_w. |
| 33 | `mc_sys_dup` | Dup | fd: i32, ret_fd: u32 | i32 | Duplicate fd onto the lowest free descriptor; written to ret_fd. |
| 34 | `mc_sys_dup2` | Dup2 | old_fd: i32, new_fd: i32 | i32 | Duplicate old_fd onto new_fd (closing new_fd first). |
| 35 | `mc_sys_isatty` | Isatty | fd: i32, ret: u32 | i32 | Write 1 to ret iff fd is the terminal (not a pipe/file). |
| 36 | `mc_sys_getpid` | Getpid | ret: u32 | i32 | Write this task's pid to ret. |
| 37 | `mc_sys_getppid` | Getppid | ret: u32 | i32 | Write this task's parent pid to ret. |
| 38 | `mc_sys_spawn` | Spawn | argv_ptr: u32, argv_len: u32, in_fd: i32, out_fd: i32, err_fd: i32, tier: i32, ret_pid: u32 | i32 | Spawn a child from NUL-separated argv with the given stdio fds and capability tier; pid to ret_pid. |
| 39 | `mc_sys_waitpid` | Waitpid | pid: i32, opts: i32, ret_status: u32, ret_pid: u32 | i32 | Wait for child pid (WNOHANG optional); status to ret_status, reaped pid to ret_pid. |
| 40 | `mc_sys_nice` | Nice | inc: i32, ret: u32 | i32 | Adjust scheduling niceness by inc (clamped -20..=19); resulting value to ret. Inherited across spawn. |
| 41 | `mc_sys_kill` | Kill | pid: i32, sig: i32 | i32 | Send signal sig to pid (or a process group when pid < 0). |
| 42 | `mc_sys_sigdisp` | Sigdisp | sig: i32, disp: i32 | i32 | Set this task's disposition for sig (SIG_DFL or SIG_IGN). |
| 43 | `mc_sys_setpgid` | Setpgid | pid: i32, pgid: i32 | i32 | Set pid's process group to pgid (0 = self). |
| 44 | `mc_sys_tcsetpgrp` | Tcsetpgrp | pgid: i32 | i32 | Make pgid the terminal's foreground process group. |
| 45 | `mc_sys_http_get` | HttpGet | url_ptr: u32, url_len: u32, ret_fd: u32 | i32 | Start a GET for url (host terminates TLS); a readable result fd to ret_fd. |
| 46 | `mc_sys_http_request` | HttpRequest | req_ptr: u32, req_len: u32, ret_fd: u32 | i32 | Start an arbitrary HTTP request from the blob at req_ptr; readable result fd to ret_fd. |
| 47 | `mc_sys_http_status` | HttpStatus | fd: i32, ret_status: u32 | i32 | Write the HTTP status code of request fd to ret_status (once headers arrive). |
| 48 | `mc_sys_ws_open` | WsOpen | url_ptr: u32, url_len: u32, ret_fd: u32 | i32 | Open a WebSocket to url (host does the handshake + TLS); a duplex fd to ret_fd. |
| 49 | `mc_sys_host_call` | HostCall | req_ptr: u32, req_len: u32, ret_fd: u32 | i32 | Invoke a host-resident function (the tool broker, host-backed mounts); readable result fd to ret_fd. |
| 50 | `mc_sys_time_monotonic` | TimeMonotonic | ret: u32 | i32 | Write a monotonic timestamp (ms) to ret (CAP_AMBIENT). |
| 51 | `mc_sys_time_realtime` | TimeRealtime | ret: u32 | i32 | Write wall-clock ms since the Unix epoch to ret; can jump (NTP) (CAP_AMBIENT). |
| 52 | `mc_sys_sleep_ms` | SleepMs | ms: i32 | i32 | Park this task for ms milliseconds. |
| 53 | `mc_sys_random` | Random | ptr: u32, len: u32 | i32 | Fill len bytes at ptr with entropy (CAP_AMBIENT). |
| 54 | `mc_sys_abi_version` | AbiVersion | ret: u32 | i32 | Write the packed syscall ABI version (major<<16|minor) to ret. |
| 55 | `mc_sys_exit` | Exit | code: i32 | noreturn | Terminate this task with exit code (never returns). |
| 56 | `mc_sys_pcall` | Pcall |  | i32 | Run the guest's stashed thunk as a nested call; return its throw code (0 = normal return). |
| 57 | `mc_sys_set_throw` | SetThrow | code: i32 | i32 | Record the throw code to be surfaced by the enclosing pcall after `unreachable`. |
