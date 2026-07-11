// A VmHost is one VM's lifecycle, owned and shared. <mc-sandbox> makes one and
// hands it to descendants; a standalone widget makes its own. It exists for two
// reasons: (a) a VM boots asynchronously, and (b) fork()/restore() swap in a
// *new* Vm — so consumers can't hold a raw Vm, they hold this indirection and
// re-bind whenever it changes.
//
// It also owns ONE canonical shell. The embedded backend fans all stdout (the
// interactive shell and every exec) through a single sink, so one shell with many
// listeners is the honest model — handing each terminal its own shell would just
// mirror the same stream.

import { mc } from "@mc/core";
import type { CreateOptions, Runtime, Shell, Vm } from "@mc/core";
import { loadCatalogCompiler, loadImage, loadKernel } from "./artifacts.js";

/** Boot options as read off an element's attributes (URLs/names, never bytes). */
export interface BootOptions {
  runtime?: Runtime;
  /** Logical image name, a direct URL, or `null` for an empty in-memory fs. */
  image?: string | null;
  /** Kernel wasm URL override. */
  kernel?: string;
  net?: boolean;
  endpoint?: string;
  token?: string;
  deterministic?: boolean;
}

export interface VmHost {
  /** The live VM, or undefined until the first boot settles. */
  readonly vm: Vm | undefined;
  /** The one canonical shell onto the VM (undefined until booted). */
  readonly shell: Shell | undefined;
  /** Resolves with the VM on first boot; rejects if boot fails or it was closed. */
  readonly ready: Promise<Vm>;
  /** The resolved CreateOptions (kernel/image bytes included) — kept for fork/restore. */
  readonly createOpts: CreateOptions | undefined;
  /** Subscribe to VM swaps (fork-in/restore); fires immediately if a VM already
   *  exists. Returns an unsubscribe fn. */
  subscribe(cb: (vm: Vm) => void): () => void;
  /** Capture the whole VM as a portable blob. */
  snapshot(): Promise<Uint8Array>;
  /** Branch a fresh, independent VM cloned from the current one. Does NOT swap this
   *  host's VM — the original keeps running (ideal for diverging two views). */
  fork(): Promise<Vm>;
  /** Rewind this host's VM to a snapshot: restore, swap in the new VM, notify
   *  subscribers so bound widgets re-bind, then close the old one. */
  restore(blob: Uint8Array): Promise<Vm>;
  /** Boot a fresh VM from the same options, swap it in, notify subscribers so bound
   *  widgets re-bind, then close the old one. */
  reboot(): Promise<Vm>;
  /** Tear down the VM. */
  close(): Promise<void>;
}

/** Turn boot attributes into CreateOptions, fetching kernel/image bytes for the
 *  embedded (local/browser) runtimes. The remote runtime carries names/URLs, not bytes. */
export async function resolveCreateOptions(boot: BootOptions): Promise<CreateOptions> {
  const runtime = boot.runtime ?? "browser";
  if (runtime === "remote") {
    return {
      runtime,
      endpoint: boot.endpoint,
      token: boot.token,
      net: boot.net,
      image: boot.image,
      deterministic: boot.deterministic,
    };
  }
  const kernel = await loadKernel(boot.kernel);
  let image: Uint8Array | null;
  if (boot.image === null) {
    image = null;
  } else {
    const pending = loadImage(boot.image ?? undefined);
    image = pending ? await pending : null;
  }
  // Runtime `vm.tool` needs catalog-compiler.wasm; in the browser there is no env-var
  // fallback, so thread the page-registered artifact (if any) into every embedded boot.
  const compiler = loadCatalogCompiler();
  return {
    runtime,
    kernel,
    image,
    net: boot.net,
    deterministic: boot.deterministic,
    ...(compiler ? { catalogCompiler: await compiler } : {}),
  };
}

