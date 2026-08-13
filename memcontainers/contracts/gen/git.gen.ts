// @generated from contracts/git.kdl by //contracts/codegen:projector — do not edit.
export const PROTOCOL_VERSION = 1 as const;
export const REQUEST_MAGIC = "AOGQ" as const;
export const RESPONSE_MAGIC = "AOGR" as const;
export const PROTOCOL_MINOR = 0 as const;
export const BACKEND_BROWSER = 1 as const;
export const BACKEND_NATIVE = 2 as const;
export const CAPABILITY_CORE = 1 as const;
export const ENVELOPE_HEADER_BYTES = 20 as const;
export const MAX_FRAME_BYTES = 1048576 as const;
export const MAX_FIELD_BYTES = 262144 as const;
export const MAX_PATH_BYTES = 4096 as const;
export const MAX_REF_BYTES = 1024 as const;
export const MAX_HANDLES = 4096 as const;
export const MAX_PACK_BYTES = 67108864 as const;
export const MAX_PACK_OBJECTS = 1000000 as const;
export const MAX_RESULT_BYTES = 16777216 as const;
export const OP_ENGINE_DESCRIBE = 1 as const;
export const OP_SESSION_OPEN = 2 as const;
export const OP_SESSION_CLOSE = 3 as const;
export const OP_REPOSITORY_INIT = 16 as const;
export const OP_REPOSITORY_OPEN = 17 as const;
export const OP_FILE_STAT = 256 as const;
export const OP_FILE_READ = 257 as const;
export const OP_FILE_WRITE = 258 as const;
export const OP_FILE_REMOVE = 259 as const;
export const OP_FILE_RENAME = 260 as const;
export const OP_FILE_READDIR = 261 as const;
export const OP_STATUS = 272 as const;
export const OP_ADD = 273 as const;
export const OP_REMOVE = 274 as const;
export const OP_COMMIT = 275 as const;
export const OP_LOG = 276 as const;
export const OP_RESOLVE_REVISION = 277 as const;
export const OP_DIFF = 278 as const;
export const OP_SHOW = 279 as const;
export const OP_CHECKOUT = 280 as const;
export const OP_RESET = 281 as const;
export const OP_BRANCH = 282 as const;
export const OP_TAG = 283 as const;
export const OP_CONFIG = 284 as const;
export const OP_REMOTE_METADATA = 285 as const;
export const OP_IGNORE_QUERY = 286 as const;
export const OP_SPARSE = 287 as const;
export const OP_SUBMODULE = 288 as const;
export const OP_OBJECT = 512 as const;
export const OP_REF = 528 as const;
export const OP_REF_TRANSACTION = 529 as const;
export const OP_PACK_IMPORT = 544 as const;
export const OP_PACK_BUILD = 545 as const;
export const OP_SHALLOW = 546 as const;
export const OP_MOUNT = 768 as const;
export const OP_STREAM = 784 as const;
export const OP_CLONE = 1024 as const;
export const OP_FETCH = 1025 as const;
export const OP_PULL = 1026 as const;
export const OP_PUSH = 1027 as const;
export const OP_HTTP_EFFECT = 1040 as const;
export const OP_REMOTE_CANCEL = 1041 as const;
export const OP_CHECKPOINT = 1280 as const;
export const OP_RESTORE = 1281 as const;
export const ACTION_LIST = 1 as const;
export const ACTION_GET = 2 as const;
export const ACTION_CREATE = 3 as const;
export const ACTION_UPDATE = 4 as const;
export const ACTION_DELETE = 5 as const;
export const ACTION_BEGIN = 6 as const;
export const ACTION_WRITE = 7 as const;
export const ACTION_FINISH = 8 as const;
export const ACTION_ABORT = 9 as const;
export const ACTION_READ = 10 as const;
export const ACTION_CLOSE = 11 as const;
export const HTTP_RESPONSE_BEGIN = 1 as const;
export const HTTP_RESPONSE_CHUNK = 2 as const;
export const HTTP_RESPONSE_END = 3 as const;
export const HTTP_RESPONSE_ABORT = 4 as const;
export const STREAM_READ = 1 as const;
export const STREAM_WRITE = 2 as const;
export const STREAM_FINISH = 3 as const;
export const STREAM_ABORT = 4 as const;
export const STREAM_CLOSE = 5 as const;
export const MOUNT_ATTACH = 1 as const;
export const MOUNT_DETACH = 2 as const;
export const MOUNT_STAT = 3 as const;
export const MOUNT_READ = 4 as const;
export const MOUNT_WRITE = 5 as const;
export const MOUNT_CREATE = 6 as const;
export const MOUNT_REMOVE = 7 as const;
export const MOUNT_RENAME = 8 as const;
export const MOUNT_READDIR = 9 as const;
export const MOUNT_CHMOD = 10 as const;
export const RESET_SOFT = 1 as const;
export const RESET_MIXED = 2 as const;
export const RESET_HARD = 3 as const;
export const RESET_MERGE = 4 as const;
export const STATUS_OK = 0 as const;
export const STATUS_EFFECT = 1 as const;
export const STATUS_ERROR = 2 as const;
export const RETRY_NEVER = 0 as const;
export const RETRY_AFTER_INPUT = 1 as const;
export const RETRY_AFTER_REFRESH = 2 as const;
export const RETRY_TRANSIENT_HOST = 3 as const;
export const ERROR_PROTOCOL = 1 as const;
export const ERROR_USAGE = 2 as const;
export const ERROR_PATH = 3 as const;
export const ERROR_REPOSITORY = 4 as const;
export const ERROR_OBJECT = 5 as const;
export const ERROR_REFERENCE = 6 as const;
export const ERROR_INDEX = 7 as const;
export const ERROR_WORKTREE = 8 as const;
export const ERROR_PACK = 9 as const;
export const ERROR_REMOTE = 10 as const;
export const ERROR_TRANSPORT_EFFECT = 11 as const;
export const ERROR_PERSISTENCE = 12 as const;
export const ERROR_LIMIT = 13 as const;
export const ERROR_CANCELLED = 14 as const;
export const ERROR_INTERNAL = 15 as const;
export const ERROR_CODE_INVALID = 1 as const;
export const ERROR_CODE_MISSING = 2 as const;
export const ERROR_CODE_EXISTS = 3 as const;
export const ERROR_CODE_NOT_DIRECTORY = 4 as const;
export const ERROR_CODE_IS_DIRECTORY = 5 as const;
export const ERROR_CODE_NOT_EMPTY = 6 as const;
export const ERROR_CODE_DENIED = 7 as const;
export const ERROR_CODE_STALE = 8 as const;
export const ERROR_CODE_CONFLICT = 9 as const;


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

