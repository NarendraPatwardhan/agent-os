//! Zig rescue shell — pid 1 survives without a guest `/bin/sh`.

use crate::{boot_rootfs, kernel_under_test_rlocation};

/// WHY: the Zig kernel has a native shcore rescue shell for images where `/bin/sh` is missing or
/// broken. GUARANTEES: booting the rootfs-only image reaches the rescue prompt and pure shcore
/// builtins run against pid 1's kernel Task rather than a guest console pipe.
#[test]
fn zig_rescue_shell_boots_without_guest_sh_and_runs_builtins() {
    if !kernel_under_test_rlocation().contains("memcontainers/kernel/zig") {
        return;
    }

    let mut s = boot_rootfs();
    assert!(
        s.host.at_prompt(),
        "rescue shell did not settle at a prompt:\n{}",
        s.transcript()
    );
    assert!(
        s.transcript()
            .contains("login shell unavailable; starting rescue shell"),
        "boot transcript did not report rescue fallback:\n{}",
        s.transcript()
    );

    assert_eq!(s.run_for_output("pwd"), "/home/user\r\n");
    assert_eq!(s.run_for_output("cd /etc"), "");
    assert_eq!(s.run_for_output("pwd"), "/etc\r\n");
    assert_eq!(s.run_for_output("echo hi"), "hi\r\n");
}
