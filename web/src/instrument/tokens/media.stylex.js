/**
 * media.stylex.js — breakpoints and input queries.
 *
 * Global breakpoints are for PAGE CHROME ONLY (gutters, nav collapse).
 * Component layout should respond to its container, not the viewport —
 * put layout.cq on a component root and use @container queries in the
 * app's own layout styles.
 */
import * as stylex from "@stylexjs/stylex";

export const media = stylex.defineConsts({
  mobile: "@media (max-width: 768px)",
  tablet: "@media (min-width: 769px) and (max-width: 1024px)",
  laptop: "@media (min-width: 1025px)",
  pointerCoarse: "@media (pointer: coarse)",
  reducedMotion: "@media (prefers-reduced-motion: reduce)",
  forcedColors: "@media (forced-colors: active)",
});
