// <mc-sandbox> — the controller. Owns one VM's lifecycle: boots from its attributes
// on connect, closes on disconnect, and provides the live VmHost to descendants via
// context. Renders no chrome of its own (display: contents) beyond an optional thin
// status pill. This is `mc.create` as an element — and the way several views share
// one VM.

import { ContextProvider } from "@lit/context";
import type { Vm } from "@mc/core";
import { LitElement, css, html } from "lit";
import { property, state } from "lit/decorators.js";
import { installContextRoot, vmHostContext } from "../vm/context.js";
import { makeControlledHost, makeVmHost } from "../vm/host.js";
import type { BootOptions, VmHost } from "../vm/host.js";
import { baseStyles } from "./shared-styles.js";

type Phase = "idle" | "booting" | "ready" | "error";

export class McSandbox extends LitElement {
  static styles = [
    baseStyles,
    css`
      :host {
        display: contents;
      }
      .status {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        font: 500 11px/1 var(--mc-font-mono, var(--font-mono, ui-monospace, monospace));
        letter-spacing: 0.04em;
        text-transform: uppercase;
        color: var(--mc-fg-subtle, var(--fg-subtle, #8a8a90));
      }
      .dot {
        width: 7px;
        height: 7px;
        border-radius: 999px;
        background: currentColor;
      }
      .status[data-phase="ready"] {
        color: var(--success, oklch(0.58 0.15 150));
      }
      .status[data-phase="ready"] .dot {
        box-shadow: 0 0 0 3px color-mix(in oklab, currentColor 24%, transparent);
      }
      .status[data-phase="booting"] {
        color: var(--mc-accent, var(--accent, #c98a16));
      }
      .status[data-phase="error"] {
        color: var(--danger, oklch(0.56 0.22 26));
      }
      .status[data-phase="booting"] .dot {
        animation: mc-pulse 1s ease-in-out infinite;
      }
      @keyframes mc-pulse {
        0%,
        100% {
          opacity: 0.35;
        }
        50% {
          opacity: 1;
        }
      }
      @media (prefers-reduced-motion: reduce) {
        .status[data-phase="booting"] .dot {
          animation: none;
        }
      }
    `,
  ];

  /** Backend. Default `"browser"`. */
  @property() runtime?: "browser" | "bun" | "remote";
  /** Logical image name, a URL, or empty for the default rootfs. */
  @property() image?: string;
  /** Enable network egress. */
  @property({ type: Boolean }) net = false;
  /** Remote endpoint (runtime="remote"). */
  @property() endpoint?: string;
  /** Bearer token (remote). */
  @property() token?: string;
  /** Deterministic clock + RNG. */
  @property({ type: Boolean }) deterministic = false;
  /** Kernel wasm URL override. */
  @property() kernel?: string;
  /** Show a thin status pill in the default `status` slot. */
  @property({ type: Boolean, attribute: "show-status" }) showStatus = false;

  /** Controlled mode (JS property): an externally-owned VM to run instead of booting
   *  from attributes. The sandbox exposes it to descendants but never closes it. Set
   *  it before connect; change it later and call `reboot()` to swap. */
  controlledVm?: Vm;

  @state() private phase: Phase = "idle";
  @state() private errorText = "";

  private readonly provider = new ContextProvider(this, { context: vmHostContext });
  private host?: VmHost;

  /** Boot options derived from the attributes. */
  bootOptions(): BootOptions {
    return {
      runtime: this.runtime,
      image: this.image && this.image.length > 0 ? this.image : undefined,
      kernel: this.kernel,
      net: this.net,
      endpoint: this.endpoint,
      token: this.token,
      deterministic: this.deterministic,
    };
  }

  connectedCallback(): void {
    super.connectedCallback();
    installContextRoot();
    if (typeof window === "undefined" || this.host) return;
    this.startBoot();
  }

  /** Boot from attributes (or adopt the controlled VM) and provide the host to
   *  descendants. The host is the stable indirection; fork/restore/reboot swap the
   *  VM inside it and notify bound widgets — the host object itself never changes. */
  private startBoot(): void {
    this.phase = "booting";
    this.setAttribute("phase", this.phase);
    const host = this.controlledVm ? makeControlledHost(this.controlledVm) : makeVmHost(this.bootOptions());
    this.host = host;
    this.provider.setValue(host);
    host.ready
      .then((vm) => {
        this.phase = "ready";
        this.setAttribute("phase", this.phase);
        this.dispatchEvent(new CustomEvent("mc-boot", { detail: { vm }, bubbles: true, composed: true }));
      })
      .catch((e: unknown) => {
        this.phase = "error";
        this.errorText = e instanceof Error ? e.message : String(e);
        this.setAttribute("phase", this.phase);
        this.dispatchEvent(
          new CustomEvent("mc-error", { detail: { error: this.errorText }, bubbles: true, composed: true }),
        );
      });
  }

  disconnectedCallback(): void {
    super.disconnectedCallback();
    const h = this.host;
    this.host = undefined;
    this.phase = "idle";
    this.removeAttribute("phase");
    if (h) void h.close();
  }

  render() {
    return html`
      <slot></slot>
      <slot name="status">${this.showStatus ? this.renderStatus() : null}</slot>
    `;
  }

  private renderStatus() {
    const label =
      this.phase === "ready"
        ? "live"
        : this.phase === "booting"
          ? "booting"
          : this.phase === "error"
            ? "error"
            : "idle";
    return html`<span class="status" data-phase=${this.phase} title=${this.errorText}>
      <span class="dot"></span>${label}
    </span>`;
  }

  // ── public API (the snapshot/fork/restore differentiator, surfaced) ─────────
  /** The live VM (undefined until booted). */
  get vm(): Vm | undefined {
    return this.host?.vm;
  }
  /** The VmHost this sandbox provides. */
  get vmHost(): VmHost | undefined {
    return this.host;
  }
  /** Capture the whole VM as a portable blob. */
  snapshot(): Promise<Uint8Array> {
    if (!this.host) return Promise.reject(new Error("<mc-sandbox> has no VM"));
    return this.host.snapshot();
  }
  /** Branch a fresh independent VM (the original keeps running). */
  async fork(): Promise<Vm> {
    if (!this.host) throw new Error("<mc-sandbox> has no VM");
    const vm = await this.host.fork();
    this.dispatchEvent(new CustomEvent("mc-fork", { detail: { vm }, bubbles: true, composed: true }));
    return vm;
  }
  /** Rewind this sandbox's VM to a snapshot (consumers re-bind). */
  async restore(blob: Uint8Array): Promise<Vm> {
    if (!this.host) throw new Error("<mc-sandbox> has no VM");
    const vm = await this.host.restore(blob);
    this.dispatchEvent(new CustomEvent("mc-vm-changed", { detail: { vm }, bubbles: true, composed: true }));
    return vm;
  }
  /** Boot a fresh VM from the same attributes, replacing the current one (consumers
   *  re-bind). Not available in controlled mode — the VM's owner reboots it. */
  async reboot(): Promise<Vm> {
    if (!this.host) throw new Error("<mc-sandbox> has no VM");
    const vm = await this.host.reboot();
    this.dispatchEvent(new CustomEvent("mc-vm-changed", { detail: { vm }, bubbles: true, composed: true }));
    return vm;
  }
}
