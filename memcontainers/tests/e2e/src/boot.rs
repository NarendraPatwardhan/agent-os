//! Boot — the nest is alive. Booting the real `kernel.wasm` under the real host is the implicit
//! first assertion of every other test; these pin the boot transcript explicitly.

use crate::{boot, boot_rootfs};
use host::AutocompleteOptions;

/// WHY: the load-bearing edge of the whole project (A3) is "the kernel runs ONLY as wasm, under the
/// host." GUARANTEES: wasmtime instantiates kernel.wasm, the generated `env` bridge services its
/// stdout/boot calls, the base image loads, the filesystems mount, and pid 1 reaches an interactive
/// prompt — the whole nest (wasmtime → kernel → wasmi) is alive, not merely compiling.
#[test]
fn boot_reaches_login_prompt() {
    let s = boot();
    assert!(s.host.at_prompt(), "shell did not settle at a prompt");
    let out = s.transcript();
    for marker in ["Booting", "Loading image", "Mounting /dev", "Mounting /var/persist"] {
        assert!(out.contains(marker), "boot transcript missing {marker:?}; got:\n{out}");
    }
}

/// WHY: a missing `/bin/sh` must not activate an undocumented kernel shell or
/// make pid 1 disappear. GUARANTEES: boot enters explicit maintenance mode,
/// retains a zero-work pid-1 anchor and the structured VFS surface, and rejects
/// completion because there is no canonical shell parser to consult.
#[test]
fn shell_less_image_enters_explicit_maintenance_mode() {
    let mut s = boot_rootfs();
    assert!(!s.host.at_prompt(), "maintenance mode must not fake a shell prompt");

    let profile = s
        .host
        .read_file("/etc/profile")
        .expect("structured VFS remains available");
    assert!(profile.starts_with(b"#"), "unexpected profile fixture");

    let status = s
        .host
        .read_file("/proc/1/status")
        .expect("maintenance pid 1 remains observable");
    assert!(
        String::from_utf8_lossy(&status).contains("Name:\tinit"),
        "maintenance pid 1 disappeared or changed identity: {:?}",
        String::from_utf8_lossy(&status)
    );
    assert!(
        s.host
            .autocomplete(b"ec", 2, AutocompleteOptions::default())
            .is_err(),
        "maintenance mode must not provide a second shell parser"
    );
}
