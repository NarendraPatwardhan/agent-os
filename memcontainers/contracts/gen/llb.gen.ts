// @generated from contracts/llb.kdl by //contracts/codegen:projector — do not edit.

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
function ctlReadStrMap(cursor: CtlCursor): Record<string, string> { const n = ctlReadU32(cursor); const out: Record<string, string> = {}; let prev: string | null = null; for (let i = 0; i < n; i++) { const k = ctlReadStr(cursor); if (prev !== null && prev >= k) throw new WireError("non-canonical strmap"); out[k] = ctlReadStr(cursor); prev = k; } return out; }

function ctlReadMessageList<T>(cursor: CtlCursor, decode: (bytes: Uint8Array) => T): T[] { const n = ctlReadU32(cursor); const out: T[] = []; for (let i = 0; i < n; i++) out.push(decode(ctlReadBytes(cursor))); return out; }

// One integer edge into a Definition's topologically ordered op array.
export interface BuildInput {
  index: number;
}
export const BUILD_INPUT_MSG_ID = 1;
export const BUILD_INPUT_VERSION = 1;
export function encodeBuildInput(msg: BuildInput): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BUILD_INPUT_MSG_ID);
  ctlPutU8(out, BUILD_INPUT_VERSION);
  ctlPutU32(out, msg.index);
  return Uint8Array.from(out);
}
export function decodeBuildInput(bytes: Uint8Array): BuildInput {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== BUILD_INPUT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== BUILD_INPUT_VERSION) throw new WireError("unsupported message version");
  const index = ctlReadU32(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    index,
  };
}

// One exact path mapping for a multi-stage copy op.
export interface CopyPath {
  src_path: string;
  dest_path: string;
}
export const COPY_PATH_MSG_ID = 4;
export const COPY_PATH_VERSION = 1;
export function encodeCopyPath(msg: CopyPath): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, COPY_PATH_MSG_ID);
  ctlPutU8(out, COPY_PATH_VERSION);
  ctlPutStr(out, msg.src_path);
  ctlPutStr(out, msg.dest_path);
  return Uint8Array.from(out);
}
export function decodeCopyPath(bytes: Uint8Array): CopyPath {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== COPY_PATH_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== COPY_PATH_VERSION) throw new WireError("unsupported message version");
  const src_path = ctlReadStr(cursor);
  const dest_path = ctlReadStr(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    src_path,
    dest_path,
  };
}

