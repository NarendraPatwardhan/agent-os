//! mc.zig — the shared `mc` syscall ABI for the Zig-lane guest tools (luau, sqlite, …): the
//! hand-written callable `extern "mc" fn` decls that mirror contracts/syscalls.kdl. This is the
//! Zig-side counterpart of the Rust //sysroot's generated import block — ONE source of truth both
//! Zig tools `@import("mc")`, so the ABI can't drift between them. Each tool calls only the subset it
//! needs; an unreferenced extern is dropped by the linker (no spurious wasm import).
//!
//! wasm32: pointers/lengths are `u32` offsets/sizes into the guest's own linear memory; each returns
//! `i32` (0 / negative errno) unless noted. The generated contracts/gen/mc.gen.zig is DESCRIPTOR data,
//! not callable externs, so these are hand-kept — //tools/mc-abi-gate pins every signature here to the
//! projected contract, failing the build on any drift or typo.

// vm — the trap-unwind boundary (luau's trap.zig). `mc_sys_pcall` runs the stashed thunk as a nested
// guest call and returns the raised code (0 if none); `mc_sys_set_throw` records the code a trap hands back.
pub extern "mc" fn mc_sys_pcall() i32;
pub extern "mc" fn mc_sys_set_throw(code: i32) i32;

// fs / io — the file + stream syscalls.
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

// resident services — typed cross-guest calls (the svc_* primitive, SERVICES.md). SERVER side
// (svc_serve/recv/respond) — used by a service binary's serve loop (see svc.zig). CLIENT side
// (svc_connect/call) — used by a client (luau's Lua binding, a service's thin CLI face).
pub extern "mc" fn mc_sys_svc_serve(name_ptr: u32, name_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_svc_recv(fd: i32, buf: u32, buf_len: u32, hbuf: u32, hbuf_len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_svc_respond(fd: i32, session: u32, req_id: u32, status: i32, data_ptr: u32, data_len: u32) i32;
pub extern "mc" fn mc_sys_svc_connect(name_ptr: u32, name_len: u32, ret_fd: u32) i32;
pub extern "mc" fn mc_sys_svc_call(fd: i32, req_ptr: u32, req_len: u32, handles_ptr: u32, nhandles: u32, ret_fd: u32) i32;

// time / rand / introspection.
pub extern "mc" fn mc_sys_time_realtime(ret: u32) i32;
pub extern "mc" fn mc_sys_time_monotonic(ret: u32) i32;
pub extern "mc" fn mc_sys_sleep_ms(ms: i32) i32;
pub extern "mc" fn mc_sys_random(ptr: u32, len: u32) i32;
pub extern "mc" fn mc_sys_args(ptr: u32, len: u32, ret_len: u32) i32;
pub extern "mc" fn mc_sys_abi_version(ret: u32) i32;

/// A Zig pointer as a wasm linear-memory address (the u32 the mc ABI takes).
pub inline fn addr(p: anytype) u32 {
    return @intCast(@intFromPtr(p));
}
