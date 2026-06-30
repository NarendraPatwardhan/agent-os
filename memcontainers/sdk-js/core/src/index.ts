// @mc/core — the unified consumer API. One `mc` / `vm` surface over the embedded JS host
// (@mc/host), browser artifacts, or a remote AgentOS host over REST + the typed wire socket.

export { capabilityConnection, mc, Vm } from "./memcontainer.js";
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
export { RemoteBackend } from "./remote.js";
export type { RemoteBackendOptions } from "./remote.js";
export { defaultKernel, defaultImage } from "./artifacts.js";
export { FsContentStore, defaultStore } from "./store.js";
export type { Backend, RawExecResult } from "./backend.js";
export type {
  Runtime,
  Permissions,
  CreateOptions,
  ConnectionDefinition,
  ConnectionAuth,
  CatalogFormat,
  CatalogSourceFormat,
  ConnectionSpecSource,
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
  ConnectionPolicyAction,
  ConnectionPolicyOwner,
  ConnectionPolicyRule,
  ImageManifest,
  ImageConfig,
  ContentStore,
} from "./types.js";
