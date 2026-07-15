// @generated from contracts/sidecar.kdl by //contracts/codegen:projector — do not edit.
export const PROTOCOL_VERSION = 1 as const;
export const SIDECAR_MAX_HOSTS = 16 as const;
export const SIDECAR_MAX_GRANTS = 32 as const;
export const SIDECAR_MAX_INSTANCES_PER_GRANT = 8 as const;
export const SIDECAR_MAX_INSTANCES_PER_VM = 32 as const;
export const SIDECAR_MAX_INFLIGHT_PER_INSTANCE = 16 as const;
export const SIDECAR_MAX_INFLIGHT_PER_VM = 64 as const;
export const SIDECAR_MAX_REQUEST_BYTES = 1048576 as const;
export const SIDECAR_MAX_RESULT_BYTES = 8388608 as const;
export const SIDECAR_MAX_NAME_BYTES = 64 as const;
export const SIDECAR_MAX_KIND_BYTES = 96 as const;
export const SIDECAR_MAX_DIGEST_BYTES = 96 as const;
export const SIDECAR_MAX_OPERATION_BYTES = 128 as const;
export const SIDECAR_MAX_IDEMPOTENCY_BYTES = 128 as const;
export const SIDECAR_WARNING_BUFFER = 64 as const;
export const SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS = 60000 as const;
export const SIDECAR_MAX_OPERATION_TIMEOUT_MS = 300000 as const;
export const SIDECAR_DEFAULT_LEASE_TTL_MS = 60000 as const;
export const SIDECAR_DEFAULT_RENEW_MS = 20000 as const;
export const SIDECAR_MIN_LEASE_TTL_MS = 100 as const;
export const SIDECAR_MAX_LEASE_TTL_MS = 300000 as const;
export const SIDECAR_MIN_RENEW_MS = 10 as const;
export const SIDECAR_MAX_RENEW_MS = 30000 as const;
export const SIDECAR_HOST_BINDING = "mc.sidecar" as const;
export const SIDECAR_ERROR_CANCELLED = "cancelled" as const;
export const SIDECAR_ERROR_CLOSING = "sidecar_closing" as const;
export const SIDECAR_ERROR_CONTRACT_MISMATCH = "sidecar_contract_mismatch" as const;
export const SIDECAR_ERROR_DETACHED = "sidecar_detached" as const;
export const SIDECAR_ERROR_GRANT_EXISTS = "sidecar_grant_exists" as const;
export const SIDECAR_ERROR_GRANT_MISSING = "sidecar_grant_missing" as const;
export const SIDECAR_ERROR_HOST_MISSING = "sidecar_host_missing" as const;
export const SIDECAR_ERROR_IDEMPOTENCY_CONFLICT = "sidecar_idempotency_conflict" as const;
export const SIDECAR_ERROR_IN_USE = "sidecar_in_use" as const;
export const SIDECAR_ERROR_INVALID_REQUEST = "sidecar_invalid_request" as const;
export const SIDECAR_ERROR_LIMIT = "sidecar_limit" as const;
export const SIDECAR_ERROR_NOT_FOUND = "sidecar_not_found" as const;
export const SIDECAR_ERROR_NOT_READY = "sidecar_not_ready" as const;
export const SIDECAR_ERROR_PERMISSION_DENIED = "sidecar_permission_denied" as const;
export const SIDECAR_ERROR_PROVIDER_FAILED = "sidecar_provider_failed" as const;
export const SIDECAR_ERROR_SCOPE_MISSING = "sidecar_scope_missing" as const;
export const SIDECAR_ERROR_STALE_GENERATION = "sidecar_stale_generation" as const;
export const SIDECAR_ERROR_TIMEOUT = "timeout" as const;
export const SIDECAR_ERROR_UNAVAILABLE = "sidecar_unavailable" as const;
export const SIDECAR_ERROR_UNSUPPORTED_FORK_POLICY = "sidecar_unsupported_fork_policy" as const;
export const SIDECAR_WARNING_FORK_OMITTED = "sidecar_fork_omitted" as const;
export const SIDECAR_STATE_ALLOCATING = 1 as const;
export const SIDECAR_STATE_STARTING = 2 as const;
export const SIDECAR_STATE_READY = 3 as const;
export const SIDECAR_STATE_SUSPENDED = 4 as const;
export const SIDECAR_STATE_FAILED = 5 as const;
export const SIDECAR_STATE_CLOSING = 6 as const;
export const SIDECAR_STATE_CLOSED = 7 as const;
export const SIDECAR_STATE_DETACHED = 8 as const;
export const SIDECAR_FORK_OMIT = 1 as const;
export const SIDECAR_FORK_CLONE = 2 as const;


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

