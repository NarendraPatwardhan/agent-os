/**
 * motion.js — entrances, exits, transitions.
 *
 * The asymmetry law: enters may announce (translate + blur + fade,
 * outQuint, staggered 60–80ms per chunk); exits whisper (opacity + blur
 * only, faster). The frequency budget: menus, dropdowns, tooltips get NO
 * entrance — at most enterInstant.
 *
 * Interaction states use the transition presets (interruptible).
 * Keyframes here are for ONE-SHOT entrances only.
 *
 * Reduced motion: durations collapse at the token level (motion.stylex.js);
 * animation durations here use the same vars, so everything honors it.
 */
import * as stylex from '@stylexjs/stylex';
import { duration, easing } from './tokens/motion.stylex.js';

const enterUp = stylex.keyframes({
  from: { opacity: 0, transform: 'translateY(8px)', filter: 'blur(8px)' },
  to: { opacity: 1, transform: 'translateY(0)', filter: 'blur(0)' },
});

const enterFade = stylex.keyframes({
  from: { opacity: 0 },
  to: { opacity: 1 },
});

const exitFade = stylex.keyframes({
  from: { opacity: 1, filter: 'blur(0)' },
  to: { opacity: 0, filter: 'blur(4px)' },
});

export const motion = stylex.create({
  /* The canonical enter: content chunks (title / body / actions) each get
   * this, staggered with motion.delay(`${i * 80}ms`). */
  enter: {
    animationName: enterUp,
    animationDuration: duration.slow,
    animationTimingFunction: easing.outQuint,
    animationFillMode: 'backwards',
  },
  /* For frequent chrome (frequency budget): opacity only, fast. */
  enterInstant: {
    animationName: enterFade,
    animationDuration: duration.fast,
    animationTimingFunction: easing.out,
    animationFillMode: 'backwards',
  },
  /* Exits whisper: opacity + blur, no positional movement, faster than
   * the enter. (Apply while unmounting via your framework's exit hook.) */
  exit: {
    animationName: exitFade,
    animationDuration: duration.fast,
    animationTimingFunction: easing.out,
    animationFillMode: 'forwards',
  },
  delay: (d) => ({
    animationDelay: d,
  }),

  /* ----- Fluid recipes — "one continuous object" -----
   * When a state change moves attention WITHIN a component (tab → tab,
   * item → item, collapsed → expanded), render it as one persistent
   * element changing geometry — never unmount + remount. Cross-fades are
   * for content INSIDE the moving container, and they trail it. */

  /* A shared indicator (pill/underline) that slides and stretches between
   * items. Position it absolutely and drive translate/width (or
   * translate/height) from measured geometry — the tabs underline is the
   * reference implementation. */
  indicator: {
    position: 'absolute',
    transitionProperty: 'translate, width, height',
    transitionDuration: duration.base,
    transitionTimingFunction: easing.outQuint,
    pointerEvents: 'none',
  },
  /* Container size-morph: height/width interpolate as content changes.
   * interpolate-size lets `auto` participate in the transition on
   * supporting engines; elsewhere the transition simply doesn't run
   * (graceful, never broken). */
  morph: {
    interpolateSize: 'allow-keywords',
    transitionProperty: 'height, width',
    transitionDuration: duration.slow,
    transitionTimingFunction: easing.outQuint,
    overflow: 'hidden',
  },
  /* Content inside a morphing container: fades/settles AFTER the
   * container has begun moving (container leads, content follows). */
  followThrough: {
    transitionProperty: 'opacity, translate, filter',
    transitionDuration: duration.base,
    transitionTimingFunction: easing.out,
    transitionDelay: '60ms',
  },
  /* The veil arrival: blur + scrim animate on the layer BEHIND an
   * arriving surface (dialogs, sheets, side panels). Pair with a
   * [data-starting-style] / open-state condition that moves
   * backdrop-filter from blur(0) to the target. Enter only — exits
   * whisper (opacity), and frequent chrome gets none of this. */
  veil: {
    transitionProperty: 'backdrop-filter, background-color, opacity',
    transitionDuration: duration.slow,
    transitionTimingFunction: easing.outQuint,
  },

  /* ----- Transition presets (interruptible interaction motion) ----- */
  colors: {
    transitionProperty: 'background-color, border-color, color, fill, stroke',
    transitionDuration: duration.fast,
    transitionTimingFunction: easing.out,
  },
  surface: {
    transitionProperty: 'box-shadow, transform, opacity',
    transitionDuration: duration.base,
    transitionTimingFunction: easing.out,
  },
  panel: {
    transitionProperty: 'transform, opacity, width, height',
    transitionDuration: duration.slow,
    transitionTimingFunction: easing.outQuint,
  },
});
