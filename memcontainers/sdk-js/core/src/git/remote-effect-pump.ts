/** Host policy plus generic HTTP-effect execution for engine-owned Git remotes. */

import {
  ACTION_BEGIN,
  ACTION_LIST,
  ACTION_UPDATE,
  HTTP_RESPONSE_ABORT,
  HTTP_RESPONSE_BEGIN,
  HTTP_RESPONSE_CHUNK,
  HTTP_RESPONSE_END,
  MAX_FIELD_BYTES,
  MAX_PACK_BYTES,
  OP_CLONE,
  OP_FETCH,
  OP_HTTP_EFFECT,
  OP_PULL,
  OP_PUSH,
  OP_STREAM,
  OP_SUBMODULE,
  STREAM_CLOSE,
  STREAM_READ,
  STATUS_EFFECT,
  STATUS_OK,
  decodeHttpEffect,
  decodeRemoteResult,
  decodeStreamChunk,
  decodeSubmoduleResult,
  encodeHttpResponse,
  encodeRemoteRequest,
  encodeStreamRequest,
  encodeSubmoduleRequest,
  type HttpEffect,
} from "@mc/contracts/git";
import type { GitEngine } from "./engine.js";
import type { GitRequest, GitResponse } from "./types.js";
import {
  guestArgsCarrySecrets,
  originAllowed,
  resolveGitRemote,
  spliceCredentialHeaders,
  type ResolveRemoteOptions,
} from "./connections.js";

export interface RemoteEffectPumpOptions extends ResolveRemoteOptions {
  allowOrigins?: string[];
  fetch?: typeof globalThis.fetch;
  readOnly?: boolean;
  onPushApproval?: (context: { url: string; connectionRef?: string }) => boolean | Promise<boolean>;
}

export type GitEngineMountMap = {
  engines: ReadonlyMap<string, GitEngine> | Record<string, GitEngine>;
  defaultMount?: string;
};
export type GitHostCallEngines = GitEngine | GitEngineMountMap;

const REMOTE_OPERATIONS = new Set(["clone", "fetch", "pull", "push"]);

export class GitRemoteEffectPump {
  private readonly fetchImpl: typeof globalThis.fetch;

  constructor(private readonly engine: GitEngine, private readonly options: RemoteEffectPumpOptions = {}) {
    this.fetchImpl = options.fetch ?? globalThis.fetch.bind(globalThis);
  }

  handle(request: GitRequest): Promise<GitResponse> {
    // Hold the engine's one queue for the complete remote state machine,
    // including HTTP waits. Local operations cannot observe an intermediate
    // advertisement/import/ref-update phase.
    return this.engine.bridge.serial(() => this.handleUnlocked(request)).catch((error) =>
      fail(error instanceof Error ? error.message : "Git remote operation failed"));
  }

  private async handleUnlocked(request: GitRequest): Promise<GitResponse> {
    const op = String(request.op ?? "").toLowerCase();
    if (op === "submodule") return this.handleSubmoduleUnlocked(request);
    const opcode = op === "clone" ? OP_CLONE : op === "fetch" ? OP_FETCH : op === "pull" ? OP_PULL : op === "push" ? OP_PUSH : 0;
    if (!opcode) return fail(`unsupported remote Git operation: ${op}`);
    if ((this.options.readOnly || this.engine.readOnly) && op === "push") return fail("read-only Git mount");
    const args = request.args && typeof request.args === "object" && !Array.isArray(request.args)
      ? request.args as Record<string, unknown> : {};
    if (guestArgsCarrySecrets(args)) return fail("credential material is forbidden in guest Git requests");
    const resolved = resolveGitRemote(args, this.options);
    if (!resolved.ok) return { ok: false, code: resolved.code, stdout: "", stderr: resolved.stderr };
    if (op === "push" && resolved.binding.pushAction === "block") return fail("Git push is blocked by policy");
    if (op === "push" && resolved.binding.pushAction === "require_approval") {
      const approved = await this.options.onPushApproval?.({
        url: resolved.binding.url,
        connectionRef: resolved.binding.connectionRef,
      });
      if (!approved) return fail("Git push approval is required");
    }
    const bareOrigins = this.options.allowOrigins ?? [];
    if (!originAllowed(resolved.binding.origins, resolved.binding.url) ||
        (!resolved.binding.connectionRef &&
          (!bareOrigins.length || !originAllowed(bareOrigins, resolved.binding.url)))) {
      return fail("Git remote origin is not allowlisted");
    }
    let refspecs: Record<string, string>;
    let depth: number | undefined;
    try {
      refspecs = parseRefspecs(args.refspecs, op === "push");
      depth = parseDepth(args.depth, op !== "push");
    } catch (error) {
      return fail(error instanceof Error ? error.message : "invalid Git remote arguments");
    }
    let response = this.engine.bridge.execute(opcode, owned(encodeRemoteRequest({
      action: ACTION_BEGIN,
      url: resolved.binding.url,
      remote: typeof args.remote === "string" ? args.remote : undefined,
      refspecs,
      depth,
      flags: typeof args.flags === "number" ? args.flags >>> 0 : 0,
    })));
    while (response.status === STATUS_EFFECT) {
      const effect = decodeHttpEffect(owned(response.payload));
      response = await this.performHttpEffect(effect, resolved.binding.url,
        spliceCredentialHeaders(resolved.binding.auth), response.requestId);
    }
    if (response.status !== STATUS_OK) return fail("Git remote operation failed");
    const result = decodeRemoteResult(owned(response.payload));
    return { ok: true, code: 0, stdout: "", stderr: "", result };
  }

