// @mc/core embedded backend over @mc/host: a real `mc.create()` boots the SAME kernel.wasm + base.tar
// the wasmtime e2e uses (passed as bytes, so no env/runfiles indirection through artifacts.ts), and the
// Vm API runs a real command + a real fs round-trip. This exercises the SDK library through the
// @mc/host → @mc/contracts package deps at RUNTIME — the layer the host-only parity test cannot reach.

import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { writeSnapshotHeader } from "@mc/contracts/snapshot";
import {
  capabilityConnection,
  FsContentStore,
  MemoryContentStore,
  llb,
  mc,
  remoteBuild,
} from "../src/index.js";
import type {
  BuildDefinition,
  ContentStore,
  CreateOptions,
  Driver,
  ImageManifest,
  PermissionRequest,
  Runtime,
  ConnectionPolicyRule,
  SolvePlatform,
  SolveProgressEvent,
  ToolDefinition,
  Vm,
} from "../src/index.js";

const LOCAL_RUNTIME: Runtime = "local";
// @ts-expect-error Alpha API: the old selector was removed rather than retained as an alias.
const REMOVED_BUN_RUNTIME: Runtime = "bun";
void REMOVED_BUN_RUNTIME;

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
  bodyBytes: number[];
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
        bodyBytes: [...Buffer.concat(chunks)],
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
  if (!address || typeof address === "string")
    throw new Error("recording server did not bind a TCP port");
  return {
    origin: `http://127.0.0.1:${address.port}`,
    requests,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

async function bytesServer(routeBytes: Map<string, Uint8Array>): Promise<{
  origin: string;
  requests: string[];
  close(): Promise<void>;
}> {
  const requests: string[] = [];
  const server = createServer((req, res) => {
    requests.push(req.url ?? "");
    const bytes = routeBytes.get(req.url ?? "");
    if (!bytes) {
      res.writeHead(404, { "content-type": "text/plain" });
      res.end("not found");
      return;
    }
    res.writeHead(200, { "content-type": "application/octet-stream" });
    res.end(bytes);
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string")
    throw new Error("bytes server did not bind a TCP port");
  return {
    origin: `http://127.0.0.1:${address.port}`,
    requests,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

async function remoteVmServer(): Promise<{
  origin: string;
  requests: RecordedRequest[];
  close(): Promise<void>;
}> {
  const snapshot = await fullSnapshotFixture("remote-fixture-kernel");
  const requests: RecordedRequest[] = [];
  const server = createServer((req, res) => {
    const chunks: Uint8Array[] = [];
    req.on("data", (chunk: Uint8Array) => chunks.push(chunk));
    req.on("end", () => {
      const body = new TextDecoder().decode(Buffer.concat(chunks));
      requests.push({
        method: req.method ?? "",
        url: req.url ?? "",
        headers: req.headers,
        body,
        bodyBytes: [...Buffer.concat(chunks)],
      });

      if (req.method === "POST" && req.url === "/v1/snapshots") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            ref: `sha256:${"a".repeat(64)}`,
            size: chunks.reduce((n, chunk) => n + chunk.length, 0),
          }),
        );
        return;
      }
      if (
        req.method === "POST" &&
        req.url?.startsWith("/v1/vms/") &&
        req.url.endsWith("/snapshots?mode=full")
      ) {
        res.writeHead(200, { "content-type": "application/octet-stream" });
        res.end(snapshot);
        return;
      }
      if (req.method === "POST" && req.url === "/v1/vms") {
        const parsed = JSON.parse(body || "{}") as { id?: string };
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ id: parsed.id ?? "remote-test" }));
        return;
      }
      if (
        req.method === "POST" &&
        req.url?.startsWith("/v1/vms/") &&
        req.url.endsWith("/restore")
      ) {
        const parts = req.url.split("/");
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ id: decodeURIComponent(parts[3] ?? "restored") }));
        return;
      }
      if (req.method === "POST" && req.url?.startsWith("/v1/vms/") && req.url.endsWith("/forks")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ vm: { id: "remote-fork" }, warnings: [] }));
        return;
      }
      if (
        req.method === "POST" &&
        req.url?.startsWith("/v1/vms/") &&
        req.url.endsWith("/autocomplete")
      ) {
        const parsed = JSON.parse(body || "{}") as { source?: string; cursor?: number };
        res.writeHead(200, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            replaceStart: 0,
            replaceEnd: parsed.cursor ?? 0,
            commonPrefix: "echo",
            items: [{ label: "echo", value: "echo", kind: "builtin" }],
            truncated: false,
          }),
        );
        return;
      }
      if (req.method === "DELETE" && req.url?.startsWith("/v1/vms/")) {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true }));
        return;
      }

      res.writeHead(404, { "content-type": "text/plain" });
      res.end("not found");
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string")
    throw new Error("remote VM test server did not bind a TCP port");
  return {
    origin: `http://127.0.0.1:${address.port}`,
    requests,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

async function remoteBuildServer(
  opts: {
    corruptDefinitionDigest?: boolean;
    corruptDefinitionBytes?: boolean;
    corruptBlobRefs?: boolean;
  } = {},
): Promise<{
  origin: string;
  requests: RecordedRequest[];
  blobs: Map<string, Uint8Array>;
  close(): Promise<void>;
}> {
  const requests: RecordedRequest[] = [];
  const blobs = new Map<string, Uint8Array>();
  const server = createServer((req, res) => {
    const chunks: Uint8Array[] = [];
    req.on("data", (chunk: Uint8Array) => chunks.push(chunk));
    req.on("end", () => {
      void (async () => {
        const bytes = new Uint8Array(Buffer.concat(chunks));
        requests.push({
          method: req.method ?? "",
          url: req.url ?? "",
          headers: req.headers,
          body: new TextDecoder().decode(bytes),
          bodyBytes: [...bytes],
        });

        if (req.method === "POST" && req.url === "/v1/blobs") {
          const digest = await sha256Digest(bytes);
          blobs.set(digest, bytes);
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify({ digest, size: bytes.length }));
          return;
        }

        if (req.method === "GET" && req.url?.startsWith("/v1/blobs/")) {
          const digest = decodeURIComponent(req.url.slice("/v1/blobs/".length));
          const blob = blobs.get(digest);
          if (!blob) {
            res.writeHead(404, { "content-type": "text/plain" });
            res.end("not found");
            return;
          }
          res.writeHead(200, { "content-type": "application/octet-stream" });
          res.end(blob);
          return;
        }

        if (req.method === "POST" && req.url === "/v1/build") {
          const definition = llb.decodeDefinition(bytes);
          const missingBlob = definition.ops
            .map((op) => op.data_digest)
            .find((digest): digest is string => typeof digest === "string" && !blobs.has(digest));
          if (missingBlob) {
            res.writeHead(422, { "content-type": "text/plain" });
            res.end(`missing blob ${missingBlob}`);
            return;
          }

          const definitionDigest = opts.corruptDefinitionDigest
            ? `sha256:${"e".repeat(64)}`
            : await sha256Digest(bytes);
          const provenanceBytes = opts.corruptDefinitionBytes
            ? new Uint8Array([0xde, 0xad])
            : bytes;
          const rootDigest = `sha256:${"b".repeat(64)}`;
          const kernelDigest = `sha256:${"c".repeat(64)}`;
          const layer = { digest: `sha256:${"d".repeat(64)}`, size: 123 };
          const blobRefs = definition.ops
            .map((op) => op.data_digest)
            .filter((digest): digest is string => typeof digest === "string")
            .sort();
          res.writeHead(200, { "content-type": "application/json" });
          res.end(
            JSON.stringify({
              definitionDigest,
              rootDigest,
              kernelDigest,
              manifestRef: "node-" + rootDigest.slice("sha256:".length),
              image: {
                schema: 1,
                layers: [layer],
                config: { tier: "read-write" },
                build: {
                  schema: 1,
                  definition: {
                    encoding: "mc.llb.definition.v1",
                    digest: definitionDigest,
                    bytes: [...provenanceBytes],
                  },
                  rootDigest,
                  kernelDigest,
                  storeRefs: {
                    layers: [layer],
                    blobs: opts.corruptBlobRefs ? [`sha256:${"f".repeat(64)}`] : blobRefs,
                  },
                },
              },
              layers: [layer],
            }),
          );
          return;
        }

        res.writeHead(404, { "content-type": "text/plain" });
        res.end("not found");
      })().catch((err) => {
        res.writeHead(500, { "content-type": "text/plain" });
        res.end(err instanceof Error ? err.message : String(err));
      });
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string")
    throw new Error("remote build test server did not bind a TCP port");
  return {
    origin: `http://127.0.0.1:${address.port}`,
    requests,
    blobs,
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

function runGit(cwd: string, args: string[]): string {
  const result = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "AgentOS Test",
      GIT_AUTHOR_EMAIL: "agent-os@example.test",
      GIT_COMMITTER_NAME: "AgentOS Test",
      GIT_COMMITTER_EMAIL: "agent-os@example.test",
    },
  });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(" ")} failed: ${result.stderr}`);
  }
  return result.stdout;
}

async function sha256Digest(bytes: Uint8Array): Promise<string> {
  const digest = await sha256Bytes(bytes);
  let hex = "";
  for (const byte of digest) hex += byte.toString(16).padStart(2, "0");
  return `sha256:${hex}`;
}

async function sha256Bytes(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>));
}

async function fullSnapshotFixture(kernelLabel: string): Promise<Uint8Array> {
  const memory = new Uint8Array(65_536);
  const header = writeSnapshotHeader(
    "full",
    memory.length,
    0,
    await sha256Bytes(new TextEncoder().encode(kernelLabel)),
    await sha256Bytes(memory),
    new Uint8Array(32),
  );
  const snapshot = new Uint8Array(header.length + memory.length);
  snapshot.set(header);
  snapshot.set(memory, header.length);
  return snapshot;
}

class CountingStore implements ContentStore {
  putDigests: string[] = [];
  putBlobDigests: string[] = [];
  manifestNames: string[] = [];
  putManifestNames: string[] = [];
  snapshotKeys: string[] = [];
  putSnapshotKeys: string[] = [];

  constructor(private readonly inner: ContentStore) {}

  reset(): void {
    this.putDigests = [];
    this.putBlobDigests = [];
    this.manifestNames = [];
    this.putManifestNames = [];
    this.snapshotKeys = [];
    this.putSnapshotKeys = [];
  }

  putCount(): number {
    return this.putDigests.length;
  }

  layer(digest: string): Promise<Uint8Array> {
    return this.inner.layer(digest);
  }

  async put(tar: Uint8Array): Promise<string> {
    const digest = await this.inner.put(tar);
    this.putDigests.push(digest);
    return digest;
  }

  blob(digest: string): Promise<Uint8Array> {
    return this.inner.blob(digest);
  }

  async putBlob(bytes: Uint8Array): Promise<string> {
    const digest = await this.inner.putBlob(bytes);
    this.putBlobDigests.push(digest);
    return digest;
  }

  manifest(name: string): Promise<ImageManifest> {
    this.manifestNames.push(name);
    return this.inner.manifest(name);
  }

  async putManifest(name: string, m: ImageManifest): Promise<void> {
    this.putManifestNames.push(name);
    await this.inner.putManifest(name, m);
  }

  snapshot(key: string): Promise<Uint8Array | null> {
    this.snapshotKeys.push(key);
    return this.inner.snapshot ? this.inner.snapshot(key) : Promise.resolve(null);
  }

  putSnapshot(key: string, snap: Uint8Array): Promise<void> {
    if (!this.inner.putSnapshot) throw new Error("inner content store does not support snapshots");
    this.putSnapshotKeys.push(key);
    return this.inner.putSnapshot(key, snap);
  }

  snapshotObject(digest: string): Promise<Uint8Array> {
    if (!this.inner.snapshotObject)
      throw new Error("inner content store does not support snapshot objects");
    return this.inner.snapshotObject(digest);
  }

  async putSnapshotObject(snapshot: Uint8Array): Promise<string> {
    if (!this.inner.putSnapshotObject)
      throw new Error("inner content store does not support snapshot objects");
    return this.inner.putSnapshotObject(snapshot);
  }
}

async function closeAll(vms: Vm[]): Promise<void> {
  for (const vm of vms.reverse()) await vm.close();
}

async function main(): Promise<void> {
  const kernelPath = runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM");
  const imagePath = runfile(process.env.MC_BASE_IMAGE, "MC_BASE_IMAGE");
  process.env.MC_KERNEL_WASM = kernelPath;
  process.env.MC_BASE_IMAGE = imagePath;
  const kernel = new Uint8Array(readFileSync(kernelPath));
  const image = new Uint8Array(readFileSync(imagePath));
  const atlasImage = new Uint8Array(
    readFileSync(runfile(process.env.MC_ATLAS_IMAGE, "MC_ATLAS_IMAGE")),
  );
  const loomImage = new Uint8Array(
    readFileSync(runfile(process.env.MC_LOOM_IMAGE, "MC_LOOM_IMAGE")),
  );
  const githubFixture = readFileSync(
    runfile(process.env.MC_GITHUB_FIXTURE, "MC_GITHUB_FIXTURE"),
    "utf8",
  );

  let rejectedRemovedRuntime = false;
  try {
    await mc.create({ runtime: "bun", kernel, image } as unknown as CreateOptions);
  } catch (error) {
    rejectedRemovedRuntime = /unsupported runtime.*bun.*local.*browser.*remote/i.test(
      String(error),
    );
  }
  if (!rejectedRemovedRuntime) {
    throw new Error('removed runtime "bun" must fail with the supported runtime list');
  }

  // mc.use capability sugar derives {ref, auth} + the tool selector (pure; no network).
  {
    const single = capabilityConnection("github.issues", "tok-123");
    if (
      single.connections.length !== 1 ||
      single.connections[0]!.ref !== "github.org.main" ||
      single.connections[0]!.auth.kind !== "bearer" ||
      JSON.stringify(single.tools) !== JSON.stringify(["github/issues"])
    ) {
      throw new Error(`capabilityConnection single wrong: ${JSON.stringify(single)}`);
    }
    const multi = capabilityConnection(["github.issues", "github.pulls"], {
      kind: "header",
      name: "X-Key",
      value: "v",
    });
    if (
      multi.connections.length !== 1 ||
      multi.connections[0]!.auth.kind !== "header" ||
      JSON.stringify(multi.tools) !== JSON.stringify(["github/issues", "github/pulls"])
    ) {
      throw new Error(`capabilityConnection multi wrong: ${JSON.stringify(multi)}`);
    }
    let threwBad = false;
    try {
      capabilityConnection("github", "tok");
    } catch {
      threwBad = true;
    }
    if (!threwBad)
      throw new Error("capabilityConnection should reject a capability without a group");
    let threwMixed = false;
    try {
      capabilityConnection(["github.issues", "slack.messages"], "tok");
    } catch {
      threwMixed = true;
    }
    if (!threwMixed) throw new Error("capabilityConnection should reject mixed integrations");
    console.log("phase: mc.use capability derivation OK");
  }

  // A declared host mount is machine boot state, so the long-lived login shell
  // and subsequently spawned vm.exec tasks must observe the same namespace.
  {
    const mountedBytes = new TextEncoder().encode("mounted fixture\n");
    const driver: Driver = {
      readOnly: true,
      async open(path) {
        if (path === "/fixture.txt") return mountedBytes;
        throw Object.assign(new Error(`missing ${path}`), { code: "ENOENT" });
      },
      async stat(path) {
        return path === "/" || path === "." || path === ""
          ? { kind: "dir", size: 0 }
          : { kind: "file", size: mountedBytes.length };
      },
      async readdir() {
        return [{ name: "fixture.txt", kind: "file" }];
      },
    };
    const mountedVm = await mc.create({
      kernel,
      image,
      mounts: [{ path: "/repo", driver, readOnly: true }],
    });
    try {
      const scripted = await mountedVm.exec('read line < /repo/fixture.txt; echo "$line"');
      if (scripted.exitCode !== 0 || scripted.stdout.trim() !== "mounted fixture") {
        throw new Error(`declared mount missing from vm.exec: ${JSON.stringify(scripted)}`);
      }

      const shell = mountedVm.shell();
      let transcript = "";
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          off();
          reject(
            new Error(`declared mount missing from login shell: ${JSON.stringify(transcript)}`),
          );
        }, 2_000);
        const off = shell.on((bytes) => {
          transcript += new TextDecoder().decode(bytes);
          if (transcript.includes("mounted fixture") && transcript.endsWith("$ ")) {
            clearTimeout(timer);
            off();
            resolve();
          }
        });
        shell.write('read line < /repo/fixture.txt; echo "$line"\n');
      });
      console.log("phase: declared mount is shared by vm.exec and login shell OK");
    } finally {
      await mountedVm.close();
    }
  }

  // Remote create must preserve the same declarative tool-plane intent as embedded create. The client does
  // not compile catalogs; it sends refs/specs/selectors/policies for the remote host to inject and enforce.
  {
    const remote = await remoteVmServer();
    try {
      const policy: ConnectionPolicyRule = {
        owner: "org",
        pattern: "github.org.main.*",
        action: "approve",
      };
      const specBytes = new TextEncoder().encode(githubFixture);
      const remoteVm = await mc.create({
        runtime: "remote",
        endpoint: remote.origin,
        token: "server-token",
        id: "remote-catalog",
        image: null,
        connections: [
          {
            ref: "github.org.main",
            auth: { kind: "bearer", token: "github-token" },
            spec: {
              bytes: specBytes,
              format: "openapi",
              sourceFormat: "json",
              baseUrl: "https://api.github.com",
            },
          },
        ],
        tools: ["github/issues"],
        policies: [policy],
      });
      const remoteCompletion = await remoteVm.autocomplete("ec");
      if (
        remoteCompletion.replaceStart !== 0 ||
        remoteCompletion.replaceEnd !== 2 ||
        remoteCompletion.items[0]?.label !== "echo"
      ) {
        throw new Error(`remote autocomplete mapping wrong: ${JSON.stringify(remoteCompletion)}`);
      }
      await remoteVm.close();

      const create = remote.requests.find((req) => req.method === "POST" && req.url === "/v1/vms");
      if (!create)
        throw new Error(`remote create did not POST /v1/vms: ${JSON.stringify(remote.requests)}`);
      if (create.headers.authorization !== "Bearer server-token") {
        throw new Error(`remote create omitted bearer token: ${JSON.stringify(create.headers)}`);
      }
      const body = JSON.parse(create.body) as {
        id?: string;
        net?: string;
        connections?: Array<{
          ref?: string;
          auth?: { kind?: string; token?: string };
          spec?: Record<string, unknown>;
        }>;
        catalogTools?: string[];
        connectionPolicies?: ConnectionPolicyRule[];
      };
      if (body.id !== "remote-catalog" || body.net !== "real") {
        throw new Error(`remote create body did not preserve id/net: ${create.body}`);
      }
      const connection = body.connections?.[0];
      if (
        connection?.ref !== "github.org.main" ||
        connection.auth?.kind !== "bearer" ||
        connection.auth.token !== "github-token" ||
        typeof connection.spec?.bytesBase64 !== "string" ||
        connection.spec.sourceFormat !== "json" ||
        connection.spec.baseUrl !== "https://api.github.com"
      ) {
        throw new Error(`remote create did not serialize connection/spec: ${create.body}`);
      }
      if (JSON.stringify(body.catalogTools) !== JSON.stringify(["github/issues"])) {
        throw new Error(`remote create did not forward catalog selectors: ${create.body}`);
      }
      if (JSON.stringify(body.connectionPolicies) !== JSON.stringify([policy])) {
        throw new Error(`remote create did not forward connection policies: ${create.body}`);
      }
      console.log("phase: remote create forwards catalog intent OK");
    } finally {
      await remote.close();
    }
  }

  // Recording is a VM proxy that emits a portable LLB DAG; it is not tied to the embedded runtime.
  {
    const remote = await remoteVmServer();
    try {
      const recorder = await mc.record({
        runtime: "remote",
        endpoint: remote.origin,
        token: "server-token",
        id: "remote-record",
        image: "remote-base",
      });
      await recorder.vm.close();
      const create = remote.requests.find((req) => req.method === "POST" && req.url === "/v1/vms");
      if (!create)
        throw new Error(`remote record did not create a VM: ${JSON.stringify(remote.requests)}`);
      const body = JSON.parse(create.body) as { id?: string; image?: string };
      if (body.id !== "remote-record" || body.image !== "remote-base") {
        throw new Error(`remote record did not forward VM create intent: ${create.body}`);
      }
      const definition = await recorder.build();
      if (definition.ops.length !== 1 || definition.ops[0]?.source_ref !== "remote-base") {
        throw new Error(
          `remote record did not produce a replayable source DAG: ${JSON.stringify(definition)}`,
        );
      }
      console.log("phase: remote record creates live VM and emits portable source DAG OK");
    } finally {
      await remote.close();
    }
  }

  // Remote build is the build-plane server protocol: upload out-of-line blobs, then send canonical
  // Definition bytes to the server solver.
  {
    const remote = await remoteBuildServer();
    try {
      const state = llb.write(llb.source("remote-base"), "/data/remote.txt", "remote-build");
      const result = await remoteBuild(state, { endpoint: remote.origin, token: "server-token" });
      const blob = remote.requests.find((req) => req.method === "POST" && req.url === "/v1/blobs");
      const build = remote.requests.find((req) => req.method === "POST" && req.url === "/v1/build");
      if (!blob || !build)
        throw new Error(
          `remote build did not use blob/build routes: ${JSON.stringify(remote.requests)}`,
        );
      if (
        blob.headers.authorization !== "Bearer server-token" ||
        build.headers.authorization !== "Bearer server-token"
      ) {
        throw new Error(`remote build omitted bearer token: ${JSON.stringify(remote.requests)}`);
      }

      const payload = new TextEncoder().encode("remote-build");
      const payloadDigest = await sha256Digest(payload);
      if (Buffer.compare(Buffer.from(blob.bodyBytes), Buffer.from(payload)) !== 0) {
        throw new Error(
          `remote build uploaded wrong blob bytes: ${JSON.stringify(blob.bodyBytes)}`,
        );
      }
      if (!remote.blobs.has(payloadDigest)) {
        throw new Error(`remote build did not upload write payload by digest: ${payloadDigest}`);
      }

      const definitionBytes = Uint8Array.from(build.bodyBytes);
      const definition = llb.decodeDefinition(definitionBytes);
      if (
        definition.ops.length !== 2 ||
        definition.root !== 1 ||
        definition.ops[0]?.source_ref !== "remote-base" ||
        definition.ops[1]?.data_digest !== payloadDigest ||
        definition.ops[1]?.path !== "/data/remote.txt"
      ) {
        throw new Error(`remote build posted wrong Definition: ${JSON.stringify(definition)}`);
      }
      const expectedDefinitionDigest = await sha256Digest(definitionBytes);
      if (
        result.definitionDigest !== expectedDefinitionDigest ||
        result.image.build?.definition.digest !== expectedDefinitionDigest ||
        result.image.build?.storeRefs.blobs[0] !== payloadDigest ||
        result.manifestRef !== "node-" + result.rootDigest.slice("sha256:".length)
      ) {
        throw new Error(
          `remote build result did not preserve server provenance: ${JSON.stringify(result)}`,
        );
      }

      const prebuiltStore = new MemoryContentStore();
      const prebuiltState = llb.write(
        llb.source("remote-base"),
        "/data/prebuilt.txt",
        "prebuilt-definition",
      );
      const prebuiltDefinition = await llb.toDefinition(prebuiltState, { store: prebuiltStore });
      const prebuiltDigest = prebuiltDefinition.ops[1]?.data_digest;
      if (!prebuiltDigest)
        throw new Error(
          `prebuilt Definition did not externalize write bytes: ${JSON.stringify(prebuiltDefinition)}`,
        );
      let missingStoreRejected = false;
      try {
        await remoteBuild(prebuiltDefinition, { endpoint: remote.origin, token: "server-token" });
      } catch (error) {
        missingStoreRejected = /pass opts\.store/.test(
          error instanceof Error ? error.message : String(error),
        );
      }
      if (!missingStoreRejected) {
        throw new Error(
          "remote build accepted a prebuilt Definition with missing server blobs and no local store",
        );
      }
      const prebuiltResult = await remoteBuild(prebuiltDefinition, {
        endpoint: remote.origin,
        token: "server-token",
        store: prebuiltStore,
      });
      if (
        !remote.blobs.has(prebuiltDigest) ||
        !prebuiltResult.image.build?.storeRefs.blobs.includes(prebuiltDigest)
      ) {
        throw new Error(
          `remote build did not upload prebuilt Definition blob refs: ${JSON.stringify(prebuiltResult)}`,
        );
      }
      console.log("phase: remote build uploads blobs and posts canonical LLB Definition OK");
    } finally {
      await remote.close();
    }

    const corrupt = await remoteBuildServer({ corruptDefinitionDigest: true });
    try {
      let rejected = false;
      try {
        await remoteBuild(llb.source("remote-base"), { endpoint: corrupt.origin });
      } catch (error) {
        rejected = /definition digest mismatch/.test(
          error instanceof Error ? error.message : String(error),
        );
      }
      if (!rejected) {
        throw new Error(
          "remote build accepted a server result whose provenance did not match the posted Definition",
        );
      }
      console.log("phase: remote build rejects mismatched server provenance OK");
    } finally {
      await corrupt.close();
    }

    const corruptBytes = await remoteBuildServer({ corruptDefinitionBytes: true });
    try {
      let rejected = false;
      try {
        await remoteBuild(llb.source("remote-base"), { endpoint: corruptBytes.origin });
      } catch (error) {
        rejected = /definition bytes mismatch/.test(
          error instanceof Error ? error.message : String(error),
        );
      }
      if (!rejected) {
        throw new Error(
          "remote build accepted server provenance whose embedded Definition bytes did not match the digest",
        );
      }
      console.log("phase: remote build rejects mismatched embedded Definition bytes OK");
    } finally {
      await corruptBytes.close();
    }

    const corruptBlobRefs = await remoteBuildServer({ corruptBlobRefs: true });
    try {
      let rejected = false;
      try {
        await remoteBuild(llb.source("remote-base"), { endpoint: corruptBlobRefs.origin });
      } catch (error) {
        rejected = /blob refs mismatch/.test(
          error instanceof Error ? error.message : String(error),
        );
      }
      if (!rejected) {
        throw new Error(
          "remote build accepted server provenance whose blob refs did not match the posted Definition",
        );
      }
      console.log("phase: remote build rejects mismatched blob refs OK");
    } finally {
      await corruptBlobRefs.close();
    }
  }

  // Remote restore is a two-plane protocol: raw snapshot bytes are uploaded to the data plane, while the
  // restore call carries only a snapshot ref plus runtime authority/callback attachments.
  {
    const remote = await remoteVmServer();
    try {
      // Remote restore validates the MCSN envelope before touching the network. Use a minimal,
      // structurally valid full snapshot here; the remote fixture is responsible only for proving
      // that those exact opaque bytes cross the data plane.
      const memory = new Uint8Array(65_536);
      const kernelDigest = await sha256Bytes(new TextEncoder().encode("remote-fixture-kernel"));
      const memoryDigest = await sha256Bytes(memory);
      const header = writeSnapshotHeader(
        "full",
        memory.length,
        0,
        kernelDigest,
        memoryDigest,
        new Uint8Array(32),
      );
      const remoteSnapshot = new Uint8Array(header.length + memory.length);
      remoteSnapshot.set(header);
      remoteSnapshot.set(memory, header.length);
      const restored = await mc.restore(remoteSnapshot, {
        runtime: "remote",
        endpoint: remote.origin,
        token: "server-token",
        id: "restore-catalog",
        connections: [{ ref: "github.org.main", auth: { kind: "bearer", token: "github-token" } }],
        policies: [{ owner: "org", pattern: "github.org.main.*", action: "approve" }],
      });
      await restored.close();
      const upload = remote.requests.find(
        (req) => req.method === "POST" && req.url === "/v1/snapshots",
      );
      if (!upload)
        throw new Error(
          `remote restore did not upload snapshot bytes: ${JSON.stringify(remote.requests)}`,
        );
      if (
        upload.headers["content-type"] !== "application/octet-stream" ||
        upload.bodyBytes.length !== remoteSnapshot.length ||
        upload.bodyBytes.some((byte, index) => byte !== remoteSnapshot[index])
      ) {
        throw new Error(
          `remote restore snapshot upload was not raw bytes: ${JSON.stringify(upload)}`,
        );
      }
      const restore = remote.requests.find(
        (req) => req.method === "POST" && req.url === "/v1/vms/restore-catalog/restore",
      );
      if (!restore)
        throw new Error(
          `remote restore did not POST restore endpoint: ${JSON.stringify(remote.requests)}`,
        );
      const body = JSON.parse(restore.body) as {
        snapshot?: { ref?: string };
        attachments?: {
          net?: string;
          connections?: Array<{ spec?: unknown; tools?: unknown }>;
          connectionPolicies?: unknown[];
          catalogTools?: unknown;
        };
        snapshotBase64?: string;
      };
      const attachments = body.attachments;
      const restoreConnection = attachments?.connections?.[0];
      if (
        body.snapshot?.ref !== `sha256:${"a".repeat(64)}` ||
        body.snapshotBase64 !== undefined ||
        !attachments ||
        attachments.net !== "real" ||
        attachments.connections?.length !== 1 ||
        restoreConnection?.spec !== undefined ||
        restoreConnection?.tools !== undefined ||
        attachments.connectionPolicies?.length !== 1 ||
        attachments.catalogTools !== undefined
      ) {
        throw new Error(`remote restore did not preserve snapshot attachments: ${restore.body}`);
      }
      console.log("phase: remote restore uploads snapshot refs and forwards attachment intent OK");
    } finally {
      await remote.close();
    }
  }

  // A served host owns the remote fork transaction and attachment state. The client asks the source
  // VM to fork atomically, receives a fresh identity, and never reconstructs a restore request from
  // caller-owned options.
  {
    const remote = await remoteVmServer();
    const sourceOptions: CreateOptions = {
      runtime: "remote",
      endpoint: remote.origin,
      id: "named-source",
      connections: [{ ref: "github.org.main", auth: { kind: "bearer", token: "owned-token" } }],
      policies: [{ owner: "org", pattern: "github.org.main.*", action: "approve" }],
      tools: [],
      mounts: [],
    };
    let source: Vm | undefined;
    let forked: Vm | undefined;
    try {
      source = await mc.create(sourceOptions);
      sourceOptions.id = "caller-mutated-id";
      const auth = sourceOptions.connections![0]!.auth;
      if (auth.kind !== "bearer") throw new Error("remote fork fixture auth changed kind");
      auth.token = "caller-mutated-token";
      sourceOptions.policies!.splice(0, 1);

      forked = await source.fork();
      const fork = remote.requests.find(
        (req) => req.method === "POST" && req.url === "/v1/vms/named-source/forks",
      );
      if (!fork)
        throw new Error(
          `remote fork did not use the server transaction: ${JSON.stringify(remote.requests)}`,
        );
      if (remote.requests.some((req) => req.method === "POST" && req.url.endsWith("/restore"))) {
        throw new Error(
          "remote fork reconstructed a client-side restore instead of delegating to the server",
        );
      }
      if (sourceOptions.tools?.length !== 0 || sourceOptions.mounts?.length !== 0) {
        throw new Error("remote VM construction mutated caller-owned attachment arrays");
      }
      console.log(
        "phase: remote fork delegates one atomic independent-identity transaction to the server OK",
      );
    } finally {
      await forked?.close().catch(() => {});
      await source?.close().catch(() => {});
      await remote.close();
    }
  }

  // A solver-provided store does not need to be filesystem-backed: the in-memory
  // implementation carries layers/manifests/snapshots through the same public ContentStore API.
  {
    const store = new MemoryContentStore();
    const baseDigest = await store.put(image);
    await store.putManifest("memory-base", {
      schema: 1,
      layers: [{ digest: baseDigest, size: image.length }],
      config: {},
    });
    const manifest = await llb
      .commit(llb.write(llb.source("memory-base"), "/home/user/memory-store.txt", "memory-store"))
      .asImage({ store, kernel });
    const vm = await mc.create({ kernel, image: manifest, store, deterministic: true });
    try {
      const out = await vm.fs.readText("/home/user/memory-store.txt");
      if (out !== "memory-store") {
        throw new Error(`memory ContentStore image bytes mismatch: ${JSON.stringify(out)}`);
      }
    } finally {
      await vm.close();
    }
    const snapshot = await llb
      .commit(
        llb.write(llb.source("memory-base"), "/home/user/memory-snapshot.txt", "memory-snapshot"),
      )
      .asSnapshot({ store, kernel });
    const restored = await mc.restore(snapshot, {
      kernel,
      image: "memory-base",
      store,
      deterministic: true,
    });
    try {
      const out = await restored.fs.readText("/home/user/memory-snapshot.txt");
      if (out !== "memory-snapshot") {
        throw new Error(`memory ContentStore snapshot bytes mismatch: ${JSON.stringify(out)}`);
      }
    } finally {
      await restored.close();
    }
    console.log("phase: memory ContentStore solves images and snapshots with real VM bytes OK");
  }

  // LLB image algebra: the README-shaped `image([base, write(base, ...)])` must not duplicate the base
  // stack, and image assembly must preserve child runtime config while allowing explicit overrides.
  {
    const store = new CountingStore(new FsContentStore(mkdtempSync(join(tmpdir(), "mc-llb-"))));
    const baseDigest = await store.put(image);
    await store.putManifest("llb-base", {
      schema: 1,
      layers: [{ digest: baseDigest, size: image.length }],
      config: { budgetMib: 512 },
    });
    const atlasDigest = await store.put(atlasImage);
    await store.putManifest("llb-atlas", {
      schema: 1,
      layers: [{ digest: atlasDigest, size: atlasImage.length }],
      config: {},
    });

    const base = llb.source("llb-base");
    const atlas = llb.source("llb-atlas");
    const written = llb.write(base, "/etc/llb-flavor", "acme\n");
    const recorder = await mc.record({ image: "llb-base", store, deterministic: true });
    try {
      await recorder.vm.fs.mkdir("/home/user/recorded-dir");
      await recorder.vm.fs.write("/home/user/recorded-dir/keep", "recorded\n");
      await recorder.vm.fs.write("/home/user/recorded-dir/remove", "remove\n");
      await recorder.vm.fs.chmod("/home/user/recorded-dir/keep", 0o600);
      await recorder.vm.fs.symlink("/home/user/recorded-dir/keep", "/home/user/recorded-link");
      await recorder.vm.fs.rm("/home/user/recorded-dir/remove");
      const liveExec = await recorder.vm.exec(
        'pwd > exec-cwd; printf "$REC_ENV" > exec-env; read line; printf "$line" > exec-stdin',
        {
          cwd: "/home/user/recorded-dir",
          env: { REC_ENV: "record-env" },
          stdin: "record-stdin\n",
        },
      );
      if (liveExec.exitCode !== 0) {
        throw new Error(`recorded live exec failed: ${liveExec.stderr}`);
      }
      const recordedManifest = await llb.commit(await recorder.build()).asImage({ store, kernel });
      const replay = await mc.create({
        kernel,
        image: recordedManifest,
        store,
        deterministic: true,
      });
      try {
        const wrote = await replay.fs.readText("/home/user/recorded-dir/keep");
        const link = await replay.fs.readText("/home/user/recorded-link");
        const cwd = await replay.fs.readText("/home/user/recorded-dir/exec-cwd");
        const env = await replay.fs.readText("/home/user/recorded-dir/exec-env");
        const stdin = await replay.fs.readText("/home/user/recorded-dir/exec-stdin");
        const mode = (await replay.fs.stat("/home/user/recorded-dir/keep")).mode;
        let removedMissing = false;
        try {
          await replay.fs.readText("/home/user/recorded-dir/remove");
        } catch {
          removedMissing = true;
        }
        if (
          wrote !== "recorded\n" ||
          link !== "recorded\n" ||
          cwd !== "/home/user/recorded-dir\n" ||
          env !== "record-env" ||
          stdin !== "record-stdin" ||
          mode !== 0o600 ||
          !removedMissing
        ) {
          throw new Error(
            `record replay bytes mismatch: write=${JSON.stringify(wrote)} link=${JSON.stringify(link)} cwd=${JSON.stringify(cwd)} env=${JSON.stringify(env)} stdin=${JSON.stringify(stdin)} mode=${mode.toString(8)} removedMissing=${removedMissing}`,
          );
        }
      } finally {
        await replay.close();
      }
    } finally {
      await recorder.vm.close();
    }
    console.log("phase: llb record round-trip replays fs mutations and exec options OK");

    const manifest = await llb
      .commit(llb.image([base, written], { tier: "full" }))
      .asImage({ store, kernel });
    if (
      manifest.layers.length !== 2 ||
      manifest.layers[0]?.digest !== baseDigest ||
      manifest.layers[1]?.digest === baseDigest
    ) {
      throw new Error(
        `llb image duplicated or misordered layers: ${JSON.stringify(manifest.layers)}`,
      );
    }
    if (manifest.config.budgetMib !== 512 || manifest.config.tier !== "full") {
      throw new Error(`llb image did not compose config: ${JSON.stringify(manifest.config)}`);
    }

    const built = await mc.create({ kernel, image: manifest, store, deterministic: true });
    try {
      const out = await built.fs.readText("/etc/llb-flavor");
      if (out !== "acme\n") {
        throw new Error(`llb image did not boot with written file: ${JSON.stringify(out)}`);
      }
    } finally {
      await built.close();
    }
    console.log("phase: llb image algebra uses provenance and boots real bytes OK");

    const execState = llb.exec(
      base,
      'pwd > llb-cwd; printf "$LLB_FLAG" > llb-env; read line; printf "$line" > llb-stdin',
      {
        cwd: "/home/user",
        env: { LLB_FLAG: "present" },
        stdin: "payload\n",
      },
    );
    const execManifest = await llb.commit(execState).asImage({ store, kernel });
    const execVm = await mc.create({ kernel, image: execManifest, store, deterministic: true });
    try {
      const cwd = await execVm.fs.readText("/home/user/llb-cwd");
      const env = await execVm.fs.readText("/home/user/llb-env");
      const stdin = await execVm.fs.readText("/home/user/llb-stdin");
      if (cwd !== "/home/user\n" || env !== "present" || stdin !== "payload") {
        throw new Error(
          `llb exec options mismatch: cwd=${JSON.stringify(cwd)} env=${JSON.stringify(env)} stdin=${JSON.stringify(stdin)}`,
        );
      }
    } finally {
      await execVm.close();
    }
    console.log("phase: llb exec forwards cwd/env/stdin through typed ExecRequest");

    const execEnvChanged = llb.exec(
      base,
      'pwd > llb-cwd; printf "$LLB_FLAG" > llb-env; read line; printf "$line" > llb-stdin',
      {
        cwd: "/home/user",
        env: { LLB_FLAG: "changed" },
        stdin: "payload\n",
      },
    );
    const execChangedManifest = await llb.commit(execEnvChanged).asImage({ store, kernel });
    const execChangedVm = await mc.create({
      kernel,
      image: execChangedManifest,
      store,
      deterministic: true,
    });
    try {
      const env = await execChangedVm.fs.readText("/home/user/llb-env");
      if (env !== "changed") {
        throw new Error(`llb exec cache key ignored env: ${JSON.stringify(env)}`);
      }
    } finally {
      await execChangedVm.close();
    }

    if (execManifest.config.tier !== "read-write") {
      throw new Error(
        `llb exec default tier was not read-write: ${JSON.stringify(execManifest.config)}`,
      );
    }
    let defaultSpawnDenied = false;
    try {
      await llb
        .commit(llb.exec(base, "sh -c 'printf child > /home/user/llb-child'"))
        .asImage({ store, kernel });
    } catch (err) {
      defaultSpawnDenied = /denied|permission|cap|spawn|exit/i.test(String(err));
    }
    if (!defaultSpawnDenied) {
      throw new Error("llb exec default tier allowed a child process spawn");
    }
    const fullSpawnManifest = await llb
      .commit(llb.exec(base, "sh -c 'printf child > /home/user/llb-child'", { tier: "full" }))
      .asImage({ store, kernel });
    const fullSpawnVm = await mc.create({
      kernel,
      image: fullSpawnManifest,
      store,
      deterministic: true,
    });
    try {
      const child = await fullSpawnVm.fs.readText("/home/user/llb-child");
      if (child !== "child") {
        throw new Error(
          `llb exec explicit full tier did not spawn child shell: ${JSON.stringify(child)}`,
        );
      }
    } finally {
      await fullSpawnVm.close();
    }
    console.log(
      "phase: llb exec defaults to read-write and requires explicit full for child spawn",
    );

    const branchA = llb.write(base, "/etc/llb-a", "a\n");
    const branchB = llb.write(base, "/etc/llb-b", "b\n");
    const mergedManifest = await llb.commit(llb.merge(branchA, branchB)).asImage({ store, kernel });
    const mergedLayerDigests = mergedManifest.layers.map((layer) => layer.digest);
    if (
      mergedManifest.layers.length !== 3 ||
      mergedLayerDigests[0] !== baseDigest ||
      new Set(mergedLayerDigests).size !== mergedLayerDigests.length
    ) {
      throw new Error(
        `llb merge did not deduplicate shared provenance: ${JSON.stringify(mergedManifest.layers)}`,
      );
    }
    const mergedVm = await mc.create({ kernel, image: mergedManifest, store, deterministic: true });
    try {
      const a = await mergedVm.fs.readText("/etc/llb-a");
      const b = await mergedVm.fs.readText("/etc/llb-b");
      if (a !== "a\n" || b !== "b\n") {
        throw new Error(
          `llb merge lost branch bytes: a=${JSON.stringify(a)} b=${JSON.stringify(b)}`,
        );
      }
    } finally {
      await mergedVm.close();
    }

    const diffManifest = await llb.commit(llb.diff(base, written)).asImage({ store, kernel });
    if (
      diffManifest.layers.length !== 1 ||
      diffManifest.layers[0]?.digest !== manifest.layers[1]?.digest
    ) {
      throw new Error(
        `llb ancestral diff did not subtract lower provenance: ${JSON.stringify(diffManifest.layers)}`,
      );
    }
    const diffVm = await mc.create({
      kernel,
      image: {
        schema: 1,
        layers: [{ digest: baseDigest, size: image.length }, ...diffManifest.layers],
        config: {},
      },
      store,
      deterministic: true,
    });
    try {
      const out = await diffVm.fs.readText("/etc/llb-flavor");
      if (out !== "acme\n") {
        throw new Error(
          `llb ancestral diff layer did not replay over lower: ${JSON.stringify(out)}`,
        );
      }
    } finally {
      await diffVm.close();
    }

    const branchAManifest = await llb.commit(branchA).asImage({ store, kernel });
    const disjointDiff = await llb.commit(llb.diff(branchA, branchB)).asImage({ store, kernel });
    const disjointVm = await mc.create({
      kernel,
      image: { schema: 1, layers: [...branchAManifest.layers, ...disjointDiff.layers], config: {} },
      store,
      deterministic: true,
    });
    try {
      const b = await disjointVm.fs.readText("/etc/llb-b");
      let aWhiteouted = false;
      try {
        await disjointVm.fs.readText("/etc/llb-a");
      } catch {
        aWhiteouted = true;
      }
      if (b !== "b\n" || !aWhiteouted) {
        throw new Error(
          `llb disjoint diff did not replay: b=${JSON.stringify(b)} aWhiteouted=${aWhiteouted}`,
        );
      }
    } finally {
      await disjointVm.close();
    }
    console.log("phase: llb merge/diff provenance algebra boots real bytes OK");

    const fatDirs = llb.mkdir(
      llb.mkdir(llb.mkdir(base, "/home/user/stage"), "/home/user/stage/bin"),
      "/home/user/stage/share",
    );
    const fatFiles = llb.write(
      llb.write(fatDirs, "/home/user/stage/bin/app", "copied-app"),
      "/home/user/stage/share/data.txt",
      "copied-data",
    );
    const fatModeStage = llb.chmod(
      llb.chmod(fatFiles, "/home/user/stage/bin/app", 0o755),
      "/home/user/stage/share",
      0o700,
    );
    const fatStage = llb.symlink(fatModeStage, "data.txt", "/home/user/stage/share/data-link");
    const fatManifest = await llb.commit(fatStage).asImage({ store, kernel });
    const copiedStage = llb.copy(base, fatStage, [
      { from: "/home/user/stage/bin/app", to: "/home/user/copied/app" },
      { from: "/home/user/stage/share", to: "/home/user/copied/share" },
    ]);
    const copyManifest = await llb.commit(copiedStage).asImage({ store, kernel });
    const fatTip = fatManifest.layers[fatManifest.layers.length - 1]?.digest;
    if (!fatTip || copyManifest.layers.some((layer) => layer.digest === fatTip)) {
      throw new Error(
        `llb.copy polluted the destination stack with source layers: fat=${JSON.stringify(fatManifest.layers)} copy=${JSON.stringify(copyManifest.layers)}`,
      );
    }
    const copyVm = await mc.create({ kernel, image: copyManifest, store, deterministic: true });
    try {
      const app = await copyVm.fs.readText("/home/user/copied/app");
      const data = await copyVm.fs.readText("/home/user/copied/share/data.txt");
      const linkedData = await copyVm.fs.readText("/home/user/copied/share/data-link");
      const linkTarget = await copyVm.fs.readlink("/home/user/copied/share/data-link");
      const appMode = (await copyVm.fs.stat("/home/user/copied/app")).mode;
      const shareMode = (await copyVm.fs.stat("/home/user/copied/share")).mode;
      const linkStat = await copyVm.fs.stat("/home/user/copied/share/data-link");
      let sourcePolluted = false;
      try {
        await copyVm.fs.readText("/home/user/stage/bin/app");
        sourcePolluted = true;
      } catch {
        // Expected: copy brings selected bytes, not the whole source stage.
      }
      if (
        app !== "copied-app" ||
        data !== "copied-data" ||
        linkedData !== "copied-data" ||
        linkTarget !== "data.txt" ||
        !linkStat.isSymlink ||
        appMode !== 0o755 ||
        shareMode !== 0o700 ||
        sourcePolluted
      ) {
        throw new Error(
          `llb.copy mismatch: app=${JSON.stringify(app)} data=${JSON.stringify(data)} linkedData=${JSON.stringify(linkedData)} linkTarget=${JSON.stringify(linkTarget)} linkStat=${JSON.stringify(linkStat)} appMode=${appMode.toString(8)} shareMode=${shareMode.toString(8)} sourcePolluted=${sourcePolluted}`,
        );
      }
    } finally {
      await copyVm.close();
    }
    const copyDefinition = await llb.toDefinition(copiedStage, { store });
    const copyFromDefinition = await llb
      .commit(llb.decodeDefinition(llb.encodeDefinition(copyDefinition)))
      .asImage({
        store,
        kernel,
      });
    if (JSON.stringify(copyFromDefinition.layers) !== JSON.stringify(copyManifest.layers)) {
      throw new Error(
        `llb.copy Definition replay diverged: definition=${JSON.stringify(copyFromDefinition.layers)} direct=${JSON.stringify(copyManifest.layers)}`,
      );
    }
    console.log("phase: llb copy builds a thin stage and round-trips through Definition OK");

    const localRoot = mkdtempSync(join(tmpdir(), "mc-llb-local-"));
    mkdirSync(join(localRoot, "nested"));
    writeFileSync(join(localRoot, "root.txt"), "local-root-v1");
    writeFileSync(join(localRoot, "nested", "child.txt"), "local-child");
    chmodSync(join(localRoot, "nested"), 0o700);
    chmodSync(join(localRoot, "nested", "child.txt"), 0o755);
    const localStage = llb.local(localRoot, { dest: "/home/user/local-src" });
    const localManifest = await llb.commit(localStage).asImage({ store, kernel });
    const localVm = await mc.create({ kernel, image: localManifest, store, deterministic: true });
    try {
      const root = await localVm.fs.readText("/home/user/local-src/root.txt");
      const child = await localVm.fs.readText("/home/user/local-src/nested/child.txt");
      const nestedMode = (await localVm.fs.stat("/home/user/local-src/nested")).mode;
      const childMode = (await localVm.fs.stat("/home/user/local-src/nested/child.txt")).mode;
      if (
        root !== "local-root-v1" ||
        child !== "local-child" ||
        nestedMode !== 0o700 ||
        childMode !== 0o755
      ) {
        throw new Error(
          `llb.local mismatch: root=${JSON.stringify(root)} child=${JSON.stringify(child)} nestedMode=${nestedMode.toString(8)} childMode=${childMode.toString(8)}`,
        );
      }
    } finally {
      await localVm.close();
    }
    const localDefinition = await llb.toDefinition(localStage, { store });
    const localFromDefinition = await llb
      .commit(llb.decodeDefinition(llb.encodeDefinition(localDefinition)))
      .asImage({
        store,
        kernel,
      });
    if (JSON.stringify(localFromDefinition.layers) !== JSON.stringify(localManifest.layers)) {
      throw new Error(
        `llb.local Definition replay diverged: definition=${JSON.stringify(localFromDefinition.layers)} direct=${JSON.stringify(localManifest.layers)}`,
      );
    }
    writeFileSync(join(localRoot, "root.txt"), "local-root-v2");
    const changedManifest = await llb.commit(localStage).asImage({ store, kernel });
    const changedVm = await mc.create({
      kernel,
      image: changedManifest,
      store,
      deterministic: true,
    });
    try {
      const root = await changedVm.fs.readText("/home/user/local-src/root.txt");
      if (
        root !== "local-root-v2" ||
        JSON.stringify(changedManifest.layers) === JSON.stringify(localManifest.layers)
      ) {
        throw new Error(
          `llb.local cache key ignored host content: root=${JSON.stringify(root)} before=${JSON.stringify(localManifest.layers)} after=${JSON.stringify(changedManifest.layers)}`,
        );
      }
    } finally {
      await changedVm.close();
    }
    console.log("phase: llb local source scans host context and round-trips through Definition OK");

    const memoryPlatform: SolvePlatform = {
      async localSource(root) {
        if (root !== "mem://context") throw new Error(`unexpected memory local root ${root}`);
        const bytes = new TextEncoder().encode("memory-platform");
        return {
          digest: "memory-local-v1",
          entries: [
            { kind: "dir", rel: "" },
            { kind: "dir", rel: "nested" },
            { kind: "file", rel: "nested/value.txt", bytes, digest: await sha256Digest(bytes) },
          ],
        };
      },
      async gitSource() {
        throw new Error("memory platform does not provide git sources");
      },
      async cacheMounts() {
        return [];
      },
    };
    const memoryLocalManifest = await llb
      .commit(llb.local("mem://context", { dest: "/home/user/memory-local" }))
      .asImage({ store, kernel, platform: memoryPlatform });
    const memoryLocalVm = await mc.create({
      kernel,
      image: memoryLocalManifest,
      store,
      deterministic: true,
    });
    try {
      const value = await memoryLocalVm.fs.readText("/home/user/memory-local/nested/value.txt");
      if (value !== "memory-platform") {
        throw new Error(
          `llb injected local-source platform bytes mismatch: ${JSON.stringify(value)}`,
        );
      }
    } finally {
      await memoryLocalVm.close();
    }
    console.log("phase: llb local source accepts injected non-node platform OK");

    const httpRoutes = new Map<string, Uint8Array>([
      ["/artifact.bin", new TextEncoder().encode("http-source-v1")],
    ]);
    const http = await bytesServer(httpRoutes);
    try {
      const url = `${http.origin}/artifact.bin`;
      const sha256 = await sha256Digest(httpRoutes.get("/artifact.bin")!);
      const httpStage = llb.http(url, { dest: "/home/user/http/artifact.bin", sha256 });
      const httpManifest = await llb.commit(httpStage).asImage({ store, kernel });
      if (http.requests.length !== 1) {
        throw new Error(
          `llb.http asImage fetched ${http.requests.length} times while building one source`,
        );
      }
      const httpVm = await mc.create({ kernel, image: httpManifest, store, deterministic: true });
      try {
        const body = await httpVm.fs.readText("/home/user/http/artifact.bin");
        if (body !== "http-source-v1") {
          throw new Error(`llb.http bytes mismatch: ${JSON.stringify(body)}`);
        }
      } finally {
        await httpVm.close();
      }
      const httpDefinition = await llb.toDefinition(httpStage, { store });
      const httpFromDefinition = await llb
        .commit(llb.decodeDefinition(llb.encodeDefinition(httpDefinition)))
        .asImage({
          store,
          kernel,
        });
      if (JSON.stringify(httpFromDefinition.layers) !== JSON.stringify(httpManifest.layers)) {
        throw new Error(
          `llb.http Definition replay diverged: definition=${JSON.stringify(httpFromDefinition.layers)} direct=${JSON.stringify(httpManifest.layers)}`,
        );
      }
      let digestRejected = false;
      try {
        await llb
          .commit(
            llb.http(url, { dest: "/home/user/http/bad.bin", sha256: `sha256:${"0".repeat(64)}` }),
          )
          .asImage({
            store,
            kernel,
          });
      } catch {
        digestRejected = true;
      }
      if (!digestRejected)
        throw new Error("llb.http accepted bytes that did not match the pinned digest");

      httpRoutes.set("/artifact.bin", new TextEncoder().encode("http-source-v2"));
      const changedHttp = llb.http(url, { dest: "/home/user/http/artifact.bin" });
      const changedHttpManifest = await llb.commit(changedHttp).asImage({ store, kernel });
      const changedHttpVm = await mc.create({
        kernel,
        image: changedHttpManifest,
        store,
        deterministic: true,
      });
      try {
        const body = await changedHttpVm.fs.readText("/home/user/http/artifact.bin");
        if (
          body !== "http-source-v2" ||
          JSON.stringify(changedHttpManifest.layers) === JSON.stringify(httpManifest.layers)
        ) {
          throw new Error(
            `llb.http cache key ignored fetched bytes: body=${JSON.stringify(body)} before=${JSON.stringify(httpManifest.layers)} after=${JSON.stringify(changedHttpManifest.layers)}`,
          );
        }
      } finally {
        await changedHttpVm.close();
      }
    } finally {
      await http.close();
    }
    console.log("phase: llb http source verifies digests and round-trips through Definition OK");

    const gitRoot = mkdtempSync(join(tmpdir(), "mc-llb-git-"));
    runGit(gitRoot, ["init", "--quiet"]);
    mkdirSync(join(gitRoot, "src"));
    writeFileSync(join(gitRoot, "src", "app.txt"), "git-v1");
    writeFileSync(join(gitRoot, "README.md"), "readme-v1");
    runGit(gitRoot, ["add", "."]);
    runGit(gitRoot, ["commit", "--quiet", "-m", "v1"]);
    const commit1 = runGit(gitRoot, ["rev-parse", "HEAD"]).trim();
    const gitStage = llb.git(gitRoot, { ref: commit1, dest: "/home/user/git-src" });
    const gitManifest = await llb.commit(gitStage).asImage({ store, kernel });
    const gitVm = await mc.create({ kernel, image: gitManifest, store, deterministic: true });
    try {
      const app = await gitVm.fs.readText("/home/user/git-src/src/app.txt");
      const readme = await gitVm.fs.readText("/home/user/git-src/README.md");
      if (app !== "git-v1" || readme !== "readme-v1") {
        throw new Error(
          `llb.git bytes mismatch: app=${JSON.stringify(app)} readme=${JSON.stringify(readme)}`,
        );
      }
    } finally {
      await gitVm.close();
    }
    const gitDefinition = await llb.toDefinition(gitStage, { store });
    const gitFromDefinition = await llb
      .commit(llb.decodeDefinition(llb.encodeDefinition(gitDefinition)))
      .asImage({
        store,
        kernel,
      });
    if (JSON.stringify(gitFromDefinition.layers) !== JSON.stringify(gitManifest.layers)) {
      throw new Error(
        `llb.git Definition replay diverged: definition=${JSON.stringify(gitFromDefinition.layers)} direct=${JSON.stringify(gitManifest.layers)}`,
      );
    }

    writeFileSync(join(gitRoot, "src", "app.txt"), "git-v2");
    runGit(gitRoot, ["add", "."]);
    runGit(gitRoot, ["commit", "--quiet", "-m", "v2"]);
    const changedGit = llb.git(`file://${gitRoot}`, { ref: "HEAD", dest: "/home/user/git-src" });
    const changedGitManifest = await llb.commit(changedGit).asImage({ store, kernel });
    const changedGitVm = await mc.create({
      kernel,
      image: changedGitManifest,
      store,
      deterministic: true,
    });
    try {
      const app = await changedGitVm.fs.readText("/home/user/git-src/src/app.txt");
      if (
        app !== "git-v2" ||
        JSON.stringify(changedGitManifest.layers) === JSON.stringify(gitManifest.layers)
      ) {
        throw new Error(
          `llb.git cache key ignored resolved commit: app=${JSON.stringify(app)} before=${JSON.stringify(gitManifest.layers)} after=${JSON.stringify(changedGitManifest.layers)}`,
        );
      }
    } finally {
      await changedGitVm.close();
    }
    console.log("phase: llb git source archives refs and round-trips through Definition OK");

    const shared = llb.write(base, "/etc/llb-shared", "shared\n");
    store.reset();
    const sharedManifest = await llb.commit(llb.image([shared, shared])).asImage({ store, kernel });
    if (sharedManifest.layers.length !== 2 || store.putDigests.length !== 1) {
      throw new Error(
        `llb in-flight dedup materialized shared vertex ${store.putDigests.length} times: ${JSON.stringify(sharedManifest.layers)}`,
      );
    }

    const cachedFsOps = llb.symlink(
      llb.chmod(
        llb.write(
          llb.mkdir(base, "/home/user/llb-fs-cache"),
          "/home/user/llb-fs-cache/file",
          "fs-cache\n",
        ),
        "/home/user/llb-fs-cache/file",
        0o600,
      ),
      "/home/user/llb-fs-cache/file",
      "/home/user/llb-fs-cache-link",
    );
    store.reset();
    const fsFirst = await llb.commit(cachedFsOps).asImage({ store, kernel });
    const fsPutsAfterFirst = store.putCount();
    const fsSecond = await llb.commit(cachedFsOps).asImage({ store, kernel });
    if (
      fsPutsAfterFirst !== 4 ||
      store.putCount() !== fsPutsAfterFirst ||
      JSON.stringify(fsFirst.layers) !== JSON.stringify(fsSecond.layers)
    ) {
      throw new Error(
        `llb file-op cache miss: puts=${store.putCount()} first=${JSON.stringify(fsFirst.layers)} second=${JSON.stringify(fsSecond.layers)}`,
      );
    }
    const fsVm = await mc.create({ kernel, image: fsFirst, store, deterministic: true });
    try {
      const link = await fsVm.fs.readText("/home/user/llb-fs-cache-link");
      const mode = (await fsVm.fs.stat("/home/user/llb-fs-cache/file")).mode;
      if (link !== "fs-cache\n" || mode !== 0o600) {
        throw new Error(
          `llb file-op replay mismatch: link=${JSON.stringify(link)} mode=${mode.toString(8)}`,
        );
      }
    } finally {
      await fsVm.close();
    }

    store.reset();
    const definition = await llb.toDefinition(cachedFsOps, { store });
    const writeDefinitions = definition.ops.filter((op) => op.data_digest);
    if (
      writeDefinitions.length !== 1 ||
      !writeDefinitions[0]!.data_digest?.startsWith("sha256:") ||
      store.putBlobDigests.length !== 1 ||
      definition.ops.some((op) => "ref" in (op as unknown as Record<string, unknown>))
    ) {
      throw new Error(
        `llb Definition did not use clean out-of-line payloads: ${JSON.stringify(definition)}`,
      );
    }
    const encodedDefinition = llb.encodeDefinition(definition);
    const decodedDefinition = llb.decodeDefinition(encodedDefinition);
    const reencodedDefinition = llb.encodeDefinition(decodedDefinition);
    if (Buffer.compare(Buffer.from(reencodedDefinition), Buffer.from(encodedDefinition)) !== 0) {
      throw new Error(
        `llb Definition codec round-trip changed bytes: before=${JSON.stringify([...encodedDefinition])} after=${JSON.stringify([...reencodedDefinition])}`,
      );
    }
    const dirtySourceDefinition: BuildDefinition = {
      version: 1,
      root: 0,
      ops: [
        {
          kind: 0,
          source_ref: "llb-base",
          parts: [],
          copy_paths: [],
          env: { SHOULD_NOT_EXIST: "1" },
          mounts: [],
        },
      ],
    };
    let unusedFieldRejected = false;
    try {
      await llb.fromDefinition(dirtySourceDefinition, { store });
    } catch (err) {
      unusedFieldRejected = /unused field env/.test(String(err));
    }
    if (!unusedFieldRejected) {
      throw new Error("llb Definition accepted a source op with an unused env field");
    }
    let legacyNetworkSourceRejected = false;
    try {
      llb.source("/net/example.test/artifact.tar");
    } catch (err) {
      legacyNetworkSourceRejected = /llb\.http/.test(String(err));
    }
    if (!legacyNetworkSourceRejected) {
      throw new Error("llb.source accepted a legacy /net source instead of requiring llb.http()");
    }
    let legacyNetworkDefinitionRejected = false;
    try {
      await llb.fromDefinition(
        {
          version: 1,
          root: 0,
          ops: [
            {
              kind: 0,
              source_ref: "https://example.test/artifact.tar",
              parts: [],
              copy_paths: [],
              env: {},
              mounts: [],
            },
          ],
        },
        { store },
      );
    } catch (err) {
      legacyNetworkDefinitionRejected = /llb\.http/.test(String(err));
    }
    if (!legacyNetworkDefinitionRejected) {
      throw new Error("llb Definition accepted an HTTP source_ref instead of requiring an http op");
    }
    const emptyStdinDefinition = await llb.toDefinition(llb.exec(base, "true", { stdin: "" }), {
      store,
    });
    const emptyStdinOp = emptyStdinDefinition.ops.find((op) => op.cmd === "true");
    const emptyStdinState = await llb.fromDefinition(emptyStdinDefinition, { store });
    if (
      emptyStdinOp?.stdin === undefined ||
      emptyStdinOp.stdin === null ||
      emptyStdinOp.stdin.length !== 0 ||
      emptyStdinState.node.op !== "exec" ||
      !(emptyStdinState.node.opts.stdin instanceof Uint8Array) ||
      emptyStdinState.node.opts.stdin.length !== 0
    ) {
      throw new Error(
        `llb Definition lost present-but-empty stdin: ${JSON.stringify(emptyStdinDefinition)}`,
      );
    }
    const definitionManifest = await llb.commit(decodedDefinition).asImage({ store, kernel });
    const directDefinitionManifest = await llb.commit(cachedFsOps).asImage({ store, kernel });
    if (
      JSON.stringify(definitionManifest.layers) !== JSON.stringify(directDefinitionManifest.layers)
    ) {
      throw new Error(
        `llb Definition commit diverged from direct DAG: definition=${JSON.stringify(definitionManifest.layers)} direct=${JSON.stringify(directDefinitionManifest.layers)}`,
      );
    }
    const buildRecord = definitionManifest.build;
    if (!buildRecord || !directDefinitionManifest.build) {
      throw new Error(
        `llb image did not carry build provenance: ${JSON.stringify(definitionManifest)}`,
      );
    }
    const expectedDefinitionDigest = await sha256Digest(encodedDefinition);
    const expectedKernelDigest = await sha256Digest(kernel);
    const expectedBlobRef = writeDefinitions[0]!.data_digest!;
    const recordedDefinitionBytes = Uint8Array.from(buildRecord.definition.bytes);
    if (
      buildRecord.schema !== 1 ||
      buildRecord.definition.encoding !== "mc.llb.definition.v1" ||
      buildRecord.definition.digest !== expectedDefinitionDigest ||
      buildRecord.kernelDigest !== expectedKernelDigest ||
      buildRecord.rootDigest !== directDefinitionManifest.build.rootDigest ||
      JSON.stringify(buildRecord.storeRefs.layers) !== JSON.stringify(definitionManifest.layers) ||
      buildRecord.storeRefs.blobs.length !== 1 ||
      buildRecord.storeRefs.blobs[0] !== expectedBlobRef ||
      Buffer.compare(Buffer.from(recordedDefinitionBytes), Buffer.from(encodedDefinition)) !== 0
    ) {
      throw new Error(`llb build provenance mismatch: ${JSON.stringify(buildRecord)}`);
    }
    const provenanceDefinitionManifest = await llb
      .commit(llb.decodeDefinition(recordedDefinitionBytes))
      .asImage({ store, kernel });
    if (
      JSON.stringify(provenanceDefinitionManifest.layers) !==
      JSON.stringify(definitionManifest.layers)
    ) {
      throw new Error(
        `llb build provenance definition did not replay: provenance=${JSON.stringify(provenanceDefinitionManifest.layers)} definition=${JSON.stringify(definitionManifest.layers)}`,
      );
    }
    await store.putManifest("llb-provenance", definitionManifest);
    const storedProvenanceManifest = await store.manifest("llb-provenance");
    if (
      storedProvenanceManifest.build?.definition.digest !== buildRecord.definition.digest ||
      JSON.stringify(storedProvenanceManifest.build.definition.bytes) !==
        JSON.stringify(buildRecord.definition.bytes)
    ) {
      throw new Error(
        `llb build provenance did not survive manifest storage: ${JSON.stringify(storedProvenanceManifest)}`,
      );
    }
    const definitionVm = await mc.create({
      kernel,
      image: definitionManifest,
      store,
      deterministic: true,
    });
    try {
      const link = await definitionVm.fs.readText("/home/user/llb-fs-cache-link");
      const mode = (await definitionVm.fs.stat("/home/user/llb-fs-cache/file")).mode;
      if (link !== "fs-cache\n" || mode !== 0o600) {
        throw new Error(
          `llb Definition replay mismatch: link=${JSON.stringify(link)} mode=${mode.toString(8)}`,
        );
      }
    } finally {
      await definitionVm.close();
    }
    console.log(
      "phase: llb Definition codec round-trip and build provenance commit bootable file ops OK",
    );

    const cached = llb.write(base, "/etc/llb-cached", "cached\n");
    store.reset();
    const firstProgress: SolveProgressEvent[] = [];
    const cachedFirst = await llb.commit(cached).asImage({
      store,
      kernel,
      onProgress: (event) => {
        firstProgress.push(event);
      },
    });
    const putsAfterFirst = store.putCount();
    const secondProgress: SolveProgressEvent[] = [];
    const cachedSecond = await llb.commit(cached).asImage({
      store,
      kernel,
      onProgress: (event) => {
        secondProgress.push(event);
      },
    });
    if (
      putsAfterFirst !== 1 ||
      store.putCount() !== putsAfterFirst ||
      JSON.stringify(cachedFirst.layers) !== JSON.stringify(cachedSecond.layers)
    ) {
      throw new Error(
        `llb deterministic cache miss: puts=${store.putCount()} first=${JSON.stringify(cachedFirst.layers)} second=${JSON.stringify(cachedSecond.layers)}`,
      );
    }
    if (
      !firstProgress.some((event) => event.type === "completed" && event.op === "write") ||
      !secondProgress.some((event) => event.type === "cached" && event.op === "write")
    ) {
      throw new Error(
        `llb progress did not report completed/cache events: first=${JSON.stringify(firstProgress)} second=${JSON.stringify(secondProgress)}`,
      );
    }

    const mountedExec = llb.exec(base, "printf mounted > /home/user/llb-mounted-cache", {
      mounts: [llb.cache("/mnt/build-cache")],
    });
    store.reset();
    const mountedFirst = await llb.commit(mountedExec).asImage({ store, kernel });
    const mountedPutsAfterFirst = store.putCount();
    const mountedSecond = await llb.commit(mountedExec).asImage({ store, kernel });
    if (
      mountedPutsAfterFirst !== 1 ||
      store.putCount() !== mountedPutsAfterFirst ||
      JSON.stringify(mountedFirst.layers) !== JSON.stringify(mountedSecond.layers)
    ) {
      throw new Error(
        `llb cache-mounted exec was not memoized: puts=${store.putCount()} first=${JSON.stringify(mountedFirst.layers)} second=${JSON.stringify(mountedSecond.layers)}`,
      );
    }
    const mountedVm = await mc.create({ kernel, image: mountedFirst, store, deterministic: true });
    try {
      const mounted = await mountedVm.fs.readText("/home/user/llb-mounted-cache");
      if (mounted !== "mounted") {
        throw new Error(`llb cache-mounted exec bytes mismatch: ${JSON.stringify(mounted)}`);
      }
    } finally {
      await mountedVm.close();
    }

    const netNode = llb.exec(base, "printf net > /tmp/llb-net", { net: true });
    store.reset();
    await llb.commit(netNode).asImage({ store, kernel });
    await llb.commit(netNode).asImage({ store, kernel });
    const netPutCount = store.putCount();
    if (netPutCount !== 2) {
      throw new Error(`llb net node was memoized across solves: puts=${netPutCount}`);
    }

    const kernelKeyNode = llb.write(base, "/etc/llb-kernel-key", "kernel\n");
    store.reset();
    await llb.commit(kernelKeyNode).asImage({ store, kernel });
    const invalidKernel = kernel.slice();
    invalidKernel[0] ^= 0xff;
    let staleHit = false;
    try {
      await llb.commit(kernelKeyNode).asImage({ store, kernel: invalidKernel });
      staleHit = true;
    } catch {
      // Expected: a different kernel byte stream must miss the node cache and try to boot.
    }
    if (staleHit) {
      throw new Error("llb VM-booting node reused a cached layer after kernel bytes changed");
    }
    console.log(
      "phase: llb cache soundness covers in-flight, deterministic, net, and kernel-key cases",
    );

    const snapshotNode = llb.write(base, "/home/user/snapshot-base", "snapshot-base");
    const snapshotManifest = await llb.commit(snapshotNode).asImage({ store, kernel });
    store.reset();
    const coldSnapshot = await llb.commit(snapshotNode).asSnapshot({ store, kernel });
    const warmSnapshot = await llb.commit(snapshotNode).asSnapshot({
      store,
      kernel,
      warm: [
        {
          kind: "exec",
          cmd: 'read line; printf "$WARM_FLAG:$line" > warm-marker',
          cwd: "/home/user",
          env: { WARM_FLAG: "warm" },
          stdin: "stdin\n",
        },
      ],
    });
    const svcWarmSnapshot = await llb.commit(snapshotNode).asSnapshot({
      store,
      kernel,
      warm: [
        {
          kind: "svc",
          name: "tools",
          request: new TextEncoder().encode(JSON.stringify({ op: "list" })),
        },
      ],
    });
    if (
      store.putSnapshotKeys.length !== 3 ||
      new Set(store.putSnapshotKeys).size !== store.putSnapshotKeys.length
    ) {
      throw new Error(
        `llb warm snapshot did not use distinct memo keys: ${JSON.stringify(store.putSnapshotKeys)}`,
      );
    }
    const coldVm = await mc.restore(coldSnapshot, {
      kernel,
      image: snapshotManifest,
      store,
      deterministic: true,
    });
    try {
      let coldHasWarmMarker = false;
      try {
        await coldVm.fs.readText("/home/user/warm-marker");
        coldHasWarmMarker = true;
      } catch {
        // Expected: no warm directive ran for the cold snapshot.
      }
      if (coldHasWarmMarker)
        throw new Error("cold llb snapshot unexpectedly contained warm marker");
    } finally {
      await coldVm.close();
    }
    const warmVm = await mc.restore(warmSnapshot, {
      kernel,
      image: snapshotManifest,
      store,
      deterministic: true,
    });
    try {
      const marker = await warmVm.fs.readText("/home/user/warm-marker");
      if (marker !== "warm:stdin") {
        throw new Error(`llb warm snapshot marker mismatch: ${JSON.stringify(marker)}`);
      }
    } finally {
      await warmVm.close();
    }
    const svcWarmVm = await mc.restore(svcWarmSnapshot, {
      kernel,
      image: snapshotManifest,
      store,
      deterministic: true,
    });
    try {
      const status = await svcWarmVm.fs.readText("/svc/tools");
      if (status.trim() !== "ready") {
        throw new Error(
          `llb service warm snapshot did not preserve a ready /svc/tools service: ${JSON.stringify(status)}`,
        );
      }
      const listed = await svcWarmVm.exec("tools list");
      if (listed.exitCode !== 0 || !listed.stdout.includes('"tools"')) {
        throw new Error(
          `llb service warm snapshot could not call warmed /svc/tools: exit=${listed.exitCode} stdout=${JSON.stringify(listed.stdout)} stderr=${JSON.stringify(listed.stderr)}`,
        );
      }
    } finally {
      await svcWarmVm.close();
    }
    console.log("phase: llb warm snapshot runs exec and service warm-up before capture OK");

    const sqliteWarmChild = `local sqlite = require("sqlite")
local sys = require("sys")
local time = require("time")

local db = assert(sqlite.open("/home/user/warm-snapshot.db"))
db:exec("CREATE TABLE IF NOT EXISTS numbers (v INTEGER)")
db:exec("DELETE FROM numbers")
db:exec("INSERT INTO numbers VALUES (?)", 41)
local stmt = db:prepare("SELECT v + ? AS answer FROM numbers")
assert(sys.fs.write("/home/user/sqlite-ready", "prepared"))

while not sys.fs.exists("/home/user/sqlite-go") do
  time.sleep(1)
end

local row = assert(stmt:queryone(1))
assert(sys.fs.write("/home/user/sqlite-result", tostring(row.answer)))
stmt:close()
db:close()
`;
    const sqliteWaitReady = `local sys = require("sys")
local time = require("time")

for _ = 1, 1000 do
  if sys.fs.exists("/home/user/sqlite-ready") then
    sys.proc.exit(0)
  end
  time.sleep(1)
end

local err = sys.fs.read("/home/user/sqlite-child.err") or ""
error("timed out waiting for warm sqlite child: " .. err)
`;
    const sqliteWaitResult = `local sys = require("sys")
local time = require("time")

for _ = 1, 1000 do
  local result = sys.fs.read("/home/user/sqlite-result")
  if result then
    print(result)
    sys.proc.exit(0)
  end
  time.sleep(1)
end

local err = sys.fs.read("/home/user/sqlite-child.err") or ""
error("timed out waiting for restored warm sqlite child: " .. err)
`;
    const sqliteWarmNode = llb.write(
      llb.write(
        llb.write(atlas, "/home/user/sqlite-warm-child.luau", sqliteWarmChild),
        "/home/user/sqlite-wait-ready.luau",
        sqliteWaitReady,
      ),
      "/home/user/sqlite-wait-result.luau",
      sqliteWaitResult,
    );
    const sqliteWarmManifest = await llb.commit(sqliteWarmNode).asImage({ store, kernel });
    store.reset();
    const sqliteColdSnapshot = await llb.commit(sqliteWarmNode).asSnapshot({ store, kernel });
    const sqlitePreparedSnapshot = await llb.commit(sqliteWarmNode).asSnapshot({
      store,
      kernel,
      warm: [
        {
          kind: "exec",
          cmd: "luau /home/user/sqlite-warm-child.luau >/home/user/sqlite-child.out 2>/home/user/sqlite-child.err & luau /home/user/sqlite-wait-ready.luau",
        },
      ],
    });
    const sqliteSnapshotKeys = [...store.putSnapshotKeys];
    if (
      sqliteSnapshotKeys.length !== 2 ||
      new Set(sqliteSnapshotKeys).size !== sqliteSnapshotKeys.length
    ) {
      throw new Error(
        `llb atlas warm snapshot did not use distinct memo keys: ${JSON.stringify(sqliteSnapshotKeys)}`,
      );
    }
    const sqliteColdVm = await mc.restore(sqliteColdSnapshot, {
      kernel,
      image: sqliteWarmManifest,
      store,
      deterministic: true,
    });
    try {
      let coldPrepared = false;
      try {
        await sqliteColdVm.fs.readText("/home/user/sqlite-ready");
        coldPrepared = true;
      } catch {
        // Expected: the cold snapshot never started the SQLite client.
      }
      if (coldPrepared)
        throw new Error("cold atlas snapshot unexpectedly had a prepared SQLite statement");
    } finally {
      await sqliteColdVm.close();
    }
    const sqliteWarmVm = await mc.restore(sqlitePreparedSnapshot, {
      kernel,
      image: sqliteWarmManifest,
      store,
      deterministic: true,
    });
    try {
      const ready = await sqliteWarmVm.fs.readText("/home/user/sqlite-ready");
      if (ready !== "prepared") {
        throw new Error(
          `atlas warm snapshot did not restore the prepared marker: ${JSON.stringify(ready)}`,
        );
      }
      await sqliteWarmVm.fs.write("/home/user/sqlite-go", "1");
      const result = await sqliteWarmVm.exec("luau /home/user/sqlite-wait-result.luau");
      if (result.exitCode !== 0 || result.stdout.trim() !== "42") {
        const err = await sqliteWarmVm.fs.readText("/home/user/sqlite-child.err").catch(() => "");
        throw new Error(
          `restored atlas warm SQLite statement failed: exit=${result.exitCode} stdout=${JSON.stringify(result.stdout)} stderr=${JSON.stringify(result.stderr)} child=${JSON.stringify(err)}`,
        );
      }
    } finally {
      await sqliteWarmVm.close();
    }
    console.log("phase: llb atlas warm snapshot preserves a live SQLite prepared statement OK");
  }

  // Bytes passed directly → no MC_STORE / defaultKernel env path; the embedded backend (the JS host)
  // boots the kernel in-process.
  const vmOptions: CreateOptions = {
    runtime: LOCAL_RUNTIME,
    kernel,
    image,
    deterministic: true,
    tools: [],
    mounts: [],
  };
  const vm = await mc.create(vmOptions);
  try {
    const r = await vm.exec("echo core-ok");
    if (r.exitCode !== 0 || r.stdout.trim() !== "core-ok") {
      throw new Error(`vm.exec mismatch: exit=${r.exitCode} stdout=${JSON.stringify(r.stdout)}`);
    }
    await vm.fs.mkdir("/home/user/exec-cwd");
    const execOpts = await vm.exec('pwd; printf "$MC_EXEC_FLAG\\n"; read line; printf "$line"', {
      cwd: "/home/user/exec-cwd",
      env: { MC_EXEC_FLAG: "typed-env" },
      stdin: "typed-stdin\n",
    });
    if (
      execOpts.exitCode !== 0 ||
      execOpts.stdout !== "/home/user/exec-cwd\ntyped-env\ntyped-stdin"
    ) {
      throw new Error(
        `vm.exec options mismatch: exit=${execOpts.exitCode} stdout=${JSON.stringify(execOpts.stdout)} stderr=${JSON.stringify(execOpts.stderr)}`,
      );
    }
    await vm.fs.write("/tmp/💡 two", "completion");
    const completionSource = "cat /tmp/💡\\ t";
    const completion = await vm.autocomplete(completionSource);
    const unicodePath = completion.items.find((item) => item.label === "/tmp/💡 two");
    if (
      completion.replaceStart !== 4 ||
      completion.replaceEnd !== completionSource.length ||
      unicodePath?.value !== "/tmp/💡\\ two" ||
      unicodePath.kind !== "file"
    ) {
      throw new Error(
        `vm.autocomplete UTF-16/path mapping mismatch: ${JSON.stringify(completion)}`,
      );
    }
    let splitSurrogateRejected = false;
    try {
      await vm.autocomplete("echo 💡", { cursor: 6 });
    } catch (error) {
      splitSurrogateRejected = error instanceof RangeError;
    }
    if (!splitSurrogateRejected)
      throw new Error("vm.autocomplete accepted a cursor inside a surrogate pair");
    let unsafeSessionRejected = false;
    try {
      vm.session("luau; echo unsafe");
    } catch {
      unsafeSessionRejected = true;
    }
    if (!unsafeSessionRejected) {
      throw new Error("vm.session accepted an agentType with shell metacharacters");
    }
    await vm.fs.write("/tmp/core", "hello");
    if ((await vm.fs.readText("/tmp/core")) !== "hello") {
      throw new Error("vm.fs round-trip mismatch");
    }

    // Activate /svc/tools while its boot catalog is empty, then register a tool at runtime. This proves
    // vm.tool() updates the warm service's live catalog instead of only rewriting the boot catalog tree.
    const before = await vm.exec("tools list");
    if (before.exitCode !== 0 || !before.stdout.includes('"tools":[]')) {
      throw new Error(
        `initial tools catalog mismatch: exit=${before.exitCode} stdout=${before.stdout}`,
      );
    }
    const dynamicTool: ToolDefinition = {
      name: "dynamic greet",
      address: "host.org.main.dynamicGreet",
      description: "Greet dynamically",
      run: (input) => ({ message: `hello ${String(input.name ?? "world")}` }),
    };
    await vm.tool(dynamicTool);
    const after = await vm.exec('tools call host.org.main.dynamicGreet \'{"name":"Ada"}\'');
    if (after.exitCode !== 0 || !after.stdout.includes('"message":"hello Ada"')) {
      throw new Error(
        `runtime tool registration mismatch: exit=${after.exitCode} stdout=${after.stdout}`,
      );
    }

    const liveMountBytes = new TextEncoder().encode("fork-mounted\n");
    const liveMount: Driver = {
      readOnly: true,
      async open(path) {
        if (path === "/value.txt") return liveMountBytes;
        throw Object.assign(new Error(`missing ${path}`), { code: "ENOENT" });
      },
      async stat(path) {
        return path === "/" || path === "." || path === ""
          ? { kind: "dir", size: 0 }
          : { kind: "file", size: liveMountBytes.length };
      },
      async readdir() {
        return [{ name: "value.txt", kind: "file" }];
      },
    };
    await vm.mount("/runtime-owned", liveMount);
    if (vmOptions.tools?.length !== 0 || vmOptions.mounts?.length !== 0) {
      throw new Error("vm.tool()/mount() mutated caller-owned CreateOptions");
    }

    const sibling = await mc.create(vmOptions);
    try {
      const siblingTools = await sibling.exec("tools list");
      let siblingSawMount = true;
      try {
        await sibling.fs.stat("/runtime-owned/value.txt");
      } catch {
        siblingSawMount = false;
      }
      if (!siblingTools.stdout.includes('"tools":[]') || siblingSawMount) {
        throw new Error(
          `VMs created from one options object leaked live attachments: tools=${siblingTools.stdout} mount=${siblingSawMount}`,
        );
      }
    } finally {
      await sibling.close();
    }

    const forked = await vm.fork();
    try {
      const forkedTool = await forked.exec(
        'tools call host.org.main.dynamicGreet \'{"name":"Fork"}\'',
      );
      const forkedMount = await forked.fs.readText("/runtime-owned/value.txt");
      if (
        !forkedTool.stdout.includes('"message":"hello Fork"') ||
        forkedMount !== "fork-mounted\n"
      ) {
        throw new Error(
          `fork did not inherit canonical live attachments: tool=${forkedTool.stdout} mount=${JSON.stringify(forkedMount)}`,
        );
      }
    } finally {
      await forked.close();
    }
    await vm.unmount("/runtime-owned");
    if (vmOptions.mounts?.length !== 0) {
      throw new Error("vm.unmount() mutated caller-owned CreateOptions");
    }
    console.log(
      "phase: fork inherits canonical live tools/mounts without mutating CreateOptions OK",
    );

    // #1 + restore attachment contract: the warm catalog snapshots WITH the VM, but JS host-call
    // closures do not. Strict restore refuses to return a VM that advertises a host-call catalog entry
    // without the matching host handler; detached restore is explicit inspection mode; strict restore
    // with the same definition reattaches the handler and the tool is callable.
    console.log("phase: restore preserves catalog and validates host attachments");
    const snap = await vm.snapshot();
    let threwMissingAttachment = false;
    try {
      await mc.restore(snap, { kernel, image, deterministic: true });
    } catch (e) {
      threwMissingAttachment = /host attachments|dynamic greet|detached/i.test(String(e));
    }
    if (!threwMissingAttachment) {
      throw new Error("strict restore must reject a host-call catalog entry without its handler");
    }

    const detached = await mc.restore(snap, {
      kernel,
      image,
      deterministic: true,
      restoreAttachments: "detached",
    });
    try {
      const detachedList = await detached.exec("tools list");
      if (
        detachedList.exitCode !== 0 ||
        !detachedList.stdout.includes("host.org.main.dynamicGreet")
      ) {
        throw new Error(
          `detached restore clobbered the warm catalog (dynamicGreet missing): exit=${detachedList.exitCode} stdout=${detachedList.stdout}`,
        );
      }
    } finally {
      await detached.close();
    }

    const restored = await mc.restore(snap, {
      runtime: LOCAL_RUNTIME,
      kernel,
      image,
      deterministic: true,
      tools: [dynamicTool],
    });
    try {
      const restoredCall = await restored.exec(
        'tools call host.org.main.dynamicGreet \'{"name":"Restore"}\'',
      );
      if (
        restoredCall.exitCode !== 0 ||
        !restoredCall.stdout.includes('"message":"hello Restore"')
      ) {
        throw new Error(
          `strict restore did not reattach dynamicGreet: exit=${restoredCall.exitCode} stdout=${restoredCall.stdout}`,
        );
      }
    } finally {
      await restored.close();
    }
  } finally {
    await vm.close();
  }

  // Incremental snapshots are self-describing deltas over one content-addressed full baseline.
  // The SDK owns that baseline lifecycle: create captures it, snapshot stores it by digest, and
  // restore resolves it without requiring callers to pass a second byte array manually.
  {
    const store = new MemoryContentStore();
    const source = await mc.create({
      runtime: LOCAL_RUNTIME,
      kernel,
      image,
      store,
      deterministic: true,
    });
    let delta: Uint8Array;
    let full: Uint8Array;
    try {
      await source.fs.write("/tmp/incremental-sdk", "survives");
      delta = await source.snapshot({ mode: "incremental" });
      full = await source.snapshot();
      if (delta.length >= full.length) {
        throw new Error(
          `incremental snapshot was not smaller than full: delta=${delta.length} full=${full.length}`,
        );
      }
    } finally {
      await source.close();
    }

    const restored = await mc.restore(delta!, {
      runtime: LOCAL_RUNTIME,
      kernel,
      store,
      deterministic: true,
    });
    try {
      if ((await restored.fs.readText("/tmp/incremental-sdk")) !== "survives") {
        throw new Error("SDK incremental restore did not reconstruct the full memory image");
      }
    } finally {
      await restored.close();
    }
    console.log("phase: SDK incremental snapshot resolves its content-addressed full baseline OK");
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
      'tools call github.org.main.issues-list \'{"path":{"owner":"octo","repo":"hello"},"query":{"state":"open"}}\'',
    );
    if (called.exitCode !== 0 || !called.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(
        `generated GitHub tool call mismatch: exit=${called.exitCode} stdout=${called.stdout}`,
      );
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
      throw new Error(
        `connection credential was not spliced at host egress: ${JSON.stringify(request.headers)}`,
      );
    }

    clearRequests(server.requests);
    console.log("phase: destructive allow");
    approvalMode = "allow";
    const allowed = await githubVm.exec(
      `tools call github.org.main.issues-create '${issueCreateArgs("allow")}'`,
    );
    if (allowed.exitCode !== 0 || !allowed.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(
        `destructive approval allow did not proceed: exit=${allowed.exitCode} stdout=${allowed.stdout}`,
      );
    }
    if (count(defaultPrompts) !== 1)
      throw new Error(`expected one tool approval prompt, saw ${count(defaultPrompts)}`);
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
      throw new Error(
        `destructive allow did not reach upstream exactly once: ${JSON.stringify(allowedRequests)}`,
      );
    }
    if (allowedRequests[0]!.headers.authorization !== "Bearer fixture-token") {
      throw new Error("credential was not spliced after destructive approval");
    }

    clearRequests(server.requests);
    console.log("phase: destructive reject");
    approvalMode = "reject";
    const rejected = await githubVm.exec(
      `tools call github.org.main.issues-create '${issueCreateArgs("reject")}'`,
    );
    if (count(defaultPrompts) !== 2) {
      throw new Error(
        `expected two total approval prompts after rejection, saw ${count(defaultPrompts)}`,
      );
    }
    const rejectedRequests = [...server.requests];
    if (rejectedRequests.length !== 0 || rejected.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(
        `destructive rejection was not fail-closed: stdout=${rejected.stdout} requests=${rejectedRequests.length}`,
      );
    }

    clearRequests(server.requests);
    console.log("phase: non-destructive GET");
    const promptsBeforeGet = count(defaultPrompts);
    const get = await githubVm.exec(
      'tools call github.org.main.issues-list \'{"path":{"owner":"octo","repo":"hello"},"query":{"state":"open"}}\'',
    );
    if (get.exitCode !== 0 || !get.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(`non-destructive GET failed: exit=${get.exitCode} stdout=${get.stdout}`);
    }
    const getRequests = [...server.requests];
    if (getRequests.length !== 1 || getRequests[0]!.method !== "GET") {
      throw new Error(
        `non-destructive GET did not reach upstream once: ${JSON.stringify(getRequests)}`,
      );
    }
    if (count(defaultPrompts) !== promptsBeforeGet) throw new Error("GET raised tool approval");

    clearRequests(server.requests);
    console.log("phase: block policy");
    const blockPrompts: ToolApprovalFact[] = [];
    const blockPolicy: ConnectionPolicyRule[] = [
      { owner: "org", pattern: "github.org.main.*", action: "block" },
    ];
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
      'tools call github.org.main.issues-list \'{"path":{"owner":"octo","repo":"hello"},"query":{"state":"open"}}\'',
    );
    const blockRequests = [...server.requests];
    if (
      blockPrompts.length !== 0 ||
      blockRequests.length !== 0 ||
      blocked.stdout.includes('"marker":"js-host-adapter"')
    ) {
      throw new Error(
        `block policy did not fail closed without prompt: stdout=${blocked.stdout} prompts=${blockPrompts.length} requests=${blockRequests.length}`,
      );
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
    const approved = await approveVm.exec(
      `tools call github.org.main.issues-create '${issueCreateArgs("policy")}'`,
    );
    if (approved.exitCode !== 0 || !approved.stdout.includes('"marker":"js-host-adapter"')) {
      throw new Error(
        `approve policy did not send destructive request: exit=${approved.exitCode} stdout=${approved.stdout}`,
      );
    }
    const approveRequests = [...server.requests];
    if (approveRequests.length !== 1 || approveRequests[0]!.method !== "POST") {
      throw new Error(
        `approve policy did not reach upstream once: ${JSON.stringify(approveRequests)}`,
      );
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
      throw new Error(
        `direct/raw bypass proof failed: exit=${bypass.exitCode} stdout=${bypass.stdout} stderr=${bypass.stderr}`,
      );
    }
    const bypassUrls = bypassPrompts.map((p) => `${p.method} ${p.url}`).sort();
    if (
      bypassPrompts.length !== 2 ||
      !bypassUrls.includes(`DELETE ${server.origin}/direct`) ||
      !bypassUrls.includes(`DELETE ${server.origin}/raw`)
    ) {
      throw new Error(
        `direct/raw requests were not gated at host egress: ${JSON.stringify(bypassPrompts)}`,
      );
    }
    const bypassRequests = [...server.requests];
    const upstreamBypass = bypassRequests.map((r) => `${r.method} ${r.url}`).sort();
    if (
      bypassRequests.length !== 2 ||
      !upstreamBypass.includes("DELETE /direct") ||
      !upstreamBypass.includes("DELETE /raw") ||
      bypassRequests.some((r) => r.headers.authorization !== "Bearer fixture-token")
    ) {
      throw new Error(
        `direct/raw requests did not reach upstream with spliced credentials: ${JSON.stringify(bypassRequests)}`,
      );
    }

    // ── Live discovery: GraphQL introspection + remote-MCP initialize→tools/list handshake. The host
    //    runs discovery as authenticated egress (credential spliced host-side), then compiles the result.
    console.log("phase: live discovery (graphql + mcp)");
    // Cross-host parity fixture (P3): graphql.introspection.json is the SAME document the Rust host's
    // `discovers_graphql_catalog_via_authenticated_introspection` serves. Both hosts run the shared
    // catalog-compiler.wasm over it, so they MUST yield the identical golden tool set
    // (gql.org.main.query.viewer + gql.org.main.mutation.updateName) — a divergence here is a transport bug.
    const introspection = readFileSync(
      runfile(process.env.MC_GRAPHQL_FIXTURE, "MC_GRAPHQL_FIXTURE"),
      "utf8",
    );
    const mcpToolsList = JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      result: {
        tools: [
          {
            name: "search",
            description: "search docs",
            inputSchema: { type: "object", properties: {} },
          },
        ],
      },
    });
    const discoSeen: { auth: string | null; method?: string }[] = [];
    const disco = createServer((req, res) => {
      let body = "";
      req.on("data", (c) => (body += c));
      req.on("end", () => {
        const auth = (req.headers.authorization as string | undefined) ?? null;
        if ((req.url ?? "").includes("/graphql")) {
          discoSeen.push({ auth });
          res.writeHead(200, { "content-type": "application/json" });
          res.end(introspection);
          return;
        }
        const msg = JSON.parse(body || "{}") as { method?: string; id?: number };
        discoSeen.push({ auth, method: msg.method });
        if (msg.method === "initialize") {
          res.writeHead(200, { "content-type": "application/json", "mcp-session-id": "s1" });
          res.end(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result: {} }));
        } else if (msg.method === "notifications/initialized") {
          res.writeHead(202).end();
        } else if (msg.method === "tools/list") {
          // Multi-event SSE: a notification frame BEFORE the response frame, so the host must select the
          // JSON-RPC response (carrying `result`) and not concatenate every `data:` line (C2).
          const notification = JSON.stringify({
            jsonrpc: "2.0",
            method: "notifications/message",
            params: { level: "info" },
          });
          res.writeHead(200, { "content-type": "text/event-stream" });
          res.end(
            `event: message\ndata: ${notification}\n\nevent: message\ndata: ${mcpToolsList}\n\n`,
          );
        } else {
          res.writeHead(400).end();
        }
      });
    });
    await new Promise<void>((resolve) => disco.listen(0, "127.0.0.1", () => resolve()));
    const discoOrigin = `http://127.0.0.1:${(disco.address() as { port: number }).port}`;
    // #4: a NON-canonical form of the same origin (uppercase scheme). Discovery must authorize by the
    // normalized origin (the splice's `originAllowed` primitive), not a raw string prefix — the old
    // `startsWith` check rejected this even though it is the identical host, diverging from the splice
    // (which normalizes) and from the wasmtime host (whose origins come back normalized from the registry).
    const discoOriginNonCanonical = discoOrigin.replace(/^http:/, "HTTP:");
    try {
      const gqlVm = await mc.create({
        kernel,
        image,
        deterministic: true,
        net: true,
        permissions: { network: "allow" },
        connections: [
          {
            ref: "gql.org.main",
            auth: { kind: "bearer", token: "gql-tok" },
            origins: [discoOriginNonCanonical],
            spec: { format: "graphql", url: `${discoOrigin}/graphql` },
          },
        ],
      });
      created.push(gqlVm);
      const gqlList = await gqlVm.exec("tools list");
      const gqlGolden = ["gql.org.main.query.viewer", "gql.org.main.mutation.updateName"];
      if (gqlList.exitCode !== 0 || !gqlGolden.every((t) => gqlList.stdout.includes(t))) {
        throw new Error(
          `graphql discovery did not yield the parity golden ${JSON.stringify(gqlGolden)}: ${gqlList.stdout}`,
        );
      }

      const mcpVm = await mc.create({
        kernel,
        image,
        deterministic: true,
        net: true,
        permissions: { network: "allow" },
        connections: [
          {
            ref: "mcp.org.main",
            auth: { kind: "bearer", token: "mcp-tok" },
            origins: [discoOrigin],
            spec: { format: "mcp-remote", url: `${discoOrigin}/mcp` },
          },
        ],
      });
      created.push(mcpVm);
      const mcpList = await mcpVm.exec("tools list");
      if (mcpList.exitCode !== 0 || !mcpList.stdout.includes("mcp.org.main.search")) {
        throw new Error(`mcp discovery produced no tools: ${mcpList.stdout}`);
      }
      // The credential was spliced host-side on the discovery calls, and the MCP handshake ran in order.
      if (
        !discoSeen.some((s) => s.auth === "Bearer gql-tok") ||
        !discoSeen.some((s) => s.auth === "Bearer mcp-tok")
      ) {
        throw new Error(`discovery did not splice the credential: ${JSON.stringify(discoSeen)}`);
      }
      if (
        !discoSeen.some((s) => s.method === "initialize") ||
        !discoSeen.some((s) => s.method === "tools/list")
      ) {
        throw new Error(`mcp handshake incomplete: ${JSON.stringify(discoSeen)}`);
      }
    } finally {
      await new Promise<void>((resolve) => disco.close(() => resolve()));
    }

    // ── Origins-only public tool (auth:none): reaches an allowed origin with NO credential, the
    //    connection marker stripped host-side, origin-gated by the splice. ──
    console.log("phase: origins-only public tool (auth:none)");
    clearRequests(server.requests);
    const publicOpenapi = JSON.stringify({
      openapi: "3.0.0",
      info: { title: "public", version: "1" },
      servers: [{ url: server.origin }],
      paths: {
        "/ping": { get: { operationId: "ping", responses: { "200": { description: "ok" } } } },
      },
    });
    const publicVm = await mc.create({
      kernel,
      image,
      deterministic: true,
      net: true,
      permissions: { network: "allow" },
      connections: [
        {
          ref: "public.org.main",
          auth: { kind: "none" },
          origins: [server.origin],
          spec: { bytes: new TextEncoder().encode(publicOpenapi), format: "openapi" },
        },
      ],
    });
    created.push(publicVm);
    const pinged = await publicVm.exec("tools call public.org.main.ping '{}'");
    if (pinged.exitCode !== 0) {
      throw new Error(
        `origins-only public tool call failed: exit=${pinged.exitCode} stdout=${pinged.stdout}`,
      );
    }
    const publicReqs = [...server.requests];
    if (publicReqs.length !== 1 || publicReqs[0]!.url !== "/ping") {
      throw new Error(`public tool did not reach upstream once: ${JSON.stringify(publicReqs)}`);
    }
    if (publicReqs[0]!.headers.authorization !== undefined) {
      throw new Error(
        `auth:none must carry no credential, got ${publicReqs[0]!.headers.authorization}`,
      );
    }
    if (publicReqs[0]!.headers["x-mc-connection"] !== undefined) {
      throw new Error(
        `connection marker must be stripped host-side, got ${publicReqs[0]!.headers["x-mc-connection"]}`,
      );
    }

    // S1: auth:none with NO origins is rejected at create — a connection marker can't be an unrestricted
    // egress channel (previously this fell open and bypassed the network allowlist).
    let rejectedEmptyOrigins = false;
    try {
      const v = await mc.create({
        kernel,
        image,
        deterministic: true,
        net: true,
        permissions: { network: "allow" },
        connections: [
          {
            ref: "empty.org.main",
            auth: { kind: "none" },
            origins: [],
            spec: { bytes: new TextEncoder().encode(publicOpenapi), format: "openapi" },
          },
        ],
      });
      created.push(v);
    } catch (e) {
      rejectedEmptyOrigins = /origin/i.test(String(e));
    }
    if (!rejectedEmptyOrigins) {
      throw new Error("auth:none + empty origins must be rejected at create (S1)");
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
