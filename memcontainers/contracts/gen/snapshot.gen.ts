// @generated from contracts/snapshot.kdl by //contracts/codegen:projector — do not edit.

export const SNAPSHOT_MAGIC = 1314079565;
export const SNAPSHOT_VERSION = 2;
export const SNAPSHOT_HEADER_LEN = 128;
export const SNAPSHOT_PAGE_SIZE = 65536;
export const SNAPSHOT_MAX_MEMORY_LEN = 1073741824;
export const SNAPSHOT_DIGEST_LEN = 32;
export const SNAPSHOT_KIND_FULL = 1;
export const SNAPSHOT_KIND_INCREMENTAL = 2;
export type SnapshotKind = "full" | "incremental";
export type SnapshotErrorCode = "too_short" | "bad_magic" | "unsupported_version" | "unknown_kind" |
  "bad_header_length" | "bad_page_size" | "empty_memory" | "memory_too_large" | "misaligned_memory" |
  "reserved_nonzero" | "missing_digest" | "unexpected_base" | "missing_base" |
  "unexpected_changed_pages" | "bad_bitmap" | "length_mismatch";
export class SnapshotFormatError extends Error {
  constructor(readonly code: SnapshotErrorCode) { super(`invalid snapshot: ${code}`); this.name = "SnapshotFormatError"; }
}
export interface SnapshotView {
  kind: SnapshotKind; memoryLen: number; changedPages: number; kernelDigest: Uint8Array;
  memoryDigest: Uint8Array; baseSnapshotDigest: Uint8Array; bitmap: Uint8Array; pages: Uint8Array;
}
const missing = (d: Uint8Array): boolean => d.every((b) => b === 0);
export const snapshotBitmapLen = (memoryLen: number): number => Math.ceil(memoryLen / SNAPSHOT_PAGE_SIZE / 8);
export function parseSnapshot(bytes: Uint8Array): SnapshotView {
  const fail = (code: SnapshotErrorCode): never => { throw new SnapshotFormatError(code); };
  if (bytes.length < SNAPSHOT_HEADER_LEN) fail("too_short");
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (dv.getUint32(0, true) !== SNAPSHOT_MAGIC) fail("bad_magic");
  if (dv.getUint32(4, true) !== SNAPSHOT_VERSION) fail("unsupported_version");
  const rawKind = dv.getUint32(8, true);
  const kind: SnapshotKind = rawKind === SNAPSHOT_KIND_FULL ? "full" :
    rawKind === SNAPSHOT_KIND_INCREMENTAL ? "incremental" : fail("unknown_kind");
  if (dv.getUint32(12, true) !== SNAPSHOT_HEADER_LEN) fail("bad_header_length");
  if (dv.getUint32(16, true) !== SNAPSHOT_PAGE_SIZE) fail("bad_page_size");
  const memoryLen = dv.getUint32(20, true);
  if (memoryLen === 0) fail("empty_memory");
  if (memoryLen > SNAPSHOT_MAX_MEMORY_LEN) fail("memory_too_large");
  if (memoryLen % SNAPSHOT_PAGE_SIZE !== 0) fail("misaligned_memory");
  const changedPages = dv.getUint32(24, true);
  if (dv.getUint32(28, true) !== 0) fail("reserved_nonzero");
  const kernelDigest = bytes.slice(32, 32 + SNAPSHOT_DIGEST_LEN),
    memoryDigest = bytes.slice(64, 64 + SNAPSHOT_DIGEST_LEN),
    baseSnapshotDigest = bytes.slice(96, 96 + SNAPSHOT_DIGEST_LEN);
  if (missing(kernelDigest) || missing(memoryDigest)) fail("missing_digest");
  const payload = bytes.subarray(SNAPSHOT_HEADER_LEN);
  if (kind === "full") {
    if (!missing(baseSnapshotDigest)) fail("unexpected_base");
    if (changedPages !== 0) fail("unexpected_changed_pages");
    if (payload.length !== memoryLen) fail("length_mismatch");
    return { kind, memoryLen, changedPages, kernelDigest, memoryDigest, baseSnapshotDigest,
      bitmap: new Uint8Array(0), pages: payload };
  }
  if (missing(baseSnapshotDigest)) fail("missing_base");
  const bitmapLen = snapshotBitmapLen(memoryLen);
  if (payload.length < bitmapLen) fail("length_mismatch");
  const bitmap = payload.subarray(0, bitmapLen), memoryPages = memoryLen / SNAPSHOT_PAGE_SIZE;
  if (memoryPages % 8 !== 0 && (bitmap[bitmap.length - 1]! >>> (memoryPages % 8)) !== 0) fail("bad_bitmap");
  let pop = 0;
  for (const byte of bitmap) { let b = byte; while (b !== 0) { b &= b - 1; pop++; } }
  if (pop !== changedPages) fail("bad_bitmap");
  if (payload.length !== bitmapLen + changedPages * SNAPSHOT_PAGE_SIZE) fail("length_mismatch");
  return { kind, memoryLen, changedPages, kernelDigest, memoryDigest, baseSnapshotDigest,
    bitmap, pages: payload.subarray(bitmapLen) };
}
export function writeSnapshotHeader(kind: SnapshotKind, memoryLen: number, changedPages: number,
  kernelDigest: Uint8Array, memoryDigest: Uint8Array, baseSnapshotDigest: Uint8Array): Uint8Array {
  if (!Number.isInteger(memoryLen) || !Number.isInteger(changedPages) ||
      changedPages < 0 || changedPages > 0xffffffff ||
      kernelDigest.length !== SNAPSHOT_DIGEST_LEN || memoryDigest.length !== SNAPSHOT_DIGEST_LEN ||
      baseSnapshotDigest.length !== SNAPSHOT_DIGEST_LEN) throw new SnapshotFormatError("length_mismatch");
  if (memoryLen <= 0) throw new SnapshotFormatError("empty_memory");
  if (memoryLen > SNAPSHOT_MAX_MEMORY_LEN) throw new SnapshotFormatError("memory_too_large");
  if (memoryLen % SNAPSHOT_PAGE_SIZE !== 0) throw new SnapshotFormatError("misaligned_memory");
  if (missing(kernelDigest) || missing(memoryDigest)) throw new SnapshotFormatError("missing_digest");
  if (kind === "full" && !missing(baseSnapshotDigest)) throw new SnapshotFormatError("unexpected_base");
  if (kind === "full" && changedPages !== 0) throw new SnapshotFormatError("unexpected_changed_pages");
  if (kind === "incremental" && missing(baseSnapshotDigest)) throw new SnapshotFormatError("missing_base");
  if (kind === "incremental" && changedPages > memoryLen / SNAPSHOT_PAGE_SIZE)
    throw new SnapshotFormatError("length_mismatch");
  const out = new Uint8Array(SNAPSHOT_HEADER_LEN), dv = new DataView(out.buffer);
  dv.setUint32(0, SNAPSHOT_MAGIC, true); dv.setUint32(4, SNAPSHOT_VERSION, true);
  dv.setUint32(8, kind === "full" ? SNAPSHOT_KIND_FULL : SNAPSHOT_KIND_INCREMENTAL, true);
  dv.setUint32(12, SNAPSHOT_HEADER_LEN, true); dv.setUint32(16, SNAPSHOT_PAGE_SIZE, true);
  dv.setUint32(20, memoryLen, true); dv.setUint32(24, changedPages, true);
  out.set(kernelDigest, 32); out.set(memoryDigest, 64);
  out.set(baseSnapshotDigest, 96); return out;
}