  private async handleSubmoduleUnlocked(request: GitRequest): Promise<GitResponse> {
    const args = request.args && typeof request.args === "object" && !Array.isArray(request.args)
      ? request.args as Record<string, unknown> : {};
    if (args.action !== "update") return fail("only submodule update uses the host HTTP effect pump");
    if (this.options.readOnly || this.engine.readOnly) return fail("read-only Git mount");
    const listed = decodeSubmoduleResult(owned(this.engine.bridge.execute(OP_SUBMODULE,
      owned(encodeSubmoduleRequest({ action: ACTION_LIST, path: typeof args.path === "string" ? args.path : undefined }))).payload));
    const bindings = [] as Array<ReturnType<typeof resolveGitRemote> & { ok: true }>;
    for (const entry of listed.entries) {
      const resolved = resolveGitRemote({
        url: entry.url,
        ...(typeof args.connection === "string" ? { connection: args.connection } : {}),
      }, this.options);
      if (!resolved.ok) return fail(`submodule ${entry.path}: ${resolved.stderr.trim()}`);
      const bareOrigins = this.options.allowOrigins ?? [];
      if (!originAllowed(resolved.binding.origins, resolved.binding.url) ||
          (!resolved.binding.connectionRef &&
            (!bareOrigins.length || !originAllowed(bareOrigins, resolved.binding.url)))) {
        return fail(`submodule ${entry.path}: Git remote origin is not allowlisted`);
      }
      bindings.push(resolved);
    }
    let response = this.engine.bridge.execute(OP_SUBMODULE, owned(encodeSubmoduleRequest({
      action: ACTION_UPDATE,
      path: typeof args.path === "string" ? args.path : undefined,
    })));
    while (response.status === STATUS_EFFECT) {
      const effect = decodeHttpEffect(owned(response.payload));
      const effectUrl = absoluteHttpEffectUrl(effect.path);
      const binding = bindings.find((candidate) => effectBelongsToRemote(effectUrl, candidate.binding.url));
      if (!binding) throw new Error("submodule HTTP effect origin was not pre-authorized");
      response = await this.performHttpEffect(effect, binding.binding.url,
        spliceCredentialHeaders(binding.binding.auth), response.requestId);
    }
    if (response.status !== STATUS_OK) return fail("Git submodule update failed");
    const result = decodeSubmoduleResult(owned(response.payload));
    return {
      ok: true,
      code: 0,
      stdout: `updated ${result.entries.length} submodule(s)\n`,
      stderr: "",
      result,
    };
  }

