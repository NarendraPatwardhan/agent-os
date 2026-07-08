/**
 * layer.stylex.js — z-index for IN-FLOW / PORTALED chrome only.
 *
 * <dialog> and [popover] render in the browser top layer, which stacks
 * above everything and ignores z-index entirely — prefer them for all
 * overlays. These values exist for sticky
 * bars and hand-portaled elements. An element with transform, filter, or
 * backdrop-filter creates a stacking context that TRAPS descendant
 * popovers regardless of these values — portal to <body> instead.
 */
import * as stylex from '@stylexjs/stylex';

export const layer = stylex.defineConsts({
  sticky: '20',
  drawer: '40',
  popover: '60',
  command: '70',
  toast: '80',
  tooltip: '90',
});
