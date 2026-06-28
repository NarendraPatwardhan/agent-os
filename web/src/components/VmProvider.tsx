import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { mc } from "@mc/core";
import type { CreateOptions, Shell, Vm } from "@mc/core";

export type VmBootStatus = "idle" | "booting" | "ready" | "error" | "closed";
export type VmFactory = (options: CreateOptions, signal: AbortSignal) => Promise<Vm>;

export interface VmHost {
  readonly vm: Vm | undefined;
  readonly shell: Shell | undefined;
  readonly ready: Promise<Vm> | undefined;
  readonly status: VmBootStatus;
  readonly error: unknown;
  readonly ownsVm: boolean;
  readonly createOptions: CreateOptions | undefined;
  snapshot(): Promise<Uint8Array>;
  fork(): Promise<Vm>;
  restore(snapshot: Uint8Array, options?: CreateOptions): Promise<Vm>;
  reboot(options?: CreateOptions): Promise<Vm>;
  close(options?: { force?: boolean }): Promise<void>;
}

export interface VmProviderProps {
  children: ReactNode;
  /** Controlled VM. The provider exposes it but does not own or close it. */
  vm?: Vm;
  /** Options used by the default factory and retained for restore/reboot. */
  createOptions?: CreateOptions;
  /** Custom VM factory for artifact loading, remote attachment, or test harnesses. */
  createVm?: VmFactory;
  /** Defaults to true when createOptions or createVm is present and no controlled vm is supplied. */
  autoBoot?: boolean;
  /** Close provider-owned VMs on unmount. Defaults to true. */
  closeOnUnmount?: boolean;
  /** The canonical provider shell. Use explicit Terminal.shell for other shell policies. */
  shellLanguage?: "sh" | "luau";
  onVmChange?: (vm: Vm | undefined) => void;
  onStatusChange?: (status: VmBootStatus) => void;
  onError?: (error: unknown) => void;
}

interface VmState {
  vm?: Vm;
  shell?: Shell;
  ready?: Promise<Vm>;
  status: VmBootStatus;
  error?: unknown;
  ownsVm: boolean;
  createOptions?: CreateOptions;
}

const VmHostContext = createContext<VmHost | null>(null);

function abortError(): Error {
  return new Error("VM boot was aborted");
}

async function defaultCreateVm(options: CreateOptions, signal: AbortSignal): Promise<Vm> {
  if (signal.aborted) throw abortError();
  const vm = await mc.create(options);
  if (signal.aborted) {
    await vm.close().catch(() => {});
    throw abortError();
  }
  return vm;
}

