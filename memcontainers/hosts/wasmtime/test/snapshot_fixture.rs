//! Cross-host snapshot fixture (A3/A8). Boots `kernel.wasm` under the WASMTIME host, writes a marker
//! through the control channel, snapshots the booted VM, and emits the bytes. A genrule runs this over
//! the SAME kernel + base the e2e boots (B1), and the JS host's `cross_host_test` rehydrates the result.
//! If the `MCSN` snapshot format or the linear-memory image were not truly host-identical, that restore
//! would fail or lose state — so this fixture turns the "a snapshot taken under one host restores under
//! the other" claim into an executable proof instead of a by-construction assertion.
//!
//! argv: `<kernel.wasm> <base.tar> <out.bin>`.

use host::{CaptureSink, KernelHostBuilder};

/// The marker the JS restore test checks for — change it in both places or the proof is hollow.
const MARKER: &[u8] = b"rust-host snapshot -> js-host restore";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let kernel = std::fs::read(&args[1]).unwrap_or_else(|e| panic!("read kernel {}: {e}", args[1]));
    let base = std::fs::read(&args[2]).unwrap_or_else(|e| panic!("read base {}: {e}", args[2]));
    let out = &args[3];

    // Deterministic (fixed clock + seeded RNG), exactly as the e2e and the JS parity test boot.
    let (sink, _stdout) = CaptureSink::new();
    let mut host = KernelHostBuilder::new(kernel)
        .with_base_image(Some(base))
        .with_stdout(Box::new(sink))
        .deterministic()
        .build()
        .expect("boot kernel.wasm under the wasmtime host");

    host.write_file("/tmp/xhost", MARKER)
        .expect("write the cross-host marker through the control channel");
    let snap = host.snapshot().expect("snapshot the booted VM");

    std::fs::write(out, &snap).unwrap_or_else(|e| panic!("write snapshot {out}: {e}"));
    eprintln!("cross-host snapshot: {} bytes produced by the wasmtime host", snap.len());
}
