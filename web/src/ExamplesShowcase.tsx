import { useEffect, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { setArtifactSources } from "@mc/elements";
import { text } from "instrument";
import { color } from "instrument/tokens/color.stylex.js";
import { space } from "instrument/tokens/space.stylex.js";
import { radius } from "instrument/tokens/radius.stylex.js";
import { MarkerToc } from "./MarkerToc";
import { chapters } from "./examples/chapters";
import type { Chapter } from "./examples/types";

// The examples terminal boots the staged browser artifacts, same as the hero.
setArtifactSources({ kernel: "/mc/kernel.wasm", image: "/mc/image.tar" });

const FALLBACK = chapters[0];

function readId(): string {
  if (typeof window === "undefined") return FALLBACK.id;
  return window.location.hash.replace(/^#/, "") || FALLBACK.id;
}

/** The URL hash picks a chapter — jump by #, no scrolling. */
function useHashChapter(): Chapter {
  const [id, setId] = useState<string>(readId);
  useEffect(() => {
    const onHash = (): void => setId(readId());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);
  return chapters.find((c) => c.id === id) ?? FALLBACK;
}

export function ExamplesShowcase() {
  const chapter = useHashChapter();
  const select = (id: string): void => {
    window.location.hash = id;
  };

  return (
    <section {...stylex.props(styles.area)} id="examples">
      <div {...stylex.props(styles.layout)}>
        <div {...stylex.props(styles.tocCol)}>
          <MarkerToc chapters={chapters} activeId={chapter.id} onSelect={select} />
        </div>

        <div {...stylex.props(styles.main)}>
          {/* Title + subtitle — no border, natural part of the surface */}
          <div {...stylex.props(styles.titleBlock)}>
            <span {...stylex.props(styles.eyebrow, text.eyebrow)}>Chapter {chapter.num}</span>
            <h2 {...stylex.props(styles.title, text.display)}>{chapter.title}</h2>
            <p {...stylex.props(styles.subtitle, text.bodyLg, text.muted)}>{chapter.tagline}</p>
          </div>

          {/* Work row: content explanation (left) · terminal + actions (right) */}
          <div {...stylex.props(styles.workRow)}>
            <div {...stylex.props(styles.content)} />
            <div {...stylex.props(styles.termCol)}>
              <TerminalPanel />
              <div {...stylex.props(styles.actions)} />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function TerminalPanel() {
  const [booted, setBooted] = useState(false);
  return (
    <div {...stylex.props(styles.terminalBox)}>
      {booted ? (
        <mc-terminal {...stylex.props(styles.terminal)} label="agent · live in your browser" net cursor="block" line-height={1.5} />
      ) : (
        <button
          type="button"
          {...stylex.props(styles.runButton)}
          onClick={() => setBooted(true)}
          aria-label="Boot the VM"
        >
          <svg width="30" height="30" viewBox="0 0 20 20" aria-hidden="true">
            <path d="M6 3.5v13l10.5-6.5z" fill="#3fcf6f" />
          </svg>
        </button>
      )}
    </div>
  );
}

const styles = stylex.create({
  area: {
    width: "100%",
    // Clip the long scale ticks at the left edge — only their convex right-ends show.
    overflowX: "hidden",
    paddingTop: "clamp(28px, 3vw, 48px)",
    paddingBottom: "clamp(48px, 8vw, 96px)",
    // Left-aligned: the rail hugs the left; ticks extend past the edge and clip.
    paddingLeft: "clamp(56px, 5vw, 72px)",
    paddingRight: "clamp(24px, 4vw, 80px)",
    borderTopWidth: "1px",
    borderTopStyle: "solid",
    borderTopColor: color.border,
  },
  // Left-aligned grid: wide rail (fits the longest chapter title) then the main
  // block right after — no empty centered gutter, so the content sits close in.
  layout: {
    maxWidth: "1560px",
    display: "grid",
    // Tighter rail column + gap so the main block (title + content) sits further left.
    gridTemplateColumns: "380px minmax(0, 1fr)",
    gap: "clamp(24px, 2.2vw, 40px)",
    alignItems: "start",
  },
  // TOC vertically centered against the main block (the wireframe).
  tocCol: { alignSelf: "center" },

  // main pane — no top offset, sits high next to the scale
  main: { minWidth: 0, display: "flex", flexDirection: "column", gap: space.s8 },

  titleBlock: { display: "flex", flexDirection: "column", gap: space.s3 },
  eyebrow: { color: color.inkSubtle },
  title: { margin: 0, fontSize: "clamp(28px, 24px + 1.4vw, 44px)" },
  subtitle: { maxWidth: "62ch" },

  workRow: {
    display: "grid",
    // Terminal is a fixed width (unchanged); the content box flexes, so the space
    // freed on the left goes to widening the content — not the terminal.
    gridTemplateColumns: {
      default: "minmax(0, 1fr) clamp(340px, 30vw, 460px)",
      "@media (max-width: 1024px)": "minmax(0, 1fr)",
    },
    gap: space.s6,
    alignItems: "start",
  },

  // content explanation — paper-thin border, scroll area, slick scrollbar (empty shell).
  // Taller than the terminal — the primary reading surface.
  content: {
    minWidth: 0,
    height: "clamp(420px, 46vw, 620px)",
    overflowY: "auto",
    padding: space.s5,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.border,
    borderRadius: radius.card,
    backgroundColor: color.bgPanel,
    scrollbarWidth: "thin",
    scrollbarColor: `${color.borderStrong} transparent`,
  },

  // terminal column
  termCol: { minWidth: 0, display: "flex", flexDirection: "column", gap: space.s3 },
  terminalBox: {
    width: "100%",
    height: "clamp(240px, 30vw, 360px)",
    borderRadius: radius.card,
    overflow: "hidden",
    display: "flex",
  },
  // No `display` here — <mc-terminal> is display:flex (column); a StyleX display
  // collapses that, unconstrains .screen, and xterm fits to a bogus size. Size only.
  terminal: { width: "100%", height: "100%" },
  runButton: {
    width: "100%",
    height: "100%",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.border,
    borderRadius: radius.card,
    backgroundColor: color.bgSunken,
    cursor: "pointer",
    opacity: { default: 0.85, ":hover": 1 },
    transform: { default: "scale(1)", ":hover": "scale(1.05)" },
    transitionProperty: "transform, opacity",
    transitionDuration: "150ms",
  },

  // optional exec/input area — dashed, empty for now
  actions: {
    height: "44px",
    borderWidth: "1px",
    borderStyle: "dashed",
    borderColor: color.border,
    borderRadius: radius.chip,
  },
});