export interface SidecarString {
  value: string;
}
export const SIDECAR_STRING_MSG_ID = 1;
export const SIDECAR_STRING_VERSION = 1;
export function encodeSidecarString(msg: SidecarString): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_STRING_MSG_ID);
  ctlPutU8(out, SIDECAR_STRING_VERSION);
  ctlPutStr(out, msg.value);
  return Uint8Array.from(out);
}
export function decodeSidecarString(bytes: Uint8Array): SidecarString {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_STRING_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_STRING_VERSION) throw new WireError("unsupported message version");
  const value = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    value,
  };
}

export interface SidecarStrings {
  items: SidecarString[];
}
export const SIDECAR_STRINGS_MSG_ID = 2;
export const SIDECAR_STRINGS_VERSION = 1;
export function encodeSidecarStrings(msg: SidecarStrings): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_STRINGS_MSG_ID);
  ctlPutU8(out, SIDECAR_STRINGS_VERSION);
  ctlPutMessageList(out, msg.items, encodeSidecarString);
  return Uint8Array.from(out);
}
export function decodeSidecarStrings(bytes: Uint8Array): SidecarStrings {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_STRINGS_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_STRINGS_VERSION) throw new WireError("unsupported message version");
  const items = ctlReadMessageList(wire, decodeSidecarString);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    items,
  };
}

export interface SidecarGrant {
  name: string;
  kind: string;
  version: number;
  contract_digest: string;
  guest: boolean;
  max_instances: number;
  fork_policy: number;
  config: Uint8Array;
}
export const SIDECAR_GRANT_MSG_ID = 3;
export const SIDECAR_GRANT_VERSION = 1;
export function encodeSidecarGrant(msg: SidecarGrant): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_GRANT_MSG_ID);
  ctlPutU8(out, SIDECAR_GRANT_VERSION);
  ctlPutStr(out, msg.name);
  ctlPutStr(out, msg.kind);
  ctlPutU32(out, msg.version);
  ctlPutStr(out, msg.contract_digest);
  ctlPutBool(out, msg.guest);
  ctlPutU32(out, msg.max_instances);
  ctlPutU32(out, msg.fork_policy);
  ctlPutBytes(out, msg.config);
  return Uint8Array.from(out);
}
export function decodeSidecarGrant(bytes: Uint8Array): SidecarGrant {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_GRANT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_GRANT_VERSION) throw new WireError("unsupported message version");
  const name = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  const version = ctlReadU32(wire);
  const contract_digest = ctlReadStr(wire);
  const guest = ctlReadBool(wire);
  const max_instances = ctlReadU32(wire);
  const fork_policy = ctlReadU32(wire);
  const config = ctlReadBytes(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    name,
    kind,
    version,
    contract_digest,
    guest,
    max_instances,
    fork_policy,
    config,
  };
}

