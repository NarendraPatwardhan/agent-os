// <mc-xterm> — a presentational terminal primitive: bytes in, bytes out, no
// knowledge of a VM. It's makeXterm dressed in design tokens and made reusable for
// any byte stream. Feed it with .write(bytes); read user keystrokes off the
// `mc-data` event.
//
// Light DOM: the element renders into the page (no shadow root) and carries the
// `.mc-term` class so styles/terminal.css can reach xterm's injected DOM — the slim
// scrollbar + accent cursor. Include "@mc/elements/styles.css" on the page.

import { LitElement, html } from "lit";
import { property } from "lit/decorators.js";
import { makeXterm } from "../terminal/xterm.js";
import type { TerminalHandle } from "../terminal/xterm.js";

const enc = new TextEncoder();

export class McXterm extends LitElement {
  // Render into light DOM so page CSS (.mc-term .xterm-*) reaches xterm.
  protected createRenderRoot(): HTMLElement {
    return this;
  }

  /** Fixed column count (omit for auto-fit to the element box). */
  @property({ type: Number }) cols?: number;
  /** Fixed row count (omit for auto-fit). */
  @property({ type: Number }) rows?: number;
  /** Caret style. Slim `bar` by default. */
  @property() cursor: "bar" | "block" | "underline" = "bar";

  private handle?: TerminalHandle;
  private readonly pending: Array<Uint8Array | string> = [];

  connectedCallback(): void {
    super.connectedCallback();
    this.classList.add("mc-term"); // shared terminal.css style hook
  }

  render() {
    return html`<div class="mc-xterm__screen"></div>`;
  }

  firstUpdated() {
    if (typeof window === "undefined") return;
    const screen = this.renderRoot.querySelector<HTMLElement>(".mc-xterm__screen");
    if (!screen) return;
    this.handle = makeXterm(this, screen, {
      cols: this.cols,
      rows: this.rows,
      cursorStyle: this.cursor,
    });
    this.handle.term.onData((data) => {
      this.dispatchEvent(
        new CustomEvent<Uint8Array>("mc-data", {
          detail: enc.encode(data),
          bubbles: true,
          composed: true,
        }),
      );
    });
    for (const chunk of this.pending) this.handle.term.write(chunk as string);
    this.pending.length = 0;
  }

  disconnectedCallback(): void {
    super.disconnectedCallback();
    this.handle?.dispose();
    this.handle = undefined;
  }

  // ── public API ──────────────────────────────────────────────────────────
  /** Write bytes (or a string) to the screen. Buffers until the terminal exists. */
  write(data: Uint8Array | string): void {
    if (this.handle) this.handle.term.write(data as string);
    else this.pending.push(data);
  }
  /** Clear scrollback and reset the screen. */
  reset(): void {
    this.handle?.term.reset();
  }
  /** Clear the viewport (keep scrollback). */
  clear(): void {
    this.handle?.term.clear();
  }
  /** Re-fit the grid to the element box. */
  fit(): void {
    this.handle?.refit();
  }
  /** Focus the terminal. */
  focus(): void {
    this.handle?.term.focus();
  }
  /** The underlying xterm Terminal (for advanced use). */
  get terminal() {
    return this.handle?.term;
  }
}
