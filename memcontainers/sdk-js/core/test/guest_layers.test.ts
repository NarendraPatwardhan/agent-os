import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { BROWSER_CONTRACT_DIGEST, BROWSER_KIND, BROWSER_VERSION } from "@mc/contracts/browser";
import { browser } from "../src/browsers.js";
import { mc } from "../src/memcontainer.js";
import type {
  SidecarAuthority,
  SidecarCapability,
  SidecarCreateRequest,
  SidecarGrant,
  SidecarHost,
  SidecarInstance,
  SidecarInvokeRequest,
} from "../src/sidecars.js";

function runfile(env: string): Uint8Array {
  const relative = process.env[env];
  const root = process.env.RUNFILES_DIR;
  if (!relative || !root) throw new Error(`${env} is unavailable outside bazel test`);
  return new Uint8Array(readFileSync(join(root, relative)));
}

class EmptyAuthority implements SidecarAuthority {
  async enable(_name: string, _grant: SidecarGrant): Promise<void> {}
  async disable(_name: string, _destroy?: boolean): Promise<void> {}
  async create(_request: SidecarCreateRequest): Promise<SidecarInstance> {
    throw new Error("not used");
  }
  async retrieve(_id: string): Promise<SidecarInstance> {
    throw new Error("not used");
  }
  async list(_kind?: string): Promise<SidecarInstance[]> {
    return [];
  }
  async invoke(_request: SidecarInvokeRequest): Promise<Uint8Array> {
    throw new Error("not used");
  }
  async delete(_id: string): Promise<void> {}
  async close(): Promise<void> {}
}

const capability: SidecarCapability = {
  kind: BROWSER_KIND,
  version: BROWSER_VERSION,
  contractDigest: BROWSER_CONTRACT_DIGEST,
  placements: ["local"],
  fork: "omit",
  maxInstancesPerVm: 2,
};

const host: SidecarHost = {
  async describe() {
    return { kinds: [capability] };
  },
  async attach() {
    return new EmptyAuthority();
  },
};

async function main(): Promise<void> {
  const kernel = runfile("MC_KERNEL_WASM");
  const image = runfile("MC_LOOM_IMAGE");
  const browserctl = runfile("MC_BROWSERCTL_LAYER");

  const hostOnly = await mc.create({
    kernel,
    image,
    sidecarHosts: { runner: host },
    sidecars: { web: browser({ host: "runner" }) },
  });
  try {
    await assert.rejects(hostOnly.fs.stat("/bin/browser"));
    await assert.rejects(hostOnly.fs.stat("/lib/luau/browser.luau"));
  } finally {
    await hostOnly.close();
  }

  const guest = await mc.create({
    kernel,
    image,
    sidecarHosts: { runner: host },
    sidecars: { web: browser({ host: "runner", guest: browserctl }) },
  });
  try {
    await guest.fs.stat("/bin/browser");
    await guest.fs.stat("/lib/luau/browser.luau");
    await guest.fs.stat("/lib/luau/_browser_wire.luau");
    await guest.fs.stat("/lib/luau/_sidecar_wire.luau");
    await guest.fs.stat("/skills/browser.md");

    const required = await guest.luau(
      'local browser = require("browser"); print(type(browser.use))',
    );
    assert.equal(required.exitCode, 0, required.stdout);
    assert.match(required.stdout, /function/);
  } finally {
    await guest.close();
  }

  await assert.rejects(
    mc.create({
      kernel,
      image,
      sidecarHosts: { runner: host },
      sidecars: { web: browser({ host: "runner", guest: true }) },
    }),
    /requires guest layer bytes/u,
  );

  await assert.rejects(
    mc.create({
      runtime: "remote",
      endpoint: "https://agent.invalid",
      sidecars: { web: browser({ guest: browserctl }) },
    }),
    /must delegate its guest layer to the server/u,
  );
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
