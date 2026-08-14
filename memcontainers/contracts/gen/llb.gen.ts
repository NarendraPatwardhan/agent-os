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
function ctlReadStrMap(cursor: CtlCursor): Record<string, string> { const n = ctlReadU32(cursor); if (n > Math.floor((cursor.bytes.length - cursor.off) / 8)) throw new WireError("truncated frame"); const out: Record<string, string> = {}; let prev: string | null = null; for (let i = 0; i < n; i++) { const k = ctlReadStr(cursor); if (prev !== null && prev >= k) throw new WireError("non-canonical strmap"); out[k] = ctlReadStr(cursor); prev = k; } return out; }

function ctlReadMessageList<T>(cursor: CtlCursor, decode: (bytes: Uint8Array) => T): T[] { const n = ctlReadU32(cursor); if (n > Math.floor((cursor.bytes.length - cursor.off) / 4)) throw new WireError("truncated frame"); const out: T[] = []; for (let i = 0; i < n; i++) out.push(decode(ctlReadBytes(cursor))); return out; }

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
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BUILD_INPUT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BUILD_INPUT_VERSION) throw new WireError("unsupported message version");
  const decoded_index = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    index: decoded_index,
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
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== COPY_PATH_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== COPY_PATH_VERSION) throw new WireError("unsupported message version");
  const decoded_src_path = ctlReadStr(wire);
  const decoded_dest_path = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    src_path: decoded_src_path,
    dest_path: decoded_dest_path,
  };
}

