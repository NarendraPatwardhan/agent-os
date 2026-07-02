// The context <mc-sandbox> provides and bound widgets consume: a VmHost (one VM's
// lifecycle, indirected so fork/restore swaps re-bind consumers).
//
// A single ContextRoot is installed at the document root. It buffers unsatisfied
// `context-request` events and re-delivers them when a matching provider connects
// later — so a consumer that upgrades before its provider (or whose provider is
// lazily imported) still gets wired. Without it the consumer would see no provider
// and wrongly boot a standalone VM.

import { ContextRoot, createContext } from "@lit/context";
import type { VmHost } from "./host.js";

export const vmHostContext = createContext<VmHost>(Symbol.for("mc.vm-host"));

let installed = false;

/** Install the document-level ContextRoot once (idempotent, no-op off-DOM).
 *
 * This is the one intentional global side effect in the package: a single
 * `context-request` listener at the document root, installed lazily the first time a
 * provider or consumer connects. It attaches to <html> (documentElement), not <body>
 * — the root exists before <body> is parsed and survives a <body> replacement, and
 * context-request events bubble up to it either way. */
export function installContextRoot(): void {
  if (installed || typeof document === "undefined") return;
  const target = document.documentElement ?? document.body;
  if (!target) return;
  installed = true;
  new ContextRoot().attach(target);
}
