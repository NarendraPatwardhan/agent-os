import type { ReactNode } from "react";
import type { VmBootStatus } from "./VmProvider";
import styles from "./TerminalFrame.module.css";

export interface TerminalFrameProps {
  children: ReactNode;
  title: string;
  status?: VmBootStatus;
  error?: unknown;
  className?: string;
}

function statusLabel(status: VmBootStatus | undefined): string {
  if (!status) return "";
  if (status === "ready") return "live";
  return status;
}

function errorMessage(error: unknown): string {
  if (!error) return "";
  return error instanceof Error ? error.message : String(error);
}

export function TerminalFrame({ children, title, status, error, className }: TerminalFrameProps) {
  const message = errorMessage(error);
  const showBooting = status === "booting";
  const showError = status === "error" && message;

  return (
    <section className={[styles.root, className].filter(Boolean).join(" ")} data-status={status}>
      <div className={styles.bar}>
        <span className={styles.lights} aria-hidden="true">
          <span className={styles.light} />
          <span className={styles.light} />
          <span className={styles.light} />
        </span>
        <span className={styles.title}>{title}</span>
        {status ? <span className={styles.status}>{statusLabel(status)}</span> : null}
      </div>
      <div className={styles.body}>
        {children}
        {showBooting ? <div className={styles.overlay}>Booting VM</div> : null}
        {showError ? (
          <div className={styles.overlay} data-kind="error">
            {message}
          </div>
        ) : null}
      </div>
    </section>
  );
}