// One literal argument in a direct LLB run operation. Empty values are significant.
export interface BuildArg {
  value: string;
}
export const BUILD_ARG_MSG_ID = 8;
export const BUILD_ARG_VERSION = 1;
export function encodeBuildArg(msg: BuildArg): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BUILD_ARG_MSG_ID);
  ctlPutU8(out, BUILD_ARG_VERSION);
  ctlPutStr(out, msg.value);
  return Uint8Array.from(out);
}
export function decodeBuildArg(bytes: Uint8Array): BuildArg {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BUILD_ARG_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BUILD_ARG_VERSION) throw new WireError("unsupported message version");
  const decoded_value = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    value: decoded_value,
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
  form?: string | null;
  argv: BuildArg[];
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
export const BUILD_OP_VERSION = 2;
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
  if (msg.form === undefined || msg.form === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.form);
  }
  ctlPutMessageList(out, msg.argv, encodeBuildArg);
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
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BUILD_OP_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BUILD_OP_VERSION) throw new WireError("unsupported message version");
  const decoded_kind = ctlReadU32(wire);
  let decoded_source_ref: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_source_ref = undefined; break;
    case 1: decoded_source_ref = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_input: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_input = undefined; break;
    case 1: decoded_input = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_src: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_src = undefined; break;
    case 1: decoded_src = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_dest: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_dest = undefined; break;
    case 1: decoded_dest = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_a: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_a = undefined; break;
    case 1: decoded_a = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_b: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_b = undefined; break;
    case 1: decoded_b = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_lower: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_lower = undefined; break;
    case 1: decoded_lower = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_upper: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_upper = undefined; break;
    case 1: decoded_upper = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_parts = ctlReadMessageList(wire, decodeBuildInput);
  const decoded_copy_paths = ctlReadMessageList(wire, decodeCopyPath);
  let decoded_path: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_path = undefined; break;
    case 1: decoded_path = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_local_path: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_local_path = undefined; break;
    case 1: decoded_local_path = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_http_url: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_http_url = undefined; break;
    case 1: decoded_http_url = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_expected_digest: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_expected_digest = undefined; break;
    case 1: decoded_expected_digest = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_git_repo: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_git_repo = undefined; break;
    case 1: decoded_git_repo = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_git_ref: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_git_ref = undefined; break;
    case 1: decoded_git_ref = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_dest_path: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_dest_path = undefined; break;
    case 1: decoded_dest_path = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_data_digest: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_data_digest = undefined; break;
    case 1: decoded_data_digest = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_target: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_target = undefined; break;
    case 1: decoded_target = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_link: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_link = undefined; break;
    case 1: decoded_link = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_mode: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_mode = undefined; break;
    case 1: decoded_mode = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_cmd: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_cmd = undefined; break;
    case 1: decoded_cmd = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_form: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_form = undefined; break;
    case 1: decoded_form = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_argv = ctlReadMessageList(wire, decodeBuildArg);
  let decoded_cwd: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_cwd = undefined; break;
    case 1: decoded_cwd = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_env = ctlReadStrMap(wire);
  let decoded_stdin: Uint8Array | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_stdin = undefined; break;
    case 1: decoded_stdin = ctlReadBytes(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_tier: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_tier = undefined; break;
    case 1: decoded_tier = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_budget_mib: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_budget_mib = undefined; break;
    case 1: decoded_budget_mib = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_fuel: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_fuel = undefined; break;
    case 1: decoded_fuel = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_deterministic: boolean | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_deterministic = undefined; break;
    case 1: decoded_deterministic = ctlReadBool(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_net: boolean | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_net = undefined; break;
    case 1: decoded_net = ctlReadBool(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const decoded_mounts = ctlReadMessageList(wire, decodeBuildInput);
  let decoded_config_tier: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_config_tier = undefined; break;
    case 1: decoded_config_tier = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_config_budget_mib: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_config_budget_mib = undefined; break;
    case 1: decoded_config_budget_mib = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  let decoded_config_fuel: number | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_config_fuel = undefined; break;
    case 1: decoded_config_fuel = ctlReadU32(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    kind: decoded_kind,
    source_ref: decoded_source_ref,
    input: decoded_input,
    src: decoded_src,
    dest: decoded_dest,
    a: decoded_a,
    b: decoded_b,
    lower: decoded_lower,
    upper: decoded_upper,
    parts: decoded_parts,
    copy_paths: decoded_copy_paths,
    path: decoded_path,
    local_path: decoded_local_path,
    http_url: decoded_http_url,
    expected_digest: decoded_expected_digest,
    git_repo: decoded_git_repo,
    git_ref: decoded_git_ref,
    dest_path: decoded_dest_path,
    data_digest: decoded_data_digest,
    target: decoded_target,
    link: decoded_link,
    mode: decoded_mode,
    cmd: decoded_cmd,
    form: decoded_form,
    argv: decoded_argv,
    cwd: decoded_cwd,
    env: decoded_env,
    stdin: decoded_stdin,
    tier: decoded_tier,
    budget_mib: decoded_budget_mib,
    fuel: decoded_fuel,
    deterministic: decoded_deterministic,
    net: decoded_net,
    mounts: decoded_mounts,
    config_tier: decoded_config_tier,
    config_budget_mib: decoded_config_budget_mib,
    config_fuel: decoded_config_fuel,
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
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== DIGEST_EDGE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== DIGEST_EDGE_VERSION) throw new WireError("unsupported message version");
  const decoded_role = ctlReadStr(wire);
  const decoded_digest = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    role: decoded_role,
    digest: decoded_digest,
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
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== LAYER_REF_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== LAYER_REF_VERSION) throw new WireError("unsupported message version");
  const decoded_producer = ctlReadStr(wire);
  const decoded_digest = ctlReadStr(wire);
  const decoded_size = ctlReadI64(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    producer: decoded_producer,
    digest: decoded_digest,
    size: decoded_size,
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
export const NODE_DIGEST_VERSION = 2;
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
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== NODE_DIGEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== NODE_DIGEST_VERSION) throw new WireError("unsupported message version");
  const decoded_op = decodeBuildOp(ctlReadBytes(wire));
  const decoded_edges = ctlReadMessageList(wire, decodeDigestEdge);
  const decoded_resolved = ctlReadStrMap(wire);
  const decoded_layers = ctlReadMessageList(wire, decodeLayerRef);
  let decoded_kernel_digest: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: decoded_kernel_digest = undefined; break;
    case 1: decoded_kernel_digest = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    op: decoded_op,
    edges: decoded_edges,
    resolved: decoded_resolved,
    layers: decoded_layers,
    kernel_digest: decoded_kernel_digest,
  };
}

// A portable LLB build graph. `root` indexes into `ops`; edges only point at earlier ops.
export interface Definition {
  version: number;
  ops: BuildOp[];
  root: number;
}
export const DEFINITION_MSG_ID = 3;
export const DEFINITION_VERSION = 2;
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
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== DEFINITION_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== DEFINITION_VERSION) throw new WireError("unsupported message version");
  const decoded_version = ctlReadU32(wire);
  const decoded_ops = ctlReadMessageList(wire, decodeBuildOp);
  const decoded_root = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    version: decoded_version,
    ops: decoded_ops,
    root: decoded_root,
  };
}
