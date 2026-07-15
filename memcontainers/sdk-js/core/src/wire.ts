// Hand-written codecs for the typed per-VM WebSocket. The numeric registry is generated from
// contracts/wire.kdl and consumed here; only the byte envelope and host-call inner bodies live in
// this file.

import {
  HEADER_LEN,
  HELLO,
  WELCOME,
  SHELL_IN,
  SHELL_OUT,
  HOST_CALL,
  HOST_RESULT,
  HOST_CANCEL,
  SESSION_START,
  SESSION_EVENT,
  SESSION_END,
  PERMISSION_REQUEST,
  PERMISSION_RESPONSE,
  MESSAGES,
} from "@mc/contracts/wire";

export * from "@mc/contracts/wire";

export const Kind = {
  Hello: HELLO,
  Welcome: WELCOME,
  ShellIn: SHELL_IN,
  ShellOut: SHELL_OUT,
  HostCall: HOST_CALL,
  HostResult: HOST_RESULT,
  HostCancel: HOST_CANCEL,
  SessionStart: SESSION_START,
  SessionEvent: SESSION_EVENT,
  SessionEnd: SESSION_END,
  PermissionRequest: PERMISSION_REQUEST,
  PermissionResponse: PERMISSION_RESPONSE,
} as const;

export const BINARY_KINDS: Set<number> = new Set<number>(
  MESSAGES.filter((message) => message.body === "binary").map((message) => message.tag),
);

export interface DecodedFrame {
  kind: number;
  seq: number;
  json?: unknown;
  bytes?: Uint8Array;
}

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const dec = (b: Uint8Array): string => new TextDecoder().decode(b);

export function encodeFrame(kind: number, seq: number, body: Uint8Array | object): Uint8Array {
  const payload = BINARY_KINDS.has(kind) ? (body as Uint8Array) : enc(JSON.stringify(body));
  const out = new Uint8Array(HEADER_LEN + payload.length);
  out[0] = kind;
  new DataView(out.buffer).setBigUint64(1, BigInt(seq), true);
  out.set(payload, HEADER_LEN);
  return out;
}

export function decodeFrame(frame: Uint8Array): DecodedFrame {
  if (frame.length < HEADER_LEN) throw new Error("short wire frame");
  const dv = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const kind = frame[0]!;
  const seq = Number(dv.getBigUint64(1, true));
  const body = frame.subarray(HEADER_LEN);
  if (BINARY_KINDS.has(kind)) return { kind, seq, bytes: body };
  return { kind, seq, json: body.length ? JSON.parse(dec(body)) : undefined };
}

export function encodeHostCall(id: number, name: string, body: Uint8Array): Uint8Array {
  const nameBytes = enc(name);
  const out = new Uint8Array(8 + nameBytes.length + body.length);
  const dv = new DataView(out.buffer);
  dv.setInt32(0, id, true);
  dv.setUint32(4, nameBytes.length, true);
  out.set(nameBytes, 8);
  out.set(body, 8 + nameBytes.length);
  return out;
}

export function decodeHostCall(body: Uint8Array): { id: number; name: string; body: Uint8Array } {
  if (body.length < 8) throw new Error("short host-call frame");
  const dv = new DataView(body.buffer, body.byteOffset, body.byteLength);
  const id = dv.getInt32(0, true);
  const nameLen = dv.getUint32(4, true);
  if (8 + nameLen > body.length) throw new Error("truncated host-call name");
  return {
    id,
    name: dec(body.subarray(8, 8 + nameLen)),
    body: body.subarray(8 + nameLen),
  };
}

export function encodeHostResult(id: number, result: Uint8Array): Uint8Array {
  const out = new Uint8Array(4 + result.length);
  new DataView(out.buffer).setInt32(0, id, true);
  out.set(result, 4);
  return out;
}

export function decodeHostResult(body: Uint8Array): { id: number; result: Uint8Array } {
  if (body.length < 4) throw new Error("short host-result frame");
  const id = new DataView(body.buffer, body.byteOffset, body.byteLength).getInt32(0, true);
  return { id, result: body.subarray(4) };
}

export function decodeHostCancel(body: Uint8Array): number {
  if (body.length !== 4) throw new Error("invalid host-cancel frame");
  return new DataView(body.buffer, body.byteOffset, body.byteLength).getInt32(0, true);
}
