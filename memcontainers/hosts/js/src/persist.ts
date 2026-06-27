import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  renameSync,
  rmSync,
  readdirSync,
} from "node:fs";
import { join } from "node:path";
import {
  PERSIST_GET_ABSENT,
  PERSIST_GET_PRESENT,
  PERSIST_OP_DELETE,
  PERSIST_OP_GET,
  PERSIST_OP_LIST,
  PERSIST_OP_PUT,
} from "@mc/contracts/constants";
import type { PersistCapability } from "./types.js";

export {
  PERSIST_OP_DELETE,
  PERSIST_OP_GET,
  PERSIST_OP_LIST,
  PERSIST_OP_PUT,
} from "@mc/contracts/constants";

const GET_ABSENT = PERSIST_GET_ABSENT;
const GET_PRESENT = PERSIST_GET_PRESENT;

interface Slot {
  result: Uint8Array;
  offset: number;
  failed: boolean;
}

/** Shared ready-slot machinery for persist implementations that complete work in `start`. */
export abstract class ReadyPersist implements PersistCapability {
  private readonly slots = new Map<number, Slot>();
  private next = 1;

  protected abstract run(op: number, key: Uint8Array, value: Uint8Array): Uint8Array;

  start(req: Uint8Array): number {
    const decoded = decodePersistRequest(req);
    if (!decoded) return -1;
    const handle = this.next;
    this.next = this.next + 1 < 1 ? 1 : this.next + 1;
    try {
      this.slots.set(handle, {
        result: this.run(decoded.op, decoded.key, decoded.value),
        offset: 0,
        failed: false,
      });
    } catch {
      this.slots.set(handle, { result: new Uint8Array(0), offset: 0, failed: true });
    }
    return handle;
  }

  poll(handle: number): number {
    const slot = this.slots.get(handle);
    if (!slot || slot.failed) return -1;
    return 1;
  }

  body(handle: number, buf: Uint8Array): number {
    const slot = this.slots.get(handle);
    if (!slot || slot.failed) return -1;
    const remaining = slot.result.subarray(slot.offset);
    const n = Math.min(remaining.length, buf.length);
    buf.set(remaining.subarray(0, n), 0);
    slot.offset += n;
    return n;
  }

  close(handle: number): void {
    this.slots.delete(handle);
  }
}

/** The default: no persistence. Every start refuses with -1 (mirrors Rust `DeniedPersist`). */
export class DeniedPersist implements PersistCapability {
  start(): number {
    return -1;
  }
  poll(): number {
    return -1;
  }
  body(): number {
    return -1;
  }
  close(): void {}
}

/** A directory-backed key/value store (mirrors Rust `DiskPersist`). */
export class DiskPersist extends ReadyPersist {
  constructor(private readonly dir: string) {
    super();
    mkdirSync(dir, { recursive: true });
  }

  protected run(op: number, key: Uint8Array, value: Uint8Array): Uint8Array {
    switch (op) {
      case PERSIST_OP_GET:
        return this.getBody(key);
      case PERSIST_OP_PUT:
        this.putValue(key, value);
        return new Uint8Array(0);
      case PERSIST_OP_DELETE:
        this.deleteValue(key);
        return new Uint8Array(0);
      case PERSIST_OP_LIST:
        return this.listBody(key);
      default:
        throw new Error(`unknown persist op ${op}`);
    }
  }

  private pathFor(key: Uint8Array): string {
    return join(this.dir, hexEncode(key));
  }

  private getBody(key: Uint8Array): Uint8Array {
    const path = this.pathFor(key);
    if (!existsSync(path)) return new Uint8Array([GET_ABSENT]);
    const value = new Uint8Array(readFileSync(path));
    const body = new Uint8Array(value.length + 1);
    body[0] = GET_PRESENT;
    body.set(value, 1);
    return body;
  }

  private putValue(key: Uint8Array, val: Uint8Array): void {
    const tmp = this.pathFor(key) + ".tmp";
    try {
      writeFileSync(tmp, val);
      renameSync(tmp, this.pathFor(key));
    } catch (e) {
      try {
        rmSync(tmp, { force: true });
      } catch {
        /* best effort */
      }
      throw e;
    }
  }

  private deleteValue(key: Uint8Array): void {
    rmSync(this.pathFor(key), { force: true });
  }

  private listBody(prefix: Uint8Array): Uint8Array {
    const keys: Uint8Array[] = [];
    for (const name of readdirSync(this.dir)) {
      if (name.endsWith(".tmp")) continue;
      const key = hexDecode(name);
      if (key && startsWith(key, prefix)) keys.push(key);
    }
    keys.sort(compareBytes);
    return encodeKeyList(keys);
  }
}

export function encodeKeyList(keys: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const k of keys) total += k.length + 1;
  const blob = new Uint8Array(total);
  let off = 0;
  for (const k of keys) {
    blob.set(k, off);
    off += k.length;
    blob[off++] = 0;
  }
  return blob;
}

export function getPresentBody(value: Uint8Array): Uint8Array {
  const body = new Uint8Array(value.length + 1);
  body[0] = GET_PRESENT;
  body.set(value, 1);
  return body;
}

export function getAbsentBody(): Uint8Array {
  return new Uint8Array([GET_ABSENT]);
}

export function decodePersistRequest(req: Uint8Array): {
  op: number;
  key: Uint8Array;
  value: Uint8Array;
} | null {
  if (req.length < 8) return null;
  const dv = new DataView(req.buffer, req.byteOffset, req.byteLength);
  const op = dv.getUint32(0, true);
  const keyLen = dv.getUint32(4, true);
  const keyStart = 8;
  const keyEnd = keyStart + keyLen;
  if (keyEnd > req.length) return null;
  return { op, key: req.subarray(keyStart, keyEnd), value: req.subarray(keyEnd) };
}

function hexEncode(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += x.toString(16).padStart(2, "0");
  return s;
}

function hexDecode(s: string): Uint8Array | null {
  if (s.length % 2 !== 0) return null;
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) {
    const v = parseInt(s.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(v)) return null;
    out[i] = v;
  }
  return out;
}

function startsWith(key: Uint8Array, prefix: Uint8Array): boolean {
  if (prefix.length > key.length) return false;
  for (let i = 0; i < prefix.length; i++) if (key[i] !== prefix[i]) return false;
  return true;
}

function compareBytes(a: Uint8Array, b: Uint8Array): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const d = (a[i] as number) - (b[i] as number);
    if (d !== 0) return d;
  }
  return a.length - b.length;
}