export interface SessionConfig {
  backend: number;
  read_only: boolean;
  root: string;
  restore?: Uint8Array | null;
}
export const SESSION_CONFIG_MSG_ID = 1;
export const SESSION_CONFIG_VERSION = 1;
export function encodeSessionConfig(msg: SessionConfig): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SESSION_CONFIG_MSG_ID);
  ctlPutU8(out, SESSION_CONFIG_VERSION);
  ctlPutU16(out, msg.backend);
  ctlPutBool(out, msg.read_only);
  ctlPutStr(out, msg.root);
  if (msg.restore === undefined || msg.restore === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.restore);
  }
  return Uint8Array.from(out);
}
export function decodeSessionConfig(bytes: Uint8Array): SessionConfig {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SESSION_CONFIG_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SESSION_CONFIG_VERSION) throw new WireError("unsupported message version");
  const decoded_backend = ctlReadU16(wire);
  const decoded_read_only = ctlReadBool(wire);
  const decoded_root = ctlReadStr(wire);
  let decoded_restore: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_restore = undefined; break;
    case 1: decoded_restore = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    backend: decoded_backend,
    read_only: decoded_read_only,
    root: decoded_root,
    restore: decoded_restore,
  };
}

export interface EngineDescription {
  abi_major: number;
  abi_minor: number;
  build_id: string;
  gitz_commit: string;
  backend: number;
  capabilities_low: number;
  capabilities_high: number;
  max_frame_bytes: number;
  max_pack_bytes: number;
  max_handles: number;
}
export const ENGINE_DESCRIPTION_MSG_ID = 2;
export const ENGINE_DESCRIPTION_VERSION = 1;
export function encodeEngineDescription(msg: EngineDescription): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, ENGINE_DESCRIPTION_MSG_ID);
  ctlPutU8(out, ENGINE_DESCRIPTION_VERSION);
  ctlPutU16(out, msg.abi_major);
  ctlPutU16(out, msg.abi_minor);
  ctlPutStr(out, msg.build_id);
  ctlPutStr(out, msg.gitz_commit);
  ctlPutU16(out, msg.backend);
  ctlPutU32(out, msg.capabilities_low);
  ctlPutU32(out, msg.capabilities_high);
  ctlPutU32(out, msg.max_frame_bytes);
  ctlPutU32(out, msg.max_pack_bytes);
  ctlPutU32(out, msg.max_handles);
  return Uint8Array.from(out);
}
export function decodeEngineDescription(bytes: Uint8Array): EngineDescription {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== ENGINE_DESCRIPTION_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== ENGINE_DESCRIPTION_VERSION) throw new WireError("unsupported message version");
  const decoded_abi_major = ctlReadU16(wire);
  const decoded_abi_minor = ctlReadU16(wire);
  const decoded_build_id = ctlReadStr(wire);
  const decoded_gitz_commit = ctlReadStr(wire);
  const decoded_backend = ctlReadU16(wire);
  const decoded_capabilities_low = ctlReadU32(wire);
  const decoded_capabilities_high = ctlReadU32(wire);
  const decoded_max_frame_bytes = ctlReadU32(wire);
  const decoded_max_pack_bytes = ctlReadU32(wire);
  const decoded_max_handles = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    abi_major: decoded_abi_major,
    abi_minor: decoded_abi_minor,
    build_id: decoded_build_id,
    gitz_commit: decoded_gitz_commit,
    backend: decoded_backend,
    capabilities_low: decoded_capabilities_low,
    capabilities_high: decoded_capabilities_high,
    max_frame_bytes: decoded_max_frame_bytes,
    max_pack_bytes: decoded_max_pack_bytes,
    max_handles: decoded_max_handles,
  };
}

export interface ObjectId {
  algorithm: number;
  bytes: Uint8Array;
}
export const OBJECT_ID_MSG_ID = 3;
export const OBJECT_ID_VERSION = 1;
export function encodeObjectId(msg: ObjectId): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, OBJECT_ID_MSG_ID);
  ctlPutU8(out, OBJECT_ID_VERSION);
  ctlPutU16(out, msg.algorithm);
  ctlPutBytes(out, msg.bytes);
  return Uint8Array.from(out);
}
export function decodeObjectId(bytes: Uint8Array): ObjectId {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== OBJECT_ID_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== OBJECT_ID_VERSION) throw new WireError("unsupported message version");
  const decoded_algorithm = ctlReadU16(wire);
  const decoded_bytes = ctlReadBytes(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    algorithm: decoded_algorithm,
    bytes: decoded_bytes,
  };
}

export interface Signature {
  name: string;
  email: string;
  unix_seconds: number;
  timezone_minutes: number;
}
export const SIGNATURE_MSG_ID = 4;
export const SIGNATURE_VERSION = 1;
export function encodeSignature(msg: Signature): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SIGNATURE_MSG_ID);
  ctlPutU8(out, SIGNATURE_VERSION);
  ctlPutStr(out, msg.name);
  ctlPutStr(out, msg.email);
  ctlPutI64(out, msg.unix_seconds);
  ctlPutI32(out, msg.timezone_minutes);
  return Uint8Array.from(out);
}
export function decodeSignature(bytes: Uint8Array): Signature {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SIGNATURE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SIGNATURE_VERSION) throw new WireError("unsupported message version");
  const decoded_name = ctlReadStr(wire);
  const decoded_email = ctlReadStr(wire);
  const decoded_unix_seconds = ctlReadI64(wire);
  const decoded_timezone_minutes = ctlReadI32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    name: decoded_name,
    email: decoded_email,
    unix_seconds: decoded_unix_seconds,
    timezone_minutes: decoded_timezone_minutes,
  };
}

export interface PathList {
  paths: Record<string, string>;
}
export const PATH_LIST_MSG_ID = 5;
export const PATH_LIST_VERSION = 1;
export function encodePathList(msg: PathList): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, PATH_LIST_MSG_ID);
  ctlPutU8(out, PATH_LIST_VERSION);
  ctlPutStrMap(out, msg.paths);
  return Uint8Array.from(out);
}
export function decodePathList(bytes: Uint8Array): PathList {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== PATH_LIST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== PATH_LIST_VERSION) throw new WireError("unsupported message version");
  const decoded_paths = ctlReadStrMap(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    paths: decoded_paths,
  };
}

export interface FileRequest {
  path: string;
  other_path?: string | null;
  mode?: number | null;
  offset_low?: number | null;
  offset_high?: number | null;
  data?: Uint8Array | null;
  handle?: number | null;
}
export const FILE_REQUEST_MSG_ID = 6;
export const FILE_REQUEST_VERSION = 1;
export function encodeFileRequest(msg: FileRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, FILE_REQUEST_MSG_ID);
  ctlPutU8(out, FILE_REQUEST_VERSION);
  ctlPutStr(out, msg.path);
  if (msg.other_path === undefined || msg.other_path === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.other_path);
  }
  if (msg.mode === undefined || msg.mode === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.mode);
  }
  if (msg.offset_low === undefined || msg.offset_low === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.offset_low);
  }
  if (msg.offset_high === undefined || msg.offset_high === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.offset_high);
  }
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  return Uint8Array.from(out);
}
export function decodeFileRequest(bytes: Uint8Array): FileRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== FILE_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== FILE_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_path = ctlReadStr(wire);
  let decoded_other_path: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_other_path = undefined; break;
    case 1: decoded_other_path = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_mode: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_mode = undefined; break;
    case 1: decoded_mode = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_offset_low: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_offset_low = undefined; break;
    case 1: decoded_offset_low = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_offset_high: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_offset_high = undefined; break;
    case 1: decoded_offset_high = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    path: decoded_path,
    other_path: decoded_other_path,
    mode: decoded_mode,
    offset_low: decoded_offset_low,
    offset_high: decoded_offset_high,
    data: decoded_data,
    handle: decoded_handle,
  };
}

