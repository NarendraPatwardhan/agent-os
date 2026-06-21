//! End-to-end suite (B6, §9.1): every test boots the REAL kernel.wasm inside the REAL
//! wasmtime host and asserts on REAL bytes — no mocks. Booting is itself the first
//! assertion: a kernel trap or a generated-bridge mismatch surfaces here as a host error,
//! not a silent skip. The kernel + base image are `data` deps (B1, §7.2), so a test always
//! runs the artifact its sources produce — the death of the memcontainers staleness class.
//!
//! Scope: this exercises what the system supports WITHOUT guest programs — boot (the `env`
//! bridge), the structured control channel (the generated `ctl` exports), the base image
//! (TarFs), and snapshot/restore (A8). Shell/coreutils/luau/sqlite tests arrive with their
//! guests; we don't port tests we can't yet run (they'd be `command not found`).
//!
//! Performance: the whole suite lives in ONE binary on purpose. The host compiles
//! kernel.wasm once per process (~0.9s) and every boot after is ~1.6ms (MODULE_CACHE), so
//! the entire suite runs in ~1s. See defs.bzl.
//!
//! Naming: `<subject>_<behavior>`, one invariant per test, each with a WHY/GUARANTEES note.

use host::{CaptureSink, DirEntry, KernelHost, KernelHostBuilder};
use std::sync::{Arc, Mutex};

/// Locate a `data`-dep artifact in the test's runfiles by its workspace-relative path.
fn runfile(path: &str) -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

/// A builder wired to the real kernel + base image, deterministic clock+rng (§15.1), and a
/// captured stdout. Returned (not built) so callers can either `.build()` a fresh boot or
/// `.restore(snapshot)` a rehydrated VM from the same configuration.
fn builder() -> (KernelHostBuilder, Arc<Mutex<Vec<u8>>>) {
    let (sink, stdout) = CaptureSink::new();
    let b = KernelHostBuilder::new(runfile("_main/kernel/rust/kernel.wasm"))
        .with_base_image(Some(runfile("_main/images/base.tar")))
        .with_stdout(Box::new(sink))
        .deterministic();
    (b, stdout)
}

/// Boot the real kernel under the real host. The returned stdout buffer already holds the
/// boot transcript, since `build()` drives ticks to the first prompt.
fn boot() -> (KernelHost, Arc<Mutex<Vec<u8>>>) {
    let (b, stdout) = builder();
    (b.build().expect("kernel booted under the host"), stdout)
}

fn names(entries: &[DirEntry]) -> Vec<&str> {
    entries.iter().map(|e| e.name.as_str()).collect()
}

/// WHY: the load-bearing edge of the whole project (A3) is "the kernel runs ONLY as wasm,
/// under the host." GUARANTEES: wasmtime instantiates kernel.wasm, the generated `env`
/// bridge services its stdout/boot calls, the base image loads, the filesystems mount, and
/// pid 1 reaches an interactive prompt — the entire nest (wasmtime → kernel → wasmi) is
/// alive, not merely compiling.
#[test]
fn boot_reaches_login_prompt() {
    let (host, stdout) = boot();
    assert!(host.at_prompt(), "shell did not settle at a prompt");
    let out = String::from_utf8_lossy(&stdout.lock().unwrap()).into_owned();
    for marker in ["Booting", "Loading image", "Mounting /dev", "Sourcing /etc/profile"] {
        assert!(out.contains(marker), "boot transcript missing {marker:?}; got:\n{out}");
    }
}

/// WHY: the base image is a deterministic pkg_tar (§10) the kernel mounts as its lowest
/// layer; the structured control channel (`mc_ctl_read`, generated in exports.rs) is how
/// the host reads guest files out-of-band. GUARANTEES: the image's /etc/profile is present
/// in the mounted TarFs AND the generated ctl `read` export round-trips its bytes to the
/// host.
#[test]
fn base_image_profile_is_readable_over_control_channel() {
    let (mut host, _stdout) = boot();
    let profile = host.read_file("/etc/profile").expect("read /etc/profile");
    let text = String::from_utf8_lossy(&profile);
    assert!(
        text.contains("export PATH=/bin:/usr/bin"),
        "/etc/profile content unexpected: {text:?}"
    );
}

/// WHY: a guest's writes land in the CoW/tmpfs overlay, and the control channel must both
/// write and read them (the host halves of `mc_ctl_write` + `mc_ctl_read`). GUARANTEES: a
/// write through the generated ctl bridge is durable within the VM and reads back
/// byte-identical — the write/read seam is wired end to end.
#[test]
fn control_channel_write_then_read_roundtrips() {
    let (mut host, _stdout) = boot();
    host.write_file("/tmp/note", b"agent-os e2e").expect("write /tmp/note");
    assert_eq!(host.read_file("/tmp/note").expect("read /tmp/note"), b"agent-os e2e");
}

