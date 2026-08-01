/**
 * PR3–PR5: GitEngine.run + gitfs ctl drain + dial refuse (no full VM).
 * Requires MC_GIT_ENGINE_JS → runfiles path of git_engine.js (sibling of .wasm).
 */

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  decodeDurableBlob,
  GitEngine,
  MemoryDurable,
} from "../src/git/index.js";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) {
    throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  }
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

function engineDir(): string {
  const jsRel = process.env.MC_GIT_ENGINE_JS || process.env.MC_GIT_ENGINE_DIR || "";
  const candidates: string[] = [];
  if (jsRel) {
    try {
      candidates.push(runfile(jsRel, "MC_GIT_ENGINE_JS"));
    } catch {
      /* fall through to local candidates */
    }
    candidates.push(jsRel);
    if (process.env.RUNFILES_DIR) {
      candidates.push(join(process.env.RUNFILES_DIR, "_main", jsRel));
    }
  }
  candidates.push(
    join(process.cwd(), "bazel-bin/memcontainers/lib/git-engine/git_engine.js"),
  );
  if (process.env.RUNFILES_DIR) {
    candidates.push(
      join(
        process.env.RUNFILES_DIR,
        "_main/memcontainers/lib/git-engine/git_engine.js",
      ),
    );
  }

  for (const c of candidates) {
    if (!c) continue;
    // Accept engine module path (.mjs/.js) or a directory containing it.
    if ((c.endsWith(".mjs") || c.endsWith(".js")) && existsSync(c)) {
      return dirname(c);
    }
    if (
      existsSync(join(c, "git_engine.mjs")) ||
      existsSync(join(c, "git_engine.js"))
    ) {
      return c;
    }
  }
  throw new Error(
    `MC_GIT_ENGINE_JS must resolve to git_engine.mjs/js (got ${JSON.stringify(jsRel)})`,
  );
}

function baseUrl(dir: string): string {
  return pathToFileURL(dir.endsWith("/") ? dir : dir + "/").href;
}