export interface PorcelainRequest {
  action: number;
  flags: number;
  revision?: string | null;
  target?: string | null;
  message?: string | null;
  paths: Record<string, string>;
  limit?: number | null;
  cursor?: Uint8Array | null;
  author?: Signature | null;
  committer?: Signature | null;
}
export const PORCELAIN_REQUEST_MSG_ID = 7;
export const PORCELAIN_REQUEST_VERSION = 1;
export function encodePorcelainRequest(msg: PorcelainRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, PORCELAIN_REQUEST_MSG_ID);
  ctlPutU8(out, PORCELAIN_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  ctlPutU32(out, msg.flags);
  if (msg.revision === undefined || msg.revision === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.revision);
  }
  if (msg.target === undefined || msg.target === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.target);
  }
  if (msg.message === undefined || msg.message === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.message);
  }
  ctlPutStrMap(out, msg.paths);
  if (msg.limit === undefined || msg.limit === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.limit);
  }
  if (msg.cursor === undefined || msg.cursor === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.cursor);
  }
  if (msg.author === undefined || msg.author === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeSignature(msg.author));
  }
  if (msg.committer === undefined || msg.committer === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeSignature(msg.committer));
  }
  return Uint8Array.from(out);
}
export function decodePorcelainRequest(bytes: Uint8Array): PorcelainRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== PORCELAIN_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== PORCELAIN_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  const decoded_flags = ctlReadU32(wire);
  let decoded_revision: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_revision = undefined; break;
    case 1: decoded_revision = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_target: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_target = undefined; break;
    case 1: decoded_target = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_message: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_message = undefined; break;
    case 1: decoded_message = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_paths = ctlReadStrMap(wire);
  let decoded_limit: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_limit = undefined; break;
    case 1: decoded_limit = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_cursor: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_cursor = undefined; break;
    case 1: decoded_cursor = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_author: Signature | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_author = undefined; break;
    case 1: decoded_author = decodeSignature(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_committer: Signature | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_committer = undefined; break;
    case 1: decoded_committer = decodeSignature(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    flags: decoded_flags,
    revision: decoded_revision,
    target: decoded_target,
    message: decoded_message,
    paths: decoded_paths,
    limit: decoded_limit,
    cursor: decoded_cursor,
    author: decoded_author,
    committer: decoded_committer,
  };
}

export interface RefUpdate {
  name: string;
  new_value?: ObjectId | null;
  expected_value?: ObjectId | null;
  require_absent: boolean;
}
export const REF_UPDATE_MSG_ID = 8;
export const REF_UPDATE_VERSION = 1;
export function encodeRefUpdate(msg: RefUpdate): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, REF_UPDATE_MSG_ID);
  ctlPutU8(out, REF_UPDATE_VERSION);
  ctlPutStr(out, msg.name);
  if (msg.new_value === undefined || msg.new_value === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeObjectId(msg.new_value));
  }
  if (msg.expected_value === undefined || msg.expected_value === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeObjectId(msg.expected_value));
  }
  ctlPutBool(out, msg.require_absent);
  return Uint8Array.from(out);
}
export function decodeRefUpdate(bytes: Uint8Array): RefUpdate {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== REF_UPDATE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== REF_UPDATE_VERSION) throw new WireError("unsupported message version");
  const decoded_name = ctlReadStr(wire);
  let decoded_new_value: ObjectId | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_new_value = undefined; break;
    case 1: decoded_new_value = decodeObjectId(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_expected_value: ObjectId | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_expected_value = undefined; break;
    case 1: decoded_expected_value = decodeObjectId(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_require_absent = ctlReadBool(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    name: decoded_name,
    new_value: decoded_new_value,
    expected_value: decoded_expected_value,
    require_absent: decoded_require_absent,
  };
}

export interface StreamRequest {
  action: number;
  handle?: number | null;
  offset_low?: number | null;
  offset_high?: number | null;
  data?: Uint8Array | null;
}
export const STREAM_REQUEST_MSG_ID = 10;
export const STREAM_REQUEST_VERSION = 1;
export function encodeStreamRequest(msg: StreamRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, STREAM_REQUEST_MSG_ID);
  ctlPutU8(out, STREAM_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  if (msg.offset_low === undefined || msg.offset_low === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.offset_low);
  }
  if (msg.offset_high === undefined || msg.offset_high === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.offset_high);
  }
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  return Uint8Array.from(out);
}
export function decodeStreamRequest(bytes: Uint8Array): StreamRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== STREAM_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== STREAM_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_offset_low: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_offset_low = undefined; break;
    case 1: decoded_offset_low = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_offset_high: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_offset_high = undefined; break;
    case 1: decoded_offset_high = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    handle: decoded_handle,
    offset_low: decoded_offset_low,
    offset_high: decoded_offset_high,
    data: decoded_data,
  };
}

export interface RemoteRequest {
  action: number;
  url: string;
  remote?: string | null;
  refspecs: Record<string, string>;
  depth?: number | null;
  flags: number;
}
export const REMOTE_REQUEST_MSG_ID = 11;
export const REMOTE_REQUEST_VERSION = 1;
export function encodeRemoteRequest(msg: RemoteRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, REMOTE_REQUEST_MSG_ID);
  ctlPutU8(out, REMOTE_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  ctlPutStr(out, msg.url);
  if (msg.remote === undefined || msg.remote === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.remote);
  }
  ctlPutStrMap(out, msg.refspecs);
  if (msg.depth === undefined || msg.depth === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.depth);
  }
  ctlPutU32(out, msg.flags);
  return Uint8Array.from(out);
}
export function decodeRemoteRequest(bytes: Uint8Array): RemoteRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== REMOTE_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== REMOTE_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  const decoded_url = ctlReadStr(wire);
  let decoded_remote: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_remote = undefined; break;
    case 1: decoded_remote = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_refspecs = ctlReadStrMap(wire);
  let decoded_depth: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_depth = undefined; break;
    case 1: decoded_depth = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_flags = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    url: decoded_url,
    remote: decoded_remote,
    refspecs: decoded_refspecs,
    depth: decoded_depth,
    flags: decoded_flags,
  };
}

