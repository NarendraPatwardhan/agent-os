/**
 * space.stylex.js — the 4px quantum.
 *
 * Every gap and padding is one of these. Tight inside a group (s1–s2),
 * standard between siblings (s3–s4), generous between sections (s8+).
 * Raw px in product code is legal only for hairlines, icon internals,
 * and canvas geometry. Parents own spacing via gap — there is no margin
 * vocabulary in this system on purpose.
 */
import * as stylex from '@stylexjs/stylex';

export const space = stylex.defineConsts({
  s0: '0px',
  s1: '4px',
  s2: '8px',
  s3: '12px',
  s4: '16px',
  s5: '20px',
  s6: '24px',
  s8: '32px',
  s10: '40px',
  s12: '48px',
  s16: '64px',
  s20: '80px',
  s24: '96px',
});
