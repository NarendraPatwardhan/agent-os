//! The `env` bridge — the ONLY functions the kernel calls on the host (the A4 boundary).
//! Every host (wasmtime, browser) must implement all of them.
//!
//! These imports are the boundary described by `contracts/bridge.kdl` and projected into
//! `env_rust`. They are hand-declared here for now because the extern block needs each
//! pointer's exact `*const`/`*mut` mutability, which the contract does not yet encode;
//! once `bridge.kdl` carries that (a `cptr`/`mptr` distinction), this block becomes a
//! `mc_bridge_table!($emit)` invocation like the syscall table, closing the last
//! hand-written ABI on the import side (B2). The host's matching export table is already
//! generated from the same contract, so the two cannot silently diverge.

#[allow(dead_code)]
#[link(wasm_import_module = "env")]
unsafe extern "C" {
    // Terminal I/O
    pub fn mc_stdout_write(ptr: *const u8, len: usize);
    pub fn mc_stderr_write(ptr: *const u8, len: usize);
    pub fn mc_stdin_read(buf: *mut u8, len: usize) -> usize;

    // Time
    pub fn mc_time_now() -> i64;
    pub fn mc_time_monotonic() -> i64;

    // Randomness
    pub fn mc_random(buf: *mut u8, len: usize);

    // HTTP (poll-based, buffer-then-deliver; the host performs the request and TLS on the
    // kernel's behalf — see the `net` module).
    //  - request: parse the blob `METHOD URL\n<headers>\n\n<body>`, start the fetch,
    //    return an opaque handle >= 0, or -1 to refuse.
    //  - response_poll: 0 while in flight; once complete, write the head
    //    `"<status> <reason>\r\n<headers>\r\n\r\n"` and return its length (>0); -1 on
    //    transport failure.
    //  - response_body: after poll, body bytes (>0), 0 = EOF, -1 = error.
    pub fn mc_http_request(req_ptr: *const u8, req_len: usize) -> i32;
    pub fn mc_http_response_poll(handle: i32, buf: *mut u8, buf_len: usize) -> i32;
    pub fn mc_http_response_body(handle: i32, buf: *mut u8, buf_len: usize) -> i32;
    pub fn mc_http_request_close(handle: i32);

    // WebSocket. connect -> handle/-1 (host does the handshake + TLS for wss). send ->
    // bytes/-1. recv -> n(>0) / 0(none pending) / -1(closed).
    pub fn mc_ws_connect(url_ptr: *const u8, url_len: usize) -> i32;
    pub fn mc_ws_send(handle: i32, ptr: *const u8, len: usize) -> i32;
    pub fn mc_ws_recv(handle: i32, buf: *mut u8, len: usize) -> i32;
    pub fn mc_ws_close(handle: i32);

    // Host call — a guest-invoked host-resident function (the tool shim and host-backed
    // mounts). Poll-based, mirroring HTTP; the host routes the opaque request blob to a
    // registered handler and streams back a result.
    //  - call: start the call; return an opaque handle >= 0, or -1 to refuse.
    //  - poll: 0 while in flight; >0 once the result is ready; -1 on failure.
    //  - body: result bytes (>0), 0 = EOF, -1 = error.
    //  - close: release the handle.
    pub fn mc_host_call(req_ptr: *const u8, req_len: usize) -> i32;
    pub fn mc_host_call_poll(handle: i32, buf: *mut u8, buf_len: usize) -> i32;
    pub fn mc_host_call_body(handle: i32, buf: *mut u8, buf_len: usize) -> i32;
    pub fn mc_host_call_close(handle: i32);

    // Persistence. A host-side key/value store, surfaced to the agent as the
    // `/var/persist` filesystem. Gateable: a host without the capability returns -1 on
    // every call. Return contract:
    //  - get(key -> value): -1 denied/error; -2 key-not-found; n>=0 the FULL value length
    //    (writes min(n, vl) bytes; 0 = present-but-empty). When n > vl the caller resizes
    //    and retries.
    //  - put(key, value): -1 denied/error; >=0 ok.
    //  - delete(key): -1 denied/error; 0 ok (deleting a missing key is ok).
    //  - list(prefix -> keys): -1 denied/error; n>=0 the FULL byte length of the
    //    NUL-separated matching keys (writes min(n, bl); resize + retry when n > bl).
    pub fn mc_persist_get(kp: *const u8, kl: usize, vp: *mut u8, vl: usize) -> i32;
    pub fn mc_persist_put(kp: *const u8, kl: usize, vp: *const u8, vl: usize) -> i32;
    pub fn mc_persist_delete(kp: *const u8, kl: usize) -> i32;
    pub fn mc_persist_list(pp: *const u8, pl: usize, bp: *mut u8, bl: usize) -> i32;

    // Threading — gateable; host returns -1/0 to refuse. The kernel calls
    // `mc_threads_init` once during boot to negotiate a worker count. `mc_thread_spawn`/
    // `park`/`unpark` are declared for ABI completeness and become live under the
    // real-OS-thread build; the cooperative-backed build does not reference them, so they
    // stay out of the import section.
    pub fn mc_threads_init(max_workers: i32) -> i32;
    pub fn mc_thread_spawn(entry: i32, arg: i32) -> i32;
    pub fn mc_thread_park(timeout_ms: i32) -> i32;
    pub fn mc_thread_unpark(handle: i32);

    // Control
    pub fn mc_yield();
    pub fn mc_exit(code: i32) -> !;
    pub fn mc_log(level: i32, ptr: *const u8, len: usize);

    // Filesystem - base image loading
    /// Load the base image (tar.gz) from host into kernel memory. Returns the number of
    /// bytes written to the buffer, or -1 on error.
    pub fn mc_load_base_image(buf: *mut u8, buf_len: usize) -> i32;

    /// Boot-time runtime contract from the image manifest. Writes
    /// `[i32 tier][i32 mem_mib][i64 fuel]` (little-endian, 16 bytes) into `buf`: `tier`
    /// 0=inherit / 1=full / 2=read-write / 3=read-only / 4=isolated; `mem_mib`/`fuel`
    /// ≤ 0 = unset (kernel default). Returns bytes written, or ≤ 0 if the host supplies no
    /// contract. Gateable (host may return 0).
    pub fn mc_boot_contract(buf: *mut u8, buf_len: usize) -> i32;
}
