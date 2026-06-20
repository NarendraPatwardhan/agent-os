// @generated from contracts/bridge.kdl by //contracts/codegen:projector — do not edit.

pub const Arg = struct { name: []const u8, ty: []const u8 };
pub const Desc = struct { name: []const u8, variant: []const u8, args: []const Arg, ret: []const u8 };

pub const IMPORTS = [_]Desc{
    .{ .name = "mc_stdout_write", .variant = "StdoutWrite", .args = &.{ .{ .name = "ptr", .ty = "ptr" }, .{ .name = "len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_stderr_write", .variant = "StderrWrite", .args = &.{ .{ .name = "ptr", .ty = "ptr" }, .{ .name = "len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_stdin_read", .variant = "StdinRead", .args = &.{ .{ .name = "buf", .ty = "ptr" }, .{ .name = "len", .ty = "len" } }, .ret = "len" },
    .{ .name = "mc_time_now", .variant = "TimeNow", .args = &.{  }, .ret = "i64" },
    .{ .name = "mc_time_monotonic", .variant = "TimeMonotonic", .args = &.{  }, .ret = "i64" },
    .{ .name = "mc_random", .variant = "Random", .args = &.{ .{ .name = "buf", .ty = "ptr" }, .{ .name = "len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_http_request", .variant = "HttpRequest", .args = &.{ .{ .name = "req_ptr", .ty = "ptr" }, .{ .name = "req_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_http_response_poll", .variant = "HttpResponsePoll", .args = &.{ .{ .name = "handle", .ty = "i32" }, .{ .name = "buf", .ty = "ptr" }, .{ .name = "buf_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_http_response_body", .variant = "HttpResponseBody", .args = &.{ .{ .name = "handle", .ty = "i32" }, .{ .name = "buf", .ty = "ptr" }, .{ .name = "buf_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_http_request_close", .variant = "HttpRequestClose", .args = &.{ .{ .name = "handle", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_ws_connect", .variant = "WsConnect", .args = &.{ .{ .name = "url_ptr", .ty = "ptr" }, .{ .name = "url_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_ws_send", .variant = "WsSend", .args = &.{ .{ .name = "handle", .ty = "i32" }, .{ .name = "ptr", .ty = "ptr" }, .{ .name = "len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_ws_recv", .variant = "WsRecv", .args = &.{ .{ .name = "handle", .ty = "i32" }, .{ .name = "buf", .ty = "ptr" }, .{ .name = "len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_ws_close", .variant = "WsClose", .args = &.{ .{ .name = "handle", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_host_call", .variant = "HostCall", .args = &.{ .{ .name = "req_ptr", .ty = "ptr" }, .{ .name = "req_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_host_call_poll", .variant = "HostCallPoll", .args = &.{ .{ .name = "handle", .ty = "i32" }, .{ .name = "buf", .ty = "ptr" }, .{ .name = "buf_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_host_call_body", .variant = "HostCallBody", .args = &.{ .{ .name = "handle", .ty = "i32" }, .{ .name = "buf", .ty = "ptr" }, .{ .name = "buf_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_host_call_close", .variant = "HostCallClose", .args = &.{ .{ .name = "handle", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_persist_get", .variant = "PersistGet", .args = &.{ .{ .name = "kp", .ty = "ptr" }, .{ .name = "kl", .ty = "len" }, .{ .name = "vp", .ty = "ptr" }, .{ .name = "vl", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_persist_put", .variant = "PersistPut", .args = &.{ .{ .name = "kp", .ty = "ptr" }, .{ .name = "kl", .ty = "len" }, .{ .name = "vp", .ty = "ptr" }, .{ .name = "vl", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_persist_delete", .variant = "PersistDelete", .args = &.{ .{ .name = "kp", .ty = "ptr" }, .{ .name = "kl", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_persist_list", .variant = "PersistList", .args = &.{ .{ .name = "pp", .ty = "ptr" }, .{ .name = "pl", .ty = "len" }, .{ .name = "bp", .ty = "ptr" }, .{ .name = "bl", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_threads_init", .variant = "ThreadsInit", .args = &.{ .{ .name = "max_workers", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_thread_spawn", .variant = "ThreadSpawn", .args = &.{ .{ .name = "entry", .ty = "i32" }, .{ .name = "arg", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_thread_park", .variant = "ThreadPark", .args = &.{ .{ .name = "timeout_ms", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_thread_unpark", .variant = "ThreadUnpark", .args = &.{ .{ .name = "handle", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_yield", .variant = "Yield", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_exit", .variant = "Exit", .args = &.{ .{ .name = "code", .ty = "i32" } }, .ret = "noreturn" },
    .{ .name = "mc_log", .variant = "Log", .args = &.{ .{ .name = "level", .ty = "i32" }, .{ .name = "ptr", .ty = "ptr" }, .{ .name = "len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_load_base_image", .variant = "LoadBaseImage", .args = &.{ .{ .name = "buf", .ty = "ptr" }, .{ .name = "buf_len", .ty = "len" } }, .ret = "i32" },
    .{ .name = "mc_boot_contract", .variant = "BootContract", .args = &.{ .{ .name = "buf", .ty = "ptr" }, .{ .name = "buf_len", .ty = "len" } }, .ret = "i32" },
};