/** Create a VmHost and start booting immediately. */
export function makeVmHost(boot: BootOptions): VmHost {
  const subs = new Set<(vm: Vm) => void>();
  let vm: Vm | undefined;
  let shell: Shell | undefined;
  let createOpts: CreateOptions | undefined;
  let closed = false;

  const notify = (): void => {
    if (!vm) return;
    for (const cb of subs) {
      try {
        cb(vm);
      } catch {
        // one misbehaving subscriber must not break the rest
      }
    }
  };

  const ready: Promise<Vm> = (async () => {
    createOpts = await resolveCreateOptions(boot);
    const booted = await mc.create(createOpts);
    if (closed) {
      // Someone called close() while we were booting — don't leak the VM.
      await booted.close().catch(() => {});
      throw new Error("VmHost was closed during boot");
    }
    vm = booted;
    shell = booted.shell();
    notify();
    return booted;
  })();
  // Callers observe boot failures via `ready`/`subscribe`; swallow the bare
  // rejection here so it isn't reported as an unhandled rejection.
  ready.catch(() => {});

  return {
    get vm() {
      return vm;
    },
    get shell() {
      return shell;
    },
    get createOpts() {
      return createOpts;
    },
    ready,

    subscribe(cb) {
      subs.add(cb);
      if (vm) {
        try {
          cb(vm);
        } catch {
          /* ignore */
        }
      }
      return () => {
        subs.delete(cb);
      };
    },

    async snapshot() {
      const v = await ready;
      return v.snapshot();
    },

    async fork() {
      const v = await ready;
      return v.fork();
    },

    async restore(blob) {
      await ready;
      const opts = createOpts ?? (await resolveCreateOptions(boot));
      const next = await mc.restore(blob, opts);
      const old = vm;
      vm = next;
      shell = next.shell();
      notify();
      if (old) await old.close().catch(() => {});
      return next;
    },

    async reboot() {
      if (closed) throw new Error("VmHost is closed");
      const opts = createOpts ?? (await resolveCreateOptions(boot));
      const next = await mc.create(opts);
      if (closed) {
        await next.close().catch(() => {});
        throw new Error("VmHost was closed during reboot");
      }
      const old = vm;
      vm = next;
      shell = next.shell();
      notify();
      if (old) await old.close().catch(() => {});
      return next;
    },

    async close() {
      closed = true;
      const v = vm;
      vm = undefined;
      shell = undefined;
      subs.clear();
      if (v) await v.close().catch(() => {});
    },
  };
}

/** Wrap an already-created VM as a VmHost that does NOT own it: `close()` leaves the
 *  VM running (its real owner manages the lifecycle). This is <mc-sandbox>'s
 *  controlled mode — one externally-created VM shared to descendants through context.
 *  snapshot/fork read through to the VM; `restore` is refused, because swapping a VM
 *  this host doesn't own would strand the owner's handle. */
export function makeControlledHost(vm: Vm): VmHost {
  const subs = new Set<(vm: Vm) => void>();
  const shell = vm.shell();
  let open = true;
  return {
    get vm() {
      return open ? vm : undefined;
    },
    get shell() {
      return open ? shell : undefined;
    },
    get createOpts() {
      return undefined;
    },
    ready: Promise.resolve(vm),

    subscribe(cb) {
      subs.add(cb);
      if (open) {
        try {
          cb(vm);
        } catch {
          /* ignore */
        }
      }
      return () => {
        subs.delete(cb);
      };
    },

    snapshot() {
      return vm.snapshot();
    },
    fork() {
      return vm.fork();
    },
    restore() {
      return Promise.reject(
        new Error("controlled <mc-sandbox> does not own its VM — restore through the VM's owner"),
      );
    },
    reboot() {
      return Promise.reject(
        new Error("controlled <mc-sandbox> does not own its VM — reboot through the VM's owner"),
      );
    },
    async close() {
      // Non-owning: drop subscribers, but never close a VM we were only handed.
      open = false;
      subs.clear();
    },
  };
}
