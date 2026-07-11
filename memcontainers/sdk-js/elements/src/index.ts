// @mc/elements — Lit <mc-*> web components over @mc/core VMs. Importing this module
// registers <mc-sandbox>, <mc-xterm>, <mc-terminal>, <mc-editor> (via ./register)
// and re-exports the classes plus the small runtime API embedders reach for. Ship
// the stylesheet too: <link rel="stylesheet" href=".../@mc/elements/styles.css">.

import "./register";

export { defineElements } from "./register.js";

// ── element classes ─────────────────────────────────────────────────────────
export { McSandbox } from "./elements/mc-sandbox.js";
export { McXterm } from "./elements/mc-xterm.js";
export { McTerminal } from "./elements/mc-terminal.js";
export { McEditor } from "./elements/mc-editor.js";

// ── runtime helpers + types (for embedders) ─────────────────────────────────
export { setArtifactSources, prefetchArtifacts, loadCatalogCompiler } from "./vm/artifacts.js";
export { makeVmHost, resolveCreateOptions } from "./vm/host.js";
export type { BootOptions, VmHost } from "./vm/host.js";
export { vmHostContext, installContextRoot } from "./vm/context.js";

// The SDK itself, for embedders that drive VM lifecycle directly (create / connect
// / restore / close) alongside the elements — e.g. a remote create→connect→kill flow.
// `tool`/`kit`/`z` ride along so a page can define typed host tools (`vm.tool`)
// without importing @mc/core separately; `defaultCatalogCompiler` reads the curated
// registry (pair it with `loadCatalogCompiler` for the wasm bytes).
export {
  mc,
  llb,
  tool,
  kit,
  z,
  defaultCatalogCompiler,
  MemoryContentStore,
} from "@mc/core";
export { s3, vectorStore } from "@mc/core/drivers";
export type {
  Vm,
  Runtime,
  CreateOptions,
  ConnectionDefinition,
  ContentStore,
  Driver,
  PermissionRequest,
  ToolDefinition,
  SessionHandle,
  SessionEvent,
  RegistryEntry,
} from "@mc/core";
