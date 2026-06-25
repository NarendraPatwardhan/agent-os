//! `typst` — the Typst document compiler as an agent-os resident SERVICE (SERVICES.md). One std binary,
//! two modes (the kv/sqlite pattern): the kernel activates it with the service marker as argv[1] and it
//! runs a warm `svc_serve` loop that loads ~30 MB of fonts ONCE and compiles `.typ` → PDF for every
//! caller; run from the shell it is a thin `svc_connect`/`svc_call` CLIENT. The Luau library
//! (`require("typst")`) is the third face over the same warm engine.
//!
//! typst is `std` on wasm32-wasi: `std::fs`/clock ride the //wasi-adapter to `mc_sys_*`, while the
//! `svc_*` serve syscalls come from //sysroot/rust (whose no_std panic handler is off on wasi, so std's
//! is used). `panic = abort` (the release_wasm profile) makes a panicking compile abort the guest — the
//! crash-only recovery a service wants (SERVICES.md §2).

mod cli;
mod proto;
mod serve;
mod world;

use sysroot as rt;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    // argv[0] is the program path; SERVICE mode is signalled by argv[1] == the service marker (the
    // kernel's activation contract, same as kv/sqlite). Otherwise this is a CLI invocation.
    if args.get(1).map(String::as_str) == Some(rt::SERVICE_MARKER) {
        serve::run();
    }
    cli::run(&args[1..]);
}
