// @mc/elements VM state machine over a REAL kernel boot. Two layers, no DOM and no
// mocks:
//
//   1. decideVmSource — the pure binding-priority policy (explicit .vm › provider ›
//      standalone › undecided), checked with plain presence flags, no VM needed.
//   2. makeVmHost / makeControlledHost — the lifecycle the Lit widgets delegate to.
//      makeVmHost boots the SAME kernel.wasm + base.tar the core e2e boots, fetched
//      through the package's own artifacts.ts from a localhost server (so the memoized
//      fetch path is exercised too). We then assert the correctness-critical edges:
//      subscribe delivery, fork independence, restore/reboot swap+notify (the re-bind
//      signal bound widgets ride), close-during-boot (no leak), and that a controlled
//      host never closes a VM it was only handed.
//
// The Lit elements themselves are not exercised here — the repo has no DOM test
// harness, and this is the framework-agnostic core those elements are thin shells over.

import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { setArtifactSources } from "../src/vm/artifacts.js";
import { decideVmSource } from "../src/vm/decide.js";
import { makeControlledHost, makeVmHost } from "../src/vm/host.js";
import type { Vm } from "@mc/core";
import type { VmHost } from "../src/vm/host.js";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

// ── phase 1: the pure resolution policy, no VM ──────────────────────────────
function testDecide(): void {
  // Presence-only inputs — decideVmSource never dereferences these, it only ranks
  // which source wins, so bare shells are honest stand-ins here.
  const vm = {} as Vm;
  const host = {} as VmHost;

  const explicit = decideVmSource({ explicitVm: vm, providedHost: host, standaloneAllowed: true });
  assert(explicit.kind === "explicit" && explicit.vm === vm, "explicit .vm must win over everything");

  const provided = decideVmSource({ explicitVm: undefined, providedHost: host, standaloneAllowed: true });
  assert(provided.kind === "provided" && provided.host === host, "provider must beat standalone boot");

  const standalone = decideVmSource({ explicitVm: undefined, providedHost: undefined, standaloneAllowed: true });
  assert(standalone.kind === "standalone", "standalone when allowed and nothing is provided");

  const undecided = decideVmSource({ explicitVm: undefined, providedHost: undefined, standaloneAllowed: false });
  assert(undecided.kind === "undecided", "undecided when standalone is not allowed (a late provider may still bind)");

  console.log("phase: decideVmSource priority explicit > provided > standalone > undecided OK");
}

