/**
 * Residuals R1 / R3 / R8 — strongest hermetic JS guest git e2e.
 *
 * R8: mc.create + experimentalGitEngine + gitfs ctl close-then-status (commit via /bin/git).
 * R3: guest without CAP_NET → host_call "git" fails closed (EPERM / clear error).
 * R1: guest with CAP_NET + /bin/git clone → MapHostCall "git" → FixtureSmartHttp → worktree.
 *
 * No external network: FixtureSmartHttp + minimal.pack only.
 * Full guest /bin/git is on loom (git_layer). Remotes remain experimental.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { FixtureSmartHttp } from "../src/git/index.js";
import type { SmartHttpTransport } from "../src/git/smart-http.js";
import { mc } from "../src/memcontainer.js";
import type { CreateOptions, ImageManifest } from "../src/types.js";
import { MemoryContentStore } from "../src/store.js";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

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

function packFixture(): { pack: Uint8Array; tip: string; url: string; origin: string } {
  const packRel = process.env.MC_GIT_MINIMAL_PACK;
  const tipRel = process.env.MC_GIT_MINIMAL_TIP;
  const rf = process.env.RUNFILES_DIR || "";
  const candidates = (rel: string | undefined) =>
    [
      rel && rf ? join(rf, rel) : "",
      rel && rf ? join(rf, "_main", rel) : "",
      rel || "",
      // genrule outs under this package
      rf ? join(rf, "memcontainers/sdk-js/core/testdata/pack/minimal.pack") : "",
      rf ? join(rf, "_main/memcontainers/sdk-js/core/testdata/pack/minimal.pack") : "",
    ].filter(Boolean);

  let packPath = "";
  for (const c of candidates(packRel)) {
    if (c.endsWith(".pack") && existsSync(c)) {
      packPath = c;
      break;
    }
    if (existsSync(join(c, "minimal.pack"))) {
      packPath = join(c, "minimal.pack");
      break;
    }
  }
  // tip siblings of pack
  const tipCandidates = [
    tipRel && rf ? join(rf, tipRel) : "",
    tipRel && rf ? join(rf, "_main", tipRel) : "",
    tipRel || "",
    packPath ? join(dirname(packPath), "minimal.tip") : "",
    rf ? join(rf, "memcontainers/sdk-js/core/testdata/pack/minimal.tip") : "",
    rf ? join(rf, "_main/memcontainers/sdk-js/core/testdata/pack/minimal.tip") : "",
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
  const pack = new Uint8Array(readFileSync(packPath));
  const tip = readFileSync(tipPath, "utf8").trim();
  if (!/^[0-9a-f]{40}$/i.test(tip)) {
    throw new Error(`invalid tip oid: ${JSON.stringify(tip)}`);
  }
  return {
    pack,
    tip,
    url: "https://example.com/demo.git",
    origin: "https://example.com",
  };
}

function gitEngineBaseUrl(): string {
  const dir = engineDir();
  return pathToFileURL(dir.endsWith("/") ? dir : dir + "/").href;
}

async function main(): Promise<void> {
  const kernel = new Uint8Array(
    readFileSync(runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM")),
  );
  const loom = new Uint8Array(
    readFileSync(runfile(process.env.MC_LOOM_IMAGE, "MC_LOOM_IMAGE")),
  );
  const baseUrl = gitEngineBaseUrl();
  const fixture = packFixture();

  // ── R8: mc.create + experimentalGitEngine + gitfs ctl close-then-status ──
  // Thin /bin/git writes Request, closes fd, re-opens ctl for Response (never close-only).
  console.log("phase: R8 gitfs ctl close-then-status via /bin/git");
  {
    const vm = await mc.create({
      kernel,
      image: loom,
      deterministic: true,
      experimentalGitEngine: true,
      gitEngineBaseUrl: baseUrl,
      gitIdentity: { name: "Guest E2E", email: "e2e@example.com" },
    } satisfies CreateOptions);
    try {
      // Default mount present
      await vm.fs.stat("/workspace/repo/.git/mc/ctl");
      await vm.fs.stat("/bin/git");

      const ver = await vm.exec("git version");
      if (ver.exitCode !== 0 || !ver.stdout.includes("agentos-git")) {
        throw new Error(`git version failed: ${JSON.stringify(ver)}`);
      }

      // Local porcelain via ctl (close-then-status inside /bin/git).
      // Note: control-channel ExecRequest.cwd cannot target a host mount path
      // synchronously (WouldBlock/EAGAIN on mount stat). Guest shell `cd` is
      // fine — chdir runs under the tick pump that drains mount ops.
      const init = await vm.exec("cd /workspace/repo && git init");
      if (init.exitCode !== 0) {
        throw new Error(`git init: exit=${init.exitCode} stderr=${init.stderr} stdout=${init.stdout}`);
      }

      // Worktree write through guest VFS → gitfs driver
      await vm.fs.write("/workspace/repo/hello.txt", "hello-e2e\n");
      const add = await vm.exec("cd /workspace/repo && git add hello.txt");
      if (add.exitCode !== 0) {
        throw new Error(`git add: exit=${add.exitCode} stderr=${add.stderr} stdout=${add.stdout}`);
      }

      const commit = await vm.exec('cd /workspace/repo && git commit -m "r8-e2e"');
      if (commit.exitCode !== 0) {
        throw new Error(
          `git commit (ctl close-then-status): exit=${commit.exitCode} stderr=${commit.stderr} stdout=${commit.stdout}`,
        );
      }

      const status = await vm.exec("cd /workspace/repo && git status");
      if (status.exitCode !== 0) {
        throw new Error(
          `git status: exit=${status.exitCode} stderr=${status.stderr} stdout=${status.stdout}`,
        );
      }

      // Host-side ctl round-trip also drains Response after write (MountFs close semantics)
      await vm.fs.write(
        "/workspace/repo/.git/mc/ctl",
        JSON.stringify({ op: "status", args: { short: true } }),
      );
      const ctlRaw = await vm.fs.readText("/workspace/repo/.git/mc/ctl");
      const ctlResp = JSON.parse(ctlRaw) as { ok?: boolean; stderr?: string };
      if (!ctlResp.ok) {
        throw new Error(`ctl status after host fs write: ${ctlRaw}`);
      }

      // Remotes via ctl fail closed (host_call only)
      await vm.fs.write(
        "/workspace/repo/.git/mc/ctl",
        JSON.stringify({ op: "fetch" }),
      );
      const refuseRaw = await vm.fs.readText("/workspace/repo/.git/mc/out/last");
      const refuse = JSON.parse(refuseRaw) as { ok?: boolean; stderr?: string };
      if (refuse.ok || !String(refuse.stderr || "").includes("host_call")) {
        throw new Error(`ctl fetch must refuse remotes: ${refuseRaw}`);
      }

      console.log("phase: R8 OK");
    } finally {
      await vm.close();
    }
  }

  // ── R3: without CAP_NET, remote host_call fails closed ──
  // Boot image at read-write tier (no CAP_NET). /bin/git clone → EPERM path.
  console.log("phase: R3 CAP_NET deny (boot tier read-write)");
  {
    const store = new MemoryContentStore();
    const dig = await store.put(loom);
    const noNetImage: ImageManifest = {
      schema: 1,
      layers: [{ digest: dig, size: loom.byteLength }],
      config: { tier: "read-write" },
    };
    const http = new FixtureSmartHttp();
    http.add(fixture.url, [{ name: "refs/heads/main", hash: fixture.tip }], fixture.pack);

    const vm = await mc.create({
      kernel,
      image: noNetImage,
      store,
      deterministic: true,
      experimentalGitEngine: true,
      gitEngineBaseUrl: baseUrl,
      gitHttp: http,
      gitAllowOrigins: [fixture.origin],
    } satisfies CreateOptions);
    try {
      await vm.fs.stat("/bin/git");
      // Direct argv spawn (not shell): host-control inherits pid-1 read-write caps
      // (no CAP_NET, no CAP_SPAWN). Binary is full-tier but caps only narrow — so
      // /bin/git runs and host_call fails closed. Shell `git clone` would fail
      // earlier at CAP_SPAWN ("Permission denied") and never reach host_call.
      const denied = await vm.run("git", ["clone", fixture.url]);
      // Thin CLI prints a stable fail-closed message on host_call EPERM.
      // Exit code should be non-zero; also accept the stderr marker alone if the
      // control channel ever reports a soft zero (kernel exit-status path).
      const msg = `${denied.stderr}\n${denied.stdout}`;
      const deniedMsg =
        msg.includes("CAP_NET") || msg.includes("host_call") || msg.includes("EPERM");
      if (!deniedMsg) {
        throw new Error(
          `R3: expected CAP_NET/host_call/EPERM error, got: ${JSON.stringify(denied)}`,
        );
      }
      if (denied.exitCode === 0 && !msg.includes("host_call git failed")) {
        throw new Error(
          `R3: git clone without CAP_NET must fail, got: ${JSON.stringify(denied)}`,
        );
      }
      if (http.listRefsCalls !== 0 || http.fetchPacksCalls !== 0) {
        throw new Error(
          `R3: host_call must not reach FixtureSmartHttp without CAP_NET (listRefs=${http.listRefsCalls} fetchPacks=${http.fetchPacksCalls})`,
        );
      }
      console.log(
        `phase: R3 boot-tier deny OK (exit=${denied.exitCode}, stderr marker present)`,
      );
    } finally {
      await vm.close();
    }
  }

  // R3b: full-tier parent spawns read-only child; sys.host.call("git") must not dial.
  // Hard gate: FixtureSmartHttp call counters stay at 0. Boot-tier test above covers
  // the guest-visible error string from /bin/git.
  console.log("phase: R3 CAP_NET deny (spawn read-only child)");
  {
    const http = new FixtureSmartHttp();
    http.add(fixture.url, [{ name: "refs/heads/main", hash: fixture.tip }], fixture.pack);
    const vm = await mc.create({
      kernel,
      image: loom,
      deterministic: true,
      experimentalGitEngine: true,
      gitEngineBaseUrl: baseUrl,
      gitHttp: http,
      gitAllowOrigins: [fixture.origin],
    } satisfies CreateOptions);
    try {
      const child = [
        'local sys = require("sys")',
        `local body = [[{"op":"clone","args":{"url":"${fixture.url}"}}]]`,
        'local raw, err = sys.host.call("git", body)',
        // Print so shared stdout (if any) is informative; EPERM → nil, "EPERM"
        'print("raw", tostring(raw))',
        'print("err", tostring(err))',
      ].join("\n");
      await vm.fs.write("/tmp/git-deny-child.luau", child);
      const parent = [
        'local sys = require("sys")',
        'local pid = assert(sys.proc.spawn({ argv = { "luau", "/tmp/git-deny-child.luau" }, tier = "read-only" }))',
        "local status = assert(sys.proc.wait(pid))",
        'print("child_status", status)',
      ].join("\n");
      await vm.fs.write("/tmp/git-deny-parent.luau", parent);

      const callsBefore = http.listRefsCalls;
      const out = await vm.exec("luau /tmp/git-deny-parent.luau");
      if (out.exitCode !== 0) {
        throw new Error(
          `R3b parent script failed: exit=${out.exitCode} stdout=${out.stdout} stderr=${out.stderr}`,
        );
      }
      if (http.listRefsCalls !== callsBefore || http.fetchPacksCalls !== 0) {
        throw new Error(
          `R3b: read-only child must not reach FixtureSmartHttp (listRefs=${http.listRefsCalls} fetchPacks=${http.fetchPacksCalls})`,
        );
      }
      console.log("phase: R3 spawn-child deny OK (no transport dial)");
    } finally {
      await vm.close();
    }
  }

  // ── R1: full guest CAP_NET + /bin/git clone via fixture smart-HTTP ──
  console.log("phase: R1 guest CAP_NET + /bin/git clone (fixture pack)");
  {
    const http = new FixtureSmartHttp();
    http.add(fixture.url, [{ name: "refs/heads/main", hash: fixture.tip }], fixture.pack);

    const vm = await mc.create({
      kernel,
      image: loom,
      deterministic: true,
      net: true,
      experimentalGitEngine: true,
      gitEngineBaseUrl: baseUrl,
      gitHttp: http,
      gitAllowOrigins: [fixture.origin],
      gitIdentity: { name: "Guest E2E", email: "e2e@example.com" },
    } satisfies CreateOptions);
    try {
      await vm.fs.stat("/bin/git");
      await vm.fs.stat("/workspace/repo/.git/mc/ctl");

      // Positive CAP_NET: host_call "git" through thin CLI
      const clone = await vm.exec(`git clone ${fixture.url}`);
      if (clone.exitCode !== 0) {
        throw new Error(
          `R1 git clone failed: exit=${clone.exitCode} stdout=${JSON.stringify(clone.stdout)} stderr=${JSON.stringify(clone.stderr)}`,
        );
      }
      if (!clone.stdout.includes("cloned") && !String(clone.stdout + clone.stderr).includes("cloned")) {
        // orch returns stdout "cloned …"; thin CLI prints Response stdout
        throw new Error(`R1 expected cloned in output: ${JSON.stringify(clone)}`);
      }
      if (http.listRefsCalls < 1 || http.fetchPacksCalls < 1) {
        throw new Error(
          `R1 fixture transport not used: listRefs=${http.listRefsCalls} fetchPacks=${http.fetchPacksCalls}`,
        );
      }

      // Worktree materialised on default gitfs mount after clone.apply
      const entries = await vm.fs.ls("/workspace/repo");
      if (!entries.some((e) => e.name === ".git")) {
        throw new Error(`R1 worktree missing .git after clone: ${JSON.stringify(entries)}`);
      }

      // Full-tier luau host_call "git" (same MapHostCall path as thin CLI remotes)
      const luauFetch = await vm.luau(
        `local sys = require("sys")
local body = [[{"op":"fetch","args":{"url":"${fixture.url}"}}]]
local raw, err = sys.host.call("git", body)
if err then error("host_call git failed: " .. tostring(err)) end
print(raw)
`,
      );
      if (luauFetch.exitCode !== 0) {
        throw new Error(
          `R1 luau host_call fetch: exit=${luauFetch.exitCode} stdout=${luauFetch.stdout} stderr=${luauFetch.stderr}`,
        );
      }
      if (!luauFetch.stdout.includes('"ok"')) {
        throw new Error(`R1 luau host_call expected Response JSON: ${luauFetch.stdout}`);
      }

      console.log("phase: R1 OK");
    } finally {
      await vm.close();
    }
  }

  // ── D17: snapshot/restore rebinds git durable (K10) ──
  // MCSN does not carry ODB. gitDurable id is recorded; snapshot checkpoints
  // process MemoryDurable (openDurable registry by id); restore reopens + rebinds AGIT.
  // HostDir diskDir path is D16 primary; process-memory proves D17 lifecycle wiring.
  console.log("phase: D17 snapshot/restore rebinds git durable");
  {
    const durableId = `d17-guest-${Date.now()}`;
    const createOpts = {
      kernel,
      image: loom,
      deterministic: true,
      experimentalGitEngine: true,
      gitEngineBaseUrl: baseUrl,
      gitIdentity: { name: "D17", email: "d17@example.com" },
      // No diskDir → openDurable MemoryDurable process registry (same id reopens).
      gitDurable: { id: durableId },
    } satisfies CreateOptions;

    const headOid = async (vm: Awaited<ReturnType<typeof mc.create>>): Promise<string> => {
      // Prefer ctl result (engine JSON); fall back to thin CLI stdout.
      await vm.fs.write(
        "/workspace/repo/.git/mc/ctl",
        JSON.stringify({ op: "rev-parse", args: { rev: "HEAD" } }),
      );
      const raw = await vm.fs.readText("/workspace/repo/.git/mc/ctl");
      let oid = "";
      try {
        const resp = JSON.parse(raw) as {
          ok?: boolean;
          stdout?: string;
          result?: unknown;
        };
        if (resp.ok) {
          const fromOut = String(resp.stdout || "")
            .trim()
            .split(/\s+/)[0];
          if (fromOut && /^[0-9a-f]{40}$/i.test(fromOut)) oid = fromOut;
          if (!oid && typeof resp.result === "string" && /^[0-9a-f]{40}$/i.test(resp.result)) {
            oid = resp.result;
          }
        }
      } catch {
        /* fall through */
      }
      if (!oid) {
        const rev = await vm.exec("cd /workspace/repo && git rev-parse HEAD");
        oid = rev.stdout.trim().split(/\s+/)[0] ?? "";
        if (!/^[0-9a-f]{40}$/i.test(oid)) {
          throw new Error(
            `D17 rev-parse failed: ctl=${raw} cli=${JSON.stringify(rev)}`,
          );
        }
      }
      return oid.toLowerCase();
    };

    const vm = await mc.create(createOpts);
    let headBefore = "";
    let snap: Uint8Array;
    try {
      // Local porcelain via ctl with explicit K28 identity (gitfs does not inject).
      const init = await vm.exec("cd /workspace/repo && git init");
      if (init.exitCode !== 0) {
        throw new Error(`D17 init: ${JSON.stringify(init)}`);
      }
      await vm.fs.write("/workspace/repo/d17.txt", "durable-snapshot-rebind\n");
      const add = await vm.exec("cd /workspace/repo && git add d17.txt");
      if (add.exitCode !== 0) {
        throw new Error(`D17 add: ${JSON.stringify(add)}`);
      }
      await vm.fs.write(
        "/workspace/repo/.git/mc/ctl",
        JSON.stringify({
          op: "commit",
          args: {
            message: "d17-checkpoint",
            name: "D17",
            email: "d17@example.com",
            when_unix: 1_700_000_100,
          },
        }),
      );
      const commitRaw = await vm.fs.readText("/workspace/repo/.git/mc/ctl");
      const commitResp = JSON.parse(commitRaw) as { ok?: boolean; stderr?: string };
      if (!commitResp.ok) {
        throw new Error(`D17 commit ctl: ${commitRaw}`);
      }
      headBefore = await headOid(vm);

      // Snapshot checkpoints AGIT into process MemoryDurable(id:mount).
      snap = await vm.snapshot();
      if (!snap || snap.byteLength < 16) {
        throw new Error("D17 MCSN snapshot empty");
      }
    } finally {
      await vm.close();
    }

    // Fresh VM from MCSN + same gitDurable id → AGIT rebind.
    const restored = await mc.restore(snap!, createOpts);
    try {
      const headAfter = await headOid(restored);
      if (headAfter !== headBefore) {
        throw new Error(
          `D17 FAIL: HEAD after restore ${headAfter} !== before ${headBefore}`,
        );
      }
      const body = await restored.fs.readText("/workspace/repo/d17.txt");
      if (!body.includes("durable-snapshot-rebind")) {
        throw new Error(`D17 FAIL: worktree missing after rebind: ${JSON.stringify(body)}`);
      }

      // Fork also rebinds via same durable id (fork = snapshot + restore).
      const child = await restored.fork();
      try {
        const headFork = await headOid(child);
        if (headFork !== headBefore) {
          throw new Error(`D17 FAIL: fork HEAD ${headFork} !== ${headBefore}`);
        }
        const bodyFork = await child.fs.readText("/workspace/repo/d17.txt");
        if (!bodyFork.includes("durable-snapshot-rebind")) {
          throw new Error(`D17 FAIL: fork worktree missing: ${JSON.stringify(bodyFork)}`);
        }
      } finally {
        await child.close();
      }
      console.log("phase: D17 OK (snapshot+restore+fork rebind git durable)");
    } finally {
      await restored.close();
    }
  }

  // ── D19: snapshot refused while guest git host_call remote is inflight ──
  // Slow fixture listRefs keeps MapHostCall "git" slot open → kernel inflight_egress
  // > 0 → vm.snapshot() throws. Silent mid-clone snapshot is FAIL.
  console.log("phase: D19 snapshot blocked during slow host_call clone");
  {
    const baseHttp = new FixtureSmartHttp();
    baseHttp.add(fixture.url, [{ name: "refs/heads/main", hash: fixture.tip }], fixture.pack);
    const holdMs = 800;
    // Gate: listRefs blocks until we release after observing inflight + refused snapshot.
    let releaseListRefs!: () => void;
    const listRefsHold = new Promise<void>((resolve) => {
      releaseListRefs = resolve;
    });
    // Failsafe so a stuck test cannot hang forever.
    const failsafe = setTimeout(() => releaseListRefs(), holdMs + 5_000);
    const slowHttp: SmartHttpTransport = {
      async listRefs(url, auth) {
        await listRefsHold;
        return baseHttp.listRefs(url, auth);
      },
      fetchPacks: (url, want, have, depth, auth, filter) =>
        baseHttp.fetchPacks(url, want, have, depth, auth, filter),
      pushPacks: (url, commands, pack, auth) =>
        baseHttp.pushPacks(url, commands, pack, auth),
    };

    const vm = await mc.create({
      kernel,
      image: loom,
      deterministic: true,
      net: true,
      experimentalGitEngine: true,
      gitEngineBaseUrl: baseUrl,
      gitHttp: slowHttp,
      gitAllowOrigins: [fixture.origin],
      gitIdentity: { name: "Guest E2E", email: "e2e@example.com" },
    } satisfies CreateOptions);
    try {
      // Quiescent baseline
      await vm.snapshot();
      if ((await vm.inflightEgress()) !== 0) {
        throw new Error("D19: expected zero inflight before clone");
      }

      // Race: start clone without await; host_call stays open until listRefs releases.
      const clonePromise = vm.exec(`git clone ${fixture.url}`);

      // Wait until the guest has opened host_call (kernel egress elevated).
      let sawInflight = false;
      const deadline = Date.now() + 10_000;
      while (Date.now() < deadline) {
        if ((await vm.inflightEgress()) > 0) {
          sawInflight = true;
          break;
        }
        await new Promise((r) => setTimeout(r, 10));
      }
      if (!sawInflight) {
        releaseListRefs();
        clearTimeout(failsafe);
        const clone = await clonePromise;
        throw new Error(
          `D19 FAIL: never saw inflight egress during clone (exit=${clone.exitCode} stderr=${clone.stderr})`,
        );
      }

      let snapErr: unknown;
      try {
        await vm.snapshot();
      } catch (e) {
        snapErr = e;
      }
      if (!snapErr) {
        releaseListRefs();
        clearTimeout(failsafe);
        throw new Error("D19 FAIL: silent snapshot during inflight git host_call");
      }
      const msg = String(snapErr);
      if (!msg.includes("host-egress") && !msg.includes("in flight") && !msg.includes("quiesce")) {
        releaseListRefs();
        clearTimeout(failsafe);
        throw new Error(`D19 unexpected snapshot error: ${msg}`);
      }

      // Release remote; clone should finish; snapshot works again.
      releaseListRefs();
      clearTimeout(failsafe);
      const clone = await clonePromise;
      if (clone.exitCode !== 0) {
        throw new Error(
          `D19 clone failed after release: exit=${clone.exitCode} stdout=${clone.stdout} stderr=${clone.stderr}`,
        );
      }
      if ((await vm.inflightEgress()) !== 0) {
        throw new Error("D19: inflight must drain after clone completes");
      }
      await vm.snapshot();
      console.log("phase: D19 OK (snapshot refused mid-clone host_call)");
    } finally {
      releaseListRefs();
      clearTimeout(failsafe);
      await vm.close();
    }
  }

  console.log("git_guest_e2e.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
