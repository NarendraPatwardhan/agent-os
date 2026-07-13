//! Kernel — the structured control channel (the generated `ctl` exports) and snapshot/restore.
//! This is the host's out-of-band, programmatic surface: a PIPE (pure LF), distinct from the
//! interactive terminal's ONLCR (CRLF — see [`crate::tty`], SYSTEMS.md section 6). No guest programs needed except the
//! one exec test, which proves the pipe stays raw.

use crate::{boot, boot_loom, boot_posix, names, restore, restore_incremental, Session};
use host::ExecOptions;

/// A tiny valid guest with one exported memory, a no-op `_start`, and one byte of non-custom data.
/// Varying `tag` changes compilation identity without changing behavior.
fn tiny_guest(tag: u8) -> Vec<u8> {
    vec![
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // wasm header
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x03, 0x02, 0x01, 0x00, // one function of type 0
        0x05, 0x03, 0x01, 0x00, 0x01, // one one-page memory
        0x07, 0x13, 0x02, // two exports
        0x06, b'm', b'e', b'm', b'o', b'r', b'y', 0x02, 0x00, // memory
        0x06, b'_', b's', b't', b'a', b'r', b't', 0x00, 0x00, // _start
        0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b, // no-op body
        0x0b, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, tag, // active data segment
    ]
}

fn semantically_invalid_guest(tag: u8) -> Vec<u8> {
    let mut wasm = tiny_guest(tag);
    let code = wasm
        .windows(6)
        .position(|window| window == [0x0a, 0x04, 0x01, 0x02, 0x00, 0x0b])
        .expect("tiny guest code section");
    wasm[code + 5] = 0xff; // no function-ending `end` opcode
    wasm
}

fn append_custom(mut wasm: Vec<u8>, name: &[u8], payload: &[u8]) -> Vec<u8> {
    fn push_uleb(out: &mut Vec<u8>, mut value: usize) {
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            out.push(byte);
            if value == 0 {
                break;
            }
        }
    }

    wasm.push(0);
    push_uleb(&mut wasm, name.len() + payload.len() + 1);
    push_uleb(&mut wasm, name.len());
    wasm.extend_from_slice(name);
    wasm.extend_from_slice(payload);
    wasm
}

fn run_guest(session: &mut Session, bytes: &[u8]) -> String {
    session
        .host
        .write_file("/tmp/admission-test.wasm", bytes)
        .expect("write admission test guest");
    session
        .host
        .chmod("/tmp/admission-test.wasm", 0o755)
        .expect("chmod admission test guest");
    // The rescue shell writes exec diagnostics to stderr, while this harness captures its terminal
    // stdout. Echo the status through stdout so the assertion observes the real exec result.
    session.run_for_output("/tmp/admission-test.wasm; echo status=$?")
}

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

/// WHY: malformed policy metadata, invalid Wasm, and irrelevant custom sections used to reach the
/// permanent wasmi arena before rejection or receive distinct FNV cache keys. GUARANTEES: 65 distinct
/// examples of each invalid class consume no admission, while 65 custom-only variants of one valid
/// executable all reuse one compilation identity and remain runnable beyond the 64-module ceiling.
#[test]
fn compilation_admission_validates_metadata_and_ignores_custom_sections() {
    let mut s = boot();
    s.drive_until_prompt(0);

    for tag in 0..=64u8 {
        let malformed = append_custom(tiny_guest(tag), b"mc_budget", &[tag]);
        let output = run_guest(&mut s, &malformed);
        assert_ne!(
            output, "status=0\r\n",
            "malformed metadata variant {tag} was admitted: {output:?}",
        );
    }

    for tag in 0..=64u8 {
        let output = run_guest(&mut s, &semantically_invalid_guest(tag));
        assert_ne!(
            output, "status=0\r\n",
            "semantically invalid module {tag} was admitted: {output:?}",
        );
    }

    for tag in 0..=64u8 {
        let same_program = append_custom(tiny_guest(0), b"note", &[tag]);
        let output = run_guest(&mut s, &same_program);
        assert_eq!(
            output, "status=0\r\n",
            "custom-only variant {tag} should reuse one compiled module: {output:?}",
        );
    }
}

