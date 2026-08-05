/**
 * PR11 / D7–D10: connection-bound remotes, origin allowlist, credential splice
 * (never in guest body), push policy from `policies`, auth-kind catalog parity.
 */

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  FixtureSmartHttp,
  GitEngine,
  GitRemoteOrchestrator,
  evaluatePushPolicy,
  guestArgsCarrySecrets,
  matchConnectionPattern,
  resolveGitRemote,
  spliceCredentialHeaders,
  spliceCredentialUrl,
} from "../src/git/index.js";
import type { ConnectionDefinition, ConnectionPolicyRule } from "../src/types.js";

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
  // require_approval alone (no block rule) maps correctly
  if (
    evaluatePushPolicy("github.user.other", [
      { owner: "org", pattern: "github.*", action: "require_approval" },
    ]) !== "require_approval"
  ) {
    throw new Error("require_approval policy not applied");
  }
  if (evaluatePushPolicy("no.match", policies) !== "approve") {
    throw new Error("no matching policy should default approve");
  }
  if (evaluatePushPolicy("x", []) !== "approve") {
    throw new Error("empty policies should default approve");
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

  // require_approval on binding when policies say so (not block)
  const needApproval = resolveGitRemote(
    {
      url: "https://github.com/org/repo.git",
      connection: "github.user.work",
    },
    {
      connections: conns,
      policies: [{ owner: "org", pattern: "github.*", action: "require_approval" }],
    },
  );
  if (!needApproval.ok) throw new Error(needApproval.stderr);
  if (needApproval.binding.pushAction !== "require_approval") {
    throw new Error(`expected require_approval binding, got ${needApproval.binding.pushAction}`);
  }

  // Credential splice never embeds token into JSON request path — only headers
  const hdrs = spliceCredentialHeaders(good.binding.auth);
  if (hdrs.Authorization !== "Bearer sekret-token") {
    throw new Error("bearer splice failed");
  }

  // catalog auth kinds — header + query splice (bearer covered above)
  const headerAuth = { kind: "header" as const, name: "X-GitHub-Token", value: "hdr-sekret" };
  const headerHdrs = spliceCredentialHeaders(headerAuth);
  if (headerHdrs["X-GitHub-Token"] !== "hdr-sekret") {
    throw new Error(`header splice failed: ${JSON.stringify(headerHdrs)}`);
  }
  const basicHdrs = spliceCredentialHeaders({
    kind: "basic",
    username: "nåme",
    password: "päss",
  });
  if (basicHdrs.Authorization !== "Basic bsOlbWU6cMOkc3M=") {
    throw new Error(`UTF-8 basic splice failed: ${JSON.stringify(basicHdrs)}`);
  }
  // Dual-host (git.kdl): query auth is rejected for remotes (no secrets in URLs).
  const queryAuth = { kind: "query" as const, name: "access_token", value: "q-sekret" };
  const queryHdrs = spliceCredentialHeaders(queryAuth);
  if (Object.keys(queryHdrs).length !== 0) {
    throw new Error(`query auth must not add headers: ${JSON.stringify(queryHdrs)}`);
  }
  const qUrl = spliceCredentialUrl("https://github.com/org/repo.git", queryAuth);
  if (qUrl.includes("access_token") || qUrl.includes("q-sekret")) {
    throw new Error(`query url splice must be a no-op: ${qUrl}`);
  }
  const queryResolve = resolveGitRemote(
    { url: "https://github.com/org/repo.git", connection: "github.user.work" },
    {
      connections: [
        {
          ref: "github.user.work",
          auth: queryAuth,
          origins: ["https://github.com"],
        },
      ],
    },
  );
  if (queryResolve.ok || !String(queryResolve.stderr).includes("query auth not supported")) {
    throw new Error(`query auth resolve must fail: ${JSON.stringify(queryResolve)}`);
  }
  const invalidAuthResolve = resolveGitRemote(
    { url: "https://github.com/org/repo.git", connection: "github.user.invalid" },
    {
      connections: [
        {
          ref: "github.user.invalid",
          auth: { kind: "basic", username: "bad:name", password: "secret" },
          origins: ["https://github.com"],
        },
      ],
    },
  );
  if (invalidAuthResolve.ok || !invalidAuthResolve.stderr.includes("invalid connection auth")) {
    throw new Error(`malformed catalog auth must fail: ${JSON.stringify(invalidAuthResolve)}`);
  }
  let invalidHeaderRejected = false;
  try {
    spliceCredentialHeaders({ kind: "header", name: "X-Test\nInjected", value: "secret" });
  } catch {
    invalidHeaderRejected = true;
  }
  if (!invalidHeaderRejected) throw new Error("credential header injection must fail closed");
  let duplicateAuthRejected = false;
  try {
    spliceCredentialHeaders({ kind: "bearer", token: "secret" }, { authorization: "existing" });
  } catch {
    duplicateAuthRejected = true;
  }
  if (!duplicateAuthRejected) throw new Error("duplicate Authorization header must fail closed");
  // none is a no-op
  if (Object.keys(spliceCredentialHeaders({ kind: "none" })).length !== 0) {
    throw new Error("none auth should not add headers");
  }

  // guest body cannot pass auth secrets — reject, never splice from args
  if (!guestArgsCarrySecrets({ url: "https://github.com/r.git", token: "evil" })) {
    throw new Error("guestArgsCarrySecrets should detect token");
  }
  if (!guestArgsCarrySecrets({ auth: { kind: "bearer", token: "x" } })) {
    throw new Error("guestArgsCarrySecrets should detect auth");
  }
  if (guestArgsCarrySecrets({ url: "https://github.com/r.git", connection: "c" })) {
    throw new Error("public locator + connection ref are not secrets");
  }

  // GIT-024: recursive secret-key rejection (maps, arrays, case) with bounds.
  if (!guestArgsCarrySecrets({ url: "https://x/r.git", nested: { Token: "evil" } })) {
    throw new Error("GIT-024: nested map case variant must reject");
  }
  if (!guestArgsCarrySecrets({ url: "https://x/r.git", items: [{ password: "x" }] })) {
    throw new Error("GIT-024: nested array secret key must reject");
  }
  if (
    guestArgsCarrySecrets({
      url: "https://x/r.git",
      meta: { headers: { "x-custom": "ok" }, note: "safe" },
    })
  ) {
    throw new Error("GIT-024: safe nested body must not reject");
  }
  // Excessive depth without secret keys → fail closed.
  {
    let deep: Record<string, unknown> = { leaf: "ok" };
    for (let i = 0; i < 12; i++) {
      deep = { wrap: deep };
    }
    if (!guestArgsCarrySecrets(deep)) {
      throw new Error("GIT-024: excessive depth must fail closed");
    }
  }
  // Excessive node count without secret keys → fail closed.
  {
    const wide: Record<string, unknown> = {};
    for (let i = 0; i < 300; i++) {
      wide[`k${i}`] = i;
    }
    if (!guestArgsCarrySecrets(wide)) {
      throw new Error("GIT-024: excessive node count must fail closed");
    }
  }
  const nestedToken = resolveGitRemote(
    {
      url: "https://github.com/org/repo.git",
      connection: "github.user.work",
      options: { auth: { kind: "bearer", token: "nested-smuggle" } },
    },
    { connections: conns },
  );
  if (nestedToken.ok || !String(nestedToken.stderr).includes("auth secrets")) {
    throw new Error(`GIT-024 nested auth must reject: ${JSON.stringify(nestedToken)}`);
  }
  const guestToken = resolveGitRemote(
    {
      url: "https://github.com/org/repo.git",
      connection: "github.user.work",
      token: "guest-smuggled-token",
    },
    { connections: conns },
  );
  if (guestToken.ok || !String(guestToken.stderr).includes("auth secrets")) {
    throw new Error(`guest token in args must reject: ${JSON.stringify(guestToken)}`);
  }
  const guestAuth = resolveGitRemote(
    {
      url: "https://github.com/org/repo.git",
      auth: { kind: "bearer", token: "guest-smuggled" },
    },
    { connections: conns },
  );
  if (guestAuth.ok || !String(guestAuth.stderr).includes("auth secrets")) {
    throw new Error(`guest auth object must reject: ${JSON.stringify(guestAuth)}`);
  }
  // Case-insensitive key (Authorization)
  const guestAuthz = resolveGitRemote(
    {
      url: "https://github.com/org/repo.git",
      Authorization: "Bearer guest",
    },
    {},
  );
  if (guestAuthz.ok) throw new Error("Authorization arg must reject");

  // Orchestrator uses connection + splices auth into transport (fixture records lastAuth)
  const eng = await GitEngine.load({
    engine: engineTar(),
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
  const userinfo = resolveGitRemote({ url: "https://user:token@github.com/org/repo.git" }, {});
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

  // bare URL (no connection) + empty allowOrigins fails closed at orch.
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

  // catalog-shaped header auth reaches transport (fixture records lastAuth)
  const headerConns: ConnectionDefinition[] = [
    {
      ref: "git.user.hdr",
      auth: { kind: "header", name: "X-Token", value: "hdr-sekret-xyz" },
      origins: ["https://github.com"],
    },
  ];
  const hdrHttp = new FixtureSmartHttp();
  hdrHttp.add(
    "https://github.com/org/hdr.git",
    [{ name: "refs/heads/main", hash }],
    new Uint8Array(0),
  );
  const hdrOrch = new GitRemoteOrchestrator(eng, {
    http: hdrHttp,
    connections: headerConns,
  });
  const hdrR = await hdrOrch.handle({
    op: "clone",
    args: {
      url: "https://github.com/org/hdr.git",
      connection: "git.user.hdr",
    },
  });
  if (String(hdrR.stderr || "").includes("list-refs failed")) {
    throw new Error(JSON.stringify(hdrR));
  }
  if (
    hdrHttp.lastAuth?.kind !== "header" ||
    (hdrHttp.lastAuth as { value?: string }).value !== "hdr-sekret-xyz"
  ) {
    throw new Error(`expected header auth on transport: ${JSON.stringify(hdrHttp.lastAuth)}`);
  }
  if (JSON.stringify(hdrR).includes("hdr-sekret-xyz")) {
    throw new Error("header secret leaked into response");
  }

  // via orch: guest-smuggled token never dials
  const smuggleHttp = new FixtureSmartHttp();
  smuggleHttp.add(
    "https://github.com/org/repo.git",
    [{ name: "refs/heads/main", hash }],
    new Uint8Array(0),
  );
  const smuggleOrch = new GitRemoteOrchestrator(eng, {
    http: smuggleHttp,
    connections: conns,
  });
  const smuggle = await smuggleOrch.handle({
    op: "fetch",
    args: {
      url: "https://github.com/org/repo.git",
      connection: "github.user.work",
      token: "should-not-work",
    },
  });
  if (smuggle.ok || !String(smuggle.stderr || "").includes("auth secrets")) {
    throw new Error(`orch must reject guest token: ${JSON.stringify(smuggle)}`);
  }
  if (smuggleHttp.listRefsCalls !== 0) {
    throw new Error("guest secret reject must not dial");
  }

  // push block from policies short-circuits before dial
  const blockHttp = new FixtureSmartHttp();
  blockHttp.add(
    "https://github.com/org/repo.git",
    [{ name: "refs/heads/main", hash }],
    new Uint8Array(0),
  );
  const blockOrch = new GitRemoteOrchestrator(eng, {
    http: blockHttp,
    connections: conns,
    policies: [{ owner: "org", pattern: "*", action: "block" }],
  });
  const blocked = await blockOrch.handle({
    op: "push",
    args: {
      url: "https://github.com/org/repo.git",
      connection: "github.user.work",
    },
  });
  if (blocked.ok || !String(blocked.stderr || "").includes("blocked by policy")) {
    throw new Error(`expected push block: ${JSON.stringify(blocked)}`);
  }
  if (blockHttp.listRefsCalls !== 0) {
    throw new Error("policy block must not dial list-refs");
  }

  await eng.close();
  console.log("git_connections.test SUCCESS");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
