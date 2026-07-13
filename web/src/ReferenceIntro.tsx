import * as stylex from "@stylexjs/stylex";
import { controls, text } from "instrument";
import { color } from "instrument/tokens/color.stylex.js";
import { media } from "instrument/tokens/media.stylex.js";
import { container } from "instrument/tokens/size.stylex.js";
import { space } from "instrument/tokens/space.stylex.js";

const styles = stylex.create({
  section: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    paddingTop: "clamp(96px, 14vw, 176px)",
    paddingBottom: "clamp(96px, 14vw, 176px)",
    paddingInline: { default: space.s6, [media.mobile]: space.s4 },
    borderTopWidth: "1px",
    borderTopStyle: "solid",
    borderTopColor: color.border,
    backgroundColor: color.bgCanvas,
  },
  content: {
    width: "100%",
    maxWidth: container.reading,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: space.s4,
    textAlign: "center",
  },
  heading: { maxWidth: "17ch" },
  description: { maxWidth: "62ch" },
  link: { display: "inline-flex", alignItems: "center", gap: space.s2, marginTop: space.s2 },
});

export function ReferenceIntro() {
  return (
    <section {...stylex.props(styles.section)} aria-labelledby="reference-intro-title">
      <div {...stylex.props(styles.content)}>
        <span {...stylex.props(text.eyebrow)}>Ready to build?</span>
        <h2 id="reference-intro-title" {...stylex.props(text.display, styles.heading)}>
          Turn examples into applications.
        </h2>
        <p {...stylex.props(text.bodyLg, text.muted, styles.description)}>
          Explore every public method, option, runtime boundary, browser element, and failure mode in
          one searchable guide.
        </p>
        <a href="#reference" {...stylex.props(controls.link, text.body, styles.link)}>
          Explore the API <span aria-hidden="true">↓</span>
        </a>
      </div>
    </section>
  );
}
