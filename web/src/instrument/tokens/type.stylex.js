/**
 * type.stylex.js — typography tokens.
 *
 * Three faces, five jobs: sans = all UI · mono = code/data + metadata
 * (eyebrows, kbd, timestamps, numbering) · serif = editorial + the italic
 * swap. The serif never sets UI; the mono never sets prose.
 *
 * Weight ceiling: 400 / 450 / 550. Bold (700) does not exist in this
 * system — hierarchy comes from size and gray-value.
 * The 450/550 weights require the variable fonts in the stacks below.
 *
 * Sizes are optically chosen (12.5 / 13.5 are deliberate half-pixel
 * in-betweens), never modular-scale output. Author against the text.*
 * roles in text.js — these tokens exist for the recipes, not for ad-hoc
 * font styling in product code.
 */
import * as stylex from '@stylexjs/stylex';

/* Families are vars (rebrandable via createTheme). */
export const font = stylex.defineVars({
  sans: '"InterVariable", "Inter Variable", "Inter", ui-sans-serif, system-ui, sans-serif',
  display: '"Inter Tight Variable", "Inter Tight", "InterVariable", "Inter Variable", "Inter", ui-sans-serif, system-ui, sans-serif',
  mono: '"IBM Plex Mono", "Geist Mono Variable", "Geist Mono", ui-monospace, "SF Mono", Menlo, monospace',
  serif: '"Newsreader", "Newsreader Variable", "Source Serif 4", "Iowan Old Style", Charter, Georgia, serif',
});

/* Everything below is consts — inlined at build, not themable. */
export const fontSize = stylex.defineConsts({
  micro: '10px',
  caption: '11px',
  label: '12.5px',
  body: '13.5px',
  bodyLg: '15px',
  title: '18px',
  heading: '24px',
  display: 'clamp(40px, 30px + 3vw, 64px)',
  code: '13px',
});

export const fontWeight = stylex.defineConsts({
  regular: '400',
  medium: '450', // the workhorse: labels, buttons, nav
  strong: '550', // headings, titles, inline emphasis — the ceiling
});

export const leading = stylex.defineConsts({
  micro: '14px',
  caption: '16px',
  label: '16px',
  body: '20px',
  bodyLg: '24px',
  title: '24px',
  heading: '32px',
  display: '1.05',
  code: '20px',
});

/* Tracking tightens as size grows; only the uppercase eyebrow opens up. */
export const tracking = stylex.defineConsts({
  display: '-0.02em',
  heading: '-0.015em',
  title: '-0.01em',
  ui: '-0.005em',
  normal: '0',
  micro: '0.06em',
  eyebrow: '0.08em',
});
