/**
 * surface.js — the surface ladder.
 *
 * The single source of background + border + shadow + radius, set
 * together so they cannot disagree. SURFACES ARE ATOMIC: an element with
 * a surface recipe never receives another background, border, or shadow.
 *
 * Levels are named jobs, not numbers. A popover is always surface.popover
 * no matter what it floats above; light-mode depth is hairline + shadow,
 * dark-mode depth is the lightness step baked into the bg tokens.
 */
import * as stylex from '@stylexjs/stylex';
import { color } from './tokens/color.stylex.js';
import { shadow } from './tokens/shadow.stylex.js';
import { radius } from './tokens/radius.stylex.js';
import { font, fontSize, fontWeight, leading, tracking } from './tokens/type.stylex.js';
import { layer } from './tokens/layer.stylex.js';

export const surface = stylex.create({
  /* App root: put this on <body> or your top-level element. Sets the
   * base register and lets light-dark() resolve (follow the OS; pin with
   * scheme.light/dark from themes.js). */
  root: {
    colorScheme: 'light dark',
    backgroundColor: color.bgCanvas,
    color: color.ink,
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.regular,
    lineHeight: leading.body,
    letterSpacing: tracking.ui,
    WebkitFontSmoothing: 'antialiased',
    MozOsxFontSmoothing: 'grayscale',
  },

  /* ----- The ladder ----- */
  canvas: {
    backgroundColor: color.bgCanvas,
    color: color.ink,
  },
  sunken: {
    backgroundColor: color.bgSunken,
    borderRadius: radius.control,
    color: color.ink,
  },
  panel: {
    /* Structural chrome — sidebars, headers, rails. Hairline, no shadow,
     * no radius: panels are architecture, not objects. */
    backgroundColor: color.bgPanel,
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: color.border,
    color: color.ink,
  },
  card: {
    backgroundColor: color.bgCard,
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: color.border,
    boxShadow: shadow.rest,
    borderRadius: radius.card,
    color: color.ink,
  },
  /* popover/modal/toast render in portals OUTSIDE the app root, so each
   * carries the base type register itself — a popup must never inherit
   * the UA's serif (surfaces are atomic). */
  popover: {
    backgroundColor: color.bgPopover,
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: color.border,
    boxShadow: shadow.overlay,
    borderRadius: radius.card,
    color: color.ink,
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.regular,
    lineHeight: leading.body,
    letterSpacing: tracking.ui,
  },
  modal: {
    backgroundColor: color.bgModal,
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: color.border,
    boxShadow: shadow.modal,
    borderRadius: radius.modal,
    color: color.ink,
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.regular,
    lineHeight: leading.body,
    letterSpacing: tracking.ui,
  },
  toast: {
    backgroundColor: color.bgToast,
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: color.border,
    boxShadow: shadow.toast,
    borderRadius: radius.card,
    color: color.ink,
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.regular,
    lineHeight: leading.body,
    letterSpacing: tracking.ui,
  },

  /* ----- The veil register -----
   * Translucent, backdrop-blurred, borderless. For chrome that FLOATS —
   * rails, menus, dialogs, HUD chips — where content can scroll or live
   * beneath. Frost is earned by float: anything in flow stays on the
   * opaque ladder. Edges come from the inner top-highlight plus the
   * backdrop discontinuity; forced-colors reinstates a real border.
   * Portaled veils (veilRaised/veilDeep) carry the type register, same
   * as popover/modal above. */
  veil: {
    backgroundColor: {
      default: color.bgVeil,
      '@media (forced-colors: active)': 'Canvas',
    },
    backdropFilter: 'blur(20px) saturate(1.1)',
    boxShadow: `inset 0 1px 0 ${color.veilHighlight}`,
    borderWidth: { default: null, '@media (forced-colors: active)': '1px' },
    borderStyle: { default: null, '@media (forced-colors: active)': 'solid' },
    borderColor: { default: null, '@media (forced-colors: active)': 'CanvasText' },
    borderRadius: radius.modal,
    color: color.ink,
  },
  veilRaised: {
    backgroundColor: {
      default: color.bgVeilRaised,
      '@media (forced-colors: active)': 'Canvas',
    },
    backdropFilter: 'blur(28px) saturate(1.1)',
    boxShadow: `inset 0 1px 0 ${color.veilHighlight}, ${shadow.overlay}`,
    borderWidth: { default: null, '@media (forced-colors: active)': '1px' },
    borderStyle: { default: null, '@media (forced-colors: active)': 'solid' },
    borderColor: { default: null, '@media (forced-colors: active)': 'CanvasText' },
    borderRadius: radius.card,
    color: color.ink,
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.regular,
    lineHeight: leading.body,
    letterSpacing: tracking.ui,
  },
  veilDeep: {
    backgroundColor: {
      default: color.bgVeilDeep,
      '@media (forced-colors: active)': 'Canvas',
    },
    backdropFilter: 'blur(36px) saturate(1.1)',
    boxShadow: `inset 0 1px 0 ${color.veilHighlight}, ${shadow.modal}`,
    borderWidth: { default: null, '@media (forced-colors: active)': '1px' },
    borderStyle: { default: null, '@media (forced-colors: active)': 'solid' },
    borderColor: { default: null, '@media (forced-colors: active)': 'CanvasText' },
    borderRadius: radius.modal,
    color: color.ink,
    fontFamily: font.sans,
    fontSize: fontSize.body,
    fontWeight: fontWeight.regular,
    lineHeight: leading.body,
    letterSpacing: tracking.ui,
  },
  /* Performance/frozen state: compose AFTER a veil while the canvas pans
   * (is-panning) or wherever backdrop sampling is too expensive — swaps
   * glass for its opaque stand-in. */
  veilFrozen: {
    backdropFilter: 'none',
    backgroundColor: color.bgVeilOpaque,
  },

  /* ----- Diffused boundary -----
   * A region of attention without an enclosure: a chat column over a
   * canvas, an inspector rail. The veil fades to nothing across its
   * leading edge via mask — never a hairline box. Hairlines are for
   * structure; diffusion is for regions. */
  diffuse: {
    backgroundColor: color.bgVeil,
    backdropFilter: 'blur(20px) saturate(1.1)',
    maskImage:
      'linear-gradient(to right, transparent 0, black 64px, black 100%)',
  },
  diffuseLeft: {
    maskImage:
      'linear-gradient(to left, transparent 0, black 64px, black 100%)',
  },
  diffuseTop: {
    maskImage:
      'linear-gradient(to bottom, transparent 0, black 48px, black 100%)',
  },

  /* ----- Edges and rules ----- */
  /* 0.5px divider — a true hairline on modern displays; the cheapest
   * "this was designed" tell in the system. */
  divider: {
    borderTopWidth: '0.5px',
    borderTopStyle: 'solid',
    borderTopColor: color.border,
  },

  /* ----- Sanctioned texture: the dot grid -----
   * Graph paper for canvases, empty states, workflow areas. The dot color
   * mirrors the `border` token (kept literal: gradients can't consume a
   * var without runtime cost). There is no other texture — no grain PNGs,
   * no glassmorphism. */
  dotGrid: {
    backgroundImage:
      'radial-gradient(circle, light-dark(oklch(0.91 0 0), oklch(0.30 0 0)) 1px, transparent 1px)',
    backgroundSize: '16px 16px',
  },
  /* Wide register for far zoom-out on canvases — same dots, 32px pitch. */
  dotGridWide: {
    backgroundSize: '32px 32px',
  },
  /* 45° hairline hatch for wells and drop zones. */
  hatch: {
    backgroundImage:
      'repeating-linear-gradient(45deg, light-dark(oklch(0.91 0 0 / 0.55), oklch(0.30 0 0 / 0.55)) 0 1px, transparent 1px 8px)',
  },
  /* Dashed seam — a 0.5px dashed rule marking a REAL layout boundary
   * (editorial/marketing surfaces only; product chrome uses divider). */
  seam: {
    borderTopWidth: '0.5px',
    borderTopStyle: 'dashed',
    borderTopColor: color.border,
  },

  /* ----- Scrims — for hand-portaled overlays only; native <dialog> gets
   * its scrim from ::backdrop in reset.css. ----- */
  scrim: {
    position: 'fixed',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    backgroundColor: color.scrim,
    zIndex: layer.drawer,
  },
  scrimStrong: {
    position: 'fixed',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    backgroundColor: color.scrimStrong,
    zIndex: layer.drawer,
  },
});
