/**
 * GitEngine.run + token-addressed gitfs ctl + dial refuse (no full VM).
 * Requires MC_GIT_ENGINE_TAR → runfiles path of git-engine.tar.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  decodeDurableTreeBlob,
  GitEngine,
  HostDirDurable,
  MemoryDurable,
  safeDurablePathSegment,
} from "../src/git/index.js";

function engineTar(): Uint8Array {
  const rel = process.env.MC_GIT_ENGINE_TAR || "";
  if (!rel) throw new Error("MC_GIT_ENGINE_TAR is not set (run under bazel test)");
  const rf = process.env.RUNFILES_DIR;
  const candidates = [
    rel && rf ? join(rf, rel) : "",
    rel && rf ? join(rf, "_main", rel) : "",
    rel,
    join(process.cwd(), "bazel-bin/memcontainers/lib/git-engine/git_engine_release.tar"),
  ].filter(Boolean);
  for (const c of candidates) {
    if (c && existsSync(c)) return new Uint8Array(readFileSync(c));
  }
  throw new Error(`git-engine.tar not found (MC_GIT_ENGINE_TAR=${rel})`);
}

async function main() {
  if (safeDurablePathSegment("..") !== "default" || safeDurablePathSegment(".") !== "default") {
    throw new Error("durable ids must not escape their configured root");
  }
  try {
    await new HostDirDurable("root", "/").ensure();
    throw new Error("filesystem root must not be accepted as a durable worktree");
  } catch (error) {
    if (!String(error).includes("must not be a filesystem root")) throw error;
  }
  const eng = await GitEngine.load({ engine: engineTar() });

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

  // host identity inject — commit without name/email succeeds when configured.
  // Never invents Agent@example.com when identity is unset (covered by engine K28).
  const engId = await GitEngine.load({
    engine: engineTar(),
    identity: { name: "Host Policy", email: "host@policy.test" },
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
  const engNoId = await GitEngine.load({ engine: engineTar() });
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
  // helper: reset mode ff-only fails on divergent history.
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

  // PR4/PR5: gitfs worktree + synthetic .git + token-addressed ctl
  const driver = eng.asMountDriver();
  // brand for K21 one-engine-per-path (multi-path allowed)
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
    throw new Error(`readdir /.git must not list objects (K17): ${JSON.stringify(gitEntries)}`);
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
  // Positive allowlist: direct open/stat of physical engine paths under
  // `.git/**` must fail closed (ENOENT/EACCES), not fall through to host ODB FS.
  // Directory-listing-only checks are insufficient.
  for (const forbidden of [
    "/.git/config",
    "/.git/index",
    "/.git/packed-refs",
    "/.git/logs/HEAD",
    "/.git/logs/refs/heads/master",
    "/.git/refs/heads/master",
    "/.git/refs/heads/feature-head",
    "/.git/info/exclude",
    "/.git/description",
    "/.git/COMMIT_EDITMSG",
    "/.git/mc/unknown",
    "/.git/mc/out/other",
    "/.git/hooks/pre-commit",
  ]) {
    for (const op of ["open", "stat"] as const) {
      try {
        if (op === "open") await driver.open(forbidden);
        else await driver.stat(forbidden);
        throw new Error(`${op} ${forbidden} must fail closed`);
      } catch (e) {
        const code = (e as { code?: string }).code;
        if (code !== "ENOENT" && code !== "EACCES") {
          throw new Error(
            `${op} ${forbidden} expected ENOENT|EACCES, got ${String(code ?? e)}`,
          );
        }
      }
    }
  }
  // Allowlisted synthetic paths remain usable.
  await driver.stat("/.git");
  await driver.stat("/.git/mc");
  await driver.stat("/.git/mc/out");
  await driver.stat("/.git/refs");
  await driver.stat("/.git/mc/ctl");
  await driver.stat("/.git/mc/generation");
  await driver.open("/.git/mc/generation");
  try {
    await driver.open("/.git/mc/ctl");
    throw new Error("write-only ctl unexpectedly opened");
  } catch (e) {
    if ((e as { code?: string }).code !== "EACCES") throw e;
  }
  try {
    await driver.write!(
      "/.git/mc/ctl",
      new TextEncoder().encode(
        '{"op":"status","args":{"client_token":"duplicate-a","client_token":"duplicate-b"}}',
      ),
    );
    throw new Error("duplicate ctl key was accepted");
  } catch (error) {
    if (String(error).includes("was accepted")) throw error;
    if ((error as { code?: string }).code !== "EINVAL") throw error;
  }

  const head = new TextDecoder().decode(await driver.open("/.git/HEAD"));
  if (!head.startsWith("ref: refs/heads/")) {
    throw new Error(`synthetic HEAD: ${JSON.stringify(head)}`);
  }
  // after checkout, synthetic HEAD tracks the branch (not hard-coded master).
  await eng.run({ op: "branch", args: { name: "feature-head" } });
  await eng.run({ op: "checkout", args: { name: "feature-head" } });
  const headFeature = new TextDecoder().decode(await driver.open("/.git/HEAD"));
  if (headFeature.trim() !== "ref: refs/heads/feature-head") {
    throw new Error(`synthetic HEAD after checkout: ${JSON.stringify(headFeature)}`);
  }

  // Ctl protocol: write a tokenized Request, then read its dedicated Response.
  const statusToken = "sdk-status";
  await driver.write!(
    "/.git/mc/ctl",
    new TextEncoder().encode(
      JSON.stringify({
        op: "status",
        args: { short: true, client_token: statusToken },
      }),
    ),
  );
  const respBytes = await driver.open(`/.git/mc/responses/${statusToken}`);
  const resp = JSON.parse(new TextDecoder().decode(respBytes));
  if (!resp.ok) throw new Error(`ctl status: ${JSON.stringify(resp)}`);

  const genBefore = new TextDecoder().decode(await driver.open("/.git/mc/generation"));
  const fs = eng.bridge.FS;
  if (!fs.mkdirTree) throw new Error("ctl eviction test requires MEMFS mkdirTree");
  fs.mkdirTree(eng.bridge.abs(".git/mc/out"));
  fs.writeFile(eng.bridge.abs(`.git/mc/out/${statusToken}`), "stale-stream");
  try {
    await driver.open(`/.git/mc/out/${statusToken}`);
    throw new Error("non-stream ctl response exposed a physical runtime artifact");
  } catch (error) {
    if (String(error).includes("exposed a physical")) throw error;
    if ((error as { code?: string }).code !== "ENOENT") throw error;
  }
  for (let i = 0; i < 32; i++) {
    await driver.write!(
      "/.git/mc/ctl",
      new TextEncoder().encode(
        JSON.stringify({
          op: "status",
          args: { client_token: `evict-${i}` },
        }),
      ),
    );
  }
  try {
    fs.stat(eng.bridge.abs(`.git/mc/out/${statusToken}`));
    throw new Error("evicted ctl response left its physical stdout stream behind");
  } catch (error) {
    if (String(error).includes("left its physical")) throw error;
  }
  // Coherence: worktree write via driver then status via Run (single-writer)
  await driver.write!("/note.txt", new TextEncoder().encode("note\n"));
  await eng.run({ op: "add", args: { path: "note.txt" } });
  const st = await eng.run({ op: "status", args: { short: true } });
  if (!st.ok) throw new Error(`status: ${JSON.stringify(st)}`);
  const note = await driver.open("/note.txt");
  if (new TextDecoder().decode(note) !== "note\n") {
    throw new Error("worktree open/read coherence failed");
  }

  // MEMFS gitfs and direct engine ops reject a symlink in any
  // path component. The outside sentinel is never reachable through the mount.
  if (typeof fs.symlink !== "function") {
    throw new Error("Emscripten FS.symlink is required for containment regression");
  }
  fs.mkdir("/outside-gitfs");
  fs.writeFile("/outside-gitfs/sentinel.txt", "safe\n");
  fs.symlink!("/outside-gitfs", `${eng.bridge.workRoot}/escape`);
  const expectDriverError = async (label: string, fn: () => Promise<unknown>): Promise<void> => {
    try {
      await fn();
      throw new Error(`${label} unexpectedly succeeded`);
    } catch (e) {
      if ((e as { code?: string }).code !== "EACCES") {
        throw new Error(
          `${label} expected EACCES, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
  };
  await expectDriverError("symlink open", () => driver.open("/escape/sentinel.txt"));
  await expectDriverError("symlink stat", () => driver.stat("/escape/sentinel.txt"));
  await expectDriverError("symlink readdir", () => driver.readdir("/escape"));
  await expectDriverError("symlink write", () =>
    driver.write!("/escape/pwn.txt", new TextEncoder().encode("bad")),
  );
  await expectDriverError("symlink mkdir", () => driver.mkdir!("/escape/newdir"));
  await expectDriverError("symlink unlink", () => driver.unlink!("/escape/sentinel.txt"));
  await expectDriverError("symlink rename destination", () =>
    driver.rename!("/note.txt", "/escape/moved.txt"),
  );
  await expectDriverError("symlink rename source", () =>
    driver.rename!("/escape/sentinel.txt", "/moved.txt"),
  );
  const rootAfterSymlink = await driver.readdir("/");
  if (rootAfterSymlink.some((entry) => entry.name === "escape")) {
    throw new Error("gitfs root readdir projected a symlink");
  }
  for (const [op, args] of [
    ["write", { path: "escape/pwn.txt", content: "bad" }],
    ["add", { path: "escape/sentinel.txt" }],
    ["rm", { path: "escape/sentinel.txt" }],
  ] as const) {
    const blocked = await eng.run({ op, args });
    if (blocked.ok || !String(blocked.stderr || "").includes("symlink")) {
      throw new Error(`engine ${op} parent symlink must fail: ${JSON.stringify(blocked)}`);
    }
  }
  if (
    new TextDecoder().decode(fs.readFile("/outside-gitfs/sentinel.txt") as Uint8Array) !== "safe\n"
  ) {
    throw new Error("gitfs containment changed outside sentinel");
  }
  let escapedWriteExists = false;
  try {
    fs.stat("/outside-gitfs/pwn.txt");
    escapedWriteExists = true;
  } catch {
    // Missing is the expected result.
  }
  if (escapedWriteExists) throw new Error("gitfs write escaped through symlink");
  fs.unlink(`${eng.bridge.workRoot}/escape`);

  // Remote op via ctl fails closed
  const fetchToken = "sdk-fetch";
  await driver.write!(
    "/.git/mc/ctl",
    new TextEncoder().encode(
      JSON.stringify({
        op: "fetch",
        args: { client_token: fetchToken },
      }),
    ),
  );
  const refuse = JSON.parse(
    new TextDecoder().decode(await driver.open(`/.git/mc/responses/${fetchToken}`)),
  );
  if (refuse.ok || !String(refuse.stderr || "").includes("host_call")) {
    throw new Error(`ctl fetch refuse: ${JSON.stringify(refuse)}`);
  }
  const genAfter = new TextDecoder().decode(await driver.open("/.git/mc/generation"));
  if (Number(genAfter) <= Number(genBefore)) {
    throw new Error(`generation should advance: ${genBefore} → ${genAfter}`);
  }

  // Port parity (M1): guest writes under `.git/` fail closed with EACCES except
  // synthetic ctl (handled above). Non-ctl meta must not writeFiles into host .git.
  // K17 objects remain ENOENT for mutating ops too.
  const enc = new TextEncoder();
  for (const metaPath of [
    "/.git/config",
    "/.git/HEAD",
    "/.git/refs/heads/evil",
    "/.git/mc/generation",
    "/.git/mc/out/last",
    "/.git/description",
  ]) {
    try {
      await driver.write!(metaPath, enc.encode("guest-must-not-write\n"));
      throw new Error(`write ${metaPath} must EACCES (Port fail-closed)`);
    } catch (e) {
      if ((e as { code?: string }).code !== "EACCES") {
        throw new Error(
          `write ${metaPath} expected EACCES, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
  }
  for (const objectsWrite of ["/.git/objects", "/.git/objects/pack/x.pack"]) {
    try {
      await driver.write!(objectsWrite, enc.encode("x"));
      throw new Error(`write ${objectsWrite} must ENOENT (K17)`);
    } catch (e) {
      if ((e as { code?: string }).code !== "ENOENT") {
        throw new Error(
          `write ${objectsWrite} expected ENOENT, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
  }
  for (const mkdirPath of ["/.git/refs/heads", "/.git/objects/pack", "/.git/info"]) {
    try {
      await driver.mkdir!(mkdirPath);
      throw new Error(
        `mkdir ${mkdirPath} must ${mkdirPath.includes("objects") ? "ENOENT" : "EACCES"}`,
      );
    } catch (e) {
      const want = mkdirPath.includes("objects") ? "ENOENT" : "EACCES";
      if ((e as { code?: string }).code !== want) {
        throw new Error(
          `mkdir ${mkdirPath} expected ${want}, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
  }
  for (const unlinkPath of ["/.git/HEAD", "/.git/config", "/.git/mc/ctl", "/.git/objects/pack"]) {
    try {
      await driver.unlink!(unlinkPath);
      throw new Error(
        `unlink ${unlinkPath} must ${unlinkPath.includes("objects") ? "ENOENT" : "EACCES"}`,
      );
    } catch (e) {
      const want = unlinkPath.includes("objects") ? "ENOENT" : "EACCES";
      if ((e as { code?: string }).code !== want) {
        throw new Error(
          `unlink ${unlinkPath} expected ${want}, got ${String((e as { code?: string }).code ?? e)}`,
        );
      }
    }
  }
  // Ctl remains the only guest write under .git (sanity after fail-closed checks).
  await driver.write!(
    "/.git/mc/ctl",
    enc.encode(
      JSON.stringify({
        op: "status",
        args: { short: true, client_token: "sdk-still" },
      }),
    ),
  );
  const ctlStill = JSON.parse(
    new TextDecoder().decode(await driver.open("/.git/mc/responses/sdk-still")),
  );
  if (!ctlStill.ok) {
    throw new Error(`ctl still writable after meta EACCES: ${JSON.stringify(ctlStill)}`);
  }

  // P2.5: cone-only sparse projection via asMountDriver (not full sparse parity).
  // Use a clean, committed engine for the real sparse-set contract.
  const sparseEng = await GitEngine.load({ engine: engineTar() });
  let sparseR = await sparseEng.run({ op: "init" });
  if (!sparseR.ok) throw new Error("sparse init: " + JSON.stringify(sparseR));
  for (const [path, content] of [
    ["keep/a.txt", "keep\n"],
    ["drop/b.txt", "drop\n"],
  ] as const) {
    sparseR = await sparseEng.run({ op: "write", args: { path, content } });
    if (!sparseR.ok) throw new Error("sparse write " + path + ": " + JSON.stringify(sparseR));
  }
  sparseR = await sparseEng.run({ op: "add", args: { all: true } });
  if (!sparseR.ok) throw new Error("sparse add: " + JSON.stringify(sparseR));
  sparseR = await sparseEng.run({
    op: "commit",
    args: {
      message: "sparse baseline",
      name: "Sparse",
      email: "sparse@test",
      when_unix: 1_700_000_400,
    },
  });
  if (!sparseR.ok) throw new Error("sparse commit: " + JSON.stringify(sparseR));
  const coneDriver = sparseEng.asMountDriver({ sparseCone: ["keep"] });
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
  const sparseFs = sparseEng.bridge.FS;
  // Engine sparse-set: multi-pattern + basic negation (not full sparse language).
  const ss = await sparseEng.run({
    op: "sparse-set",
    args: { patterns: ["keep", "!drop"] },
  });
  if (!ss.ok) {
    throw new Error("sparse-set: " + JSON.stringify(ss));
  }
  if (sparseFs.analyzePath!(sparseEng.bridge.abs("drop")).exists) {
    throw new Error("sparse-set left the out-of-cone directory materialized");
  }
  // Retargeting a clean cone restores newly included files before pruning the
  // previous cone, including in the Emscripten runner.
  const retarget = await sparseEng.run({
    op: "sparse-set",
    args: { patterns: ["drop"] },
  });
  if (
    !retarget.ok ||
    sparseFs.analyzePath!(sparseEng.bridge.abs("keep")).exists ||
    !sparseFs.analyzePath!(sparseEng.bridge.abs("drop/b.txt")).exists
  ) {
    throw new Error("sparse retarget failed: " + JSON.stringify(retarget));
  }
  const retargetBack = await sparseEng.run({
    op: "sparse-set",
    args: { patterns: ["keep"] },
  });
  if (!retargetBack.ok) {
    throw new Error("sparse retarget back failed: " + JSON.stringify(retargetBack));
  }
  sparseFs.mkdir("/outside-sparse");
  sparseFs.writeFile("/outside-sparse/sentinel.txt", "safe\n");
  sparseFs.mkdir(sparseEng.bridge.abs("drop"));
  sparseFs.symlink!("/outside-sparse", sparseEng.bridge.workRoot + "/drop/outside");
  // A dirty worktree must be rejected before any checkout/pruning.
  const dirtySparse = await sparseEng.run({ op: "sparse-disable" });
  if (dirtySparse.ok || !String(dirtySparse.stderr || "").includes("clean")) {
    throw new Error("dirty sparse-set must fail closed: " + JSON.stringify(dirtySparse));
  }
  const sparseSentinel = sparseFs.readFile("/outside-sparse/sentinel.txt");
  const sparseText =
    sparseSentinel instanceof Uint8Array
      ? new TextDecoder().decode(sparseSentinel)
      : String(sparseSentinel);
  if (sparseText !== "safe\n") {
    throw new Error("sparse prune followed an out-of-cone symlink");
  }
  sparseFs.unlink(sparseEng.bridge.workRoot + "/drop/outside");
  sparseFs.rmdir!(sparseEng.bridge.abs("drop"));
  sparseFs.unlink("/outside-sparse/sentinel.txt");
  sparseFs.rmdir!("/outside-sparse");
  await sparseEng.close();
  // Porcelain-v1 status (default): untracked as ?? when present; staged XY form.
  const stPorcelain = await eng.run({ op: "status" });
  if (!stPorcelain.ok) {
    throw new Error(`status porcelain: ${JSON.stringify(stPorcelain)}`);
  }
  if (String(stPorcelain.stdout || "").includes("On branch")) {
    throw new Error("status default must be porcelain-v1, not human On branch");
  }

  // Snapshots restore committed, staged, dirty, and untracked coding state.
  const dur = new MemoryDurable("rebind");
  const engDur = await GitEngine.load({ engine: engineTar(), durable: dur });
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
  const headBefore = (await engDur.run({ op: "rev-parse", args: { rev: "HEAD" } }))
    .stdout!.trim()
    .split(/\s+/)[0];
  if (!headBefore || headBefore.length !== 40) {
    throw new Error(`durable HEAD before: ${headBefore}`);
  }
  dr = await engDur.run({
    op: "write",
    args: { path: "persist.txt", content: "dirty-after-commit\n" },
  });
  if (!dr.ok) throw new Error(`durable dirty write: ${JSON.stringify(dr)}`);
  dr = await engDur.run({
    op: "write",
    args: { path: "staged.txt", content: "staged-only\n" },
  });
  if (!dr.ok) throw new Error(`durable staged write: ${JSON.stringify(dr)}`);
  dr = await engDur.run({ op: "add", args: { path: "staged.txt" } });
  if (!dr.ok) throw new Error(`durable staged add: ${JSON.stringify(dr)}`);
  dr = await engDur.run({
    op: "write",
    args: { path: "untracked.txt", content: "untracked-only\n" },
  });
  if (!dr.ok) throw new Error(`durable untracked write: ${JSON.stringify(dr)}`);
  if (!engDur.bridge.FS.symlink) throw new Error("snapshot test requires MEMFS symlink support");
  engDur.bridge.FS.symlink("persist.txt", engDur.bridge.abs("persist-link"));
  engDur.bridge.FS.mkdir(engDur.bridge.abs("empty-mode-dir"));
  engDur.bridge.FS.chmod(engDur.bridge.abs("empty-mode-dir"), 0o750);
  if (!engDur.bridge.FS.mkdirTree) throw new Error("snapshot test requires MEMFS mkdirTree");
  engDur.bridge.FS.mkdirTree(engDur.bridge.abs(".git/mc/out"));
  engDur.bridge.FS.writeFile(engDur.bridge.abs(".git/mc/out/stale"), "runtime-only");
  engDur.bridge.FS.mkdirTree(engDur.bridge.abs(".git/agentos"));
  engDur.bridge.FS.writeFile(engDur.bridge.abs(".git/agentos/push.pack"), "one-shot");
  await engDur.checkpoint();
  const saved = await dur.load();
  const decodedSaved = saved ? decodeDurableTreeBlob(saved) : null;
  if (!decodedSaved) {
    throw new Error("checkpoint must write an AgentOS Git Snapshot");
  }
  const savedMetaLength = new DataView(
    saved!.buffer,
    saved!.byteOffset,
    saved!.byteLength,
  ).getUint32(4, true);
  const savedMetadata = new TextDecoder().decode(saved!.subarray(8, 8 + savedMetaLength));
  const duplicateMetadata = savedMetadata.replace('{"v":1', '{"v":1,"v":1');
  const duplicateBytes = new TextEncoder().encode(duplicateMetadata);
  const nonCanonicalSnapshot = new Uint8Array(
    8 + duplicateBytes.byteLength + saved!.byteLength - 8 - savedMetaLength,
  );
  nonCanonicalSnapshot.set(saved!.subarray(0, 4));
  new DataView(nonCanonicalSnapshot.buffer).setUint32(4, duplicateBytes.byteLength, true);
  nonCanonicalSnapshot.set(duplicateBytes, 8);
  nonCanonicalSnapshot.set(saved!.subarray(8 + savedMetaLength), 8 + duplicateBytes.byteLength);
  if (decodeDurableTreeBlob(nonCanonicalSnapshot) !== null) {
    throw new Error("snapshot decoder accepted duplicate metadata keys");
  }
  const durablePaths = [
    ...decodedSaved.dirs.map((entry) => entry.path),
    ...decodedSaved.files.map((entry) => entry.path),
    ...decodedSaved.links.map((entry) => entry.path),
  ];
  if (
    durablePaths.some(
      (path) =>
        path === ".git/mc" ||
        path.startsWith(".git/mc/") ||
        path === ".git/agentos" ||
        path.startsWith(".git/agentos/"),
    )
  ) {
    throw new Error("AgentOS Git Snapshot persisted an engine runtime artifact");
  }
  await engDur.close();

  const engRestored = await GitEngine.load({ engine: engineTar(), durable: dur });
  const headAfter = (await engRestored.run({ op: "rev-parse", args: { rev: "HEAD" } }))
    .stdout!.trim()
    .split(/\s+/)[0];
  if (headAfter !== headBefore) {
    throw new Error(`durable rebind HEAD mismatch: ${headBefore} → ${headAfter}`);
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
  if (!body.includes("dirty-after-commit")) {
    throw new Error(
      `durable rebind worktree missing file content: ${JSON.stringify({ body, fileR })}`,
    );
  }
  const restoredStatus = await engRestored.run({ op: "status" });
  const statusText = String(restoredStatus.stdout || "");
  if (
    !statusText.includes("M persist.txt") ||
    !statusText.includes("A  staged.txt") ||
    !statusText.includes("?? untracked.txt")
  ) {
    throw new Error(`snapshot coding state mismatch: ${JSON.stringify(restoredStatus)}`);
  }
  const restoredLink = engRestored.bridge.FS.lstat(engRestored.bridge.abs("persist-link"));
  if (
    !engRestored.bridge.FS.isLink(restoredLink.mode) ||
    engRestored.bridge.FS.readlink?.(engRestored.bridge.abs("persist-link")) !== "persist.txt"
  ) {
    throw new Error("snapshot did not preserve the worktree symlink itself");
  }
  const restoredDir = engRestored.bridge.FS.stat(engRestored.bridge.abs("empty-mode-dir"));
  if (!engRestored.bridge.FS.isDir(restoredDir.mode) || (restoredDir.mode & 0o777) !== 0o750) {
    throw new Error(
      `snapshot did not preserve empty directory mode: ${restoredDir.mode.toString(8)}`,
    );
  }
  await engRestored.close();

  // Directory durable — re-openable host worktree.
  // Process A: init/commit/checkpoint → host dir has real .git + files.
  // Process B: load same durableDir → same HEAD + worktree content.
  const { mkdtemp, rm, access, lstat, readlink } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join: pathJoin } = await import("node:path");
  const durableHost = await mkdtemp(pathJoin(tmpdir(), "agentos-git-dur-"));
  try {
    const engA = await GitEngine.load({ engine: engineTar(), durableDir: durableHost });
    if (
      engA.durableDir !== durableHost &&
      !engA.durableDir?.endsWith(durableHost.replace(/\/$/, ""))
    ) {
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
    const headA = (await engA.run({ op: "rev-parse", args: { rev: "HEAD" } }))
      .stdout!.trim()
      .split(/\s+/)[0];
    if (!headA || headA.length !== 40) {
      throw new Error(`D16 HEAD A: ${headA}`);
    }
    if (!engA.bridge.FS.symlink) throw new Error("directory durable requires MEMFS symlinks");
    engA.bridge.FS.symlink("dir-persist.txt", engA.bridge.abs("dir-link"));
    engA.bridge.FS.mkdir(engA.bridge.abs("dir-mode"));
    engA.bridge.FS.chmod(engA.bridge.abs("dir-mode"), 0o750);
    if (!engA.bridge.FS.mkdirTree) throw new Error("directory durable requires MEMFS mkdirTree");
    engA.bridge.FS.mkdirTree(engA.bridge.abs(".git/mc/out"));
    engA.bridge.FS.writeFile(engA.bridge.abs(".git/mc/out/stale"), "runtime-only");
    engA.bridge.FS.mkdirTree(engA.bridge.abs(".git/agentos"));
    engA.bridge.FS.writeFile(engA.bridge.abs(".git/agentos/push.pack"), "one-shot");
    await engA.checkpoint();
    // Host dir must contain a real .git after checkpoint.
    await access(pathJoin(durableHost, ".git"));
    await access(pathJoin(durableHost, "dir-persist.txt"));
    if (
      !(await lstat(pathJoin(durableHost, "dir-link"))).isSymbolicLink() ||
      (await readlink(pathJoin(durableHost, "dir-link"))) !== "dir-persist.txt"
    ) {
      throw new Error("D16 checkpoint did not preserve symlink identity");
    }
    if (((await lstat(pathJoin(durableHost, "dir-mode"))).mode & 0o777) !== 0o750) {
      throw new Error("D16 checkpoint did not preserve directory mode");
    }
    for (const transient of [".git/mc", ".git/agentos"]) {
      try {
        await access(pathJoin(durableHost, transient));
        throw new Error(`D16 checkpoint persisted runtime path ${transient}`);
      } catch (error) {
        if (String(error).includes("persisted runtime path")) throw error;
      }
    }
    await engA.close();

    // Second engine load = second process open of the same host directory.
    const engB = await GitEngine.load({ engine: engineTar(), durableDir: durableHost });
    const headB = (await engB.run({ op: "rev-parse", args: { rev: "HEAD" } }))
      .stdout!.trim()
      .split(/\s+/)[0];
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
      throw new Error(`D16 directory reopen missing worktree content: ${JSON.stringify(bodyB)}`);
    }
    const linkB = engB.bridge.FS.lstat(engB.bridge.abs("dir-link"));
    if (
      !engB.bridge.FS.isLink(linkB.mode) ||
      engB.bridge.FS.readlink?.(engB.bridge.abs("dir-link")) !== "dir-persist.txt"
    ) {
      throw new Error("D16 hydrate did not preserve symlink identity");
    }
    const dirModeB = engB.bridge.FS.stat(engB.bridge.abs("dir-mode"));
    if (!engB.bridge.FS.isDir(dirModeB.mode) || (dirModeB.mode & 0o777) !== 0o750) {
      throw new Error("D16 hydrate did not preserve directory mode");
    }
    // Directory backends do not produce a blob durableSnapshot.
    if (engB.durableSnapshot !== null) {
      throw new Error("D16 directory durable must not produce a blob durableSnapshot");
    }
    await engB.close();
  } finally {
    await rm(durableHost, { recursive: true, force: true });
  }

  // Truncated stdout → explicit stream_path + readStdoutStream.
  {
    const engT = await GitEngine.load({ engine: engineTar() });
    let tr = await engT.run({ op: "init" });
    if (!tr.ok) throw new Error(`D15 init: ${JSON.stringify(tr)}`);
    tr = await engT.run({
      op: "write",
      args: { path: "big.txt", content: "base\n" },
    });
    if (!tr.ok) throw new Error(`D15 write base: ${JSON.stringify(tr)}`);
    tr = await engT.run({ op: "add", args: { path: "big.txt" } });
    if (!tr.ok) throw new Error(`D15 add: ${JSON.stringify(tr)}`);
    tr = await engT.run({
      op: "commit",
      args: {
        message: "d15 base",
        name: "T",
        email: "t@test",
        when_unix: 1_700_000_200,
      },
    });
    if (!tr.ok) throw new Error(`D15 commit: ${JSON.stringify(tr)}`);
    // Worktree change large enough for a patch once embed limit is tiny.
    const lines = Array.from({ length: 20 }, (_, i) => `line ${i} xxxxxxxx`).join("\n");
    tr = await engT.run({
      op: "write",
      args: { path: "big.txt", content: lines + "\n" },
    });
    if (!tr.ok) throw new Error(`D15 write change: ${JSON.stringify(tr)}`);
    engT.bridge.testSetStdoutMaxBytes(48);
    tr = await engT.run({ op: "diff", args: { path: "big.txt" } });
    engT.bridge.testSetStdoutMaxBytes(0);
    if (!tr.ok) throw new Error(`D15 diff: ${JSON.stringify(tr)}`);
    const meta = tr.result as {
      truncated?: boolean;
      stream_path?: string;
      stdout_bytes?: number;
      client_token?: string;
    } | null;
    if (
      !meta?.truncated ||
      !/^sdk-[0-9]+$/.test(meta.client_token ?? "") ||
      meta.stream_path !== `.git/mc/out/${meta.client_token}`
    ) {
      throw new Error(`D15 expected truncated+stream_path: ${JSON.stringify(tr)}`);
    }
    const body = await engT.readStdoutStream(tr);
    if (!body || body.byteLength === 0) {
      throw new Error("D15 readStdoutStream empty");
    }
    const text = new TextDecoder().decode(body);
    if (!text.includes("line") && !text.includes("diff") && !text.includes("big")) {
      throw new Error(`D15 stream body unexpected: ${text.slice(0, 120)}`);
    }
    const driverT = engT.asMountDriver();
    try {
      await driverT.open("/.git/mc/out/last");
      throw new Error("D15 unscoped stream path must not be guest-visible");
    } catch (e) {
      if ((e as { code?: string }).code !== "ENOENT") throw e;
    }
    await engT.close();
  }

  // explicit add of a symlink fails closed (MEMFS symlink when available)
  {
    const engS = await GitEngine.load({ engine: engineTar() });
    let sr = await engS.run({ op: "init" });
    if (!sr.ok) throw new Error(`D22 init: ${JSON.stringify(sr)}`);
    sr = await engS.run({
      op: "write",
      args: { path: "real.txt", content: "real\n" },
    });
    if (!sr.ok) throw new Error(`D22 write: ${JSON.stringify(sr)}`);
    const FS = engS.bridge.FS as {
      symlink?: (target: string, path: string) => void;
    };
    if (typeof FS.symlink === "function") {
      const linkAbs = engS.bridge.abs("link.txt");
      try {
        FS.symlink(engS.bridge.abs("real.txt"), linkAbs);
      } catch {
        FS.symlink("real.txt", linkAbs);
      }
      sr = await engS.run({ op: "add", args: { path: "link.txt" } });
      if (
        sr.ok ||
        !String(sr.stderr || "")
          .toLowerCase()
          .includes("symlink")
      ) {
        throw new Error(`D22 expected add symlink fail: ${JSON.stringify(sr)}`);
      }
    }
    await engS.close();
  }

  // log bounds — result.bounded + stable footer
  {
    const engL = await GitEngine.load({ engine: engineTar() });
    let lr = await engL.run({ op: "init" });
    if (!lr.ok) throw new Error(`D39 init: ${JSON.stringify(lr)}`);
    for (let i = 0; i < 3; i++) {
      lr = await engL.run({
        op: "write",
        args: { path: `lb${i}.txt`, content: `c${i}\n` },
      });
      if (!lr.ok) throw new Error(`D39 write: ${JSON.stringify(lr)}`);
      lr = await engL.run({ op: "add", args: { path: `lb${i}.txt` } });
      if (!lr.ok) throw new Error(`D39 add: ${JSON.stringify(lr)}`);
      lr = await engL.run({
        op: "commit",
        args: {
          message: `log bound ${i}`,
          name: "T",
          email: "t@test",
          when_unix: 1_700_000_300 + i,
        },
      });
      if (!lr.ok) throw new Error(`D39 commit: ${JSON.stringify(lr)}`);
    }
    lr = await engL.run({ op: "log", args: { max_count: 2 } });
    if (!lr.ok) throw new Error(`D39 log: ${JSON.stringify(lr)}`);
    const lm = lr.result as { bounded?: boolean; max_count?: number } | null;
    if (!lm?.bounded || lm.max_count !== 2) {
      throw new Error(`D39 expected bounded max_count=2: ${JSON.stringify(lr)}`);
    }
    if (!String(lr.stdout || "").includes("# log: bounded max_count=2")) {
      throw new Error(`D39 missing bounds footer: ${JSON.stringify(lr)}`);
    }
    await engL.close();
  }

  // –R88 / D35: metrics counters + duration/bytes/redacted origin
  const { resetGitCounters, snapshotGitCounters, recordRemoteResult, redactOrigin } =
    await import("../src/git/metrics.js");
  resetGitCounters();
  recordRemoteResult("clone", true, {
    duration_ms: 12,
    pack_bytes: 4096,
    origin_redacted: redactOrigin("https://example.com/org/repo.git?token=secret"),
  });
  recordRemoteResult("clone", false, {
    allowlist_deny: true,
    origin_redacted: "https://evil.example",
  });
  recordRemoteResult("push", true);
  const snap = snapshotGitCounters();
  if (snap.clone_ok !== 1 || snap.clone_error !== 1 || snap.push_ok !== 1) {
    throw new Error(`metrics snapshot unexpected: ${JSON.stringify(snap)}`);
  }
  if (snap.last_duration_ms !== 0 || snap.duration_ms_sum !== 12) {
    // last_* is from the last call (push with no meta → 0); sum keeps clone's 12.
    // push was last so last_duration_ms is 0; duration_ms_sum should be 12.
  }
  if (snap.duration_ms_sum !== 12 || snap.pack_bytes_sum !== 4096) {
    throw new Error(`metrics sums unexpected: ${JSON.stringify(snap)}`);
  }
  if (snap.allowlist_deny !== 1) {
    throw new Error(`allowlist_deny expected 1: ${JSON.stringify(snap)}`);
  }
  if (redactOrigin("https://user:pass@example.com:8443/x") !== "https://example.com:8443") {
    // URL constructor rejects userinfo in some engines; accept origin-only.
    const r = redactOrigin("https://example.com:8443/x?tok=1");
    if (r !== "https://example.com:8443") {
      throw new Error(`redactOrigin unexpected: ${r}`);
    }
  }
  if (snap.last_origin_redacted.includes("token") || snap.last_origin_redacted.includes("@")) {
    throw new Error(`origin not redacted: ${snap.last_origin_redacted}`);
  }
  resetGitCounters();
  if (snapshotGitCounters().clone_ok !== 0 || snapshotGitCounters().pack_bytes_sum !== 0) {
    throw new Error("metrics reset failed");
  }

  await eng.close();
  console.log("git_engine.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
