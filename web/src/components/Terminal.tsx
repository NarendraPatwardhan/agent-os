import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  type MutableRefObject,
} from "react";
import type { Shell, Vm } from "@mc/core";
import { useOptionalVmHost } from "./VmProvider";
import { XtermView, type XtermViewHandle, type XtermViewProps } from "./XtermView";

export interface TerminalHandle extends XtermViewHandle {
  readonly shell: Shell | undefined;
  readonly vm: Vm | undefined;
  send(data: string | Uint8Array): void;
}

export interface TerminalProps extends Omit<XtermViewProps, "onData" | "onReady"> {
  vm?: Vm;
  shell?: Shell;
  language?: "sh" | "luau";
  replayHistory?: boolean;
  onData?: (data: string, bytes: Uint8Array) => void;
  onOutput?: (bytes: Uint8Array, text: string) => void;
  onReady?: (handle: TerminalHandle) => void;
}

const decoder = new TextDecoder();

function useLatest<T>(value: T): MutableRefObject<T> {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
}

function resolveShell(
  explicitShell: Shell | undefined,
  explicitVm: Vm | undefined,
  host: { vm: Vm | undefined; shell: Shell | undefined } | null,
  language: "sh" | "luau" | undefined,
): { shell: Shell | undefined; vm: Vm | undefined } {
  if (explicitShell) return { shell: explicitShell, vm: explicitVm ?? host?.vm };
  if (explicitVm) return { shell: explicitVm.shell(language ? { language } : undefined), vm: explicitVm };
  if (!host?.vm) return { shell: host?.shell, vm: undefined };
  if (language) return { shell: host.vm.shell({ language }), vm: host.vm };
  return { shell: host.shell, vm: host.vm };
}

export const Terminal = forwardRef<TerminalHandle, TerminalProps>(function Terminal(
  {
    vm,
    shell,
    language,
    replayHistory = true,
    onData,
    onOutput,
    onReady,
    ...xtermProps
  },
  ref,
) {
  const host = useOptionalVmHost();
  const hasHost = host !== null;
  const hostVm = host?.vm;
  const hostShell = host?.shell;
  const xtermRef = useRef<XtermViewHandle | null>(null);
  const shellRef = useRef<Shell | undefined>(undefined);
  const vmRef = useRef<Vm | undefined>(undefined);
  const onDataRef = useLatest(onData);
  const onOutputRef = useLatest(onOutput);
  const onReadyRef = useLatest(onReady);
  const [terminalHandle, setTerminalHandle] = useState<XtermViewHandle | null>(null);
  const [activeShell, setActiveShell] = useState<Shell | undefined>(undefined);

  const send = useCallback((data: string | Uint8Array): void => {
    shellRef.current?.write(data);
  }, []);

  const handle = useMemo<TerminalHandle>(
    () => ({
      get terminal() {
        return xtermRef.current?.terminal ?? null;
      },
      get shell() {
        return shellRef.current;
      },
      get vm() {
        return vmRef.current;
      },
      clear() {
        xtermRef.current?.clear();
      },
      fit() {
        xtermRef.current?.fit();
      },
      focus() {
        xtermRef.current?.focus();
      },
      reset() {
        xtermRef.current?.reset();
      },
      send,
      write(data) {
        xtermRef.current?.write(data);
      },
    }),
    [send],
  );

  useImperativeHandle(ref, () => handle, [handle]);

  useEffect(() => {
    const resolved = resolveShell(shell, vm, hasHost ? { vm: hostVm, shell: hostShell } : null, language);
    shellRef.current = resolved.shell;
    vmRef.current = resolved.vm;
    setActiveShell(resolved.shell);
  }, [hasHost, hostShell, hostVm, language, shell, vm]);

  useEffect(() => {
    if (!terminalHandle || !activeShell) return undefined;

    terminalHandle.reset();
    if (replayHistory) {
      const history = activeShell.history();
      if (history.length > 0) terminalHandle.write(history);
    }

    const unsubscribe = activeShell.on((bytes) => {
      terminalHandle.write(bytes);
      onOutputRef.current?.(bytes, decoder.decode(bytes));
    });
    terminalHandle.fit();
    return unsubscribe;
  }, [activeShell, onOutputRef, replayHistory, terminalHandle]);

  const handleReady = useCallback(
    (xterm: XtermViewHandle): void => {
      xtermRef.current = xterm;
      setTerminalHandle(xterm);
      onReadyRef.current?.(handle);
    },
    [handle, onReadyRef],
  );

  const handleData = useCallback(
    (data: string, bytes: Uint8Array): void => {
      shellRef.current?.write(bytes);
      onDataRef.current?.(data, bytes);
    },
    [onDataRef],
  );

  return <XtermView {...xtermProps} ref={xtermRef} onData={handleData} onReady={handleReady} />;
});
