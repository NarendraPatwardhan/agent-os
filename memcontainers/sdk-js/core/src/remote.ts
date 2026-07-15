// Remote backend: the same Vm surface over the AgentOS REST + typed WebSocket contract.
// The server owns kernel execution; this client owns only the consumer-side callbacks for
// host-backed mounts, host tools, and interactive approval prompts.

import type { Backend, RawAutocompleteResult, RawExecResult } from "./backend.js";
import { forkRemoteVm, RemoteVmSidecarBackend } from "./sidecars.js";
import type { VmWarning } from "./sidecars.js";
import { makeFs } from "./fs.js";
import { dispatchMount } from "./mount.js";
import { assertSessionAgentType } from "./session.js";
import { Kind } from "./wire.js";
import { runToolJson, assertSafeToolBindingName } from "./tools.js";
import { UnifiedSocket } from "./unified-ws.js";
import type {
  DirEntry,
  Driver,
  ExecOptions,
  PermissionRequest,
  SessionEvent,
  SessionHandle,
  Shell,
  StatResult,
  ToolContext,
  ToolDefinition,
  VmStatus,
  SnapshotOptions,
  AutocompleteOptions,
} from "./types.js";

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const dec = (b: Uint8Array): string => new TextDecoder().decode(b);
function bytesBase64(bytes: Uint8Array): string {
  let raw = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    raw += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(raw);
}

function execBody(cmd: string, opts: ExecOptions = {}): Record<string, unknown> {
  const body: Record<string, unknown> = { cmd };
  if (opts.cwd !== undefined) body.cwd = opts.cwd;
  if (opts.env !== undefined) body.env = opts.env;
  if (typeof opts.stdin === "string") body.stdin = opts.stdin;
  else if (opts.stdin) body.stdinBase64 = bytesBase64(opts.stdin);
  return body;
}

export interface RemoteBackendOptions {
  endpoint: string;
  token?: string;
  vmId: string;
  onPermission?: (req: PermissionRequest) => void | Promise<void>;
}

interface RemoteVm {
  id: string;
  status: string;
  inflightEgress: number;
}

interface RemoteExecResult {
  ok: boolean;
  exitCode?: number;
  stdout: string;
  stderr: string;
}

interface RemoteAutocompleteResult extends RawAutocompleteResult {}

interface RemoteFsStat {
  path: string;
  kind: string;
  size: number;
  mode: number;
}

interface RemoteSessionEvent {
  sessionId?: string;
  event?: SessionEvent;
}

interface RemoteSessionEnd {
  sessionId?: string;
}

interface RemotePermissionRequest {
  id?: number;
  kind?: string;
  host?: string;
  url?: string;
  connection?: string;
  method?: string;
  origin?: string;
  argsDigest?: string;
}

export class RemoteBackend implements Backend {
  readonly sidecars: RemoteVmSidecarBackend;
  private readonly base: string;
  private readonly headers: Record<string, string>;
  private readonly token?: string;
  private readonly vmId: string;
  private readonly drivers = new Map<string, Driver>();
  private readonly tools = new Map<string, ToolDefinition>();
  private readonly onPermission?: (req: PermissionRequest) => void | Promise<void>;
  private readonly toolContext: ToolContext = { fs: makeFs(this) };
  private socket?: UnifiedSocket;
  private sessionSeq = 0;

  constructor(opts: RemoteBackendOptions) {
    this.base = opts.endpoint.replace(/\/$/, "");
    this.headers = opts.token ? { authorization: `Bearer ${opts.token}` } : {};
    this.token = opts.token;
    this.vmId = opts.vmId;
    this.onPermission = opts.onPermission;
    this.sidecars = new RemoteVmSidecarBackend(this.base, opts.token, opts.vmId);
  }

  private vmUrl(path = ""): string {
    return `${this.base}/v1/vms/${encodeURIComponent(this.vmId)}${path}`;
  }

  private wsUrl(path = "/ws"): string {
    const wsBase = this.base.replace(/^http/i, "ws");
    return `${wsBase}/v1/vms/${encodeURIComponent(this.vmId)}${path}`;
  }

  private urlWithPath(route: string, path: string): string {
    const url = new URL(this.vmUrl(route));
    url.searchParams.set("path", path);
    return url.toString();
  }

  private unified(): UnifiedSocket {
    if (!this.socket) {
      const socket = new UnifiedSocket(
        this.wsUrl(),
        this.token ? { vmId: this.vmId, token: this.token } : { vmId: this.vmId },
      );
      socket.hostCall = async (name, body, signal) => {
        if (name.startsWith("/")) {
          const driver = this.drivers.get(name);
          return driver ? dispatchMount(driver, body) : new Uint8Array(0);
        }
        const def = this.tools.get(name);
        if (!def) return new Uint8Array(0);
        const argsJson = dec(body).replace(/\0+$/u, "");
        return enc(await runToolJson(def, argsJson, { ...this.toolContext, signal }));
      };
      socket.frameHandlers.add((kind, json) => this.handlePermissionFrame(socket, kind, json));
      this.socket = socket;
    }
    return this.socket;
  }

