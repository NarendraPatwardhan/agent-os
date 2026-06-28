//! Resident-service primitive proof (SYSTEMS.md): the `kv` service reached as BOTH the `kv` CLI
//! and the Luau `sys.svc` library — the SAME warm instance — plus warm-across-calls and crash-only.
//! The kernel activates `kv` at boot from `/etc/services.d/kv.json`; these tests drive it through the
//! real shell on the real kernel (B6, no mocks).

use crate::{boot_svc_test, restore};

/// The CLI face: `kv put` then `kv get`, two separate processes, hit the SAME warm service — the
/// store survives across calls because it lives in the service's linear memory.
#[test]
fn kv_cli_is_warm_across_calls() {
    let mut s = boot_svc_test();
    assert_eq!(s.run_for_output("kv put greeting hello"), "");
    assert_eq!(s.run_for_output("kv get greeting"), "hello\r\n");
    assert_eq!(s.run_for_output("kv put count 42"), "");
    assert_eq!(s.run_for_output("kv get count"), "42\r\n");
    // the first key is still there — proof the service stayed warm across calls.
    assert_eq!(s.run_for_output("kv get greeting"), "hello\r\n");
    // a missing key → no output.
    assert_eq!(s.run_for_output("kv get nope"), "");
}

/// DUAL behavior (the 1e gate): a value written through the CLI is read back through the Luau
/// `sys.svc` library, and vice versa — the CLI and the library are clients of the SAME warm service.
#[test]
fn kv_dual_cli_and_luau_same_warm_service() {
    let mut s = boot_svc_test();

    // Write through the CLI, read through Luau `sys.svc`.
    assert_eq!(s.run_for_output("kv put shared via-cli"), "");
    s.host
        .write_file(
            "/tmp/get.luau",
            br#"local fd = assert(sys.svc.connect("kv"))
local v = assert(sys.svc.call(fd, "get\0shared"))
print(v)
"#,
        )
        .expect("write get.luau");
    assert_eq!(s.run_for_output("luau /tmp/get.luau"), "via-cli\r\n");

    // Write through Luau, read through the CLI.
    s.host
        .write_file(
            "/tmp/put.luau",
            br#"local fd = assert(sys.svc.connect("kv"))
assert(sys.svc.call(fd, "put\0fromlua\0hi"))
"#,
        )
        .expect("write put.luau");
    let _ = s.run_for_output("luau /tmp/put.luau");
    assert_eq!(s.run_for_output("kv get fromlua"), "hi\r\n");
}

/// Crash-only + lazy recovery: when the warm service dies mid-call, the next call does NOT hang — the
/// kernel lazily re-activates a FRESH instance on connect. The crashed warm state is gone (warm ≠
/// durable), so the old key is absent, but the service is usable again immediately.
#[test]
fn kv_crash_recovers_a_fresh_instance() {
    let mut s = boot_svc_test();
    assert_eq!(s.run_for_output("kv put k v"), "");
    assert_eq!(s.run_for_output("kv get k"), "v\r\n");
    let _ = s.run_for_output("kv _crash"); // the warm service exits mid-call
                                           // Not a hang: a fresh instance is lazily spawned on the next connect. Its store is empty, so the
                                           // pre-crash key is gone...
    assert_eq!(s.run_for_output("kv get k"), "");
    // ...but the recovered instance serves normally — a new put/get round-trips.
    assert_eq!(s.run_for_output("kv put k2 v2"), "");
    assert_eq!(s.run_for_output("kv get k2"), "v2\r\n");
}

/// `/svc` is the resident-service registry made observable as a listing. An EAGER service (kv) is
/// activated at boot, so `ls /svc` shows it BEFORE any `kv` command runs — proof the kernel started
/// it from the manifest, not on first use.
#[test]
fn svc_lists_an_eager_service_at_boot() {
    let mut s = boot_svc_test();
    assert_eq!(s.run_for_output("ls /svc"), "kv\r\n");
}

/// pid-1 boot invariant (codex P1): in an image with an EAGER service (svc_test's kv), the LOGIN SHELL —
/// not the service — owns pid 1. Orphaned tasks reparent to pid 1, which must be init (the shell), never a
/// resident service (no parent, can't reap). Activating eager services before the shell let kv grab pid 1;
/// the shell now boots first and reserves it.
#[test]
fn the_login_shell_owns_pid_1_not_an_eager_service() {
    let mut s = boot_svc_test();
    let status = s.run_for_output("cat /proc/1/status");
    assert!(
        status.contains("Name:\tsh"),
        "pid 1 should be the shell, got: {status:?}"
    );
    assert!(
        !status.contains("kv"),
        "pid 1 must not be the eager kv service, got: {status:?}"
    );
}

