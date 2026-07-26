import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseArgs, statistics, type BenchmarkResult } from "../shared/result.js";
import { validate } from "../tools/validate.js";

const ISOLATION_HEADERS = {
  "cross-origin-opener-policy": "same-origin",
  "cross-origin-embedder-policy": "require-corp",
  "cross-origin-resource-policy": "same-origin",
};

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function runfilesRoot(): string {
  const root = process.env.RUNFILES_DIR;
  if (!root) throw new Error("RUNFILES_DIR is not set; run through Bazel");
  return join(root, "_main");
}

function runfile(rel: string | undefined, env: string): string {
  if (!rel) throw new Error(`${env} is not set`);
  return join(process.env.RUNFILES_DIR!, rel);
}

function contentType(path: string): string {
  if (path.endsWith(".html")) return "text/html";
  if (path.endsWith(".js")) return "text/javascript";
  if (path.endsWith(".wasm")) return "application/wasm";
  if (path.endsWith(".json")) return "application/json";
  return "application/octet-stream";
}

function html(): string {
  const importMap = {
    imports: {
      "@mc/host": "/core/node_modules/@mc/host/src/index.js",
      "@mc/contracts/constants": "/core/node_modules/@mc/contracts/gen/constants.gen.js",
      "@mc/contracts/ctl": "/core/node_modules/@mc/contracts/gen/ctl.gen.js",
      "@mc/contracts/env": "/core/node_modules/@mc/contracts/gen/env.gen.js",
      "@mc/contracts/llb": "/core/node_modules/@mc/contracts/gen/llb.gen.js",
      "@mc/contracts/browser": "/core/node_modules/@mc/contracts/gen/browser.gen.js",
      "@mc/contracts/sidecar": "/core/node_modules/@mc/contracts/gen/sidecar.gen.js",
      "@mc/contracts/snapshot": "/core/node_modules/@mc/contracts/gen/snapshot.gen.js",
      "@mc/contracts/wire": "/core/node_modules/@mc/contracts/gen/wire.gen.js",
      zod: "/core/node_modules/zod/index.js",
    },
  };
  return `<!doctype html><meta charset="utf-8"><script type="importmap">${JSON.stringify(
    importMap,
  )}</script><script type="module" src="/bench/browser/page.js"></script>`;
}

async function server(): Promise<{ origin: string; close(): Promise<void> }> {
  const artifactPaths: Record<string, string> = {
    "/artifacts/kernel.wasm": runfile(process.env.MC_KERNEL_WASM, "MC_KERNEL_WASM"),
    "/artifacts/minimal.tar": runfile(process.env.MC_MINIMAL_IMAGE, "MC_MINIMAL_IMAGE"),
    "/artifacts/posix.tar": runfile(process.env.MC_POSIX_IMAGE, "MC_POSIX_IMAGE"),
    "/artifacts/loom.tar": runfile(process.env.MC_LOOM_IMAGE, "MC_LOOM_IMAGE"),
    "/artifacts/atlas.tar": runfile(process.env.MC_ATLAS_IMAGE, "MC_ATLAS_IMAGE"),
    "/artifacts/paper.tar": runfile(process.env.MC_PAPER_IMAGE, "MC_PAPER_IMAGE"),
  };
  const instance = createServer((req, res) => {
    void (async () => {
      const url = new URL(req.url ?? "/", "http://localhost");
      if (url.pathname === "/") {
        res.writeHead(200, {
          ...ISOLATION_HEADERS,
          "content-type": "text/html",
          "cache-control": "no-store",
        });
        res.end(html());
        return;
      }
      let path = artifactPaths[url.pathname];
      if (!path && url.pathname.startsWith("/core/"))
        path = join(runfilesRoot(), "memcontainers/sdk-js/core", url.pathname.slice(6));
      if (!path && url.pathname.startsWith("/memcontainers/"))
        path = join(runfilesRoot(), url.pathname.slice(1));
      if (!path && url.pathname.startsWith("/bench/"))
        path = join(runfilesRoot(), "benchmarks", url.pathname.slice(7));
      if (!path || url.pathname.split("/").includes("..")) {
        res.writeHead(404, ISOLATION_HEADERS);
        res.end("not found");
        return;
      }
      await stat(path);
      res.writeHead(200, {
        ...ISOLATION_HEADERS,
        "content-type": contentType(path),
        "cache-control": "no-store",
      });
      res.end(await readFile(path));
    })().catch((error) => {
      res.writeHead(500, { ...ISOLATION_HEADERS, "content-type": "text/plain" });
      res.end(error instanceof Error ? error.message : String(error));
    });
  });
  await new Promise<void>((resolve, reject) => {
    instance.once("error", reject);
    instance.listen(0, "127.0.0.1", resolve);
  });
  const address = instance.address();
  if (!address || typeof address === "string") throw new Error("benchmark server did not bind");
  return {
    origin: `http://127.0.0.1:${address.port}`,
    close: () =>
      new Promise((resolve, reject) => instance.close((e) => (e ? reject(e) : resolve()))),
  };
}