export interface HttpEffect {
  exchange: number;
  method: string;
  path: string;
  headers: Record<string, string>;
  body?: number | null;
}
export const HTTP_EFFECT_MSG_ID = 12;
export const HTTP_EFFECT_VERSION = 1;
export function encodeHttpEffect(msg: HttpEffect): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, HTTP_EFFECT_MSG_ID);
  ctlPutU8(out, HTTP_EFFECT_VERSION);
  ctlPutU32(out, msg.exchange);
  ctlPutStr(out, msg.method);
  ctlPutStr(out, msg.path);
  ctlPutStrMap(out, msg.headers);
  if (msg.body === undefined || msg.body === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.body);
  }
  return Uint8Array.from(out);
}
export function decodeHttpEffect(bytes: Uint8Array): HttpEffect {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== HTTP_EFFECT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== HTTP_EFFECT_VERSION) throw new WireError("unsupported message version");
  const decoded_exchange = ctlReadU32(wire);
  const decoded_method = ctlReadStr(wire);
  const decoded_path = ctlReadStr(wire);
  const decoded_headers = ctlReadStrMap(wire);
  let decoded_body: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_body = undefined; break;
    case 1: decoded_body = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    exchange: decoded_exchange,
    method: decoded_method,
    path: decoded_path,
    headers: decoded_headers,
    body: decoded_body,
  };
}

export interface HttpResponse {
  exchange: number;
  action: number;
  status?: number | null;
  headers: Record<string, string>;
  data?: Uint8Array | null;
  error_code?: number | null;
}
export const HTTP_RESPONSE_MSG_ID = 13;
export const HTTP_RESPONSE_VERSION = 1;
export function encodeHttpResponse(msg: HttpResponse): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, HTTP_RESPONSE_MSG_ID);
  ctlPutU8(out, HTTP_RESPONSE_VERSION);
  ctlPutU32(out, msg.exchange);
  ctlPutU16(out, msg.action);
  if (msg.status === undefined || msg.status === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU16(out, msg.status);
  }
  ctlPutStrMap(out, msg.headers);
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  if (msg.error_code === undefined || msg.error_code === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU16(out, msg.error_code);
  }
  return Uint8Array.from(out);
}
export function decodeHttpResponse(bytes: Uint8Array): HttpResponse {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== HTTP_RESPONSE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== HTTP_RESPONSE_VERSION) throw new WireError("unsupported message version");
  const decoded_exchange = ctlReadU32(wire);
  const decoded_action = ctlReadU16(wire);
  let decoded_status: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_status = undefined; break;
    case 1: decoded_status = ctlReadU16(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_headers = ctlReadStrMap(wire);
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_error_code: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_error_code = undefined; break;
    case 1: decoded_error_code = ctlReadU16(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    exchange: decoded_exchange,
    action: decoded_action,
    status: decoded_status,
    headers: decoded_headers,
    data: decoded_data,
    error_code: decoded_error_code,
  };
}

export interface EngineError {
  domain: number;
  code: number;
  operation: number;
  retry: number;
  message?: string | null;
  detail_kind?: number | null;
  detail?: Uint8Array | null;
}
export const ENGINE_ERROR_MSG_ID = 14;
export const ENGINE_ERROR_VERSION = 1;
export function encodeEngineError(msg: EngineError): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, ENGINE_ERROR_MSG_ID);
  ctlPutU8(out, ENGINE_ERROR_VERSION);
  ctlPutU16(out, msg.domain);
  ctlPutU16(out, msg.code);
  ctlPutU16(out, msg.operation);
  ctlPutU16(out, msg.retry);
  if (msg.message === undefined || msg.message === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.message);
  }
  if (msg.detail_kind === undefined || msg.detail_kind === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU16(out, msg.detail_kind);
  }
  if (msg.detail === undefined || msg.detail === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.detail);
  }
  return Uint8Array.from(out);
}
export function decodeEngineError(bytes: Uint8Array): EngineError {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== ENGINE_ERROR_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== ENGINE_ERROR_VERSION) throw new WireError("unsupported message version");
  const decoded_domain = ctlReadU16(wire);
  const decoded_code = ctlReadU16(wire);
  const decoded_operation = ctlReadU16(wire);
  const decoded_retry = ctlReadU16(wire);
  let decoded_message: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_message = undefined; break;
    case 1: decoded_message = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_detail_kind: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_detail_kind = undefined; break;
    case 1: decoded_detail_kind = ctlReadU16(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_detail: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_detail = undefined; break;
    case 1: decoded_detail = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    domain: decoded_domain,
    code: decoded_code,
    operation: decoded_operation,
    retry: decoded_retry,
    message: decoded_message,
    detail_kind: decoded_detail_kind,
    detail: decoded_detail,
  };
}

export interface Result {
  kind: number;
  generation: number;
  handle?: number | null;
  count?: number | null;
  data?: Uint8Array | null;
}
export const RESULT_MSG_ID = 15;
export const RESULT_VERSION = 1;
export function encodeResult(msg: Result): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, RESULT_MSG_ID);
  ctlPutU8(out, RESULT_VERSION);
  ctlPutU16(out, msg.kind);
  ctlPutU32(out, msg.generation);
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  if (msg.count === undefined || msg.count === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.count);
  }
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  return Uint8Array.from(out);
}
export function decodeResult(bytes: Uint8Array): Result {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_kind = ctlReadU16(wire);
  const decoded_generation = ctlReadU32(wire);
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_count: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_count = undefined; break;
    case 1: decoded_count = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    kind: decoded_kind,
    generation: decoded_generation,
    handle: decoded_handle,
    count: decoded_count,
    data: decoded_data,
  };
}

export interface FileResult {
  path: string;
  mode: number;
  size_low: number;
  size_high: number;
  data?: Uint8Array | null;
}
export const FILE_RESULT_MSG_ID = 16;
export const FILE_RESULT_VERSION = 1;
export function encodeFileResult(msg: FileResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, FILE_RESULT_MSG_ID);
  ctlPutU8(out, FILE_RESULT_VERSION);
  ctlPutStr(out, msg.path);
  ctlPutU32(out, msg.mode);
  ctlPutU32(out, msg.size_low);
  ctlPutU32(out, msg.size_high);
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  return Uint8Array.from(out);
}
export function decodeFileResult(bytes: Uint8Array): FileResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== FILE_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== FILE_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_path = ctlReadStr(wire);
  const decoded_mode = ctlReadU32(wire);
  const decoded_size_low = ctlReadU32(wire);
  const decoded_size_high = ctlReadU32(wire);
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    path: decoded_path,
    mode: decoded_mode,
    size_low: decoded_size_low,
    size_high: decoded_size_high,
    data: decoded_data,
  };
}

export interface StatusEntry {
  path: string;
  index: number;
  worktree: number;
}
export const STATUS_ENTRY_MSG_ID = 17;
export const STATUS_ENTRY_VERSION = 1;
export function encodeStatusEntry(msg: StatusEntry): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, STATUS_ENTRY_MSG_ID);
  ctlPutU8(out, STATUS_ENTRY_VERSION);
  ctlPutStr(out, msg.path);
  ctlPutU16(out, msg.index);
  ctlPutU16(out, msg.worktree);
  return Uint8Array.from(out);
}
export function decodeStatusEntry(bytes: Uint8Array): StatusEntry {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== STATUS_ENTRY_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== STATUS_ENTRY_VERSION) throw new WireError("unsupported message version");
  const decoded_path = ctlReadStr(wire);
  const decoded_index = ctlReadU16(wire);
  const decoded_worktree = ctlReadU16(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    path: decoded_path,
    index: decoded_index,
    worktree: decoded_worktree,
  };
}

