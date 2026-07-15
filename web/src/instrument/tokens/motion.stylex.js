/**
 * motion.stylex.js — time.
 *
 * Durations are vars, and REDUCED MOTION COLLAPSES HERE, at the token
 * level — every duration becomes 0ms under prefers-reduced-motion, so no
 * component can forget the check.
 *
 * The rules the recipes encode:
 *  · Enters announce (translate + blur + fade, outQuint), exits whisper
 *    (opacity/blur only, shorter).
 *  · Frequency budget: menus, tooltips, dropdowns get NO entrance
 *    animation — at most 100ms of opacity.
 *  · Interaction states use transitions (interruptible, retargetable);
 *    keyframes are for one-shot entrances only.
 */
import * as stylex from "@stylexjs/stylex";

const REDUCE = "@media (prefers-reduced-motion: reduce)";

export const duration = stylex.defineVars({
  fast: { default: "150ms", [REDUCE]: "0ms" }, // hover, color, small state
  base: { default: "200ms", [REDUCE]: "0ms" }, // most transitions
  slow: { default: "300ms", [REDUCE]: "0ms" }, // panels, size changes
  page: { default: "500ms", [REDUCE]: "0ms" }, // page-level orchestration only
});

export const easing = stylex.defineConsts({
  out: "cubic-bezier(0, 0, 0.2, 1)", // the default
  outQuint: "cubic-bezier(0.23, 1, 0.32, 1)", // panels + enters: fast start, long settle
  inOut: "cubic-bezier(0.45, 0, 0.55, 1)", // continuous movement only
});
