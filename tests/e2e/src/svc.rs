//! Resident-service primitive proof (SERVICES.md P1): the `kv` service reached as BOTH the `kv` CLI
//! and the Luau `sys.svc` library — the SAME warm instance — plus warm-across-calls and crash-only.
//! The kernel activates `kv` at boot from `/etc/services.json`; these tests drive it through the
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

/// Bounded activation failure (#4): a service that crashes BEFORE `svc_serve`, every time, must not
/// make a connect spin forever. The kernel re-activates it a bounded number of times, then fails the
/// connect with `EIO`. `crashloop` is exactly that, so `sys.svc.connect("crashloop")` returns nil — a
/// clean failure, not a hang — and the kernel keeps serving working services afterward.
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

/// Snapshot quiescence + warm survival (#5; SERVICES.md §3.5): the in-flight-svc-call counter folds
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
