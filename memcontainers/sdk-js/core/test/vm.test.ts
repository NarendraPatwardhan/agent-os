// @mc/core embedded backend over @mc/host: a real `mc.create()` boots the SAME kernel.wasm + base.tar
// the wasmtime e2e uses (passed as bytes, so no env/runfiles indirection through artifacts.ts), and the
// Vm API runs a real command + a real fs round-trip. This exercises the SDK library through the
// @mc/host → @mc/contracts package deps at RUNTIME — the layer the host-only parity test cannot reach.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { mc } from "../src/index.js";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

async function main(): Promise<void> {
  const kernel = new Uint8Array(readFileSync(runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM")));
  const image = new Uint8Array(readFileSync(runfile(process.env.MC_BASE_IMAGE, "MC_BASE_IMAGE")));

  // Bytes passed directly → no MC_STORE / defaultKernel env path; the embedded backend (the JS host)
  // boots the kernel in-process.
  const vm = await mc.create({ kernel, image, deterministic: true });
  try {
    const r = await vm.exec("echo core-ok");
    if (r.exitCode !== 0 || r.stdout.trim() !== "core-ok") {
      throw new Error(`vm.exec mismatch: exit=${r.exitCode} stdout=${JSON.stringify(r.stdout)}`);
    }
    await vm.fs.write("/tmp/core", "hello");
    if ((await vm.fs.readText("/tmp/core")) !== "hello") {
      throw new Error("vm.fs round-trip mismatch");
    }

    // Activate /svc/tools while its boot catalog is empty, then register a tool at runtime. This proves
    // vm.tool() updates the warm service's live catalog instead of only rewriting /etc/tools/catalog.json.
    const before = await vm.exec("tools list");
    if (before.exitCode !== 0 || !before.stdout.includes('"tools":[]')) {
      throw new Error(`initial tools catalog mismatch: exit=${before.exitCode} stdout=${before.stdout}`);
    }
    await vm.tool({
      name: "dynamic greet",
      address: "host.org.main.dynamicGreet",
      description: "Greet dynamically",
      run: (input) => ({ message: `hello ${String(input.name ?? "world")}` }),
    });
    const after = await vm.exec("tools call host.org.main.dynamicGreet '{\"name\":\"Ada\"}'");
    if (after.exitCode !== 0 || !after.stdout.includes('"message":"hello Ada"')) {
      throw new Error(`runtime tool registration mismatch: exit=${after.exitCode} stdout=${after.stdout}`);
    }
  } finally {
    await vm.close();
  }
  console.log("CORE OK — mc.create booted kernel.wasm via @mc/host; vm.exec + vm.fs verified.");
}

main().catch((e) => {
  console.error("CORE FAIL:", e instanceof Error ? e.message : e);
  process.exit(1);
});
