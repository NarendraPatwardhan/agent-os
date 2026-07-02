// The single place custom elements are registered. Importing this module defines
// the four <mc-*> tags — guarded so it's a no-op in non-browser/SSR environments,
// and idempotent so a double import (or a second bundle on the page) is safe.

import { McEditor } from "./elements/mc-editor.js";
import { McSandbox } from "./elements/mc-sandbox.js";
import { McTerminal } from "./elements/mc-terminal.js";
import { McXterm } from "./elements/mc-xterm.js";

const REGISTRY: ReadonlyArray<readonly [string, CustomElementConstructor]> = [
  ["mc-sandbox", McSandbox],
  ["mc-xterm", McXterm],
  ["mc-terminal", McTerminal],
  ["mc-editor", McEditor],
];

/** Register every element. Called automatically on import in the browser; exported
 *  so a consumer can opt into explicit registration too. */
export function defineElements(): void {
  if (typeof customElements === "undefined") return;
  for (const [tag, ctor] of REGISTRY) {
    if (!customElements.get(tag)) customElements.define(tag, ctor);
  }
}

defineElements();

declare global {
  interface HTMLElementTagNameMap {
    "mc-sandbox": McSandbox;
    "mc-xterm": McXterm;
    "mc-terminal": McTerminal;
    "mc-editor": McEditor;
  }
}