async function chromePort(
  directory: string,
  child: ChildProcessWithoutNullStreams,
): Promise<number> {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`Chromium exited early with ${child.exitCode}`);
    try {
      const raw = await readFile(join(directory, "DevToolsActivePort"), "utf8");
      const port = Number(raw.split(/\r?\n/, 1)[0]);
      if (Number.isInteger(port) && port > 0) return port;
    } catch {}
    await sleep(50);
  }
  throw new Error("timed out waiting for Chromium");
}

async function launch(): Promise<{
  port: number;
  pid: number;
  startupMs: number;
  startupProcessTreeRssBytes: number;
  close(): Promise<void>;
}> {
  const started = performance.now();
  const directory = await mkdtemp(join(tmpdir(), "agentos-benchmark-chrome-"));
  const child = spawn(process.env.CHROMIUM_BIN ?? "/usr/bin/chromium", [
    "--headless=new",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--enable-precise-memory-info",
    "--no-sandbox",
    "--remote-debugging-port=0",
    `--user-data-dir=${directory}`,
    "about:blank",
  ]);
  const port = await chromePort(directory, child);
  if (child.pid === undefined) throw new Error("Chromium did not expose its process id");
  return {
    port,
    pid: child.pid,
    startupMs: performance.now() - started,
    startupProcessTreeRssBytes: await processTreeRss(child.pid),
    close: async () => {
      const exited = new Promise<void>((resolve) => child.once("exit", () => resolve()));
      if (child.exitCode === null) child.kill("SIGTERM");
      await Promise.race([exited, sleep(1_000)]);
      if (child.exitCode === null) {
        child.kill("SIGKILL");
        await Promise.race([exited, sleep(1_000)]);
      }
      for (let attempt = 0; attempt < 5; attempt++) {
        try {
          await rm(directory, { recursive: true, force: true });
          break;
        } catch (error) {
          if (
            attempt === 4 ||
            !(error instanceof Error && "code" in error && error.code === "ENOTEMPTY")
          )
            throw error;
          await sleep(100);
        }
      }
    },
  };
}

async function processTreeRss(root: number): Promise<number> {
  const processes = new Map<number, { parent: number; rss: number }>();
  for (const entry of await readdir("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const status = await readFile(`/proc/${entry}/status`, "utf8");
      const parent = Number(/^PPid:\s+(\d+)$/m.exec(status)?.[1]);
      const rss = Number(/^VmRSS:\s+(\d+)\s+kB$/m.exec(status)?.[1]) * 1024;
      if (Number.isFinite(parent) && Number.isFinite(rss))
        processes.set(Number(entry), { parent, rss });
    } catch {}
  }
  const descendants = new Set([root]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const [pid, process] of processes) {
      if (!descendants.has(pid) && descendants.has(process.parent)) {
        descendants.add(pid);
        changed = true;
      }
    }
  }
  return [...descendants].reduce((sum, pid) => sum + (processes.get(pid)?.rss ?? 0), 0);
}

class Cdp {
  private id = 0;
  private readonly pending = new Map<
    number,
    { resolve(value: unknown): void; reject(error: Error): void }
  >();
  private constructor(private readonly socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data)) as {
        id?: number;
        result?: unknown;
        error?: { message?: string };
      };
      if (message.id === undefined) return;
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message ?? "CDP error"));
      else pending.resolve(message.result);
    });
  }
  static async connect(url: string): Promise<Cdp> {
    const socket = new WebSocket(url);
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), { once: true });
      socket.addEventListener("error", () => reject(new Error("CDP websocket failed")), {
        once: true,
      });
    });
    return new Cdp(socket);
  }
  send<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    const id = ++this.id;
    const result = new Promise<T>((resolve, reject) =>
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject }),
    );
    this.socket.send(JSON.stringify({ id, method, params }));
    return result;
  }
  close(): void {
    this.socket.close();
  }
}

