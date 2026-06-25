// @generated from contracts/control.kdl by //contracts/codegen:projector — do not edit.

pub const Arg = struct { name: []const u8, ty: []const u8 };
pub const Desc = struct { name: []const u8, variant: []const u8, args: []const Arg, ret: []const u8 };

pub const EXPORTS = [_]Desc{
    .{ .name = "mc_init", .variant = "Init", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_tick", .variant = "Tick", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_input", .variant = "Input", .args = &.{ .{ .name = "ptr", .ty = "cptr" }, .{ .name = "len", .ty = "len" } }, .ret = "void" },
    .{ .name = "mc_resize", .variant = "Resize", .args = &.{ .{ .name = "cols", .ty = "i32" }, .{ .name = "rows", .ty = "i32" } }, .ret = "void" },
    .{ .name = "mc_ctl_buf", .variant = "Buf", .args = &.{ .{ .name = "len", .ty = "len" } }, .ret = "mptr" },
    .{ .name = "mc_ctl_read", .variant = "Read", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_write", .variant = "Write", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "data_ptr", .ty = "u32" }, .{ .name = "data_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_readdir", .variant = "Readdir", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_stat", .variant = "Stat", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_mkdir", .variant = "Mkdir", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_unlink", .variant = "Unlink", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_symlink", .variant = "Symlink", .args = &.{ .{ .name = "target_ptr", .ty = "u32" }, .{ .name = "target_len", .ty = "u32" }, .{ .name = "link_ptr", .ty = "u32" }, .{ .name = "link_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_mount", .variant = "Mount", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" }, .{ .name = "read_only", .ty = "i32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_unmount", .variant = "Unmount", .args = &.{ .{ .name = "path_ptr", .ty = "u32" }, .{ .name = "path_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_start", .variant = "ExecStart", .args = &.{ .{ .name = "cmd_len", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_poll", .variant = "ExecPoll", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_peek", .variant = "ExecPeek", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_ctl_exec_close", .variant = "ExecClose", .args = &.{ .{ .name = "job_id", .ty = "u32" } }, .ret = "i32" },
    .{ .name = "mc_commit_layer", .variant = "CommitLayer", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_inflight_egress", .variant = "InflightEgress", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_pending_commits", .variant = "PendingCommits", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_quiesce_request", .variant = "QuiesceRequest", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_quiesce_release", .variant = "QuiesceRelease", .args = &.{  }, .ret = "i32" },
    .{ .name = "mc_worker_entry", .variant = "WorkerEntry", .args = &.{ .{ .name = "arg", .ty = "i32" } }, .ret = "i32" },
};
