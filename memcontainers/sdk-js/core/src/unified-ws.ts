// Client transport for one VM's typed WebSocket. REST owns bounded request/response operations;
// this socket owns live shell bytes, relayed host calls, streamed sessions, and permission prompts.

import { WIRE_VERSION } from "@mc/contracts/wire";
import {
  Kind,
  decodeFrame,
  decodeHostCall,
  decodeHostCancel,
  encodeFrame,
  encodeHostResult,
} from "./wire.js";

export type HostCallDispatcher = (name: string, body: Uint8Array, signal: AbortSignal) => Promise<Uint8Array>;
export type FrameHandler = (kind: number, json: unknown) => boolean;

const BACKOFF_MIN_MS = 250;
const BACKOFF_MAX_MS = 4_000;
const ANSWER_CACHE_LIMIT = 256;

export class UnifiedSocket {
  private ws?: WebSocket;
  private ready?: Promise<void>;
  private wantOpen = false;
  private backoffMs = BACKOFF_MIN_MS;
  private shellSeen = 0;
  private seq = 0;
  private readonly shellBuf: Uint8Array[] = [];
  private readonly pending: Array<{ kind: number; body: Uint8Array | object }> = [];
  private readonly inflight = new Map<number, AbortController>();
  private readonly answered = new Map<number, Uint8Array>();

  readonly shellListeners = new Set<(bytes: Uint8Array) => void>();
  readonly frameHandlers = new Set<FrameHandler>();
  hostCall?: HostCallDispatcher;

  constructor(
    private readonly url: string,
    private readonly hello: Record<string, unknown> = {},
  ) {}

  ensure(): Promise<void> {
    this.wantOpen = true;
    if (!this.ready) this.ready = this.connect();
    return this.ready;
  }

  private connect(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      const ws = new WebSocket(this.url);
      ws.binaryType = "arraybuffer";
      this.ws = ws;

      ws.addEventListener("open", () => {
        this.backoffMs = BACKOFF_MIN_MS;
        this.sendOpen(ws, Kind.Hello, {
          protocol: WIRE_VERSION,
          resume: this.shellSeen,
          ...this.hello,
        });
        this.flushPending();
        if (!settled) {
          settled = true;
          resolve();
        }
      });
      ws.addEventListener("message", (event: MessageEvent) => {
        if (event.data instanceof ArrayBuffer) {
          void this.onFrame(new Uint8Array(event.data));
        } else if (event.data instanceof Blob) {
          void event.data.arrayBuffer().then((buf) => this.onFrame(new Uint8Array(buf)));
        }
      });
      ws.addEventListener("close", () => this.onDrop(ws));
      ws.addEventListener("error", () => {
        if (!settled) {
          settled = true;
          reject(new Error("wire WebSocket failed to open"));
        }
        this.onDrop(ws);
      });
    });
  }

  private onDrop(ws: WebSocket): void {
    if (this.ws !== ws) return;
    this.ws = undefined;
    if (!this.wantOpen) {
      this.ready = undefined;
      return;
    }
    const delay = Math.min(this.backoffMs, BACKOFF_MAX_MS) * (0.7 + Math.random() * 0.6);
    this.backoffMs = Math.min(this.backoffMs * 2, BACKOFF_MAX_MS);
    setTimeout(() => {
      if (this.wantOpen && !this.ws) this.ready = this.connect();
    }, delay);
  }

  private rememberAnswer(id: number, result: Uint8Array): void {
    this.answered.set(id, result);
    if (this.answered.size > ANSWER_CACHE_LIMIT) {
      const oldest = this.answered.keys().next().value;
      if (oldest !== undefined) this.answered.delete(oldest);
    }
  }

  private async onFrame(frame: Uint8Array): Promise<void> {
    let decoded;
    try {
      decoded = decodeFrame(frame);
    } catch {
      return;
    }

    switch (decoded.kind) {
      case Kind.ShellOut: {
        const bytes = decoded.bytes ?? new Uint8Array(0);
        this.shellSeen += bytes.length;
        this.shellBuf.push(bytes.slice());
        for (const listener of this.shellListeners) listener(bytes);
        return;
      }
      case Kind.Welcome:
        return;
      case Kind.HostCall: {
        if (!decoded.bytes) return;
        const { id, name, body } = decodeHostCall(decoded.bytes);
        const cached = this.answered.get(id);
        if (cached) {
          this.send(Kind.HostResult, encodeHostResult(id, cached));
          return;
        }
        if (this.inflight.has(id)) return;
        const abort = new AbortController();
        this.inflight.set(id, abort);
        try {
          const result = this.hostCall ? await this.hostCall(name, body, abort.signal) : new Uint8Array(0);
          if (abort.signal.aborted) return;
          this.rememberAnswer(id, result);
          this.send(Kind.HostResult, encodeHostResult(id, result));
        } catch {
          if (!abort.signal.aborted) this.send(Kind.HostResult, encodeHostResult(id, new Uint8Array(0)));
        } finally {
          this.inflight.delete(id);
        }
        return;
      }
      case Kind.HostCancel: {
        if (!decoded.bytes) return;
        try {
          this.inflight.get(decodeHostCancel(decoded.bytes))?.abort();
        } catch {
          // Malformed cancellation cannot be allowed to disturb unrelated calls.
        }
        return;
      }
      default:
        for (const handler of this.frameHandlers) {
          if (handler(decoded.kind, decoded.json)) return;
        }
    }
  }

  send(kind: number, body: Uint8Array | object): void {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      this.pending.push({ kind, body });
      return;
    }
    this.sendOpen(ws, kind, body);
  }

  private sendOpen(ws: WebSocket, kind: number, body: Uint8Array | object): void {
    try {
      ws.send(encodeFrame(kind, this.seq++, body));
    } catch {
      this.pending.unshift({ kind, body });
    }
  }

  private flushPending(): void {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    while (this.pending.length > 0) {
      const next = this.pending.shift()!;
      this.sendOpen(ws, next.kind, next.body);
    }
  }

  shellWrite(data: Uint8Array): void {
    void this.ensure().then(() => this.send(Kind.ShellIn, data));
  }

  history(): Uint8Array {
    let len = 0;
    for (const chunk of this.shellBuf) len += chunk.length;
    const out = new Uint8Array(len);
    let off = 0;
    for (const chunk of this.shellBuf) {
      out.set(chunk, off);
      off += chunk.length;
    }
    return out;
  }

  forceReconnect(): void {
    try {
      this.ws?.close();
    } catch {
      /* already closed */
    }
  }

  close(): void {
    this.wantOpen = false;
    for (const controller of this.inflight.values()) controller.abort();
    this.inflight.clear();
    try {
      this.ws?.close();
    } catch {
      /* already closed */
    }
  }
}
