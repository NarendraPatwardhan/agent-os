// Host-side connection registry and HTTP credential injection.
//
// Guests may name a connection with `X-MC-Connection: integration.owner.name`, but they never see the
// secret. The host removes that marker at the egress boundary and applies the configured credential
// to the outbound request blob.

const CONNECTION_HEADER = "X-MC-Connection";

export type ConnectionCredential =
  | { kind: "none" }
  | { kind: "bearer"; token: string }
  | { kind: "header"; name: string; value: string }
  | { kind: "query"; name: string; value: string };

export class ConnectionRegistry {
  private readonly entries = new Map<string, ConnectionCredential>();

  insert(reference: string, credential: ConnectionCredential): this {
    validateReference(reference);
    validateCredential(credential);
    if (this.entries.has(reference)) throw new Error(`duplicate connection '${reference}'`);
    this.entries.set(reference, credential);
    return this;
  }

  bearer(reference: string, token: string): this {
    return this.insert(reference, { kind: "bearer", token });
  }

  injectHttpRequest(req: Uint8Array): Uint8Array | null {
    const parsed = parseBlob(req);
    if (!parsed) return null;
    const markerValues = parsed.headers.filter(([name]) => eqHeader(name, CONNECTION_HEADER));
    if (markerValues.length === 0) return req;
    if (markerValues.length > 1) return null;
    const reference = markerValues[0]![1];
    if (!validReference(reference)) return null;
    const credential = this.entries.get(reference);
    if (!credential) return null;

    const headers = parsed.headers.filter(([name]) => !eqHeader(name, CONNECTION_HEADER));
    let url = parsed.url;
    switch (credential.kind) {
      case "none":
        break;
      case "bearer":
        if (!addHeader(headers, "Authorization", `Bearer ${credential.token}`)) return null;
        break;
      case "header":
        if (!addHeader(headers, credential.name, credential.value)) return null;
        break;
      case "query":
        url = appendQuery(url, credential.name, credential.value);
        break;
    }
    return serializeRequest(parsed.method, url, headers, parsed.body);
  }
}

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
  if (!method || !url) return null;
  const headers: [string, string][] = [];
  for (let i = 1; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    const c = line.indexOf(":");
    if (c < 0) return null;
    headers.push([line.slice(0, c).trim(), line.slice(c + 1).trim()]);
  }
  return { method, url, headers, body };
}

function serializeRequest(
  method: string,
  url: string,
  headers: [string, string][],
  body: Uint8Array,
): Uint8Array {
  let head = `${method} ${url}\n`;
  for (const [name, value] of headers) head += `${name}: ${value}\n`;
  head += "\n";
  const headBytes = new TextEncoder().encode(head);
  const out = new Uint8Array(headBytes.length + body.length);
  out.set(headBytes);
  out.set(body, headBytes.length);
  return out;
}

function addHeader(headers: [string, string][], name: string, value: string): boolean {
  if (!validHeaderName(name) || !validSecret(value)) return false;
  if (headers.some(([existing]) => eqHeader(existing, name))) return false;
  headers.push([name, value]);
  return true;
}

function appendQuery(url: string, name: string, value: string): string {
  const hash = url.indexOf("#");
  const base = hash >= 0 ? url.slice(0, hash) : url;
  const fragment = hash >= 0 ? url.slice(hash) : "";
  const sep = base.includes("?") ? (base.endsWith("?") || base.endsWith("&") ? "" : "&") : "?";
  return `${base}${sep}${encodeURIComponent(name)}=${encodeURIComponent(value)}${fragment}`;
}

function validateCredential(credential: ConnectionCredential): void {
  switch (credential.kind) {
    case "none":
      return;
    case "bearer":
      if (!validSecret(credential.token)) throw new Error("invalid bearer token");
      return;
    case "header":
      if (!validHeaderName(credential.name) || !validSecret(credential.value)) {
        throw new Error("invalid header credential");
      }
      return;
    case "query":
      if (credential.name.length === 0 || hasControl(credential.name) || !validSecret(credential.value)) {
        throw new Error("invalid query credential");
      }
  }
}

function validateReference(reference: string): void {
  if (!validReference(reference)) throw new Error(`invalid connection reference '${reference}'`);
}

function validReference(reference: string): boolean {
  const parts = reference.split(".");
  return (
    parts.length === 3 &&
    safeSegment(parts[0]!) &&
    (parts[1] === "org" || parts[1] === "user") &&
    safeSegment(parts[2]!)
  );
}

function safeSegment(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/.test(value);
}

function validHeaderName(name: string): boolean {
  return /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/.test(name);
}

function validSecret(value: string): boolean {
  return value.length > 0 && !hasControl(value);
}

function hasControl(value: string): boolean {
  return /[\u0000-\u001f\u007f]/u.test(value);
}

function eqHeader(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}
