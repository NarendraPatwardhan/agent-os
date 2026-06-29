import { EAGAIN, EMSGSIZE } from "@mc/contracts/constants";
import { ConnectionRegistry } from "./connections.js";
import type { PreparedConnectionRequest } from "./connections.js";
import { ToolPolicySet } from "./policy.js";
import type { ToolPolicyRule } from "./policy.js";
import type { NetCapability } from "./types.js";

/** Flow-control mark for `wsSend` backpressure: accepted sends must fit wholly within the socket's
 *  own send window (`bufferedAmount + len <= mark`). Oversized messages fail permanently with
 *  `-EMSGSIZE`; retryable pressure reports `-EAGAIN`, so the kernel parks the guest's bytes in its
 *  own linear memory (B5) instead of growing host memory on the agent's behalf (A1). */
const WS_SEND_MARK = 1024 * 1024;

/** How long a `wsConnect` may sit in CONNECTING before the host gives up, closes the socket, and marks
 *  the slot closed — so a guest blocked on a never-opening socket eventually ERRORS (its `ws_send`
 *  returns -1, its `poll` reports the close) instead of parking forever. A real handshake completes in
 *  well under this; a socket still connecting after it is dead. Overridable for tests. */
const WS_CONNECT_DEADLINE_MS = 30_000;

/** The default: no network. Every call refuses with -1 (mirrors Rust `DeniedNet`). Denial surfaces to
 *  the agent as an ordinary fs/IO error. */
export class DeniedNet implements NetCapability {
  httpRequest(): number {
    return -1;
  }
  httpPoll(): number {
    return -1;
  }
  httpBody(): number {
    return -1;
  }
  httpClose(): void {}
  wsConnect(): number {
    return -1;
  }
  wsSend(): number {
    return -1;
  }
  /** A denied send errors immediately (wsSend → -1), so a parked write must NEVER block on a denied
   *  socket: report writable-to-error (1) so it wakes and surfaces the denial (mirrors Rust
   *  `DeniedNet::ws_ready`). */
  wsReady(): number {
    return 1;
  }
  wsRecv(): number {
    return -1;
  }
  wsClose(): void {}
}

interface HttpSlot {
  done: boolean;
  failed: boolean;
  head: Uint8Array;
  body: Uint8Array;
  bodyPos: number;
}

interface WsSlot {
  ws: WebSocket | null;
  open: boolean;
  closed: boolean;
  incoming: Uint8Array[];
  frontPos: number;
  /** The pending connect-deadline timer (cleared once the socket opens or closes). */
  deadline: ReturnType<typeof setTimeout> | null;
}

// fetch refuses to *set* these request headers; the runtime manages them.
const FORBIDDEN_REQ_HEADERS = new Set(["host", "content-length", "connection"]);

/** A non-allowlisted host's egress is referred here for an allow/deny decision. */
export type NetApprover = (
  host: string,
  url: string,
) => Promise<{ allow: boolean; remember?: "once" | "session" }>;

export interface ToolApprovalFacts {
  readonly kind: "tool_approval";
  readonly connection: string;
  readonly method: string;
  readonly url: string;
  readonly origin: string;
  readonly argsDigest?: string;
}

export type ToolApprover = (
  request: ToolApprovalFacts,
) => Promise<{ allow: boolean; remember?: "once" | "session" }>;

export interface HostNetOptions {
  /** Hosts allowed without prompting. `undefined` = no filtering (all allowed). */
  allowlist?: Set<string>;
  /** Consulted for a non-allowlisted host. Absent → deny (default-deny). */
  approver?: NetApprover;
  /** Host-only credentials keyed by `X-MC-Connection` markers in guest request blobs. */
  connections?: ConnectionRegistry;
  /** Host-side destructive-action approval for connection-marked HTTP egress. */
  toolApprover?: ToolApprover;
  /** Embedder-owned policy over connection/tool address patterns. */
  policies?: readonly ToolPolicyRule[];
}

/** Real network over `fetch` (HTTP) and `WebSocket` (WS) — the browser/Bun analogue of Rust `RealNet`
 *  (ureq + tungstenite). The host terminates TLS, so the kernel only ever sees plaintext: the kernel
 *  imports no socket or crypto surface (A4), so a browser host (which cannot open raw sockets) drives
 *  it unchanged. The poll-based bridge means a `fetch` is kicked off here and drained between ticks —
 *  no blocking. An optional allowlist + approver gate egress to non-allowlisted hosts (the
 *  `onPermission` seam, A9 default-deny): the slot simply stays "not done" until the decision lands, so
 *  the guest parks on `http_poll → 0` with no kernel change. */
