import {
  SIDECAR_ERROR_LIMIT,
  SIDECAR_ERROR_TIMEOUT,
  SIDECAR_MAX_RESULT_BYTES,
} from "./sidecar.gen";
import { boundedByOperation, defaultTimeout, fault } from "./limits";

const encoder = new TextEncoder();
const maxMessageBytes = Math.ceil((SIDECAR_MAX_RESULT_BYTES * 4) / 3) + 65_536;

interface Pending {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface Waiter {
  method: string;
  sessionId?: string;
  predicate: (params: Record<string, unknown>) => boolean;
  resolve: (params: Record<string, unknown>) => void;
  reject: (reason: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

export class CdpClient {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  private readonly waiters = new Set<Waiter>();
  private failure: unknown;

  private constructor(private readonly socket: WebSocket) {
    socket.onmessage = (event) => this.receive(String(event.data));
    socket.onclose = () => this.failAll(new Error("Chromium CDP connection closed"));
    socket.onerror = () => this.failAll(new Error("Chromium CDP connection failed"));
  }

  static async connect(url: string, timeoutMs: number): Promise<CdpClient> {
    const socket = new WebSocket(url);
    timeoutMs = boundedByOperation(timeoutMs);
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const finish = (error?: unknown) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (error === undefined) resolve();
        else {
          socket.close();
          reject(error);
        }
      };
      const timer = setTimeout(
        () => finish(fault(SIDECAR_ERROR_TIMEOUT, "Chromium CDP connection timed out")),
        timeoutMs,
      );
      socket.onopen = () => finish();
      socket.onerror = () => finish(new Error("Chromium CDP connection failed"));
    });
    return new CdpClient(socket);
  }

  call<T = Record<string, unknown>>(
    method: string,
    params: Record<string, unknown> = {},
    sessionId?: string,
    timeoutMs = defaultTimeout(),
  ): Promise<T> {
    if (this.failure !== undefined) return Promise.reject(this.failure);
    timeoutMs = boundedByOperation(timeoutMs);
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(fault(SIDECAR_ERROR_TIMEOUT, `${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject, timer });
      try {
        this.socket.send(
          JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }),
        );
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        this.failAll(error);
        this.socket.close();
        reject(error);
      }
    });
  }

  waitFor(
    method: string,
    sessionId: string | undefined,
    predicate: (params: Record<string, unknown>) => boolean,
    timeoutMs: number,
  ): { promise: Promise<Record<string, unknown>>; cancel: () => void } {
    if (this.failure !== undefined) throw this.failure;
    timeoutMs = boundedByOperation(timeoutMs);
    let waiter: Waiter;
    const promise = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(waiter);
        reject(fault(SIDECAR_ERROR_TIMEOUT, `${method} timed out`));
      }, timeoutMs);
      waiter = { method, sessionId, predicate, resolve, reject, timer };
      this.waiters.add(waiter);
    });
    return {
      promise,
      cancel: () => {
        if (this.waiters.delete(waiter)) clearTimeout(waiter.timer);
      },
    };
  }

  private receive(raw: string): void {
    if (raw.length > maxMessageBytes || encoder.encode(raw).length > maxMessageBytes) {
      this.failAll(fault(SIDECAR_ERROR_LIMIT, "CDP message exceeds the browser runner limit"));
      this.socket.close();
      return;
    }
    let message: {
      id?: number;
      result?: unknown;
      error?: { message?: string };
      method?: string;
      params?: Record<string, unknown>;
      sessionId?: string;
    };
    try {
      message = JSON.parse(raw);
    } catch {
      this.failAll(new Error("Chromium sent malformed CDP JSON"));
      this.socket.close();
      return;
    }
    if (message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message ?? "CDP command failed"));
      else pending.resolve(message.result ?? {});
      return;
    }
    if (!message.method) return;
    for (const waiter of [...this.waiters]) {
      if (waiter.method !== message.method || waiter.sessionId !== message.sessionId) continue;
      let matches = false;
      try {
        matches = waiter.predicate(message.params ?? {});
      } catch (error) {
        this.waiters.delete(waiter);
        clearTimeout(waiter.timer);
        waiter.reject(error);
        continue;
      }
      if (!matches) continue;
      this.waiters.delete(waiter);
      clearTimeout(waiter.timer);
      waiter.resolve(message.params ?? {});
    }
  }

  private failAll(error: unknown): void {
    this.failure ??= error;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    for (const waiter of this.waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.waiters.clear();
  }
}
