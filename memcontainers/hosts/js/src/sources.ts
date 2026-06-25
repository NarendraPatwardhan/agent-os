import type { ClockSource, RngSource } from "./types.js";

/** Real wall-clock + monotonic time (mirrors Rust `SystemClock`). */
export class SystemClock implements ClockSource {
  nowMillis(): bigint {
    return BigInt(Date.now());
  }
  monotonicMillis(): bigint {
    // `performance.now()` is already monotonic; only monotonicity matters to the kernel, not the
    // absolute origin.
    return BigInt(Math.floor(performance.now()));
  }
}

/** Deterministic clock for replay (mirrors Rust `FixedClock`): a fixed epoch and a monotonic counter
 *  that ticks by 1 ms per read. This is what makes a run byte-for-byte replayable + the two hosts'
 *  output identical under `.deterministic()` (A7). */
export class FixedClock implements ClockSource {
  private mono = 0n;
  constructor(private readonly epoch: bigint = 1_700_000_000_000n) {}
  nowMillis(): bigint {
    return this.epoch;
  }
  monotonicMillis(): bigint {
    const v = this.mono;
    this.mono += 1n;
    return v;
  }
}

/** Real OS entropy (mirrors Rust `OsRng`). */
export class OsRng implements RngSource {
  fill(buf: Uint8Array): void {
    // crypto.getRandomValues rejects requests > 65536 bytes; chunk to be safe.
    for (let off = 0; off < buf.length; off += 65536) {
      crypto.getRandomValues(buf.subarray(off, Math.min(off + 65536, buf.length)));
    }
  }
}

/** A seeded SplitMix64 PRNG for deterministic runs (mirrors Rust `SeededRng`'s intent; the exact byte
 *  stream is NOT guaranteed to match the Rust version — determinism per host, not cross-language
 *  bit-parity). */
export class SeededRng implements RngSource {
  private state: bigint;
  private static readonly MASK = (1n << 64n) - 1n;
  constructor(seed: bigint = 0xdead_beef_cafe_f00dn) {
    this.state = seed & SeededRng.MASK;
  }
  private nextU64(): bigint {
    this.state = (this.state + 0x9e37_79b9_7f4a_7c15n) & SeededRng.MASK;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58_476d_1ce4_e5b9n) & SeededRng.MASK;
    z = ((z ^ (z >> 27n)) * 0x94d0_49bb_1331_11ebn) & SeededRng.MASK;
    return (z ^ (z >> 31n)) & SeededRng.MASK;
  }
  fill(buf: Uint8Array): void {
    let acc = 0n;
    let have = 0;
    for (let i = 0; i < buf.length; i++) {
      if (have === 0) {
        acc = this.nextU64();
        have = 8;
      }
      buf[i] = Number(acc & 0xffn);
      acc >>= 8n;
      have--;
    }
  }
}
