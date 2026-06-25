// Host-call capability: the TS host side of `mc_sys_host_call`. The kernel hands the host an opaque
// request blob (`name\0args`, from `mc-tool`); the host routes it to a registered handler and streams
// back a result. Poll-based, mirroring the net capability — and async-friendly, since tool handlers
// are async: `start` kicks off the handler, `poll` reports `0` until it resolves, then `body` streams
// the result. Default-deny (A9).

export interface HostCallCapability {
  /** Start a call; return an opaque handle >= 0, or -1 to refuse. */
  start(req: Uint8Array): number;
  /** `0` in flight, `1` ready, `-1` failed/unknown. */
  poll(handle: number): number;
  /** Result bytes into `buf`: `n > 0`, `0` = EOF, `-1` = error. */
  body(handle: number, buf: Uint8Array): number;
  close(handle: number): void;
}

/** Default: refuse every host call (no tools installed). */
export class DeniedHostCall implements HostCallCapability {
  start(): number {
    return -1;
  }
  poll(): number {
    return -1;
  }
  body(): number {
    return -1;
  }
  close(): void {}
}

/** A handler for a named tool: given the args string (typically JSON), return a result (text or
 *  bytes). May be async. */
export type ToolHandler = (args: string) => Promise<Uint8Array | string> | Uint8Array | string;

/** A binary-safe handler: given the request body (the bytes after `name\0`, verbatim — no UTF-8
 *  decode, no trailing-NUL trim), return a result. Used by host-backed mount drivers, whose WRITE op
 *  carries binary file content. */
export type RawToolHandler = (body: Uint8Array) => Promise<Uint8Array | string> | Uint8Array | string;

interface Slot {
  result?: Uint8Array;
  offset: number;
  failed: boolean;
  done: boolean;
}

/** A registry of named (possibly async) handlers — the host-call capability for the JS host, driven by
 *  `vm.tool` (UTF-8 `tools`) and `vm.mount` (binary-safe `raw` handlers, keyed by absolute mount
 *  path). */
export class MapHostCall implements HostCallCapability {
  private readonly tools = new Map<string, ToolHandler>();
  private readonly raw = new Map<string, RawToolHandler>();
  private readonly slots = new Map<number, Slot>();
  private next = 1;

  register(name: string, handler: ToolHandler): void {
    this.tools.set(name, handler);
  }
  /** Register a binary-safe handler (a host-backed mount, keyed by its absolute path). Checked before
   *  the UTF-8 `tools` map. */
  registerRaw(name: string, handler: RawToolHandler): void {
    this.raw.set(name, handler);
  }
  unregister(name: string): void {
    this.tools.delete(name);
    this.raw.delete(name);
  }
  has(name: string): boolean {
    return this.tools.has(name) || this.raw.has(name);
  }

  /** Allocate a slot and run `produce` (sync or async); the result streams back via `body` once it
   *  resolves. */
  private startSlot(produce: () => Promise<Uint8Array | string> | Uint8Array | string): number {
    const handle = this.next;
    this.next = this.next + 1 < 1 ? 1 : this.next + 1;
    const slot: Slot = { offset: 0, failed: false, done: false };
    this.slots.set(handle, slot);
    Promise.resolve()
      .then(produce)
      .then((res) => {
        slot.result = typeof res === "string" ? new TextEncoder().encode(res) : res;
        slot.done = true;
      })
      .catch(() => {
        slot.failed = true;
        slot.done = true;
      });
    return handle;
  }

  start(req: Uint8Array): number {
    // Mount drivers register binary-safe handlers keyed by absolute path; tools register UTF-8
    // handlers keyed by bare name. The two key spaces are disjoint (mount names start with `/`), so
    // check raw first — passing the body verbatim (no UTF-8 decode, no NUL-trim, since a binary WRITE
    // may end in 0x00).
    const rawNul = req.indexOf(0);
    const rawName = new TextDecoder().decode(rawNul < 0 ? req : req.subarray(0, rawNul));
    const rawHandler = this.raw.get(rawName);
    if (rawHandler) {
      const body = rawNul < 0 ? new Uint8Array(0) : req.subarray(rawNul + 1);
      return this.startSlot(() => rawHandler(body));
    }

    // argv blobs are NUL-terminated; trim trailing NUL(s) before splitting so the args string doesn't
    // carry a stray `\0` that would break JSON parsing.
    let trimEnd = req.length;
    while (trimEnd > 0 && req[trimEnd - 1] === 0) trimEnd--;
    req = req.subarray(0, trimEnd);
    const nul = req.indexOf(0);
    const name = new TextDecoder().decode(nul < 0 ? req : req.subarray(0, nul));
    const args = nul < 0 ? "" : new TextDecoder().decode(req.subarray(nul + 1));
    const handler = this.tools.get(name);
    if (!handler) return -1;
    return this.startSlot(() => handler(args));
  }

  poll(handle: number): number {
    const s = this.slots.get(handle);
    if (!s) return -1;
    if (s.failed) return -1;
    return s.done ? 1 : 0;
  }

  body(handle: number, buf: Uint8Array): number {
    const s = this.slots.get(handle);
    if (!s || s.failed || !s.result) return -1;
    const remaining = s.result.subarray(s.offset);
    const n = Math.min(remaining.length, buf.length);
    buf.set(remaining.subarray(0, n), 0);
    s.offset += n;
    return n;
  }

  close(handle: number): void {
    this.slots.delete(handle);
  }
}
