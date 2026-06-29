// @mc/core embedded backend over @mc/host: a real `mc.create()` boots the SAME kernel.wasm + base.tar
// the wasmtime e2e uses (passed as bytes, so no env/runfiles indirection through artifacts.ts), and the
// Vm API runs a real command + a real fs round-trip. This exercises the SDK library through the
// @mc/host → @mc/contracts package deps at RUNTIME — the layer the host-only parity test cannot reach.

import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mc } from "../src/index.js";
import type { CreateOptions, PermissionRequest, ToolPolicyRule, Vm } from "../src/index.js";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

interface RecordedRequest {
  method: string;
  url: string;
  headers: Record<string, string | string[] | undefined>;
  body: string;
}

interface ToolApprovalFact {
  connection: string;
  method: string;
  url: string;
  origin: string;
  argsDigest?: string;
}

async function recordingServer(): Promise<{
  origin: string;
  requests: RecordedRequest[];
  close(): Promise<void>;
}> {
  const requests: RecordedRequest[] = [];
  const server = createServer((req, res) => {
    const chunks: Uint8Array[] = [];
    req.on("data", (chunk: Uint8Array) => chunks.push(chunk));
    req.on("end", () => {
      requests.push({
        method: req.method ?? "",
        url: req.url ?? "",
        headers: req.headers,
        body: new TextDecoder().decode(Buffer.concat(chunks)),
      });
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ marker: "js-host-adapter", ok: true }));
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("recording server did not bind a TCP port");
  return {
    origin: `http://127.0.0.1:${address.port}`,
    requests,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

function toolApprovalFact(req: PermissionRequest): ToolApprovalFact {
  if (req.kind !== "tool_approval") {
    throw new Error(`unexpected permission prompt kind ${req.kind}`);
  }
  const raw = req as unknown as Record<string, unknown>;
  for (const oldField of [
    "address",
    "integration",
    "owner",
    "tool",
    "description",
    "approvalDescription",
    "argsPreview",
    "argsSha256",
    "policy",
  ]) {
    if (oldField in raw) throw new Error(`tool_approval leaked old guest field ${oldField}`);
  }
  return {
    connection: req.connection,
    method: req.method,
    url: req.url,
    origin: req.origin,
    ...(req.argsDigest ? { argsDigest: req.argsDigest } : {}),
  };
}

function issueCreateArgs(title: string): string {
  return JSON.stringify({
    path: { owner: "octo", repo: "hello" },
    body: { title },
  });
}

function clearRequests(requests: RecordedRequest[]): void {
  requests.splice(0, requests.length);
}

function count<T>(items: readonly T[]): number {
  return items.length;
}

async function closeAll(vms: Vm[]): Promise<void> {
  for (const vm of vms.reverse()) await vm.close();
}

async function main(): Promise<void> {
  const kernel = new Uint8Array(readFileSync(runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM")));
  const image = new Uint8Array(readFileSync(runfile(process.env.MC_BASE_IMAGE, "MC_BASE_IMAGE")));
  const loomImage = new Uint8Array(readFileSync(runfile(process.env.MC_LOOM_IMAGE, "MC_LOOM_IMAGE")));
  const githubFixture = readFileSync(runfile(process.env.MC_GITHUB_FIXTURE, "MC_GITHUB_FIXTURE"), "utf8");

  // Bytes passed directly → no MC_STORE / defaultKernel env path; the embedded backend (the JS host)
  // boots the kernel in-process.
  const vm = await mc.create({ kernel, image, deterministic: true });
  try {
    const r = await vm.exec("echo core-ok");
    if (r.exitCode !== 0 || r.stdout.trim() !== "core-ok") {
      throw new Error(`vm.exec mismatch: exit=${r.exitCode} stdout=${JSON.stringify(r.stdout)}`);
    }
    await vm.fs.write("/tmp/core", "hello");
    if ((await vm.fs.readText("/tmp/core")) !== "hello") {
      throw new Error("vm.fs round-trip mismatch");
    }

    // Activate /svc/tools while its boot catalog is empty, then register a tool at runtime. This proves
    // vm.tool() updates the warm service's live catalog instead of only rewriting the boot catalog tree.
    const before = await vm.exec("tools list");
    if (before.exitCode !== 0 || !before.stdout.includes('"tools":[]')) {
      throw new Error(`initial tools catalog mismatch: exit=${before.exitCode} stdout=${before.stdout}`);
    }
    await vm.tool({
      name: "dynamic greet",
      address: "host.org.main.dynamicGreet",
      description: "Greet dynamically",
      run: (input) => ({ message: `hello ${String(input.name ?? "world")}` }),
    });
    const after = await vm.exec("tools call host.org.main.dynamicGreet '{\"name\":\"Ada\"}'");
    if (after.exitCode !== 0 || !after.stdout.includes('"message":"hello Ada"')) {
      throw new Error(`runtime tool registration mismatch: exit=${after.exitCode} stdout=${after.stdout}`);
    }
  } finally {
    await vm.close();
  }

  const server = await recordingServer();
  const specDir = mkdtempSync(join(tmpdir(), "mc-catalog-"));
  const specPath = join(specDir, "github_issues.openapi.json");
  writeFileSync(specPath, githubFixture.replace("https://api.github.com", server.origin));
  const githubOptions = (extra: Partial<CreateOptions> = {}): CreateOptions => ({
    kernel,
    image,
    deterministic: true,
    net: true,
    permissions: { network: "allow" },
    connections: [
      {
        ref: "github.org.main",
        auth: { kind: "bearer", token: "fixture-token" },
        origins: [server.origin],
        spec: { path: specPath, sourceFormat: "json" },
      },
    ],
    tools: ["github/issues"],
    ...extra,
  });
  const created: Vm[] = [];
  const defaultPrompts: ToolApprovalFact[] = [];
  let approvalMode: "allow" | "reject" = "allow";
  const githubVm = await mc.create(
    githubOptions({
      onPermission: (req) => {
        if (req.kind !== "tool_approval") {
          req.allow();
          return;
        }
        const fact = toolApprovalFact(req);
        defaultPrompts.push(fact);
        if (approvalMode === "reject") req.reject("no");
        else req.allow();
      },
    }),
  );
  created.push(githubVm);
  try {
    console.log("phase: github catalog GET");
    const listed = await githubVm.exec("tools list");
    if (
      listed.exitCode !== 0 ||
      !listed.stdout.includes("github.org.main.issues-list") ||
      !listed.stdout.includes("github.org.main.issues-create") ||
      listed.stdout.includes("github.org.main.pulls-list")
    ) {
      throw new Error(`host-compiled GitHub issues catalog mismatch: ${listed.stdout}`);
    }

    const called = await githubVm.exec(
      "tools call github.org.main.issues-list '{\"path\":{\"owner\":\"octo\",\"repo\":\"hello\"},\"query\":{\"state\":\"open\"}}'",
    );
    if (called.exitCode !== 0 || !called.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(`generated GitHub tool call mismatch: exit=${called.exitCode} stdout=${called.stdout}`);
    }
    const listRequests = [...server.requests];
    if (listRequests.length !== 1) {
      throw new Error(`expected one adapter egress request, saw ${listRequests.length}`);
    }
    const request = listRequests[0]!;
    if (request.method !== "GET" || request.url !== "/repos/octo/hello/issues?state=open") {
      throw new Error(`adapter request shape mismatch: ${request.method} ${request.url}`);
    }
    if (request.headers.authorization !== "Bearer fixture-token") {
      throw new Error(`connection credential was not spliced at host egress: ${JSON.stringify(request.headers)}`);
    }

    clearRequests(server.requests);
    console.log("phase: destructive allow");
    approvalMode = "allow";
    const allowed = await githubVm.exec(`tools call github.org.main.issues-create '${issueCreateArgs("allow")}'`);
    if (allowed.exitCode !== 0 || !allowed.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(`destructive approval allow did not proceed: exit=${allowed.exitCode} stdout=${allowed.stdout}`);
    }
    if (count(defaultPrompts) !== 1) throw new Error(`expected one tool approval prompt, saw ${count(defaultPrompts)}`);
    const approval = defaultPrompts[0]!;
    if (
      approval.connection !== "github.org.main" ||
      approval.method !== "POST" ||
      approval.url !== `${server.origin}/repos/octo/hello/issues` ||
      approval.origin !== server.origin ||
      !approval.argsDigest?.match(/^[0-9a-f]{64}$/)
    ) {
      throw new Error(`tool approval facts mismatch: ${JSON.stringify(approval)}`);
    }
    const allowedRequests = [...server.requests];
    if (allowedRequests.length !== 1 || allowedRequests[0]!.method !== "POST") {
      throw new Error(`destructive allow did not reach upstream exactly once: ${JSON.stringify(allowedRequests)}`);
    }
    if (allowedRequests[0]!.headers.authorization !== "Bearer fixture-token") {
      throw new Error("credential was not spliced after destructive approval");
    }

    clearRequests(server.requests);
    console.log("phase: destructive reject");
    approvalMode = "reject";
    const rejected = await githubVm.exec(`tools call github.org.main.issues-create '${issueCreateArgs("reject")}'`);
    if (count(defaultPrompts) !== 2) {
      throw new Error(`expected two total approval prompts after rejection, saw ${count(defaultPrompts)}`);
    }
    const rejectedRequests = [...server.requests];
    if (rejectedRequests.length !== 0 || rejected.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(`destructive rejection was not fail-closed: stdout=${rejected.stdout} requests=${rejectedRequests.length}`);
    }

    clearRequests(server.requests);
    console.log("phase: non-destructive GET");
    const promptsBeforeGet = count(defaultPrompts);
    const get = await githubVm.exec(
      "tools call github.org.main.issues-list '{\"path\":{\"owner\":\"octo\",\"repo\":\"hello\"},\"query\":{\"state\":\"open\"}}'",
    );
    if (get.exitCode !== 0 || !get.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(`non-destructive GET failed: exit=${get.exitCode} stdout=${get.stdout}`);
    }
    const getRequests = [...server.requests];
    if (getRequests.length !== 1 || getRequests[0]!.method !== "GET") {
      throw new Error(`non-destructive GET did not reach upstream once: ${JSON.stringify(getRequests)}`);
    }
    if (count(defaultPrompts) !== promptsBeforeGet) throw new Error("GET raised tool approval");

    clearRequests(server.requests);
    console.log("phase: block policy");
    const blockPrompts: ToolApprovalFact[] = [];
    const blockPolicy: ToolPolicyRule[] = [{ owner: "org", pattern: "github.org.main.*", action: "block" }];
    const blockVm = await mc.create(
      githubOptions({
        policies: blockPolicy,
        onPermission: (req) => {
          blockPrompts.push(toolApprovalFact(req));
          req.allow();
        },
      }),
    );
    created.push(blockVm);
    const blocked = await blockVm.exec(
      "tools call github.org.main.issues-list '{\"path\":{\"owner\":\"octo\",\"repo\":\"hello\"},\"query\":{\"state\":\"open\"}}'",
    );
    const blockRequests = [...server.requests];
    if (blockPrompts.length !== 0 || blockRequests.length !== 0 || blocked.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(`block policy did not fail closed without prompt: stdout=${blocked.stdout} prompts=${blockPrompts.length} requests=${blockRequests.length}`);
    }

    clearRequests(server.requests);
    console.log("phase: approve policy");
    const approveVm = await mc.create(
      githubOptions({
        policies: [{ owner: "org", pattern: "github.org.main.*", action: "approve" }],
        onPermission: (req) => {
          throw new Error(`approve policy should not prompt ${req.kind}`);
        },
      }),
    );
    created.push(approveVm);
    const approved = await approveVm.exec(`tools call github.org.main.issues-create '${issueCreateArgs("policy")}'`);
    if (approved.exitCode !== 0 || !approved.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(`approve policy did not send destructive request: exit=${approved.exitCode} stdout=${approved.stdout}`);
    }
    const approveRequests = [...server.requests];
    if (approveRequests.length !== 1 || approveRequests[0]!.method !== "POST") {
      throw new Error(`approve policy did not reach upstream once: ${JSON.stringify(approveRequests)}`);
    }

    clearRequests(server.requests);
    console.log("phase: direct and raw bypass");
    const bypassPrompts: ToolApprovalFact[] = [];
    const bypassVm = await mc.create({
      kernel,
      image: loomImage,
      deterministic: true,
      net: true,
      permissions: { network: "allow" },
      connections: [
        {
          ref: "github.org.main",
          auth: { kind: "bearer", token: "fixture-token" },
          origins: [server.origin],
        },
      ],
      onPermission: (req) => {
        const fact = toolApprovalFact(req);
        bypassPrompts.push(fact);
        req.allow();
      },
    });
    created.push(bypassVm);
    const bypass = await bypassVm.luau(`
local sys = require("sys")
local json = require("json")
local fd = assert(sys.svc.connect("adapters"))
local raw = assert(sys.svc.call(fd, json.encode({
  op = "invoke",
  adapter = "openapi",
  binding = { method = "DELETE", url_template = "${server.origin}/direct", parameters = {} },
  connection_ref = "github.org.main",
  args = {},
})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
assert(res.ok, raw)
local fetched = assert(sys.net.fetch("${server.origin}/raw", {
  method = "DELETE",
  headers = { ["X-MC-Connection"] = "github.org.main" },
}))
assert(fetched.status == 200, tostring(fetched.status))
print("bypass-ok")
`);
    if (bypass.exitCode !== 0 || !bypass.stdout.includes("bypass-ok")) {
      throw new Error(`direct/raw bypass proof failed: exit=${bypass.exitCode} stdout=${bypass.stdout} stderr=${bypass.stderr}`);
    }
    const bypassUrls = bypassPrompts.map((p) => `${p.method} ${p.url}`).sort();
    if (
      bypassPrompts.length !== 2 ||
      !bypassUrls.includes(`DELETE ${server.origin}/direct`) ||
      !bypassUrls.includes(`DELETE ${server.origin}/raw`)
    ) {
      throw new Error(`direct/raw requests were not gated at host egress: ${JSON.stringify(bypassPrompts)}`);
    }
    const bypassRequests = [...server.requests];
    const upstreamBypass = bypassRequests.map((r) => `${r.method} ${r.url}`).sort();
    if (
      bypassRequests.length !== 2 ||
      !upstreamBypass.includes("DELETE /direct") ||
      !upstreamBypass.includes("DELETE /raw") ||
      bypassRequests.some((r) => r.headers.authorization !== "Bearer fixture-token")
    ) {
      throw new Error(`direct/raw requests did not reach upstream with spliced credentials: ${JSON.stringify(bypassRequests)}`);
    }
  } finally {
    await closeAll(created);
    await server.close();
  }
  console.log("CORE OK — mc.create booted kernel.wasm via @mc/host; vm.exec + vm.fs verified.");
}

main().catch((e) => {
  console.error("CORE FAIL:", e instanceof Error ? e.message : e);
  process.exit(1);
});
