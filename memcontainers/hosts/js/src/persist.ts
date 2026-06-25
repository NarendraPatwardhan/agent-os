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
import type { PersistCapability } from "./types.js";

/** The default: no persistence. Every call refuses with -1 (mirrors Rust `DeniedPersist`). */
export class DeniedPersist implements PersistCapability {
  get(): number {
    return -1;
  }
  put(): number {
    return -1;
  }
  delete(): number {
    return -1;
  }
  list(): number {
    return -1;
  }
}

/** A directory-backed key/value store (mirrors Rust `DiskPersist`): keys are hex-encoded to safe flat
 *  filenames, writes are atomic (temp + rename), list returns NUL-separated sorted keys. Return codes
 *  match the bridge contract. The node/bun durability path; the browser uses OpfsPersist. */
export class DiskPersist implements PersistCapability {
  constructor(private readonly dir: string) {
    mkdirSync(dir, { recursive: true });
  }

  private pathFor(key: Uint8Array): string {
    return join(this.dir, hexEncode(key));
  }

  get(key: Uint8Array, out: Uint8Array): number {
    const path = this.pathFor(key);
    if (!existsSync(path)) return -2;
    try {
      const value = new Uint8Array(readFileSync(path));
      const n = Math.min(value.length, out.length);
      out.set(value.subarray(0, n));
      return value.length; // FULL length
    } catch {
      return -1;
    }
  }

  put(key: Uint8Array, val: Uint8Array): number {
    const tmp = this.pathFor(key) + ".tmp";
    try {
      writeFileSync(tmp, val);
      renameSync(tmp, this.pathFor(key));
      return 0;
    } catch {
      try {
        rmSync(tmp, { force: true });
      } catch {
        /* best effort */
      }
      return -1;
    }
  }

  delete(key: Uint8Array): number {
    try {
      rmSync(this.pathFor(key), { force: true }); // missing key is ok
      return 0;
    } catch {
      return -1;
    }
  }

  list(prefix: Uint8Array, out: Uint8Array): number {
    let keys: Uint8Array[];
    try {
      keys = [];
      for (const name of readdirSync(this.dir)) {
        if (name.endsWith(".tmp")) continue; // skip in-flight writes
        const key = hexDecode(name);
        if (key && startsWith(key, prefix)) keys.push(key);
      }
    } catch {
      return -1;
    }
    keys.sort(compareBytes);
    let total = 0;
    for (const k of keys) total += k.length + 1;
    const blob = new Uint8Array(total);
    let off = 0;
    for (const k of keys) {
      blob.set(k, off);
      off += k.length;
      blob[off++] = 0; // NUL separator
    }
    const n = Math.min(blob.length, out.length);
    out.set(blob.subarray(0, n));
    return blob.length; // FULL length
  }
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
