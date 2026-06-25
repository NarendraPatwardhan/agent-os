// Linear-memory access for the kernel's exported `memory`.
//
// THE JS GOTCHA: `WebAssembly.Memory.grow` — at boot (the scratch page) *and* whenever the kernel's
// Talc allocator grows the heap mid-run — DETACHES and replaces `memory.buffer`. Any cached
// `Uint8Array`/`DataView` over the old buffer becomes a zero-length detached view. So every access
// re-derives a fresh view from `memory.buffer`. (wasmtime hides this via `Memory::data_mut(&caller)`;
// the JS host must do it by hand.)

const WASM_PAGE_SIZE = 65536;

export class Mem {
  constructor(private readonly memory: WebAssembly.Memory) {}

  /** A fresh view over current memory — never cache the result. */
  private u8(): Uint8Array {
    return new Uint8Array(this.memory.buffer);
  }

  /** Copy `len` bytes out of guest memory at `ptr`. */
  read(ptr: number, len: number): Uint8Array {
    return this.u8().slice(ptr, ptr + len);
  }

  /** Decode a UTF-8 string out of guest memory. */
  readString(ptr: number, len: number): string {
    return new TextDecoder().decode(this.read(ptr, len));
  }

  /** Write `data` into guest memory at `ptr`. Returns false if out of range (matching the Rust host,
   *  which validates every `[ptr, ptr+len)` range against current memory before trusting it). */
  write(ptr: number, data: Uint8Array): boolean {
    const mem = this.u8();
    if (ptr < 0 || ptr + data.length > mem.length) return false;
    mem.set(data, ptr);
    return true;
  }

  /** Grow by one page; returns the previous page count (the scratch base). */
  growOnePage(): number {
    return this.memory.grow(1);
  }

  static get pageSize(): number {
    return WASM_PAGE_SIZE;
  }
}