export class HostNet implements NetCapability {
  private next = 1;
  private http = new Map<number, HttpSlot>();
  private ws = new Map<number, WsSlot>();
  /** Hosts remembered-for-session via `req.allow({ remember: "session" })`. */
  private readonly sessionAllow = new Set<string>();
  /** Destructive connection egress remembered-for-session by exact connection/method/url. */
  private readonly toolSessionAllow = new Set<string>();
  private readonly connections: ConnectionRegistry;
  private readonly policies: ToolPolicySet;

  constructor(private readonly opts: HostNetOptions = {}) {
    this.connections = opts.connections ?? new ConnectionRegistry();
    this.policies = new ToolPolicySet(opts.policies ?? []);
  }

  httpRequest(req: Uint8Array): number {
    const prepared = this.connections.prepareHttpRequest(req);
    if (!prepared) return -1;
    const parsed = prepared.kind === "unmarked" ? parseBlob(prepared.request) : null;
    if (prepared.kind === "unmarked" && !parsed) return -1;
    const slot: HttpSlot = {
      done: false,
      failed: false,
      head: new Uint8Array(0),
      body: new Uint8Array(0),
      bodyPos: 0,
    };
    const handle = this.next++;
    this.http.set(handle, slot);

    const failTransport = (): void => {
      slot.failed = true;
      slot.done = true;
    };
    const rejectConnection = (): void => {
      this.completeHttp(
        slot,
        403,
        "Forbidden",
        [["content-type", "application/json"]],
        new TextEncoder().encode(
          JSON.stringify({ ok: false, err: { code: "declined", message: "tool approval declined" } }),
        ),
      );
    };

    if (prepared.kind === "connection") {
      this.authorizeConnectionHttp(prepared.request)
        .then((allow) => {
          if (!allow) {
            rejectConnection();
            return;
          }
          const injected = prepared.request.inject();
          const injectedParsed = injected ? parseBlob(injected) : null;
          if (!injectedParsed) {
            failTransport();
            return;
          }
          this.fetchHttp(injectedParsed, slot);
        })
        .catch(rejectConnection);
    } else {
      this.gateNetworkHttp(parsed!, () => this.fetchHttp(parsed!, slot), failTransport);
    }

    return handle;
  }

  private fetchHttp(
    parsed: { method: string; url: string; headers: [string, string][]; body: Uint8Array },
    slot: HttpSlot,
  ): void {
    const method = parsed.method.toUpperCase();
    const init: RequestInit = {
      method: parsed.method,
      headers: parsed.headers.filter(([k]) => !FORBIDDEN_REQ_HEADERS.has(k.toLowerCase())),
    };
    if (parsed.body.length > 0 && method !== "GET" && method !== "HEAD") {
      // A fresh copy guarantees an `ArrayBuffer` (not `ArrayBufferLike`) backing, which `BodyInit`
      // requires.
      init.body = new Uint8Array(parsed.body);
    }

    fetch(parsed.url, init)
      .then(async (resp) => {
        // Serialize the head exactly like the Rust host:
        //   "<status> <reason>\r\n<Name: value>\r\n…\r\n\r\n"
        let head = `${resp.status} ${resp.statusText}\r\n`;
        resp.headers.forEach((value, name) => {
          head += `${name}: ${value}\r\n`;
        });
        head += "\r\n";
        const bodyBuf = new Uint8Array(await resp.arrayBuffer());
        slot.head = new TextEncoder().encode(head);
        slot.body = bodyBuf;
        slot.done = true;
      })
      .catch(() => {
        slot.failed = true;
        slot.done = true;
      });
  }

  private completeHttp(
    slot: HttpSlot,
    status: number,
    statusText: string,
    headers: [string, string][],
    body: Uint8Array,
  ): void {
    let head = `${status} ${statusText}\r\n`;
    for (const [name, value] of headers) head += `${name}: ${value}\r\n`;
    head += `content-length: ${body.length}\r\n\r\n`;
    slot.head = new TextEncoder().encode(head);
    slot.body = body;
    slot.done = true;
  }

