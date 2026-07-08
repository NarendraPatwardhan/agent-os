/**
 * color.stylex.js — every color in the system.
 *
 * Semantic tokens only: the raw 12-step ladders are deliberately NOT
 * exported, so product code cannot reach around the semantics. All neutrals
 * are chroma-0 achromatic; the only hues here are
 * signal (255), danger (26), warning (78), success (150), and the chart set.
 *
 * Every value carries both modes via light-dark(). This resolves against
 * `color-scheme`, which `surface.root` (and reset.css) set to "light dark";
 * pin a subtree with `scheme.light` / `scheme.dark` from themes.js.
 *
 * Contrast contract (verify both modes if you retune an L):
 *   ink ≥ 15:1 · inkMuted ≥ 8:1 (body-safe) · inkSubtle ≥ 4.5:1 on raised
 *   surfaces, large text/captions/icons only on the canvas · inkDisabled is
 *   WCAG-exempt (disabled controls only, never readable content).
 */
import * as stylex from '@stylexjs/stylex';

export const color = stylex.defineVars({
  /* ----- Ink — text and iconography ----- */
  ink:         'light-dark(oklch(0.16 0 0), oklch(0.96 0 0))',
  inkMuted:    'light-dark(oklch(0.38 0 0), oklch(0.79 0 0))',
  inkSubtle:   'light-dark(oklch(0.54 0 0), oklch(0.62 0 0))',
  inkDisabled: 'light-dark(oklch(0.64 0 0), oklch(0.52 0 0))',

  /* ----- The surface ladder -----
   * Light: tinted canvas, identical white raised surfaces — hairline +
   * shadow carry depth. Dark: depth is a lightness step.
   * The canvas register (sunken/canvas, and the whole dark ladder) carries
   * chroma 0.004 at hue 80 — an optical correction, not a palette: pure
   * zero-chroma dark reads blue on most panels, and reference near-blacks
   * are faintly warm. Ink and borders stay chroma-0. */
  bgSunken:  'light-dark(oklch(0.955 0.004 80), oklch(0.128 0.004 80))',
  bgCanvas:  'light-dark(oklch(0.975 0.004 80), oklch(0.145 0.004 80))',
  bgPanel:   'light-dark(oklch(0.99 0 0),  oklch(0.17 0.004 80))',
  bgCard:    'light-dark(oklch(0.99 0 0),  oklch(0.21 0.004 80))',
  bgPopover: 'light-dark(oklch(0.99 0 0),  oklch(0.24 0.004 80))',
  bgModal:   'light-dark(oklch(0.99 0 0),  oklch(0.28 0.004 80))',
  bgToast:   'light-dark(oklch(0.99 0 0),  oklch(0.335 0.004 80))',

  /* ----- The veil register -----
   * Translucent, backdrop-blurred, borderless chrome that floats OVER
   * work: rails, menus, dialogs, HUD chips. Frost is earned by float —
   * anything in flow stays on the opaque ladder above. Edges come from
   * veilHighlight (inner top light) + the backdrop discontinuity, never
   * from a border token. */
  bgVeil:       'light-dark(oklch(0.99 0 0 / 0.72), oklch(0.22 0.004 80 / 0.62))',
  bgVeilRaised: 'light-dark(oklch(0.99 0 0 / 0.80), oklch(0.24 0.004 80 / 0.72))',
  bgVeilDeep:   'light-dark(oklch(0.99 0 0 / 0.86), oklch(0.26 0.004 80 / 0.80))',
  /* Opaque stand-ins for the same rungs: forced-colors/perf fallbacks and
   * the frozen-during-pan state (backdrop-filter off). */
  bgVeilOpaque: 'light-dark(oklch(0.99 0 0 / 0.94), oklch(0.24 0.004 80 / 0.94))',
  veilHighlight: 'light-dark(oklch(1 0 0 / 0.60), oklch(1 0 0 / 0.10))',

  /* ----- Frost — selection as material, not paint -----
   * Selected rows, tabs, checked segments, active nav items: a translucent
   * ink-lift, so the selected thing reads as the surface rising to meet
   * you. Selection has NO hue — the signal points, it does not select. */
  frost:      'light-dark(oklch(0.16 0 0 / 0.06), oklch(1 0 0 / 0.09))',
  frostHover: 'light-dark(oklch(0.16 0 0 / 0.09), oklch(1 0 0 / 0.12))',

  /* ----- Edges ----- */
  border:       'light-dark(oklch(0.91 0 0), oklch(0.30 0 0))',
  borderStrong: 'light-dark(oklch(0.79 0 0), oklch(0.42 0 0))',
  borderHover:  'light-dark(oklch(0.70 0 0), oklch(0.52 0 0))',

  /* ----- Signal — the pointing hue -----
   * TWO jobs, one meaning — "the system is pointing at something":
   * the focus ring, and informational status. Selection is frost (above);
   * links are ink + underline (linkUnderline below). Hue sits at 245 —
   * two steps toward cyan-slate, off the default-blue band every
   * framework ships. */
  signal:       'light-dark(oklch(0.58 0.14 245), oklch(0.75 0.11 245))',
  signalHover:  'light-dark(oklch(0.52 0.14 245), oklch(0.80 0.10 245))',
  signalSoft:   'light-dark(oklch(0.95 0.025 245), oklch(0.30 0.05 245 / 0.5))',
  signalBorder: 'light-dark(oklch(0.82 0.07 245), oklch(0.52 0.09 245))',
  signalText:   'light-dark(oklch(0.46 0.13 245), oklch(0.81 0.09 245))',

  /* ----- Links — ink with a gray underline that darkens on hover.
   * In dense product UI a link is navigation, not an alarm. ----- */
  linkUnderline:      'light-dark(oklch(0.70 0 0), oklch(0.52 0 0))',
  linkUnderlineHover: 'light-dark(oklch(0.16 0 0), oklch(0.96 0 0))',

  /* ----- The accent slot -----
   * What primary actions consume. Defaults to INK — near-black solid on
   * light, near-white on dark. Components stay color-agnostic; a subtree
   * gets a colored accent only via the accent themes in themes.js. */
  accent:         'light-dark(oklch(0.22 0 0), oklch(0.92 0 0))',
  accentHover:    'light-dark(oklch(0.32 0 0), oklch(0.98 0 0))',
  accentSoft:     'light-dark(oklch(0.94 0 0), oklch(0.24 0 0))',
  accentBorder:   'light-dark(oklch(0.67 0 0), oklch(0.58 0 0))',
  accentText:     'light-dark(oklch(0.36 0 0), oklch(0.82 0 0))',
  accentContrast: 'light-dark(oklch(0.99 0 0), oklch(0.15 0 0))',

  /* ----- Status — compact slots, not ramps ----- */
  dangerBase:     'light-dark(oklch(0.56 0.22 26),  oklch(0.70 0.18 26))',
  dangerHover:    'light-dark(oklch(0.50 0.22 26),  oklch(0.76 0.17 26))',
  dangerSoft:     'light-dark(oklch(0.96 0.028 26), oklch(0.32 0.07 26 / 0.44))',
  dangerBorder:   'light-dark(oklch(0.84 0.075 26), oklch(0.52 0.13 26))',
  dangerText:     'light-dark(oklch(0.43 0.18 26),  oklch(0.82 0.12 26))',
  dangerContrast: 'light-dark(oklch(0.99 0 0),      oklch(0.16 0.01 26))',

  warningBase:     'light-dark(oklch(0.72 0.16 78),   oklch(0.80 0.14 78))',
  warningHover:    'light-dark(oklch(0.66 0.16 78),   oklch(0.86 0.13 78))',
  warningSoft:     'light-dark(oklch(0.97 0.045 78),  oklch(0.35 0.07 78 / 0.42))',
  warningBorder:   'light-dark(oklch(0.86 0.11 78),   oklch(0.56 0.11 78))',
  warningText:     'light-dark(oklch(0.43 0.12 70),   oklch(0.86 0.10 78))',
  warningContrast: 'light-dark(oklch(0.18 0.012 78),  oklch(0.16 0.012 78))',

  successBase:     'light-dark(oklch(0.58 0.15 150),  oklch(0.72 0.13 150))',
  successHover:    'light-dark(oklch(0.52 0.15 150),  oklch(0.78 0.12 150))',
  successSoft:     'light-dark(oklch(0.96 0.035 150), oklch(0.32 0.06 150 / 0.44))',
  successBorder:   'light-dark(oklch(0.84 0.085 150), oklch(0.52 0.10 150))',
  successText:     'light-dark(oklch(0.39 0.12 150),  oklch(0.84 0.10 150))',
  successContrast: 'light-dark(oklch(0.99 0 0),       oklch(0.15 0.01 150))',

  /* ----- Charts — categorical, matched L, CVD-spaced hues. Use IN ORDER.
   * chart8 is "other/remainder". Never repurpose status colors as series —
   * a red line must keep meaning danger. Sequential ramps: hold one of
   * these hues, step L (0.9 → 0.4 light). ----- */
  chart1: 'light-dark(oklch(0.58 0.15 245), oklch(0.72 0.12 245))',
  chart2: 'light-dark(oklch(0.60 0.15 150), oklch(0.74 0.12 150))',
  chart3: 'light-dark(oklch(0.66 0.16 70),  oklch(0.78 0.13 75))',
  chart4: 'light-dark(oklch(0.58 0.19 25),  oklch(0.72 0.15 25))',
  chart5: 'light-dark(oklch(0.56 0.17 300), oklch(0.72 0.13 300))',
  chart6: 'light-dark(oklch(0.60 0.13 200), oklch(0.74 0.11 200))',
  chart7: 'light-dark(oklch(0.60 0.15 340), oklch(0.74 0.12 340))',
  chart8: 'light-dark(oklch(0.55 0 0),      oklch(0.70 0 0))',

  /* ----- Overlay scrims ----- */
  scrim:       'light-dark(oklch(0 0 0 / 0.42), oklch(0 0 0 / 0.62))',
  scrimStrong: 'light-dark(oklch(0 0 0 / 0.58), oklch(0 0 0 / 0.72))',
});