export interface StatusResult {
  generation: number;
  entries: StatusEntry[];
}
export const STATUS_RESULT_MSG_ID = 18;
export const STATUS_RESULT_VERSION = 1;
export function encodeStatusResult(msg: StatusResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, STATUS_RESULT_MSG_ID);
  ctlPutU8(out, STATUS_RESULT_VERSION);
  ctlPutU32(out, msg.generation);
  ctlPutMessageList(out, msg.entries, encodeStatusEntry);
  return Uint8Array.from(out);
}
export function decodeStatusResult(bytes: Uint8Array): StatusResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== STATUS_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== STATUS_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_generation = ctlReadU32(wire);
  const decoded_entries = ctlReadMessageList(wire, decodeStatusEntry);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    generation: decoded_generation,
    entries: decoded_entries,
  };
}

export interface CommitResult {
  generation: number;
  object_id: ObjectId;
}
export const COMMIT_RESULT_MSG_ID = 19;
export const COMMIT_RESULT_VERSION = 1;
export function encodeCommitResult(msg: CommitResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, COMMIT_RESULT_MSG_ID);
  ctlPutU8(out, COMMIT_RESULT_VERSION);
  ctlPutU32(out, msg.generation);
  ctlPutBytes(out, encodeObjectId(msg.object_id));
  return Uint8Array.from(out);
}
export function decodeCommitResult(bytes: Uint8Array): CommitResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== COMMIT_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== COMMIT_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_generation = ctlReadU32(wire);
  const decoded_object_id = decodeObjectId(ctlReadBytes(wire));
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    generation: decoded_generation,
    object_id: decoded_object_id,
  };
}

export interface ResolveResult {
  object_id: ObjectId;
}
export const RESOLVE_RESULT_MSG_ID = 20;
export const RESOLVE_RESULT_VERSION = 1;
export function encodeResolveResult(msg: ResolveResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, RESOLVE_RESULT_MSG_ID);
  ctlPutU8(out, RESOLVE_RESULT_VERSION);
  ctlPutBytes(out, encodeObjectId(msg.object_id));
  return Uint8Array.from(out);
}
export function decodeResolveResult(bytes: Uint8Array): ResolveResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== RESOLVE_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== RESOLVE_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_object_id = decodeObjectId(ctlReadBytes(wire));
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    object_id: decoded_object_id,
  };
}

export interface DirectoryEntry {
  name: string;
  mode: number;
  size_low: number;
  size_high: number;
}
export const DIRECTORY_ENTRY_MSG_ID = 21;
export const DIRECTORY_ENTRY_VERSION = 1;
export function encodeDirectoryEntry(msg: DirectoryEntry): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, DIRECTORY_ENTRY_MSG_ID);
  ctlPutU8(out, DIRECTORY_ENTRY_VERSION);
  ctlPutStr(out, msg.name);
  ctlPutU32(out, msg.mode);
  ctlPutU32(out, msg.size_low);
  ctlPutU32(out, msg.size_high);
  return Uint8Array.from(out);
}
export function decodeDirectoryEntry(bytes: Uint8Array): DirectoryEntry {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== DIRECTORY_ENTRY_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== DIRECTORY_ENTRY_VERSION) throw new WireError("unsupported message version");
  const decoded_name = ctlReadStr(wire);
  const decoded_mode = ctlReadU32(wire);
  const decoded_size_low = ctlReadU32(wire);
  const decoded_size_high = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    name: decoded_name,
    mode: decoded_mode,
    size_low: decoded_size_low,
    size_high: decoded_size_high,
  };
}

export interface DirectoryResult {
  entries: DirectoryEntry[];
}
export const DIRECTORY_RESULT_MSG_ID = 22;
export const DIRECTORY_RESULT_VERSION = 1;
export function encodeDirectoryResult(msg: DirectoryResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, DIRECTORY_RESULT_MSG_ID);
  ctlPutU8(out, DIRECTORY_RESULT_VERSION);
  ctlPutMessageList(out, msg.entries, encodeDirectoryEntry);
  return Uint8Array.from(out);
}
export function decodeDirectoryResult(bytes: Uint8Array): DirectoryResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== DIRECTORY_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== DIRECTORY_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_entries = ctlReadMessageList(wire, decodeDirectoryEntry);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    entries: decoded_entries,
  };
}

export interface ReferenceResult {
  name: string;
  kind: number;
  object_id?: ObjectId | null;
  target?: string | null;
}
export const REFERENCE_RESULT_MSG_ID = 23;
export const REFERENCE_RESULT_VERSION = 1;
export function encodeReferenceResult(msg: ReferenceResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, REFERENCE_RESULT_MSG_ID);
  ctlPutU8(out, REFERENCE_RESULT_VERSION);
  ctlPutStr(out, msg.name);
  ctlPutU16(out, msg.kind);
  if (msg.object_id === undefined || msg.object_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeObjectId(msg.object_id));
  }
  if (msg.target === undefined || msg.target === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.target);
  }
  return Uint8Array.from(out);
}
export function decodeReferenceResult(bytes: Uint8Array): ReferenceResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== REFERENCE_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== REFERENCE_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_name = ctlReadStr(wire);
  const decoded_kind = ctlReadU16(wire);
  let decoded_object_id: ObjectId | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_object_id = undefined; break;
    case 1: decoded_object_id = decodeObjectId(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_target: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_target = undefined; break;
    case 1: decoded_target = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    name: decoded_name,
    kind: decoded_kind,
    object_id: decoded_object_id,
    target: decoded_target,
  };
}

export interface ReferenceList {
  references: ReferenceResult[];
}
export const REFERENCE_LIST_MSG_ID = 24;
export const REFERENCE_LIST_VERSION = 1;
export function encodeReferenceList(msg: ReferenceList): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, REFERENCE_LIST_MSG_ID);
  ctlPutU8(out, REFERENCE_LIST_VERSION);
  ctlPutMessageList(out, msg.references, encodeReferenceResult);
  return Uint8Array.from(out);
}
export function decodeReferenceList(bytes: Uint8Array): ReferenceList {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== REFERENCE_LIST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== REFERENCE_LIST_VERSION) throw new WireError("unsupported message version");
  const decoded_references = ctlReadMessageList(wire, decodeReferenceResult);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    references: decoded_references,
  };
}

export interface ObjectRequest {
  action: number;
  kind: number;
  object_id?: ObjectId | null;
  data?: Uint8Array | null;
}
export const OBJECT_REQUEST_MSG_ID = 25;
export const OBJECT_REQUEST_VERSION = 1;
export function encodeObjectRequest(msg: ObjectRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, OBJECT_REQUEST_MSG_ID);
  ctlPutU8(out, OBJECT_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  ctlPutU16(out, msg.kind);
  if (msg.object_id === undefined || msg.object_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeObjectId(msg.object_id));
  }
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  return Uint8Array.from(out);
}
export function decodeObjectRequest(bytes: Uint8Array): ObjectRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== OBJECT_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== OBJECT_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  const decoded_kind = ctlReadU16(wire);
  let decoded_object_id: ObjectId | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_object_id = undefined; break;
    case 1: decoded_object_id = decodeObjectId(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    kind: decoded_kind,
    object_id: decoded_object_id,
    data: decoded_data,
  };
}

