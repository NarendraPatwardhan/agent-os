// Cross-host parity (A3/A8): a snapshot taken under the WASMTIME host — the
// //memcontainers/hosts/wasmtime:cross_host_snapshot fixture booted base.tar, wrote a marker through
// the control channel, and snapshotted — is rehydrated HERE under the JS host. If the MCSN format or
// the kernel's linear-memory image weren't truly host-identical, the restore would trap or the saved
// state would be lost. So this is the executable proof that "the SAME kernel.wasm, snapshotted under
// one host family, restores under the other" — A3/A8 enforced across hosts, not by construction.
//
// The kernel + the foreign snapshot arrive as bazel runfiles (data-deps), exactly like the Rust e2e.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { KernelHostBuilder } from "../src/index.js";
import type { StreamSink } from "../src/index.js";

/** The marker the wasmtime fixture writes before snapshotting — keep in lockstep with snapshot_fixture.rs. */
const MARKER = "rust-host snapshot -> js-host restore";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

async function main(): Promise<void> {
  const wasm = new Uint8Array(readFileSync(runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM")));
  const snapshot = new Uint8Array(
    readFileSync(runfile(process.env.MC_CROSS_SNAPSHOT, "MC_CROSS_SNAPSHOT")),
  );
  const incrementalBundle = new Uint8Array(
    readFileSync(runfile(process.env.MC_CROSS_INCREMENTAL, "MC_CROSS_INCREMENTAL")),
  );
  const baseLen = new DataView(incrementalBundle.buffer, incrementalBundle.byteOffset).getUint32(
    0,
    true,
  );
  const incrementalBase = incrementalBundle.subarray(4, 4 + baseLen);
  const incremental = incrementalBundle.subarray(4 + baseLen);

  const discard: StreamSink = { write() {} };

  // Rehydrate the WASMTIME-produced snapshot under THIS (JS) host — fresh capabilities/sinks, no boot.
  const host = await new KernelHostBuilder(wasm)
    .deterministic()
    .withStdout(discard)
    .withStderr(discard)
    .withLog(discard)
    .restore(snapshot);

  // 1) The marker the wasmtime host wrote before snapshotting must survive the cross-host restore.
  const marker = new TextDecoder().decode(host.readFile("/tmp/xhost"));
  if (marker !== MARKER) {
    throw new Error(`cross-host snapshot lost state: /tmp/xhost = ${JSON.stringify(marker)}`);
  }

  // 2) The rehydrated VM is live under the JS host — a real exec runs to completion.
  const echo = await host.exec("echo cross-host-ok");
  if (echo.exitCode !== 0 || new TextDecoder().decode(echo.stdout).trim() !== "cross-host-ok") {
    throw new Error(`restored VM is not live: exit=${echo.exitCode}`);
  }

  const thin = await new KernelHostBuilder(wasm)
    .deterministic()
    .withStdout(discard)
    .withStderr(discard)
    .withLog(discard)
    .restore(incremental, incrementalBase);
  if (new TextDecoder().decode(thin.readFile("/tmp/xhost")) !== MARKER) {
    throw new Error("Rust incremental snapshot did not restore under the JS host");
  }

  console.log("CROSS-HOST OK — wasmtime full + incremental snapshots restored under the JS host.");
}

main().catch((e) => {
  console.error("CROSS-HOST FAIL:", e instanceof Error ? e.message : e);
  process.exit(1);
});
