// Default kernel + base-image loading for the node/bun embedded backend, read via env vars so it works
// under BOTH node and bun (no `Bun.file`) and against the bazel-built artifacts (which have no single
// fixed source path). A browser caller passes `opts.kernel` + `opts.image` bytes directly (no
// filesystem). Point these at the built artifacts via MC_KERNEL_WASM / MC_BASE_IMAGE, or pass
// `opts.kernel` / `opts.image` to `mc.create`.

import { readFileSync } from "node:fs";

function readEnvArtifact(envVar: string, what: string, optsKey: string): Uint8Array {
  const path = process.env[envVar];
  if (!path) {
    throw new Error(
      `${what} not available: set ${envVar} to the built artifact path, or pass it as ` +
        `mc.create({ ${optsKey}: <Uint8Array> }).`,
    );
  }
  return new Uint8Array(readFileSync(path));
}

/** The kernel.wasm bytes (from $MC_KERNEL_WASM). */
export async function defaultKernel(): Promise<Uint8Array> {
  return readEnvArtifact("MC_KERNEL_WASM", "kernel.wasm", "kernel");
}

/** The default base image / base.tar (from $MC_BASE_IMAGE). */
export async function defaultImage(): Promise<Uint8Array> {
  return readEnvArtifact("MC_BASE_IMAGE", "base image", "image");
}
