/**
 * controls.js — interactive recipes.
 *
 * Every state is designed here: hover, active, focus, disabled, invalid,
 * selected, loading. If a state you need is missing, extend THIS file —
 * never patch at a call site.
 *
 * Composition is ordered, last wins:
 *   stylex.props(controls.button, controls.buttonGhost, controls.buttonSm)
 *
 * Focus is :focus-visible + outline only. Disabled is explicit muted
 * color, never opacity.
 */
import * as stylex from "@stylexjs/stylex";
import { color } from "./tokens/color.stylex.js";
import { font, fontSize, fontWeight, tracking } from "./tokens/type.stylex.js";
import { space } from "./tokens/space.stylex.js";
import { size } from "./tokens/size.stylex.js";
import { radius } from "./tokens/radius.stylex.js";
import { duration, easing } from "./tokens/motion.stylex.js";
import { media } from "./tokens/media.stylex.js";

/* Skeleton sweep lives here because keyframes cannot cross files. */
const sweep = stylex.keyframes({
  from: { transform: "translateX(-100%)" },
  to: { transform: "translateX(100%)" },
});

export const controls = stylex.create({
  /* --------------------------------------------------------------------
   * BUTTON — base is the solid (accent-slot) variant. Inside an accent
   * theme scope it recolors with zero extra markup.
   * ------------------------------------------------------------------ */
  button: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.s2,
    height: size.controlMd,
    minHeight: { default: null, [media.pointerCoarse]: "44px" },
    paddingInline: space.s4,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: "transparent",
    borderRadius: radius.control,
    backgroundColor: {
      default: color.accent,
      ":hover": color.accentHover,
      ":disabled": color.bgSunken,
    },
    color: {
      default: color.accentContrast,
      ":disabled": color.inkDisabled,
    },
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.medium,
    letterSpacing: tracking.ui,
    lineHeight: "1",
    whiteSpace: "nowrap",
    textDecorationLine: "none",
    cursor: { default: "pointer", ":disabled": "not-allowed" },
    userSelect: "none",
    transitionProperty: "background-color, border-color, color, transform",
    transitionDuration: duration.fast,
    transitionTimingFunction: easing.out,
    transform: { default: null, ":active": "translateY(0.5px)" },
    pointerEvents: { default: null, ":disabled": "none" },
    outlineWidth: { default: null, ":focus-visible": "2px" },
    outlineStyle: { default: null, ":focus-visible": "solid" },
    outlineColor: { default: null, ":focus-visible": color.signal },
    outlineOffset: { default: null, ":focus-visible": "2px" },
  },
  buttonGhost: {
    backgroundColor: {
      default: "transparent",
      ":hover": "color-mix(in oklab, currentColor 6%, transparent)",
      ":disabled": "transparent",
    },
    color: { default: color.ink, ":disabled": color.inkDisabled },
    borderColor: {
      default: color.borderStrong,
      ":hover": color.borderHover,
      ":disabled": color.border,
    },
  },
  buttonQuiet: {
    backgroundColor: {
      default: "transparent",
      ":hover": "color-mix(in oklab, currentColor 8%, transparent)",
      ":disabled": "transparent",
    },
    color: {
      default: color.inkMuted,
      ":hover": color.ink,
      ":disabled": color.inkDisabled,
    },
    borderColor: "transparent",
  },
  buttonDanger: {
    backgroundColor: {
      default: color.dangerBase,
      ":hover": color.dangerHover,
      ":disabled": color.bgSunken,
    },
    color: { default: color.dangerContrast, ":disabled": color.inkDisabled },
  },
  buttonSm: {
    height: size.controlSm,
    paddingInline: space.s3,
    fontSize: fontSize.label,
  },
  buttonLg: {
    height: size.controlLg,
    paddingInline: space.s5,
    fontSize: fontSize.bodyLg,
  },
  /* Square icon button — REQUIRES aria-label. */
  buttonIcon: {
    aspectRatio: "1",
    paddingInline: 0,
    minWidth: { default: null, [media.pointerCoarse]: "44px" },
  },

  /* --------------------------------------------------------------------
   * FIELD — input / select / textarea shared treatment.
   * Invalid state responds to [data-invalid] (Base UI's convention) and
   * swaps the border AND the focus-ring hue — the one place the ring
   * leaves signal blue. For non-Base-UI markup, apply fieldInvalid.
   * ------------------------------------------------------------------ */
  field: {
    display: "block",
    width: "100%",
    height: size.controlMd,
    minHeight: { default: null, [media.pointerCoarse]: "44px" },
    paddingInline: space.s3,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: {
      default: color.borderStrong,
      ":hover": color.borderHover,
      ":disabled": color.border,
      "[data-invalid]": color.dangerBorder,
    },
    borderRadius: radius.control,
    backgroundColor: { default: color.bgPanel, ":disabled": color.bgSunken },
    color: { default: color.ink, ":disabled": color.inkDisabled },
    fontFamily: font.sans,
    fontSize: fontSize.body,
    letterSpacing: tracking.ui,
    transitionProperty: "border-color",
    transitionDuration: duration.fast,
    transitionTimingFunction: easing.out,
    "::placeholder": { color: color.inkSubtle },
    outlineWidth: { default: null, ":focus-visible": "2px" },
    outlineStyle: { default: null, ":focus-visible": "solid" },
    outlineColor: {
      default: null,
      ":focus-visible": color.signal,
      "[data-invalid]:focus-visible": color.dangerBase,
    },
    outlineOffset: { default: null, ":focus-visible": "2px" },
  },
  fieldMultiline: {
    height: "auto",
    minHeight: size.controlLg,
    paddingBlock: space.s2,
    resize: "vertical",
  },
  fieldInvalid: {
    borderColor: { default: color.dangerBorder, ":hover": color.dangerBorder },
    outlineColor: { default: null, ":focus-visible": color.dangerBase },
  },

  /* --------------------------------------------------------------------
   * INTERACTIVE — rows, list items, tree nodes: hover/active/selected as
   * one behavior. The hover tint is translucent currentColor, so it works
   * on ANY surface without knowing its substrate. Selection is FROST —
   * a translucent ink-lift, no hue (the signal points, it does not
   * select) — applied by the APP as state:
   *   stylex.props(controls.interactive, isSelected && controls.interactiveSelected)
   * ------------------------------------------------------------------ */
  interactive: {
    borderRadius: radius.control,
    cursor: "pointer",
    backgroundColor: {
      default: "transparent",
      ":hover": "color-mix(in oklab, currentColor 7%, transparent)",
      ":active": "color-mix(in oklab, currentColor 12%, transparent)",
    },
    transitionProperty: "background-color, color",
    transitionDuration: duration.fast,
    transitionTimingFunction: easing.out,
    outlineWidth: { default: null, ":focus-visible": "2px" },
    outlineStyle: { default: null, ":focus-visible": "solid" },
    outlineColor: { default: null, ":focus-visible": color.signal },
    outlineOffset: { default: null, ":focus-visible": "-2px" },
  },
  interactiveSelected: {
    backgroundColor: {
      default: color.frost,
      ":hover": color.frostHover,
      ":active": color.frostHover,
    },
    color: color.ink,
  },
  interactiveDisabled: {
    color: color.inkDisabled,
    backgroundColor: "transparent",
    pointerEvents: "none",
  },

  /* --------------------------------------------------------------------
   * BADGE — pill shape in the metadata voice. Compose with a status:
   *   stylex.props(controls.badge, controls.statusSuccess)
   * ------------------------------------------------------------------ */
  badge: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.s1,
    paddingInline: space.s2,
    paddingBlock: "3px",
    borderRadius: radius.pill,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.border,
    fontFamily: font.mono,
    fontSize: fontSize.caption,
    fontWeight: fontWeight.medium,
    lineHeight: "1",
    letterSpacing: tracking.eyebrow,
    textTransform: "uppercase",
    whiteSpace: "nowrap",
    fontVariantNumeric: "tabular-nums",
  },

  /* Status treatments — soft bg + matching text + matching border as ONE
   * decision, so dangerSoft can never pair with successText. */
  statusInfo: {
    backgroundColor: color.signalSoft,
    color: color.signalText,
    borderColor: color.signalBorder,
  },
  statusDanger: {
    backgroundColor: color.dangerSoft,
    color: color.dangerText,
    borderColor: color.dangerBorder,
  },
  statusWarning: {
    backgroundColor: color.warningSoft,
    color: color.warningText,
    borderColor: color.warningBorder,
  },
  statusSuccess: {
    backgroundColor: color.successSoft,
    color: color.successText,
    borderColor: color.successBorder,
  },
  /* Solid variants — short, loud, rare. */
  statusDangerSolid: {
    backgroundColor: color.dangerBase,
    color: color.dangerContrast,
    borderColor: "transparent",
  },
  statusSuccessSolid: {
    backgroundColor: color.successBase,
    color: color.successContrast,
    borderColor: "transparent",
  },

  /* --------------------------------------------------------------------
   * KBD — keyboard hint chip. Honest ornament.
   * ------------------------------------------------------------------ */
  kbd: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    minWidth: "20px",
    minHeight: "20px",
    paddingInline: "5px",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.border,
    borderRadius: radius.r1,
    backgroundColor: color.bgSunken,
    color: color.inkMuted,
    fontFamily: font.mono,
    fontSize: fontSize.caption,
    fontWeight: fontWeight.medium,
    lineHeight: "1",
  },

  /* --------------------------------------------------------------------
   * SKELETON — loading placeholder. Size it (or apply to the real element
   * and hide content). Sweep collapses under reduced motion.
   * ------------------------------------------------------------------ */
  skeleton: {
    position: "relative",
    overflow: "hidden",
    backgroundColor: color.bgSunken,
    borderRadius: radius.chip,
    color: "transparent",
    userSelect: "none",
    pointerEvents: "none",
    "::after": {
      content: '""',
      position: "absolute",
      top: 0,
      right: 0,
      bottom: 0,
      left: 0,
      transform: "translateX(-100%)",
      backgroundImage:
        "linear-gradient(90deg, transparent, light-dark(oklch(1 0 0 / 0.6), oklch(1 0 0 / 0.06)), transparent)",
      animationName: sweep,
      animationDuration: "1.4s",
      animationTimingFunction: easing.out,
      animationIterationCount: "infinite",
    },
  },
  skeletonStill: {
    /* Compose after skeleton under prefers-reduced-motion contexts that
     * the app manages, or for static placeholders. */
    "::after": { animationName: "none" },
  },

  /* --------------------------------------------------------------------
   * LINK — ink with a gray underline that darkens on hover. A link
   * is navigation, not an alarm; the page's only always-on hue is gone.
   * ------------------------------------------------------------------ */
  link: {
    color: color.ink,
    textDecorationLine: "underline",
    textDecorationColor: {
      default: color.linkUnderline,
      ":hover": color.linkUnderlineHover,
    },
    textDecorationThickness: "1px",
    textUnderlineOffset: "0.15em",
    transitionProperty: "text-decoration-color",
    transitionDuration: duration.fast,
    transitionTimingFunction: easing.out,
    outlineWidth: { default: null, ":focus-visible": "2px" },
    outlineStyle: { default: null, ":focus-visible": "solid" },
    outlineColor: { default: null, ":focus-visible": color.signal },
    outlineOffset: { default: null, ":focus-visible": "2px" },
  },

  /* Reusable focus ring for custom interactive elements not covered by a
   * recipe above (e.g. a canvas node). Same channel, same hue. */
  focusRing: {
    outlineWidth: { default: null, ":focus-visible": "2px" },
    outlineStyle: { default: null, ":focus-visible": "solid" },
    outlineColor: { default: null, ":focus-visible": color.signal },
    outlineOffset: { default: null, ":focus-visible": "2px" },
  },
});
