/**
 * shadow.stylex.js — depth.
 *
 * Every shadow is a recipe of two soft drops at very low alpha — never one
 * heavy drop. If a shadow is NOTICEABLE, it is too strong; depth lives at
 * the threshold of perception (light-mode alphas run 0.04–0.28).
 *
 * Shadows are the DEPTH channel only. Edges are borders; focus is outline;
 * selection is the one sanctioned inset ring (controls.js). Never draw a
 * border or a focus ring with box-shadow.
 *
 * Dark mode keeps a faint grounding shadow, but real dark-mode elevation
 * is the lightness step in the surface ladder (color.stylex.js).
 */
import * as stylex from '@stylexjs/stylex';

export const shadow = stylex.defineVars({
  rest: '0 1px 2px 0 light-dark(oklch(0 0 0 / 0.04), oklch(0 0 0 / 0.35)), 0 2px 4px -2px light-dark(oklch(0 0 0 / 0.04), oklch(0 0 0 / 0.35))',
  raised: '0 2px 4px -2px light-dark(oklch(0 0 0 / 0.06), oklch(0 0 0 / 0.40)), 0 4px 12px -4px light-dark(oklch(0 0 0 / 0.08), oklch(0 0 0 / 0.45))',
  overlay: '0 3px 12px -4px light-dark(oklch(0 0 0 / 0.10), oklch(0 0 0 / 0.50)), 0 12px 32px -12px light-dark(oklch(0 0 0 / 0.14), oklch(0 0 0 / 0.55))',
  modal: '0 12px 32px -12px light-dark(oklch(0 0 0 / 0.18), oklch(0 0 0 / 0.60)), 0 40px 96px -32px light-dark(oklch(0 0 0 / 0.24), oklch(0 0 0 / 0.70))',
  toast: '0 8px 24px -8px light-dark(oklch(0 0 0 / 0.20), oklch(0 0 0 / 0.60)), 0 24px 48px -24px light-dark(oklch(0 0 0 / 0.28), oklch(0 0 0 / 0.70))',
});
