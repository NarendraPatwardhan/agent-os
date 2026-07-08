import { useEffect, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { setArtifactSources } from "@mc/elements";
import { text } from "instrument";
import { MarkerToc } from "./MarkerToc";
import { chapters } from "./examples/chapters";
import { styles } from "./examples/styles";
import { ExampleDriver } from "./examples/drivers";
import type { Chapter } from "./examples/types";

// Register the kernel + each shipped flavor tar as a logical image name. Examples pass
// image="loom" etc.; the browser boot fetches /mc/<flavor>.tar per-instance (cached
// per-URL), so flavors never leak across terminals. loom aliases the hero's image.tar
// so the "Boot a VM" tab reuses the hero's already-warm fetch instead of re-downloading.
setArtifactSources({
  kernel: "/mc/kernel.wasm",
  images: {
    minimal: "/mc/minimal.tar",
    posix: "/mc/posix.tar",
    loom: "/mc/image.tar",
    atlas: "/mc/atlas.tar",
    paper: "/mc/paper.tar",
  },
});

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
  const examples = chapter.examples;
  const [exampleId, setExampleId] = useState<string | null>(null);
  // The clicked example if it belongs to this chapter, else the first — so switching
  // chapters resets to the first example automatically.
  const activeId = examples.find((e) => e.id === exampleId)?.id ?? examples[0]?.id ?? null;
  const active = examples.find((e) => e.id === activeId) ?? examples[0] ?? null;
  // One fresh, off-by-default VM per example — keying the driver by this remounts it
  // (disposing the old VM) on every chapter or example switch.
  const unitKey = `${chapter.id}::${activeId ?? "solo"}`;

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

          {/* Work row — a 2×2 grid: example tabs in row 1 over the content column, the
              driver's content + terminal in row 2 (aligned tops). */}
          <div {...stylex.props(styles.workRow)}>
            {examples.length >= 2 ? (
              <div {...stylex.props(styles.pillRow)} role="tablist" aria-label="Examples">
                {examples.map((ex) => (
                  <button
                    key={ex.id}
                    type="button"
                    role="tab"
                    aria-selected={ex.id === activeId}
                    onClick={() => setExampleId(ex.id)}
                    {...stylex.props(styles.pill, ex.id === activeId && styles.pillActive)}
                  >
                    {ex.label}
                  </button>
                ))}
              </div>
            ) : null}
            {active ? <ExampleDriver key={unitKey} example={active} /> : null}
          </div>
        </div>
      </div>
    </section>
  );
}
