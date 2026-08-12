/** Standard WebAssembly host adapter for the freestanding Gitz engine. */

import {
  BACKEND_BROWSER,
  CAPABILITY_CORE,
  ENVELOPE_HEADER_BYTES,
  MAX_FRAME_BYTES,
  MAX_RESULT_BYTES,
  PROTOCOL_MINOR,
  PROTOCOL_VERSION,
  STATUS_ERROR,
  decodeCommitResult,
  decodeEngineDescription,
  decodeEngineError,
  decodeFileResult,
  decodeResolveResult,
  decodeResult,
  decodeStatusResult,
  decodeResponseEnvelope,
  encodeRequestEnvelope,
  encodeFileRequest,
  encodePorcelainRequest,
  encodeSessionConfig,
  type CommitResult,
  type EngineDescription,
  type FileRequest,
  type FileResult,
  type PorcelainRequest,
  type ResolveResult,
  type Result,
  type StatusResult,
  type GitResponseEnvelope,
} from "@mc/contracts/git";

export const DEFAULT_WORK_ROOT = "";

export type GitWasmExports = {
  memory: WebAssembly.Memory;
  ao_git_abi_version(): number;
  ao_git_capabilities(): bigint;
  ao_git_buffer_alloc(length: number): number;
  ao_git_buffer_free(pointer: number, length: number): number;
  ao_git_session_open(pointer: number, length: number): number;
  ao_git_session_close(session: number): number;
  ao_git_execute(session: number, pointer: number, length: number): number;
  ao_git_result_len(result: number): number;
  ao_git_result_read(result: number, offset: number, pointer: number, capacity: number): number;
  ao_git_result_free(result: number): number;
};

export type GitBridgeCreateOptions = {
  workRoot?: string;
  readOnly?: boolean;
  restore?: Uint8Array;
};

/** One freestanding module instance owns its sessions, in-memory repositories, and handles. */
export class GitBridge {
  private queue: Promise<unknown> = Promise.resolve();
  private requestId = 0;
  private closed = false;

  private constructor(
    readonly module: WebAssembly.Module,
    readonly exports: GitWasmExports,
    public session: number,
    readonly workRoot: string,
  ) {}

  static async create(wasm: Uint8Array, opts: GitBridgeCreateOptions = {}): Promise<GitBridge> {
    const module = await WebAssembly.compile(wasm);
    const imports = WebAssembly.Module.imports(module);
    if (imports.length !== 0) {
      throw new Error(`git_engine.wasm must be freestanding; found ${imports.length} imports`);
    }
    const instance = await WebAssembly.instantiate(module, {});
    const exports = validateExports(instance.exports);
    const actualAbi = exports.ao_git_abi_version() >>> 0;
    const expectedAbi = ((PROTOCOL_VERSION << 16) | PROTOCOL_MINOR) >>> 0;
    if (actualAbi !== expectedAbi) {
      throw new Error(`unsupported Git engine ABI 0x${actualAbi.toString(16)}`);
    }
    if ((exports.ao_git_capabilities() & BigInt(CAPABILITY_CORE)) === 0n) {
      throw new Error("git_engine.wasm does not provide the core Git capability");
    }
    const config = encodeSessionConfig({
      backend: BACKEND_BROWSER,
      read_only: !!opts.readOnly,
      root: opts.workRoot ?? DEFAULT_WORK_ROOT,
      restore: opts.restore ? owned(opts.restore) : undefined,
    });
    const resultHandle = copyInAndCall(exports, config, (ptr, len) =>
      exports.ao_git_session_open(ptr, len),
    );
    const opened = takeResult(exports, resultHandle);
    const envelope = decodeResponseEnvelope(opened);
    if (envelope.status === STATUS_ERROR) throw engineError(envelope);
    const result = decodeResult(envelope.payload);
    if (!result.handle) throw new Error("Git engine session.open returned no session handle");
    return new GitBridge(module, exports, result.handle, opts.workRoot ?? DEFAULT_WORK_ROOT);
  }

  serial<T>(fn: () => T | Promise<T>): Promise<T> {
    const next = this.queue.then(fn, fn) as Promise<T>;
    this.queue = next.then(() => undefined, () => undefined);
    return next;
  }

  execute(opcode: number, payload = new Uint8Array()): GitResponseEnvelope {
    if (this.closed || !this.session) throw new Error("Git engine session is closed");
    const requestId = (this.requestId = (this.requestId + 1) >>> 0 || 1);
    return this.executeForRequest(opcode, requestId, payload);
  }

