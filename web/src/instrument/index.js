/**
 * Instrument — design tokens and recipes (StyleX).
 *
 * This entry re-exports RECIPES and THEMES only. Tokens must be imported
 * from their defining files (a StyleX rule — no var barrels):
 *
 *   import { text, surface, layout, controls, motion } from 'instrument';
 *   import { scheme, accentBrand, densityCompact } from 'instrument';
 *   import { space } from 'instrument/tokens/space.stylex';
 *   import { color } from 'instrument/tokens/color.stylex';
 *
 * Also import 'instrument/reset.css' once, at the app root.
 */
export { text } from './text.js';
export { layout } from './layout.js';
export { surface } from './surface.js';
export { controls } from './controls.js';
export { motion } from './motion.js';
export {
  scheme,
  accentBrand,
  accentSignal,
  accentDanger,
  accentSuccess,
  densityCompact,
  densityComfortable,
} from './themes.js';
