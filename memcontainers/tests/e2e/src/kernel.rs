//! Kernel — the structured control channel (the generated `ctl` exports) and snapshot/restore.
//! This is the host's out-of-band, programmatic surface: a PIPE (pure LF), distinct from the
//! interactive terminal's ONLCR (CRLF — see [`crate::tty`], SYSTEMS.md section 6). No guest programs needed except the
//! one exec test, which proves the pipe stays raw.

use crate::{boot, boot_posix, names, restore};
use host::ExecOptions;

/// WHY: the base image is a deterministic pkg_tar (SYSTEMS.md section 11) the kernel mounts as its lowest layer; the
/// control channel (`mc_ctl_read`) reads guest files out-of-band. GUARANTEES: the image's
/// /etc/profile is present in the mounted TarFs AND the generated ctl `read` round-trips its bytes.
#[test]
fn control_channel_reads_image_profile() {
    let mut s = boot();
    let profile = s.host.read_file("/etc/profile").expect("read /etc/profile");
    let text = String::from_utf8_lossy(&profile);
    assert!(
        text.contains("export PATH=/bin:/usr/bin"),
        "/etc/profile unexpected: {text:?}"
    );
}

/// WHY: a guest's writes land in the CoW/tmpfs overlay, and the control channel must both write and
/// read them (`mc_ctl_write` + `mc_ctl_read`). GUARANTEES: a write through the ctl bridge is durable
/// within the VM and reads back byte-identical — the write/read seam is wired end to end.
#[test]
fn control_channel_write_then_read_roundtrips() {
    let mut s = boot();
    s.host
        .write_file("/tmp/note", b"agent-os e2e")
        .expect("write /tmp/note");
    assert_eq!(
        s.host.read_file("/tmp/note").expect("read /tmp/note"),
        b"agent-os e2e"
    );
}

/// WHY: directories, metadata, and listing are distinct ctl exports (`mc_ctl_mkdir`/`stat`/
/// `readdir`). GUARANTEES: a created directory reports `is_dir` through `stat`, and a file written
/// inside it shows up in `readdir` — the directory surface agrees with the VFS.
#[test]
fn control_channel_mkdir_stat_and_readdir() {
    let mut s = boot();
    s.host.mkdir("/tmp/work").expect("mkdir /tmp/work");
    s.host
        .write_file("/tmp/work/a.txt", b"x")
        .expect("write a.txt");

    let st = s.host.stat("/tmp/work").expect("stat /tmp/work");
    assert!(st.is_dir && !st.is_symlink, "stat of a dir: {st:?}");

    let listing = s.host.readdir("/tmp/work").expect("readdir /tmp/work");
    assert!(
        names(&listing).contains(&"a.txt"),
        "readdir missing a.txt: {listing:?}"
    );
}

/// WHY: removal must actually remove (`mc_ctl_unlink`), and a read of a missing path must fail
/// rather than return stale bytes. GUARANTEES: after `unlink`, the path is gone and the ctl `read`
/// reports an error — deletions are real, and errno surfaces as a host error.
#[test]
fn control_channel_unlink_then_read_errors() {
    let mut s = boot();
    s.host
        .write_file("/tmp/gone", b"temporary")
        .expect("write /tmp/gone");
    s.host.unlink("/tmp/gone").expect("unlink /tmp/gone");
    assert!(
        s.host.read_file("/tmp/gone").is_err(),
        "read of an unlinked file should error"
    );
}