  /** @internal — allocate a new remote VM identity through the VM transport. */
  fork(): Promise<{ id: string; warnings: VmWarning[] }> {
    return forkRemoteVm(this.base, this.token, this.vmId);
  }

  private handlePermissionFrame(socket: UnifiedSocket, kind: number, json: unknown): boolean {
    if (kind !== Kind.PermissionRequest) return false;
    const msg = asRecord(json) as RemotePermissionRequest | null;
    if (!msg || typeof msg.id !== "number") {
      return true;
    }

    let settled = false;
    const respond = (
      allow: boolean,
      opts: { remember?: "once" | "session"; message?: string } = {},
    ): void => {
      if (settled) return;
      settled = true;
      socket.send(
        Kind.PermissionResponse,
        opts.message ? { id: msg.id, allow, remember: opts.remember, message: opts.message } : { id: msg.id, allow, remember: opts.remember },
      );
    };

    if (!this.onPermission) {
      respond(false);
      return true;
    }

    const req: PermissionRequest = msg.kind === "tool_approval"
      ? {
          id: msg.id,
          kind: "tool_approval",
          connection: str(msg.connection),
          method: str(msg.method),
          url: str(msg.url),
          origin: str(msg.origin),
          ...(typeof msg.argsDigest === "string" ? { argsDigest: msg.argsDigest } : {}),
          allow: (opts?: { remember?: "once" | "session" }) => respond(true, opts),
          reject: (message?: string) => respond(false, { message }),
        }
      : {
          id: msg.id,
          kind: "network",
          host: str(msg.host),
          url: str(msg.url),
          allow: (opts?: { remember?: "once" | "session" }) => respond(true, opts),
          reject: (message?: string) => respond(false, { message }),
        };

    void Promise.resolve(this.onPermission(req)).catch(() => respond(false));
    return true;
  }

  async exec(cmd: string, opts: ExecOptions = {}): Promise<RawExecResult> {
    const response = await fetch(this.vmUrl("/exec"), {
      method: "POST",
      headers: { ...this.headers, "content-type": "application/json" },
      body: JSON.stringify(execBody(cmd, opts)),
    });
    if (!response.ok) throw new Error(`remote exec failed: ${response.status} ${await safeText(response)}`);
    const result = (await response.json()) as RemoteExecResult;
    return {
      stdout: enc(result.stdout),
      stderr: enc(result.stderr),
      exitCode: result.exitCode ?? (result.ok ? 0 : 1),
    };
  }

  async autocomplete(
    source: Uint8Array,
    cursor: number,
    opts: Omit<AutocompleteOptions, "cursor"> = {},
  ): Promise<RawAutocompleteResult> {
    const response = await fetch(this.vmUrl("/autocomplete"), {
      method: "POST",
      headers: { ...this.headers, "content-type": "application/json" },
      body: JSON.stringify({
        source: dec(source),
        cursor,
        ...(opts.cwd === undefined ? {} : { cwd: opts.cwd }),
        ...(opts.env === undefined ? {} : { env: opts.env }),
        ...(opts.limit === undefined ? {} : { limit: opts.limit }),
      }),
    });
    if (!response.ok) {
      throw new Error(`remote autocomplete failed: ${response.status} ${await safeText(response)}`);
    }
    return (await response.json()) as RemoteAutocompleteResult;
  }

  async read(path: string): Promise<Uint8Array> {
    const response = await fetch(this.urlWithPath("/fs/files", path), { headers: this.headers });
    if (!response.ok) throw new Error(`remote read ${path}: ${response.status} ${await safeText(response)}`);
    return responseBytes(response);
  }

  async write(path: string, data: Uint8Array): Promise<void> {
    const response = await fetch(this.urlWithPath("/fs/files", path), {
      method: "PUT",
      headers: { ...this.headers, "content-type": "application/octet-stream" },
      body: data as BodyInit,
    });
    if (!response.ok) throw new Error(`remote write ${path}: ${response.status} ${await safeText(response)}`);
  }

  async ls(path: string): Promise<DirEntry[]> {
    const response = await fetch(this.urlWithPath("/fs/entries", path), { headers: this.headers });
    if (!response.ok) throw new Error(`remote ls ${path}: ${response.status} ${await safeText(response)}`);
    const body = (await response.json()) as { items?: RemoteFsStat[] };
    return (body.items ?? []).map((entry) => ({
      name: basename(entry.path),
      isDir: isDirKind(entry.kind),
      isSymlink: isSymlinkKind(entry.kind),
    }));
  }

