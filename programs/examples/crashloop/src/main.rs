//! `crashloop` — a deliberately-broken resident service for the e2e. In SERVICE mode it CRASHES BEFORE
//! `svc_serve`, every activation, to exercise the kernel's BOUNDED activation-failure path (codex #4):
//! a `svc_connect` to it re-activates it a few times, then fails with `EIO` rather than busy-polling
//! forever (the failure mode k8s calls CrashLoopBackOff). As a CLI it does nothing. Not shipped in a
//! real flavor — only the kv-test image carries it, as a negative control alongside the working `kv`.

#![no_std]
#![no_main]

use sysroot as rt;

rt::entry!(main); // tier (isolated) + service ("crashloop") are declared in the BUILD (mc_rust_program)

/// The kernel passes this as `argv[1]` when it spawns a binary in SERVICE mode (matches the kernel's
/// `SERVICE_MARKER`).
const SERVICE_MARKER: &[u8] = b"--mc-serve";

fn main() {
    let mut argbuf = [0u8; 256];
    let n = rt::args_into(&mut argbuf);
    let mut parts = argbuf[..n].split(|&b| b == 0);
    let _arg0 = parts.next();
    let arg1 = parts.next().unwrap_or(b"");
    if arg1 == SERVICE_MARKER {
        // …but crashes before ever reaching `svc_serve`. The kernel bounds the retries and fails the
        // connecting client with EIO instead of spinning forever (codex #4).
        rt::exit(1);
    }
    rt::exit(0);
}
