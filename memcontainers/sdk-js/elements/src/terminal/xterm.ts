// The one place that knows how to dress an xterm in the host page's design tokens,
// open it into a body element, keep it fitted, and tear it down cleanly. This is
// half of the "xterm fights the DOM" subsystem — the JS half (fit / dispose /
// theme sampling); the other half is styles/terminal.css (the .mc-term overrides
// that tame xterm's injected scrollbar + cursor). The two must move together.

import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import type { ITerminalInitOnlyOptions, ITerminalOptions, ITheme } from "@xterm/xterm";
import { readVar, resolveColor, resolvePx, rgbaColor } from "./token-probe.js";

export interface MakeXtermOptions {
  cols?: number;
  rows?: number;
  /** Slim `bar` caret by default — a block reads "fat" against a comfortable line-height. */
  cursorStyle?: "bar" | "block" | "underline";
  cursorBlink?: boolean;
  lineHeight?: number;
  fontSize?: number;
}

export interface TerminalHandle {
  readonly term: Terminal;
  readonly fit: FitAddon;
  refit(): void;
  ensureColumns(columns: number): void;
  dispose(): void;
}

/** Sample the effective background: an explicit CSS background on the scope wins,
 *  else the terminal-bg token, else a dark fallback. */
function pickBackground(scope: HTMLElement): string {
  const bg = getComputedStyle(scope).backgroundColor;
  if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") return bg;
  return resolveColor("var(--mc-term-bg, var(--surface-2, #0b0b0c))", scope);
}

/** Open an xterm into `body`, themed from the tokens visible at `scope`, and keep
 *  it fitted to the box. `scope` is the element that carries `.mc-term` (and any
 *  per-terminal `--mc-*` overrides); `body` is the inner screen it renders into. */
export function makeXterm(
  scope: HTMLElement,
  body: HTMLElement,
  opts: MakeXtermOptions = {},
): TerminalHandle {
  const background = pickBackground(scope);
  const fontFamily =
    readVar(scope, "--mc-font-mono") ||
    readVar(scope, "--font-mono") ||
    'ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace';
  const fontSize = opts.fontSize ?? resolvePx("var(--mc-term-fs, var(--fs-13, 13px))", scope) ?? 13;

  const theme: ITheme = {
    background,
    foreground: resolveColor("var(--mc-fg, var(--fg, #e8e8ea))", scope),
    cursor: resolveColor("var(--mc-cursor, var(--accent, #d8a531))", scope),
    cursorAccent: background,
    // Translucent so selected text stays readable.
    selectionBackground: rgbaColor("var(--mc-accent, var(--accent, #d8a531))", 0.28, scope),
    brightBlack: resolveColor("var(--mc-fg-subtle, var(--fg-subtle, #8b8b90))", scope),
  };

  // Auto-fit unless the caller pinned an explicit grid.
  const autoFit = !(opts.cols && opts.rows);

  const options: ITerminalOptions & ITerminalInitOnlyOptions = {
    convertEol: false, // the kernel already emits CRLF (ONLCR)
    cursorBlink: opts.cursorBlink ?? true,
    cursorStyle: opts.cursorStyle ?? "bar",
    cursorInactiveStyle: "outline",
    fontFamily,
    fontSize,
    lineHeight: opts.lineHeight ?? 1.3,
    scrollback: 1000,
    theme,
  };
  if (!autoFit) {
    options.cols = opts.cols;
    options.rows = opts.rows;
  }

  const term = new Terminal(options);
  const fit = new FitAddon();
  let transcriptColumns = 0;
  term.loadAddon(fit);
  term.open(body);

  const refit = (): void => {
    if (!autoFit) return;
    try {
      const dims = fit.proposeDimensions();
      if (!dims) return;
      const columns = Math.max(dims.cols, transcriptColumns);
      const element = term.element;
      if (element && columns > dims.cols) {
        const css = getComputedStyle(element);
        const padding = Number.parseFloat(css.paddingLeft) + Number.parseFloat(css.paddingRight);
        const contentWidth = Math.max(1, body.clientWidth - padding);
        const cellWidth = contentWidth / dims.cols;
        element.style.width = `${Math.ceil(cellWidth * columns + padding)}px`;
      } else if (element) {
        element.style.width = "100%";
      }
      term.resize(columns, dims.rows);
      term.scrollToBottom();
    } catch {
      /* element detached mid-fit */
    }
  };

  if (autoFit) {
    refit();
    // The first fit can run before fonts/layout settle, leaving rows too tall;
    // re-fit once the box and the mono font are ready.
    requestAnimationFrame(refit);
    if (typeof document !== "undefined" && document.fonts?.ready) {
      document.fonts.ready.then(refit).catch(() => {});
    }
  }

  const ro = autoFit ? new ResizeObserver(() => refit()) : null;
  ro?.observe(body);

  const onClick = (): void => term.focus();
  scope.addEventListener("click", onClick);

  return {
    term,
    fit,
    refit,
    ensureColumns(columns: number) {
      transcriptColumns = Math.max(transcriptColumns, columns);
      refit();
    },
    dispose() {
      ro?.disconnect();
      scope.removeEventListener("click", onClick);
      try {
        term.dispose();
      } catch {
        /* already disposed */
      }
    },
  };
}