  private async performHttpEffect(
    effect: HttpEffect,
    remoteUrl: string,
    credentialHeaders: Record<string, string>,
    requestId: number,
  ) {
    const url = new URL(effect.path, remoteUrl);
    if (url.origin !== new URL(remoteUrl).origin) throw new Error("Git engine HTTP effect changed origin");
    try {
      const body = effect.body ? await this.readStream(effect.body) : undefined;
      const response = await this.fetchImpl(url, {
        method: effect.method,
        headers: { ...effect.headers, ...credentialHeaders },
        body: body?.byteLength ? Uint8Array.from(body) : undefined,
        redirect: "manual",
      });
      if (response.status >= 300 && response.status < 400) throw new Error("Git HTTP redirects are forbidden");
      const headers: Record<string, string> = {};
      for (const name of ["content-type", "content-length", "etag", "last-modified"]) {
        const value = response.headers.get(name);
        if (value !== null) headers[name] = value;
      }
      const declaredLength = response.headers.get("content-length");
      if (declaredLength !== null) {
        const parsed = Number(declaredLength);
        if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > MAX_PACK_BYTES) {
          throw new Error("Git HTTP response Content-Length exceeds protocol limits");
        }
      }
      this.expectHttpAck(this.engine.bridge.executeForRequest(OP_HTTP_EFFECT, requestId, owned(encodeHttpResponse({
        exchange: effect.exchange, action: HTTP_RESPONSE_BEGIN, status: response.status, headers,
      }))));
      let responseBytes = 0;
      if (response.body) {
        const reader = response.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          if (!value?.byteLength) continue;
          if (responseBytes > MAX_PACK_BYTES - value.byteLength) {
            await reader.cancel("Git HTTP response exceeds MAX_PACK_BYTES");
            throw new Error("Git HTTP response exceeds MAX_PACK_BYTES");
          }
          responseBytes += value.byteLength;
          for (let offset = 0; offset < value.byteLength; offset += MAX_FIELD_BYTES) {
            const chunk = value.subarray(offset, Math.min(value.byteLength, offset + MAX_FIELD_BYTES));
            this.expectHttpAck(this.engine.bridge.executeForRequest(OP_HTTP_EFFECT, requestId, owned(encodeHttpResponse({
              exchange: effect.exchange,
              action: HTTP_RESPONSE_CHUNK,
              headers: {},
              data: owned(chunk),
            }))));
          }
        }
      }
      // END may complete the remote or emit its next HTTP effect. Preserve that
      // response verbatim for the outer state-machine loop.
      return this.engine.bridge.executeForRequest(OP_HTTP_EFFECT, requestId, owned(encodeHttpResponse({
        exchange: effect.exchange, action: HTTP_RESPONSE_END, headers: {},
      })));
    } catch (error) {
      try {
        this.engine.bridge.executeForRequest(OP_HTTP_EFFECT, requestId, owned(encodeHttpResponse({
          exchange: effect.exchange,
          action: HTTP_RESPONSE_ABORT,
          headers: {},
          error_code: 1,
        })));
      } catch { /* the original transport/protocol failure remains authoritative */ }
      throw error;
    }
  }

  private async readStream(handle: number): Promise<Uint8Array> {
    const chunks: Uint8Array[] = [];
    let length = 0;
    let offset = 0n;
    let readFailure: unknown;
    try {
      for (;;) {
        const low = Number(offset & 0xffff_ffffn);
        const high = Number((offset >> 32n) & 0xffff_ffffn);
        const result = decodeStreamChunk(owned(this.engine.bridge.execute(OP_STREAM,
          owned(encodeStreamRequest({
            action: STREAM_READ,
            handle,
            offset_low: low,
            offset_high: high,
          }))).payload));
        if (result.handle !== handle || result.offset_low !== low || result.offset_high !== high) {
          throw new Error("Git engine returned a mismatched stream chunk");
        }
        const chunk = result.data;
        if (chunk.byteLength > MAX_FIELD_BYTES || length > MAX_PACK_BYTES - chunk.byteLength) {
          throw new Error("Git request body stream exceeds protocol limits");
        }
        if (!chunk.byteLength && !result.done) throw new Error("Git engine stream made no progress");
        if (chunk.byteLength) {
          chunks.push(owned(chunk));
          length += chunk.byteLength;
          offset += BigInt(chunk.byteLength);
        }
        if (result.done) break;
      }
    } catch (error) {
      readFailure = error;
      throw error;
    } finally {
      try {
        this.expectStreamClose(this.engine.bridge.execute(OP_STREAM, owned(encodeStreamRequest({
          action: STREAM_CLOSE,
          handle,
        }))));
      } catch (closeError) {
        if (readFailure === undefined) throw closeError;
      }
    }
    const body = new Uint8Array(length);
    let outputOffset = 0;
    for (const chunk of chunks) { body.set(chunk, outputOffset); outputOffset += chunk.byteLength; }
    return body;
  }

  private expectHttpAck(response: { opcode: number; status: number }): void {
    if (response.opcode !== OP_HTTP_EFFECT || response.status !== STATUS_OK) {
      throw new Error("Git engine rejected an HTTP response phase");
    }
  }

  private expectStreamClose(response: { opcode: number; status: number }): void {
    if (response.opcode !== OP_STREAM || response.status !== STATUS_OK) {
      throw new Error("Git engine rejected request-body stream close");
    }
  }
}

function owned(bytes: Uint8Array): Uint8Array<ArrayBuffer> { return Uint8Array.from(bytes); }

function absoluteHttpEffectUrl(value: string): URL {
  const url = new URL(value);
  if ((url.protocol !== "http:" && url.protocol !== "https:") || url.username || url.password) {
    throw new Error("submodule HTTP effect URL is not public HTTP(S)");
  }
  return url;
}

