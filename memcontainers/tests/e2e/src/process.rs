//! Process syscalls — guest spawn/wait through the real shell on the real kernel.

use crate::boot_posix;

/// WHY: `/bin/sh` launches an external coreutil through `mc_sys_spawn`, the child runs under the
/// scheduler, and the shell observes its status through `mc_sys_waitpid`. GUARANTEES: the child
/// prints real file content and `$?` is the reaped exit status, not a shell-only shortcut.
#[test]
fn shell_spawns_coreutil_and_reaps_exit_status() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/process-proof", b"spawned child\n")
        .expect("write /tmp/process-proof");
    let response = s.send_line("cat /tmp/process-proof; echo status:$?");
    assert!(
        response.contains("spawned child"),
        "child output missing; got:\n{response:?}"
    );
    assert!(
        response.contains("status:0"),
        "reaped exit status missing; got:\n{response:?}"
    );
}