async function main() {
  const dir = engineDir();
  const eng = await GitEngine.load({ baseUrl: baseUrl(dir) });

  let r = await eng.run({ op: "init" });
  if (!r.ok) throw new Error(`init: ${JSON.stringify(r)}`);

  r = await eng.run({
    op: "write",
    args: { path: "hello.txt", content: "from sdk\n" },
  });
  if (!r.ok) throw new Error(`write: ${JSON.stringify(r)}`);

  r = await eng.run({ op: "add", args: { path: "hello.txt" } });
  if (!r.ok) throw new Error(`add: ${JSON.stringify(r)}`);

  r = await eng.run({
    op: "commit",
    args: {
      message: "sdk commit",
      name: "Sdk",
      email: "sdk@test",
      when_unix: 1_700_000_000,
    },
  });
  if (!r.ok) throw new Error(`commit: ${JSON.stringify(r)}`);

  // R27: host identity inject — commit without name/email succeeds when configured.
  // Never invents Agent@example.com when identity is unset (covered by engine K28).
  const engId = await GitEngine.load({
    baseUrl: baseUrl(dir),
    gitIdentity: { name: "Host Policy", email: "host@policy.test" },
  });
  let ir = await engId.run({ op: "init" });
  if (!ir.ok) throw new Error(`id init: ${JSON.stringify(ir)}`);
  ir = await engId.run({
    op: "write",
    args: { path: "id.txt", content: "id\n" },
  });
  if (!ir.ok) throw new Error(`id write: ${JSON.stringify(ir)}`);
  ir = await engId.run({ op: "add", args: { path: "id.txt" } });
  if (!ir.ok) throw new Error(`id add: ${JSON.stringify(ir)}`);
  ir = await engId.run({
    op: "commit",
    args: { message: "injected identity", when_unix: 1_700_000_001 },
  });
  if (!ir.ok) {
    throw new Error(`identity inject commit failed: ${JSON.stringify(ir)}`);
  }
  // Without identity, missing name/email still fails closed (no invented author).
  const engNoId = await GitEngine.load({ baseUrl: baseUrl(dir) });
  await engNoId.run({ op: "init" });
  await engNoId.run({
    op: "write",
    args: { path: "x.txt", content: "x\n" },
  });
  await engNoId.run({ op: "add", args: { path: "x.txt" } });
  const noId = await engNoId.run({
    op: "commit",
    args: { message: "no identity" },
  });
  if (noId.ok || !String(noId.stderr || "").includes("name and email")) {
    throw new Error(`commit without identity must fail K28: ${JSON.stringify(noId)}`);
  }
  // R34 helper: reset mode ff-only fails on divergent history.
  const c1 = await engNoId.run({
    op: "commit",
    args: {
      message: "c1",
      name: "T",
      email: "t@t",
      when_unix: 1_700_000_010,
    },
  });
  if (!c1.ok) throw new Error(`c1: ${JSON.stringify(c1)}`);
  const head1 = (await engNoId.run({ op: "rev-parse", args: { rev: "HEAD" } }))
    .stdout!.trim()
    .split(/\s+/)[0];
  await engNoId.run({
    op: "write",
    args: { path: "a.txt", content: "a\n" },
  });
  await engNoId.run({ op: "add", args: { path: "a.txt" } });
  await engNoId.run({
    op: "commit",
    args: {
      message: "c2",
      name: "T",
      email: "t@t",
      when_unix: 1_700_000_011,
    },
  });
  const head2 = (await engNoId.run({ op: "rev-parse", args: { rev: "HEAD" } }))
    .stdout!.trim()
    .split(/\s+/)[0];
  // Reset to c1 then diverge
  let rr = await engNoId.run({
    op: "reset",
    args: { rev: head1, mode: "hard" },
  });
  if (!rr.ok) throw new Error(`reset hard: ${JSON.stringify(rr)}`);
  await engNoId.run({
    op: "write",
    args: { path: "b.txt", content: "b\n" },
  });
  await engNoId.run({ op: "add", args: { path: "b.txt" } });
  await engNoId.run({
    op: "commit",
    args: {
      message: "c3",
      name: "T",
      email: "t@t",
      when_unix: 1_700_000_012,
    },
  });
  rr = await engNoId.run({
    op: "reset",
    args: { rev: head2, mode: "ff-only" },
  });
  if (rr.ok || !String(rr.stderr || "").includes("not fast-forward")) {
    throw new Error(`ff-only on diverge must fail: ${JSON.stringify(rr)}`);
  }
  // FF to self / ancestor tip should succeed (reset back to c3's parent path: use HEAD)
  const head3 = (await engNoId.run({ op: "rev-parse", args: { rev: "HEAD" } }))
    .stdout!.trim()
    .split(/\s+/)[0];
  rr = await engNoId.run({
    op: "reset",
    args: { rev: head3, mode: "ff-only" },
  });
  if (!rr.ok) throw new Error(`ff-only same tip: ${JSON.stringify(rr)}`);
  await engId.close();
  await engNoId.close();

  const dial = await eng.run({
    op: "clone",
    args: { url: "https://example.com/r.git" },
  });
  if (dial.ok || !String(dial.stderr || "").includes("orchestrator")) {
    throw new Error(`dial should fail closed: ${JSON.stringify(dial)}`);
  }

  // PR4/PR5: gitfs worktree + synthetic .git + ctl drain
  const driver = eng.asMountDriver();
  // R66/R63: brand for K21 one-engine-per-path (multi-path allowed)
  const { isGitFsDriver } = await import("../src/git/gitfs.js");
  if (!isGitFsDriver(driver)) {
    throw new Error("asMountDriver must brand gitfs driver (K21)");
  }
  const driver2 = eng.asMountDriver();
  if (!isGitFsDriver(driver2)) {
    throw new Error("second asMountDriver must also brand gitfs");
  }

  const rootEntries = await driver.readdir("/");
  if (!rootEntries.some((e) => e.name === ".git" && e.kind === "dir")) {
    throw new Error(`readdir / missing .git: ${JSON.stringify(rootEntries)}`);
  }
  const gitEntries = await driver.readdir("/.git");
  for (const need of ["HEAD", "mc", "refs"]) {
    if (!gitEntries.some((e) => e.name === need)) {
      throw new Error(`readdir /.git missing ${need}: ${JSON.stringify(gitEntries)}`);
    }
  }
  // K17: no `.git/objects` façade — not listed; open/stat → ENOENT (host ODB not projected).
  if (gitEntries.some((e) => e.name === "objects")) {
    throw new Error(
      `readdir /.git must not list objects (K17): ${JSON.stringify(gitEntries)}`,
    );
  }
  for (const objectsPath of [
    "/.git/objects",
    "/.git/objects/pack",
    // Path aliases must not bypass K17 (V2: . and empty segments).
    "/.git/./objects",
    "/.git//objects",
    "/.git/./objects/pack",
  ]) {
    try {
      await driver.stat(objectsPath);
      throw new Error(`stat ${objectsPath} must ENOENT (K17)`);
    } catch (e) {
      if ((e as { code?: string }).code !== "ENOENT") {
        throw new Error(
          `stat ${objectsPath} expected ENOENT, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
    try {
      await driver.open(objectsPath);
      throw new Error(`open ${objectsPath} must ENOENT (K17)`);
    } catch (e) {
      if ((e as { code?: string }).code !== "ENOENT") {
        throw new Error(
          `open ${objectsPath} expected ENOENT, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
  }
  for (const objectsDir of ["/.git/objects", "/.git/./objects", "/.git//objects"]) {
    try {
      await driver.readdir(objectsDir);
      throw new Error(`readdir ${objectsDir} must ENOENT (K17)`);
    } catch (e) {
      if ((e as { code?: string }).code !== "ENOENT") {
        throw new Error(
          `readdir ${objectsDir} expected ENOENT, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
  }
  const head = new TextDecoder().decode(await driver.open("/.git/HEAD"));
  if (!head.startsWith("ref: refs/heads/")) {
    throw new Error(`synthetic HEAD: ${JSON.stringify(head)}`);
  }
  // R23: after checkout, synthetic HEAD tracks the branch (not hard-coded master).
  await eng.run({ op: "branch", args: { name: "feature-head" } });
  await eng.run({ op: "checkout", args: { name: "feature-head" } });
  const headFeature = new TextDecoder().decode(await driver.open("/.git/HEAD"));
  if (headFeature.trim() !== "ref: refs/heads/feature-head") {
    throw new Error(`synthetic HEAD after checkout: ${JSON.stringify(headFeature)}`);
  }

  // Ctl protocol: write Request → open/read Response (MountFs drain; never close-only)
  await driver.write!(
    "/.git/mc/ctl",
    new TextEncoder().encode(
      JSON.stringify({
        op: "status",
        args: { short: true },
      }),
    ),
  );
  const respBytes = await driver.open("/.git/mc/ctl");
  const resp = JSON.parse(new TextDecoder().decode(respBytes));
  if (!resp.ok) throw new Error(`ctl status: ${JSON.stringify(resp)}`);

  const genBefore = new TextDecoder().decode(
    await driver.open("/.git/mc/generation"),
  );
  // Coherence: worktree write via driver then status via Run (single-writer)
  await driver.write!(
    "/note.txt",
    new TextEncoder().encode("note\n"),
  );
  await eng.run({ op: "add", args: { path: "note.txt" } });
  const st = await eng.run({ op: "status", args: { short: true } });
  if (!st.ok) throw new Error(`status: ${JSON.stringify(st)}`);
  const note = await driver.open("/note.txt");
  if (new TextDecoder().decode(note) !== "note\n") {
    throw new Error("worktree open/read coherence failed");
  }

  // Remote op via ctl fails closed
  await driver.write!(
    "/.git/mc/ctl",
    new TextEncoder().encode(JSON.stringify({ op: "fetch" })),
  );
  const refuse = JSON.parse(
    new TextDecoder().decode(await driver.open("/.git/mc/out/last")),
  );
  if (refuse.ok || !String(refuse.stderr || "").includes("host_call")) {
    throw new Error(`ctl fetch refuse: ${JSON.stringify(refuse)}`);
  }
  const genAfter = new TextDecoder().decode(
    await driver.open("/.git/mc/generation"),
  );
  if (Number(genAfter) <= Number(genBefore)) {
    throw new Error(`generation should advance: ${genBefore} → ${genAfter}`);
  }

  // P2.5: cone-only sparse projection via asMountDriver (not full sparse parity).
  await eng.run({
    op: "write",
    args: { path: "keep/a.txt", content: "keep\n" },
  });
  await eng.run({
    op: "write",
    args: { path: "drop/b.txt", content: "drop\n" },
  });
  const coneDriver = eng.asMountDriver({ sparseCone: ["keep"] });
  const coneRoot = await coneDriver.readdir("/");
  if (!coneRoot.some((e) => e.name === "keep")) {
    throw new Error(`cone readdir missing keep: ${JSON.stringify(coneRoot)}`);
  }
  if (coneRoot.some((e) => e.name === "drop")) {
    throw new Error(`cone readdir must hide drop: ${JSON.stringify(coneRoot)}`);
  }
  const keep = await coneDriver.open("/keep/a.txt");
  if (new TextDecoder().decode(keep) !== "keep\n") {
    throw new Error("in-cone open failed");
  }
  // Engine sparse-set: multi-pattern + basic negation (not full sparse language).
  const ss = await eng.run({
    op: "sparse-set",
    args: { patterns: ["keep", "!drop"] },
  });
  if (!ss.ok) {
    throw new Error(`sparse-set: ${JSON.stringify(ss)}`);
  }
  // Porcelain-v1 status (default): untracked as ?? when present; staged XY form.
  const stPorcelain = await eng.run({ op: "status" });
  if (!stPorcelain.ok) {
    throw new Error(`status porcelain: ${JSON.stringify(stPorcelain)}`);
  }
  if (String(stPorcelain.stdout || "").includes("On branch")) {
    throw new Error("status default must be porcelain-v1, not human On branch");
  }

  // R52–R55: durable rebind — pack+refs AGIT envelope restores objects + worktree.
  const dur = new MemoryDurable("rebind");
  const engDur = await GitEngine.load({
    baseUrl: baseUrl(dir),
    durable: dur,
  });
  let dr = await engDur.run({ op: "init" });
  if (!dr.ok) throw new Error(`durable init: ${JSON.stringify(dr)}`);
  dr = await engDur.run({
    op: "write",
    args: { path: "persist.txt", content: "durable-roundtrip\n" },
  });
  if (!dr.ok) throw new Error(`durable write: ${JSON.stringify(dr)}`);
  dr = await engDur.run({ op: "add", args: { path: "persist.txt" } });
  if (!dr.ok) throw new Error(`durable add: ${JSON.stringify(dr)}`);
  dr = await engDur.run({
    op: "commit",
    args: {
      message: "durable commit",
      name: "Dur",
      email: "dur@test",
      when_unix: 1_700_000_100,
    },
  });
  if (!dr.ok) throw new Error(`durable commit: ${JSON.stringify(dr)}`);
  const headBefore = (
    await engDur.run({ op: "rev-parse", args: { rev: "HEAD" } })
  ).stdout!.trim().split(/\s+/)[0];
  if (!headBefore || headBefore.length !== 40) {
    throw new Error(`durable HEAD before: ${headBefore}`);
  }
  await engDur.checkpoint();
  const saved = await dur.load();
  if (!saved || !decodeDurableBlob(saved)) {
    throw new Error("checkpoint must write AGIT pack+refs envelope");
  }
  await engDur.close();

  const engRestored = await GitEngine.load({
    baseUrl: baseUrl(dir),
    durable: dur,
  });
  const headAfter = (
    await engRestored.run({ op: "rev-parse", args: { rev: "HEAD" } })
  ).stdout!.trim().split(/\s+/)[0];
  if (headAfter !== headBefore) {
    throw new Error(
      `durable rebind HEAD mismatch: ${headBefore} → ${headAfter}`,
    );
  }
  const fileR = await engRestored.run({
    op: "show",
    args: { rev: "HEAD:persist.txt" },
  });
  // Prefer worktree path via driver if show path form unavailable.
  const driverR = engRestored.asMountDriver();
  let body = "";
  try {
    body = new TextDecoder().decode(await driverR.open("/persist.txt"));
  } catch {
    body = String(fileR.stdout || "");
  }
  if (!body.includes("durable-roundtrip")) {
    throw new Error(
      `durable rebind worktree missing file content: ${JSON.stringify({ body, fileR })}`,
    );
  }
  await engRestored.close();

  // D16: directory durable — re-openable host worktree (not AGIT-only).
  // Process A: init/commit/checkpoint → host dir has real .git + files.
  // Process B: load same durableDir → same HEAD + worktree content.
  const { mkdtemp, rm, access } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join: pathJoin } = await import("node:path");
  const durableHost = await mkdtemp(pathJoin(tmpdir(), "agentos-git-dur-"));
  try {
    const engA = await GitEngine.load({
      baseUrl: baseUrl(dir),
      durableDir: durableHost,
    });
    if (engA.durableDir !== durableHost && !engA.durableDir?.endsWith(durableHost.replace(/\/$/, ""))) {
      // hostPath is absolute-resolved
      if (!engA.durableDir) {
        throw new Error("durableDir load must surface HostDirDurable path");
      }
    }
    let r = await engA.run({ op: "init" });
    if (!r.ok) throw new Error(`D16 init: ${JSON.stringify(r)}`);
    r = await engA.run({
      op: "write",
      args: { path: "dir-persist.txt", content: "host-dir-roundtrip\n" },
    });
    if (!r.ok) throw new Error(`D16 write: ${JSON.stringify(r)}`);
    r = await engA.run({ op: "add", args: { path: "dir-persist.txt" } });
    if (!r.ok) throw new Error(`D16 add: ${JSON.stringify(r)}`);
    r = await engA.run({
      op: "commit",
      args: {
        message: "dir durable",
        name: "Dir",
        email: "dir@test",
        when_unix: 1_700_000_200,
      },
    });
    if (!r.ok) throw new Error(`D16 commit: ${JSON.stringify(r)}`);
    const headA = (
      await engA.run({ op: "rev-parse", args: { rev: "HEAD" } })
    ).stdout!.trim().split(/\s+/)[0];
    if (!headA || headA.length !== 40) {
      throw new Error(`D16 HEAD A: ${headA}`);
    }
    await engA.checkpoint();
    // Host dir must contain a real .git after checkpoint (not AGIT-only).
    await access(pathJoin(durableHost, ".git"));
    await access(pathJoin(durableHost, "dir-persist.txt"));
    await engA.close();

    // Second engine load = second process open of the same host directory.
    const engB = await GitEngine.load({
      baseUrl: baseUrl(dir),
      durableDir: durableHost,
    });
    const headB = (
      await engB.run({ op: "rev-parse", args: { rev: "HEAD" } })
    ).stdout!.trim().split(/\s+/)[0];
    if (headB !== headA) {
      throw new Error(`D16 directory reopen HEAD mismatch: ${headA} → ${headB}`);
    }
    const driverB = engB.asMountDriver();
    let bodyB = "";
    try {
      bodyB = new TextDecoder().decode(await driverB.open("/dir-persist.txt"));
    } catch {
      const showB = await engB.run({
        op: "show",
        args: { rev: "HEAD:dir-persist.txt" },
      });
      bodyB = String(showB.stdout || "");
    }
    if (!bodyB.includes("host-dir-roundtrip")) {
      throw new Error(
        `D16 directory reopen missing worktree content: ${JSON.stringify(bodyB)}`,
      );
    }
    // Directory backends do not produce AGIT durableSnapshot.
    if (engB.durableSnapshot !== null) {
      throw new Error("D16 directory durable must not force AGIT durableSnapshot");
    }
    await engB.close();
  } finally {
    await rm(durableHost, { recursive: true, force: true });
  }

  // R85–R88: metrics counters are inspectable / resettable
  const {
    resetGitCounters,
    snapshotGitCounters,
    recordRemoteResult,
  } = await import("../src/git/metrics.js");
  resetGitCounters();
  recordRemoteResult("clone", true);
  recordRemoteResult("clone", false);
  recordRemoteResult("push", true);
  const snap = snapshotGitCounters();
  if (snap.clone_ok !== 1 || snap.clone_error !== 1 || snap.push_ok !== 1) {
    throw new Error(`metrics snapshot unexpected: ${JSON.stringify(snap)}`);
  }
  resetGitCounters();
  if (snapshotGitCounters().clone_ok !== 0) {
    throw new Error("metrics reset failed");
  }

  await eng.close();
  console.log("git_engine.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