function effectBelongsToRemote(effect: URL, remote: string): boolean {
  const base = new URL(remote);
  const root = base.pathname.replace(/\/+$/, "");
  return effect.origin === base.origin &&
    (effect.pathname === root || effect.pathname.startsWith(`${root}/`));
}

function parseRefspecs(value: unknown, required: boolean): Record<string, string> {
  if (value === undefined || value === null) {
    if (required) throw new Error("Git push requires one explicit source:destination refspec");
    return {};
  }
  if (!Array.isArray(value)) throw new Error("Git refspecs must be an array of source:destination strings");
  const out: Record<string, string> = {};
  for (const raw of value) {
    if (typeof raw !== "string" || raw.length > 2048 || /[\0\r\n]/.test(raw)) {
      throw new Error("invalid Git refspec");
    }
    const separator = raw.indexOf(":");
    if (separator <= 0 || separator !== raw.lastIndexOf(":") || separator === raw.length - 1) {
      throw new Error("Git refspec must contain exactly one nonempty source:destination mapping");
    }
    const source = raw.slice(0, separator);
    const destination = raw.slice(separator + 1);
    if (!source.startsWith("refs/") || !destination.startsWith("refs/") ||
        Object.prototype.hasOwnProperty.call(out, source)) {
      throw new Error("Git refspec must use unique fully-qualified refs");
    }
    out[source] = destination;
  }
  const count = Object.keys(out).length;
  if (required && count !== 1) {
    throw new Error("Git push requires exactly one explicit source:destination refspec");
  }
  if (count > 1) throw new Error("Git remote operation accepts at most one explicit refspec");
  return out;
}

function parseDepth(value: unknown, permitted: boolean): number | undefined {
  if (value === undefined || value === null) return undefined;
  if (!permitted) throw new Error("Git push does not accept depth");
  if (typeof value !== "number" || !Number.isInteger(value) || value < 1 || value > 0xffff_ffff) {
    throw new Error("Git depth must be a positive u32 integer");
  }
  return value;
}

export function normalizeGitEngineMap(input: GitHostCallEngines): { engines: Map<string, GitEngine>; defaultMount: string } {
  if (input instanceof Map || (typeof input === "object" && input && "engines" in input)) {
    const spec = input as GitEngineMountMap;
    const engines = spec.engines instanceof Map ? new Map(spec.engines) : new Map(Object.entries(spec.engines));
    const defaultMount = spec.defaultMount ?? engines.keys().next().value;
    if (!defaultMount || !engines.has(defaultMount)) throw new Error("Git engine map has no valid default mount");
    return { engines, defaultMount };
  }
  return { engines: new Map([["/", input as GitEngine]]), defaultMount: "/" };
}

export function mountFromGitRequest(request: GitRequest & { mount?: unknown }): string | undefined {
  if (typeof request.mount === "string") return request.mount;
  const args = request.args as Record<string, unknown> | undefined;
  return typeof args?.mount === "string" ? args.mount : undefined;
}

export function resolveGitEngineForMount(request: GitRequest, engines: Map<string, GitEngine>, defaultMount: string) {
  const mount = mountFromGitRequest(request);
  const key = mount ?? defaultMount;
  const engine = engines.get(key);
  return engine ? { ok: true as const, engine } : { ok: false as const, response: fail(`unknown Git mount: ${key}`) };
}

export function gitHostCallHandler(engineOrMap: GitHostCallEngines, options: RemoteEffectPumpOptions = {}) {
  const { engines, defaultMount } = normalizeGitEngineMap(engineOrMap);
  const pumps = new Map<GitEngine, GitRemoteEffectPump>();
  return async (body: string): Promise<string> => {
    let request: GitRequest;
    try { request = JSON.parse(body) as GitRequest; } catch { return JSON.stringify(fail("invalid Git host-call request")); }
    const selected = resolveGitEngineForMount(request, engines, defaultMount);
    if (!selected.ok) return JSON.stringify(selected.response);
    const operation = String(request.op ?? "").toLowerCase();
    const args = request.args && typeof request.args === "object" && !Array.isArray(request.args)
      ? request.args as Record<string, unknown> : {};
    const remoteOperation = REMOTE_OPERATIONS.has(operation) ||
      (operation === "submodule" && args.action === "update");
    if (!remoteOperation) {
      return JSON.stringify(await selected.engine.run(request));
    }
    let pump = pumps.get(selected.engine);
    if (!pump) { pump = new GitRemoteEffectPump(selected.engine, options); pumps.set(selected.engine, pump); }
    return JSON.stringify(await pump.handle(request));
  };
}

function fail(stderr: string): GitResponse {
  return { ok: false, code: 1, stdout: "", stderr: `${stderr.replace(/\n?$/, "\n")}` };
}
