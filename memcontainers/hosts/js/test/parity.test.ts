// A3/A8 parity: boot the SAME kernel.wasm the wasmtime e2e boots, plus the minimal image
// (so /bin/echo, /bin/true, and /bin/printf exist as applets), but under THIS (JS) host,
// and assert a real boot-to-prompt + a real exec + a control-channel fs round-trip + a snapshot/restore
// round-trip. If the JS host's `env` bridge, `mc_ctl_*` protocol, or MCSN snapshot format had diverged
// from what the kernel expects, the boot would trap or the state would not survive — so this is the
// EXECUTABLE proof of the two-host invariant, not a comment. The kernel + image arrive as bazel
// runfiles (data-deps), exactly like the Rust e2e.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { KernelHostBuilder, TickState } from "../src/index.js";
import type { ExecResult, StreamSink } from "../src/index.js";

/** Resolve a bazel runfile: `$(rlocationpath)` yields a runfiles-relative path; RUNFILES_DIR roots it. */
function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

async function main(): Promise<void> {
  const wasm = new Uint8Array(readFileSync(runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM")));
  const base = new Uint8Array(readFileSync(runfile(process.env.MC_BASE_IMAGE, "MC_BASE_IMAGE")));

  // exec()/readFile() return their own captures, so the boot banner can be discarded.
  const discard: StreamSink = { write() {} };

  const host = await new KernelHostBuilder(wasm)
    .withBaseImage(base)
    .deterministic() // fixed clock + seeded rng — the same determinism the wasmtime e2e boots with
    .withStdout(discard)
    .withStderr(discard)
    .withLog(discard)
    .build();

  const bootTicks = host.bootToPrompt();
  if (!host.atPrompt()) {
    throw new Error(
      `kernel did not reach a shell prompt within the boot budget (${bootTicks} ticks)`,
    );
  }

  // The generated tick state is the same scheduling fact the Rust host consumes: an idle login
  // shell waits. `true` is a `/bin` applet and may complete inside one bounded slice, so completion
  // is polled immediately rather than requiring a synthetic intermediate runnable state.
  let idleState = TickState.Runnable;
  for (let i = 0; i < 8 && idleState !== TickState.Waiting; i++) idleState = host.tick();
  if (idleState !== TickState.Waiting) {
    throw new Error(`idle shell did not settle to waiting: ${idleState}`);
  }
  const tickJob = host.execStart("true");
  let tickResult: ExecResult | null = null;
  for (let i = 0; i < 32 && !tickResult; i++) {
    host.tick();
    tickResult = host.execPoll(tickJob);
  }
  if (tickResult?.exitCode !== 0) {
    throw new Error(`tick-state exec mismatch: result=${JSON.stringify(tickResult)}`);
  }

  // 1) A real command through the control-channel exec path: captured stdout + the real exit code.
  const echo = await host.exec("echo parity-ok");
  const stdout = new TextDecoder().decode(echo.stdout).trim();
  if (echo.exitCode !== 0 || stdout !== "parity-ok") {
    throw new Error(`exec mismatch: exit=${echo.exitCode} stdout=${JSON.stringify(stdout)}`);
  }

  // The base fixture intentionally has no coreutils. Select its real `sh`
  // executable directly and pass hostile/empty positional argv literally.
  const direct = await host.run("sh", [
    "-c",
    'printf "<%s>|<%s>|<%s>\\n" "$1" "$2" "$3"',
    "direct-parity",
    "a b",
    "$HOME;touch /tmp/js-direct-shell-leak",
    "",
  ]);
  const directStdout = new TextDecoder().decode(direct.stdout);
  if (
    direct.exitCode !== 0 ||
    directStdout !== "<a b>|<$HOME;touch /tmp/js-direct-shell-leak>|<>\n"
  ) {
    throw new Error(
      `direct exec mismatch: exit=${direct.exitCode} stdout=${JSON.stringify(directStdout)}`,
    );
  }
  try {
    host.stat("/tmp/js-direct-shell-leak");
    throw new Error("direct argv was interpreted as shell syntax");
  } catch (error) {
    if ((error as Error).message === "direct argv was interpreted as shell syntax") throw error;
  }

  // The same resident /bin/sh powers interactive Tab and this programmatic query. No guest task is
  // spawned: the shell parses/renders while the kernel resolves its live namespace and PATH.
  const completion = host.autocomplete(new TextEncoder().encode("cd"), 2);
  const cdCandidate = completion.items.find((item) => item.label === "cd");
  if (
    completion.replaceStart !== 0 ||
    completion.replaceEnd !== 2 ||
    completion.commonPrefix !== "cd" ||
    cdCandidate?.kind !== "builtin"
  ) {
    throw new Error(`autocomplete mismatch: ${JSON.stringify(completion)}`);
  }

  // 2) A control-channel fs round-trip (mc_ctl_write / mc_ctl_read against the live VM).
  host.writeFile("/tmp/parity", new TextEncoder().encode("xyz"));
  const back = new TextDecoder().decode(host.readFile("/tmp/parity"));
  if (back !== "xyz") throw new Error(`control-channel fs mismatch: ${JSON.stringify(back)}`);

  // 3) Snapshot → restore (A8): the MCSN image round-trips through this host, and the rehydrated VM
  //    continues from the saved state — the /tmp/parity file survives and the restored VM is live.
  //    Cross-host Rust→JS/JS→Rust restore is the stronger parity proof and belongs in the shared suite.
  const snap = await host.snapshot();
  const restored = await new KernelHostBuilder(wasm)
    .deterministic() // fresh capabilities — a restored VM never shares the original's host handles
    .withStdout(discard)
    .withStderr(discard)
    .withLog(discard)
    .restore(snap);
  const survived = new TextDecoder().decode(restored.readFile("/tmp/parity"));
  if (survived !== "xyz") {
    throw new Error(`snapshot/restore lost state: /tmp/parity = ${JSON.stringify(survived)}`);
  }
  const echo2 = await restored.exec("echo restored");
  if (echo2.exitCode !== 0 || new TextDecoder().decode(echo2.stdout).trim() !== "restored") {
    throw new Error(`restored VM is not live: exit=${echo2.exitCode}`);
  }

  // 4) Incremental MCSN v2: only pages changed after `snap` are carried, while restore reconstructs
  //    the complete runnable memory image against that one full baseline.
  host.writeFile("/tmp/incremental", new TextEncoder().encode("thin"));
  const incremental = await host.snapshotIncremental(snap);
  if (incremental.length >= snap.length)
    throw new Error("small mutation did not produce a thin snapshot");
  const thinRestored = await new KernelHostBuilder(wasm)
    .deterministic()
    .withStdout(discard)
    .withStderr(discard)
    .withLog(discard)
    .restore(incremental, snap);
  if (new TextDecoder().decode(thinRestored.readFile("/tmp/incremental")) !== "thin") {
    throw new Error("incremental snapshot lost post-baseline state");
  }

  console.log(
    `PARITY OK — JS host booted kernel.wasm in ${bootTicks} ticks; full + incremental restore verified.`,
  );
}

main().catch((e) => {
  console.error("PARITY FAIL:", e instanceof Error ? e.message : e);
  process.exit(1);
});
