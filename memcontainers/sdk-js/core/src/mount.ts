// Host-backed mount wire codec + driver dispatch (the host-call substrate, SYSTEMS.md §7.4). The
// kernel's `MountFs` proxies each VFS op to a host-resident driver over the `mc_host_call` bridge;
// this module is the host-side peer of that kernel `MountFs`. The byte layouts MUST stay in lockstep
// with the `MOUNT_OP_*` / `SERVE_DIRENT_*` / errno blocks — which is exactly why they come from the
// generated contract (the @mc/contracts/constants import below), the single source of truth.

import type { Driver, DriverEntry, DriverMeta, DriverError } from "./types.js";

// The opcodes, dirent kinds, and errnos all come from the generated contract — the SINGLE source of
// truth (contracts/constants.kdl → constants.gen.ts). The kernel's MountFs derives from the same
// table, so the two sides cannot drift (the prior hand-copied block was exactly the staleness this
// generated lane exists to kill).
import {
  MOUNT_OP_OPEN,
  MOUNT_OP_READDIR,
  MOUNT_OP_MKDIR,
  MOUNT_OP_UNLINK,
  MOUNT_OP_RENAME,
  MOUNT_OP_STAT,
  MOUNT_OP_WRITE,
  SERVE_DIRENT_FILE,
  SERVE_DIRENT_DIR,
  EPERM,
  EACCES,
  ENOENT,
  EINVAL,
  EIO,
  EEXIST,
  ENOTDIR,
  EISDIR,
  ENOTEMPTY,
} from "@mc/contracts/constants";

const STAT_RECORD_LEN = 44;

interface MountRequest {
  op: number;
  path: string;
  arg: string;
  data: Uint8Array;
}

/** Decode the `[op][path_len][path][arg_len][arg][data]` body the kernel sends
 *  (the leading `name\0` was already split off by the host-call router). */
function decodeRequest(body: Uint8Array): MountRequest {
  const dv = new DataView(body.buffer, body.byteOffset, body.byteLength);
  const op = dv.getUint32(0, true);
  const pathLen = dv.getUint32(4, true);
  const path = new TextDecoder().decode(body.subarray(8, 8 + pathLen));
  const argOff = 8 + pathLen;
  const argLen = dv.getUint32(argOff, true);
  const arg = new TextDecoder().decode(body.subarray(argOff + 4, argOff + 4 + argLen));
  // Copy the write payload out of the shared request buffer (an async driver may
  // outlive this call).
  const data = body.slice(argOff + 4 + argLen);
  return { op, path, arg, data };
}

function ok(payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(4 + payload.length);
  new DataView(out.buffer).setInt32(0, 0, true); // status 0 = ok
  out.set(payload, 4);
  return out;
}

function fail(errno: number): Uint8Array {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setInt32(0, errno, true);
  return out;
}

const EMPTY = new Uint8Array(0);

function encodeStat(m: DriverMeta): Uint8Array {
  const out = new Uint8Array(STAT_RECORD_LEN);
  const dv = new DataView(out.buffer);
  const isDir = m.kind === "dir";
  dv.setBigUint64(0, BigInt(Math.max(0, Math.floor(m.size))), true); // size
  dv.setUint32(8, isDir ? SERVE_DIRENT_DIR : SERVE_DIRENT_FILE, true); // node_type: the serve-dirent file/dir enum
  dv.setUint32(12, isDir ? 2 : 1, true); // nlink
  dv.setUint32(16, isDir ? 0o755 : 0o644, true); // mode
  // mtime/atime/ctime (i64 each at 20/28/36) stay 0 — synthetic.
  return out;
}

function encodeDirents(entries: DriverEntry[]): Uint8Array {
  const recs = entries.map((e) => {
    const name = new TextEncoder().encode(e.name);
    const rec = new Uint8Array(8 + name.length);
    const dv = new DataView(rec.buffer);
    dv.setUint32(0, e.kind === "dir" ? SERVE_DIRENT_DIR : SERVE_DIRENT_FILE, true);
    dv.setUint32(4, name.length, true);
    rec.set(name, 8);
    return rec;
  });
  const out = new Uint8Array(recs.reduce((n, r) => n + r.length, 0));
  let off = 0;
  for (const r of recs) {
    out.set(r, off);
    off += r.length;
  }
  return out;
}

function codeToErrno(e: unknown): number {
  switch ((e as DriverError | undefined)?.code) {
    case "ENOENT":
      return ENOENT;
    case "EACCES":
      return EACCES;
    case "EEXIST":
      return EEXIST;
    case "ENOTDIR":
      return ENOTDIR;
    case "EISDIR":
      return EISDIR;
    case "ENOTEMPTY":
      return ENOTEMPTY;
    case "EINVAL":
      return EINVAL;
    default:
      return EIO;
  }
}

/** Serve one mount request against `driver`, returning the encoded
 *  `[status:i32][payload]` response. A driver error becomes an in-band errno
 *  status (the host call itself still succeeds); a missing optional write method
 *  is `EACCES`. This is the raw host-call handler registered per mount. */
export async function dispatchMount(driver: Driver, body: Uint8Array): Promise<Uint8Array> {
  let req: MountRequest;
  try {
    req = decodeRequest(body);
  } catch {
    return fail(EINVAL);
  }
  // A driver flagged read-only refuses every mutation up front (belt-and-braces
  // with the kernel's read-only mount flag).
  const mutating =
    req.op === MOUNT_OP_WRITE ||
    req.op === MOUNT_OP_MKDIR ||
    req.op === MOUNT_OP_UNLINK ||
    req.op === MOUNT_OP_RENAME;
  if (mutating && driver.readOnly) return fail(EPERM);

  try {
    switch (req.op) {
      case MOUNT_OP_OPEN:
        return ok(await driver.open(req.path));
      case MOUNT_OP_STAT:
        return ok(encodeStat(await driver.stat(req.path)));
      case MOUNT_OP_READDIR:
        return ok(encodeDirents(await driver.readdir(req.path)));
      case MOUNT_OP_WRITE:
        if (!driver.write) return fail(EACCES);
        await driver.write(req.path, req.data);
        return ok(EMPTY);
      case MOUNT_OP_MKDIR:
        if (!driver.mkdir) return fail(EACCES);
        await driver.mkdir(req.path);
        return ok(EMPTY);
      case MOUNT_OP_UNLINK:
        if (!driver.unlink) return fail(EACCES);
        await driver.unlink(req.path);
        return ok(EMPTY);
      case MOUNT_OP_RENAME:
        if (!driver.rename) return fail(EACCES);
        await driver.rename(req.path, req.arg);
        return ok(EMPTY);
      default:
        return fail(EINVAL);
    }
  } catch (e) {
    return fail(codeToErrno(e));
  }
}