export interface SidecarCapability {
  kind: string;
  version: number;
  contract_digest: string;
  placements: SidecarStrings;
  fork_policy: number;
  max_instances_per_vm: number;
}
export const SIDECAR_CAPABILITY_MSG_ID = 4;
export const SIDECAR_CAPABILITY_VERSION = 1;
export function encodeSidecarCapability(msg: SidecarCapability): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_CAPABILITY_MSG_ID);
  ctlPutU8(out, SIDECAR_CAPABILITY_VERSION);
  ctlPutStr(out, msg.kind);
  ctlPutU32(out, msg.version);
  ctlPutStr(out, msg.contract_digest);
  ctlPutBytes(out, encodeSidecarStrings(msg.placements));
  ctlPutU32(out, msg.fork_policy);
  ctlPutU32(out, msg.max_instances_per_vm);
  return Uint8Array.from(out);
}
export function decodeSidecarCapability(bytes: Uint8Array): SidecarCapability {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_CAPABILITY_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_CAPABILITY_VERSION) throw new WireError("unsupported message version");
  const kind = ctlReadStr(wire);
  const version = ctlReadU32(wire);
  const contract_digest = ctlReadStr(wire);
  const placements = decodeSidecarStrings(ctlReadBytes(wire));
  const fork_policy = ctlReadU32(wire);
  const max_instances_per_vm = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    kind,
    version,
    contract_digest,
    placements,
    fork_policy,
    max_instances_per_vm,
  };
}

export interface SidecarInstance {
  id: string;
  grant: string;
  kind: string;
  generation: number;
  state: number;
  created_at_ms: number;
  expires_at_ms: number;
  metadata: Uint8Array;
}
export const SIDECAR_INSTANCE_MSG_ID = 5;
export const SIDECAR_INSTANCE_VERSION = 1;
export function encodeSidecarInstance(msg: SidecarInstance): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_INSTANCE_MSG_ID);
  ctlPutU8(out, SIDECAR_INSTANCE_VERSION);
  ctlPutStr(out, msg.id);
  ctlPutStr(out, msg.grant);
  ctlPutStr(out, msg.kind);
  ctlPutU32(out, msg.generation);
  ctlPutU32(out, msg.state);
  ctlPutI64(out, msg.created_at_ms);
  ctlPutI64(out, msg.expires_at_ms);
  ctlPutBytes(out, msg.metadata);
  return Uint8Array.from(out);
}
export function decodeSidecarInstance(bytes: Uint8Array): SidecarInstance {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_INSTANCE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_INSTANCE_VERSION) throw new WireError("unsupported message version");
  const id = ctlReadStr(wire);
  const grant = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  const generation = ctlReadU32(wire);
  const state = ctlReadU32(wire);
  const created_at_ms = ctlReadI64(wire);
  const expires_at_ms = ctlReadI64(wire);
  const metadata = ctlReadBytes(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    id,
    grant,
    kind,
    generation,
    state,
    created_at_ms,
    expires_at_ms,
    metadata,
  };
}

export interface SidecarInstances {
  items: SidecarInstance[];
}
export const SIDECAR_INSTANCES_MSG_ID = 6;
export const SIDECAR_INSTANCES_VERSION = 1;
export function encodeSidecarInstances(msg: SidecarInstances): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_INSTANCES_MSG_ID);
  ctlPutU8(out, SIDECAR_INSTANCES_VERSION);
  ctlPutMessageList(out, msg.items, encodeSidecarInstance);
  return Uint8Array.from(out);
}
export function decodeSidecarInstances(bytes: Uint8Array): SidecarInstances {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_INSTANCES_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_INSTANCES_VERSION) throw new WireError("unsupported message version");
  const items = ctlReadMessageList(wire, decodeSidecarInstance);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    items,
  };
}

export interface SidecarCreate {
  grant: string;
  kind: string;
  body: Uint8Array;
  idempotency_key: string;
  timeout_ms: number;
}
export const SIDECAR_CREATE_MSG_ID = 7;
export const SIDECAR_CREATE_VERSION = 1;
export function encodeSidecarCreate(msg: SidecarCreate): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_CREATE_MSG_ID);
  ctlPutU8(out, SIDECAR_CREATE_VERSION);
  ctlPutStr(out, msg.grant);
  ctlPutStr(out, msg.kind);
  ctlPutBytes(out, msg.body);
  ctlPutStr(out, msg.idempotency_key);
  ctlPutI64(out, msg.timeout_ms);
  return Uint8Array.from(out);
}
export function decodeSidecarCreate(bytes: Uint8Array): SidecarCreate {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_CREATE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_CREATE_VERSION) throw new WireError("unsupported message version");
  const grant = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  const body = ctlReadBytes(wire);
  const idempotency_key = ctlReadStr(wire);
  const timeout_ms = ctlReadI64(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    grant,
    kind,
    body,
    idempotency_key,
    timeout_ms,
  };
}

