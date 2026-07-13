// The transport behind a Vm. Embedded (in-process KernelHost) and remote
// (mc-server over REST + WS) both implement this; the Vm surface above it is
// identical across them — that symmetry is the point. Methods use the clean
// Unix-flavored verbs (`read`/`write`/`ls`/`rm`); the low-level
// `@mc/host` driver keeps its mechanical names, and each backend
// adapts at that boundary.

import type {
  DirEntry,
  Driver,
  ExecOptions,
  SessionHandle,
  Shell,
  StatResult,
  ToolDefinition,
  VmStatus,
  SnapshotOptions,
} from "./types.js";

/** Raw exec result from a backend (bytes; the Vm decodes to strings). */
export interface RawExecResult {
  stdout: Uint8Array;
  stderr: Uint8Array;
  exitCode: number;
}

export interface Backend {
  exec(cmd: string, opts?: ExecOptions): Promise<RawExecResult>;
  read(path: string): Promise<Uint8Array>;
  write(path: string, data: Uint8Array): Promise<void>;
  ls(path: string): Promise<DirEntry[]>;
  stat(path: string): Promise<StatResult>;
  readlink(path: string): Promise<string>;
  mkdir(path: string): Promise<void>;
  rm(path: string): Promise<void>;
  chmod(path: string, mode: number): Promise<void>;
  /** Create a symbolic link at `link` with target text `target`. */
  symlink(target: string, link: string): Promise<void>;
  snapshot(opts?: SnapshotOptions): Promise<Uint8Array>;
  /** The `commit` primitive: serialize the live CoW overlay into a content-
   *  addressed `.tar` layer — `{ digest, tar }`. */
  commitLayer(): Promise<{ digest: string; tar: Uint8Array }>;
  inflightEgress(): Promise<number>;
  /** Size of the VM's WASM linear memory in bytes (the whole RAM footprint).
   *  `0` when the backend can't measure it (e.g. remote). */
  memoryBytes(): number;
  status(): Promise<VmStatus>;
  tool(def: ToolDefinition): void;
  unregisterTool(name: string): void;
  serviceCall(name: string, req: Uint8Array): Promise<Uint8Array>;
  /** Install a host-backed driver at `path` (read-only if `readOnly`). */
  mount(path: string, driver: Driver, readOnly: boolean): Promise<void>;
  /** Remove a host-backed mount at `path`. */
  unmount(path: string): Promise<void>;
  shell(): Shell;
  /** A live agent session that streams events as the agent emits them — embedded
   *  (the pump tails the running exec) and served (over the WS), both via the
   *  kernel exec-peek. */
  liveSession(agentType: string): SessionHandle;
  close(): Promise<void>;
}