  private gateNetworkHttp(
    parsed: { method: string; url: string; headers: [string, string][]; body: Uint8Array },
    allow: () => void,
    deny: () => void,
  ): void {
    let host = "";
    try {
      host = new URL(parsed.url).host;
    } catch {
      /* malformed URL → host stays empty (not allowlisted) */
    }
    const allowed =
      !this.opts.allowlist || this.opts.allowlist.has(host) || this.sessionAllow.has(host);
    if (allowed) {
      allow();
    } else if (this.opts.approver) {
      this.opts
        .approver(host, parsed.url)
        .then((d) => {
          if (d.allow) {
            if (d.remember === "session") this.sessionAllow.add(host);
            allow();
          } else {
            deny();
          }
        })
        .catch(deny);
    } else {
      deny(); // default-deny a non-allowlisted host with no approver
    }
  }

  private async authorizeConnectionHttp(req: PreparedConnectionRequest): Promise<boolean> {
    const policy = this.policies.resolve(req.policyAddress);
    if (policy === "block") return false;
    if (policy === "approve") return true;
    if (policy === null && !isDestructiveMethod(req.method)) return true;

    const key = toolRememberKey(req);
    if (this.toolSessionAllow.has(key)) return true;
    if (!this.opts.toolApprover) return false;

    const facts: ToolApprovalFacts = {
      kind: "tool_approval",
      connection: req.connection,
      method: req.method.toUpperCase(),
      url: req.url,
      origin: req.origin,
      ...(req.body.length > 0 ? { argsDigest: await sha256Hex(req.body) } : {}),
    };
    const decision = await this.opts.toolApprover(facts);
    if (!decision.allow) return false;
    if (decision.remember === "session") this.toolSessionAllow.add(key);
    return true;
  }

  httpPoll(handle: number, buf: Uint8Array): number {
    const s = this.http.get(handle);
    if (!s) return -1;
    if (!s.done) return 0;
    if (s.failed) return -1;
    const n = Math.min(s.head.length, buf.length);
    buf.set(s.head.subarray(0, n));
    return n;
  }

  httpBody(handle: number, buf: Uint8Array): number {
    const s = this.http.get(handle);
    if (!s) return -1;
    if (!s.done) return 0;
    if (s.failed) return -1;
    const remaining = s.body.length - s.bodyPos;
    if (remaining === 0) return 0; // EOF
    const n = Math.min(remaining, buf.length);
    buf.set(s.body.subarray(s.bodyPos, s.bodyPos + n));
    s.bodyPos += n;
    return n;
  }

  httpClose(handle: number): void {
    this.http.delete(handle);
  }

  wsConnect(url: string): number {
    const slot: WsSlot = {
      ws: null,
      open: false,
      closed: false,
      incoming: [],
      frontPos: 0,
      deadline: null,
    };
    const handle = this.next++;
    this.ws.set(handle, slot);

    const clearDeadline = (): void => {
      if (slot.deadline !== null) {
        clearTimeout(slot.deadline);
        slot.deadline = null;
      }
    };

    // Dial only after the egress is permitted. While pending (connecting), the slot stays
    // not-open/not-closed, so `wsSend` reports `-EAGAIN` and `wsReady` reports 0 — the guest's
    // write parks until the socket opens. The host queues NOTHING (the lie + unbounded host buffer this
    // replaces): the unsent message stays in the guest's own linear memory (A1/B5).
    const dial = (): void => {
      try {
        const sock = new WebSocket(url);
        sock.binaryType = "arraybuffer";
        slot.ws = sock;
        sock.onopen = () => {
          slot.open = true;
          clearDeadline();
        };
        sock.onmessage = (e: MessageEvent) => {
          const data =
            typeof e.data === "string"
              ? new TextEncoder().encode(e.data)
              : new Uint8Array(e.data as ArrayBuffer);
          slot.incoming.push(data);
        };
        sock.onclose = () => {
          slot.closed = true;
          clearDeadline();
        };
        sock.onerror = () => {
          slot.closed = true;
          clearDeadline();
        };
        // Connect deadline: a socket still CONNECTING after the window is dead — close it and mark the
        // slot closed so a guest blocked on it errors out instead of parking forever (the wake-to-error
        // the contract requires; without this a never-opening socket would `-EAGAIN` indefinitely).
        const ms = WS_CONNECT_DEADLINE_MS;
        const t = setTimeout(() => {
          if (!slot.open && !slot.closed) {
            slot.closed = true;
            try {
              sock.close();
            } catch {
              /* already closing */
            }
          }
        }, ms);
        // A pending deadline must not keep the event loop (or a test process) alive; bun/node Timers
        // expose `unref`, browsers return a bare number (no-op).
        (t as { unref?: () => void }).unref?.();
        slot.deadline = t;
      } catch {
        slot.closed = true;
      }
    };

    let host = "";
    try {
      host = new URL(url).host;
    } catch {
      /* malformed → not allowlisted */
    }
    const allowed =
      !this.opts.allowlist || this.opts.allowlist.has(host) || this.sessionAllow.has(host);
    if (allowed) {
      dial();
    } else if (this.opts.approver) {
      this.opts
        .approver(host, url)
        .then((d) => {
          if (d.allow) {
            if (d.remember === "session") this.sessionAllow.add(host);
            dial();
          } else {
            slot.closed = true;
          }
        })
        .catch(() => {
          slot.closed = true;
        });
    } else {
      slot.closed = true; // default-deny a non-allowlisted host with no approver
    }
    return handle;
  }

