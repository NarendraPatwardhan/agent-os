import { useRef, useState } from "react";
import type { ReactNode } from "react";
import * as stylex from "@stylexjs/stylex";
import type { Vm } from "@mc/elements";
import { text } from "instrument";
import { Icon } from "../Icon";
import { styles } from "./styles";
import type { VmSession } from "./useVmSession";
import type { Example, IconId } from "./types";

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

// ── artifact download chips ───────────────────────────────────────────────────
type Artifact = { readonly path: string; readonly size: number };

const EXT_ICON: Record<string, IconId> = { xlsx: "xlsx", docx: "docx", pptx: "pptx", pdf: "pdf", db: "sqlite" };
const EXT_MIME: Record<string, string> = {
  xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  pdf: "application/pdf",
  db: "application/vnd.sqlite3",
};
const ext = (path: string): string => path.split(".").pop() ?? "";
const basename = (path: string): string => path.split("/").pop() ?? path;
const human = (n: number): string => (n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`);

export type Artifacts = {
  /** Download chips for `TerminalPanel`'s actions slot (undefined when none). */
  readonly chips: ReactNode | undefined;
  /** Stat the declared paths on the still-live VM; existing ones become chips. */
  readonly collect: (vm: Vm) => Promise<void>;
  readonly reset: () => void;
};

/** Declared artifact paths → download chips. After a run, `collect(vm)` stats each
 *  path; the ones the (possibly edited) program actually produced render as
 *  icon+name+size chips. Clicking reads the bytes out of the live VM (vm.fs.read)
 *  and saves them via a Blob download with the right MIME type. */
export function useArtifacts(paths: readonly string[] | undefined): Artifacts {
  const [items, setItems] = useState<readonly Artifact[]>([]);
  const vmRef = useRef<Vm | null>(null);

  const collect = async (vm: Vm): Promise<void> => {
    vmRef.current = vm;
    const found: Artifact[] = [];
    for (const path of paths ?? []) {
      try {
        found.push({ path, size: (await vm.fs.stat(path)).size });
      } catch {
        // not produced this run — no chip
      }
    }
    setItems(found);
  };

  const download = async (artifact: Artifact): Promise<void> => {
    const vm = vmRef.current;
    if (!vm) return;
    const bytes = await vm.fs.read(artifact.path);
    const blob = new Blob([bytes as BlobPart], { type: EXT_MIME[ext(artifact.path)] ?? "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = basename(artifact.path);
    link.click();
    URL.revokeObjectURL(url);
  };

  const chips =
    items.length > 0
      ? items.map((artifact) => (
          <button
            key={artifact.path}
            type="button"
            {...stylex.props(styles.artifactBtn)}
            onClick={() => void download(artifact)}
            title={`Download ${artifact.path}`}
          >
            <Icon id={EXT_ICON[ext(artifact.path)] ?? "file"} size={16} />
            {basename(artifact.path)}
            <span {...stylex.props(styles.artifactSize)}>{human(artifact.size)}</span>
          </button>
        ))
      : undefined;

  return { chips, collect, reset: () => setItems([]) };
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
