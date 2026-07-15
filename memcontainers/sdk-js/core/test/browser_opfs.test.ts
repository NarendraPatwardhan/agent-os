import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { llb, mc, MemoryContentStore } from "../src/index.js";

function runfile(rel: string | undefined, envVar: string): string {
  if (!rel) throw new Error(`${envVar} is not set (this test must run under \`bazel test\`)`);
  const rf = process.env.RUNFILES_DIR;
  if (!rf) throw new Error("RUNFILES_DIR is not set (this test must run under bazel)");
  return join(rf, rel);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function sha256Digest(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>));
  let hex = "";
  for (const byte of digest) hex += byte.toString(16).padStart(2, "0");
  return `sha256:${hex}`;
}

function contentType(path: string): string {
  if (path.endsWith(".html")) return "text/html";
  if (path.endsWith(".js")) return "text/javascript";
  if (path.endsWith(".json")) return "application/json";
  if (path.endsWith(".wasm")) return "application/wasm";
  return "application/octet-stream";
}

async function staticServer(routes: Map<string, { bytes: Uint8Array; type: string }>): Promise<{
  origin: string;
  requests: string[];
  close(): Promise<void>;
}> {
  const requests: string[] = [];
  const server = createServer((req, res) => {
    requests.push(req.url ?? "");
    const route = routes.get(req.url ?? "");
    if (route) {
      res.writeHead(200, {
        "content-type": route.type,
        "cache-control": "no-store",
      });
      res.end(route.bytes);
      return;
    }

    void (async () => {
      const url = req.url ?? "";
      if (!url.startsWith("/core/")) {
        res.writeHead(404, { "content-type": "text/plain" });
        res.end("not found");
        return;
      }
      const rel = decodeURIComponent(url.slice("/core/".length));
      if (rel.startsWith("/") || rel.split("/").includes("..")) {
        res.writeHead(403, { "content-type": "text/plain" });
        res.end("forbidden");
        return;
      }
      try {
        const bytes = await readFile(join(runfilesRoot(), "memcontainers/sdk-js/core", rel));
        res.writeHead(200, {
          "content-type": contentType(rel),
          "cache-control": "no-store",
        });
        res.end(bytes);
      } catch {
        res.writeHead(404, { "content-type": "text/plain" });
        res.end("not found");
      }
    })().catch((err) => {
      res.writeHead(500, { "content-type": "text/plain" });
      res.end(err instanceof Error ? err.message : String(err));
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("browser test server did not bind a TCP port");
  return {
    origin: `http://127.0.0.1:${address.port}`,
    requests,
    close: () =>
      new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      }),
  };
}

function browserHtml(): Uint8Array {
  const importMap = {
    imports: {
      "@mc/host": "/core/node_modules/@mc/host/src/index.js",
      "@mc/contracts/constants": "/core/node_modules/@mc/contracts/gen/constants.gen.js",
      "@mc/contracts/ctl": "/core/node_modules/@mc/contracts/gen/ctl.gen.js",
      "@mc/contracts/env": "/core/node_modules/@mc/contracts/gen/env.gen.js",
      "@mc/contracts/llb": "/core/node_modules/@mc/contracts/gen/llb.gen.js",
      "@mc/contracts/sidecar": "/core/node_modules/@mc/contracts/gen/sidecar.gen.js",
      "@mc/contracts/snapshot": "/core/node_modules/@mc/contracts/gen/snapshot.gen.js",
      "@mc/contracts/wire": "/core/node_modules/@mc/contracts/gen/wire.gen.js",
      zod: "/core/node_modules/zod/index.js",
    },
  };
  return new TextEncoder().encode(`<!doctype html>
<meta charset="utf-8">
<script type="importmap">${JSON.stringify(importMap)}</script>
<script type="module" src="/entry.js"></script>`);
}

function browserEntry(): Uint8Array {
  return new TextEncoder().encode(`
import { llb, mc, OpfsContentStore } from "/core/src/index.js";

function mark(step) {
  globalThis.__MC_BROWSER_PROGRESS__ = step;
  console.log("browser-opfs:", step);
}

async function bytes(path) {
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(path + " failed: " + response.status);
  return new Uint8Array(await response.arrayBuffer());
}

try {
  mark("fetch artifacts");
  const kernel = await bytes("/kernel.wasm");
  const base = await bytes("/base.tar");
  const definitionBytes = await bytes("/definition.bin");
  const payload = await bytes("/payload.bin");
  mark("open opfs store");
  const store = await OpfsContentStore.open("browser-opfs-build-test");
  const baseDigest = await store.put(base);
  await store.putManifest("browser-base", {
    schema: 1,
    layers: [{ digest: baseDigest, size: base.length }],
    config: {},
  });
  await store.putBlob(payload);
  mark("solve definition");
  const definition = llb.decodeDefinition(definitionBytes);
  const manifest = await llb.commit(definition).asImage({ store, kernel });
  mark("boot solved image");
  const vm = await mc.create({ runtime: "browser", kernel, image: manifest, store, deterministic: true });
  try {
    const text = await vm.fs.readText("/home/user/browser-opfs.txt");
    globalThis.__MC_BROWSER_RESULT__ = {
      ok: true,
      opfs: Boolean(navigator.storage?.getDirectory),
      rootDigest: manifest.build?.rootDigest ?? "",
      text,
    };
    mark("done");
  } finally {
    await vm.close();
  }
} catch (error) {
  globalThis.__MC_BROWSER_RESULT__ = {
    ok: false,
    error: error instanceof Error ? error.message : String(error),
    stack: error instanceof Error ? error.stack : undefined,
  };
}
`);
}

function runfilesRoot(): string {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set");
  return join(root, "_main");
}

async function chromiumPort(userDataDir: string, child: ChildProcessWithoutNullStreams): Promise<number> {
  const deadline = Date.now() + 15_000;
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += String(chunk);
  });
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`chromium exited early (${child.exitCode}): ${stderr}`);
    try {
      const raw = await readFile(join(userDataDir, "DevToolsActivePort"), "utf8");
      const port = Number(raw.split(/\r?\n/, 1)[0]);
      if (Number.isInteger(port) && port > 0) return port;
    } catch {
      // File appears once Chromium has bound the debugging socket.
    }
    await sleep(50);
  }
  throw new Error(`timed out waiting for Chromium DevToolsActivePort: ${stderr}`);
}

