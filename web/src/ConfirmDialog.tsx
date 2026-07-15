import { useEffect, useRef } from "react";
import type { ReactNode } from "react";
import * as stylex from "@stylexjs/stylex";
import { accentSignal, controls, surface, text } from "instrument";
import { color } from "instrument/tokens/color.stylex.js";
import { duration, easing } from "instrument/tokens/motion.stylex.js";
import { space } from "instrument/tokens/space.stylex.js";
import { shell } from "instrument/tokens/size.stylex.js";

const styles = stylex.create({
  dialog: {
    position: "fixed",
    top: "50%",
    left: "50%",
    width: shell.dialogSm,
    maxWidth: "calc(100vw - 32px)",
    maxHeight: "calc(100dvh - 64px)",
    margin: 0,
    padding: space.s6,
    overflowY: "auto",
    display: { default: "none", "[open]": "flex" },
    flexDirection: "column",
    gap: space.s4,
    transform: "translate(-50%, -50%)",
    opacity: 1,
    filter: "blur(0)",
    transitionProperty: "opacity, transform, filter, display, overlay",
    transitionDuration: duration.slow,
    transitionTimingFunction: easing.outQuint,
    transitionBehavior: "allow-discrete",
    "::backdrop": {
      backgroundColor: color.scrim,
      backdropFilter: "blur(8px)",
    },
    "@starting-style": {
      opacity: 0,
      filter: "blur(8px)",
      transform: "translate(-50%, calc(-50% + 8px))",
    },
  },
  header: {
    display: "flex",
    flexDirection: "column",
    gap: space.s2,
  },
  title: {
    margin: 0,
  },
  body: {
    display: "flex",
    flexDirection: "column",
    gap: space.s4,
  },
  footer: {
    display: "flex",
    justifyContent: "flex-end",
    gap: space.s2,
    marginTop: space.s2,
  },
  facts: {
    display: "flex",
    flexDirection: "column",
    borderTopWidth: "0.5px",
    borderTopStyle: "solid",
    borderTopColor: color.border,
  },
  fact: {
    display: "grid",
    gridTemplateColumns: "72px minmax(0, 1fr)",
    gap: space.s3,
    paddingBlock: space.s2,
    borderBottomWidth: "0.5px",
    borderBottomStyle: "solid",
    borderBottomColor: color.border,
  },
  factLabel: {
    color: color.inkSubtle,
  },
  factValue: {
    minWidth: 0,
    overflowWrap: "anywhere",
    color: color.ink,
  },
});

export function ConfirmDialog({
  open,
  title,
  description,
  confirmLabel,
  cancelLabel = "Cancel",
  onConfirm,
  onCancel,
  children,
}: {
  readonly open: boolean;
  readonly title: string;
  readonly description: string;
  readonly confirmLabel: string;
  readonly cancelLabel?: string;
  readonly onConfirm: () => void;
  readonly onCancel: () => void;
  readonly children?: ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      aria-labelledby="confirm-dialog-title"
      aria-describedby="confirm-dialog-description"
      onCancel={(event) => {
        event.preventDefault();
        onCancel();
      }}
      {...stylex.props(surface.veilDeep, styles.dialog)}
    >
      <header {...stylex.props(styles.header)}>
        <h2 id="confirm-dialog-title" {...stylex.props(styles.title, text.title)}>
          {title}
        </h2>
        <p id="confirm-dialog-description" {...stylex.props(text.body, text.muted)}>
          {description}
        </p>
      </header>
      {children ? <div {...stylex.props(styles.body)}>{children}</div> : null}
      <footer {...stylex.props(styles.footer)}>
        <button
          type="button"
          onClick={onCancel}
          {...stylex.props(controls.button, controls.buttonQuiet)}
        >
          {cancelLabel}
        </button>
        <span {...stylex.props(accentSignal)}>
          <button type="button" onClick={onConfirm} {...stylex.props(controls.button)}>
            {confirmLabel}
          </button>
        </span>
      </footer>
    </dialog>
  );
}

export function ConfirmFacts({
  facts,
}: {
  readonly facts: readonly { readonly label: string; readonly value: string }[];
}) {
  return (
    <dl {...stylex.props(styles.facts)}>
      {facts.map((fact) => (
        <div key={fact.label} {...stylex.props(styles.fact)}>
          <dt {...stylex.props(styles.factLabel, text.eyebrow)}>{fact.label}</dt>
          <dd {...stylex.props(styles.factValue, text.code)}>{fact.value}</dd>
        </div>
      ))}
    </dl>
  );
}