export interface ObjectResult {
  kind: number;
  object_id: ObjectId;
  size_low: number;
  size_high: number;
  data?: Uint8Array | null;
}
export const OBJECT_RESULT_MSG_ID = 26;
export const OBJECT_RESULT_VERSION = 1;
export function encodeObjectResult(msg: ObjectResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, OBJECT_RESULT_MSG_ID);
  ctlPutU8(out, OBJECT_RESULT_VERSION);
  ctlPutU16(out, msg.kind);
  ctlPutBytes(out, encodeObjectId(msg.object_id));
  ctlPutU32(out, msg.size_low);
  ctlPutU32(out, msg.size_high);
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  return Uint8Array.from(out);
}
export function decodeObjectResult(bytes: Uint8Array): ObjectResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== OBJECT_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== OBJECT_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_kind = ctlReadU16(wire);
  const decoded_object_id = decodeObjectId(ctlReadBytes(wire));
  const decoded_size_low = ctlReadU32(wire);
  const decoded_size_high = ctlReadU32(wire);
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    kind: decoded_kind,
    object_id: decoded_object_id,
    size_low: decoded_size_low,
    size_high: decoded_size_high,
    data: decoded_data,
  };
}

export interface PackRequest {
  action: number;
  handle?: number | null;
  wants: ObjectId[];
  haves: ObjectId[];
  updates: RefUpdate[];
  data?: Uint8Array | null;
}
export const PACK_REQUEST_MSG_ID = 27;
export const PACK_REQUEST_VERSION = 1;
export function encodePackRequest(msg: PackRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, PACK_REQUEST_MSG_ID);
  ctlPutU8(out, PACK_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  ctlPutMessageList(out, msg.wants, encodeObjectId);
  ctlPutMessageList(out, msg.haves, encodeObjectId);
  ctlPutMessageList(out, msg.updates, encodeRefUpdate);
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  return Uint8Array.from(out);
}
export function decodePackRequest(bytes: Uint8Array): PackRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== PACK_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== PACK_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_wants = ctlReadMessageList(wire, decodeObjectId);
  const decoded_haves = ctlReadMessageList(wire, decodeObjectId);
  const decoded_updates = ctlReadMessageList(wire, decodeRefUpdate);
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    handle: decoded_handle,
    wants: decoded_wants,
    haves: decoded_haves,
    updates: decoded_updates,
    data: decoded_data,
  };
}

export interface PackResult {
  handle?: number | null;
  object_count: number;
  reference_count: number;
  data?: Uint8Array | null;
}
export const PACK_RESULT_MSG_ID = 28;
export const PACK_RESULT_VERSION = 1;
export function encodePackResult(msg: PackResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, PACK_RESULT_MSG_ID);
  ctlPutU8(out, PACK_RESULT_VERSION);
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  ctlPutU32(out, msg.object_count);
  ctlPutU32(out, msg.reference_count);
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  return Uint8Array.from(out);
}
export function decodePackResult(bytes: Uint8Array): PackResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== PACK_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== PACK_RESULT_VERSION) throw new WireError("unsupported message version");
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_object_count = ctlReadU32(wire);
  const decoded_reference_count = ctlReadU32(wire);
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    handle: decoded_handle,
    object_count: decoded_object_count,
    reference_count: decoded_reference_count,
    data: decoded_data,
  };
}

export interface SnapshotResult {
  generation: number;
  image: Uint8Array;
}
export const SNAPSHOT_RESULT_MSG_ID = 29;
export const SNAPSHOT_RESULT_VERSION = 1;
export function encodeSnapshotResult(msg: SnapshotResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SNAPSHOT_RESULT_MSG_ID);
  ctlPutU8(out, SNAPSHOT_RESULT_VERSION);
  ctlPutU32(out, msg.generation);
  ctlPutBytes(out, msg.image);
  return Uint8Array.from(out);
}
export function decodeSnapshotResult(bytes: Uint8Array): SnapshotResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SNAPSHOT_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SNAPSHOT_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_generation = ctlReadU32(wire);
  const decoded_image = ctlReadBytes(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    generation: decoded_generation,
    image: decoded_image,
  };
}

export interface StreamChunk {
  handle: number;
  offset_low: number;
  offset_high: number;
  data: Uint8Array;
  done: boolean;
}
export const STREAM_CHUNK_MSG_ID = 30;
export const STREAM_CHUNK_VERSION = 1;
export function encodeStreamChunk(msg: StreamChunk): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, STREAM_CHUNK_MSG_ID);
  ctlPutU8(out, STREAM_CHUNK_VERSION);
  ctlPutU32(out, msg.handle);
  ctlPutU32(out, msg.offset_low);
  ctlPutU32(out, msg.offset_high);
  ctlPutBytes(out, msg.data);
  ctlPutBool(out, msg.done);
  return Uint8Array.from(out);
}
export function decodeStreamChunk(bytes: Uint8Array): StreamChunk {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== STREAM_CHUNK_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== STREAM_CHUNK_VERSION) throw new WireError("unsupported message version");
  const decoded_handle = ctlReadU32(wire);
  const decoded_offset_low = ctlReadU32(wire);
  const decoded_offset_high = ctlReadU32(wire);
  const decoded_data = ctlReadBytes(wire);
  const decoded_done = ctlReadBool(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    handle: decoded_handle,
    offset_low: decoded_offset_low,
    offset_high: decoded_offset_high,
    data: decoded_data,
    done: decoded_done,
  };
}