// One portable LLB op. `kind` is the SDK's closed op enum; unused fields must be absent or empty.
export interface BuildOp {
  kind: number;
  source_ref?: string | null;
  input?: number | null;
  src?: number | null;
  dest?: number | null;
  a?: number | null;
  b?: number | null;
  lower?: number | null;
  upper?: number | null;
  parts: BuildInput[];
  copy_paths: CopyPath[];
  path?: string | null;
  local_path?: string | null;
  http_url?: string | null;
  expected_digest?: string | null;
  git_repo?: string | null;
  git_ref?: string | null;
  dest_path?: string | null;
  data_digest?: string | null;
  target?: string | null;
  link?: string | null;
  mode?: number | null;
  cmd?: string | null;
  cwd?: string | null;
  env: Record<string, string>;
  stdin?: Uint8Array | null;
  tier?: string | null;
  budget_mib?: number | null;
  fuel?: number | null;
  deterministic?: boolean | null;
  net?: boolean | null;
  mounts: BuildInput[];
  config_tier?: string | null;
  config_budget_mib?: number | null;
  config_fuel?: number | null;
}
export const BUILD_OP_MSG_ID = 2;
export const BUILD_OP_VERSION = 1;
export function encodeBuildOp(msg: BuildOp): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BUILD_OP_MSG_ID);
  ctlPutU8(out, BUILD_OP_VERSION);
  ctlPutU32(out, msg.kind);
  if (msg.source_ref === undefined || msg.source_ref === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.source_ref);
  }
  if (msg.input === undefined || msg.input === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.input);
  }
  if (msg.src === undefined || msg.src === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.src);
  }
  if (msg.dest === undefined || msg.dest === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.dest);
  }
  if (msg.a === undefined || msg.a === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.a);
  }
  if (msg.b === undefined || msg.b === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.b);
  }
  if (msg.lower === undefined || msg.lower === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.lower);
  }
  if (msg.upper === undefined || msg.upper === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.upper);
  }
  ctlPutMessageList(out, msg.parts, encodeBuildInput);
  ctlPutMessageList(out, msg.copy_paths, encodeCopyPath);
  if (msg.path === undefined || msg.path === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.path);
  }
  if (msg.local_path === undefined || msg.local_path === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.local_path);
  }
  if (msg.http_url === undefined || msg.http_url === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.http_url);
  }
  if (msg.expected_digest === undefined || msg.expected_digest === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.expected_digest);
  }
  if (msg.git_repo === undefined || msg.git_repo === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.git_repo);
  }
  if (msg.git_ref === undefined || msg.git_ref === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.git_ref);
  }
  if (msg.dest_path === undefined || msg.dest_path === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.dest_path);
  }
  if (msg.data_digest === undefined || msg.data_digest === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.data_digest);
  }
  if (msg.target === undefined || msg.target === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.target);
  }
  if (msg.link === undefined || msg.link === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.link);
  }
  if (msg.mode === undefined || msg.mode === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.mode);
  }
  if (msg.cmd === undefined || msg.cmd === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.cmd);
  }
  if (msg.cwd === undefined || msg.cwd === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.cwd);
  }
  ctlPutStrMap(out, msg.env);
  if (msg.stdin === undefined || msg.stdin === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.stdin);
  }
  if (msg.tier === undefined || msg.tier === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.tier);
  }
  if (msg.budget_mib === undefined || msg.budget_mib === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.budget_mib);
  }
  if (msg.fuel === undefined || msg.fuel === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.fuel);
  }
  if (msg.deterministic === undefined || msg.deterministic === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBool(out, msg.deterministic);
  }
  if (msg.net === undefined || msg.net === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBool(out, msg.net);
  }
  ctlPutMessageList(out, msg.mounts, encodeBuildInput);
  if (msg.config_tier === undefined || msg.config_tier === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.config_tier);
  }
  if (msg.config_budget_mib === undefined || msg.config_budget_mib === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.config_budget_mib);
  }
  if (msg.config_fuel === undefined || msg.config_fuel === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutU32(out, msg.config_fuel);
  }
  return Uint8Array.from(out);
}
export function decodeBuildOp(bytes: Uint8Array): BuildOp {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== BUILD_OP_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== BUILD_OP_VERSION) throw new WireError("unsupported message version");
  const kind = ctlReadU32(cursor);
  let source_ref: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: source_ref = undefined; break;
    case 1: source_ref = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let input: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: input = undefined; break;
    case 1: input = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let src: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: src = undefined; break;
    case 1: src = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let dest: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: dest = undefined; break;
    case 1: dest = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let a: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: a = undefined; break;
    case 1: a = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let b: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: b = undefined; break;
    case 1: b = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let lower: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: lower = undefined; break;
    case 1: lower = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let upper: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: upper = undefined; break;
    case 1: upper = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  const parts = ctlReadMessageList(cursor, decodeBuildInput);
  const copy_paths = ctlReadMessageList(cursor, decodeCopyPath);
  let path: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: path = undefined; break;
    case 1: path = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let local_path: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: local_path = undefined; break;
    case 1: local_path = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let http_url: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: http_url = undefined; break;
    case 1: http_url = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let expected_digest: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: expected_digest = undefined; break;
    case 1: expected_digest = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let git_repo: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: git_repo = undefined; break;
    case 1: git_repo = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let git_ref: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: git_ref = undefined; break;
    case 1: git_ref = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let dest_path: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: dest_path = undefined; break;
    case 1: dest_path = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let data_digest: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: data_digest = undefined; break;
    case 1: data_digest = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let target: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: target = undefined; break;
    case 1: target = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let link: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: link = undefined; break;
    case 1: link = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let mode: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: mode = undefined; break;
    case 1: mode = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let cmd: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: cmd = undefined; break;
    case 1: cmd = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let cwd: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: cwd = undefined; break;
    case 1: cwd = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  const env = ctlReadStrMap(cursor);
  let stdin: Uint8Array | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: stdin = undefined; break;
    case 1: stdin = ctlReadBytes(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let tier: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: tier = undefined; break;
    case 1: tier = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let budget_mib: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: budget_mib = undefined; break;
    case 1: budget_mib = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let fuel: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: fuel = undefined; break;
    case 1: fuel = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let deterministic: boolean | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: deterministic = undefined; break;
    case 1: deterministic = ctlReadBool(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let net: boolean | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: net = undefined; break;
    case 1: net = ctlReadBool(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  const mounts = ctlReadMessageList(cursor, decodeBuildInput);
  let config_tier: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: config_tier = undefined; break;
    case 1: config_tier = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let config_budget_mib: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: config_budget_mib = undefined; break;
    case 1: config_budget_mib = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let config_fuel: number | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: config_fuel = undefined; break;
    case 1: config_fuel = ctlReadU32(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    kind,
    source_ref,
    input,
    src,
    dest,
    a,
    b,
    lower,
    upper,
    parts,
    copy_paths,
    path,
    local_path,
    http_url,
    expected_digest,
    git_repo,
    git_ref,
    dest_path,
    data_digest,
    target,
    link,
    mode,
    cmd,
    cwd,
    env,
    stdin,
    tier,
    budget_mib,
    fuel,
    deterministic,
    net,
    mounts,
    config_tier,
    config_budget_mib,
    config_fuel,
  };
}

// One resolved input edge for a cache-key node digest. Roles are stable names such as input, src, dest, or part:0.
export interface DigestEdge {
  role: string;
  digest: string;
}
export const DIGEST_EDGE_MSG_ID = 5;
export const DIGEST_EDGE_VERSION = 1;
export function encodeDigestEdge(msg: DigestEdge): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, DIGEST_EDGE_MSG_ID);
  ctlPutU8(out, DIGEST_EDGE_VERSION);
  ctlPutStr(out, msg.role);
  ctlPutStr(out, msg.digest);
  return Uint8Array.from(out);
}
export function decodeDigestEdge(bytes: Uint8Array): DigestEdge {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== DIGEST_EDGE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== DIGEST_EDGE_VERSION) throw new WireError("unsupported message version");
  const role = ctlReadStr(cursor);
  const digest = ctlReadStr(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    role,
    digest,
  };
}

