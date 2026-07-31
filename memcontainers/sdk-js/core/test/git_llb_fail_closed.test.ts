/**
 * P2.4 — llb.git / nodeSolvePlatform fails closed without engine env
 * and without MC_GIT_USE_SYSTEM=1 (no silent system-git fallback).
 */

import { nodeSolvePlatform } from "../src/solve-node.js";

async function main() {
  const keys = [
    "MC_GIT_ENGINE_DIR",
    "MC_GIT_ENGINE_BASE_URL",
    "MC_GIT_USE_SYSTEM",
  ] as const;
  const saved: Record<string, string | undefined> = {};
  for (const k of keys) {
    saved[k] = process.env[k];
    delete process.env[k];
  }

  let threw = false;
  let message = "";
  try {
    await nodeSolvePlatform.gitSource("https://example.com/repo.git", "HEAD", "/src");
  } catch (e) {
    threw = true;
    message = e instanceof Error ? e.message : String(e);
  } finally {
    for (const k of keys) {
      const v = saved[k];
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }

  if (!threw) {
    throw new Error("llb.git must fail closed without MC_GIT_ENGINE_DIR and without MC_GIT_USE_SYSTEM=1");
  }
  if (
    !message.includes("llb.git requires") &&
    !message.includes("MC_GIT_ENGINE_DIR") &&
    !message.includes("MC_GIT_USE_SYSTEM")
  ) {
    throw new Error(`unexpected fail-closed message: ${JSON.stringify(message)}`);
  }

  console.log("git_llb_fail_closed.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
