// @generated from contracts/runner.kdl by //contracts/codegen:projector — do not edit.
export const PROTOCOL_VERSION = 1 as const;
export const RUNNER_MAX_FRAME_BYTES = 8392704 as const;
export const RUNNER_DEFAULT_VSOCK_PORT = 52 as const;
export const RUNNER_HEALTH_KIND = "agentos.health.v1" as const;
export const RUNNER_HEALTH_CONTRACT_DIGEST = "sha256:515a069b3ebe4d7e6fbb23496b4e71908ad2b5046b00345b3cfe833c4ea82339" as const;
export const RUNNER_INIT_OPERATION = "init" as const;
export const RUNNER_PREPARE_SNAPSHOT_OPERATION = "prepare-snapshot" as const;


const CTL_TEXT_ENCODER = new TextEncoder();
const CTL_TEXT_DECODER = new TextDecoder("utf-8", { fatal: true });

export class WireError extends Error { constructor(message: string) { super(message); this.name = "WireError"; } }
interface CtlCursor { bytes: Uint8Array; off: number }
function ctlNeed(cursor: CtlCursor, len: number): Uint8Array { const end = cursor.off + len; if (end > cursor.bytes.length) throw new WireError("truncated frame"); const out = cursor.bytes.subarray(cursor.off, end); cursor.off = end; return out; }
function ctlPutU8(out: number[], v: number): void { out.push(v & 0xff); }
function ctlPutU16(out: number[], v: number): void { out.push(v & 0xff, (v >>> 8) & 0xff); }
function ctlPutU32(out: number[], v: number): void { out.push(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff); }
function ctlPutI32(out: number[], v: number): void { ctlPutU32(out, v >>> 0); }
function ctlPutI64(out: number[], v: number): void { let x = BigInt(Math.trunc(v)); for (let i = 0; i < 8; i++) { out.push(Number((x >> BigInt(i * 8)) & 0xffn)); } }
function ctlPutBool(out: number[], v: boolean): void { out.push(v ? 1 : 0); }
function ctlPutBytes(out: number[], v: Uint8Array): void { ctlPutU32(out, v.length); for (const b of v) out.push(b); }
function ctlPutStr(out: number[], v: string): void { ctlPutBytes(out, CTL_TEXT_ENCODER.encode(v)); }
function ctlPutStrMap(out: number[], v: Record<string, string>): void { const entries = Object.entries(v).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0); ctlPutU32(out, entries.length); for (const [k, val] of entries) { ctlPutStr(out, k); ctlPutStr(out, val); } }
function ctlPutMessageList<T>(out: number[], values: readonly T[], encode: (msg: T) => Uint8Array): void { ctlPutU32(out, values.length); for (const value of values) ctlPutBytes(out, encode(value)); }
function ctlReadU8(cursor: CtlCursor): number { return ctlNeed(cursor, 1)[0]!; }
function ctlReadU16(cursor: CtlCursor): number { const b = ctlNeed(cursor, 2); return b[0]! | (b[1]! << 8); }
function ctlReadU32(cursor: CtlCursor): number { const b = ctlNeed(cursor, 4); return (b[0]! | (b[1]! << 8) | (b[2]! << 16) | (b[3]! << 24)) >>> 0; }
function ctlReadI32(cursor: CtlCursor): number { return ctlReadU32(cursor) | 0; }
function ctlReadI64(cursor: CtlCursor): number { const b = ctlNeed(cursor, 8); let x = 0n; for (let i = 0; i < 8; i++) x |= BigInt(b[i]!) << BigInt(i * 8); if ((x & (1n << 63n)) !== 0n) x -= 1n << 64n; return Number(x); }
function ctlReadBool(cursor: CtlCursor): boolean { const v = ctlReadU8(cursor); if (v === 0) return false; if (v === 1) return true; throw new WireError("invalid bool"); }
function ctlReadBytes(cursor: CtlCursor): Uint8Array { const len = ctlReadU32(cursor); return ctlNeed(cursor, len).slice(); }
function ctlReadStr(cursor: CtlCursor): string { try { return CTL_TEXT_DECODER.decode(ctlReadBytes(cursor)); } catch { throw new WireError("invalid utf-8"); } }
function ctlReadStrMap(cursor: CtlCursor): Record<string, string> { const n = ctlReadU32(cursor); if (n > Math.floor((cursor.bytes.length - cursor.off) / 8)) throw new WireError("truncated frame"); const out: Record<string, string> = {}; let prev: string | null = null; for (let i = 0; i < n; i++) { const k = ctlReadStr(cursor); if (prev !== null && prev >= k) throw new WireError("non-canonical strmap"); out[k] = ctlReadStr(cursor); prev = k; } return out; }

