// <mc-terminal> — the hero. An xterm bound to vm.shell(): boot banner in, keystrokes
// out, a real Unix shell in one tag. Attaches to a shared VM when placed inside
// <mc-sandbox>, accepts an explicit `.vm` property, or boots its own VM standalone.
// Re-binds cleanly when the VM is forked-in/restored.
//
// Light DOM: the element carries `.mc-term` so styles/terminal.css styles xterm's
// injected DOM; the card chrome around it is styled by `mc-terminal { … }` in
// styles/components.css.

import type { Runtime, Shell, Vm } from "@mc/core";
import { LitElement, html } from "lit";
import { property, state } from "lit/decorators.js";
import { VmBinding } from "../vm/binding.js";
import type { BootOptions } from "../vm/host.js";
import { makeXterm } from "../terminal/xterm.js";
import type { TerminalHandle } from "../terminal/xterm.js";

const enc = new TextEncoder();
const dec = new TextDecoder();

export class McTerminal extends LitElement {
  protected createRenderRoot(): HTMLElement {
    return this;
  }

  /** Fixed grid columns (omit for auto-fit). */
  @property({ type: Number }) cols?: number;
  /** Fixed grid rows (omit for auto-fit). */
  @property({ type: Number }) rows?: number;
  /** Caret style. Slim `bar` by default; `block` reads as a classic shell cursor. */
  @property() cursor: "bar" | "block" | "underline" = "bar";
  /** Line height multiple (omit for the terminal default). */
  @property({ type: Number, attribute: "line-height" }) lineHeight?: number;
  /** Open a dedicated shell in this language instead of the sandbox's canonical shell. */
  @property() language?: "sh" | "luau";
  /** Replay the shell's scrollback on (re)attach. On by default. */
  @property({ type: Boolean, attribute: "replay-history" }) replayHistory = true;
  /** Enable network egress when booting a standalone VM. */
  @property({ type: Boolean }) net = false;
  /** Backend for standalone boot. Default `"browser"`. */
  @property() runtime?: Runtime;
  /** Image to boot standalone (logical name or URL). */
  @property() image?: string;
  /** Remote endpoint (runtime="remote"). */
  @property() endpoint?: string;
  /** Bearer token (remote). */
  @property() token?: string;
  /** Deterministic clock + RNG for standalone boot. */
  @property({ type: Boolean }) deterministic = false;
  /** Kernel wasm URL override for embedded standalone boot. */
  @property() kernel?: string;
  /** Title-bar caption. */
  @property() label = "agent · live in your browser";
  /** A host-driven command is still running. */
  @property({ type: Boolean, reflect: true }) working = false;

  /** Explicit VM to attach (JS property; takes precedence over context). */
  vm?: Vm;
  /** Wait for an explicit .vm / attach() / provider — don't boot a standalone VM
   *  (used for a fork target that gets its VM handed to it later). */
  @property({ type: Boolean }) manual = false;
  /** This element may boot its own VM when nothing provides one. */
  get standaloneAllowed(): boolean {
    return !this.manual;
  }

  @state() private live = false;

  private readonly binding = new VmBinding(this, {
    onVm: (vm) => this.onVm(vm),
    onError: (e) => this.onError(e),
  });
  private handle?: TerminalHandle;
  private activeVm?: Vm;
  private shell?: Shell;
  private shellUnsub?: () => void;

  connectedCallback(): void {
    super.connectedCallback();
    this.classList.add("mc-term"); // shared terminal.css style hook
  }

  bootOptions(): BootOptions {
    return {
      runtime: this.runtime,
      image: this.image,
      net: this.net,
      endpoint: this.endpoint,
      token: this.token,
      deterministic: this.deterministic,
      kernel: this.kernel,
    };
  }

  render() {
    return html`
      <div class="bar">
        <span class="lights"><span></span><span></span><span></span></span>
        <span class="title">${this.label}</span>
        <span class="live-dot"><i></i>${this.working ? "working" : "live"}</span>
      </div>
      <div class="screen"></div>
    `;
  }

  firstUpdated() {
    if (typeof window === "undefined") return;
    const screen = this.renderRoot.querySelector<HTMLElement>(".screen");
    if (!screen) return;
    this.handle = makeXterm(this, screen, {
      cols: this.cols,
      rows: this.rows,
      cursorStyle: this.cursor,
      lineHeight: this.lineHeight,
    });
    this.handle.term.onData((data) => {
      const bytes = enc.encode(data);
      this.shell?.write(bytes);
      this.dispatchEvent(
        new CustomEvent<Uint8Array>("mc-data", { detail: bytes, bubbles: true, composed: true }),
      );
    });
    this.tryAttach();
  }

  disconnectedCallback(): void {
    super.disconnectedCallback();
    this.detachShell();
    this.handle?.dispose();
    this.handle = undefined;
  }

  private onVm(vm: Vm | undefined): void {
    if (vm === this.activeVm) return;
    this.activeVm = vm;
    if (!vm) {
      this.detachShell();
      this.setLive(false);
      this.dispatchEvent(new CustomEvent("mc-exit", { bubbles: true, composed: true }));
      return;
    }
    this.tryAttach();
  }

  private onError(err: unknown): void {
    const msg = err instanceof Error ? err.message : String(err);
    this.handle?.term.write(`\r\n\x1b[31m[could not boot: ${msg}]\x1b[0m\r\n`);
  }

  private tryAttach(): void {
    if (!this.handle || !this.activeVm) return;
    this.detachShell();

    // A requested `language` forces a dedicated shell; otherwise prefer the host's
    // ONE canonical shell (so terminal + exec share a stream), falling back to
    // opening a shell on the VM directly.
    const shell = this.language
      ? this.activeVm.shell({ language: this.language })
      : (this.binding.vmHost?.shell ?? this.activeVm.shell());
    this.shell = shell;

    const term = this.handle.term;
    term.reset();
    if (this.replayHistory) {
      const history = shell.history();
      if (history.length > 0) term.write(history);
    }
    this.shellUnsub = shell.on((bytes) => {
      term.write(bytes);
      this.dispatchEvent(
        new CustomEvent("mc-output", {
          detail: { bytes, text: dec.decode(bytes) },
          bubbles: true,
          composed: true,
        }),
      );
    });
    this.handle.refit();
    this.setLive(true);

    this.dispatchEvent(
      new CustomEvent("mc-ready", { detail: { vm: this.activeVm }, bubbles: true, composed: true }),
    );
  }

  private detachShell(): void {
    this.shellUnsub?.();
    this.shellUnsub = undefined;
    this.shell = undefined;
  }

  private setLive(on: boolean): void {
    this.live = on;
    if (on) this.setAttribute("data-live", "");
    else this.removeAttribute("data-live");
  }

  // ── public API ────────────────────────────────────────────────────────────
  /** Attach an externally-supplied VM (e.g. a fork) — drives the same bind path as
   *  a provider/standalone VM. */
  attach(vm: Vm): void {
    this.onVm(vm);
  }
  /** Write bytes straight to the shell's stdin (as if typed). */
  send(data: string | Uint8Array): void {
    this.shell?.write(data);
  }
  focus(): void {
    this.handle?.term.focus();
  }
  fit(): void {
    this.handle?.refit();
  }
  /** Widen the backing grid without widening the element; the screen scrolls it. */
  ensureColumns(columns: number): void {
    this.handle?.ensureColumns(columns);
  }
  /** The underlying xterm Terminal (advanced use / testing). */
  get terminal() {
    return this.handle?.term;
  }
}
