/**
 * themes.js — scoped remapping: color scheme, accent scopes, density.
 *
 * ACCENT SCOPES are the only sanctioned "splash of color". Apply one to a subtree root and every accent-slot
 * consumer inside (buttons, accent text) shifts together — components
 * stay color-agnostic:
 *
 *   <aside {...stylex.props(accentBrand)}>
 *     <button {...stylex.props(controls.button)}>Upgrade</button>
 *   </aside>
 *
 * Values are literals (not var references) because a theme must stand on
 * its own; each carries both modes via light-dark().
 */
import * as stylex from '@stylexjs/stylex';
import { color } from './tokens/color.stylex.js';
import { size } from './tokens/size.stylex.js';

/* ----- Color scheme: follow the OS by default (surface.root); pin a
 * subtree — or the whole app — explicitly with these. ----- */
export const scheme = stylex.create({
  auto: { colorScheme: 'light dark' },
  light: { colorScheme: 'light' },
  dark: { colorScheme: 'dark' },
});

/* ----- Accent scopes ----- */

/* Brand splash — violet 275. Deliberate marketing moments: a hero CTA,
 * plan badges, onboarding. Never product chrome wholesale. */
export const accentBrand = stylex.createTheme(color, {
  accent: 'light-dark(oklch(0.50 0.19 275), oklch(0.74 0.14 275))',
  accentHover: 'light-dark(oklch(0.45 0.19 275), oklch(0.79 0.13 275))',
  accentSoft: 'light-dark(oklch(0.95 0.03 275), oklch(0.30 0.07 275 / 0.5))',
  accentBorder: 'light-dark(oklch(0.82 0.08 275), oklch(0.55 0.12 275))',
  accentText: 'light-dark(oklch(0.44 0.17 275), oklch(0.83 0.10 275))',
  accentContrast: 'light-dark(oklch(0.99 0 0), oklch(0.15 0.02 275))',
});

/* Signal accent — primary actions take the attention hue (e.g. a
 * "continue" flow where the action IS the pointing). */
export const accentSignal = stylex.createTheme(color, {
  accent: 'light-dark(oklch(0.58 0.14 245), oklch(0.75 0.11 245))',
  accentHover: 'light-dark(oklch(0.52 0.14 245), oklch(0.80 0.10 245))',
  accentSoft: 'light-dark(oklch(0.95 0.025 245), oklch(0.30 0.05 245 / 0.5))',
  accentBorder: 'light-dark(oklch(0.82 0.07 245), oklch(0.52 0.09 245))',
  accentText: 'light-dark(oklch(0.46 0.13 245), oklch(0.81 0.09 245))',
  accentContrast: 'light-dark(oklch(0.99 0 0), oklch(0.15 0.01 245))',
});

/* Danger accent — destructive confirmation scopes. */
export const accentDanger = stylex.createTheme(color, {
  accent: 'light-dark(oklch(0.56 0.22 26), oklch(0.70 0.18 26))',
  accentHover: 'light-dark(oklch(0.50 0.22 26), oklch(0.76 0.17 26))',
  accentSoft: 'light-dark(oklch(0.96 0.028 26), oklch(0.32 0.07 26 / 0.44))',
  accentBorder: 'light-dark(oklch(0.84 0.075 26), oklch(0.52 0.13 26))',
  accentText: 'light-dark(oklch(0.43 0.18 26), oklch(0.82 0.12 26))',
  accentContrast: 'light-dark(oklch(0.99 0 0), oklch(0.16 0.01 26))',
});

/* Success accent — completion moments. */
export const accentSuccess = stylex.createTheme(color, {
  accent: 'light-dark(oklch(0.58 0.15 150), oklch(0.72 0.13 150))',
  accentHover: 'light-dark(oklch(0.52 0.15 150), oklch(0.78 0.12 150))',
  accentSoft: 'light-dark(oklch(0.96 0.035 150), oklch(0.32 0.06 150 / 0.44))',
  accentBorder: 'light-dark(oklch(0.84 0.085 150), oklch(0.52 0.10 150))',
  accentText: 'light-dark(oklch(0.39 0.12 150), oklch(0.84 0.10 150))',
  accentContrast: 'light-dark(oklch(0.99 0 0), oklch(0.15 0.01 150))',
});

/* ----- Density — a THEME applied to a scope, never per-element sizing.
 * Apply to a data table, an inspector, a comfortable settings page. ----- */
export const densityCompact = stylex.createTheme(size, {
  controlSm: '24px',
  controlMd: '32px',
  controlLg: '40px',
  row: '32px',
  rowCompact: '24px',
});

export const densityComfortable = stylex.createTheme(size, {
  controlSm: '32px',
  controlMd: '40px',
  controlLg: '48px',
  row: '44px',
  rowCompact: '36px',
});