  async stat(path: string): Promise<StatResult> {
    const response = await fetch(this.urlWithPath("/fs/stat", path), { headers: this.headers });
    if (!response.ok) throw new Error(`remote stat ${path}: ${response.status} ${await safeText(response)}`);
    return statFromWire((await response.json()) as RemoteFsStat);
  }

  async readlink(path: string): Promise<string> {
    const response = await fetch(this.urlWithPath("/fs/symlinks", path), { headers: this.headers });
    if (!response.ok) throw new Error(`remote readlink ${path}: ${response.status} ${await safeText(response)}`);
    const body = (await response.json()) as { target?: unknown };
    if (typeof body.target !== "string") {
      throw new Error(`remote readlink ${path}: malformed response`);
    }
    return body.target;
  }

  async mkdir(path: string): Promise<void> {
    const response = await fetch(this.urlWithPath("/fs/dirs", path), {
      method: "PUT",
      headers: this.headers,
    });
    if (!response.ok) throw new Error(`remote mkdir ${path}: ${response.status} ${await safeText(response)}`);
  }

  async rm(path: string): Promise<void> {
    const response = await fetch(this.urlWithPath("/fs/files", path), {
      method: "DELETE",
      headers: this.headers,
    });
    if (!response.ok) throw new Error(`remote rm ${path}: ${response.status} ${await safeText(response)}`);
  }

  async chmod(path: string, mode: number): Promise<void> {
    const response = await fetch(this.urlWithPath("/fs/mode", path), {
      method: "PUT",
      headers: { ...this.headers, "content-type": "application/json" },
      body: JSON.stringify({ mode }),
    });
    if (!response.ok) throw new Error(`remote chmod ${path}: ${response.status} ${await safeText(response)}`);
  }

  async symlink(target: string, link: string): Promise<void> {
    const response = await fetch(this.vmUrl("/fs/symlinks"), {
      method: "PUT",
      headers: { ...this.headers, "content-type": "application/json" },
      body: JSON.stringify({ target, link }),
    });
    if (!response.ok) {
      throw new Error(`remote symlink ${link} -> ${target}: ${response.status} ${await safeText(response)}`);
    }
  }

  async snapshot(opts: SnapshotOptions = {}): Promise<Uint8Array> {
    const mode = opts.mode ?? "full";
    const response = await fetch(`${this.vmUrl("/snapshots")}?mode=${encodeURIComponent(mode)}`, {
      method: "POST",
      headers: this.headers,
    });
    if (!response.ok) throw new Error(`remote snapshot failed: ${response.status} ${await safeText(response)}`);
    return responseBytes(response);
  }

  async commitLayer(): Promise<{ digest: string; tar: Uint8Array }> {
    const response = await fetch(this.vmUrl("/layers"), {
      method: "POST",
      headers: this.headers,
    });
    if (!response.ok) throw new Error(`remote layer commit failed: ${response.status} ${await safeText(response)}`);
    const tar = await responseBytes(response);
    const digest = response.headers.get("x-mc-digest") ?? (await sha256Digest(tar));
    return { digest, tar };
  }

  async inflightEgress(): Promise<number> {
    try {
      return (await this.remoteVm()).inflightEgress;
    } catch {
      return 0;
    }
  }

  memoryBytes(): number {
    return 0;
  }

  async status(): Promise<VmStatus> {
    const vm = await this.remoteVm();
    return {
      running: vm.status !== "exited" && vm.status !== "disposed",
      memoryBytes: 0,
      inflightEgress: vm.inflightEgress,
    };
  }

  tool(def: ToolDefinition): void {
    assertSafeToolBindingName(def.name);
    this.tools.set(def.name, def);
    void this.unified().ensure();
  }

  unregisterTool(name: string): void {
    this.tools.delete(name);
  }

  async serviceCall(name: string, req: Uint8Array): Promise<Uint8Array> {
    // POST /v1/vms/:id/svc/:service — the served host runs the resident-service call as host control
    // on its own authority boundary and returns the framed body. A framed non-zero status (the
    // service could not be delivered) is surfaced by the server as a non-2xx, matching the embedded
    // backend which throws on a non-zero status.
    const response = await fetch(this.vmUrl(`/svc/${encodeURIComponent(name)}`), {
      method: "POST",
      headers: { ...this.headers, "content-type": "application/octet-stream" },
      body: req as BodyInit,
    });
    if (!response.ok) {
      throw new Error(`remote svc_call ${name}: ${response.status} ${await safeText(response)}`);
    }
    return responseBytes(response);
  }

