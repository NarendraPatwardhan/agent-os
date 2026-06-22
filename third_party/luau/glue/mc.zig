//! mc.zig — callable wrappers over the `mc` syscall imports the Luau glue uses. The signatures
//! MIRROR contracts/syscalls.kdl (the generated contracts/gen/mc.gen.zig is DESCRIPTOR data, not
//! callable externs). wasm32: pointers/lengths are `u32` offsets/sizes into linear memory; each
//! returns `i32` (0 / negative errno) unless noted. The bindings (sys.zig, …) extend this with the
//! fs/proc/time/net syscalls as they land.
//!
//! TODO: a projector `zig-extern` output would GENERATE these decls from the contract ("generate the
//! boundary", VISION §16.2). Hand-kept in sync for now; a signature mismatch surfaces at the e2e
//! (the kernel's `mc` provider would reject the call).

// vm — the trap-unwind boundary (used by trap.zig). `mc_sys_pcall` runs the stashed thunk as a
// nested guest call and returns the raised code (0 if none); `mc_sys_set_throw` records the code a
// subsequent trap hands back.
pub extern "mc" fn mc_sys_pcall() i32;
pub extern "mc" fn mc_sys_set_throw(code: i32) i32;

// fs / io — the file + stream syscalls sys.zig drives directly (sys IS the syscall layer, §6).
pub extern "mc" fn mc_sys_open(path_ptr: u32, path_len: u32, flags: i32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_read(fd: i32, ptr: u32, len: u32, ret_n: u32) i32;
pub extern "mc" fn mc_sys_write(fd: i32, ptr: u32, len: u32, ret_n: u32) i32;
pub extern "mc" fn mc_sys_close(fd: i32) i32;
pub extern "mc" fn mc_sys_stat(path_ptr: u32, path_len: u32, ret_stat: u32) i32;
pub extern "mc" fn mc_sys_lstat(path_ptr: u32, path_len: u32, ret_stat: u32) i32;
pub extern "mc" fn mc_sys_readdir(path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_mkdir(path_ptr: u32, path_len: u32) i32;
pub extern "mc" fn mc_sys_unlink(path_ptr: u32, path_len: u32) i32;
pub extern "mc" fn mc_sys_rename(from_ptr: u32, from_len: u32, to_ptr: u32, to_len: u32) i32;
pub extern "mc" fn mc_sys_symlink(target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) i32;
pub extern "mc" fn mc_sys_readlink(path_ptr: u32, path_len: u32, buf: u32, buf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_chmod(path_ptr: u32, path_len: u32, mode: u32) i32;
pub extern "mc" fn mc_sys_getcwd(buf: u32, buf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_chdir(path_ptr: u32, path_len: u32) i32;
pub extern "mc" fn mc_sys_isatty(fd: i32, ret: u32) i32;

// proc — process control (WASI has no process model; these are direct mc calls).
pub extern "mc" fn mc_sys_pipe(ret_r: u32, ret_w: u32) i32;
pub extern "mc" fn mc_sys_getpid(ret: u32) i32;
pub extern "mc" fn mc_sys_getppid(ret: u32) i32;
pub extern "mc" fn mc_sys_spawn(argv_ptr: u32, argv_len: u32, in_fd: i32, out_fd: i32, err_fd: i32, tier: i32, ret_pid: u32) i32;
pub extern "mc" fn mc_sys_waitpid(pid: i32, opts: i32, ret_status: u32, ret_pid: u32) i32;
// Exit is `[noreturn]` in the contract, but the kernel registers the import as (i32)->i32 (matching
// the rest); declaring it noreturn here changes the wasm import TYPE and the kernel rejects the guest
// at spawn (EINVAL). So: i32 return, treated as unreachable at the call site.
pub extern "mc" fn mc_sys_exit(code: i32) i32;

// net / host — capability egress + host-tool invocation.
pub extern "mc" fn mc_sys_http_get(url_ptr: u32, url_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_http_request(req_ptr: u32, req_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_http_status(fd: i32, ret_status: u32) i32;
pub extern "mc" fn mc_sys_host_call(req_ptr: u32, req_len: u32, ret_fd: u32) i32;

// time / rand / introspection.
pub extern "mc" fn mc_sys_time_realtime(ret: u32) i32;
pub extern "mc" fn mc_sys_time_monotonic(ret: u32) i32;
pub extern "mc" fn mc_sys_sleep_ms(ms: i32) i32;
pub extern "mc" fn mc_sys_random(ptr: u32, len: u32) i32;
pub extern "mc" fn mc_sys_args(ptr: u32, len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_abi_version(ret: u32) i32;

// A Zig pointer as a wasm linear-memory address (the u32 the mc ABI takes).
pub inline fn addr(p: anytype) u32 {
    return @intCast(@intFromPtr(p));
}