  wsSend(handle: number, data: Uint8Array): number {
    const s = this.ws.get(handle);
    if (!s || s.closed) return -1; // closed → the write errors out
    if (data.length > WS_SEND_MARK) return -EMSGSIZE; // permanent: it can never fit the window
    const ws = s.ws;
    // Still CONNECTING/not-open, or accepting this whole frame would cross the mark: would-block.
    // Because oversized messages failed above, every `-EAGAIN` is retryable once the socket opens or
    // the browser buffer drains; the host buffers nothing beyond the transport's bounded window (A1/B5).
    if (!ws || ws.readyState !== WebSocket.OPEN || ws.bufferedAmount + data.length > WS_SEND_MARK) {
      return -EAGAIN;
    }
    try {
      ws.send(data as Uint8Array<ArrayBuffer>);
    } catch {
      s.closed = true;
      return -1;
    }
    return data.length;
  }

  wsReady(handle: number): number {
    const s = this.ws.get(handle);
    // Unknown handle or closed → writable-to-error (1): a parked write must WAKE so its next `wsSend`
    // returns -1 (POSIX: a closed socket is write-ready). 0 would hang the guest forever.
    if (!s || s.closed) return 1;
    // Coarse readiness only: `mc_ws_ready` has no message size, so "some room below the mark" wakes a
    // writer, and `wsSend` remains the authority for whether that particular frame fits.
    return s.open && s.ws && s.ws.bufferedAmount < WS_SEND_MARK ? 1 : 0;
  }

  wsRecv(handle: number, buf: Uint8Array): number {
    const s = this.ws.get(handle);
    if (!s) return -1;
    const front = s.incoming[0];
    if (!front) return s.closed ? -1 : 0;
    const n = Math.min(front.length - s.frontPos, buf.length);
    buf.set(front.subarray(s.frontPos, s.frontPos + n));
    s.frontPos += n;
    if (s.frontPos >= front.length) {
      s.incoming.shift();
      s.frontPos = 0;
    }
    return n;
  }

  wsClose(handle: number): void {
    const s = this.ws.get(handle);
    if (!s) return;
    if (s.deadline !== null) {
      clearTimeout(s.deadline);
      s.deadline = null;
    }
    try {
      s.ws?.close();
    } catch {
      /* already closing */
    }
    s.closed = true;
  }
}

/** Parse the request blob `METHOD URL\n<headers>\n\n<body>` (mirrors Rust `parse_blob`). */
function parseBlob(
  req: Uint8Array,
): { method: string; url: string; headers: [string, string][]; body: Uint8Array } | null {
  let sep = -1;
  for (let i = 0; i + 1 < req.length; i++) {
    if (req[i] === 0x0a && req[i + 1] === 0x0a) {
      sep = i;
      break;
    }
  }
  if (sep < 0) return null;
  const head = new TextDecoder().decode(req.subarray(0, sep));
  const body = req.subarray(sep + 2).slice();
  const lines = head.split("\n");
  const first = lines[0] ?? "";
  const sp = first.indexOf(" ");
  if (sp < 0) return null;
  const method = first.slice(0, sp);
  const url = first.slice(sp + 1);
  const headers: [string, string][] = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    const c = line.indexOf(":");
    if (c >= 0) headers.push([line.slice(0, c).trim(), line.slice(c + 1).trim()]);
  }
  return { method, url, headers, body };
}

function isDestructiveMethod(method: string): boolean {
  switch (method.toUpperCase()) {
    case "POST":
    case "PUT":
    case "PATCH":
    case "DELETE":
      return true;
    default:
      return false;
  }
}

function toolRememberKey(req: PreparedConnectionRequest): string {
  return `${req.connection}\0${req.method.toUpperCase()}\0${req.url}`;
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
