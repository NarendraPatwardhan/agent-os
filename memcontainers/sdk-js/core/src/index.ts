// @mc/core — the unified consumer API. One `mc` / `vm` surface over the embedded JS host
// (@mc/host), browser artifacts, or a remote AgentOS host over REST + the typed wire socket.

export { capabilityConnection, mc, Vm } from "./memcontainer.js";
export { llb } from "./llb.js";
export type {
  BuildDefinition,
  BuildRef,
  BuildState,
  CopyPath,
  DefinitionOptions,
  ExecOpts,
  GitSourceOptions,
  HttpSourceOptions,
  LocalSourceOptions,
} from "./llb.js";
export { record } from "./record.js";
export type { Recorder } from "./record.js";
export { startCron, parseSchedule } from "./cron.js";
export type { CronAction, CronOptions, CronHandle, CronRunResult } from "./cron.js";
export type { VmFs } from "./types.js";
export { tool, kit } from "./tools.js";
export type { ToolSpec } from "./tools.js";
export { remoteSidecars, SidecarError, VmSidecars } from "./sidecars.js";
export { browser, VmBrowsers, VmBrowserComputer, VmBrowserPages } from "./browsers.js";
export type {
  BrowserCreateOptions,
  BrowserKeyOptions,
  BrowserLocatorOptions,
  BrowserOptions,
  BrowserPageOptions,
  BrowserPoint,
  BrowserScreenshotOptions,
  BrowserScrollOptions,
  BrowserSession,
  BrowserTypeOptions,
  BrowserWaitUntil,
} from "./browsers.js";
export type {
  RemoteSidecarHostOptions,
  SidecarAuthority,
  SidecarCapability,
  SidecarContractDescriptor,
  SidecarCreateRequest,
  SidecarForkPolicy,
  SidecarGrant,
  SidecarGrantDescriptor,
  SidecarHost,
  SidecarHostContext,
  SidecarInstance,
  SidecarInvokeRequest,
  SidecarPlacement,
  SidecarProviderDescription,
  VmWarning,
} from "./sidecars.js";
// zod, re-exported so embedders can type `tool()` inputs without a second install.
export { z } from "zod";
// The curated-registry reader (§5.11) — build integration pickers from the same
// entries the host compiles connections from.
export { defaultCatalogCompiler } from "@mc/host";
export type { RegistryEntry } from "@mc/host";
export { EmbeddedBackend, FanoutSink } from "./embedded.js";
export { RemoteBackend } from "./remote.js";
export type { RemoteBackendOptions } from "./remote.js";
export { remoteBuild } from "./remote-build.js";
export type { RemoteBuildOptions, RemoteBuildResult } from "./remote-build.js";
export type { WarmDirective } from "./solve.js";
export type {
  GitSource,
  LocalEntry,
  LocalSource,
  SolvePlatform,
  SolveProgressEvent,
} from "./solve.js";
export { defaultKernel, defaultImage } from "./artifacts.js";
export { FsContentStore, MemoryContentStore, OpfsContentStore, defaultStore } from "./store.js";
export type { Backend, RawAutocompleteResult, RawExecResult } from "./backend.js";
export type {
  Runtime,
  Permissions,
  CreateOptions,
  ConnectionDefinition,
  ConnectionAuth,
  CatalogFormat,
  CatalogSourceFormat,
  ConnectionSpecSource,
  ExecOptions,
  ExecResult,
  AutocompleteOptions,
  AutocompleteItem,
  AutocompleteResult,
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
  BuildRecord,
  ImageManifest,
  ImageConfig,
  ContentStore,
} from "./types.js";
