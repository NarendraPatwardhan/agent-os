// @mc/host — the JavaScript host for the agent-os kernel, with behavioral parity to the Rust/wasmtime
// host (A3). It implements the same `env` bridge over web APIs (`fetch`, `WebSocket`, `crypto`,
// `node:fs`/OPFS) and drives the same tick loop, so the SAME kernel.wasm runs unchanged under bun, the
// browser, and node. The `env` bridge and the `mc_ctl_*` export lookup are wired from the generated
// contract descriptors (env.gen.ts / ctl.gen.ts), so the boundary the kernel + Rust host derive from is
// the one the JS host derives from too — it cannot silently desync (B2).

export { KernelHost, KernelHostBuilder, EagainError } from "./host.js";
export type { ExecResult, DirEntry } from "./host.js";
export { CaptureSink, WritableSink, processStdout, processStderr } from "./io.js";
export { SystemClock, FixedClock, OsRng, SeededRng } from "./sources.js";
export { ConnectionRegistry } from "./connections.js";
export type { ConnectionCredential, PreparedConnectionRequest, PreparedHttpRequest } from "./connections.js";
export type { ToolPolicyAction, ToolPolicyOwner, ToolPolicyRule } from "./policy.js";
export { CatalogCompiler, defaultCatalogCompiler } from "./catalog_compiler.js";
export type { CatalogBundle, RegistryEntry, RegistryGroup } from "./catalog_compiler.js";
export { DeniedNet, HostNet } from "./net.js";
export type { NetApprover, ToolApprovalFacts, ToolApprover, HostNetOptions } from "./net.js";
export { DeniedPersist, DiskPersist } from "./persist.js";
export { OpfsPersist, OpfsKv, IdbKv, MemoryKv } from "./opfs-persist.js";
export type { BrowserKv } from "./opfs-persist.js";
export { DeniedHostCall, MapHostCall } from "./host_call.js";
export type { HostCallCapability, ToolHandler, RawToolHandler } from "./host_call.js";
export { Mem } from "./memory.js";
export type {
  StreamSink,
  ClockSource,
  RngSource,
  NetCapability,
  PersistCapability,
} from "./types.js";
export type { HostState } from "./bridge.js";
