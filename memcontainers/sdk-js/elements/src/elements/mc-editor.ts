// <mc-editor> — a code editor primitive over CodeMirror 6 (line numbers, bracket
// matching, JS/TS grammar), themed from design tokens. VM-agnostic: it just edits
// text and emits `mc-run` (Mod-Enter, or .run()) with the source. CodeMirror is
// lazy-loaded so it only ships to pages that use an editor.
//
// Light DOM: renders into the page; styling comes from styles/components.css
// (`mc-editor { … }`). Seed it with the `value` property/attribute, or as text
// content:
//   <mc-editor>const x = 1\nawait vm.fs.write("x", String(x))</mc-editor>
//
// Structural knobs — `language` (javascript | typescript | plain), `read-only`,
// `line-wrapping` — reconfigure the live editor in place (Compartments), so toggling
// them never drops the doc or undo history. `extensions` (a JS property) appends
// arbitrary CodeMirror extensions for advanced embedders.

import { LitElement, html } from "lit";
import type { PropertyValues } from "lit";
import { property } from "lit/decorators.js";
import type { EditorHandle, EditorLanguage, Extension } from "../editor/codemirror.js";

/** Strip a uniform leading indent from templated seed text so `<mc-editor>` bodies
 *  can be indented in source without leaking whitespace into the doc. */
function dedent(s: string): string {
  const body = s.replace(/^\n/, "").replace(/[ \t]+$/g, "");
  const lines = body.split("\n");
  const indents = lines
    .filter((l) => l.trim().length > 0)
    .map((l) => l.match(/^[ \t]*/)?.[0].length ?? 0);
  const min = indents.length ? Math.min(...indents) : 0;
  return lines
    .map((l) => l.slice(min))
    .join("\n")
    .replace(/\s+$/, "");
}

export class McEditor extends LitElement {
  // Render into light DOM. CodeMirror injects its StyleModule into the document
  // (makeEditor resolves the root via getRootNode), which works for light DOM.
  protected createRenderRoot(): HTMLElement {
    return this;
  }

  /** Language mode. `plain` drops syntax parsing; `typescript` enables TS syntax. */
  @property() language: EditorLanguage = "javascript";
  /** The editor source. Two-way: updated as the user types. */
  @property() value = "";
  /** Read-only: no caret, no edits. */
  @property({ type: Boolean, attribute: "read-only" }) readOnly = false;
  /** Soft-wrap long lines instead of scrolling horizontally. */
  @property({ type: Boolean, attribute: "line-wrapping" }) lineWrapping = false;
  /** Focus the editor once it mounts. */
  @property({ type: Boolean, attribute: "auto-focus" }) autoFocus = false;
  /** Extra CodeMirror extensions (JS property only — set before first render). */
  extensions?: readonly Extension[];

  private editor?: EditorHandle;
  private ready = false;
  private seed = "";

  connectedCallback(): void {
    // Capture any seed text BEFORE Lit renders into light DOM (which replaces this
    // element's children).
    if (!this.value && !this.seed) {
      const s = this.textContent ?? "";
      if (s.trim().length > 0) this.seed = dedent(s);
    }
    super.connectedCallback();
  }

  render() {
    return html`<div class="mc-editor__host"></div>`;
  }

  async firstUpdated() {
    if (typeof window === "undefined") return;
    const parent = this.renderRoot.querySelector<HTMLElement>(".mc-editor__host");
    if (!parent) return;

    if (!this.value && this.seed) this.value = this.seed;

    const { makeEditor } = await import("../editor/codemirror.js");
    this.editor = makeEditor({
      parent,
      doc: this.value,
      language: this.language,
      readOnly: this.readOnly,
      lineWrapping: this.lineWrapping,
      autoFocus: this.autoFocus,
      extraExtensions: this.extensions,
      onChange: (doc) => {
        this.value = doc;
        this.dispatchEvent(new CustomEvent("input", { bubbles: true, composed: true }));
      },
      onRun: (doc) =>
        this.dispatchEvent(
          new CustomEvent("mc-run", { detail: { source: doc }, bubbles: true, composed: true }),
        ),
    });
    this.ready = true;
  }

  updated(changed: PropertyValues<this>) {
    const editor = this.editor;
    if (!editor || !this.ready) return;

    if (changed.has("value")) {
      const current = editor.view.state.doc.toString();
      if (current !== this.value) {
        editor.view.dispatch({ changes: { from: 0, to: current.length, insert: this.value } });
      }
    }
    // Structural options reconfigure in place (Compartments) — no teardown.
    if (changed.has("language") || changed.has("readOnly") || changed.has("lineWrapping")) {
      editor.update({
        language: this.language,
        readOnly: this.readOnly,
        lineWrapping: this.lineWrapping,
      });
    }
  }

  disconnectedCallback(): void {
    super.disconnectedCallback();
    this.editor?.view.destroy();
    this.editor = undefined;
    this.ready = false;
  }

  // ── public API ──────────────────────────────────────────────────────────
  /** The current source. */
  get source(): string {
    return this.editor ? this.editor.view.state.doc.toString() : this.value;
  }
  /** Emit `mc-run` with the current source. */
  run(): void {
    this.dispatchEvent(
      new CustomEvent("mc-run", { detail: { source: this.source }, bubbles: true, composed: true }),
    );
  }
  focus(): void {
    this.editor?.view.focus();
  }
}