async function main(): Promise<void> {
  testDecide();

  const kernelBytes = readFileSync(runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM"));
  const imageBytes = readFileSync(runfile(process.env.MC_BASE_IMAGE, "MC_BASE_IMAGE"));

  // Serve the real artifacts over loopback so makeVmHost fetches them through
  // artifacts.ts exactly as a browser would.
  const server = createServer((req, res) => {
    if (req.url === "/kernel.wasm") {
      res.writeHead(200, { "content-type": "application/wasm" });
      res.end(kernelBytes);
    } else if (req.url === "/image.tar") {
      res.writeHead(200, { "content-type": "application/x-tar" });
      res.end(imageBytes);
    } else {
      res.writeHead(404);
      res.end();
    }
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("artifact server did not bind a TCP port");
  const origin = `http://127.0.0.1:${address.port}`;
  setArtifactSources({ kernel: `${origin}/kernel.wasm`, image: `${origin}/image.tar` });

  const opened: Vm[] = [];
  try {
    // ── close-during-boot: close() before ready settles must reject ready and not
    //    leak the VM that finishes booting after the close. ─────────────────────
    {
      const host = makeVmHost({ deterministic: true });
      const closing = host.close(); // synchronous, while the boot is still in flight
      let rejected = false;
      await host.ready.catch(() => {
        rejected = true;
      });
      await closing;
      assert(rejected, "ready must reject when close() lands during boot");
      assert(host.vm === undefined, "a host closed during boot must expose no VM");
      console.log("phase: close-during-boot rejects ready and leaks no VM OK");
    }

    const host = makeVmHost({ deterministic: true });

    // ── subscribe delivery (pending + immediate) + snapshot ─────────────────────
    let subVm: Vm | undefined;
    const unsub = host.subscribe((vm) => {
      subVm = vm;
    });
    const baseVm = await host.ready;
    opened.push(baseVm);
    assert(subVm === baseVm, "a subscriber added before boot must receive the booted VM");
    assert(host.vm === baseVm, "host.vm must be the booted VM");
    assert(host.shell !== undefined, "host.shell must exist once booted");

    let lateVm: Vm | undefined;
    host.subscribe((vm) => {
      lateVm = vm;
    })();
    assert(lateVm === baseVm, "a subscriber added after boot must fire immediately with the current VM");
    unsub();

    const snap = await host.snapshot();
    assert(snap instanceof Uint8Array && snap.byteLength > 0, "snapshot must produce bytes");
    console.log("phase: subscribe delivers the VM (immediate for late subscribers) + snapshot OK");

    // ── fork is independent; the host's VM does NOT change ──────────────────────
    const forked = await host.fork();
    opened.push(forked);
    assert(forked !== baseVm, "fork must produce a new, distinct VM");
    assert(host.vm === baseVm, "fork must NOT swap the host's VM (the original keeps running)");
    console.log("phase: fork is independent and leaves the host VM in place OK");

    // ── restore swaps the host's VM, notifies subscribers (the re-bind signal),
    //    and closes the old VM. ───────────────────────────────────────────────
    const restoreSnap = await host.snapshot();
    let swappedTo: Vm | undefined;
    const unsubRestore = host.subscribe(() => {}); // immediate fire ignored below
    swappedTo = undefined;
    const unsubWatch = host.subscribe((vm) => {
      swappedTo = vm;
    });
    swappedTo = undefined; // ignore the immediate fire; keep only the swap notification
    const restored = await host.restore(restoreSnap);
    opened.push(restored);
    assert(restored !== baseVm, "restore must produce a new VM");
    assert(host.vm === restored, "restore must swap in the new VM");
    assert(swappedTo === restored, "restore must notify subscribers with the new VM (bound widgets re-bind)");
    unsubRestore();
    unsubWatch();
    console.log("phase: restore swaps the VM and notifies subscribers OK");

    // ── reboot boots a fresh VM from the same options and notifies subscribers ──
    const beforeReboot = host.vm;
    let rebootedTo: Vm | undefined;
    const unsubReboot = host.subscribe((vm) => {
      rebootedTo = vm;
    });
    rebootedTo = undefined; // ignore the immediate fire
    const rebooted = await host.reboot();
    opened.push(rebooted);
    assert(host.vm === rebooted && rebooted !== beforeReboot, "reboot must swap in a fresh VM");
    assert(rebootedTo === rebooted, "reboot must notify subscribers");
    unsubReboot();
    console.log("phase: reboot boots a fresh VM and notifies subscribers OK");

    // ── controlled host is non-owning: close() leaves the handed-in VM running,
    //    and restore/reboot are refused. ─────────────────────────────────────
    const external = await host.vm!.fork();
    opened.push(external);
    const controlled = makeControlledHost(external);
    assert(controlled.vm === external, "controlled host exposes the VM it was given");
    let restoreRefused = false;
    await controlled.restore(new Uint8Array()).catch(() => {
      restoreRefused = true;
    });
    assert(restoreRefused, "controlled host must refuse restore (it does not own the VM)");
    await controlled.close();
    assert(controlled.vm === undefined, "controlled close drops the host's reference");
    const proofSnap = await external.snapshot(); // throws if external was closed
    assert(proofSnap.byteLength > 0, "controlled close must NOT close the VM it was handed");
    console.log("phase: controlled host is non-owning — close leaves the VM alive OK");

    await host.close();
    assert(host.vm === undefined, "close() must drop the host's VM");
  } finally {
    for (const vm of opened) await vm.close().catch(() => {});
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  console.log(
    "ELEMENTS OK — makeVmHost booted kernel.wasm via artifacts.ts; subscribe/fork/restore/reboot/close + controlled host + decideVmSource verified.",
  );
}

main().catch((e) => {
  console.error("ELEMENTS FAIL:", e instanceof Error ? e.message : e);
  process.exit(1);
});
