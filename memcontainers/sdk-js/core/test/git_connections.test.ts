/**
 * PR11: connection-bound remotes, origin allowlist, credential splice (never in guest body).
 */

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import {
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
  evaluatePushPolicy,
  matchConnectionPattern,
  resolveGitRemote,
  spliceCredentialHeaders,
} from "../src/git/index.js";
import type { ConnectionDefinition, ConnectionPolicyRule } from "../src/types.js";

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
  throw new Error(`engine dir not found`);
}

async function main() {
  // Pattern matching
  if (!matchConnectionPattern("github.user.*", "github.user.work")) {
    throw new Error("prefix match failed");
  }
  if (matchConnectionPattern("github.org.*", "github.user.work")) {
    throw new Error("should not match");
  }

  const policies: ConnectionPolicyRule[] = [
    { owner: "org", pattern: "github.*", action: "require_approval" },
    { owner: "user", pattern: "github.user.work", action: "block" },
  ];
  if (evaluatePushPolicy("github.user.work", policies) !== "block") {
    throw new Error("most restrictive should be block");
  }

  const conns: ConnectionDefinition[] = [
    {
      ref: "github.user.work",
      auth: { kind: "bearer", token: "sekret-token" },
      origins: ["https://github.com"],
    },
  ];

  // Origin allowlist via connection
  const bad = resolveGitRemote(
    { url: "https://evil.example/r.git", connection: "github.user.work" },
    { connections: conns },
  );
  if (bad.ok) throw new Error("evil origin should fail");

  const good = resolveGitRemote(
    {
      url: "https://github.com/org/repo.git",
      connection: "github.user.work",
    },
    { connections: conns, policies },
  );
  if (!good.ok) throw new Error(good.stderr);
  if (good.binding.auth.kind !== "bearer") throw new Error("auth missing");
  if (good.binding.pushAction !== "block") throw new Error("policy not applied");

  // Credential splice never embeds token into JSON request path — only headers
  const hdrs = spliceCredentialHeaders(good.binding.auth);
  if (hdrs.Authorization !== "Bearer sekret-token") {
    throw new Error("bearer splice failed");
  }

  // Orchestrator uses connection + splices auth into transport (fixture records lastAuth)
  const dir = engineDir();
  const eng = await GitEngine.load({
    baseUrl: pathToFileURL(dir.endsWith("/") ? dir : dir + "/").href,
  });
  const http = new FixtureSmartHttp();
  const hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  http.add(
    "https://github.com/org/repo.git",
    [{ name: "refs/heads/main", hash }],
    new Uint8Array(0),
  );
  const orch = new GitRemoteOrchestrator(eng, {
    http,
    connections: conns,
    policies: [{ owner: "org", pattern: "*", action: "approve" }],
  });
  const r = await orch.handle({
    op: "clone",
    args: {
      url: "https://github.com/org/repo.git",
      connection: "github.user.work",
    },
  });
  if (String(r.stderr || "").includes("list-refs failed")) {
    throw new Error(JSON.stringify(r));
  }
  if (http.lastAuth?.kind !== "bearer") {
    throw new Error(`expected bearer on transport, got ${JSON.stringify(http.lastAuth)}`);
  }
  // Response must not echo secret
  if (JSON.stringify(r).includes("sekret-token")) {
    throw new Error("secret leaked into response");
  }

  // Unknown connection
  const unk = await orch.handle({
    op: "fetch",
    args: { connection: "no.such.conn" },
  });
  if (unk.ok || !String(unk.stderr || "").includes("unknown connection")) {
    throw new Error(`expected unknown connection: ${JSON.stringify(unk)}`);
  }

  // Empty origins → fail closed (no credential to attacker URL)
  const emptyOrigins: ConnectionDefinition[] = [
    { ref: "github.user.work", auth: { kind: "bearer", token: "sekret-token" } },
  ];
  const open = resolveGitRemote(
    { url: "https://evil.example/r.git", connection: "github.user.work" },
    { connections: emptyOrigins },
  );
  if (open.ok) throw new Error("empty origins must fail closed");

  // Embedded credentials in URL rejected
  const userinfo = resolveGitRemote(
    { url: "https://user:token@github.com/org/repo.git" },
    {},
  );
  if (userinfo.ok) throw new Error("userinfo URL must be rejected");

  // Canonical origin match (not path prefix confusion)
  const pathy: ConnectionDefinition[] = [
    {
      ref: "github.user.work",
      auth: { kind: "bearer", token: "sekret-token" },
      origins: ["https://github.com"],
    },
  ];
  const org = resolveGitRemote(
    {
      url: "https://github.com/organization/repo.git",
      connection: "github.user.work",
    },
    { connections: pathy },
  );
  if (!org.ok) throw new Error(`canonical origin should allow: ${org.stderr}`);

  // R32: bare URL (no connection) + empty allowOrigins fails closed at orch.
  const bareHttp = new FixtureSmartHttp();
  bareHttp.add(
    "https://example.com/r.git",
    [{ name: "refs/heads/main", hash: "cccccccccccccccccccccccccccccccccccccccc" }],
    new Uint8Array(0),
  );
  const bareOrch = new GitRemoteOrchestrator(eng, { http: bareHttp });
  const bareResp = await bareOrch.handle({
    op: "clone",
    args: { url: "https://example.com/r.git" },
  });
  if (bareResp.ok || !String(bareResp.stderr || "").includes("not allowlisted")) {
    throw new Error(`R32 bare URL must fail closed: ${JSON.stringify(bareResp)}`);
  }
  if (bareHttp.listRefsCalls !== 0) {
    throw new Error("R32 bare deny must not dial");
  }
  // Explicit allowOrigins permits bare URL through the gate (fixture path).
  const bareOkOrch = new GitRemoteOrchestrator(eng, {
    http: bareHttp,
    allowOrigins: ["https://example.com"],
  });
  const bareOk = await bareOkOrch.handle({
    op: "clone",
    args: { url: "https://example.com/r.git" },
  });
  if (String(bareOk.stderr || "").includes("not allowlisted")) {
    throw new Error(`allowOrigins should permit bare fixture URL: ${JSON.stringify(bareOk)}`);
  }
  if (bareHttp.listRefsCalls < 1) {
    throw new Error("expected listRefs after allowOrigins gate");
  }

  await eng.close();
  console.log("git_connections.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