// Resolved layer metadata folded into source-node cache keys.
export interface LayerRef {
  producer: string;
  digest: string;
  size: number;
}
export const LAYER_REF_MSG_ID = 6;
export const LAYER_REF_VERSION = 1;
export function encodeLayerRef(msg: LayerRef): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, LAYER_REF_MSG_ID);
  ctlPutU8(out, LAYER_REF_VERSION);
  ctlPutStr(out, msg.producer);
  ctlPutStr(out, msg.digest);
  ctlPutI64(out, msg.size);
  return Uint8Array.from(out);
}
export function decodeLayerRef(bytes: Uint8Array): LayerRef {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== LAYER_REF_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== LAYER_REF_VERSION) throw new WireError("unsupported message version");
  const producer = ctlReadStr(cursor);
  const digest = ctlReadStr(cursor);
  const size = ctlReadI64(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    producer,
    digest,
    size,
  };
}

// Canonical cache-key input for one solved LLB vertex: op args, child digests, resolved mutable-source facts, source layers, and kernel identity when a VM is booted.
export interface NodeDigest {
  op: BuildOp;
  edges: DigestEdge[];
  resolved: Record<string, string>;
  layers: LayerRef[];
  kernel_digest?: string | null;
}
export const NODE_DIGEST_MSG_ID = 7;
export const NODE_DIGEST_VERSION = 1;
export function encodeNodeDigest(msg: NodeDigest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, NODE_DIGEST_MSG_ID);
  ctlPutU8(out, NODE_DIGEST_VERSION);
  ctlPutBytes(out, encodeBuildOp(msg.op));
  ctlPutMessageList(out, msg.edges, encodeDigestEdge);
  ctlPutStrMap(out, msg.resolved);
  ctlPutMessageList(out, msg.layers, encodeLayerRef);
  if (msg.kernel_digest === undefined || msg.kernel_digest === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.kernel_digest);
  }
  return Uint8Array.from(out);
}
export function decodeNodeDigest(bytes: Uint8Array): NodeDigest {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== NODE_DIGEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== NODE_DIGEST_VERSION) throw new WireError("unsupported message version");
  const op = decodeBuildOp(ctlReadBytes(cursor));
  const edges = ctlReadMessageList(cursor, decodeDigestEdge);
  const resolved = ctlReadStrMap(cursor);
  const layers = ctlReadMessageList(cursor, decodeLayerRef);
  let kernel_digest: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: kernel_digest = undefined; break;
    case 1: kernel_digest = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    op,
    edges,
    resolved,
    layers,
    kernel_digest,
  };
}

// A portable LLB build graph. `root` indexes into `ops`; edges only point at earlier ops.
export interface Definition {
  version: number;
  ops: BuildOp[];
  root: number;
}
export const DEFINITION_MSG_ID = 3;
export const DEFINITION_VERSION = 1;
export function encodeDefinition(msg: Definition): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, DEFINITION_MSG_ID);
  ctlPutU8(out, DEFINITION_VERSION);
  ctlPutU32(out, msg.version);
  ctlPutMessageList(out, msg.ops, encodeBuildOp);
  ctlPutU32(out, msg.root);
  return Uint8Array.from(out);
}
export function decodeDefinition(bytes: Uint8Array): Definition {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== DEFINITION_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== DEFINITION_VERSION) throw new WireError("unsupported message version");
  const version = ctlReadU32(cursor);
  const ops = ctlReadMessageList(cursor, decodeBuildOp);
  const root = ctlReadU32(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    version,
    ops,
    root,
  };
}