export function VmProvider({
  children,
  vm: controlledVm,
  createOptions,
  createVm = defaultCreateVm,
  autoBoot,
  closeOnUnmount = true,
  shellLanguage,
  onVmChange,
  onStatusChange,
  onError,
}: VmProviderProps) {
  const [state, setState] = useState<VmState>({
    status: controlledVm ? "ready" : "idle",
    ownsVm: false,
  });
  const stateRef = useRef(state);
  const bootSeqRef = useRef(0);
  const bootAbortRef = useRef<AbortController | null>(null);

  const commitState = useCallback(
    (next: VmState): void => {
      stateRef.current = next;
      setState(next);
      onStatusChange?.(next.status);
      onVmChange?.(next.vm);
    },
    [onStatusChange, onVmChange],
  );

  const adoptVm = useCallback(
    async (nextVm: Vm | undefined, ownsVm: boolean, nextCreateOptions?: CreateOptions): Promise<void> => {
      const previous = stateRef.current;
      const shell = nextVm?.shell(shellLanguage ? { language: shellLanguage } : undefined);
      commitState({
        vm: nextVm,
        shell,
        ready: nextVm ? Promise.resolve(nextVm) : undefined,
        status: nextVm ? "ready" : "idle",
        ownsVm,
        createOptions: nextCreateOptions,
      });
      if (previous.vm && previous.vm !== nextVm && previous.ownsVm) {
        await previous.vm.close().catch(() => {});
      }
    },
    [commitState, shellLanguage],
  );

  const close = useCallback(
    async (options: { force?: boolean } = {}): Promise<void> => {
      bootSeqRef.current += 1;
      bootAbortRef.current?.abort();
      bootAbortRef.current = null;
      const previous = stateRef.current;
      commitState({
        status: "closed",
        ownsVm: false,
      });
      if (previous.vm && (previous.ownsVm || options.force)) {
        await previous.vm.close().catch(() => {});
      }
    },
    [commitState],
  );

  const boot = useCallback(
    async (options?: CreateOptions): Promise<Vm> => {
      const nextCreateOptions = options ?? createOptions ?? {};
      const seq = bootSeqRef.current + 1;
      bootSeqRef.current = seq;
      bootAbortRef.current?.abort();
      const controller = new AbortController();
      bootAbortRef.current = controller;
      const ready = createVm(nextCreateOptions, controller.signal);
      commitState({
        ready,
        status: "booting",
        ownsVm: true,
        createOptions: nextCreateOptions,
      });

      try {
        const nextVm = await ready;
        if (controller.signal.aborted || bootSeqRef.current !== seq) {
          await nextVm.close().catch(() => {});
          throw abortError();
        }
        await adoptVm(nextVm, true, nextCreateOptions);
        return nextVm;
      } catch (error) {
        if (bootSeqRef.current === seq) {
          commitState({
            ready,
            status: "error",
            error,
            ownsVm: true,
            createOptions: nextCreateOptions,
          });
          onError?.(error);
        }
        throw error;
      }
    },
    [adoptVm, commitState, createOptions, createVm, onError],
  );

  useEffect(() => {
    if (controlledVm) {
      bootSeqRef.current += 1;
      bootAbortRef.current?.abort();
      void adoptVm(controlledVm, false, createOptions);
      return undefined;
    }

    const shouldBoot = autoBoot ?? Boolean(createOptions || createVm !== defaultCreateVm);
    if (!shouldBoot) {
      if (stateRef.current.ownsVm) return undefined;
      commitState({
        status: "idle",
        ownsVm: false,
      });
      return undefined;
    }

    void boot(createOptions).catch(() => {});
    return undefined;
  }, [adoptVm, autoBoot, boot, commitState, controlledVm, createOptions, createVm]);

  useEffect(
    () => () => {
      bootSeqRef.current += 1;
      bootAbortRef.current?.abort();
      const current = stateRef.current;
      if (closeOnUnmount && current.ownsVm && current.vm) {
        void current.vm.close().catch(() => {});
      }
    },
    [closeOnUnmount],
  );

  const currentVm = useCallback(async (): Promise<Vm> => {
    const current = stateRef.current;
    if (current.vm) return current.vm;
    if (current.ready) return current.ready;
    throw new Error("VM is not ready");
  }, []);

  const snapshot = useCallback(async (): Promise<Uint8Array> => {
    return (await currentVm()).snapshot();
  }, [currentVm]);

  const fork = useCallback(async (): Promise<Vm> => {
    return (await currentVm()).fork();
  }, [currentVm]);

  const restore = useCallback(
    async (snapshotBytes: Uint8Array, options?: CreateOptions): Promise<Vm> => {
      const nextCreateOptions = options ?? stateRef.current.createOptions ?? createOptions ?? {};
      const nextVm = await mc.restore(snapshotBytes, nextCreateOptions);
      await adoptVm(nextVm, true, nextCreateOptions);
      return nextVm;
    },
    [adoptVm, createOptions],
  );

  const reboot = useCallback(
    async (options?: CreateOptions): Promise<Vm> => {
      const nextCreateOptions = options ?? stateRef.current.createOptions ?? createOptions ?? {};
      await close();
      return boot(nextCreateOptions);
    },
    [boot, close, createOptions],
  );

  const value = useMemo<VmHost>(
    () => ({
      vm: state.vm,
      shell: state.shell,
      ready: state.ready,
      status: state.status,
      error: state.error,
      ownsVm: state.ownsVm,
      createOptions: state.createOptions,
      snapshot,
      fork,
      restore,
      reboot,
      close,
    }),
    [close, fork, reboot, restore, snapshot, state],
  );

  return <VmHostContext.Provider value={value}>{children}</VmHostContext.Provider>;
}

export function useVmHost(): VmHost {
  const host = useContext(VmHostContext);
  if (!host) {
    throw new Error("useVmHost() must be used inside <VmProvider>");
  }
  return host;
}

export function useOptionalVmHost(): VmHost | null {
  return useContext(VmHostContext);
}