export interface MountRequest {
  action: number;
  path?: string | null;
  other_path?: string | null;
  handle?: number | null;
  flags: number;
  mode?: number | null;
  offset_low?: number | null;
  offset_high?: number | null;
  data?: Uint8Array | null;
  cursor?: Uint8Array | null;
  limit?: number | null;
}
export const MOUNT_REQUEST_MSG_ID = 31;
export const MOUNT_REQUEST_VERSION = 1;
export function encodeMountRequest(msg: MountRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, MOUNT_REQUEST_MSG_ID);
  ctlPutU8(out, MOUNT_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  if (msg.path === undefined || msg.path === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.path);
  }
  if (msg.other_path === undefined || msg.other_path === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.other_path);
  }
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  ctlPutU32(out, msg.flags);
  if (msg.mode === undefined || msg.mode === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.mode);
  }
  if (msg.offset_low === undefined || msg.offset_low === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.offset_low);
  }
  if (msg.offset_high === undefined || msg.offset_high === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.offset_high);
  }
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  if (msg.cursor === undefined || msg.cursor === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.cursor);
  }
  if (msg.limit === undefined || msg.limit === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.limit);
  }
  return Uint8Array.from(out);
}
export function decodeMountRequest(bytes: Uint8Array): MountRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== MOUNT_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== MOUNT_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  let decoded_path: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_path = undefined; break;
    case 1: decoded_path = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_other_path: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_other_path = undefined; break;
    case 1: decoded_other_path = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_flags = ctlReadU32(wire);
  let decoded_mode: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_mode = undefined; break;
    case 1: decoded_mode = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_offset_low: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_offset_low = undefined; break;
    case 1: decoded_offset_low = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_offset_high: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_offset_high = undefined; break;
    case 1: decoded_offset_high = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_data: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data = undefined; break;
    case 1: decoded_data = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_cursor: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_cursor = undefined; break;
    case 1: decoded_cursor = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_limit: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_limit = undefined; break;
    case 1: decoded_limit = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    path: decoded_path,
    other_path: decoded_other_path,
    handle: decoded_handle,
    flags: decoded_flags,
    mode: decoded_mode,
    offset_low: decoded_offset_low,
    offset_high: decoded_offset_high,
    data: decoded_data,
    cursor: decoded_cursor,
    limit: decoded_limit,
  };
}

export interface RemoteResult {
  handle: number;
  state: number;
  generation: number;
  updated: ReferenceResult[];
}
export const REMOTE_RESULT_MSG_ID = 32;
export const REMOTE_RESULT_VERSION = 1;
export function encodeRemoteResult(msg: RemoteResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, REMOTE_RESULT_MSG_ID);
  ctlPutU8(out, REMOTE_RESULT_VERSION);
  ctlPutU32(out, msg.handle);
  ctlPutU16(out, msg.state);
  ctlPutU32(out, msg.generation);
  ctlPutMessageList(out, msg.updated, encodeReferenceResult);
  return Uint8Array.from(out);
}
export function decodeRemoteResult(bytes: Uint8Array): RemoteResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== REMOTE_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== REMOTE_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_handle = ctlReadU32(wire);
  const decoded_state = ctlReadU16(wire);
  const decoded_generation = ctlReadU32(wire);
  const decoded_updated = ctlReadMessageList(wire, decodeReferenceResult);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    handle: decoded_handle,
    state: decoded_state,
    generation: decoded_generation,
    updated: decoded_updated,
  };
}

export interface PathQuery {
  paths: Record<string, string>;
}
export const PATH_QUERY_MSG_ID = 33;
export const PATH_QUERY_VERSION = 1;
export function encodePathQuery(msg: PathQuery): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, PATH_QUERY_MSG_ID);
  ctlPutU8(out, PATH_QUERY_VERSION);
  ctlPutStrMap(out, msg.paths);
  return Uint8Array.from(out);
}
export function decodePathQuery(bytes: Uint8Array): PathQuery {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== PATH_QUERY_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== PATH_QUERY_VERSION) throw new WireError("unsupported message version");
  const decoded_paths = ctlReadStrMap(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    paths: decoded_paths,
  };
}

export interface IgnoreResult {
  paths: Record<string, string>;
}
export const IGNORE_RESULT_MSG_ID = 34;
export const IGNORE_RESULT_VERSION = 1;
export function encodeIgnoreResult(msg: IgnoreResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, IGNORE_RESULT_MSG_ID);
  ctlPutU8(out, IGNORE_RESULT_VERSION);
  ctlPutStrMap(out, msg.paths);
  return Uint8Array.from(out);
}
export function decodeIgnoreResult(bytes: Uint8Array): IgnoreResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== IGNORE_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== IGNORE_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_paths = ctlReadStrMap(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    paths: decoded_paths,
  };
}

export interface RefTransactionRequest {
  action: number;
  handle?: number | null;
  updates: RefUpdate[];
}
export const REF_TRANSACTION_REQUEST_MSG_ID = 35;
export const REF_TRANSACTION_REQUEST_VERSION = 1;
export function encodeRefTransactionRequest(msg: RefTransactionRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, REF_TRANSACTION_REQUEST_MSG_ID);
  ctlPutU8(out, REF_TRANSACTION_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  ctlPutMessageList(out, msg.updates, encodeRefUpdate);
  return Uint8Array.from(out);
}
export function decodeRefTransactionRequest(bytes: Uint8Array): RefTransactionRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== REF_TRANSACTION_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== REF_TRANSACTION_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_updates = ctlReadMessageList(wire, decodeRefUpdate);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    handle: decoded_handle,
    updates: decoded_updates,
  };
}

export interface RefTransactionResult {
  handle?: number | null;
  generation: number;
  count: number;
}
export const REF_TRANSACTION_RESULT_MSG_ID = 36;
export const REF_TRANSACTION_RESULT_VERSION = 1;
export function encodeRefTransactionResult(msg: RefTransactionResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, REF_TRANSACTION_RESULT_MSG_ID);
  ctlPutU8(out, REF_TRANSACTION_RESULT_VERSION);
  if (msg.handle === undefined || msg.handle === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.handle);
  }
  ctlPutU32(out, msg.generation);
  ctlPutU32(out, msg.count);
  return Uint8Array.from(out);
}
export function decodeRefTransactionResult(bytes: Uint8Array): RefTransactionResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== REF_TRANSACTION_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== REF_TRANSACTION_RESULT_VERSION) throw new WireError("unsupported message version");
  let decoded_handle: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_handle = undefined; break;
    case 1: decoded_handle = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_generation = ctlReadU32(wire);
  const decoded_count = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    handle: decoded_handle,
    generation: decoded_generation,
    count: decoded_count,
  };
}

export interface ShallowRequest {
  action: number;
  commits: ObjectId[];
}
export const SHALLOW_REQUEST_MSG_ID = 37;
export const SHALLOW_REQUEST_VERSION = 1;
export function encodeShallowRequest(msg: ShallowRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SHALLOW_REQUEST_MSG_ID);
  ctlPutU8(out, SHALLOW_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  ctlPutMessageList(out, msg.commits, encodeObjectId);
  return Uint8Array.from(out);
}
export function decodeShallowRequest(bytes: Uint8Array): ShallowRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SHALLOW_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SHALLOW_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  const decoded_commits = ctlReadMessageList(wire, decodeObjectId);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    commits: decoded_commits,
  };
}

export interface ShallowResult {
  commits: ObjectId[];
}
export const SHALLOW_RESULT_MSG_ID = 38;
export const SHALLOW_RESULT_VERSION = 1;
export function encodeShallowResult(msg: ShallowResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SHALLOW_RESULT_MSG_ID);
  ctlPutU8(out, SHALLOW_RESULT_VERSION);
  ctlPutMessageList(out, msg.commits, encodeObjectId);
  return Uint8Array.from(out);
}
export function decodeShallowResult(bytes: Uint8Array): ShallowResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SHALLOW_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SHALLOW_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_commits = ctlReadMessageList(wire, decodeObjectId);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    commits: decoded_commits,
  };
}

