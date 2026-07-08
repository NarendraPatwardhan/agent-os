/**
 * layout.js — the four arrangement primitives + containers.
 *
 * Parents own spacing via gap; children never push with margins. Gaps come
 * from the space scale:
 *   <div {...stylex.props(layout.stack(space.s4))}>
 *
 * App code MAY write its own layout-shaped stylex.create (grid areas,
 * flex arrangements, widths) — with token values only. Anything visual
 * (color, shadow, border, type, radius, motion) comes from recipes.
 */
import * as stylex from '@stylexjs/stylex';
import { space } from './tokens/space.stylex.js';
import { container } from './tokens/size.stylex.js';
import { layer } from './tokens/layer.stylex.js';
import { media } from './tokens/media.stylex.js';

export const layout = stylex.create({
  /* ----- Arrangement (gap from the space scale) ----- */
  stack: (gap) => ({
    display: 'flex',
    flexDirection: 'column',
    gap,
  }),
  row: (gap) => ({
    display: 'flex',
    alignItems: 'center',
    gap,
  }),
  rowWrap: (gap) => ({
    display: 'flex',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap,
  }),
  split: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.s4,
  },
  gridAuto: (min, gap) => ({
    display: 'grid',
    gridTemplateColumns: `repeat(auto-fit, minmax(min(${min}, 100%), 1fr))`,
    gap,
  }),

  /* ----- Page + measure containers ----- */
  page: {
    minHeight: '100dvh',
    paddingBlock: { default: space.s8, [media.mobile]: space.s6 },
    paddingInline: {
      default: space.s8,
      [media.tablet]: space.s6,
      [media.mobile]: space.s4,
    },
  },
  container: {
    width: '100%',
    maxWidth: container.page,
    marginInline: 'auto',
  },
  content: {
    width: '100%',
    maxWidth: container.content,
    marginInline: 'auto',
  },
  reading: {
    width: '100%',
    maxWidth: container.reading,
    marginInline: 'auto',
  },

  /* ----- Scroll + sticky chrome ----- */
  scroll: {
    overflow: 'auto',
    scrollbarGutter: 'stable',
  },
  stickyTop: {
    position: 'sticky',
    top: 0,
    zIndex: layer.sticky,
  },

  /* Container-query root: component layout responds to the box it lives
   * in, not the viewport. App layout styles then use @container. */
  cq: {
    containerType: 'inline-size',
  },

  /* ----- A11y ----- */
  srOnly: {
    position: 'absolute',
    width: '1px',
    height: '1px',
    padding: 0,
    margin: '-1px',
    overflow: 'hidden',
    clipPath: 'inset(50%)',
    whiteSpace: 'nowrap',
    borderWidth: 0,
  },
});
