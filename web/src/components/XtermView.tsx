import { FitAddon } from "@xterm/addon-fit";
import { Terminal as XtermTerminal } from "@xterm/xterm";
import type {
  ITerminalInitOnlyOptions,
  ITerminalOptions,
  ITheme,
  Terminal as XtermTerminalType,
} from "@xterm/xterm";
import {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  type HTMLAttributes,
  type MutableRefObject,
} from "react";
import { readCssVar, resolveCssColor, resolveCssPx, rgbaCssColor } from "./terminalTheme";
import styles from "./XtermView.module.css";

export interface XtermViewHandle {
  readonly terminal: XtermTerminalType | null;
  clear(): void;
  fit(): void;
  focus(): void;
  reset(): void;
  write(data: string | Uint8Array): void;
}

export interface XtermViewProps extends Omit<HTMLAttributes<HTMLDivElement>, "onInput"> {
  cols?: number;
  rows?: number;
  cursorStyle?: "bar" | "block" | "underline";
  cursorBlink?: boolean;
  fontSize?: number;
  lineHeight?: number;
  scrollback?: number;
  theme?: Partial<ITheme>;
  terminalOptions?: Partial<ITerminalOptions & ITerminalInitOnlyOptions>;
  onData?: (data: string, bytes: Uint8Array) => void;
  onReady?: (handle: XtermViewHandle) => void;
}

const encoder = new TextEncoder();

function useLatest<T>(value: T): MutableRefObject<T> {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
}

function pickBackground(scope: HTMLElement): string {
  const ownBackground = getComputedStyle(scope).backgroundColor;
  if (ownBackground && ownBackground !== "rgba(0, 0, 0, 0)" && ownBackground !== "transparent") {
    return ownBackground;
  }
  return resolveCssColor("var(--mc-term-bg, var(--surface-2, #0b0b0c))", scope);
}

function buildTheme(scope: HTMLElement, overrides: Partial<ITheme> | undefined): ITheme {
  const background = overrides?.background ?? pickBackground(scope);
  return {
    background,
    foreground:
      overrides?.foreground ?? resolveCssColor("var(--mc-fg, var(--fg, #e8e8ea))", scope),
    cursor:
      overrides?.cursor ?? resolveCssColor("var(--mc-cursor, var(--accent, #d8a531))", scope),
    cursorAccent: overrides?.cursorAccent ?? background,
    selectionBackground:
      overrides?.selectionBackground ??
      rgbaCssColor("var(--mc-accent, var(--accent, #d8a531))", 0.28, scope),
    brightBlack:
      overrides?.brightBlack ??
      resolveCssColor("var(--mc-fg-subtle, var(--fg-subtle, #8b8b90))", scope),
    ...overrides,
  };
}

export const XtermView = forwardRef<XtermViewHandle, XtermViewProps>(function XtermView(
  {
    className,
    cols,
    rows,
    cursorStyle = "bar",
    cursorBlink = true,
    fontSize,
    lineHeight = 1.3,
    scrollback = 1000,
    theme,
    terminalOptions,
    onData,
    onReady,
    ...divProps
  },
  ref,
) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const screenRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<XtermTerminalType | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const autoFitRef = useRef(!(cols && rows));
  const onDataRef = useLatest(onData);
  const onReadyRef = useLatest(onReady);

  const write = useCallback((data: string | Uint8Array): void => {
    terminalRef.current?.write(data);
  }, []);

  const fit = useCallback((): void => {
    try {
      fitRef.current?.fit();
      terminalRef.current?.scrollToBottom();
    } catch {
      // xterm throws if fit runs while the host node is detached or display:none.
    }
  }, []);

  const handle = useMemo<XtermViewHandle>(
    () => ({
      get terminal() {
        return terminalRef.current;
      },
      clear() {
        terminalRef.current?.clear();
      },
      fit,
      focus() {
        terminalRef.current?.focus();
      },
      reset() {
        terminalRef.current?.reset();
      },
      write,
    }),
    [fit, write],
  );

  useImperativeHandle(ref, () => handle, [handle]);

  useLayoutEffect(() => {
    const root = rootRef.current;
    const screen = screenRef.current;
    if (!root || !screen) return undefined;

    autoFitRef.current = !(cols && rows);
    const fontFamily =
      readCssVar(root, "--mc-font-mono") ||
      readCssVar(root, "--font-mono") ||
      'ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace';
    const resolvedFontSize =
      fontSize ?? resolveCssPx("var(--mc-term-fs, var(--fs-13, 13px))", root) ?? 13;
    const options: ITerminalOptions & ITerminalInitOnlyOptions = {
      convertEol: false,
      cursorBlink,
      cursorStyle,
      cursorInactiveStyle: "outline",
      fontFamily,
      fontSize: resolvedFontSize,
      lineHeight,
      scrollback,
      theme: buildTheme(root, theme),
      ...terminalOptions,
    };

    if (!autoFitRef.current) {
      options.cols = cols;
      options.rows = rows;
    }

    const terminal = new XtermTerminal(options);
    const fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.open(screen);
    terminalRef.current = terminal;
    fitRef.current = fitAddon;

    const dataSubscription = terminal.onData((data) => {
      onDataRef.current?.(data, encoder.encode(data));
    });

    const refit = (): void => {
      if (autoFitRef.current) fit();
    };

    if (autoFitRef.current) {
      fit();
      requestAnimationFrame(refit);
      document.fonts?.ready.then(refit).catch(() => {});
    }

    const resizeObserver = autoFitRef.current ? new ResizeObserver(refit) : null;
    if (resizeObserver) {
      resizeObserver.observe(root);
      resizeObserver.observe(screen);
    }

    const focus = (): void => terminal.focus();
    root.addEventListener("click", focus);
    onReadyRef.current?.(handle);

    return () => {
      root.removeEventListener("click", focus);
      resizeObserver?.disconnect();
      dataSubscription.dispose();
      terminalRef.current = null;
      fitRef.current = null;
      terminal.dispose();
    };
  }, [
    cols,
    cursorBlink,
    cursorStyle,
    fit,
    fontSize,
    lineHeight,
    rows,
    scrollback,
    terminalOptions,
    theme,
    handle,
  ]);

  return (
    <div {...divProps} ref={rootRef} className={[styles.root, className].filter(Boolean).join(" ")}>
      <div ref={screenRef} className={styles.screen} />
    </div>
  );
});