export interface SidecarCall {
  id: string;
  generation: number;
  grant: string;
  kind: string;
  operation: string;
  body: Uint8Array;
  idempotency_key?: string | null;
  timeout_ms: number;
}
export const SIDECAR_CALL_MSG_ID = 8;
export const SIDECAR_CALL_VERSION = 1;
export function encodeSidecarCall(msg: SidecarCall): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_CALL_MSG_ID);
  ctlPutU8(out, SIDECAR_CALL_VERSION);
  ctlPutStr(out, msg.id);
  ctlPutU32(out, msg.generation);
  ctlPutStr(out, msg.grant);
  ctlPutStr(out, msg.kind);
  ctlPutStr(out, msg.operation);
  ctlPutBytes(out, msg.body);
  if (msg.idempotency_key === undefined || msg.idempotency_key === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.idempotency_key);
  }
  ctlPutI64(out, msg.timeout_ms);
  return Uint8Array.from(out);
}
export function decodeSidecarCall(bytes: Uint8Array): SidecarCall {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_CALL_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_CALL_VERSION) throw new WireError("unsupported message version");
  const id = ctlReadStr(wire);
  const generation = ctlReadU32(wire);
  const grant = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  const operation = ctlReadStr(wire);
  const body = ctlReadBytes(wire);
  let idempotency_key: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: idempotency_key = undefined; break;
    case 1: idempotency_key = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const timeout_ms = ctlReadI64(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    id,
    generation,
    grant,
    kind,
    operation,
    body,
    idempotency_key,
    timeout_ms,
  };
}

export interface SidecarError {
  code: string;
  message: string;
  retryable: boolean;
  details?: Uint8Array | null;
}
export const SIDECAR_ERROR_MSG_ID = 9;
export const SIDECAR_ERROR_VERSION = 1;
export function encodeSidecarError(msg: SidecarError): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_ERROR_MSG_ID);
  ctlPutU8(out, SIDECAR_ERROR_VERSION);
  ctlPutStr(out, msg.code);
  ctlPutStr(out, msg.message);
  ctlPutBool(out, msg.retryable);
  if (msg.details === undefined || msg.details === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.details);
  }
  return Uint8Array.from(out);
}
export function decodeSidecarError(bytes: Uint8Array): SidecarError {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_ERROR_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_ERROR_VERSION) throw new WireError("unsupported message version");
  const code = ctlReadStr(wire);
  const message = ctlReadStr(wire);
  const retryable = ctlReadBool(wire);
  let details: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: details = undefined; break;
    case 1: details = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    code,
    message,
    retryable,
    details,
  };
}

export interface SidecarResult {
  ok: boolean;
  body: Uint8Array;
  error?: SidecarError | null;
}
export const SIDECAR_RESULT_MSG_ID = 10;
export const SIDECAR_RESULT_VERSION = 1;
export function encodeSidecarResult(msg: SidecarResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_RESULT_MSG_ID);
  ctlPutU8(out, SIDECAR_RESULT_VERSION);
  ctlPutBool(out, msg.ok);
  ctlPutBytes(out, msg.body);
  if (msg.error === undefined || msg.error === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeSidecarError(msg.error));
  }
  return Uint8Array.from(out);
}
export function decodeSidecarResult(bytes: Uint8Array): SidecarResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_RESULT_VERSION) throw new WireError("unsupported message version");
  const ok = ctlReadBool(wire);
  const body = ctlReadBytes(wire);
  let error: SidecarError | undefined;
  switch (ctlReadU8(wire)) {
    case 0: error = undefined; break;
    case 1: error = decodeSidecarError(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    ok,
    body,
    error,
  };
}

