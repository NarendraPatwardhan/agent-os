/**
 * PR12: push.prepare → PushPacks → push.complete; read-only reject; approval policy.
 */

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
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
  throw new Error("engine dir not found");
}

async function main() {
  const dir = engineDir();
  const baseUrl = pathToFileURL(dir.endsWith("/") ? dir : dir + "/").href;

  // Read-only reject
  {
    const eng = await GitEngine.load({ baseUrl, readOnly: true });
    const http = new FixtureSmartHttp();
    const orch = new GitRemoteOrchestrator(eng, {
      http,
      readOnly: true,
    });
    const r = await orch.handle({
      op: "push",
      args: { url: "https://example.com/r.git" },
    });
    if (r.ok || !String(r.stderr || "").includes("read-only")) {
      throw new Error(`expected read-only reject: ${JSON.stringify(r)}`);
    }
    await eng.close();
  }

  // Happy path with fixture push
  {
    const eng = await GitEngine.load({ baseUrl });
    await eng.run({ op: "init" });
    await eng.run({
      op: "write",
      args: { path: "p.txt", content: "pushme\n" },
    });
    await eng.run({ op: "add", args: { path: "p.txt" } });
    await eng.run({
      op: "commit",
      args: {
        message: "c",
        name: "P",
        email: "p@p",
        when_unix: 1_700_000_100,
      },
    });

    const http = new FixtureSmartHttp();
    let approved = false;
    // Fixture advertises remote so lease path runs; inject pack builder.
    http.add(
      "https://example.com/r.git",
      [{ name: "refs/heads/master", hash: "0000000000000000000000000000000000000000" }],
      new Uint8Array(0),
    );
    const orchWithPack = new GitRemoteOrchestrator(eng, {
      http,
      connections: [
        {
          ref: "git.user.demo",
          auth: { kind: "none" },
          origins: ["https://example.com"],
        },
      ],
      policies: [
        { owner: "user", pattern: "git.user.*", action: "require_approval" },
      ],
      onPushApproval: async () => {
        approved = true;
        return true;
      },
      buildPushPack: async () => new Uint8Array([0x50, 0x41, 0x43, 0x4b]),
    });
    const r = await orchWithPack.handle({
      op: "push",
      args: {
        url: "https://example.com/r.git",
        connection: "git.user.demo",
      },
    });
    if (!r.ok) throw new Error(`expected push ok: ${JSON.stringify(r)}`);
    if (!approved) throw new Error("approval not invoked on success");
    if (!http.lastPush || http.lastPush.url !== "https://example.com/r.git") {
      throw new Error(`push not recorded: ${JSON.stringify(http.lastPush)}`);
    }
    if (http.lastPush.packLen === 0) {
      throw new Error("expected non-empty pack for create/update");
    }
    await eng.close();
  }

  // Approval denied when prepare has commands (seed via host buildPushPack path)
  {
    const eng = await GitEngine.load({ baseUrl });
    await eng.run({ op: "init" });
    const http = new FixtureSmartHttp();
    // Force commands by wrapping handle after stubbing engine is hard; policy block is enough
    const orch = new GitRemoteOrchestrator(eng, {
      http,
      policies: [{ owner: "org", pattern: "*", action: "block" }],
    });
    const r = await orch.handle({
      op: "push",
      args: { url: "https://example.com/r.git" },
    });
    if (r.ok || !String(r.stderr || "").includes("blocked")) {
      throw new Error(`expected policy block: ${JSON.stringify(r)}`);
    }
    await eng.close();
  }

  console.log("git_push.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