  async mount(path: string, driver: Driver, readOnly: boolean): Promise<void> {
    const socket = this.unified();
    await socket.ensure();
    this.drivers.set(path, driver);
    const response = await fetch(this.vmUrl("/mounts"), {
      method: "POST",
      headers: { ...this.headers, "content-type": "application/json" },
      body: JSON.stringify({ path, kind: "host-call", source: path, readOnly }),
    });
    if (!response.ok) {
      this.drivers.delete(path);
      throw new Error(`remote mount ${path}: ${response.status} ${await safeText(response)}`);
    }
  }

  async unmount(path: string): Promise<void> {
    const response = await fetch(this.vmUrl("/mounts"), {
      method: "DELETE",
      headers: { ...this.headers, "content-type": "application/json" },
      body: JSON.stringify({ path }),
    });
    this.drivers.delete(path);
    if (!response.ok) throw new Error(`remote unmount ${path}: ${response.status} ${await safeText(response)}`);
  }

  shell(): Shell {
    const socket = this.unified();
    void socket.ensure();
    return {
      on(cb: (bytes: Uint8Array) => void): () => void {
        socket.shellListeners.add(cb);
        return () => {
          socket.shellListeners.delete(cb);
        };
      },
      write(data: string | Uint8Array): void {
        socket.shellWrite(typeof data === "string" ? enc(data) : data);
      },
      history(): Uint8Array {
        return socket.history();
      },
    };
  }

  liveSession(agentType: string): SessionHandle {
    assertSessionAgentType(agentType);
    const id = `s${++this.sessionSeq}`;
    const socket = this.unified();
    const backend = this;
    const listeners = new Set<(event: SessionEvent) => void>();
    let events: SessionEvent[] = [];
    let resolveEnd: ((events: SessionEvent[]) => void) | undefined;

    socket.frameHandlers.add((kind, json) => {
      if (kind === Kind.SessionEvent) {
        const msg = json as RemoteSessionEvent;
        if (msg.sessionId !== id || !msg.event) return false;
        events.push(msg.event);
        for (const listener of listeners) listener(msg.event);
        return true;
      }
      if (kind === Kind.SessionEnd) {
        const msg = json as RemoteSessionEnd;
        if (msg.sessionId !== id) return false;
        resolveEnd?.(events);
        return true;
      }
      return false;
    });

    return {
      id,
      on(cb: (event: SessionEvent) => void): () => void {
        listeners.add(cb);
        return () => {
          listeners.delete(cb);
        };
      },
      async prompt(text: string): Promise<SessionEvent[]> {
        events = [];
        const promptFile = `/tmp/.mc-session-${id}`;
        await backend.write(promptFile, enc(text));
        await socket.ensure();
        const done = new Promise<SessionEvent[]>((resolve) => {
          resolveEnd = resolve;
        });
        socket.send(Kind.SessionStart, { sessionId: id, agentType, promptPath: promptFile });
        return done;
      },
    };
  }

  async connect(): Promise<void> {
    await this.unified().ensure();
  }

  forceReconnect(): void {
    this.socket?.forceReconnect();
  }

  async close(): Promise<void> {
    this.socket?.close();
    await fetch(this.vmUrl(), { method: "DELETE", headers: this.headers }).catch(() => {});
  }

  private async remoteVm(): Promise<RemoteVm> {
    const response = await fetch(this.vmUrl(), { headers: this.headers });
    if (!response.ok) throw new Error(`remote status failed: ${response.status} ${await safeText(response)}`);
    return (await response.json()) as RemoteVm;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

function str(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function isDirKind(kind: string): boolean {
  return kind === "dir" || kind === "directory";
}

function isSymlinkKind(kind: string): boolean {
  return kind === "symlink" || kind === "link";
}

function basename(path: string): string {
  const trimmed = path.replace(/\/+$/u, "");
  const idx = trimmed.lastIndexOf("/");
  return idx >= 0 ? trimmed.slice(idx + 1) : trimmed;
}

function statFromWire(stat: RemoteFsStat): StatResult {
  const isDir = isDirKind(stat.kind);
  return {
    size: stat.size,
    isDir,
    isSymlink: isSymlinkKind(stat.kind),
    nlink: isDir ? 2 : 1,
    mode: stat.mode,
  };
}

async function responseBytes(response: Response): Promise<Uint8Array> {
  return new Uint8Array(await response.arrayBuffer());
}

async function sha256Digest(bytes: Uint8Array): Promise<string> {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) throw new Error("remote layer commit response omitted x-mc-digest and crypto.subtle is unavailable");
  const digest = await subtle.digest("SHA-256", bytes);
  return `sha256:${hex(new Uint8Array(digest))}`;
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function safeText(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return "";
  }
}
