// @generated from contracts/control.kdl by //contracts/codegen:projector — do not edit.

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

// Structured host-control exec request. `cmd` still runs under /bin/sh -c; cwd/env/stdin are applied by the kernel at spawn.
export interface ExecRequest {
  cmd: string;
  cwd?: string | null;
  env: Record<string, string>;
  stdin?: Uint8Array | null;
}
export const EXEC_REQUEST_MSG_ID = 1;
export const EXEC_REQUEST_VERSION = 1;
export function encodeExecRequest(msg: ExecRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, EXEC_REQUEST_MSG_ID);
  ctlPutU8(out, EXEC_REQUEST_VERSION);
  ctlPutStr(out, msg.cmd);
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
  return Uint8Array.from(out);
}
export function decodeExecRequest(bytes: Uint8Array): ExecRequest {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== EXEC_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== EXEC_REQUEST_VERSION) throw new WireError("unsupported message version");
  const cmd = ctlReadStr(cursor);
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
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    cmd,
    cwd,
    env,
    stdin,
  };
}

// Structured host-control exec result: process exit code plus captured stdout/stderr bytes.
export interface ExecOutcome {
  exit_code: number;
  stdout: Uint8Array;
  stderr: Uint8Array;
}
export const EXEC_OUTCOME_MSG_ID = 2;
export const EXEC_OUTCOME_VERSION = 1;
export function encodeExecOutcome(msg: ExecOutcome): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, EXEC_OUTCOME_MSG_ID);
  ctlPutU8(out, EXEC_OUTCOME_VERSION);
  ctlPutI32(out, msg.exit_code);
  ctlPutBytes(out, msg.stdout);
  ctlPutBytes(out, msg.stderr);
  return Uint8Array.from(out);
}
export function decodeExecOutcome(bytes: Uint8Array): ExecOutcome {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== EXEC_OUTCOME_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== EXEC_OUTCOME_VERSION) throw new WireError("unsupported message version");
  const exit_code = ctlReadI32(cursor);
  const stdout = ctlReadBytes(cursor);
  const stderr = ctlReadBytes(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    exit_code,
    stdout,
    stderr,
  };
}

// Structured host-control stat result. Size is non-negative; hosts reject negative values.
export interface FileStat {
  size: number;
  is_dir: boolean;
  is_symlink: boolean;
  nlink: number;
  mode: number;
}
export const FILE_STAT_MSG_ID = 3;
export const FILE_STAT_VERSION = 1;
export function encodeFileStat(msg: FileStat): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, FILE_STAT_MSG_ID);
  ctlPutU8(out, FILE_STAT_VERSION);
  ctlPutI64(out, msg.size);
  ctlPutBool(out, msg.is_dir);
  ctlPutBool(out, msg.is_symlink);
  ctlPutU32(out, msg.nlink);
  ctlPutU32(out, msg.mode);
  return Uint8Array.from(out);
}
export function decodeFileStat(bytes: Uint8Array): FileStat {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== FILE_STAT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== FILE_STAT_VERSION) throw new WireError("unsupported message version");
  const size = ctlReadI64(cursor);
  const is_dir = ctlReadBool(cursor);
  const is_symlink = ctlReadBool(cursor);
  const nlink = ctlReadU32(cursor);
  const mode = ctlReadU32(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    size,
    is_dir,
    is_symlink,
    nlink,
    mode,
  };
}

// One structured host-control directory entry.
export interface DirEntry {
  name: string;
  is_dir: boolean;
  is_symlink: boolean;
}
export const DIR_ENTRY_MSG_ID = 4;
export const DIR_ENTRY_VERSION = 1;
export function encodeDirEntry(msg: DirEntry): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, DIR_ENTRY_MSG_ID);
  ctlPutU8(out, DIR_ENTRY_VERSION);
  ctlPutStr(out, msg.name);
  ctlPutBool(out, msg.is_dir);
  ctlPutBool(out, msg.is_symlink);
  return Uint8Array.from(out);
}
export function decodeDirEntry(bytes: Uint8Array): DirEntry {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== DIR_ENTRY_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== DIR_ENTRY_VERSION) throw new WireError("unsupported message version");
  const name = ctlReadStr(cursor);
  const is_dir = ctlReadBool(cursor);
  const is_symlink = ctlReadBool(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    name,
    is_dir,
    is_symlink,
  };
}

