/**
 * PR9–PR10a: smart-HTTP fixture + TS orchestrator + MapHostCall "git" shape.
 * Engine dial refuse remains fail-closed on GitEngine.run.
 * P2.5: pack-cache second clone skips fetchPacks; keys exclude credentials.
 */

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
  MemoryDurable,
  MemoryPackCache,
  gitHostCallHandler,
  registerGitHostCall,
  uploadPackCacheKey,
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
  const base = pathToFileURL(dir.endsWith("/") ? dir : dir + "/").href;
  const eng = await GitEngine.load({ baseUrl: base });

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
    baseUrl: base,
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
  // (no real objects) — do not soft-accept success. Direct orch: no default packCache.
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
  if (http.fetchPacksCalls !== 1) {
    throw new Error(`expected 1 fetchPacks without cache, got ${http.fetchPacksCalls}`);
  }

  // P2.5: second clone with packCache must skip fetchPacks (download-key hit).
  // Non-empty pack body so empty-pack short-circuit is not the only path; import
  // may still fail closed — we only assert transport call counts + key shape.
  const packBody = new Uint8Array([0x50, 0x41, 0x43, 0x4b, 0, 0, 0, 2, 1, 2, 3, 4]);
  const http2 = new FixtureSmartHttp();
  const url2 = "https://example.com/cached.git";
  http2.add(url2, [{ name: "refs/heads/main", hash }], packBody);
  const cache = new MemoryPackCache();
  const eng2 = await GitEngine.load({ baseUrl: base });
  const orchCached = new GitRemoteOrchestrator(eng2, {
    http: http2,
    packCache: cache,
  });
  const c1 = await orchCached.handle({ op: "clone", args: { url: url2 } });
  if (c1.ok === undefined) throw new Error("no c1");
  if (http2.fetchPacksCalls !== 1) {
    throw new Error(`first clone must call fetchPacks once, got ${http2.fetchPacksCalls}`);
  }
  const packKey = uploadPackCacheKey({
    url: url2,
    wants: [hash],
    haves: [],
  });
  const dig = await cache.getByKey!(packKey);
  if (!dig) {
    throw new Error(`pack cache key miss after first clone: ${packKey}`);
  }
  // Auth must never appear in download-key (credentials only at transport).
  const secret = "s3cr3t-bearer-token";
  if (packKey.includes(secret) || dig.includes(secret)) {
    throw new Error("cache key/digest must not include credentials");
  }

  const eng3 = await GitEngine.load({ baseUrl: base });
  const orch2 = new GitRemoteOrchestrator(eng3, {
    http: http2,
    packCache: cache,
  });
  const c2 = await orch2.handle({ op: "clone", args: { url: url2 } });
  if (c2.ok === undefined) throw new Error("no c2");
  if (http2.fetchPacksCalls !== 1) {
    throw new Error(
      `second clone must hit pack cache (fetchPacks stays 1), got ${http2.fetchPacksCalls}`,
    );
  }
  // listRefs still runs to resolve tip — that is fine; pack transport decreases.
  if (http2.listRefsCalls < 2) {
    throw new Error(`expected listRefs on both clones, got ${http2.listRefsCalls}`);
  }
  await eng2.close();
  await eng3.close();

  // Default path without packCache still works (direct orch above).
  // Product handler defaults process cache on; packCache:null disables.
  const http3 = new FixtureSmartHttp();
  http3.add(url2, [{ name: "refs/heads/main", hash }], packBody);
  const hNull = gitHostCallHandler(eng, { http: http3, packCache: null });
  await hNull(JSON.stringify({ op: "clone", args: { url: url2 } }));
  await hNull(JSON.stringify({ op: "clone", args: { url: url2 } }));
  if (http3.fetchPacksCalls !== 2) {
    throw new Error(
      `packCache:null must not cache (2 fetchPacks), got ${http3.fetchPacksCalls}`,
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

  // Sparse cone on asMountDriver: out-of-cone paths are ENOENT (cone-only).
  await eng.run({ op: "init" });
  await eng.run({
    op: "write",
    args: { path: "src/in.txt", content: "in\n" },
  });
  await eng.run({
    op: "write",
    args: { path: "other/out.txt", content: "out\n" },
  });
  const sparseDriver = eng.asMountDriver({ sparseCone: ["src"] });
  const root = await sparseDriver.readdir("/");
  if (!root.some((e) => e.name === "src")) {
    throw new Error(`sparse readdir missing src: ${JSON.stringify(root)}`);
  }
  if (root.some((e) => e.name === "other")) {
    throw new Error(`sparse readdir must hide other: ${JSON.stringify(root)}`);
  }
  try {
    await sparseDriver.open("/other/out.txt");
    throw new Error("out-of-cone open must ENOENT");
  } catch (e) {
    if ((e as { code?: string }).code !== "ENOENT") {
      throw new Error(`expected ENOENT, got ${String(e)}`);
    }
  }

  await eng.close();
  console.log("git_remote.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
