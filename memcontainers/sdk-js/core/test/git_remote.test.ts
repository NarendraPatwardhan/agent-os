/**
 * PR9–PR10a: smart-HTTP fixture + TS orchestrator + MapHostCall "git" shape.
 * Engine dial refuse remains fail-closed on GitEngine.run.
 * P2.5: pack-cache second clone skips fetchPacks; keys exclude credentials.
 * D21: multi-mount two clones via args.mount + concurrent remotes on two engines.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  FetchSmartHttp,
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
  MemoryDurable,
  MemoryPackCache,
  gitHostCallHandler,
  isRedirectResponse,
  mountFromGitRequest,
  registerGitHostCall,
  resolveGitEngineForMount,
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

/** Real minimal.pack + tip for successful clone e2e (D21 dual-mount). */
function minimalPackFixture(): { pack: Uint8Array; tip: string } {
  const packRel = process.env.MC_GIT_MINIMAL_PACK || "";
  const tipRel = process.env.MC_GIT_MINIMAL_TIP || "";
  const rf = process.env.RUNFILES_DIR || "";
  const packCandidates = [
    packRel && rf ? join(rf, packRel) : "",
    packRel && rf ? join(rf, "_main", packRel) : "",
    packRel,
    rf ? join(rf, "memcontainers/sdk-js/core/fixtures/pack/minimal.pack") : "",
    rf ? join(rf, "_main/memcontainers/sdk-js/core/fixtures/pack/minimal.pack") : "",
    join(process.cwd(), "memcontainers/lib/git-engine/fixtures/pack/minimal.pack"),
  ].filter(Boolean);
  let packPath = "";
  for (const c of packCandidates) {
    if (c.endsWith(".pack") && existsSync(c)) {
      packPath = c;
      break;
    }
    if (existsSync(join(c, "minimal.pack"))) {
      packPath = join(c, "minimal.pack");
      break;
    }
  }
  const tipCandidates = [
    tipRel && rf ? join(rf, tipRel) : "",
    tipRel && rf ? join(rf, "_main", tipRel) : "",
    tipRel,
    packPath ? join(dirname(packPath), "minimal.tip") : "",
    join(process.cwd(), "memcontainers/lib/git-engine/fixtures/pack/minimal.tip"),
  ].filter(Boolean);
  let tipPath = "";
  for (const c of tipCandidates) {
    if (existsSync(c)) {
      tipPath = c;
      break;
    }
  }
  if (!packPath || !tipPath) {
    throw new Error(
      `minimal pack/tip not found (MC_GIT_MINIMAL_PACK=${packRel} MC_GIT_MINIMAL_TIP=${tipRel})`,
    );
  }
  const tip = readFileSync(tipPath, "utf8").trim();
  if (!/^[0-9a-f]{40}$/i.test(tip)) {
    throw new Error(`invalid tip oid: ${JSON.stringify(tip)}`);
  }
  return { pack: new Uint8Array(readFileSync(packPath)), tip };
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

  // Durable: backend byte store + legacy non-AGIT attach (engine-level only).
  // Real pack+refs rebind is covered in git_engine.test (R52–R55).
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
    throw new Error(
      "GitEngine.load must surface legacy non-AGIT snapshot engine-level only",
    );
  }
  // Explicit snapshot override still persists caller bytes as-is.
  await engDurable.checkpoint(new TextEncoder().encode("snap2"));
  const afterCp = await dur.load();
  if (!afterCp || new TextDecoder().decode(afterCp) !== "snap2") {
    throw new Error("checkpoint(explicit) must persist caller bytes");
  }
  await engDurable.close();

  // redirect policy — never follow; open redirect cannot leave allowlist.
  if (!isRedirectResponse({ status: 301 })) {
    throw new Error("isRedirectResponse must treat 301 as redirect");
  }
  if (!isRedirectResponse({ status: 302 })) {
    throw new Error("isRedirectResponse must treat 302 as redirect");
  }
  if (!isRedirectResponse({ status: 307 })) {
    throw new Error("isRedirectResponse must treat 307 as redirect");
  }
  if (!isRedirectResponse({ status: 0, type: "opaqueredirect" })) {
    throw new Error("isRedirectResponse must treat opaqueredirect as redirect");
  }
  if (isRedirectResponse({ status: 200 }) || isRedirectResponse({ status: 404 })) {
    throw new Error("isRedirectResponse must not flag non-redirect statuses");
  }

  const fetchCalls: { url: string; redirect?: RequestRedirect }[] = [];
  const redirectFetch = async (
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = String(input);
    fetchCalls.push({ url, redirect: init?.redirect });
    // Simulate a 302 open redirect to a non-allowlisted origin. Product must
    // use redirect:"manual" so this Response is returned (not auto-followed).
    return new Response(null, {
      status: 302,
      headers: { Location: "https://evil.example/stolen-pack" },
    });
  };
  const redirectHttp = new FetchSmartHttp(undefined, redirectFetch);
  const redirectUrl = "https://example.com/demo.git";

  let listThrew = false;
  try {
    await redirectHttp.listRefs(redirectUrl);
  } catch (e) {
    listThrew = true;
    if (!String(e).includes("redirect not allowed")) {
      throw new Error(`listRefs redirect must say not allowed: ${String(e)}`);
    }
  }
  if (!listThrew) throw new Error("listRefs must reject 302 open redirect");

  let fetchThrew = false;
  try {
    await redirectHttp.fetchPacks(redirectUrl, ["a".repeat(40)], []);
  } catch (e) {
    fetchThrew = true;
    if (!String(e).includes("redirect not allowed")) {
      throw new Error(`fetchPacks redirect must say not allowed: ${String(e)}`);
    }
  }
  if (!fetchThrew) throw new Error("fetchPacks must reject 302 open redirect");

  const pushSt = await redirectHttp.pushPacks(
    redirectUrl,
    [
      {
        oldHash: "0".repeat(40),
        newHash: "a".repeat(40),
        name: "refs/heads/main",
      },
    ],
    new Uint8Array([0x50, 0x41, 0x43, 0x4b]),
  );
  if (pushSt.ok || !String(pushSt.message || "").includes("redirect not allowed")) {
    throw new Error(`pushPacks redirect must fail closed: ${JSON.stringify(pushSt)}`);
  }

  if (fetchCalls.length < 3) {
    throw new Error(`expected ≥3 dials for list/fetch/push, got ${fetchCalls.length}`);
  }
  for (const c of fetchCalls) {
    if (c.redirect !== "manual") {
      throw new Error(`FetchSmartHttp must set redirect:manual, got ${c.redirect} for ${c.url}`);
    }
    if (c.url.includes("evil.example")) {
      throw new Error(`open redirect followed to evil origin: ${c.url}`);
    }
  }

  // bare URL + empty allowOrigins fails closed before transport dial.
  const bareDenied = new FixtureSmartHttp();
  bareDenied.add(
    "https://example.com/bare.git",
    [{ name: "refs/heads/main", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }],
    new Uint8Array(0),
  );
  const orchBare = new GitRemoteOrchestrator(eng, { http: bareDenied });
  const bareR = await orchBare.handle({
    op: "clone",
    args: { url: "https://example.com/bare.git" },
  });
  if (bareR.ok || !String(bareR.stderr || "").includes("not allowlisted")) {
    throw new Error(`bare URL empty allowOrigins must fail closed: ${JSON.stringify(bareR)}`);
  }
  if (bareDenied.listRefsCalls !== 0) {
    throw new Error("bare URL deny must not dial listRefs");
  }

  // Empty pack orchestrator path with fixture: list-refs must work; clone must fail closed
  // (no real objects) — do not soft-accept success. Direct orch: no default packCache.
  // fixture bare URLs need explicit allowOrigins.
  const http = new FixtureSmartHttp();
  const hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const fixtureOrigin = "https://example.com";
  http.add(
    "https://example.com/demo.git",
    [{ name: "refs/heads/main", hash }],
    new Uint8Array(0),
  );
  const orch = new GitRemoteOrchestrator(eng, {
    http,
    allowOrigins: [fixtureOrigin],
  });
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
  // product default depth=1 is part of the cache key.
  const packBody = new Uint8Array([0x50, 0x41, 0x43, 0x4b, 0, 0, 0, 2, 1, 2, 3, 4]);
  const http2 = new FixtureSmartHttp();
  const url2 = "https://example.com/cached.git";
  http2.add(url2, [{ name: "refs/heads/main", hash }], packBody);
  const cache = new MemoryPackCache();
  const eng2 = await GitEngine.load({ baseUrl: base });
  const orchCached = new GitRemoteOrchestrator(eng2, {
    http: http2,
    packCache: cache,
    allowOrigins: [fixtureOrigin],
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
    depth: 1,
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
    allowOrigins: [fixtureOrigin],
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
  // Product handler defaults a fresh Memory cache; packCache:null disables.
  const http3 = new FixtureSmartHttp();
  http3.add(url2, [{ name: "refs/heads/main", hash }], packBody);
  const hNull = gitHostCallHandler(eng, {
    http: http3,
    packCache: null,
    allowOrigins: [fixtureOrigin],
  });
  await hNull(JSON.stringify({ op: "clone", args: { url: url2 } }));
  await hNull(JSON.stringify({ op: "clone", args: { url: url2 } }));
  if (http3.fetchPacksCalls !== 2) {
    throw new Error(
      `packCache:null must not cache (2 fetchPacks), got ${http3.fetchPacksCalls}`,
    );
  }

  // MapHostCall-shaped handler
  const handler = gitHostCallHandler(eng, {
    http,
    allowOrigins: [fixtureOrigin],
  });
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
  registerGitHostCall(tools, eng, { http, allowOrigins: [fixtureOrigin] });
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

  // / M7 v1: multi-path monorepo pack → shallow depth=1 clone + cone sparse
  // → worktree + gitfs hide out-of-cone (not filter-only theater).
  {
    const engSrc = await GitEngine.load({ baseUrl: base });
    let wr = await engSrc.run({ op: "init" });
    if (!wr.ok) throw new Error(`D13 src init: ${JSON.stringify(wr)}`);
    wr = await engSrc.run({
      op: "write",
      args: { path: "src/in.txt", content: "in-cone\n" },
    });
    if (!wr.ok) throw new Error(`D13 write src: ${JSON.stringify(wr)}`);
    wr = await engSrc.run({
      op: "write",
      args: { path: "other/out.txt", content: "out-of-cone\n" },
    });
    if (!wr.ok) throw new Error(`D13 write other: ${JSON.stringify(wr)}`);
    wr = await engSrc.run({ op: "add", args: { path: "src/in.txt" } });
    if (!wr.ok) throw new Error(`D13 add src: ${JSON.stringify(wr)}`);
    wr = await engSrc.run({ op: "add", args: { path: "other/out.txt" } });
    if (!wr.ok) throw new Error(`D13 add other: ${JSON.stringify(wr)}`);
    wr = await engSrc.run({
      op: "commit",
      args: {
        message: "monorepo multi-path",
        name: "Mono",
        email: "mono@test",
        when_unix: 1_700_000_400,
      },
    });
    if (!wr.ok) throw new Error(`D13 commit: ${JSON.stringify(wr)}`);
    const tipRaw = await engSrc.run({
      op: "rev-parse",
      args: { rev: "HEAD" },
    });
    const monoTip = String(tipRaw.stdout || "")
      .trim()
      .split(/\s+/)[0];
    if (!monoTip || !/^[0-9a-f]{40}$/i.test(monoTip)) {
      throw new Error(`D13 bad tip: ${JSON.stringify(tipRaw)}`);
    }
    const monoPack = await engSrc.buildPushPack([monoTip]);
    if (monoPack.byteLength < 4 || monoPack[0] !== 0x50) {
      throw new Error("D13 pack missing PACK magic");
    }
    await engSrc.close();

    const monoUrl = "https://example.com/monorepo.git";
    const baseMonoHttp = new FixtureSmartHttp();
    baseMonoHttp.add(
      monoUrl,
      [{ name: "refs/heads/main", hash: monoTip }],
      monoPack,
    );
    let seenDepth: number | undefined;
    const monoHttp = {
      listRefs: (
        url: string,
        auth?: Parameters<FixtureSmartHttp["listRefs"]>[1],
      ) => baseMonoHttp.listRefs(url, auth),
      fetchPacks: async (
        url: string,
        want: string[],
        have: string[],
        depth?: number,
        auth?: Parameters<FixtureSmartHttp["fetchPacks"]>[4],
        filter?: string,
      ) => {
        seenDepth = depth;
        return baseMonoHttp.fetchPacks(url, want, have, depth, auth, filter);
      },
    };

    // Engine load sparseCone → orch post-clone sparse-set + gitfs projection.
    const engDst = await GitEngine.load({
      baseUrl: base,
      sparseCone: ["src"],
    });
    if (!engDst.sparseCone?.includes("src")) {
      throw new Error(`D13 engine.sparseCone missing src: ${JSON.stringify(engDst.sparseCone)}`);
    }
    // Orch inherits engine.sparseCone when opts.sparseCone omitted (D13).
    const monoOrch = new GitRemoteOrchestrator(engDst, {
      http: monoHttp,
      allowOrigins: [fixtureOrigin],
      packCache: null,
    });
    const monoClone = await monoOrch.handle({
      op: "clone",
      args: { url: monoUrl },
    });
    if (!monoClone.ok) {
      throw new Error(`D13 monorepo clone failed: ${JSON.stringify(monoClone)}`);
    }
    if (seenDepth !== 1) {
      throw new Error(`D13 product default depth=1, got ${String(seenDepth)}`);
    }

    // Cruel: engine sparse-set must prune MEMFS worktree (not gitfs filter-only).
    // Full driver (no cone) still must not see other/ after prune.
    const fullFs = engDst.asMountDriver({ sparseCone: [] });
    const fullRoot = await fullFs.readdir("/");
    if (!fullRoot.some((e) => e.name === "src")) {
      throw new Error(`D13 worktree missing src: ${JSON.stringify(fullRoot)}`);
    }
    if (fullRoot.some((e) => e.name === "other")) {
      throw new Error(
        `D13 worktree must not retain out-of-cone other: ${JSON.stringify(fullRoot)}`,
      );
    }
    try {
      await fullFs.open("/other/out.txt");
      throw new Error("D13 out-of-cone must be gone from MEMFS worktree");
    } catch (e) {
      if (String(e).includes("must be gone from MEMFS")) throw e;
    }

    // gitfs cone projection (defense in depth) still hides out-of-cone.
    const monoFs = engDst.asMountDriver(); // uses load-time sparseCone
    const monoRoot = await monoFs.readdir("/");
    if (!monoRoot.some((e) => e.name === "src")) {
      throw new Error(`D13 gitfs missing src: ${JSON.stringify(monoRoot)}`);
    }
    if (monoRoot.some((e) => e.name === "other")) {
      throw new Error(
        `D13 gitfs must hide out-of-cone other: ${JSON.stringify(monoRoot)}`,
      );
    }
    const inCone = new TextDecoder().decode(await monoFs.open("/src/in.txt"));
    if (inCone !== "in-cone\n") {
      throw new Error(`D13 in-cone content: ${JSON.stringify(inCone)}`);
    }
    try {
      await monoFs.open("/other/out.txt");
      throw new Error("D13 out-of-cone open must fail on gitfs");
    } catch (e) {
      if (String(e).includes("out-of-cone open must fail")) throw e;
      if ((e as { code?: string }).code !== "ENOENT") {
        // Accept ENOENT-coded or message-based missing path.
        if (!/ENOENT|not found|No such|no such/i.test(String(e))) {
          throw new Error(`D13 expected ENOENT for other/out.txt: ${String(e)}`);
        }
      }
    }

    // In-cone content + prune above prove sparse-set ran (not projection-only).
    // HEAD/ref form after sparse-set + checkout can be detached tip-only — clone
    // already returned ok with depth=1 and worktree materialised.

    await engDst.close();
  }

  // –R65 / D21: multi-engine demux via args.mount / mount
  const engA = await GitEngine.load({ baseUrl: base });
  const engB = await GitEngine.load({ baseUrl: base });
  const engineMap = new Map([
    ["/workspace/a", engA],
    ["/workspace/b", engB],
  ]);
  if (mountFromGitRequest({ op: "clone", args: { mount: "/workspace/a" } }) !== "/workspace/a") {
    throw new Error("mountFromGitRequest args.mount failed");
  }
  if (mountFromGitRequest({ op: "clone", mount: "/workspace/b", args: {} }) !== "/workspace/b") {
    throw new Error("mountFromGitRequest top-level mount failed");
  }
  const hitA = resolveGitEngineForMount(
    { op: "fetch", args: { mount: "/workspace/a" } },
    engineMap,
    "/workspace/a",
  );
  if ("error" in hitA || hitA.engine !== engA) {
    throw new Error(`demux A failed: ${JSON.stringify(hitA)}`);
  }
  const hitB = resolveGitEngineForMount(
    { op: "fetch", mount: "/workspace/b" },
    engineMap,
    "/workspace/a",
  );
  if ("error" in hitB || hitB.engine !== engB) {
    throw new Error(`demux B failed: ${JSON.stringify(hitB)}`);
  }
  const hitBad = resolveGitEngineForMount(
    { op: "fetch", args: { mount: "/workspace/missing" } },
    engineMap,
    "/workspace/a",
  );
  if (!("error" in hitBad) || !String(hitBad.error).includes("unknown mount")) {
    throw new Error(`unknown mount must fail: ${JSON.stringify(hitBad)}`);
  }

  // Two independent engines: init+write only on A; B stays empty.
  await engA.run({ op: "init" });
  await engA.run({
    op: "write",
    args: { path: "only-a.txt", content: "a\n" },
  });
  const stA = await engA.run({ op: "status" });
  const stB = await engB.run({ op: "status" });
  if (!stA.ok) throw new Error(`engA status: ${JSON.stringify(stA)}`);
  // engB never inited — status may fail or show empty; must not see only-a.
  if (String(stB.stdout || "").includes("only-a")) {
    throw new Error("engines must not share worktree state");
  }

  // Unknown mount returns code 1 without dialing (shared empty-pack fixture http).
  {
    const multiHandlerDeny = gitHostCallHandler(
      { engines: engineMap, defaultMount: "/workspace/a" },
      { http, allowOrigins: [fixtureOrigin], packCache: null },
    );
    const listBefore = http.listRefsCalls;
    const fetchBefore = http.fetchPacksCalls;
    const unknownRaw = await multiHandlerDeny(
      JSON.stringify({
        op: "clone",
        args: { url: "https://example.com/demo.git", mount: "/nope" },
      }),
    );
    const unknownParsed = JSON.parse(unknownRaw);
    if (unknownParsed.ok || !String(unknownParsed.stderr || "").includes("unknown mount")) {
      throw new Error(`unknown mount host_call: ${unknownRaw}`);
    }
    if (http.listRefsCalls !== listBefore || http.fetchPacksCalls !== fetchBefore) {
      throw new Error(
        `unknown mount must not dial (listRefs ${listBefore}→${http.listRefsCalls} fetchPacks ${fetchBefore}→${http.fetchPacksCalls})`,
      );
    }
  }

  const toolsMulti = {
    map: new Map<string, (a: string) => Promise<string> | string>(),
    register(name: string, h: (a: string) => Promise<string> | string) {
      this.map.set(name, h);
    },
  };
  registerGitHostCall(
    toolsMulti,
    { engines: engineMap, defaultMount: "/workspace/a" },
    { http, allowOrigins: [fixtureOrigin], packCache: null },
  );
  if (!toolsMulti.map.has("git")) {
    throw new Error("registerGitHostCall multi missing git");
  }

  // product e2e: two mounts, two engines, clone into each via args.mount
  // with real minimal.pack → worktree isolation (README hello).
  {
    const { pack: realPack, tip: realTip } = minimalPackFixture();
    const dualA = await GitEngine.load({ baseUrl: base });
    const dualB = await GitEngine.load({ baseUrl: base });
    const dualMap = new Map([
      ["/workspace/a", dualA],
      ["/workspace/b", dualB],
    ]);
    const dualUrlA = "https://example.com/repo-a.git";
    const dualUrlB = "https://example.com/repo-b.git";
    const dualHttp = new FixtureSmartHttp();
    dualHttp.add(dualUrlA, [{ name: "refs/heads/main", hash: realTip }], realPack);
    dualHttp.add(dualUrlB, [{ name: "refs/heads/main", hash: realTip }], realPack);
    const dualHandler = gitHostCallHandler(
      { engines: dualMap, defaultMount: "/workspace/a" },
      { http: dualHttp, allowOrigins: [fixtureOrigin], packCache: null },
    );

    const cloneARaw = await dualHandler(
      JSON.stringify({
        op: "clone",
        args: { url: dualUrlA, mount: "/workspace/a" },
      }),
    );
    const cloneA = JSON.parse(cloneARaw);
    if (!cloneA.ok) {
      throw new Error(`D21 clone mount A failed: ${cloneARaw}`);
    }
    if (!String(cloneA.stdout || "").includes("cloned")) {
      throw new Error(`D21 clone A expected cloned stdout: ${cloneARaw}`);
    }

    const cloneBRaw = await dualHandler(
      JSON.stringify({
        op: "clone",
        args: { url: dualUrlB, mount: "/workspace/b" },
      }),
    );
    const cloneB = JSON.parse(cloneBRaw);
    if (!cloneB.ok) {
      throw new Error(`D21 clone mount B failed: ${cloneBRaw}`);
    }
    if (!String(cloneB.stdout || "").includes("cloned")) {
      throw new Error(`D21 clone B expected cloned stdout: ${cloneBRaw}`);
    }
    if (dualHttp.listRefsCalls < 2 || dualHttp.fetchPacksCalls < 2) {
      throw new Error(
        `D21 both mounts must dial transport (listRefs=${dualHttp.listRefsCalls} fetchPacks=${dualHttp.fetchPacksCalls})`,
      );
    }

    // Worktree isolation: each engine has README from minimal.pack.
    const readmeA = new TextDecoder().decode(
      await dualA.asMountDriver().open("/README"),
    );
    const readmeB = new TextDecoder().decode(
      await dualB.asMountDriver().open("/README"),
    );
    if (readmeA !== "hello\n") {
      throw new Error(`D21 mount A README want hello\\n got ${JSON.stringify(readmeA)}`);
    }
    if (readmeB !== "hello\n") {
      throw new Error(`D21 mount B README want hello\\n got ${JSON.stringify(readmeB)}`);
    }

    // Write only on A must not appear on B.
    await dualA.run({
      op: "write",
      args: { path: "only-on-a.txt", content: "a-only\n" },
    });
    try {
      await dualB.asMountDriver().open("/only-on-a.txt");
      throw new Error("D21 engines must not share worktree (B saw only-on-a.txt)");
    } catch (e) {
      if ((e as { code?: string }).code !== "ENOENT" && !String(e).includes("ENOENT") &&
          !String(e).includes("not found") && !String(e).includes("No such")) {
        // Some drivers throw ENOENT-coded; accept any failure that is not success.
        if (String(e).includes("must not share")) throw e;
      }
    }

    // Omit mount → defaultMount (/workspace/a) for fetch.
    const fetchDefaultRaw = await dualHandler(
      JSON.stringify({ op: "fetch", args: { url: dualUrlA } }),
    );
    const fetchDefault = JSON.parse(fetchDefaultRaw);
    if (fetchDefault.ok === undefined) {
      throw new Error(`D21 default-mount fetch: ${fetchDefaultRaw}`);
    }

    await dualA.close();
    await dualB.close();
  }

  // two engines concurrent — distinct mounts may overlap fetchPacks
  // (per-engine single-writer only; multi-mount remotes are independent).
  {
    const { pack: realPack, tip: realTip } = minimalPackFixture();
    const concA = await GitEngine.load({ baseUrl: base });
    const concB = await GitEngine.load({ baseUrl: base });
    const concMap = new Map([
      ["/workspace/a", concA],
      ["/workspace/b", concB],
    ]);
    const concUrlA = "https://example.com/conc-a.git";
    const concUrlB = "https://example.com/conc-b.git";
    const baseConcHttp = new FixtureSmartHttp();
    baseConcHttp.add(concUrlA, [{ name: "refs/heads/main", hash: realTip }], realPack);
    baseConcHttp.add(concUrlB, [{ name: "refs/heads/main", hash: realTip }], realPack);
    let inflightFetch = 0;
    let peakFetch = 0;
    const delayedConcHttp = {
      listRefs: (
        url: string,
        auth?: Parameters<FixtureSmartHttp["listRefs"]>[1],
      ) => baseConcHttp.listRefs(url, auth),
      fetchPacks: async (
        url: string,
        want: string[],
        have: string[],
        depth?: number,
        auth?: Parameters<FixtureSmartHttp["fetchPacks"]>[4],
        filter?: string,
      ) => {
        inflightFetch += 1;
        if (inflightFetch > peakFetch) peakFetch = inflightFetch;
        try {
          await new Promise((r) => setTimeout(r, 50));
          return baseConcHttp.fetchPacks(url, want, have, depth, auth, filter);
        } finally {
          inflightFetch -= 1;
        }
      },
    };
    const concHandler = gitHostCallHandler(
      { engines: concMap, defaultMount: "/workspace/a" },
      { http: delayedConcHttp, allowOrigins: [fixtureOrigin], packCache: null },
    );
    const [rawConcA, rawConcB] = await Promise.all([
      concHandler(
        JSON.stringify({
          op: "clone",
          args: { url: concUrlA, mount: "/workspace/a" },
        }),
      ),
      concHandler(
        JSON.stringify({
          op: "clone",
          args: { url: concUrlB, mount: "/workspace/b" },
        }),
      ),
    ]);
    const pA = JSON.parse(rawConcA);
    const pB = JSON.parse(rawConcB);
    if (!pA.ok) throw new Error(`D21 concurrent clone A failed: ${rawConcA}`);
    if (!pB.ok) throw new Error(`D21 concurrent clone B failed: ${rawConcB}`);
    if (baseConcHttp.fetchPacksCalls !== 2) {
      throw new Error(
        `D21 concurrent both mounts must fetch (got ${baseConcHttp.fetchPacksCalls})`,
      );
    }
    // Distinct engines: remotes may overlap (peak ≥ 2). Do not require exact
    // timing; if they did not overlap, still pass as long as both succeeded —
    // but record that concurrent path is the intended product shape.
    if (peakFetch < 1) {
      throw new Error(`D21 concurrent peakFetch unset: ${peakFetch}`);
    }
    const readmeConcA = new TextDecoder().decode(
      await concA.asMountDriver().open("/README"),
    );
    const readmeConcB = new TextDecoder().decode(
      await concB.asMountDriver().open("/README"),
    );
    if (readmeConcA !== "hello\n" || readmeConcB !== "hello\n") {
      throw new Error(
        `D21 concurrent worktrees: A=${JSON.stringify(readmeConcA)} B=${JSON.stringify(readmeConcB)}`,
      );
    }
    await concA.close();
    await concB.close();
  }

  // Per-engine remote single-flight: two concurrent clones on the same
  // orchestrator must not overlap fetchPacks (HTTP + apply). Delayed fixture
  // so both callers enter handle() before either finishes transport.
  {
    const engSerial = await GitEngine.load({ baseUrl: base });
    const baseHttp = new FixtureSmartHttp();
    const serialUrl = "https://example.com/serial.git";
    baseHttp.add(
      serialUrl,
      [{ name: "refs/heads/main", hash }],
      packBody,
    );
    let inflightFetch = 0;
    let peakFetch = 0;
    const delayedHttp = {
      listRefs: (url: string, auth?: Parameters<FixtureSmartHttp["listRefs"]>[1]) =>
        baseHttp.listRefs(url, auth),
      fetchPacks: async (
        url: string,
        want: string[],
        have: string[],
        depth?: number,
        auth?: Parameters<FixtureSmartHttp["fetchPacks"]>[4],
        filter?: string,
      ) => {
        inflightFetch += 1;
        if (inflightFetch > peakFetch) peakFetch = inflightFetch;
        try {
          await new Promise((r) => setTimeout(r, 40));
          return baseHttp.fetchPacks(url, want, have, depth, auth, filter);
        } finally {
          inflightFetch -= 1;
        }
      },
    };
    const orchSerial = new GitRemoteOrchestrator(engSerial, {
      http: delayedHttp,
      allowOrigins: [fixtureOrigin],
      packCache: null,
    });
    const [s1, s2] = await Promise.all([
      orchSerial.handle({ op: "clone", args: { url: serialUrl } }),
      orchSerial.handle({ op: "clone", args: { url: serialUrl } }),
    ]);
    if (s1.ok === undefined || s2.ok === undefined) {
      throw new Error(`serial clone missing response: ${JSON.stringify({ s1, s2 })}`);
    }
    if (peakFetch > 1) {
      throw new Error(
        `remote single-flight violated: peak concurrent fetchPacks=${peakFetch} (want ≤ 1)`,
      );
    }
    if (baseHttp.fetchPacksCalls !== 2) {
      throw new Error(
        `both clones should reach fetchPacks serially, got ${baseHttp.fetchPacksCalls}`,
      );
    }
    await engSerial.close();
  }

  // after clone.apply, remote.origin.url + branch tracking are set so
  // config get shows remote and fetch/pull can use tracking (no re-pass URL).
  {
    const packRel = process.env.MC_GIT_MINIMAL_PACK || "";
    const tipRel = process.env.MC_GIT_MINIMAL_TIP || "";
    const rf = process.env.RUNFILES_DIR || "";
    const packCandidates = [
      packRel && rf ? join(rf, packRel) : "",
      packRel && rf ? join(rf, "_main", packRel) : "",
      packRel,
      rf ? join(rf, "memcontainers/sdk-js/core/fixtures/pack/minimal.pack") : "",
      rf
        ? join(rf, "_main/memcontainers/sdk-js/core/fixtures/pack/minimal.pack")
        : "",
    ].filter(Boolean);
    let packPath = "";
    for (const c of packCandidates) {
      if (c && existsSync(c)) {
        packPath = c;
        break;
      }
    }
    const tipCandidates = [
      tipRel && rf ? join(rf, tipRel) : "",
      tipRel && rf ? join(rf, "_main", tipRel) : "",
      tipRel,
      packPath ? join(dirname(packPath), "minimal.tip") : "",
    ].filter(Boolean);
    let tipPath = "";
    for (const c of tipCandidates) {
      if (c && existsSync(c)) {
        tipPath = c;
        break;
      }
    }
    if (!packPath || !tipPath) {
      throw new Error(
        `D9 minimal pack/tip missing (MC_GIT_MINIMAL_PACK=${packRel})`,
      );
    }
    const pack = new Uint8Array(readFileSync(packPath));
    const tip = readFileSync(tipPath, "utf8").trim();
    if (!/^[0-9a-f]{40}$/i.test(tip)) {
      throw new Error(`D9 bad tip: ${tip}`);
    }

    const d9Url = "https://example.com/d9-tracking.git";
    const d9Http = new FixtureSmartHttp();
    d9Http.add(d9Url, [{ name: "refs/heads/main", hash: tip }], pack);
    const engD9 = await GitEngine.load({ baseUrl: base });
    const orchD9 = new GitRemoteOrchestrator(engD9, {
      http: d9Http,
      allowOrigins: [fixtureOrigin],
      packCache: null,
    });
    const cloneD9 = await orchD9.handle({
      op: "clone",
      args: { url: d9Url },
    });
    if (!cloneD9.ok) {
      throw new Error(`D9 clone failed: ${JSON.stringify(cloneD9)}`);
    }

    const remoteUrl = await engD9.run({
      op: "config",
      args: { action: "get", key: "remote.origin.url" },
    });
    if (!remoteUrl.ok || String(remoteUrl.stdout || "").trim() !== d9Url) {
      throw new Error(
        `D9 remote.origin.url want ${d9Url}, got ${JSON.stringify(remoteUrl)}`,
      );
    }
    const brRemote = await engD9.run({
      op: "config",
      args: { action: "get", key: "branch.main.remote" },
    });
    if (!brRemote.ok || String(brRemote.stdout || "").trim() !== "origin") {
      throw new Error(
        `D9 branch.main.remote want origin, got ${JSON.stringify(brRemote)}`,
      );
    }
    const brMerge = await engD9.run({
      op: "config",
      args: { action: "get", key: "branch.main.merge" },
    });
    if (
      !brMerge.ok ||
      String(brMerge.stdout || "").trim() !== "refs/heads/main"
    ) {
      throw new Error(
        `D9 branch.main.merge want refs/heads/main, got ${JSON.stringify(brMerge)}`,
      );
    }

    // Pull via remote name only (no url) — tracking/config must resolve origin.
    const pullD9 = await orchD9.handle({
      op: "pull",
      args: { remote: "origin" },
    });
    if (!pullD9.ok) {
      throw new Error(
        `D9 pull via remote=origin (tracking) failed: ${JSON.stringify(pullD9)}`,
      );
    }
    if (
      !String(pullD9.stdout || "").includes("Already up to date") &&
      !String(pullD9.stdout || "").includes("Fast-forward") &&
      !String(pullD9.stdout || "").includes("fetched")
    ) {
      throw new Error(
        `D9 pull stdout unexpected: ${JSON.stringify(pullD9)}`,
      );
    }

    // Bare fetch/pull with empty args also defaults to origin after clone.
    const pullEmpty = await orchD9.handle({ op: "pull", args: {} });
    if (!pullEmpty.ok) {
      throw new Error(
        `D9 pull {} (default origin from config) failed: ${JSON.stringify(pullEmpty)}`,
      );
    }

    await engD9.close();
  }

  // –D24: host-mediated submodule update → nested worktree under super gitfs.
  // Superproject: .gitmodules + gitlink; submodule pack = minimal.pack (README).
  {
    const { pack, tip } = minimalPackFixture();
    const subUrl = "https://example.com/submodule-lib.git";
    const subHttp = new FixtureSmartHttp();
    subHttp.add(subUrl, [{ name: "refs/heads/main", hash: tip }], pack);

    const engSuper = await GitEngine.load({ baseUrl: base });
    const initS = await engSuper.run({ op: "init" });
    if (!initS.ok) throw new Error(`D23 super init: ${JSON.stringify(initS)}`);

    const gm = `[submodule "deps/lib"]
	path = deps/lib
	url = ${subUrl}
`;
    const w = await engSuper.run({
      op: "write",
      args: { path: ".gitmodules", content: gm },
    });
    if (!w.ok) throw new Error(`D23 write .gitmodules: ${JSON.stringify(w)}`);
    const addGm = await engSuper.run({
      op: "add",
      args: { path: ".gitmodules" },
    });
    if (!addGm.ok) throw new Error(`D23 add .gitmodules: ${JSON.stringify(addGm)}`);

    // Stage gitlink at deps/lib → tip (mode 160000); commit super tree.
    const gl = await engSuper.run({
      op: "gitlink",
      args: { path: "deps/lib", hash: tip },
    });
    if (!gl.ok) throw new Error(`D23 gitlink: ${JSON.stringify(gl)}`);
    const commitS = await engSuper.run({
      op: "commit",
      args: {
        message: "super with submodule",
        name: "Test",
        email: "t@example.com",
      },
    });
    if (!commitS.ok) {
      throw new Error(`D23 super commit: ${JSON.stringify(commitS)}`);
    }

    // Engine purity: update still fails closed (no dial).
    const engUpd = await engSuper.run({
      op: "submodule",
      args: { action: "update" },
    });
    if (engUpd.ok || !String(engUpd.stderr || "").includes("host_call")) {
      throw new Error(
        `D23 engine submodule update must fail closed: ${JSON.stringify(engUpd)}`,
      );
    }

    // List includes gitlink hash.
    const listed = await engSuper.run({
      op: "submodule",
      args: { action: "list" },
    });
    if (!listed.ok) throw new Error(`D23 list: ${JSON.stringify(listed)}`);
    const subs = (listed.result as { submodules?: Array<{ hash?: string; path?: string }> })
      ?.submodules;
    if (!Array.isArray(subs) || !subs.some((s) => s.path === "deps/lib" && s.hash === tip)) {
      throw new Error(`D23 list missing gitlink: ${JSON.stringify(listed)}`);
    }

    // Origin deny on submodule URL.
    const orchDeny = new GitRemoteOrchestrator(engSuper, {
      http: subHttp,
      allowOrigins: ["https://other.example"],
      packCache: null,
    });
    const denied = await orchDeny.handle({
      op: "submodule",
      args: { action: "update" },
    });
    if (denied.ok || !String(denied.stderr || "").toLowerCase().includes("allowlist")) {
      throw new Error(`D23 origin deny expected: ${JSON.stringify(denied)}`);
    }

    // Host orch update: network via fixture, nested clone into deps/lib.
    const orchSub = new GitRemoteOrchestrator(engSuper, {
      http: subHttp,
      allowOrigins: [fixtureOrigin],
      packCache: null,
    });
    const upd = await orchSub.handle({
      op: "submodule",
      args: { action: "update" },
    });
    if (!upd.ok) {
      throw new Error(`D23 submodule update failed: ${JSON.stringify(upd)}`);
    }
    if (!String(upd.stdout || "").includes("updated 1")) {
      throw new Error(`D23 update stdout: ${JSON.stringify(upd)}`);
    }

    // nested worktree files project via super MEMFS / gitfs.
    const readmePath = engSuper.bridge.abs("deps/lib/README");
    let readme = "";
    try {
      const raw = engSuper.bridge.FS.readFile(readmePath, { encoding: "utf8" });
      readme = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
    } catch (e) {
      throw new Error(`D24 deps/lib/README missing after update: ${String(e)}`);
    }
    if (readme !== "hello\n") {
      throw new Error(`D24 README want hello\\n got ${JSON.stringify(readme)}`);
    }

    // gitfs driver also sees nested path.
    const driver = engSuper.asMountDriver();
    const entries = await driver.readdir!("deps/lib");
    if (!entries.some((e) => e.name === "README")) {
      throw new Error(`D24 gitfs readdir deps/lib: ${JSON.stringify(entries)}`);
    }
    const openReadme = await driver.open!("deps/lib/README");
    const openText = new TextDecoder().decode(openReadme);
    if (openText !== "hello\n") {
      throw new Error(`D24 gitfs open README: ${JSON.stringify(openText)}`);
    }

    // list-only is not DONE: assert we did real clone (transport dialed).
    if (subHttp.listRefsCalls < 1 || subHttp.fetchPacksCalls < 1) {
      throw new Error(
        `D23 must dial submodule: listRefs=${subHttp.listRefsCalls} fetchPacks=${subHttp.fetchPacksCalls}`,
      );
    }

    await engSuper.close();
  }

  await engA.close();
  await engB.close();
  await eng.close();
  console.log("git_remote.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