// Structured host-control directory listing.
export interface DirEntries {
  entries: DirEntry[];
}
export const DIR_ENTRIES_MSG_ID = 5;
export const DIR_ENTRIES_VERSION = 1;
export function encodeDirEntries(msg: DirEntries): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, DIR_ENTRIES_MSG_ID);
  ctlPutU8(out, DIR_ENTRIES_VERSION);
  ctlPutMessageList(out, msg.entries, encodeDirEntry);
  return Uint8Array.from(out);
}
export function decodeDirEntries(bytes: Uint8Array): DirEntries {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== DIR_ENTRIES_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== DIR_ENTRIES_VERSION) throw new WireError("unsupported message version");
  const entries = ctlReadMessageList(cursor, decodeDirEntry);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    entries,
  };
}

// Structured host-control resident-service request.
export interface SvcRequest {
  service: string;
  request: Uint8Array;
}
export const SVC_REQUEST_MSG_ID = 6;
export const SVC_REQUEST_VERSION = 1;
export function encodeSvcRequest(msg: SvcRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SVC_REQUEST_MSG_ID);
  ctlPutU8(out, SVC_REQUEST_VERSION);
  ctlPutStr(out, msg.service);
  ctlPutBytes(out, msg.request);
  return Uint8Array.from(out);
}
export function decodeSvcRequest(bytes: Uint8Array): SvcRequest {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== SVC_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== SVC_REQUEST_VERSION) throw new WireError("unsupported message version");
  const service = ctlReadStr(cursor);
  const request = ctlReadBytes(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    service,
    request,
  };
}

// Structured host-control resident-service response. Status 0 means the service handled the call; nonzero is a transport errno.
export interface SvcResponse {
  status: number;
  body: Uint8Array;
}
export const SVC_RESPONSE_MSG_ID = 7;
export const SVC_RESPONSE_VERSION = 1;
export function encodeSvcResponse(msg: SvcResponse): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, SVC_RESPONSE_MSG_ID);
  ctlPutU8(out, SVC_RESPONSE_VERSION);
  ctlPutI32(out, msg.status);
  ctlPutBytes(out, msg.body);
  return Uint8Array.from(out);
}
export function decodeSvcResponse(bytes: Uint8Array): SvcResponse {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== SVC_RESPONSE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== SVC_RESPONSE_VERSION) throw new WireError("unsupported message version");
  const status = ctlReadI32(cursor);
  const body = ctlReadBytes(cursor);
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    status,
    body,
  };
}

