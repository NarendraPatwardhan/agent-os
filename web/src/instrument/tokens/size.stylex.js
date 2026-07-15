/**
 * size.stylex.js — control metrics and containers.
 *
 * Control/row heights are vars so DENSITY IS A THEME: apply
 * themes.densityCompact / densityComfortable to a scope (a data table)
 * and everything inside re-derives. Never hand-size a control.
 *
 * On coarse pointers the control recipes enforce a 44px floor
 * (see controls.js) — pointer accuracy, not viewport width, is the signal.
 */
import * as stylex from "@stylexjs/stylex";

export const size = stylex.defineVars({
  controlSm: "28px",
  controlMd: "36px",
  controlLg: "44px",
  row: "36px",
  rowCompact: "28px",
});

export const iconSize = stylex.defineConsts({
  sm: "16px",
  md: "20px",
  lg: "24px",
});

export const avatar = stylex.defineConsts({
  xs: "16px",
  sm: "20px",
  md: "28px",
  lg: "36px",
  xl: "48px",
});

/* Shell anatomy + dialog widths. Collapse order:
 * sidebar → sidebarRail → drawer. */
export const shell = stylex.defineConsts({
  sidebar: "240px",
  sidebarRail: "56px",
  inspector: "320px",
  header: "56px",
  dialogSm: "400px", // confirmations
  dialogMd: "560px", // forms
  dialogLg: "720px", // pickers, previews
  toastMin: "240px", // a toast hugs its content between these
  toastMax: "380px",
});

/* Layout containers: page chrome, content column, reading measure
 * (~65ch at bodyLg). */
export const container = stylex.defineConsts({
  page: "1200px",
  content: "1040px",
  reading: "720px",
});
