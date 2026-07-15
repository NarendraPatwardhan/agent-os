/**
 * text.js — the ONLY way type is set.
 *
 * Compose one hierarchy role with at most one tone:
 *   stylex.props(text.body, text.muted)
 * Never set font-size / font-weight / line-height in product code.
 *
 * Roles never use the `font` shorthand (it silently resets
 * font-variant-numeric and would wipe tabular figures).
 */
import * as stylex from "@stylexjs/stylex";
import { color } from "./tokens/color.stylex.js";
import { font, fontSize, fontWeight, leading, tracking } from "./tokens/type.stylex.js";

export const text = stylex.create({
  /* ----- Hierarchy roles ----- */
  display: {
    fontFamily: font.display,
    fontSize: fontSize.display,
    fontWeight: fontWeight.strong,
    lineHeight: leading.display,
    letterSpacing: tracking.display,
    textWrap: "balance",
  },
  heading: {
    fontFamily: font.display,
    fontSize: fontSize.heading,
    fontWeight: fontWeight.strong,
    lineHeight: leading.heading,
    letterSpacing: tracking.heading,
    textWrap: "balance",
  },
  title: {
    fontFamily: font.sans,
    fontSize: fontSize.title,
    fontWeight: fontWeight.strong,
    lineHeight: leading.title,
    letterSpacing: tracking.title,
  },
  body: {
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.regular,
    lineHeight: leading.body,
    letterSpacing: tracking.ui,
    textWrap: "pretty",
  },
  bodyLg: {
    fontFamily: font.sans,
    fontSize: fontSize.bodyLg,
    fontWeight: fontWeight.regular,
    lineHeight: leading.bodyLg,
    letterSpacing: tracking.ui,
    textWrap: "pretty",
  },
  label: {
    fontFamily: font.sans,
    fontSize: fontSize.label,
    fontWeight: fontWeight.medium,
    lineHeight: leading.label,
    letterSpacing: tracking.ui,
  },
  caption: {
    fontFamily: font.sans,
    fontSize: fontSize.caption,
    fontWeight: fontWeight.regular,
    lineHeight: leading.caption,
    letterSpacing: tracking.normal,
  },

  /* ----- Metadata voice (mono —) ----- */
  eyebrow: {
    fontFamily: font.mono,
    fontSize: fontSize.caption,
    fontWeight: fontWeight.medium,
    lineHeight: "1",
    letterSpacing: tracking.eyebrow,
    textTransform: "uppercase",
    color: color.inkSubtle,
  },
  micro: {
    fontFamily: font.mono,
    fontSize: fontSize.micro,
    fontWeight: fontWeight.medium,
    lineHeight: leading.micro,
    letterSpacing: tracking.micro,
  },
  code: {
    fontFamily: font.mono,
    fontSize: fontSize.code,
    fontWeight: fontWeight.regular,
    lineHeight: leading.code,
    letterSpacing: tracking.normal,
  },

  /* ----- Editorial voice (serif) ----- */
  prose: {
    fontFamily: font.serif,
    fontSize: fontSize.bodyLg,
    fontWeight: fontWeight.regular,
    lineHeight: leading.bodyLg,
    letterSpacing: tracking.normal,
    textWrap: "pretty",
  },

  /* The italic swap — the system's one flourish.
   * Wrap one or two load-bearing words INSIDE a display/heading.
   * One per screen. Never in chrome, never in body copy. */
  swap: {
    fontFamily: font.serif,
    fontStyle: "italic",
    fontWeight: fontWeight.regular,
    fontSize: "1.02em", // optical match against the sans
    letterSpacing: tracking.normal,
  },

  /* ----- Tones (compose with a role) ----- */
  muted: { color: color.inkMuted },
  subtle: { color: color.inkSubtle }, // captions/icons/large text only — not body on canvas
  strong: { fontWeight: fontWeight.strong }, // inline emphasis: 550, never 700
  danger: { color: color.dangerText },
  warning: { color: color.warningText },
  success: { color: color.successText },
  signal: { color: color.signalText },
  accent: { color: color.accentText },

  /* ----- Numerals ----- */
  numeral: { fontVariantNumeric: "tabular-nums" },
  /* Muted decimals: <span {...props(text.numeralUnit)}>.50 USD</span>
   * inside a numeral — magnitude first, precision on request. */
  numeralUnit: {
    color: color.inkSubtle,
    fontSize: "0.6em",
    fontWeight: fontWeight.regular,
    letterSpacing: tracking.normal,
  },

  /* ----- Line behavior ----- */
  truncate: {
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },

  /* Links: ink with a gray underline that darkens on hover.
   * Navigation, not alarm — the signal's jobs are focus and info only. */
  link: {
    color: color.ink,
    textDecorationLine: "underline",
    textDecorationColor: {
      default: color.linkUnderline,
      ":hover": color.linkUnderlineHover,
    },
    textDecorationThickness: "1px",
    textUnderlineOffset: "0.18em",
  },
});
