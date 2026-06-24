//! System programs — the non-coreutils binaries that aren't part of the mcbox multicall: `invoke`
//! (the host-tool bridge over `mc_host_call`) and, as it lands, `pkgfsd` (the `/pkg` serve daemon).
//! These exercise the host_call + serve machinery, not just a tool's output.

use std::path::PathBuf;

use host::MapHostCall;

use crate::{boot_posix, boot_posix_with_persist, boot_posix_with_tools};

/// WHY: `invoke` is the guest→host tool bridge — it packs `name\0args`, fires `mc_host_call`, and
/// streams the host handler's result. GUARANTEES: with a tool registered on the host (MapHostCall),
/// `invoke <tool> <args>` reaches the handler WITH the args and streams its result to the terminal
/// (ONLCR → CRLF). Proves the whole path: guest → kernel host_call.rs → the host bridge → the
/// registered handler → back.
#[test]
fn invoke_calls_a_registered_host_tool() {
    let mut tools = MapHostCall::new();
    tools.register("greet", Box::new(|args: &str| Ok(format!("hello {args}\n").into_bytes())));
    let mut s = boot_posix_with_tools(tools);
    assert_eq!(s.run_for_output("invoke greet world"), "hello world\r\n");
}

/// WHY: default-deny (A9) — an unregistered tool must be REFUSED, not silently succeed. GUARANTEES:
/// `invoke` produces no stdout for an unknown tool (the "host tools unavailable" error goes to
/// stderr, exit 1) — the host opts in per tool, nothing leaks through.
#[test]
fn invoke_refuses_an_unregistered_tool() {
    let tools = MapHostCall::new(); // empty registry → every call refused
    let mut s = boot_posix_with_tools(tools);
    assert_eq!(s.run_for_output("invoke nope {}"), "", "an unregistered tool must produce no stdout");
}

/// WHY: the ergonomic flags form must assemble a CORRECT JSON args object (now via //lib/json:serde,
/// not a hand-rolled writer) — type-inferred values, integer-clean numbers, insertion order, and a
/// space-joined multi-word name. GUARANTEES: `--flag value` / `--flag=value` / a bare `--flag` become
/// string / number / bool fields in order; the name is the pre-flag tokens joined by space. The
/// handler echoes the exact blob it received, so this asserts the byte-exact JSON invoke built.
#[test]
fn invoke_flags_form_builds_json_args() {
    let mut tools = MapHostCall::new();
    tools.register("api call", Box::new(|args: &str| Ok(format!("{args}\n").into_bytes())));
    let mut s = boot_posix_with_tools(tools);
    let out = s.run_for_output("invoke api call --city London --count 3 --live --ratio=0.5");
    assert_eq!(out, "{\"city\":\"London\",\"count\":3,\"live\":true,\"ratio\":0.5}\r\n");
}

/// WHY: `pkgfsd` is the demand-load file server for /pkg (§7.1) — a daemon that `serve("/pkg")`s,
/// then spawns its consumer in that namespace. GUARANTEES: given a baked catalog, `pkgfsd ls
/// /pkg/bin` spawns `ls` in pkgfsd's namespace, ls reads the SERVED readdir, and the catalog's tools
/// appear — proving the serve protocol (servedfs) + the spawn-into-namespace model end to end
/// (pkgfsd exits when the consumer closes the channel). The NAME is cheap + offline; no fetch here.
#[test]
fn pkgfsd_serves_the_catalog_over_pkg() {
    let mut s = boot_posix();
    s.host.mkdir("/etc/pkg").ok(); // the catalog dir (CoW overlay over the image)
    s.host
        .write_file("/etc/pkg/catalog", b"alpha\tdeadbeef\t10\talpha.wasm\nbeta\tcafef00d\t20\tbeta.wasm\n")
        .expect("write catalog");
    // pkgfsd is a daemon (it serves forever, never returns the prompt), so drive a fixed budget and
    // capture what the spawned `ls` consumer emits.
    let out = s.send_line_async("pkgfsd ls /pkg/bin", 50_000);
    assert!(
        out.contains("alpha") && out.contains("beta"),
        "pkgfsd should serve the catalog at /pkg/bin; got {out:?}"
    );
}

/// WHY: the demand-load READ path (§7.1) — a tool's BYTES are fetched only on open; a cache hit is
/// served from `/var/persist/pkg/<sha>` after a sha256 RE-verify (which defends a corrupted/
/// truncated cache). GUARANTEES: given a catalog row and a matching cached blob, `pkgfsd cat
/// /pkg/bin/<name>` serves the REAL bytes through the serve channel — the demand-load, sha-verified,
/// end to end. (This is the cache-hit branch; the cold-start fetch over /net is netfs's layer and
/// needs a registry, so it is exercised separately.)
#[test]
fn pkgfsd_serves_a_cached_package_on_read() {
    let payload = b"demo package payload\n";
    let sha = pkgcore::sha256_hex(payload); // the content-addressed digest, as the catalog records it
    let dir = PathBuf::from(std::env::var("TEST_TMPDIR").expect("TEST_TMPDIR set by bazel")).join("pkgfsd-cache");
    let mut s = boot_posix_with_persist(dir);

    s.host.mkdir("/etc/pkg").ok();
    let catalog = format!("demo\t{sha}\t{}\tdemo.wasm\n", payload.len());
    s.host.write_file("/etc/pkg/catalog", catalog.as_bytes()).expect("write catalog");
    s.host.mkdir("/var/persist/pkg").ok();
    s.host.write_file(&format!("/var/persist/pkg/{sha}"), payload).expect("seed the cache");

    // pkgfsd serves /pkg + spawns `cat /pkg/bin/demo`; cat reads the SERVED file — pkgfsd resolves
    // it to the cache hit, re-verifies the sha, and streams the bytes back.
    let out = s.send_line_async("pkgfsd cat /pkg/bin/demo", 50_000);
    assert!(out.contains("demo package payload"), "pkgfsd should serve the cached package; got {out:?}");
}
