import { useRef, useState } from "react";
import type { McTerminal, Vm } from "@mc/elements";

/** How a session gets its VM. `browser` self-boots a staged flavor tar (the `image`
 *  prop drives the browser boot per-instance); `attach` binds an externally-created
 *  VM (a remote handle, a fork) to a `manual` terminal. */
export type BootSpec =
  | { readonly kind: "browser"; readonly image: string; readonly net?: boolean; readonly deterministic?: boolean }
  | { readonly kind: "attach"; readonly vm: Vm };

export type VmSession = {
  // render props consumed by <TerminalPanel>
  readonly terminalRef: (el: McTerminal | null) => void;
  readonly bootKey: number;
  readonly spec: BootSpec | null;
  readonly live: boolean;
  readonly logs: readonly string[];
  readonly vm: Vm | null;
  // imperative API for drivers
  readonly bootBrowser: (image: string, opts?: { net?: boolean; deterministic?: boolean }) => void;
  readonly attach: (vm: Vm) => void;
  readonly reboot: () => void;
  readonly close: () => void;
  readonly send: (data: string) => void;
  /** Resolves the next time the shell emits its `$ ` prompt (or on timeout, so a hung
   *  command can't wedge a step list). Subscribe BEFORE typing, then await. */
  readonly promptReturn: (timeoutMs?: number) => Promise<void>;
  readonly print: (line: string) => void;
  readonly setLogs: (lines: readonly string[]) => void;
  readonly clearLogs: () => void;
  /** Paint a synthetic prompt + captured stdout into the xterm display (display-only). */
  readonly echoTerminal: (prompt: string, stdout: string) => void;
};

type Options = {
  /** Fired once per boot, when the VM's shell is ready. Read through a ref, so the
   *  latest closure (fresh editor source, etc.) is always used. */
  readonly onReady?: (vm: Vm, session: VmSession) => void;
};

const crlf = (s: string): string => s.replace(/\r?\n/g, "\r\n");

/** The shared VM/terminal substrate, once. Owns the race-safe mc-ready wiring, the
 *  reboot-by-key, the vm handle, the logs, and both boot modes. Every driver calls
 *  this and hands the result to <TerminalPanel>. */
export function useVmSession(opts: Options = {}): VmSession {
  const [spec, setSpec] = useState<BootSpec | null>(null);
  const [bootKey, setBootKey] = useState(0);
  const [logs, setLogsState] = useState<readonly string[]>([]);

  const termRef = useRef<McTerminal | null>(null);
  const vmRef = useRef<Vm | null>(null);
  const specRef = useRef<BootSpec | null>(null);
  const ranRef = useRef(false); // onReady fires at most once per boot (mc-ready can double-fire)
  const optsRef = useRef(opts);
  const sessionRef = useRef<VmSession | null>(null);
  optsRef.current = opts;
  specRef.current = spec;

  // ONE place: the mc-ready listener. Stable handler; reads the latest onReady + spec
  // via refs. Fires for BOTH a browser self-boot and an attach (attach → onVm → mc-ready).
  const onReady = useRef((e: Event): void => {
    const vm = ((e as CustomEvent).detail?.vm ?? null) as Vm | null;
    if (!vm || ranRef.current) return;
    ranRef.current = true;
    vmRef.current = vm;
    optsRef.current.onReady?.(vm, sessionRef.current!);
  }).current;

  // Ref callback (not an effect): attaches the listener SYNCHRONOUSLY on mount, so a
  // warm-cache boot can't fire mc-ready before we're listening. Also kicks el.attach.
  const terminalRef = useRef((el: McTerminal | null): void => {
    const prev = termRef.current;
    if (prev) prev.removeEventListener("mc-ready", onReady);
    termRef.current = el;
    if (!el) return;
    el.addEventListener("mc-ready", onReady);
    if (specRef.current?.kind === "attach") el.attach(specRef.current.vm);
  }).current;

  const reset = (): void => {
    vmRef.current = null;
    ranRef.current = false;
  };

  const api: VmSession = {
    terminalRef,
    bootKey,
    spec,
    live: spec !== null,
    logs,
    vm: vmRef.current,
    bootBrowser: (image, o) => {
      reset();
      setSpec({ kind: "browser", image, net: o?.net ?? true, deterministic: o?.deterministic ?? false });
      setBootKey((k) => k + 1);
    },
    attach: (vm) => {
      reset();
      setSpec({ kind: "attach", vm });
      setBootKey((k) => k + 1);
    },
    reboot: () => {
      if (specRef.current?.kind !== "browser") return;
      reset();
      setBootKey((k) => k + 1);
    },
    close: () => {
      reset();
      setSpec(null);
    },
    send: (data) => termRef.current?.send(data),
    promptReturn: (timeoutMs = 15_000) =>
      new Promise<void>((resolve) => {
        const el = termRef.current;
        if (!el) return resolve();
        const settle = (): void => {
          clearTimeout(timer);
          el.removeEventListener("mc-output", onOut);
          resolve();
        };
        const timer = setTimeout(settle, timeoutMs);
        const onOut = (e: Event): void => {
          const text = ((e as CustomEvent).detail?.text ?? "") as string;
          if (text.endsWith("$ ")) settle();
        };
        el.addEventListener("mc-output", onOut);
      }),
    print: (line) => setLogsState((p) => [...p, line]),
    setLogs: (lines) => setLogsState(lines),
    clearLogs: () => setLogsState([]),
    echoTerminal: (prompt, stdout) => {
      const t = termRef.current?.terminal;
      if (!t) return;
      if (prompt) t.write(crlf(prompt));
      if (stdout) t.write(crlf(stdout));
    },
  };
  sessionRef.current = api;
  return api;
}
