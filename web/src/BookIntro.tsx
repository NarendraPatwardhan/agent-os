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
    paddingTop: "clamp(48px, 7vw, 88px)",
    paddingBottom: "clamp(96px, 14vw, 176px)",
    paddingInline: { default: space.s6, [media.mobile]: space.s4 },
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
  heading: {
    maxWidth: "16ch",
  },
  description: {
    maxWidth: "58ch",
  },
  link: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.s2,
    marginTop: space.s2,
  },
});

export function BookIntro() {
  return (
    <section {...stylex.props(styles.section)} aria-labelledby="book-intro-title">
      <div {...stylex.props(styles.content)}>
        <span {...stylex.props(text.eyebrow)}>Learn by doing</span>
        <h2 id="book-intro-title" {...stylex.props(text.display, styles.heading)}>
          Ready to dive in?
        </h2>
        <p {...stylex.props(text.bodyLg, text.muted, styles.description)}>
          Explore AgentOS by Example—a hands-on guide to building with real VMs, files,
          tools, snapshots, and more.
        </p>
        <a href="#examples" {...stylex.props(controls.link, text.body, styles.link)}>
          Start with First Contact <span aria-hidden="true">↓</span>
        </a>
      </div>
    </section>
  );
}