function ctlReadMessageList<T>(cursor: CtlCursor, decode: (bytes: Uint8Array) => T): T[] { const n = ctlReadU32(cursor); if (n > Math.floor((cursor.bytes.length - cursor.off) / 4)) throw new WireError("truncated frame"); const out: T[] = []; for (let i = 0; i < n; i++) out.push(decode(ctlReadBytes(cursor))); return out; }

export interface RunnerHello {
  protocol_version: number;
  agent: string;
  kind: string;
  version: number;
  contract_digest: string;
}
export const RUNNER_HELLO_MSG_ID = 1;
export const RUNNER_HELLO_VERSION = 1;
export function encodeRunnerHello(msg: RunnerHello): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, RUNNER_HELLO_MSG_ID);
  ctlPutU8(out, RUNNER_HELLO_VERSION);
  ctlPutU32(out, msg.protocol_version);
  ctlPutStr(out, msg.agent);
  ctlPutStr(out, msg.kind);
  ctlPutU32(out, msg.version);
  ctlPutStr(out, msg.contract_digest);
  return Uint8Array.from(out);
}
export function decodeRunnerHello(bytes: Uint8Array): RunnerHello {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== RUNNER_HELLO_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== RUNNER_HELLO_VERSION) throw new WireError("unsupported message version");
  const protocol_version = ctlReadU32(wire);
  const agent = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  const version = ctlReadU32(wire);
  const contract_digest = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    protocol_version,
    agent,
    kind,
    version,
    contract_digest,
  };
}

export interface RunnerRequest {
  request_id: string;
  kind: string;
  operation: string;
  body: Uint8Array;
  timeout_ms: number;
}
export const RUNNER_REQUEST_MSG_ID = 2;
export const RUNNER_REQUEST_VERSION = 1;
export function encodeRunnerRequest(msg: RunnerRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, RUNNER_REQUEST_MSG_ID);
  ctlPutU8(out, RUNNER_REQUEST_VERSION);
  ctlPutStr(out, msg.request_id);
  ctlPutStr(out, msg.kind);
  ctlPutStr(out, msg.operation);
  ctlPutBytes(out, msg.body);
  ctlPutI64(out, msg.timeout_ms);
  return Uint8Array.from(out);
}
export function decodeRunnerRequest(bytes: Uint8Array): RunnerRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== RUNNER_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== RUNNER_REQUEST_VERSION) throw new WireError("unsupported message version");
  const request_id = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  const operation = ctlReadStr(wire);
  const body = ctlReadBytes(wire);
  const timeout_ms = ctlReadI64(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    request_id,
    kind,
    operation,
    body,
    timeout_ms,
  };
}

export interface RunnerResponse {
  request_id: string;
  ok: boolean;
  body: Uint8Array;
  error_code?: string | null;
  error_message?: string | null;
}
export const RUNNER_RESPONSE_MSG_ID = 3;
export const RUNNER_RESPONSE_VERSION = 1;
export function encodeRunnerResponse(msg: RunnerResponse): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, RUNNER_RESPONSE_MSG_ID);
  ctlPutU8(out, RUNNER_RESPONSE_VERSION);
  ctlPutStr(out, msg.request_id);
  ctlPutBool(out, msg.ok);
  ctlPutBytes(out, msg.body);
  if (msg.error_code === undefined || msg.error_code === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.error_code);
  }
  if (msg.error_message === undefined || msg.error_message === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.error_message);
  }
  return Uint8Array.from(out);
}
export function decodeRunnerResponse(bytes: Uint8Array): RunnerResponse {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== RUNNER_RESPONSE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== RUNNER_RESPONSE_VERSION) throw new WireError("unsupported message version");
  const request_id = ctlReadStr(wire);
  const ok = ctlReadBool(wire);
  const body = ctlReadBytes(wire);
  let error_code: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: error_code = undefined; break;
    case 1: error_code = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let error_message: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: error_message = undefined; break;
    case 1: error_message = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    request_id,
    ok,
    body,
    error_code,
    error_message,
  };
}