/// WHY: wasmi's arena and the registry live together in kernel linear memory, so A8 snapshots must
/// preserve consumed compilation capacity exactly. GUARANTEES: the boot-time `/bin/sh` admission,
/// 32 admissions before a snapshot, and 31 after restore fill the 64-module ceiling; the next identity
/// fails, while an identity compiled before the snapshot remains runnable from cache after exhaustion.
#[test]
fn compilation_budget_and_cache_survive_snapshot_restore() {
    let mut s = boot();
    s.drive_until_prompt(0);
    for tag in 0..32u8 {
        assert_eq!(run_guest(&mut s, &tiny_guest(tag)), "status=0\r\n");
    }

    let snapshot = s.host.snapshot().expect("snapshot compilation registry");
    let mut restored = restore(&snapshot);
    for tag in 32..63u8 {
        assert_eq!(run_guest(&mut restored, &tiny_guest(tag)), "status=0\r\n");
    }

    let rejected = run_guest(&mut restored, &tiny_guest(63));
    assert_ne!(
        rejected, "status=0\r\n",
        "65th compilation identity should fail at the VM-wide ceiling: {rejected:?}",
    );
    assert_eq!(
        run_guest(&mut restored, &tiny_guest(0)),
        "status=0\r\n",
        "cache hits must remain runnable after admission is exhausted",
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

/// WHY: an incremental A8 value excludes every unchanged base page but must reconstruct the same
/// runnable VM as a full snapshot. GUARANTEES: the delta is smaller than its full baseline for a
/// small mutation, preserves both baseline and post-baseline state, and restores without booting.
#[test]
fn incremental_snapshot_restores_against_one_full_baseline() {
    let mut s = boot();
    s.host
        .write_file("/tmp/base", b"baseline")
        .expect("write baseline");
    let base = s.host.snapshot().expect("full baseline");
    s.host
        .write_file("/tmp/delta", b"incremental")
        .expect("write delta");
    let delta = s
        .host
        .snapshot_incremental(&base)
        .expect("incremental snapshot");
    assert!(
        delta.len() < base.len(),
        "small mutation should produce a thin snapshot"
    );

    let mut restored = restore_incremental(&delta, &base);
    assert_eq!(restored.host.read_file("/tmp/base").unwrap(), b"baseline");
    assert_eq!(
        restored.host.read_file("/tmp/delta").unwrap(),
        b"incremental"
    );
}

/// WHY: Group G / A8 under Asyncify (ZIG_KERNEL section 7.4) — the DEEPEST snapshot guarantee. The two
/// snapshot tests above quiesce first; this one snapshots a guest that is provably STILL RUNNING —
/// suspended mid-computation on an Asyncify fuel-yield, its native wasm call stack spilled into linear
/// memory. A VM restored from that snapshot must RESUME the same computation to the identical result,
/// proving the Asyncify buffer is snapshottable by construction, not just the filesystem.
#[test]
fn snapshot_while_a_guest_is_suspended_resumes_identically() {
    // A heavy, deterministic loop that spans many fuel slices and prints a clean integer only at the
    // END — so no output exists before completion, and the whole result appears only on resume in the
    // restored VM.
    let mut s = boot_loom();
    s.drive_until_prompt(0);

    s.send_raw(b"luau -e 'local n=0 for i=1,4000000 do n=n+1 end print(n)'\n");

    // Drive only a FEW ticks — far fewer than the loop needs — so the guest is suspended mid-loop.
    // Each tick must report more work pending; a loop that finished this fast would not prove a
    // mid-flight snapshot, so fail loudly (raise the iteration count) rather than degrade silently.
    for _ in 0..5 {
        assert!(
            s.host.tick().expect("tick"),
            "the heavy guest finished before we could snapshot it mid-suspend — raise the loop count"
        );
    }
    assert!(
        !s.transcript().ends_with("$ "),
        "expected the guest still mid-computation, but the prompt already returned:\n{}",
        s.transcript()
    );

    // Snapshot WHILE the guest is Asyncify-suspended, then rehydrate a fresh VM from the blob.
    let snap = s
        .host
        .snapshot()
        .expect("snapshot while a guest is suspended");
    let mut restored = restore(&snap);

    // The restored VM must RESUME the suspended loop and finish it — the result appears only now.
    restored.drive_until_prompt(0);
    let resumed = restored.transcript();
    assert!(
        resumed.contains("4000000"),
        "restored VM did not resume the suspended computation to its result; got:\n{resumed}"
    );
}