/// Dead-client cleanup: a client that dies mid-session (a Luau trap while holding a `kv` connection)
/// does NOT wedge or corrupt the warm service. The connection is torn down — the fd Drop on the
/// universal clear_program, backed by the server's self-healing eviction on `svc_recv` — and the
/// service keeps serving: the pre-existing key survives and a new put/get round-trips.
#[test]
fn kv_survives_a_client_dying_mid_session() {
    let mut s = boot_svc_test();
    assert_eq!(s.run_for_output("kv put k v"), "");
    s.host
        .write_file(
            "/tmp/die.luau",
            br#"local fd = assert(sys.svc.connect("kv")); error("boom while connected")"#,
        )
        .expect("write die.luau");
    let _ = s.run_for_output("luau /tmp/die.luau"); // connects, then traps mid-session
                                                    // The warm service is unaffected — the prior key survives and it serves new calls.
    assert_eq!(s.run_for_output("kv get k"), "v\r\n");
    assert_eq!(s.run_for_output("kv put k2 v2"), "");
    assert_eq!(s.run_for_output("kv get k2"), "v2\r\n");
}

/// Oversize-request safety (#3): a request larger than the service's recv buffer is AUTO-REJECTED by
/// the kernel — the CLIENT's call fails, but the service is never stalled, starved, or killed by it, so
/// a malicious or buggy client cannot take a service down with a too-big request. Here a 4 KiB call to
/// kv (whose buffer is 1 KiB) fails, and kv keeps serving normally afterward.
#[test]
fn kv_survives_an_oversize_request() {
    let mut s = boot_svc_test();
    assert_eq!(s.run_for_output("kv put k v"), "");
    s.host
        .write_file(
            "/tmp/big.luau",
            br#"local fd = assert(sys.svc.connect("kv"))
local r = sys.svc.call(fd, string.rep("x", 4096))
print(r == nil)
"#,
        )
        .expect("write big.luau");
    // The oversize call fails (the kernel rejected it) — but kv was never killed.
    assert_eq!(s.run_for_output("luau /tmp/big.luau"), "true\r\n");
    // kv is unharmed: the prior key survives and it serves new calls.
    assert_eq!(s.run_for_output("kv get k"), "v\r\n");
    assert_eq!(s.run_for_output("kv put k2 v2"), "");
    assert_eq!(s.run_for_output("kv get k2"), "v2\r\n");
}

/// Bounded activation failure (#4/#6): a service that crashes BEFORE `svc_serve` must not make a connect
/// spin forever. The supervisor fails the connect with `EIO` and drops the service into a backoff
/// cooldown (so a connect storm can't respawn-storm it). `crashloop` is exactly that, so
/// `sys.svc.connect("crashloop")` returns nil — a clean failure, not a hang — and the kernel keeps
/// serving working services afterward.
#[test]
fn connecting_to_a_crash_looping_service_fails_not_hangs() {
    let mut s = boot_svc_test();
    s.host
        .write_file(
            "/tmp/crashloop.luau",
            br#"local fd = sys.svc.connect("crashloop")
print(fd == nil)
"#,
        )
        .expect("write crashloop.luau");
    // If the bounding regressed, this line would HANG (the old busy-poll) instead of returning nil.
    assert_eq!(s.run_for_output("luau /tmp/crashloop.luau"), "true\r\n");
    // The kernel is unharmed — kv still activates and serves after crashloop's failed activation.
    assert_eq!(s.run_for_output("kv put k v"), "");
    assert_eq!(s.run_for_output("kv get k"), "v\r\n");
}

