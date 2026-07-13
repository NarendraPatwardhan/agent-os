import { useEffect, useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { setArtifactSources } from "@mc/elements";
import type { McTerminal } from "@mc/elements";
import { layout, text } from "instrument";
import { color } from "instrument/tokens/color.stylex.js";
import { space } from "instrument/tokens/space.stylex.js";
import { radius } from "instrument/tokens/radius.stylex.js";
import { font } from "instrument/tokens/type.stylex.js";
import { container } from "instrument/tokens/size.stylex.js";
import { media } from "instrument/tokens/media.stylex.js";
import { duration, easing } from "instrument/tokens/motion.stylex.js";
import { runAutoDemo, type AutoDemoHandle } from "./heroDemo";
import { CopyIcon } from "./CopyIcon";

// Point @mc/elements' artifact loader at the Bazel-staged kernel/image that Vite
// serves from /mc/ (see web/BUILD.bazel `hero_vm_assets`). Module scope: runs once,
// before any <mc-terminal> boots.
setArtifactSources({ kernel: "/mc/kernel.wasm", image: "/mc/image.tar" });

const styles = stylex.create({
  page: {
    minHeight: "100vh",
    display: "flex",
    justifyContent: "center",
    paddingBlock: { default: "clamp(64px, 12vw, 120px)", [media.mobile]: space.s6 },
    paddingInline: { default: space.s6, [media.mobile]: space.s4 },
  },
  shell: {
    width: "100%",
    maxWidth: container.content,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: { default: "clamp(40px, 6vw, 72px)", [media.mobile]: space.s6 },
  },
  copy: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: space.s5,
    maxWidth: container.reading,
    textAlign: "center",
  },
  eyebrow: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.s2,
    paddingBlock: space.s1,
    paddingInline: space.s3,
    borderRadius: radius.pill,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.border,
    backgroundColor: color.bgPanel,
  },
  dot: {
    width: "7px",
    height: "7px",
    borderRadius: radius.pill,
    backgroundColor: color.successBase,
  },
  headline: {
    maxWidth: "16ch",
  },
  lede: {
    maxWidth: "60ch",
  },
  command: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.s3,
    maxWidth: "100%",
    paddingBlock: space.s3,
    paddingInline: space.s4,
    borderRadius: radius.card,
    borderWidth: "1px",
    borderStyle: "solid",
    fontFamily: font.mono,
    fontSize: "13px",
    color: color.ink,
    overflowWrap: "anywhere",
    justifyContent: { default: "flex-start", [media.mobile]: "center" },
    appearance: "none",
    textAlign: "left",
    cursor: "pointer",
    transitionProperty: "background-color, border-color",
    transitionDuration: duration.fast,
    transitionTimingFunction: easing.out,
    backgroundColor: {
      default: color.bgPanel,
      ":hover": color.bgCard,
    },
    borderColor: {
      default: color.border,
      ":hover": color.borderHover,
    },
    outlineWidth: { default: null, ":focus-visible": "2px" },
    outlineStyle: { default: null, ":focus-visible": "solid" },
    outlineColor: { default: null, ":focus-visible": color.signal },
    outlineOffset: { default: null, ":focus-visible": "2px" },
  },
  prompt: {
    color: color.inkSubtle,
  },
  commandText: {
    minWidth: 0,
  },
  copyStatus: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    flexShrink: 0,
    paddingLeft: space.s3,
    borderLeftWidth: "1px",
    borderLeftStyle: "solid",
    borderLeftColor: color.border,
    color: color.inkMuted,
  },
  copyStatusDone: {
    color: color.successText,
  },
  copyIcon: {
    display: "block",
  },
  terminalWrap: {
    width: "100%",
    maxWidth: container.content,
    // Definite height lives on the wrapper (a plain div, no @layer contest). The
    // element's own `mc-terminal { height: 100% }` fills it — otherwise a StyleX height
    // on <mc-terminal> loses to that layered rule and xterm fits to a bogus size.
    height: { default: "clamp(20rem, 40vw, 30rem)", [media.mobile]: "22rem" },
  },
  terminal: {
    // NOTE: do NOT set `display` here. <mc-terminal> is `display: flex` (column) from
    // @mc/elements; a StyleX display wins over that layered rule and collapses the flex,
    // leaving the inner .screen unconstrained so xterm can't fit. Size only.
    width: "100%",
    height: "100%",
  },
});

function HeroTerminal() {
  const ref = useRef<McTerminal>(null);

  useEffect(() => {
    const term = ref.current;
    if (!term) return undefined;
    let demo: AutoDemoHandle | null = null;

    // Run the scripted demo once the shell is live; cancel the instant the user types.
    const onReady = (): void => {
      demo?.cancel();
      demo = runAutoDemo((bytes) => term.send(bytes));
    };
    const onData = (): void => {
      demo?.cancel();
      demo = null;
    };
    term.addEventListener("mc-ready", onReady);
    term.addEventListener("mc-data", onData);
    return () => {
      term.removeEventListener("mc-ready", onReady);
      term.removeEventListener("mc-data", onData);
      demo?.cancel();
    };
  }, []);

  return (
    <mc-terminal
      ref={ref}
      {...stylex.props(styles.terminal)}
      label="agent · live in your browser"
      net
      cursor="block"
      line-height={1.55}
    />
  );
}

export function Hero() {
  const [copied, setCopied] = useState(false);
  const resetTimer = useRef<number | null>(null);
  const origin = typeof window === "undefined" ? "" : window.location.origin;
  const installCommand = `curl -fsSL ${origin}/install.sh | bash`;

  useEffect(
    () => () => {
      if (resetTimer.current !== null) window.clearTimeout(resetTimer.current);
    },
    [],
  );

  const copyInstallCommand = async (): Promise<void> => {
    try {
      await navigator.clipboard.writeText(installCommand);
      setCopied(true);
      if (resetTimer.current !== null) window.clearTimeout(resetTimer.current);
      resetTimer.current = window.setTimeout(() => setCopied(false), 2000);
    } catch {
      setCopied(false);
    }
  };

  return (
    <main {...stylex.props(styles.page)}>
      <div {...stylex.props(styles.shell)}>
        <div {...stylex.props(styles.copy)}>
          <span {...stylex.props(styles.eyebrow, text.eyebrow)}>
            <i {...stylex.props(styles.dot)} />
            an operating system for AI agents
          </span>
          <h1 {...stylex.props(text.display, styles.headline)}>
            Give the agent <span {...stylex.props(text.swap)}>its own</span> computer.
          </h1>
          <p {...stylex.props(text.bodyLg, text.muted, styles.lede)}>
            A WebAssembly VM with a Unix shell, files, processes, pipes, snapshots, and a
            host-controlled capability boundary.
          </p>
          <button
            type="button"
            {...stylex.props(styles.command)}
            onClick={() => void copyInstallCommand()}
            aria-label={`${copied ? "Copied" : "Copy"} install command`}
            title="Copy install command"
          >
            <span {...stylex.props(styles.prompt)}>$</span>
            <span {...stylex.props(styles.commandText)}>{installCommand}</span>
            <span
              {...stylex.props(styles.copyStatus, copied && styles.copyStatusDone)}
              aria-hidden="true"
            >
              <CopyIcon copied={copied} {...stylex.props(styles.copyIcon)} />
            </span>
            <span {...stylex.props(layout.srOnly)} aria-live="polite">
              {copied ? "Install command copied" : ""}
            </span>
          </button>
        </div>

        <div {...stylex.props(styles.terminalWrap)}>
          <HeroTerminal />
        </div>
      </div>
    </main>
  );
}