/// WHY: symlinks carry their own metadata AND resolve POSIX-style — `stat` is lstat (the LINK:
/// symlink kind, size = target-text length, nlink 1), while a `read` of a symlink path FOLLOWS the
/// link. GUARANTEES: `mc_ctl_symlink`/`stat`/`readdir` expose the link's metadata, and the ctl
/// `read` resolves through the link to its target content.
#[test]
fn control_channel_symlink_lstat_metadata_and_read_follows() {
    let mut s = boot();
    s.host
        .write_file("/tmp/target", b"pointee")
        .expect("write target");
    s.host.symlink("/tmp/target", "/tmp/link").expect("symlink");

    let st = s.host.stat("/tmp/link").expect("stat /tmp/link");
    assert!(
        st.is_symlink && !st.is_dir,
        "lstat should report a symlink: {st:?}"
    );
    assert_eq!(
        st.size,
        "/tmp/target".len() as u64,
        "symlink size = target-text length"
    );
    assert_eq!(st.nlink, 1, "fresh symlink link count");

    let entries = s.host.readdir("/tmp").expect("readdir /tmp");
    assert!(
        entries
            .iter()
            .any(|e| e.name == "link" && e.is_symlink && !e.is_dir),
        "readdir must expose symlink kind; got {entries:?}"
    );
    assert_eq!(
        s.host.read_file("/tmp/link").expect("read through link"),
        b"pointee"
    );
}

/// WHY: the ctl read path negotiates buffer size — the kernel returns the FULL length so the host
/// grows its buffer and retries. GUARANTEES: a payload far larger than the control buffer
/// round-trips intact — the resize-and-retry handshake works, not just small reads.
#[test]
fn control_channel_large_file_roundtrips() {
    let mut s = boot();
    let big = vec![b'Z'; 256 * 1024];
    s.host.write_file("/tmp/big", &big).expect("write big");
    assert_eq!(s.host.read_file("/tmp/big").expect("read big"), big);
}

/// WHY: the exec channel (`mc_ctl_exec`) is a structured PIPE, not the terminal — it captures a
/// guest's raw stdout (pure LF), the deliberate counterpart to the console's ONLCR (CRLF, kernel
/// io.rs; see [`crate::tty`]). GUARANTEES: `exec` spawns `/bin/sh -c`, runs the guest, and returns
/// its bytes verbatim — LF, with no CR added by a terminal layer.
#[test]
fn exec_channel_captures_raw_lf_not_crlf() {
    let mut s = boot_posix();
    s.host
        .write_file("/tmp/note", b"line1\nline2\n")
        .expect("write");
    let r = s
        .host
        .exec("cat /tmp/note", 200_000, ExecOptions::default())
        .expect("exec cat");
    assert_eq!(r.exit_code, 0, "cat exit code");
    assert_eq!(
        r.stdout, b"line1\nline2\n",
        "exec pipe must stay raw LF, not CRLF: {:?}",
        r.stdout
    );
}

/// WHY: A8 — the entire VM is a portable value: `snapshot` captures linear memory, `restore`
/// rehydrates a fresh VM. GUARANTEES: state written before a snapshot is present in a VM restored
/// from it — the round-trip preserves the filesystem, with no re-boot.
#[test]
fn snapshot_then_restore_preserves_a_written_file() {
    let mut s = boot();
    s.host
        .write_file("/tmp/keep", b"survives a snapshot")
        .expect("write /tmp/keep");
    let snap = s.host.snapshot().expect("snapshot");

    let mut restored = restore(&snap);
    assert_eq!(
        restored.host.read_file("/tmp/keep").expect("read restored"),
        b"survives a snapshot"
    );
}

/// WHY: A8 forking — restoring one snapshot twice must yield two INDEPENDENT VMs, not two views of
/// one. GUARANTEES: divergent writes to the same path in each restored VM do not bleed across — the
/// restore path gives each VM its own linear memory.
#[test]
fn restoring_a_snapshot_twice_forks_independent_vms() {
    let mut s = boot();
    let snap = s.host.snapshot().expect("snapshot");

    let mut a = restore(&snap);
    let mut b = restore(&snap);
    a.host
        .write_file("/tmp/fork", b"branch-a")
        .expect("write a");
    b.host
        .write_file("/tmp/fork", b"branch-b")
        .expect("write b");

    assert_eq!(a.host.read_file("/tmp/fork").expect("read a"), b"branch-a");
    assert_eq!(b.host.read_file("/tmp/fork").expect("read b"), b"branch-b");
}
