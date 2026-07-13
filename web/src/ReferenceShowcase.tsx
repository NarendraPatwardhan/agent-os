import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { controls, text } from "instrument";
import { color } from "instrument/tokens/color.stylex.js";
import { media } from "instrument/tokens/media.stylex.js";
import { radius } from "instrument/tokens/radius.stylex.js";
import { space } from "instrument/tokens/space.stylex.js";

import { MarkdownArticle } from "./reference/Markdown";
import { referenceGroups, referencePage, referencePages } from "./reference/catalog";

type Route = Readonly<{ active: boolean; slug: string; anchor?: string }>;

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function readRoute(): Route {
  if (typeof window === "undefined") return { active: false, slug: "index" };
  const hash = window.location.hash.replace(/^#/, "");
  if (hash === "reference") return { active: true, slug: "index" };
  if (!hash.startsWith("reference/")) return { active: false, slug: "index" };
  const [rawSlug = "index", ...rawAnchor] = hash.slice("reference/".length).split("/");
  const slug = safeDecode(rawSlug);
  const anchor = rawAnchor.length ? safeDecode(rawAnchor.join("/")) : undefined;
  return { active: true, slug, anchor };
}

function referenceHash(slug: string, anchor?: string): string {
  return `#reference/${encodeURIComponent(slug)}${anchor ? `/${encodeURIComponent(anchor)}` : ""}`;
}

const styles = stylex.create({
  area: {
    width: "100%",
    minHeight: "100dvh",
    paddingBlock: "clamp(48px, 7vw, 96px)",
    paddingInline: { default: "clamp(32px, 5vw, 80px)", [media.tablet]: space.s6, [media.mobile]: space.s4 },
    borderTopWidth: "1px",
    borderTopStyle: "solid",
    borderTopColor: color.border,
    backgroundColor: color.bgCanvas,
  },
  layout: {
    width: "100%",
    maxWidth: "1440px",
    marginInline: "auto",
    display: "grid",
    gridTemplateColumns: { default: "280px minmax(0, 1fr)", [media.tablet]: "1fr", [media.mobile]: "1fr" },
    gap: { default: "clamp(48px, 6vw, 96px)", [media.tablet]: space.s6, [media.mobile]: space.s6 },
    alignItems: "start",
  },
  sidebar: {
    minWidth: 0,
    position: { default: "sticky", [media.tablet]: "static", [media.mobile]: "static" },
    top: space.s6,
    maxHeight: { default: "calc(100vh - 48px)", [media.tablet]: "none", [media.mobile]: "none" },
    display: "flex",
    flexDirection: "column",
    gap: space.s5,
  },
  navHeader: { display: "flex", flexDirection: "column", gap: space.s3 },
  navTitle: { display: "flex", alignItems: "baseline", justifyContent: "space-between", gap: space.s3 },
  count: { color: color.inkSubtle },
  search: { width: "100%", backgroundColor: color.bgPanel },
  mobileSelect: {
    display: { default: "none", [media.tablet]: "none", [media.mobile]: "block" },
    backgroundColor: color.bgPanel,
  },
  nav: {
    minHeight: 0,
    overflowY: { default: "auto", [media.tablet]: "visible", [media.mobile]: "visible" },
    overflowX: "hidden",
    paddingRight: { default: space.s2, [media.tablet]: 0, [media.mobile]: 0 },
    display: { default: "flex", [media.tablet]: "grid", [media.mobile]: "none" },
    gridTemplateColumns: { default: null, [media.tablet]: "repeat(2, minmax(0, 1fr))", [media.mobile]: null },
    flexDirection: "column",
    gap: space.s5,
  },
  group: { minWidth: 0, display: "flex", flexDirection: "column", gap: space.s1 },
  groupTitle: { marginBottom: space.s1 },
  navLink: {
    display: "block",
    width: "100%",
    minWidth: 0,
    paddingBlock: "7px",
    paddingInline: space.s3,
    borderRadius: radius.chip,
    color: { default: color.inkMuted, ":hover": color.ink },
    textDecorationLine: "none",
    backgroundColor: { default: "transparent", ":hover": color.frost },
    overflowWrap: "anywhere",
  },
  navLinkActive: { color: color.ink, backgroundColor: color.frost },
  empty: { paddingBlock: space.s5, color: color.inkMuted },
  main: { minWidth: 0 },
  articleMeta: {
    marginBottom: space.s6,
    paddingBottom: space.s5,
    borderBottomWidth: "1px",
    borderBottomStyle: "solid",
    borderBottomColor: color.border,
    display: "flex",
    alignItems: { default: "center", [media.mobile]: "flex-start" },
    justifyContent: "space-between",
    flexDirection: { default: "row", [media.mobile]: "column" },
    gap: space.s3,
  },
  sourceTag: {
    flexShrink: 0,
    paddingBlock: "5px",
    paddingInline: space.s3,
    borderRadius: radius.pill,
    backgroundColor: color.frost,
    color: color.inkMuted,
  },
  pager: {
    maxWidth: "880px",
    marginTop: "64px",
    paddingTop: space.s5,
    borderTopWidth: "1px",
    borderTopStyle: "solid",
    borderTopColor: color.border,
    display: "grid",
    gridTemplateColumns: "repeat(2, minmax(0, 1fr))",
    gap: space.s3,
  },
  pagerLink: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: space.s1,
    padding: space.s4,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: { default: color.border, ":hover": color.borderHover },
    borderRadius: radius.card,
    color: color.ink,
    textDecorationLine: "none",
    backgroundColor: { default: color.bgPanel, ":hover": color.bgCard },
  },
  pagerRight: { textAlign: "right", gridColumn: "2" },
});

