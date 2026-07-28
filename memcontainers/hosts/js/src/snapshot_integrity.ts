import { SNAPSHOT_INTEGRITY_CHUNK_SIZE } from "@mc/contracts/snapshot";

const encoder = new TextEncoder();
const LEAF_DOMAIN = encoder.encode("MCSN4-CHUNK\0");
const NODE_DOMAIN = encoder.encode("MCSN4-NODE\0");
const ROOT_DOMAIN = encoder.encode("MCSN4-ROOT\0");
const BASE_DOMAIN = encoder.encode("MCSN4-BASE\0");

export type ChunkHash = Uint8Array<ArrayBuffer>;

const u32le = (value: number): Uint8Array => {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setUint32(0, value, true);
  return bytes;
};

const sha256Parts = async (parts: readonly Uint8Array[]): Promise<ChunkHash> => {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const input = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    input.set(part, offset);
    offset += part.length;
  }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", input));
};

export const hashChunk = (index: number, chunk: Uint8Array): Promise<ChunkHash> =>
  sha256Parts([LEAF_DOMAIN, u32le(index), u32le(chunk.length), chunk]);

export async function chunkHashes(memory: Uint8Array): Promise<ChunkHash[]> {
  const pending: Promise<ChunkHash>[] = [];
  for (let start = 0, index = 0; start < memory.length; start += SNAPSHOT_INTEGRITY_CHUNK_SIZE, index++) {
    pending.push(hashChunk(index, memory.subarray(start, start + SNAPSHOT_INTEGRITY_CHUNK_SIZE)));
  }
  return Promise.all(pending);
}

const hashNode = (
  level: number,
  left: ChunkHash,
  right: ChunkHash,
): Promise<ChunkHash> => sha256Parts([NODE_DOMAIN, u32le(level), left, right]);

export class IntegrityTree {
  private constructor(
    readonly levels: ChunkHash[][],
    readonly memoryLen: number,
  ) {}

  static async fromMemory(memory: Uint8Array): Promise<IntegrityTree> {
    return IntegrityTree.create(await chunkHashes(memory), memory.length);
  }

  static async create(leaves: ChunkHash[], memoryLen: number): Promise<IntegrityTree> {
    if (leaves.length === 0) throw new Error("cannot hash empty snapshot memory");
    const levels = [leaves];
    for (let level = 1; levels[level - 1]!.length > 1; level++) {
      const prior = levels[level - 1]!;
      const pending: Promise<ChunkHash>[] = [];
      for (let i = 0; i < prior.length; i += 2) {
        pending.push(hashNode(level, prior[i]!, prior[i + 1] ?? prior[i]!));
      }
      levels.push(await Promise.all(pending));
    }
    return new IntegrityTree(levels, memoryLen);
  }

  clone(): IntegrityTree {
    return new IntegrityTree(
      this.levels.map((level) => level.map((hash) => hash.slice())),
      this.memoryLen,
    );
  }

  leaves(): readonly ChunkHash[] {
    return this.levels[0]!;
  }

  async update(chunk: number, value: ChunkHash): Promise<void> {
    this.levels[0]![chunk] = value;
    let child = chunk;
    for (let level = 1; level < this.levels.length; level++) {
      const parent = Math.floor(child / 2);
      const lower = this.levels[level - 1]!;
      const left = lower[parent * 2]!;
      const right = lower[parent * 2 + 1] ?? left;
      this.levels[level]![parent] = await hashNode(level, left, right);
      child = parent;
    }
  }

  root(): Promise<ChunkHash> {
    return sha256Parts([
      ROOT_DOMAIN,
      u32le(this.memoryLen),
      this.levels[this.levels.length - 1]![0]!,
    ]);
  }
}

export const baselineId = (
  kernelDigest: Uint8Array,
  memoryRoot: Uint8Array,
  memoryLen: number,
): Promise<ChunkHash> =>
  sha256Parts([BASE_DOMAIN, kernelDigest, memoryRoot, u32le(memoryLen)]);
