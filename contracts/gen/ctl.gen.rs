// @generated from contracts/control.kdl by //contracts/codegen:projector — do not edit.

pub const CONTROL_EXPORTS: &[&str] = &[
    "mc_init",
    "mc_tick",
    "mc_input",
    "mc_resize",
    "mc_ctl_buf",
    "mc_ctl_read",
    "mc_ctl_write",
    "mc_ctl_readdir",
    "mc_ctl_stat",
    "mc_ctl_mkdir",
    "mc_ctl_unlink",
    "mc_ctl_symlink",
    "mc_ctl_mount",
    "mc_ctl_unmount",
    "mc_ctl_exec_start",
    "mc_ctl_exec_poll",
    "mc_ctl_exec_peek",
    "mc_ctl_exec_close",
    "mc_commit_layer",
    "mc_inflight_egress",
    "mc_pending_commits",
    "mc_quiesce_request",
    "mc_quiesce_release",
    "mc_worker_entry",
];

/// The canonical table. A consumer hands its own `$emit!` callback (the kernel's
/// dispatch, the sysroot's extern block, the host's import table) and cannot drift.
#[macro_export]
macro_rules! mc_control_table {
    ($emit:path) => { $emit! {
        mc_init => Init ();  // -> i32
        mc_tick => Tick ();  // -> i32
        mc_input => Input (ptr: ptr, len: len);  // -> i32
        mc_resize => Resize (cols: i32, rows: i32);  // -> i32
        mc_ctl_buf => Buf (len: len);  // -> ptr
        mc_ctl_read => Read (path_ptr: u32, path_len: u32);  // -> i32
        mc_ctl_write => Write (path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32);  // -> i32
        mc_ctl_readdir => Readdir (path_ptr: u32, path_len: u32);  // -> i32
        mc_ctl_stat => Stat (path_ptr: u32, path_len: u32);  // -> i32
        mc_ctl_mkdir => Mkdir (path_ptr: u32, path_len: u32);  // -> i32
        mc_ctl_unlink => Unlink (path_ptr: u32, path_len: u32);  // -> i32
        mc_ctl_symlink => Symlink (target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32);  // -> i32
        mc_ctl_mount => Mount (path_ptr: u32, path_len: u32, read_only: i32);  // -> i32
        mc_ctl_unmount => Unmount (path_ptr: u32, path_len: u32);  // -> i32
        mc_ctl_exec_start => ExecStart (cmd_len: u32);  // -> i32
        mc_ctl_exec_poll => ExecPoll (job_id: u32);  // -> i32
        mc_ctl_exec_peek => ExecPeek (job_id: u32);  // -> i32
        mc_ctl_exec_close => ExecClose (job_id: u32);  // -> i32
        mc_commit_layer => CommitLayer ();  // -> i32
        mc_inflight_egress => InflightEgress ();  // -> i32
        mc_pending_commits => PendingCommits ();  // -> i32
        mc_quiesce_request => QuiesceRequest ();  // -> i32
        mc_quiesce_release => QuiesceRelease ();  // -> i32
        mc_worker_entry => WorkerEntry (arg: i32);  // -> i32
    } };
}
