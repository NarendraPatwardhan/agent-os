import type { StreamSink } from "./types.js";

/** Buffers everything written, for tests and assertions (mirrors Rust `CaptureSink`). */
export class CaptureSink implements StreamSink {
  private chunks: Uint8Array[] = [];
  private len = 0;

  write(bytes: Uint8Array): void {
    this.chunks.push(bytes.slice());
    this.len += bytes.length;
  }

  /** Total bytes captured so far. */
  get length(): number {
    return this.len;
  }

  /** All captured bytes, concatenated. */
  bytes(): Uint8Array {
    const out = new Uint8Array(this.len);
    let off = 0;
    for (const c of this.chunks) {
      out.set(c, off);
      off += c.length;
    }
    return out;
  }

  /** Captured bytes from `offset` onward (a byte offset, e.g. a prior `length`). */
  bytesFrom(offset: number): Uint8Array {
    return this.bytes().subarray(offset);
  }

  text(): string {
    return new TextDecoder().decode(this.bytes());
  }
}

/** Forwards bytes to a callback (e.g. `process.stdout`). */
export class WritableSink implements StreamSink {
  constructor(private readonly out: (bytes: Uint8Array) => void) {}
  write(bytes: Uint8Array): void {
    this.out(bytes);
  }
}

/** The default stdout/stderr sinks: straight to the process streams (Node/Bun). */
export const processStdout = (): StreamSink =>
  new WritableSink((b) => void process.stdout.write(b));
export const processStderr = (): StreamSink =>
  new WritableSink((b) => void process.stderr.write(b));
