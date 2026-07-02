// VmBinding: the reactive controller a "bound" widget uses to acquire a VM.
// Resolution priority, decided once after connect:
//   1. an explicit `.vm` property — the app wired one in (highest)
//   2. a VmHost from a wrapping <mc-sandbox>, via context
//   3. boot its own standalone VM — only if the element opts in
//
// First-owner-wins: once a widget standalone-boots, a provider that shows up later
// is ignored (we never orphan a booted VM). On disconnect it unsubscribes and
// closes the VM only if it owns it.

import { ContextConsumer } from "@lit/context";
import type { Vm } from "@mc/core";
import type { ReactiveController, ReactiveControllerHost } from "lit";
import { installContextRoot, vmHostContext } from "./context.js";
import { decideVmSource } from "./decide.js";
import { makeVmHost } from "./host.js";
import type { BootOptions, VmHost } from "./host.js";

export interface VmBindingHost extends ReactiveControllerHost, HTMLElement {
  /** Explicit VM set as a property (highest priority). */
  vm?: Vm;
  /** Boot options for a standalone VM, read from this element's attributes. */
  bootOptions(): BootOptions;
  /** Whether this element may boot its own VM when nothing provides one. */
  standaloneAllowed?: boolean;
}

export interface VmBindingCallbacks {
  /** Called whenever the bound VM appears or is swapped (fork-in/restore), and with
   *  `undefined` on teardown. */
  onVm(vm: Vm | undefined): void;
  /** Called if a standalone boot (or the provider's boot) fails. */
  onError?(err: unknown): void;
}

export class VmBinding implements ReactiveController {
  ownsVm = false;

  private readonly consumer: ContextConsumer<typeof vmHostContext, VmBindingHost>;
  private providedHost?: VmHost;
  private ownHost?: VmHost;
  private boundHost?: VmHost;
  private currentVm?: Vm;
  private unsub?: () => void;
  private decided = false;

  constructor(
    private readonly host: VmBindingHost,
    private readonly cb: VmBindingCallbacks,
  ) {
    host.addController(this);
    this.consumer = new ContextConsumer(host, {
      context: vmHostContext,
      subscribe: true,
      callback: (value) => this.onProvidedHost(value),
    });
  }

  /** The current bound VM, if any. */
  get vm(): Vm | undefined {
    return this.currentVm;
  }

  /** The VmHost backing this binding (a provider's, or our own), if any. */
  get vmHost(): VmHost | undefined {
    return this.boundHost;
  }

  hostConnected(): void {
    installContextRoot();
    // Decide after a microtask: a wrapping provider upgrades and connects before
    // its children, so a synchronous context-request has already been answered;
    // the ContextRoot covers late/cross-tree providers.
    queueMicrotask(() => this.decide());
  }

  hostDisconnected(): void {
    this.unsub?.();
    this.unsub = undefined;
    if (this.ownsVm && this.ownHost) {
      const owned = this.ownHost;
      this.ownHost = undefined;
      void owned.close();
    }
    this.boundHost = undefined;
    this.providedHost = undefined;
    this.currentVm = undefined;
    this.ownsVm = false;
    this.decided = false;
    this.cb.onVm(undefined);
  }

  private onProvidedHost(value: VmHost | undefined): void {
    this.providedHost = value;
    if (!this.decided && value) this.decide();
  }

  private decide(): void {
    if (this.decided) return;

    const source = decideVmSource({
      explicitVm: this.host.vm,
      providedHost: this.providedHost,
      standaloneAllowed: this.host.standaloneAllowed ?? false,
    });

    switch (source.kind) {
      case "explicit":
        this.decided = true;
        this.ownsVm = false;
        this.setVm(source.vm);
        return;
      case "provided":
        this.decided = true;
        this.ownsVm = false;
        this.bind(source.host);
        return;
      case "standalone":
        this.decided = true;
        this.ownsVm = true;
        this.ownHost = makeVmHost(this.host.bootOptions());
        this.bind(this.ownHost);
        return;
      case "undecided":
        // stay undecided — a late provider can still bind us.
        return;
    }
  }

  private bind(h: VmHost): void {
    this.boundHost = h;
    this.unsub?.();
    this.unsub = h.subscribe((vm) => this.setVm(vm));
    h.ready.catch((e) => this.cb.onError?.(e));
  }

  private setVm(vm: Vm | undefined): void {
    this.currentVm = vm;
    this.cb.onVm(vm);
    this.host.requestUpdate();
  }
}