// Structured BEAM egress relay event. `kind` selects which optional payload fields are present.
export interface RelayEvent {
  kind: string;
  handle: number;
  request?: Uint8Array | null;
  name?: string | null;
  body?: Uint8Array | null;
  key?: Uint8Array | null;
  value?: Uint8Array | null;
  prefix?: Uint8Array | null;
  url?: string | null;
  data?: Uint8Array | null;
  connection?: string | null;
  method?: string | null;
  origin?: string | null;
  args_digest?: string | null;
}
export const RELAY_EVENT_MSG_ID = 8;
export const RELAY_EVENT_VERSION = 1;
export function encodeRelayEvent(msg: RelayEvent): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, RELAY_EVENT_MSG_ID);
  ctlPutU8(out, RELAY_EVENT_VERSION);
  ctlPutStr(out, msg.kind);
  ctlPutI32(out, msg.handle);
  if (msg.request === undefined || msg.request === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.request);
  }
  if (msg.name === undefined || msg.name === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.name);
  }
  if (msg.body === undefined || msg.body === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.body);
  }
  if (msg.key === undefined || msg.key === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.key);
  }
  if (msg.value === undefined || msg.value === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.value);
  }
  if (msg.prefix === undefined || msg.prefix === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.prefix);
  }
  if (msg.url === undefined || msg.url === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.url);
  }
  if (msg.data === undefined || msg.data === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, msg.data);
  }
  if (msg.connection === undefined || msg.connection === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.connection);
  }
  if (msg.method === undefined || msg.method === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.method);
  }
  if (msg.origin === undefined || msg.origin === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.origin);
  }
  if (msg.args_digest === undefined || msg.args_digest === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.args_digest);
  }
  return Uint8Array.from(out);
}
export function decodeRelayEvent(bytes: Uint8Array): RelayEvent {
  const cursor: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(cursor) !== RELAY_EVENT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(cursor) !== RELAY_EVENT_VERSION) throw new WireError("unsupported message version");
  const kind = ctlReadStr(cursor);
  const handle = ctlReadI32(cursor);
  let request: Uint8Array | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: request = undefined; break;
    case 1: request = ctlReadBytes(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let name: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: name = undefined; break;
    case 1: name = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let body: Uint8Array | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: body = undefined; break;
    case 1: body = ctlReadBytes(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let key: Uint8Array | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: key = undefined; break;
    case 1: key = ctlReadBytes(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let value: Uint8Array | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: value = undefined; break;
    case 1: value = ctlReadBytes(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let prefix: Uint8Array | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: prefix = undefined; break;
    case 1: prefix = ctlReadBytes(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let url: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: url = undefined; break;
    case 1: url = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let data: Uint8Array | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: data = undefined; break;
    case 1: data = ctlReadBytes(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let connection: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: connection = undefined; break;
    case 1: connection = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let method: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: method = undefined; break;
    case 1: method = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let origin: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: origin = undefined; break;
    case 1: origin = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  let args_digest: string | undefined;
  switch (ctlReadU8(cursor)) {
    case 0: args_digest = undefined; break;
    case 1: args_digest = ctlReadStr(cursor); break;
    default: throw new WireError("invalid optional presence");
  }
  if (cursor.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    kind,
    handle,
    request,
    name,
    body,
    key,
    value,
    prefix,
    url,
    data,
    connection,
    method,
    origin,
    args_digest,
  };
}


export const CONTROL_EXPORTS = [
  "mc_init",
  "mc_tick",
  "mc_input",
  "mc_resize",
  "mc_ctl_buf",
  "mc_ctl_read",
  "mc_ctl_readlink",
  "mc_ctl_write",
  "mc_ctl_readdir",
  "mc_ctl_stat",
  "mc_ctl_mkdir",
  "mc_ctl_unlink",
  "mc_ctl_chmod",
  "mc_ctl_symlink",
  "mc_ctl_mount",
  "mc_ctl_unmount",
  "mc_ctl_exec_start",
  "mc_ctl_exec_poll",
  "mc_ctl_exec_peek",
  "mc_ctl_exec_close",
  "mc_ctl_svc_call_start",
  "mc_ctl_svc_call_poll",
  "mc_ctl_svc_call_close",
  "mc_commit_layer",
  "mc_inflight_egress",
  "mc_pending_commits",
  "mc_quiesce_request",
  "mc_quiesce_release",
  "mc_worker_entry",
] as const;

export const EXPORTS = [
  { name: "mc_init", variant: "Init", args: [], ret: "i32" },
  { name: "mc_tick", variant: "Tick", args: [], ret: "i32" },
  { name: "mc_input", variant: "Input", args: [{ name: "ptr", type: "cptr" }, { name: "len", type: "len" }], ret: "void" },
  { name: "mc_resize", variant: "Resize", args: [{ name: "cols", type: "i32" }, { name: "rows", type: "i32" }], ret: "void" },
  { name: "mc_ctl_buf", variant: "Buf", args: [{ name: "len", type: "len" }], ret: "mptr" },
  { name: "mc_ctl_read", variant: "Read", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_readlink", variant: "Readlink", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_write", variant: "Write", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }, { name: "data_ptr", type: "u32" }, { name: "data_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_readdir", variant: "Readdir", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_stat", variant: "Stat", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_mkdir", variant: "Mkdir", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_unlink", variant: "Unlink", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_chmod", variant: "Chmod", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }, { name: "mode", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_symlink", variant: "Symlink", args: [{ name: "target_ptr", type: "u32" }, { name: "target_len", type: "u32" }, { name: "link_ptr", type: "u32" }, { name: "link_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_mount", variant: "Mount", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }, { name: "read_only", type: "i32" }], ret: "i32" },
  { name: "mc_ctl_unmount", variant: "Unmount", args: [{ name: "path_ptr", type: "u32" }, { name: "path_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_exec_start", variant: "ExecStart", args: [{ name: "request_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_exec_poll", variant: "ExecPoll", args: [{ name: "job_id", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_exec_peek", variant: "ExecPeek", args: [{ name: "job_id", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_exec_close", variant: "ExecClose", args: [{ name: "job_id", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_svc_call_start", variant: "SvcCallStart", args: [{ name: "request_len", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_svc_call_poll", variant: "SvcCallPoll", args: [{ name: "job_id", type: "u32" }], ret: "i32" },
  { name: "mc_ctl_svc_call_close", variant: "SvcCallClose", args: [{ name: "job_id", type: "u32" }], ret: "i32" },
  { name: "mc_commit_layer", variant: "CommitLayer", args: [], ret: "i32" },
  { name: "mc_inflight_egress", variant: "InflightEgress", args: [], ret: "i32" },
  { name: "mc_pending_commits", variant: "PendingCommits", args: [], ret: "i32" },
  { name: "mc_quiesce_request", variant: "QuiesceRequest", args: [], ret: "i32" },
  { name: "mc_quiesce_release", variant: "QuiesceRelease", args: [], ret: "i32" },
  { name: "mc_worker_entry", variant: "WorkerEntry", args: [{ name: "arg", type: "i32" }], ret: "i32" },
] as const;