/// WHY: directories, metadata, and listing are distinct ctl exports
/// (`mc_ctl_mkdir`/`stat`/`readdir`). GUARANTEES: a created directory reports `is_dir`
/// through `stat`, and a file written inside it shows up in `readdir` — the directory
/// surface of the control channel agrees with the VFS.
#[test]
fn control_channel_mkdir_stat_and_readdir() {
    let (mut host, _stdout) = boot();
    host.mkdir("/tmp/work").expect("mkdir /tmp/work");
    host.write_file("/tmp/work/a.txt", b"x").expect("write a.txt");

    let st = host.stat("/tmp/work").expect("stat /tmp/work");
    assert!(st.is_dir && !st.is_symlink, "stat of a dir: {st:?}");

    let listing = host.readdir("/tmp/work").expect("readdir /tmp/work");
    assert!(names(&listing).contains(&"a.txt"), "readdir missing a.txt: {listing:?}");
}

/// WHY: removal must actually remove (`mc_ctl_unlink`), and a read of a missing path must
/// fail rather than return stale bytes. GUARANTEES: after `unlink`, the path is gone and
/// the ctl `read` reports an error — deletions are real, and errno surfaces as a host error.
#[test]
fn control_channel_unlink_then_read_errors() {
    let (mut host, _stdout) = boot();
    host.write_file("/tmp/gone", b"temporary").expect("write /tmp/gone");
    host.unlink("/tmp/gone").expect("unlink /tmp/gone");
    assert!(host.read_file("/tmp/gone").is_err(), "read of an unlinked file should error");
}

/// WHY: symlinks carry their own metadata AND resolve POSIX-style — `stat` is lstat (the
/// LINK itself: symlink kind, size = target-text length, nlink 1), while a `read` of a
/// symlink path FOLLOWS the link to the target's bytes (like `open`). GUARANTEES: the
/// generated `mc_ctl_symlink`/`stat`/`readdir` expose the link's metadata, and the ctl
/// `read` path resolves through the link to its target content.
#[test]
fn control_channel_symlink_lstat_metadata_and_read_follows() {
    let (mut host, _stdout) = boot();
    host.write_file("/tmp/target", b"pointee").expect("write target");
    host.symlink("/tmp/target", "/tmp/link").expect("symlink");

    let st = host.stat("/tmp/link").expect("stat /tmp/link");
    assert!(st.is_symlink && !st.is_dir, "lstat should report a symlink: {st:?}");
    assert_eq!(st.size, "/tmp/target".len() as u64, "symlink size = target-text length");
    assert_eq!(st.nlink, 1, "fresh symlink link count");

    let entries = host.readdir("/tmp").expect("readdir /tmp");
    assert!(
        entries.iter().any(|e| e.name == "link" && e.is_symlink && !e.is_dir),
        "readdir must expose symlink kind; got {entries:?}"
    );

    // A read of the link path follows it to the target (POSIX open semantics).
    assert_eq!(host.read_file("/tmp/link").expect("read through link"), b"pointee");
}

/// WHY: the ctl read path negotiates buffer size — the kernel returns the FULL length so
/// the host grows its buffer and retries when the data exceeds the initial control buffer.
/// GUARANTEES: a payload far larger than the control buffer round-trips intact — the
/// resize-and-retry handshake works, not just small reads.
#[test]
fn control_channel_large_file_roundtrips() {
    let (mut host, _stdout) = boot();
    let big = vec![b'Z'; 256 * 1024];
    host.write_file("/tmp/big", &big).expect("write big");
    assert_eq!(host.read_file("/tmp/big").expect("read big"), big);
}

/// WHY: A8 — the entire VM is a portable value: `snapshot` captures linear memory, and
/// `restore` rehydrates a fresh VM from it. GUARANTEES: state written before a snapshot is
/// present in a VM restored from it — the snapshot/restore round-trip preserves the
/// filesystem, with no re-boot.
#[test]
fn snapshot_then_restore_preserves_a_written_file() {
    let (mut host, _stdout) = boot();
    host.write_file("/tmp/keep", b"survives a snapshot").expect("write /tmp/keep");
    let snap = host.snapshot().expect("snapshot");

    let (b, _stdout) = builder();
    let mut restored = b.restore(&snap).expect("restore from snapshot");
    assert_eq!(
        restored.read_file("/tmp/keep").expect("read in restored VM"),
        b"survives a snapshot"
    );
}

/// WHY: A8 forking — restoring one snapshot twice must yield two INDEPENDENT VMs, not two
/// views of one. GUARANTEES: divergent writes to the same path in each restored VM do not
/// bleed across — the restore path gives each VM its own linear memory.
#[test]
fn restoring_a_snapshot_twice_forks_independent_vms() {
    let (mut host, _stdout) = boot();
    let snap = host.snapshot().expect("snapshot");

    let mut a = builder().0.restore(&snap).expect("restore a");
    let mut b = builder().0.restore(&snap).expect("restore b");
    a.write_file("/tmp/fork", b"branch-a").expect("write a");
    b.write_file("/tmp/fork", b"branch-b").expect("write b");

    assert_eq!(a.read_file("/tmp/fork").expect("read a"), b"branch-a");
    assert_eq!(b.read_file("/tmp/fork").expect("read b"), b"branch-b");
}