async function launchChromium(): Promise<{
  port: number;
  close(): Promise<void>;
}> {
  const chromium = process.env.CHROMIUM_BIN ?? "/usr/bin/chromium";
  const userDataDir = await mkdtemp(join(tmpdir(), "mc-chromium-"));
  const child = spawn(chromium, [
    "--headless=new",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--no-sandbox",
    "--remote-debugging-port=0",
    `--user-data-dir=${userDataDir}`,
    "about:blank",
  ]);
  const port = await chromiumPort(userDataDir, child);
  return {
    port,
    close: async () => {
      child.kill("SIGTERM");
      await new Promise<void>((resolve) => {
        child.once("exit", () => resolve());
        setTimeout(() => {
          if (child.exitCode === null) child.kill("SIGKILL");
          resolve();
        }, 1_000);
      });
      await rm(userDataDir, { recursive: true, force: true });
    },
  };
}

class Cdp {
  private seq = 0;
  private readonly pending = new Map<number, { resolve: (value: unknown) => void; reject: (reason: unknown) => void }>();
  readonly events: string[] = [];

  private constructor(private readonly ws: WebSocket) {
    ws.addEventListener("message", (event: MessageEvent) => {
      const msg = JSON.parse(String(event.data)) as {
        id?: number;
        method?: string;
        params?: unknown;
        error?: { message?: string };
        result?: unknown;
      };
      if (msg.id !== undefined) {
        const pending = this.pending.get(msg.id);
        if (!pending) return;
        this.pending.delete(msg.id);
        if (msg.error) pending.reject(new Error(msg.error.message ?? "CDP command failed"));
        else pending.resolve(msg.result);
        return;
      }
      if (
        msg.method === "Runtime.consoleAPICalled" ||
        msg.method === "Runtime.exceptionThrown" ||
        msg.method === "Log.entryAdded" ||
        msg.method === "Network.loadingFailed" ||
        msg.method === "Network.responseReceived"
      ) {
        this.events.push(JSON.stringify(msg.params));
      }
    });
  }

  static async connect(url: string): Promise<Cdp> {
    const ws = new WebSocket(url);
    await new Promise<void>((resolve, reject) => {
      ws.addEventListener("open", () => resolve(), { once: true });
      ws.addEventListener("error", () => reject(new Error(`CDP websocket failed: ${url}`)), { once: true });
    });
    return new Cdp(ws);
  }

  send<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = ++this.seq;
    const promise = new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
    });
    this.ws.send(JSON.stringify({ id, method, params }));
    return promise;
  }

  close(): void {
    this.ws.close();
  }
}