export function ReferenceShowcase() {
  const [route, setRoute] = useState<Route>(readRoute);
  const [query, setQuery] = useState("");
  const section = useRef<HTMLElement>(null);

  useEffect(() => {
    const update = (): void => setRoute(readRoute());
    window.addEventListener("hashchange", update);
    window.addEventListener("popstate", update);
    return () => {
      window.removeEventListener("hashchange", update);
      window.removeEventListener("popstate", update);
    };
  }, []);

  const page = referencePage(route.slug);
  const activeIndex = referencePages.findIndex((entry) => entry.slug === page.slug);

  const navigate = useCallback((slug: string, anchor?: string): void => {
    const hash = referenceHash(slug, anchor);
    window.history.pushState(null, "", hash);
    setRoute({ active: true, slug, anchor });
  }, []);

  useEffect(() => {
    if (!route.active) return;
    const frame = window.requestAnimationFrame(() => {
      const target = route.anchor
        ? document.getElementById(`reference-${page.slug}-${route.anchor}`)
        : section.current;
      const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      target?.scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth", block: "start" });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [page.slug, route.active, route.anchor]);

  const normalizedQuery = query.trim().toLowerCase();
  const visible = useMemo(() => {
    if (!normalizedQuery) return new Set(referencePages.map((entry) => entry.slug));
    return new Set(referencePages
      .filter((entry) => `${entry.title}\n${entry.summary}\n${entry.source}`.toLowerCase().includes(normalizedQuery))
      .map((entry) => entry.slug));
  }, [normalizedQuery]);

  const visibleCount = visible.size;
  const previous = activeIndex > 0 ? referencePages[activeIndex - 1] : null;
  const next = activeIndex >= 0 && activeIndex < referencePages.length - 1 ? referencePages[activeIndex + 1] : null;

  return (
    <section ref={section} id="reference" {...stylex.props(styles.area)} aria-label="API reference">
      <div {...stylex.props(styles.layout)}>
        <aside {...stylex.props(styles.sidebar)}>
          <div {...stylex.props(styles.navHeader)}>
            <div {...stylex.props(styles.navTitle)}>
              <span {...stylex.props(text.eyebrow)}>Reference</span>
              <span {...stylex.props(text.micro, styles.count)}>{visibleCount}/{referencePages.length}</span>
            </div>
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.currentTarget.value)}
              placeholder="Search methods and topics"
              aria-label="Search the API reference"
              {...stylex.props(controls.field, styles.search)}
            />
            <select
              value={page.slug}
              onChange={(event) => navigate(event.currentTarget.value)}
              aria-label="Current reference page"
              {...stylex.props(controls.field, styles.mobileSelect)}
            >
              {!visible.has(page.slug) ? <option value={page.slug}>{page.title}</option> : null}
              {referenceGroups.map((group) => {
                const pages = group.pages.filter((entry) => visible.has(entry.slug));
                return pages.length ? (
                  <optgroup key={group.title} label={group.title}>
                    {pages.map((entry) => <option key={entry.slug} value={entry.slug}>{entry.title}</option>)}
                  </optgroup>
                ) : null;
              })}
            </select>
          </div>
          <nav {...stylex.props(styles.nav)} aria-label="Reference pages">
            {referenceGroups.map((group) => {
              const pages = group.pages.filter((entry) => visible.has(entry.slug));
              if (!pages.length) return null;
              return (
                <div key={group.title} {...stylex.props(styles.group)}>
                  <span {...stylex.props(text.micro, text.subtle, styles.groupTitle)}>{group.title}</span>
                  {pages.map((entry) => (
                    <a
                      key={entry.slug}
                      href={referenceHash(entry.slug)}
                      aria-current={entry.slug === page.slug ? "page" : undefined}
                      onClick={(event) => { event.preventDefault(); navigate(entry.slug); }}
                      {...stylex.props(text.body, styles.navLink, entry.slug === page.slug && styles.navLinkActive)}
                    >
                      {entry.title}
                    </a>
                  ))}
                </div>
              );
            })}
            {visibleCount === 0 ? <p {...stylex.props(text.body, styles.empty)}>No reference page matches “{query}”.</p> : null}
          </nav>
        </aside>

        <main {...stylex.props(styles.main)}>
          <div {...stylex.props(styles.articleMeta)}>
            <span {...stylex.props(text.eyebrow)}>{page.group}</span>
            <span {...stylex.props(text.micro, styles.sourceTag)}>docs/{page.slug}.md</span>
          </div>
          <MarkdownArticle source={page.source} slug={page.slug} navigate={navigate} />
          <nav {...stylex.props(styles.pager)} aria-label="Adjacent reference pages">
            {previous ? (
              <a href={referenceHash(previous.slug)} onClick={(event) => { event.preventDefault(); navigate(previous.slug); }} {...stylex.props(styles.pagerLink)}>
                <span {...stylex.props(text.micro, text.subtle)}>← Previous</span>
                <span {...stylex.props(text.body, text.strong)}>{previous.title}</span>
              </a>
            ) : null}
            {next ? (
              <a href={referenceHash(next.slug)} onClick={(event) => { event.preventDefault(); navigate(next.slug); }} {...stylex.props(styles.pagerLink, styles.pagerRight)}>
                <span {...stylex.props(text.micro, text.subtle)}>Next →</span>
                <span {...stylex.props(text.body, text.strong)}>{next.title}</span>
              </a>
            ) : null}
          </nav>
        </main>
      </div>
    </section>
  );
}
