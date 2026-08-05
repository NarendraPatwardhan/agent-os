/**
 * PR12: push.prepare → PushPacks → push.complete; read-only reject; approval policy.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
  parseReceiveStatus,
} from "../src/git/index.js";

function engineTar(): Uint8Array {
  const rel = process.env.MC_GIT_ENGINE_TAR || "";
  if (!rel) throw new Error("MC_GIT_ENGINE_TAR is not set (run under bazel test)");
  const rf = process.env.RUNFILES_DIR;
  const candidates = [
    rel && rf ? join(rf, rel) : "",
    rel && rf ? join(rf, "_main", rel) : "",
    rel,
  ].filter(Boolean) as string[];
  for (const c of candidates) {
    if (c && existsSync(c)) return new Uint8Array(readFileSync(c));
  }
  throw new Error(`git-engine.tar not found (MC_GIT_ENGINE_TAR=${rel})`);
}

async function main() {
  const reportOk = "000eunpack ok\n0017ok refs/heads/main\n0000";
  if (!parseReceiveStatus(reportOk, true).ok) {
    throw new Error("negotiated report-status receipt should succeed");
  }
  if (parseReceiveStatus("", true).ok) {
    throw new Error("negotiated report-status must reject a missing receipt");
  }
  if (!parseReceiveStatus("", false).ok) {
    throw new Error("HTTP success is the receipt when report-status was not negotiated");
  }

  // Read-only reject (checked before origin policy)
  {
    const eng = await GitEngine.load({ engine: engineTar(), readOnly: true });
    const http = new FixtureSmartHttp();
    const orch = new GitRemoteOrchestrator(eng, {
      http,
      readOnly: true,
      allowOrigins: ["https://example.com"],
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
    const eng = await GitEngine.load({ engine: engineTar() });
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
    // Fixture advertises remote so lease path runs; default engine packbuilder (no inject).
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
      policies: [{ owner: "user", pattern: "git.user.*", action: "require_approval" }],
      onPushApproval: async () => {
        approved = true;
        return true;
      },
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
    // Real packbuilder bytes must start with PACK magic.
    const tip = await eng.run({ op: "rev-parse", args: { rev: "HEAD" } });
    const tipHex = String(tip.stdout || "")
      .trim()
      .split(/\s+/)[0];
    if (!/^[0-9a-f]{40}$/i.test(tipHex)) {
      throw new Error(`bad HEAD for pack check: ${tipHex}`);
    }
    const pack = await eng.buildPushPack([tipHex]);
    if (
      pack.byteLength < 4 ||
      pack[0] !== 0x50 ||
      pack[1] !== 0x41 ||
      pack[2] !== 0x43 ||
      pack[3] !== 0x4b
    ) {
      throw new Error("buildPushPack missing PACK magic");
    }
    try {
      await eng.buildPushPack([]);
      throw new Error("empty oids should fail closed");
    } catch (e) {
      if (!String(e).includes("no oids") && !String(e).includes("ge_pack_build")) {
        throw e;
      }
    }
    await eng.close();
  }

  // Policy block (most restrictive) — short-circuit before prepare/dial
  {
    const eng = await GitEngine.load({ engine: engineTar() });
    await eng.run({ op: "init" });
    const http = new FixtureSmartHttp();
    const orch = new GitRemoteOrchestrator(eng, {
      http,
      allowOrigins: ["https://example.com"],
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

  // require_approval without onPushApproval fails closed after prepare
  {
    const eng = await GitEngine.load({ engine: engineTar() });
    await eng.run({ op: "init" });
    await eng.run({
      op: "write",
      args: { path: "a.txt", content: "need-approval\n" },
    });
    await eng.run({ op: "add", args: { path: "a.txt" } });
    await eng.run({
      op: "commit",
      args: {
        message: "c",
        name: "P",
        email: "p@p",
        when_unix: 1_700_000_150,
      },
    });
    const http = new FixtureSmartHttp();
    http.add(
      "https://example.com/r.git",
      [{ name: "refs/heads/master", hash: "0000000000000000000000000000000000000000" }],
      new Uint8Array(0),
    );
    const orch = new GitRemoteOrchestrator(eng, {
      http,
      connections: [
        {
          ref: "git.user.demo",
          auth: { kind: "none" },
          origins: ["https://example.com"],
        },
      ],
      policies: [{ owner: "user", pattern: "git.user.*", action: "require_approval" }],
      // no onPushApproval → fail closed
    });
    const r = await orch.handle({
      op: "push",
      args: {
        url: "https://example.com/r.git",
        connection: "git.user.demo",
      },
    });
    if (r.ok || !String(r.stderr || "").includes("requires approval")) {
      throw new Error(`require_approval fail-closed: ${JSON.stringify(r)}`);
    }
    if (http.lastPush) {
      throw new Error("denied approval must not pushPacks");
    }

    // Explicit deny callback
    let asked = false;
    const http2 = new FixtureSmartHttp();
    http2.add(
      "https://example.com/r.git",
      [{ name: "refs/heads/master", hash: "0000000000000000000000000000000000000000" }],
      new Uint8Array(0),
    );
    const orchDeny = new GitRemoteOrchestrator(eng, {
      http: http2,
      connections: [
        {
          ref: "git.user.demo",
          auth: { kind: "none" },
          origins: ["https://example.com"],
        },
      ],
      policies: [{ owner: "user", pattern: "git.user.*", action: "require_approval" }],
      onPushApproval: async () => {
        asked = true;
        return false;
      },
    });
    const denied = await orchDeny.handle({
      op: "push",
      args: {
        url: "https://example.com/r.git",
        connection: "git.user.demo",
      },
    });
    if (!asked) throw new Error("onPushApproval not invoked");
    if (denied.ok || !String(denied.stderr || "").includes("requires approval")) {
      throw new Error(`require_approval deny: ${JSON.stringify(denied)}`);
    }
    if (http2.lastPush) {
      throw new Error("denied callback must not pushPacks");
    }
    await eng.close();
  }

  // delete-ref push — newHash all-zero, empty pack, fixture receive-status ok
  {
    const eng = await GitEngine.load({ engine: engineTar() });
    await eng.run({ op: "init" });
    await eng.run({
      op: "write",
      args: { path: "d.txt", content: "del\n" },
    });
    await eng.run({ op: "add", args: { path: "d.txt" } });
    await eng.run({
      op: "commit",
      args: {
        message: "c",
        name: "P",
        email: "p@p",
        when_unix: 1_700_000_200,
      },
    });
    const tip = await eng.run({ op: "rev-parse", args: { rev: "HEAD" } });
    const tipHex = String(tip.stdout || "")
      .trim()
      .split(/\s+/)[0];
    if (!/^[0-9a-f]{40}$/i.test(tipHex)) {
      throw new Error(`bad HEAD for delete push: ${tipHex}`);
    }

    const http = new FixtureSmartHttp();
    http.add(
      "https://example.com/r.git",
      [{ name: "refs/heads/master", hash: tipHex, capabilities: ["delete-refs"] }],
      new Uint8Array(0),
    );
    http.pushResult = { ok: true, message: "ok" };
    const orch = new GitRemoteOrchestrator(eng, {
      http,
      allowOrigins: ["https://example.com"],
    });
    const r = await orch.handle({
      op: "push",
      args: {
        url: "https://example.com/r.git",
        delete: true,
      },
    });
    if (!r.ok) throw new Error(`expected delete push ok: ${JSON.stringify(r)}`);
    if (!http.lastPush) throw new Error("delete push not recorded");
    if (http.lastPush.packLen !== 0) {
      throw new Error(`delete-only must send empty pack, got ${http.lastPush.packLen}`);
    }
    const cmds = http.lastPush.commands;
    if (!cmds?.length) throw new Error("delete push missing commands");
    const zero = "0000000000000000000000000000000000000000";
    for (const c of cmds) {
      if (c.newHash !== zero) {
        throw new Error(`delete newHash must be zero: ${JSON.stringify(c)}`);
      }
      if (c.oldHash !== tipHex.toLowerCase() && c.oldHash !== tipHex) {
        // oldHash should be remote tip (lease)
        if (!/^[0-9a-f]{40}$/i.test(c.oldHash) || c.oldHash === zero) {
          throw new Error(`delete oldHash should be remote tip: ${JSON.stringify(c)}`);
        }
      }
    }
    // Cruel: non-delete empty pack still fails
    const http2 = new FixtureSmartHttp();
    http2.add(
      "https://example.com/r.git",
      [{ name: "refs/heads/master", hash: zero }],
      new Uint8Array(0),
    );
    const orchEmpty = new GitRemoteOrchestrator(eng, {
      http: http2,
      allowOrigins: ["https://example.com"],
      buildPushPack: async () => new Uint8Array(0),
    });
    const bad = await orchEmpty.handle({
      op: "push",
      args: { url: "https://example.com/r.git" },
    });
    if (bad.ok || !String(bad.stderr || "").includes("empty pack")) {
      throw new Error(`non-delete empty pack must fail closed: ${JSON.stringify(bad)}`);
    }
    await eng.close();
  }

  // pack with haves (parent) smaller than full tip pack
  {
    const eng = await GitEngine.load({ engine: engineTar() });
    await eng.run({ op: "init" });
    await eng.run({
      op: "write",
      args: { path: "a.txt", content: "one\n" },
    });
    await eng.run({ op: "add", args: { path: "a.txt" } });
    await eng.run({
      op: "commit",
      args: {
        message: "c1",
        name: "P",
        email: "p@p",
        when_unix: 1_700_000_300,
      },
    });
    const p1 = String((await eng.run({ op: "rev-parse", args: { rev: "HEAD" } })).stdout || "")
      .trim()
      .split(/\s+/)[0]!;
    await eng.run({
      op: "write",
      args: { path: "b.txt", content: "two-more-bytes-for-thin\n" },
    });
    await eng.run({ op: "add", args: { path: "b.txt" } });
    await eng.run({
      op: "commit",
      args: {
        message: "c2",
        name: "P",
        email: "p@p",
        when_unix: 1_700_000_301,
      },
    });
    const p2 = String((await eng.run({ op: "rev-parse", args: { rev: "HEAD" } })).stdout || "")
      .trim()
      .split(/\s+/)[0]!;
    const full = await eng.buildPushPack([p2]);
    const thin = await eng.buildPushPack([p2], [p1]);
    if (thin.byteLength >= full.byteLength) {
      throw new Error(
        `R48 haves pack should be smaller: thin=${thin.byteLength} full=${full.byteLength}`,
      );
    }
    if (thin[0] !== 0x50 || thin[1] !== 0x41 || thin[2] !== 0x43 || thin[3] !== 0x4b) {
      throw new Error("thin pack missing PACK magic");
    }
    await eng.close();
  }

  // args.filter reaches transport; fixture ignores it and still returns pack
  {
    const eng = await GitEngine.load({ engine: engineTar() });
    const pack = new Uint8Array([0x50, 0x41, 0x43, 0x4b, 0, 0, 0, 2, 0, 0, 0, 0]);
    // minimal invalid-but-nonempty PACK magic header so empty-pack gate passes;
    // import may fail — we only assert filter is recorded and fetch is invoked.
    const http = new FixtureSmartHttp();
    const tip = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    http.add("https://example.com/r.git", [{ name: "refs/heads/master", hash: tip }], pack);
    const orch = new GitRemoteOrchestrator(eng, {
      http,
      allowOrigins: ["https://example.com"],
    });
    await orch.handle({
      op: "clone",
      args: {
        url: "https://example.com/r.git",
        filter: "blob:none",
      },
    });
    if (!http.lastFetch) throw new Error("clone did not call fetchPacks");
    if (http.lastFetch.filter !== "blob:none") {
      throw new Error(`expected filter blob:none, got ${http.lastFetch.filter}`);
    }
    await eng.close();
  }

  console.log("git_push.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
