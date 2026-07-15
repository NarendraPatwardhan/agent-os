import { useEffect, useLayoutEffect, useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { setArtifactSources } from "@mc/elements";
import { motion, text } from "instrument";
import { MarkerToc } from "./MarkerToc";
import { Icon } from "./Icon";
import { chapters } from "./examples/chapters";
import { styles } from "./examples/styles";
import { ExampleDriver } from "./examples/drivers";
import type { Chapter, Example, IconId } from "./examples/types";

// Register the kernel + each shipped flavor tar as a logical image name. Examples pass
// image="loom" etc.; the browser boot fetches /mc/<flavor>.tar per-instance (cached
// per-URL), so flavors never leak across terminals. loom aliases the hero's image.tar
// so the "Boot a VM" tab reuses the hero's already-warm fetch instead of re-downloading.
// The catalog compiler backs runtime vm.tool (the host-tool examples in chapter 3).
setArtifactSources({
  kernel: "/mc/kernel.wasm",
  images: {
    minimal: "/mc/minimal.tar",
    posix: "/mc/posix.tar",
    loom: "/mc/image.tar",
    atlas: "/mc/atlas.tar",
    paper: "/mc/paper.tar",
  },
  catalogCompiler: "/mc/catalog-compiler.wasm",
});

const FALLBACK = chapters[0];

// Logo assignments copied from the preserved pre-reset showcase. Only its icon
// vocabulary/associations are reused; none of its components or examples are.
const ICON_BY_ID: Readonly<Record<string, IconId>> = {
  "boot-a-vm": "terminal",
  remote: "key",
  images: "tar",
  pipelines: "terminal",
  "vm-fs": "file",
  "vm-shell": "terminal",
  determinism: "cron",
  "vm-luau": "luau",
  sessions: "luau",
  analyze: "luau",
  sys: "terminal",
  "require-tools": "tools",
  "vm-tool": "tools",
  kits: "tools",
  "tool-doc": "docx",
  xlsx: "xlsx",
  docx: "docx",
  pptx: "pptx",
  "typst-pdf": "pdf",
  diagnostics: "pdf",
  sqlite: "sqlite",
  "vector-search": "vector",
  "data-pdf": "pdf",
  batteries: "luau",
  "cli-twins": "terminal",
  "the-model": "tools",
  "mc-use": "github",
  "from-the-shell": "terminal",
  envelope: "tools",
  github: "github",
  "ms-graph": "microsoft",
  google: "google",
  graphql: "graphql",
  "remote-mcp": "mcp",
  "any-api": "globe",
  registry: "tools",
  capstone: "stripe",
  "host-dir": "mount",
  s3: "mount",
  "rag-mount": "vector",
  "custom-driver": "mount",
  "mount-vs-connection": "tools",
  snapshot: "snapshot",
  fork: "fork",
  layers: "tar",
  "custom-flavor": "tar",
  "restore-modes": "lock",
  record: "build",
  "llb-graph": "build",
  caching: "snapshot",
  tiers: "lock",
  permissions: "globe",
  approval: "lock",
  "secret-free": "key",
  audit: "tools",
  webhook: "globe",
  "queue-worker": "build",
  handoff: "snapshot",
  "vm-pool": "fork",
  cron: "cron",
  "web-components": "terminal",
};

const DEFAULT_ICON: Readonly<Record<Example["kind"], IconId>> = {
  program: "play",
  commands: "terminal",
  connect: "tools",
  flavors: "tar",
  remote: "key",
  files: "mount",
  s3: "mount",
  approval: "lock",
  prose: "file",
};

const iconFor = (example: Example): IconId => ICON_BY_ID[example.id] ?? DEFAULT_ICON[example.kind];

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
  const pillRow = useRef<HTMLDivElement>(null);
  const pillButtons = useRef(new Map<string, HTMLButtonElement>());
  const [indicator, setIndicator] = useState<{
    left: number;
    top: number;
    width: number;
    height: number;
  } | null>(null);
  // The clicked example if it belongs to this chapter, else the first — so switching
  // chapters resets to the first example automatically.
  const activeId = examples.find((e) => e.id === exampleId)?.id ?? examples[0]?.id ?? null;
  const active = examples.find((e) => e.id === activeId) ?? examples[0] ?? null;
  // One fresh, off-by-default VM per example — keying the driver by this remounts it
  // (disposing the old VM) on every chapter or example switch.
  const unitKey = `${chapter.id}::${activeId ?? "solo"}`;

  useLayoutEffect(() => {
    const row = pillRow.current;
    const button = activeId ? pillButtons.current.get(activeId) : undefined;
    if (!row || !button) {
      setIndicator(null);
      return undefined;
    }
    const measure = (): void => {
      setIndicator({
        left: button.offsetLeft,
        top: button.offsetTop,
        width: button.offsetWidth,
        height: button.offsetHeight,
      });
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(row);
    observer.observe(button);
    return () => observer.disconnect();
  }, [activeId, chapter.id]);

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
              <div
                ref={pillRow}
                {...stylex.props(styles.pillRow)}
                role="tablist"
                aria-label="Examples"
              >
                {indicator ? (
                  <span
                    aria-hidden="true"
                    {...stylex.props(styles.pillIndicator, motion.indicator)}
                    style={{
                      width: indicator.width,
                      height: indicator.height,
                      translate: `${indicator.left}px ${indicator.top}px`,
                    }}
                  />
                ) : null}
                {examples.map((ex) => (
                  <button
                    key={ex.id}
                    ref={(element) => {
                      if (element) pillButtons.current.set(ex.id, element);
                      else pillButtons.current.delete(ex.id);
                    }}
                    type="button"
                    role="tab"
                    aria-selected={ex.id === activeId}
                    onClick={() => setExampleId(ex.id)}
                    {...stylex.props(
                      styles.pill,
                      motion.colors,
                      ex.id === activeId && styles.pillActive,
                    )}
                  >
                    <Icon id={iconFor(ex)} size={16} />
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