/// Supervisor observability (#6): the activation state is visible under /svc, so a wedged service is
/// observable rather than silent. kv (eager) reads "ready" at boot; after a connect to the broken
/// crashloop fails, /svc/crashloop reads "failed: …" while kv stays "ready", and the listing shows both.
#[test]
fn svc_status_reflects_the_activation_supervisor() {
    let mut s = boot_svc_test();
    // The eager service is ready at boot; `cat /svc/<name>` reports its lifecycle state.
    assert_eq!(s.run_for_output("cat /svc/kv"), "ready\r\n");
    // Trigger crashloop's activation — it crashes before serving, so the supervisor marks it failed.
    s.host
        .write_file(
            "/tmp/c.luau",
            br#"print(sys.svc.connect("crashloop") == nil)"#,
        )
        .expect("write c.luau");
    assert_eq!(s.run_for_output("luau /tmp/c.luau"), "true\r\n");
    // crashloop is now observably FAILED (not silently gone); kv is unaffected.
    assert_eq!(
        s.run_for_output("cat /svc/crashloop"),
        "failed: crashed before serving\r\n"
    );
    assert_eq!(s.run_for_output("cat /svc/kv"), "ready\r\n");
    // The listing shows every known service — ready and failed alike (sorted).
    assert_eq!(s.run_for_output("ls /svc"), "crashloop\r\nkv\r\n");
}

/// Snapshot quiescence + warm survival (#5; SYSTEMS.md): the in-flight-svc-call counter folds
/// into the snapshot gate, so a snapshot is never taken while a service is mid-call. After a COMPLETED
/// call the counter is back to zero — so the snapshot proceeds (a leaked counter would hang it forever)
/// — and the service's WARM heap state rides the snapshot: a value put into kv before the snapshot is
/// still served by the instance in a VM restored from it.
#[test]
fn a_warm_service_survives_snapshot_and_restore() {
    let mut s = boot_svc_test();
    assert_eq!(s.run_for_output("kv put persisted yes"), ""); // a completed call: inflight 1 → 0
    let snap = s.host.snapshot().expect("snapshot"); // succeeds — quiescent, no service mid-call
    let mut restored = restore(&snap);
    // The warm kv store (linear-memory heap) rode the snapshot — the key is present in the fresh VM.
    assert_eq!(restored.run_for_output("kv get persisted"), "yes\r\n");
}

/// Streaming crash-only (codex audit): a service that sends a PARTIAL chunk (`last=0`) then dies before
/// the final chunk must NOT leave the client polling forever. Once the server's channel closes, the
/// kernel surfaces `EIO` on the still-incomplete response. kv's `_stream_crash` does exactly that, so the
/// call fails cleanly (nil) instead of hanging — and kv recovers a fresh instance on the next connect.
#[test]
fn a_streaming_service_crash_fails_the_call_not_hangs() {
    let mut s = boot_svc_test();
    s.host
        .write_file(
            "/tmp/streamcrash.luau",
            br#"local fd = assert(sys.svc.connect("kv"))
print(sys.svc.call(fd, "_stream_crash") == nil)
"#,
        )
        .expect("write streamcrash.luau");
    // Without the fix this HANGS (Pending forever on the undrained-but-incomplete buffer).
    assert_eq!(s.run_for_output("luau /tmp/streamcrash.luau"), "true\r\n");
    // kv recovers — a fresh instance serves the next connect (crash-only, warm ≠ durable).
    assert_eq!(s.run_for_output("kv put k v"), "");
    assert_eq!(s.run_for_output("kv get k"), "v\r\n");
}

/// Service-zombie reaping (codex P2): a resident service has no parent, so nothing waitpids its zombie
/// when it crashes — left alone, every crash/retry leaks a parentless task into the scheduler and /proc.
/// The supervisor now reaps a service's dead instances when it re-activates, so repeated crash/recover
/// cycles do NOT accumulate kv zombies in /proc.
#[test]
fn crashed_service_instances_are_reaped_not_leaked() {
    let mut s = boot_svc_test();
    // Several crash → lazy-recover cycles. Without reaping, each leaves a parentless kv zombie behind.
    for _ in 0..6 {
        let _ = s.run_for_output("kv _crash"); // the warm kv dies mid-call
        assert_eq!(s.run_for_output("kv put k v"), ""); // re-activates a fresh instance (+ reaps the dead one)
    }
    // /proc lists every task incl. zombies; count only the numeric pid entries (skip uptime/mounts).
    let proc = s.run_for_output("ls /proc");
    let pids = proc
        .lines()
        .filter(|l| !l.is_empty() && l.bytes().all(|b| b.is_ascii_digit()))
        .count();
    // With reaping only a few live tasks remain (shell, the current kv, the listing) — NOT 6 leaked
    // zombies. Without the fix this would be ≥ 6 higher.
    assert!(
        pids <= 4,
        "leaked service zombies: /proc lists {pids} pids:\n{proc}"
    );
}
