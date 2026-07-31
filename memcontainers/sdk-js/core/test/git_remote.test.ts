/**
 * PR9–PR10a: smart-HTTP fixture + TS orchestrator + MapHostCall "git" shape.
 * Engine dial refuse remains fail-closed on GitEngine.run.
 */

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
  MemoryDurable,
  gitHostCallHandler,
  registerGitHostCall,
} from "../src/git/index.js";

function engineDir(): string {
  const jsRel = process.env.MC_GIT_ENGINE_JS || "";
  const rf = process.env.RUNFILES_DIR;
  const candidates = [
    jsRel && rf ? join(rf, jsRel) : "",
    jsRel && rf ? join(rf, "_main", jsRel) : "",
    jsRel,
    join(process.cwd(), "bazel-bin/memcontainers/lib/git-engine/git_engine.mjs"),
  ];
  for (const c of candidates) {
    if (c && existsSync(c)) return dirname(c);
    if (c && existsSync(join(c, "git_engine.mjs"))) return c;
  }
  throw new Error(`engine dir not found (MC_GIT_ENGINE_JS=${jsRel})`);
}

async function main() {
  const dir = engineDir();
  const eng = await GitEngine.load({
    baseUrl: pathToFileURL(dir.endsWith("/") ? dir : dir + "/").href,
  });

  // Engine purity: run(clone) never dials
  const dial = await eng.run({
    op: "clone",
    args: { url: "https://example.com/r.git" },
  });
  if (dial.ok || !String(dial.stderr || "").includes("orchestrator")) {
    throw new Error(`engine must refuse dial: ${JSON.stringify(dial)}`);
  }

  // Durable: opaque store round-trip + engine-level attach (no MEMFS rebind)
  const dur = new MemoryDurable("t");
  await dur.save(new TextEncoder().encode("snap"));
  const loaded = await dur.load();
  if (!loaded || new TextDecoder().decode(loaded) !== "snap") {
    throw new Error("MemoryDurable failed");
  }
  const engDurable = await GitEngine.load({
    baseUrl: pathToFileURL(dir.endsWith("/") ? dir : dir + "/").href,
    durable: dur,
  });
  const engSnap = engDurable.durableSnapshot;
  if (!engSnap || new TextDecoder().decode(engSnap) !== "snap") {
    throw new Error("GitEngine.load must surface durable snapshot engine-level only");
  }
  await engDurable.checkpoint(new TextEncoder().encode("snap2"));
  const afterCp = await dur.load();
  if (!afterCp || new TextDecoder().decode(afterCp) !== "snap2") {
    throw new Error("checkpoint must persist opaque bytes");
  }
  await engDurable.close();

  // Empty pack orchestrator path with fixture: list-refs must work; clone must fail closed
  // (no real objects) — do not soft-accept success.
  const http = new FixtureSmartHttp();
  const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  http.add(
    "https://example.com/demo.git",
    [{ name: "refs/heads/main", hash }],
    new Uint8Array(0),
  );
  const orch = new GitRemoteOrchestrator(eng, { http });
  const r = await orch.handle({
    op: "clone",
    args: { url: "https://example.com/demo.git" },
  });
  if (r.ok === undefined) throw new Error("no response");
  if (String(r.stderr || "").includes("list-refs failed")) {
    throw new Error(`list-refs should use fixture: ${JSON.stringify(r)}`);
  }
  if (r.ok) {
    throw new Error(
      `empty pack clone must fail closed (no objects), got success: ${JSON.stringify(r)}`,
    );
  }

  // MapHostCall-shaped handler
  const handler = gitHostCallHandler(eng, { http });
  const raw = await handler(
    JSON.stringify({ op: "fetch", args: { url: "https://example.com/demo.git" } }),
  );
  const parsed = JSON.parse(raw);
  if (parsed.ok === undefined) throw new Error(raw);

  // register helper
  const tools = {
    map: new Map<string, (a: string) => Promise<string> | string>(),
    register(name: string, h: (a: string) => Promise<string> | string) {
      this.map.set(name, h);
    },
  };
  registerGitHostCall(tools, eng, { http });
  if (!tools.map.has("git")) throw new Error("registerGitHostCall missing git");

  // Ctl still refuses remotes
  const driver = eng.asMountDriver();
  await driver.write!(
    "/.git/mc/ctl",
    new TextEncoder().encode(JSON.stringify({ op: "fetch" })),
  );
  const refuse = JSON.parse(
    new TextDecoder().decode(await driver.open("/.git/mc/out/last")),
  );
  if (refuse.ok || !String(refuse.stderr || "").includes("host_call")) {
    throw new Error(`ctl fetch must refuse: ${JSON.stringify(refuse)}`);
  }

  await eng.close();
  console.log("git_remote.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