async function pageSocket(port: number): Promise<string> {
  for (let i = 0; i < 200; i++) {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`);
    const targets = (await response.json()) as { type?: string; webSocketDebuggerUrl?: string }[];
    const page = targets.find((item) => item.type === "page" && item.webSocketDebuggerUrl);
    if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    await sleep(50);
  }
  throw new Error("no Chromium page target");
}

async function waitResult(cdp: Cdp): Promise<BenchmarkResult> {
  const deadline = Date.now() + 15 * 60_000;
  while (Date.now() < deadline) {
    const evaluation = await cdp.send<{ result?: { value?: unknown }; exceptionDetails?: unknown }>(
      "Runtime.evaluate",
      {
        expression: "globalThis.__AGENTOS_BENCHMARK_RESULT__ ?? null",
        returnByValue: true,
        awaitPromise: true,
      },
    );
    const value = evaluation.result?.value as Record<string, unknown> | undefined;
    if (value?.error) throw new Error(`${value.error}\n${value.stack ?? ""}`);
    if (value) {
      validate(value);
      return value;
    }
    await sleep(100);
  }
  throw new Error("browser benchmark timed out");
}

async function waitBoolean(cdp: Cdp, expression: string): Promise<void> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    const evaluation = await cdp.send<{ result?: { value?: unknown } }>("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (evaluation.result?.value === true) return;
    await sleep(50);
  }
  throw new Error(`browser condition timed out: ${expression}`);
}

async function memoryProbe(
  chrome: { port: number; pid: number; startupProcessTreeRssBytes: number },
  origin: string,
): Promise<number> {
  const cdp = await Cdp.connect(await pageSocket(chrome.port));
  try {
    await cdp.send("Runtime.enable");
    await cdp.send("Page.enable");
    await cdp.send("Page.navigate", { url: `${origin}/?mode=memory` });
    await waitBoolean(cdp, "globalThis.__AGENTOS_MEMORY_READY__ === true");
    const memoryBytes = Math.max(
      0,
      (await processTreeRss(chrome.pid)) - chrome.startupProcessTreeRssBytes,
    );
    await cdp.send("Runtime.evaluate", {
      expression: "globalThis.__AGENTOS_MEMORY_CLOSE__?.()",
      awaitPromise: true,
      returnByValue: true,
    });
    return memoryBytes;
  } finally {
    cdp.close();
  }
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const web = await server();
  const startupSamples: number[] = [];
  const vmMemorySamples: number[] = [];
  for (let iteration = 1; iteration < args.profile.samples; iteration++) {
    const probe = await launch();
    startupSamples.push(probe.startupMs);
    vmMemorySamples.push(await memoryProbe(probe, web.origin));
    await probe.close();
  }
  const chrome = await launch();
  startupSamples.push(chrome.startupMs);
  vmMemorySamples.push(await memoryProbe(chrome, web.origin));
  let cdp: Cdp | undefined;
  try {
    cdp = await Cdp.connect(await pageSocket(chrome.port));
    await cdp.send("Runtime.enable");
    await cdp.send("Page.enable");
    await cdp.send("Page.navigate", {
      url: `${web.origin}/?profile=${args.profile.name}&samples=${args.profile.samples}`,
    });
    const result = await waitResult(cdp);
    result.measurements.push({
      name: "browser.process_startup",
      unit: "ms",
      dimensions: { host: "chromium", temperature: "cold" },
      samples: startupSamples,
      failures: [],
      stats: statistics(startupSamples),
    });
    result.measurements.push({
      name: "browser.agentos_vm_memory",
      unit: "bytes",
      dimensions: { host: "chromium", image: "posix", state: "idle" },
      samples: vmMemorySamples,
      failures: [],
      stats: statistics(vmMemorySamples),
    });
    validate(result);
    const json = `${JSON.stringify(result, null, 2)}\n`;
    if (args.output) await writeFile(args.output, json);
    else process.stdout.write(json);
  } finally {
    cdp?.close();
    await chrome.close();
    await web.close();
  }
}

await main();
