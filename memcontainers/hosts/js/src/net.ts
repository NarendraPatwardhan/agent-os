import type { NetCapability } from "./types.js";

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
  outgoing: Uint8Array[];
  incoming: Uint8Array[];
  frontPos: number;
}

// fetch refuses to *set* these request headers; the runtime manages them.
const FORBIDDEN_REQ_HEADERS = new Set(["host", "content-length", "connection"]);

/** A non-allowlisted host's egress is referred here for an allow/deny decision. */
export type NetApprover = (
  host: string,
  url: string,
) => Promise<{ allow: boolean; remember?: "once" | "session" }>;

export interface HostNetOptions {
  /** Hosts allowed without prompting. `undefined` = no filtering (all allowed). */
  allowlist?: Set<string>;
  /** Consulted for a non-allowlisted host. Absent → deny (default-deny). */
  approver?: NetApprover;
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

  constructor(private readonly opts: HostNetOptions = {}) {}

  httpRequest(req: Uint8Array): number {
    const parsed = parseBlob(req);
    if (!parsed) return -1;
    const { method, url, headers, body } = parsed;
    const slot: HttpSlot = {
      done: false,
      failed: false,
      head: new Uint8Array(0),
      body: new Uint8Array(0),
      bodyPos: 0,
    };
    const handle = this.next++;
    this.http.set(handle, slot);

    const init: RequestInit = {
      method,
      headers: headers.filter(([k]) => !FORBIDDEN_REQ_HEADERS.has(k.toLowerCase())),
    };
    if (body.length > 0 && method !== "GET" && method !== "HEAD") {
      // A fresh copy guarantees an `ArrayBuffer` (not `ArrayBufferLike`) backing, which `BodyInit`
      // requires.
      init.body = new Uint8Array(body);
    }

    const doFetch = (): void => {
      fetch(url, init)
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
    };
    const deny = (): void => {
      slot.failed = true;
      slot.done = true;
    };

    let host = "";
    try {
      host = new URL(url).host;
    } catch {
      /* malformed URL → host stays empty (not allowlisted) */
    }
    const allowed =
      !this.opts.allowlist || this.opts.allowlist.has(host) || this.sessionAllow.has(host);
    if (allowed) {
      doFetch();
    } else if (this.opts.approver) {
      this.opts
        .approver(host, url)
        .then((d) => {
          if (d.allow) {
            if (d.remember === "session") this.sessionAllow.add(host);
            doFetch();
          } else {
            deny();
          }
        })
        .catch(deny);
    } else {
      deny(); // default-deny a non-allowlisted host with no approver
    }

    return handle;
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
      outgoing: [],
      incoming: [],
      frontPos: 0,
    };
    const handle = this.next++;
    this.ws.set(handle, slot);

    // Dial only after the egress is permitted. While pending, the slot stays not-open/not-closed, so
    // `ws_recv` reports 0 and the guest waits.
    const dial = (): void => {
      try {
        const sock = new WebSocket(url);
        sock.binaryType = "arraybuffer";
        slot.ws = sock;
        sock.onopen = () => {
          slot.open = true;
          for (const msg of slot.outgoing) sock.send(msg as Uint8Array<ArrayBuffer>);
          slot.outgoing = [];
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
        };
        sock.onerror = () => {
          slot.closed = true;
        };
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
    if (!s || s.closed) return -1;
    if (s.open && s.ws) {
      try {
        s.ws.send(data as Uint8Array<ArrayBuffer>);
      } catch {
        return -1;
      }
    } else {
      // Not OPEN yet: queue until the socket flushes on `onopen` (matches the wasmtime host, which has
      // no async pre-open window). Bounding this buffer is a kernel/contract concern, not the host's —
      // see TODO.md §1.
      s.outgoing.push(data.slice());
    }
    return data.length;
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
