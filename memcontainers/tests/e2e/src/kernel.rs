//! Kernel — the structured control channel (the generated `ctl` exports) and snapshot/restore.
//! This is the host's out-of-band, programmatic surface: a PIPE (pure LF), distinct from the
//! interactive terminal's ONLCR (CRLF — see [`crate::tty`], SYSTEMS.md section 6). No guest programs needed except the
//! one exec test, which proves the pipe stays raw.

use crate::{boot, boot_loom, boot_posix, names, restore};
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

/// WHY: Group G / A8 — the DEEPEST snapshot guarantee, for a FUEL-yield suspend. The two snapshot
/// tests above quiesce first; this one snapshots a guest that is provably STILL RUNNING — suspended
/// mid-computation on a fuel-slice yield, its entire execution state (the WAMR exec_env: the in-memory
/// frame chain + operand stack) resident in linear memory. A VM restored from that snapshot must
/// RESUME the same computation to the identical result, proving the interpreter's suspended state is
/// snapshottable by construction, not just the filesystem. (The kernel runs on WAMR, whose re-entrant
/// interpreter keeps this state in linear memory — no Binaryen/Asyncify buffer is involved.)
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
    let snap = s.host.snapshot().expect("snapshot while a guest is suspended");
    let mut restored = restore(&snap);

    // The restored VM must RESUME the suspended loop and finish it — the result appears only now.
    restored.drive_until_prompt(0);
    let resumed = restored.transcript();
    assert!(
        resumed.contains("4000000"),
        "restored VM did not resume the suspended computation to its result; got:\n{resumed}"
    );
}

/// WHY: Group G / A8, the OTHER suspend kind — a guest parked at a BLOCKING SYSCALL (not a fuel
/// yield). `cat` with no args reads stdin in a loop; with an empty console pipe it suspends inside the
/// read syscall (the driver's `.syscall_blocked`), the pending syscall + the WAMR exec_env both in
/// linear memory. Snapshotting there and restoring a fresh VM must resume the blocked read: feeding
/// input to the RESTORED VM unblocks the resumed `cat`, which echoes it. This exercises the second
/// resumable boundary the fuel-yield test above does not — together they cover both suspend kinds
/// against snapshot/restore.
#[test]
fn snapshot_while_a_guest_is_blocked_on_a_syscall_resumes_identically() {
    let mut s = boot_posix();
    s.drive_until_prompt(0);

    // Start `cat` (no args): it reads stdin and echoes each line. With stdin now empty it blocks in
    // the read syscall — no prompt returns while it is the foreground reader.
    s.send_raw(b"cat\n");
    for _ in 0..5 {
        assert!(
            s.host.tick().expect("tick"),
            "cat exited before we could snapshot it blocked on stdin — it should be waiting for input"
        );
    }
    assert!(
        !s.transcript().ends_with("$ "),
        "expected cat still blocked on the stdin read, but the prompt already returned:\n{}",
        s.transcript()
    );

    // Snapshot WHILE cat is suspended inside the blocking read, then rehydrate a fresh VM.
    let snap = s.host.snapshot().expect("snapshot while a guest is blocked on a syscall");
    let mut restored = restore(&snap);

    // Feed a line to the RESTORED VM and drive a fixed budget of ticks (the resumed cat need not exit
    // — we are not waiting for a prompt). If the blocked read resumed, the fed line appears TWICE: the
    // cooked line-discipline echoes the typed bytes, and the resumed `cat` reads them and echoes them
    // to stdout. A cat that failed to resume would show only the line-discipline copy — so >= 2 copies
    // is the proof the syscall-blocked guest resumed across the restore.
    let out = restored.send_line_async("resumed-line", 40);
    let copies = out.matches("resumed-line").count();
    assert!(
        copies >= 2,
        "restored VM did not resume the stdin-blocked cat (saw {copies} copies of the fed line; \
         expected the line-discipline echo plus cat's own echo):\n{out}"
    );
}

/// Interpreter-throughput microbenchmark: a tight 10M-iteration arithmetic loop — pure interpreter
/// dispatch, no spawn/syscall/IO. See PERFORMANCE.md. #[ignore]d so it never taxes the fast suite; run
/// against both `core` (Rust/wasmi) and `core_zig` (Zig/WAMR) to compare raw dispatch (they are at
/// parity: WAMR -O3 ~3.0s vs wasmi ~2.9s). NOTE: this loop is the BEST case for WAMR — the realistic
/// workload benchmarks below (spawn/pipeline/scripting) show where the two diverge.
#[test]
#[ignore = "manual perf benchmark — see PERFORMANCE.md; run with --test_arg=--ignored"]
fn zz_bench_luau_loop() {
    let mut s = boot_loom();
    s.drive_until_prompt(0);
    let t = std::time::Instant::now();
    let out = s.run_for_output_heavy("luau -e 'local n=0 for i=1,10000000 do n=n+1 end print(n)'");
    let dt = t.elapsed();
    assert!(out.contains("10000000"), "got: {out}");
    println!("BENCH luau 10M-iter loop: {} ms", dt.as_millis());
}

