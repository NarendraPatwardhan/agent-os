// @generated from contracts/bridge.kdl by //contracts/codegen:projector — do not edit.

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
    "mc_ws_recv",
    "mc_ws_close",
    "mc_host_call",
    "mc_host_call_poll",
    "mc_host_call_body",
    "mc_host_call_close",
    "mc_persist_get",
    "mc_persist_put",
    "mc_persist_delete",
    "mc_persist_list",
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
        mc_stdout_write => StdoutWrite (ptr: ptr, len: len);  // -> i32
        mc_stderr_write => StderrWrite (ptr: ptr, len: len);  // -> i32
        mc_stdin_read => StdinRead (buf: ptr, len: len);  // -> len
        mc_time_now => TimeNow ();  // -> i64
        mc_time_monotonic => TimeMonotonic ();  // -> i64
        mc_random => Random (buf: ptr, len: len);  // -> i32
        mc_http_request => HttpRequest (req_ptr: ptr, req_len: len);  // -> i32
        mc_http_response_poll => HttpResponsePoll (handle: i32, buf: ptr, buf_len: len);  // -> i32
        mc_http_response_body => HttpResponseBody (handle: i32, buf: ptr, buf_len: len);  // -> i32
        mc_http_request_close => HttpRequestClose (handle: i32);  // -> i32
        mc_ws_connect => WsConnect (url_ptr: ptr, url_len: len);  // -> i32
        mc_ws_send => WsSend (handle: i32, ptr: ptr, len: len);  // -> i32
        mc_ws_recv => WsRecv (handle: i32, buf: ptr, len: len);  // -> i32
        mc_ws_close => WsClose (handle: i32);  // -> i32
        mc_host_call => HostCall (req_ptr: ptr, req_len: len);  // -> i32
        mc_host_call_poll => HostCallPoll (handle: i32, buf: ptr, buf_len: len);  // -> i32
        mc_host_call_body => HostCallBody (handle: i32, buf: ptr, buf_len: len);  // -> i32
        mc_host_call_close => HostCallClose (handle: i32);  // -> i32
        mc_persist_get => PersistGet (kp: ptr, kl: len, vp: ptr, vl: len);  // -> i32
        mc_persist_put => PersistPut (kp: ptr, kl: len, vp: ptr, vl: len);  // -> i32
        mc_persist_delete => PersistDelete (kp: ptr, kl: len);  // -> i32
        mc_persist_list => PersistList (pp: ptr, pl: len, bp: ptr, bl: len);  // -> i32
        mc_threads_init => ThreadsInit (max_workers: i32);  // -> i32
        mc_thread_spawn => ThreadSpawn (entry: i32, arg: i32);  // -> i32
        mc_thread_park => ThreadPark (timeout_ms: i32);  // -> i32
        mc_thread_unpark => ThreadUnpark (handle: i32);  // -> i32
        mc_yield => Yield ();  // -> i32
        mc_exit => Exit (code: i32);  // -> noreturn
        mc_log => Log (level: i32, ptr: ptr, len: len);  // -> i32
        mc_load_base_image => LoadBaseImage (buf: ptr, buf_len: len);  // -> i32
        mc_boot_contract => BootContract (buf: ptr, buf_len: len);  // -> i32
    } };
}