  /** Continue an engine-owned effect exchange using its original request identity. */
  executeForRequest(opcode: number, requestId: number, payload = new Uint8Array()): GitResponseEnvelope {
    if (this.closed || !this.session) throw new Error("Git engine session is closed");
    if (!Number.isInteger(requestId) || requestId < 1 || requestId > 0xffff_ffff) {
      throw new Error("invalid Git engine request identity");
    }
    const frame = encodeRequestEnvelope(opcode, 0, requestId, owned(payload));
    const resultHandle = copyInAndCall(this.exports, frame, (ptr, len) =>
      this.exports.ao_git_execute(this.session, ptr, len),
    );
    const envelope = decodeResponseEnvelope(takeResult(this.exports, resultHandle));
    if (envelope.requestId !== requestId) {
      throw new Error("Git engine returned a response for a different request");
    }
    if (envelope.status === STATUS_ERROR) throw engineError(envelope);
    return envelope;
  }

  describe(opcode: number): EngineDescription {
    return decodeEngineDescription(this.execute(opcode).payload);
  }

  result(opcode: number, payload = new Uint8Array()): Result {
    return decodeResult(this.execute(opcode, payload).payload);
  }

  file(opcode: number, request: FileRequest): FileResult {
    return decodeFileResult(owned(this.execute(opcode, owned(encodeFileRequest(request))).payload));
  }

  porcelain(opcode: number, request: PorcelainRequest): Uint8Array {
    return owned(this.execute(opcode, owned(encodePorcelainRequest(request))).payload);
  }

  status(opcode: number): StatusResult {
    return decodeStatusResult(this.execute(opcode).payload);
  }

  commit(opcode: number, request: PorcelainRequest): CommitResult {
    return decodeCommitResult(owned(this.execute(opcode, owned(encodePorcelainRequest(request))).payload));
  }

  resolve(opcode: number, request: PorcelainRequest): ResolveResult {
    return decodeResolveResult(owned(this.execute(opcode, owned(encodePorcelainRequest(request))).payload));
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    const session = this.session;
    this.session = 0;
    if (session && this.exports.ao_git_session_close(session) !== 0) {
      throw new Error("Git engine rejected session.close");
    }
  }
}

function validateExports(raw: WebAssembly.Exports): GitWasmExports {
  const required = [
    "memory", "ao_git_abi_version", "ao_git_capabilities", "ao_git_buffer_alloc",
    "ao_git_buffer_free", "ao_git_session_open", "ao_git_session_close", "ao_git_execute",
    "ao_git_result_len", "ao_git_result_read", "ao_git_result_free",
  ] as const;
  for (const name of required) if (!(name in raw)) throw new Error(`git_engine.wasm missing export ${name}`);
  return raw as unknown as GitWasmExports;
}

function copyInAndCall(
  exports: GitWasmExports,
  bytes: Uint8Array,
  call: (pointer: number, length: number) => number,
): number {
  if (bytes.byteLength > MAX_FRAME_BYTES) throw new Error("Git engine request exceeds MAX_FRAME_BYTES");
  const pointer = exports.ao_git_buffer_alloc(bytes.byteLength);
  if (!pointer && bytes.byteLength) throw new Error("Git engine request allocation failed");
  try {
    new Uint8Array(exports.memory.buffer, pointer, bytes.byteLength).set(bytes);
    const result = call(pointer, bytes.byteLength);
    if (!result) throw new Error("Git engine returned no result handle");
    return result;
  } finally {
    if (pointer && exports.ao_git_buffer_free(pointer, bytes.byteLength) !== 0) {
      throw new Error("Git engine request free failed");
    }
  }
}

function takeResult(exports: GitWasmExports, handle: number): Uint8Array {
  if (!handle) throw new Error("Git engine returned an invalid result handle");
  try {
    const length = exports.ao_git_result_len(handle) >>> 0;
    if (length < ENVELOPE_HEADER_BYTES || length > MAX_RESULT_BYTES) {
      throw new Error(`Git engine returned invalid result length ${length}`);
    }
    const pointer = exports.ao_git_buffer_alloc(length);
    if (!pointer) throw new Error("Git engine result allocation failed");
    try {
      const read = exports.ao_git_result_read(handle, 0, pointer, length) >>> 0;
      if (read !== length) throw new Error(`Git engine result short read ${read}/${length}`);
      return new Uint8Array(exports.memory.buffer, pointer, length).slice();
    } finally {
      if (exports.ao_git_buffer_free(pointer, length) !== 0) throw new Error("Git engine result buffer free failed");
    }
  } finally {
    if (exports.ao_git_result_free(handle) !== 0) throw new Error("Git engine result handle free failed");
  }
}

function owned(bytes: Uint8Array): Uint8Array<ArrayBuffer> { return Uint8Array.from(bytes); }

function engineError(envelope: GitResponseEnvelope): Error {
  let message = `Git engine operation ${envelope.opcode} failed`;
  let domain: number | undefined;
  let code: number | undefined;
  try {
    const detail = decodeEngineError(envelope.payload);
    domain = detail.domain;
    code = detail.code;
    if (detail.message) message = detail.message;
  } catch { /* malformed errors still fail closed */ }
  const error = new Error(message) as Error & { domain?: number; engineCode?: number; opcode?: number };
  error.domain = domain;
  error.engineCode = code;
  error.opcode = envelope.opcode;
  return error;
}
