/**
 * radius.stylex.js — shape.
 *
 * Small, precise radii built for CONCENTRIC NESTING (outer = inner +
 * padding): a modal (16) with s1 (4px) padding holds a card (12); the
 * card with s1 padding holds a control (8); floor at 4. Corners that
 * share a center look machined; equal nested radii look glued.
 */
import * as stylex from '@stylexjs/stylex';

export const radius = stylex.defineConsts({
  r1: '4px', // concentric floor
  r2: '6px',
  r3: '8px',
  r4: '12px',
  r5: '16px',
  r6: '20px',
  pill: '999px',

  /* Semantic aliases — use these, not the scale, in recipes. */
  chip: '6px',
  control: '8px', // buttons, inputs
  card: '12px',
  modal: '16px', // dialogs, floating frames
  sheet: '20px',
});