export interface SidecarWarning {
  code: string;
  message: string;
  kind?: string | null;
  grant?: string | null;
  id?: string | null;
}
export const SIDECAR_WARNING_MSG_ID = 11;
export const SIDECAR_WARNING_VERSION = 1;
export function encodeSidecarWarning(msg: SidecarWarning): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_WARNING_MSG_ID);
  ctlPutU8(out, SIDECAR_WARNING_VERSION);
  ctlPutStr(out, msg.code);
  ctlPutStr(out, msg.message);
  if (msg.kind === undefined || msg.kind === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.kind);
  }
  if (msg.grant === undefined || msg.grant === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.grant);
  }
  if (msg.id === undefined || msg.id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.id);
  }
  return Uint8Array.from(out);
}
export function decodeSidecarWarning(bytes: Uint8Array): SidecarWarning {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_WARNING_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_WARNING_VERSION) throw new WireError("unsupported message version");
  const code = ctlReadStr(wire);
  const message = ctlReadStr(wire);
  let kind: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: kind = undefined; break;
    case 1: kind = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let grant: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: grant = undefined; break;
    case 1: grant = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: id = undefined; break;
    case 1: id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    code,
    message,
    kind,
    grant,
    id,
  };
}

export interface SidecarDelete {
  id: string;
  generation: number;
  grant: string;
  kind: string;
}
export const SIDECAR_DELETE_MSG_ID = 12;
export const SIDECAR_DELETE_VERSION = 1;
export function encodeSidecarDelete(msg: SidecarDelete): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_DELETE_MSG_ID);
  ctlPutU8(out, SIDECAR_DELETE_VERSION);
  ctlPutStr(out, msg.id);
  ctlPutU32(out, msg.generation);
  ctlPutStr(out, msg.grant);
  ctlPutStr(out, msg.kind);
  return Uint8Array.from(out);
}
export function decodeSidecarDelete(bytes: Uint8Array): SidecarDelete {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_DELETE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_DELETE_VERSION) throw new WireError("unsupported message version");
  const id = ctlReadStr(wire);
  const generation = ctlReadU32(wire);
  const grant = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    id,
    generation,
    grant,
    kind,
  };
}

export interface SidecarGet {
  id: string;
  generation: number;
  grant: string;
  kind: string;
}
export const SIDECAR_GET_MSG_ID = 13;
export const SIDECAR_GET_VERSION = 1;
export function encodeSidecarGet(msg: SidecarGet): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_GET_MSG_ID);
  ctlPutU8(out, SIDECAR_GET_VERSION);
  ctlPutStr(out, msg.id);
  ctlPutU32(out, msg.generation);
  ctlPutStr(out, msg.grant);
  ctlPutStr(out, msg.kind);
  return Uint8Array.from(out);
}
export function decodeSidecarGet(bytes: Uint8Array): SidecarGet {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_GET_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_GET_VERSION) throw new WireError("unsupported message version");
  const id = ctlReadStr(wire);
  const generation = ctlReadU32(wire);
  const grant = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    id,
    generation,
    grant,
    kind,
  };
}

export interface SidecarList {
  grant: string;
  kind: string;
}
export const SIDECAR_LIST_MSG_ID = 14;
export const SIDECAR_LIST_VERSION = 1;
export function encodeSidecarList(msg: SidecarList): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIDECAR_LIST_MSG_ID);
  ctlPutU8(out, SIDECAR_LIST_VERSION);
  ctlPutStr(out, msg.grant);
  ctlPutStr(out, msg.kind);
  return Uint8Array.from(out);
}
export function decodeSidecarList(bytes: Uint8Array): SidecarList {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIDECAR_LIST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIDECAR_LIST_VERSION) throw new WireError("unsupported message version");
  const grant = ctlReadStr(wire);
  const kind = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    grant,
    kind,
  };
}
