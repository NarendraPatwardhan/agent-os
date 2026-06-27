// @generated from contracts/bridge.kdl by //contracts/codegen:projector — do not edit.
#![no_std]

pub const BRIDGE_IMPORTS: &[&str] = &[
    "mc_stdout_write",
    "mc_stderr_write",
    "mc_stdin_read",
    "mc_time_now",
    "mc_time_monotonic",
    "mc_random",
    "mc_http_request",
    "mc_http_response_poll",
    "mc_http_response_body",
    "mc_http_request_close",
    "mc_ws_connect",
    "mc_ws_send",
    "mc_ws_ready",
    "mc_ws_recv",
    "mc_ws_close",
    "mc_host_call",
    "mc_host_call_poll",
    "mc_host_call_body",
    "mc_host_call_close",
    "mc_persist_start",
    "mc_persist_poll",
    "mc_persist_body",
    "mc_persist_close",
    "mc_threads_init",
    "mc_thread_spawn",
    "mc_thread_park",
    "mc_thread_unpark",
    "mc_yield",
    "mc_exit",
    "mc_log",
    "mc_load_base_image",
    "mc_boot_contract",
];

/// The canonical table. A consumer hands its own `$emit!` callback (the kernel's
/// dispatch, the sysroot's extern block, the host's import table) and cannot drift.
#[macro_export]
macro_rules! mc_bridge_table {
    ($emit:path) => { $emit! {
        mc_stdout_write => StdoutWrite (ptr: cptr, len: len) [void];
        mc_stderr_write => StderrWrite (ptr: cptr, len: len) [void];
        mc_stdin_read => StdinRead (buf: mptr, len: len) [len];
        mc_time_now => TimeNow () [i64];
        mc_time_monotonic => TimeMonotonic () [i64];
        mc_random => Random (buf: mptr, len: len) [void];
        mc_http_request => HttpRequest (req_ptr: cptr, req_len: len) [i32];
        mc_http_response_poll => HttpResponsePoll (handle: i32, buf: mptr, buf_len: len) [i32];
        mc_http_response_body => HttpResponseBody (handle: i32, buf: mptr, buf_len: len) [i32];
        mc_http_request_close => HttpRequestClose (handle: i32) [void];
        mc_ws_connect => WsConnect (url_ptr: cptr, url_len: len) [i32];
        mc_ws_send => WsSend (handle: i32, ptr: cptr, len: len) [i32];
        mc_ws_ready => WsReady (handle: i32) [i32];
        mc_ws_recv => WsRecv (handle: i32, buf: mptr, len: len) [i32];
        mc_ws_close => WsClose (handle: i32) [void];
        mc_host_call => HostCall (req_ptr: cptr, req_len: len) [i32];
        mc_host_call_poll => HostCallPoll (handle: i32, buf: mptr, buf_len: len) [i32];
        mc_host_call_body => HostCallBody (handle: i32, buf: mptr, buf_len: len) [i32];
        mc_host_call_close => HostCallClose (handle: i32) [void];
        mc_persist_start => PersistStart (req_ptr: cptr, req_len: len) [i32];
        mc_persist_poll => PersistPoll (handle: i32) [i32];
        mc_persist_body => PersistBody (handle: i32, buf: mptr, buf_len: len) [i32];
        mc_persist_close => PersistClose (handle: i32) [void];
        mc_threads_init => ThreadsInit (max_workers: i32) [i32];
        mc_thread_spawn => ThreadSpawn (entry: i32, arg: i32) [i32];
        mc_thread_park => ThreadPark (timeout_ms: i32) [i32];
        mc_thread_unpark => ThreadUnpark (handle: i32) [void];
        mc_yield => Yield () [void];
        mc_exit => Exit (code: i32) [noreturn];
        mc_log => Log (level: i32, ptr: cptr, len: len) [void];
        mc_load_base_image => LoadBaseImage (buf: mptr, buf_len: len) [i32];
        mc_boot_contract => BootContract (buf: mptr, buf_len: len) [i32];
    } };
}
