import { useEffect, useRef } from "react";
import type { Chapter } from "./examples/types";
import styles from "./Showcase.module.css";

type MarkerTocProps = {
  readonly chapters: readonly Chapter[];
  readonly activeId: string;
  readonly onSelect: (id: string) => void;
};

export function MarkerToc({ chapters, activeId, onSelect }: MarkerTocProps) {
  const scroller = useRef<HTMLOListElement>(null);
  const active = useRef<HTMLLIElement>(null);

  // Keep the active chapter centered in the scale (the scroll-timeline animation
  // then bulges it rightward and lights its tick).
  useEffect(() => {
    const s = scroller.current;
    const a = active.current;
    if (!s || !a) return;
    const top = a.offsetTop - (s.clientHeight - a.clientHeight) / 2;
    s.scrollTo({ top, behavior: "smooth" });
  }, [activeId]);

  return (
    <nav className={styles.toc} aria-label="Chapters">
      <ol className={styles.tocScroller} ref={scroller}>
        {chapters.map((chapter) => {
          const on = chapter.id === activeId;
          return (
            <li className={styles.tocItem} data-active={on} key={chapter.id} ref={on ? active : undefined}>
              <button className={styles.tocButton} type="button" onClick={() => onSelect(chapter.id)}>
                <span className={styles.tocIndex}>{chapter.num.padStart(2, "0")}</span>
                <span className={styles.tocText}>
                  {chapter.title}
                  <span className={styles.tocCount}> · {chapter.count}</span>
                </span>
              </button>
              <span className={styles.topMarker} />
              <span className={styles.bottomMarker} />
              <span className={styles.primaryMarker} />
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
