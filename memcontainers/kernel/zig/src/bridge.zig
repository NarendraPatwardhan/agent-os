//! bridge.zig — the ONLY window to the host: the `extern "env"` import surface (ZIG_KERNEL
//! §1.1 A4, §5.1), declared here and GATED against the bridge-contract descriptor so it can
//! never silently drift.
//!
//! Why declared, not reflection-generated: Zig cannot synthesize a function type from a
//! descriptor (`@Type` rejects `.@"fn"`), so — unlike the Rust kernel's `mc_bridge_table!`
//! macro — the extern block is written out. Drift is caught two ways instead: (1) the
//! `contract_covered` check below fails the kernel build if bridge.kdl adds/renames an import
//! this file has not declared; (2) the contracts diff gate fails if a signature drifts from
//! bridge.kdl (env.gen.zig regenerates, the committed copy no longer matches). ABI-slot →
//! Zig-type mapping (§1.3): cptr → [*]const u8, mptr → [*]u8, len → usize.
//!
//! Owns: the typed `extern "env"` host imports. Lazy: an import becomes a wasm import only
//!   when a caller references it (A4, purity gate), so a declared-but-unused import costs
//!   nothing until boot/egress/persist actually calls it.
//! Invariants: A4 (imports only `env`), A5 (every native side effect flows through here).
//! Consumes: env_zig (the generated IMPORTS descriptor — the drift oracle).
//! Not here: guest→kernel syscalls (syscall.zig); control exports (main.zig/control.zig).
//!
//! Usage (Phase 3+): `const bridge = @import("bridge.zig");`
//!                   `const rc = bridge.mc_load_base_image(buf.ptr, buf.len);`

const contract = @import("env_zig");

// ── Terminal + clock + entropy ────────────────────────────────────────────────────────
pub extern "env" fn mc_stdout_write(ptr: [*]const u8, len: usize) void;
pub extern "env" fn mc_stderr_write(ptr: [*]const u8, len: usize) void;
pub extern "env" fn mc_stdin_read(buf: [*]u8, len: usize) usize;
pub extern "env" fn mc_time_now() i64;
pub extern "env" fn mc_time_monotonic() i64;
pub extern "env" fn mc_random(buf: [*]u8, len: usize) void;

// ── HTTP + WebSocket egress ─────────────────────────────────────────────────────────────
pub extern "env" fn mc_http_request(req_ptr: [*]const u8, req_len: usize) i32;
pub extern "env" fn mc_http_response_poll(handle: i32, buf: [*]u8, buf_len: usize) i32;
pub extern "env" fn mc_http_response_body(handle: i32, buf: [*]u8, buf_len: usize) i32;
pub extern "env" fn mc_http_request_close(handle: i32) void;
pub extern "env" fn mc_ws_connect(url_ptr: [*]const u8, url_len: usize) i32;
pub extern "env" fn mc_ws_send(handle: i32, ptr: [*]const u8, len: usize) i32;
pub extern "env" fn mc_ws_ready(handle: i32) i32;
pub extern "env" fn mc_ws_recv(handle: i32, buf: [*]u8, len: usize) i32;
pub extern "env" fn mc_ws_close(handle: i32) void;

// ── Opaque host call + persistence ──────────────────────────────────────────────────────
pub extern "env" fn mc_host_call(req_ptr: [*]const u8, req_len: usize) i32;
pub extern "env" fn mc_host_call_poll(handle: i32, buf: [*]u8, buf_len: usize) i32;
pub extern "env" fn mc_host_call_body(handle: i32, buf: [*]u8, buf_len: usize) i32;
pub extern "env" fn mc_host_call_close(handle: i32) void;
pub extern "env" fn mc_persist_start(req_ptr: [*]const u8, req_len: usize) i32;
pub extern "env" fn mc_persist_poll(handle: i32) i32;
pub extern "env" fn mc_persist_body(handle: i32, buf: [*]u8, buf_len: usize) i32;
pub extern "env" fn mc_persist_close(handle: i32) void;

// ── Cooperative worker plane (host has none yet; A2 threads gate) ───────────────────────
pub extern "env" fn mc_threads_init(max_workers: i32) i32;
pub extern "env" fn mc_thread_spawn(entry: i32, arg: i32) i32;
pub extern "env" fn mc_thread_park(timeout_ms: i32) i32;
pub extern "env" fn mc_thread_unpark(handle: i32) void;
pub extern "env" fn mc_yield() void;

// ── Process + logging + boot ────────────────────────────────────────────────────────────
pub extern "env" fn mc_exit(code: i32) noreturn;
pub extern "env" fn mc_log(level: i32, ptr: [*]const u8, len: usize) void;
pub extern "env" fn mc_load_base_image(buf: [*]u8, buf_len: usize) i32;
pub extern "env" fn mc_boot_contract(buf: [*]u8, buf_len: usize) i32;

/// Completeness gate: every import the bridge contract declares is declared above. Reference
/// this from the kernel root (main.zig) so a bridge.kdl add/rename breaks the kernel build
/// (§5.2) — @hasDecl is type-level, so no import materializes here.
pub const contract_covered = blk: {
    for (contract.IMPORTS) |desc| {
        if (!@hasDecl(@This(), desc.name)) {
            @compileError("bridge.zig: missing `extern \"env\"` decl for contract import '" ++ desc.name ++ "' — bridge.kdl changed; declare it here.");
        }
    }
    break :blk contract.IMPORTS.len;
};
