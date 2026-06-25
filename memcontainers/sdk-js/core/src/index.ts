// @mc/core — the unified consumer API. One `mc` / `vm` surface over the embedded (in-process) JS host
// (@mc/host), under bun, node, and the browser. The remote backend — mc-server over the wire protocol
// — lands when mc-server is ported; until then the `"remote"` runtime throws a clear error.

export { mc, Vm } from "./memcontainer.js";
export { llb } from "./llb.js";
export type { BuildState, ExecOpts } from "./llb.js";
export { record } from "./record.js";
export type { Recorder } from "./record.js";
export { startCron, parseSchedule } from "./cron.js";
export type { CronAction, CronOptions, CronHandle, CronRunResult } from "./cron.js";
export type { VmFs } from "./types.js";
export { tool, kit } from "./tools.js";
export type { ToolSpec } from "./tools.js";
export { EmbeddedBackend, FanoutSink } from "./embedded.js";
export { defaultKernel, defaultImage } from "./artifacts.js";
export { FsContentStore, defaultStore } from "./store.js";
export type { Backend, RawExecResult } from "./backend.js";
export type {
  Runtime,
  Permissions,
  CreateOptions,
  ExecResult,
  DirEntry,
  StatResult,
  JsonSchema,
  ToolContext,
  Shell,
  ToolDefinition,
  SessionHandle,
  SessionEvent,
  VmStatus,
  Driver,
  DriverEntry,
  DriverMeta,
  DriverError,
  MountSpec,
  PermissionRequest,
  ImageManifest,
  ImageConfig,
  ContentStore,
} from "./types.js";