async function pageWebSocket(port: number): Promise<string> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`);
    if (response.ok) {
      const targets = (await response.json()) as Array<{ type?: string; webSocketDebuggerUrl?: string }>;
      const page = targets.find((target) => target.type === "page" && target.webSocketDebuggerUrl);
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    }
    await sleep(50);
  }
  throw new Error("timed out waiting for Chromium page target");
}

async function browserResult(cdp: Cdp): Promise<Record<string, unknown>> {
  const started = Date.now();
  const deadline = Date.now() + 180_000;
  let lastDiagnostic = "";
  while (Date.now() < deadline) {
    const evaluated = await cdp.send<{
      result?: { value?: unknown };
      exceptionDetails?: unknown;
    }>("Runtime.evaluate", {
      expression: "globalThis.__MC_BROWSER_RESULT__ ?? null",
      returnByValue: true,
      awaitPromise: true,
    });
    if (evaluated.exceptionDetails) {
      throw new Error(`browser evaluation failed: ${JSON.stringify(evaluated.exceptionDetails)}`);
    }
    const value = evaluated.result?.value;
    if (value && typeof value === "object") return value as Record<string, unknown>;
    const diagnostic = await cdp.send<{
      result?: { value?: unknown };
    }>("Runtime.evaluate", {
      expression: "({ href: location.href, readyState: document.readyState, progress: globalThis.__MC_BROWSER_PROGRESS__ ?? null })",
      returnByValue: true,
    });
    const diagnosticValue = diagnostic.result?.value as { progress?: unknown } | undefined;
    lastDiagnostic = JSON.stringify(diagnosticValue ?? null);
    if ((diagnosticValue?.progress ?? null) === null && Date.now() - started > 15_000) {
      throw new Error(`browser entry module did not start; last=${lastDiagnostic}; events=${cdp.events.join("\n")}`);
    }
    await sleep(100);
  }
  throw new Error(`timed out waiting for browser result; last=${lastDiagnostic}; events=${cdp.events.join("\n")}`);
}

async function main(): Promise<void> {
  const kernel = new Uint8Array(await readFile(runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM")));
  const base = new Uint8Array(await readFile(runfile(process.env.MC_BASE_IMAGE, "MC_BASE_IMAGE")));
  const store = new MemoryContentStore();
  const baseDigest = await store.put(base);
  await store.putManifest("browser-base", {
    schema: 1,
    layers: [{ digest: baseDigest, size: base.length }],
    config: {},
  });

  const state = llb.write(llb.source("browser-base"), "/home/user/browser-opfs.txt", "browser-opfs");
  const definition = await llb.toDefinition(state, { store });
  const definitionBytes = llb.encodeDefinition(definition);
  const blobDigest = definition.ops.find((op) => op.data_digest)?.data_digest;
  if (!blobDigest) throw new Error(`browser Definition did not externalize write bytes: ${JSON.stringify(definition)}`);
  const payload = await store.blob(blobDigest);
  if ((await sha256Digest(payload)) !== blobDigest) throw new Error(`payload digest mismatch for ${blobDigest}`);

  const expected = await llb.commit(llb.decodeDefinition(definitionBytes)).asImage({ store, kernel });
  const expectedRootDigest = expected.build?.rootDigest;
  if (!expectedRootDigest) throw new Error(`Bun solve did not return build provenance: ${JSON.stringify(expected)}`);

  const server = await staticServer(
    new Map([
      ["/", { bytes: browserHtml(), type: "text/html" }],
      ["/entry.js", { bytes: browserEntry(), type: "text/javascript" }],
      ["/kernel.wasm", { bytes: kernel, type: "application/wasm" }],
      ["/base.tar", { bytes: base, type: "application/octet-stream" }],
      ["/definition.bin", { bytes: definitionBytes, type: "application/octet-stream" }],
      ["/payload.bin", { bytes: payload, type: "application/octet-stream" }],
    ]),
  );

  let chrome: Awaited<ReturnType<typeof launchChromium>> | null = null;
  let cdp: Cdp | null = null;
  try {
    chrome = await launchChromium();
    cdp = await Cdp.connect(await pageWebSocket(chrome.port));
    await cdp.send("Runtime.enable");
    await cdp.send("Page.enable");
    await cdp.send("Log.enable");
    await cdp.send("Network.enable");
    await cdp.send("Page.navigate", { url: server.origin + "/" });
    let result: Record<string, unknown>;
    try {
      result = await browserResult(cdp);
    } catch (error) {
      throw new Error(
        `${error instanceof Error ? error.message : String(error)}; requests=${JSON.stringify(server.requests)}`,
      );
    }
    if (result.ok !== true) {
      throw new Error(`browser OPFS solve failed: ${JSON.stringify(result)} events=${cdp.events.join("\n")}`);
    }
    if (result.opfs !== true) throw new Error(`browser test did not use OPFS: ${JSON.stringify(result)}`);
    if (result.rootDigest !== expectedRootDigest) {
      throw new Error(
        `browser OPFS root digest diverged: browser=${JSON.stringify(result.rootDigest)} local=${expectedRootDigest}`,
      );
    }
    if (result.text !== "browser-opfs") {
      throw new Error(`browser OPFS image bytes mismatch: ${JSON.stringify(result)}`);
    }
    console.log("phase: browser OPFS solves the same LLB Definition root digest OK");
  } finally {
    cdp?.close();
    if (chrome) await chrome.close();
    await server.close();
  }
}

main().catch((err) => {
  console.error("BROWSER OPFS FAIL:", err instanceof Error ? err.stack || err.message : err);
  process.exit(1);
});
