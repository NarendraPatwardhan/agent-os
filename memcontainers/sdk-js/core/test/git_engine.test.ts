/**
 * PR3–PR5: GitEngine.run + gitfs ctl drain + dial refuse (no full VM).
 * Requires MC_GIT_ENGINE_JS → runfiles path of git_engine.js (sibling of .wasm).
 */

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { GitEngine } from "../src/git/index.js";

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

  const dial = await eng.run({
    op: "clone",
    args: { url: "https://example.com/r.git" },
  });
  if (dial.ok || !String(dial.stderr || "").includes("orchestrator")) {
    throw new Error(`dial should fail closed: ${JSON.stringify(dial)}`);
  }

  // PR4/PR5: gitfs worktree + synthetic .git + ctl drain
  const driver = eng.asMountDriver();

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
  const head = new TextDecoder().decode(await driver.open("/.git/HEAD"));
  if (!head.startsWith("ref: refs/heads/")) {
    throw new Error(`synthetic HEAD: ${JSON.stringify(head)}`);
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
  // Engine sparse-set (cone-only config write + checkout when HEAD exists).
  const ss = await eng.run({
    op: "sparse-set",
    args: { patterns: "keep" },
  });
  if (!ss.ok) {
    throw new Error(`sparse-set: ${JSON.stringify(ss)}`);
  }

  await eng.close();
  console.log("git_engine.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
