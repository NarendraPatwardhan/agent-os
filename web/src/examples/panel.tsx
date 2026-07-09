import type { ReactNode } from "react";
import * as stylex from "@stylexjs/stylex";
import { text } from "instrument";
import { styles } from "./styles";
import type { VmSession } from "./useVmSession";
import type { Example } from "./types";

export function PlayIcon({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden="true">
      <path d="M6 3.5v13l10.5-6.5z" fill="#3fcf6f" />
    </svg>
  );
}

/** The one bare green-triangle button. `place` picks a positioning variant:
 *  "abs" (top-right of the code block), "right" (end of a row), "fill" (fills the box). */
export function PlayButton({
  size = 18,
  onClick,
  label,
  place,
}: {
  size?: number;
  onClick: () => void;
  label: string;
  place?: "abs" | "right" | "fill";
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={label}
      {...stylex.props(
        styles.playBtn,
        place === "abs" && styles.playAbs,
        place === "right" && styles.playRight,
        place === "fill" && styles.playFill,
      )}
    >
      <PlayIcon size={size} />
    </button>
  );
}

/** The faint idle-terminal hint text. */
export function Hint({ children }: { children: ReactNode }) {
  return <span {...stylex.props(styles.termHint, text.body, text.subtle)}>{children}</span>;
}

/** The left panel frame: summary + notes header, then the driver's control surface. */
export function ExampleShell({ example, left, terminal }: { example: Example; left: ReactNode; terminal: ReactNode }) {
  return (
    <>
      <div {...stylex.props(styles.content)}>
        <div {...stylex.props(styles.contentInner)}>
          {example.summary ? <p {...stylex.props(styles.lede, text.body)}>{example.summary}</p> : null}
          {example.notes && example.notes.length > 0 ? (
            <ul {...stylex.props(styles.notes)}>
              {example.notes.map((n) => (
                <li key={n} {...stylex.props(styles.note, text.body)}>
                  {n}
                </li>
              ))}
            </ul>
          ) : null}
          {left}
        </div>
      </div>
      {terminal}
    </>
  );
}

/** The right column: the terminal (idle hint or `<mc-terminal>` derived from the
 *  session's boot spec), an optional actions slot, and the console-log panel. */
export function TerminalPanel({
  session,
  label,
  hint,
  actions,
}: {
  session: VmSession;
  label: string;
  hint: ReactNode;
  actions?: ReactNode;
}) {
  const s = session.spec;
  return (
    <div {...stylex.props(styles.termCol)}>
      <div {...stylex.props(styles.terminalBox, !session.live && styles.terminalBoxIdle)}>
        {s == null ? (
          hint
        ) : (
          <mc-terminal
            key={session.bootKey}
            ref={session.terminalRef}
            {...stylex.props(styles.terminal)}
            label={label}
            cursor="block"
            line-height={1.5}
            {...(s.kind === "browser"
              ? {
                  image: s.image,
                  ...(s.net ? { net: true } : {}),
                  ...(s.deterministic ? { deterministic: true } : {}),
                }
              : { manual: true })}
          />
        )}
      </div>
      {actions ? <div {...stylex.props(styles.actions)}>{actions}</div> : null}
      <div {...stylex.props(styles.logs)} aria-live="polite">
        {session.logs.map((line, i) => (
          <span key={`${i}-${line}`} {...stylex.props(styles.logLine)}>
            {line}
          </span>
        ))}
      </div>
    </div>
  );
}
