//! Boot — the nest is alive. Booting the real `kernel.wasm` under the real host is the implicit
//! first assertion of every other test; these pin the boot transcript explicitly.

use crate::boot;

/// WHY: the load-bearing edge of the whole project (A3) is "the kernel runs ONLY as wasm, under the
/// host." GUARANTEES: wasmtime instantiates kernel.wasm, the generated `env` bridge services its
/// stdout/boot calls, the base image loads, the filesystems mount, and pid 1 reaches an interactive
/// prompt — the whole nest (wasmtime → kernel → wasmi) is alive, not merely compiling.
#[test]
fn boot_reaches_login_prompt() {
    let s = boot();
    assert!(s.host.at_prompt(), "shell did not settle at a prompt");
    let out = s.transcript();
    for marker in ["Booting", "Loading image", "Mounting /dev", "Sourcing /etc/profile"] {
        assert!(out.contains(marker), "boot transcript missing {marker:?}; got:\n{out}");
    }
}
