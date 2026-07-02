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
export { setArtifactSources, prefetchArtifacts } from "./vm/artifacts.js";
export { makeVmHost } from "./vm/host.js";
export type { BootOptions, VmHost } from "./vm/host.js";
export { vmHostContext, installContextRoot } from "./vm/context.js";
