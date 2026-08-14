import { readSync, writeSync } from "node:fs";
import { RUNNER_MAX_FRAME_BYTES } from "./runner.gen";

export function readFrame(): Uint8Array {
  const lengthBytes = readExact(4);
  const length = new DataView(lengthBytes.buffer, lengthBytes.byteOffset, 4).getUint32(0, false);
  if (length === 0 || length > RUNNER_MAX_FRAME_BYTES) throw new Error("invalid frame length");
  return readExact(length);
}

export function writeFrame(frame: Uint8Array): void {
  if (frame.length === 0 || frame.length > RUNNER_MAX_FRAME_BYTES) {
    throw new Error("invalid frame length");
  }
  const prefix = new Uint8Array(4);
  new DataView(prefix.buffer).setUint32(0, frame.length, false);
  writeAll(prefix);
  writeAll(frame);
}

function readExact(length: number): Uint8Array {
  const out = new Uint8Array(length);
  let offset = 0;
  while (offset < length) {
    const count = readSync(0, out, offset, length - offset, null);
    if (count === 0) throw new Error("end of stream");
    offset += count;
  }
  return out;
}

function writeAll(bytes: Uint8Array): void {
  let offset = 0;
  while (offset < bytes.length) {
    const written = writeSync(1, bytes, offset, bytes.length - offset);
    if (written <= 0) throw new Error("runner stream stopped accepting writes");
    offset += written;
  }
}