export interface SubmoduleRequest {
  action: number;
  path?: string | null;
  object_id?: ObjectId | null;
}
export const SUBMODULE_REQUEST_MSG_ID = 39;
export const SUBMODULE_REQUEST_VERSION = 1;
export function encodeSubmoduleRequest(msg: SubmoduleRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SUBMODULE_REQUEST_MSG_ID);
  ctlPutU8(out, SUBMODULE_REQUEST_VERSION);
  ctlPutU16(out, msg.action);
  if (msg.path === undefined || msg.path === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.path);
  }
  if (msg.object_id === undefined || msg.object_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeObjectId(msg.object_id));
  }
  return Uint8Array.from(out);
}
export function decodeSubmoduleRequest(bytes: Uint8Array): SubmoduleRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SUBMODULE_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SUBMODULE_REQUEST_VERSION) throw new WireError("unsupported message version");
  const decoded_action = ctlReadU16(wire);
  let decoded_path: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_path = undefined; break;
    case 1: decoded_path = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_object_id: ObjectId | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_object_id = undefined; break;
    case 1: decoded_object_id = decodeObjectId(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    action: decoded_action,
    path: decoded_path,
    object_id: decoded_object_id,
  };
}

export interface SubmoduleEntry {
  name: string;
  path: string;
  url: string;
  gitlink?: ObjectId | null;
  head?: ObjectId | null;
  state: number;
}
export const SUBMODULE_ENTRY_MSG_ID = 40;
export const SUBMODULE_ENTRY_VERSION = 1;
export function encodeSubmoduleEntry(msg: SubmoduleEntry): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SUBMODULE_ENTRY_MSG_ID);
  ctlPutU8(out, SUBMODULE_ENTRY_VERSION);
  ctlPutStr(out, msg.name);
  ctlPutStr(out, msg.path);
  ctlPutStr(out, msg.url);
  if (msg.gitlink === undefined || msg.gitlink === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeObjectId(msg.gitlink));
  }
  if (msg.head === undefined || msg.head === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeObjectId(msg.head));
  }
  ctlPutU16(out, msg.state);
  return Uint8Array.from(out);
}
export function decodeSubmoduleEntry(bytes: Uint8Array): SubmoduleEntry {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SUBMODULE_ENTRY_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SUBMODULE_ENTRY_VERSION) throw new WireError("unsupported message version");
  const decoded_name = ctlReadStr(wire);
  const decoded_path = ctlReadStr(wire);
  const decoded_url = ctlReadStr(wire);
  let decoded_gitlink: ObjectId | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_gitlink = undefined; break;
    case 1: decoded_gitlink = decodeObjectId(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_head: ObjectId | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_head = undefined; break;
    case 1: decoded_head = decodeObjectId(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_state = ctlReadU16(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    name: decoded_name,
    path: decoded_path,
    url: decoded_url,
    gitlink: decoded_gitlink,
    head: decoded_head,
    state: decoded_state,
  };
}

export interface SubmoduleResult {
  generation: number;
  entries: SubmoduleEntry[];
}
export const SUBMODULE_RESULT_MSG_ID = 41;
export const SUBMODULE_RESULT_VERSION = 1;
export function encodeSubmoduleResult(msg: SubmoduleResult): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SUBMODULE_RESULT_MSG_ID);
  ctlPutU8(out, SUBMODULE_RESULT_VERSION);
  ctlPutU32(out, msg.generation);
  ctlPutMessageList(out, msg.entries, encodeSubmoduleEntry);
  return Uint8Array.from(out);
}
export function decodeSubmoduleResult(bytes: Uint8Array): SubmoduleResult {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== SUBMODULE_RESULT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== SUBMODULE_RESULT_VERSION) throw new WireError("unsupported message version");
  const decoded_generation = ctlReadU32(wire);
  const decoded_entries = ctlReadMessageList(wire, decodeSubmoduleEntry);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    generation: decoded_generation,
    entries: decoded_entries,
  };
}

export type GitRequestEnvelope = { opcode: number; flags: number; requestId: number; payload: Uint8Array };
export type GitResponseEnvelope = { opcode: number; status: number; requestId: number; payload: Uint8Array };
function encodeGitEnvelope(magic: string, opcode: number, word: number, requestId: number, payload: Uint8Array): Uint8Array {
const out = new Uint8Array(ENVELOPE_HEADER_BYTES + payload.length); const view = new DataView(out.buffer);
out.set(CTL_TEXT_ENCODER.encode(magic), 0); view.setUint16(4, PROTOCOL_VERSION, true); view.setUint16(6, PROTOCOL_MINOR, true);
view.setUint16(8, opcode, true); view.setUint16(10, word, true); view.setUint32(12, requestId, true); view.setUint32(16, payload.length, true); out.set(payload, ENVELOPE_HEADER_BYTES); return out;
}
export function encodeRequestEnvelope(opcode: number, flags: number, requestId: number, payload: Uint8Array): Uint8Array { if (payload.length > MAX_FRAME_BYTES - ENVELOPE_HEADER_BYTES) throw new WireError("payload exceeds frame limit"); return encodeGitEnvelope(REQUEST_MAGIC, opcode, flags, requestId, payload); }
export function decodeRequestEnvelope(bytes: Uint8Array): GitRequestEnvelope {
if (bytes.length > MAX_FRAME_BYTES || bytes.length < ENVELOPE_HEADER_BYTES) throw new Error("git wire: invalid frame length");
if (new TextDecoder().decode(bytes.subarray(0, 4)) !== REQUEST_MAGIC) throw new Error("git wire: wrong magic");
const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
if (view.getUint16(4, true) !== PROTOCOL_VERSION || view.getUint16(6, true) > PROTOCOL_MINOR) throw new Error("git wire: unsupported version");
const payloadLength = view.getUint32(16, true);
if (payloadLength > MAX_FRAME_BYTES - ENVELOPE_HEADER_BYTES || ENVELOPE_HEADER_BYTES + payloadLength !== bytes.length) throw new Error("git wire: invalid payload length");
return { opcode: view.getUint16(8, true), flags: view.getUint16(10, true), requestId: view.getUint32(12, true), payload: bytes.subarray(ENVELOPE_HEADER_BYTES) };
}
export function decodeResponseEnvelope(bytes: Uint8Array): GitResponseEnvelope {
if (bytes.length > MAX_RESULT_BYTES || bytes.length < ENVELOPE_HEADER_BYTES) throw new WireError("invalid response length");
if (CTL_TEXT_DECODER.decode(bytes.subarray(0, 4)) !== RESPONSE_MAGIC) throw new WireError("wrong response magic");
const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); if (view.getUint16(4, true) !== PROTOCOL_VERSION || view.getUint16(6, true) > PROTOCOL_MINOR) throw new WireError("unsupported response version");
const len = view.getUint32(16, true); if (ENVELOPE_HEADER_BYTES + len !== bytes.length) throw new WireError("invalid response payload length");
return { opcode: view.getUint16(8, true), status: view.getUint16(10, true), requestId: view.getUint32(12, true), payload: bytes.subarray(ENVELOPE_HEADER_BYTES) };
}