// ── Realistic-workload benchmarks ────────────────────────────────────────────────────────────────
// Normal agent workloads — cold boot, per-command spawn, coreutils pipelines, and real scripting —
// NOT the tight-loop microbenchmark above. Each runs on BOTH `core` (Rust/wasmi) and `core_zig`
// (Zig/WAMR), so a side-by-side run quantifies the end-to-end gap where it actually matters. All are
// #[ignore]d. Run: bazel test //memcontainers/tests/e2e:{core,core_zig} \
//   --test_arg=zz_bench --test_arg=--ignored --test_arg=--nocapture --cache_test_results=no

/// Cold-boot latency: construct a fresh VM and drive its shell to the first prompt, N times — the
/// kernel-init + pid-1-shell load/instantiate cost the user waits on before typing anything.
#[test]
#[ignore = "manual perf benchmark — run with --test_arg=--ignored"]
fn zz_bench_boot_to_prompt() {
    const N: usize = 20;
    let t = std::time::Instant::now();
    for _ in 0..N {
        let mut s = boot_posix();
        s.drive_until_prompt(0);
    }
    let dt = t.elapsed();
    println!(
        "BENCH boot-to-prompt: {N} boots in {} ms ({:.1} ms/boot)",
        dt.as_millis(),
        dt.as_secs_f64() * 1000.0 / N as f64
    );
}

/// Per-command spawn cost: from ONE booted VM, run a trivial command N times through the control
/// channel. The module is preprocessed once (content-addressed cache), so this isolates
/// instantiate + run + teardown per `sh -c` — the dominant cost of an agent running many commands.
#[test]
#[ignore = "manual perf benchmark — run with --test_arg=--ignored"]
fn zz_bench_spawn_churn() {
    let mut s = boot_posix();
    s.drive_until_prompt(0);
    const N: usize = 300;
    let t = std::time::Instant::now();
    for _ in 0..N {
        let r = s
            .host
            .exec("true", 200_000, ExecOptions::default())
            .expect("exec true");
        assert_eq!(r.exit_code, 0, "true exit code");
    }
    let dt = t.elapsed();
    println!(
        "BENCH spawn-churn: {N} runs of `true` in {} ms ({:.2} ms/spawn)",
        dt.as_millis(),
        dt.as_secs_f64() * 1000.0 / N as f64
    );
    // Per-phase attribution (populated only when the kernel is built with instrument.enabled = true).
    print!("{}", s.host.instr_report());
}

/// A realistic multi-stage coreutils pipeline (several guests spawned, pipes wired, real read/write
/// syscalls) run N times — the shape of a lot of agent shell work.
#[test]
#[ignore = "manual perf benchmark — run with --test_arg=--ignored"]
fn zz_bench_coreutils_pipeline() {
    let mut s = boot_posix();
    s.drive_until_prompt(0);
    const N: usize = 100;
    let t = std::time::Instant::now();
    for _ in 0..N {
        let r = s
            .host
            .exec("seq 1 500 | grep 7 | sort | wc -l", 2_000_000, ExecOptions::default())
            .expect("exec pipeline");
        assert_eq!(r.exit_code, 0, "pipeline exit code; stderr: {:?}", r.stderr);
    }
    let dt = t.elapsed();
    println!(
        "BENCH coreutils-pipeline: {N} runs of `seq|grep|sort|wc` in {} ms ({:.2} ms/run)",
        dt.as_millis(),
        dt.as_secs_f64() * 1000.0 / N as f64
    );
}

/// Realistic scripting: build, sort, and join a table of 20k formatted strings — interpreter work
/// over strings/tables/stdlib, not a tight arithmetic loop, closer to how agents actually script.
#[test]
#[ignore = "manual perf benchmark — run with --test_arg=--ignored"]
fn zz_bench_luau_workload() {
    let mut s = boot_loom();
    s.drive_until_prompt(0);
    let script = "luau -e 'local t={} for i=1,20000 do t[i]=string.format(\"row-%d-%d\",i,i*7) end table.sort(t) print(#table.concat(t,\",\"))'";
    let t = std::time::Instant::now();
    let out = s.run_for_output_heavy(script);
    let dt = t.elapsed();
    assert!(
        out.trim().parse::<usize>().is_ok(),
        "luau workload produced no length; got: {out:?}"
    );
    println!("BENCH luau-workload (20k rows build+sort+concat): {} ms", dt.as_millis());
}
