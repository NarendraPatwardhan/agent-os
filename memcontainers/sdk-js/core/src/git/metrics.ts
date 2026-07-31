/**
 * In-process git remote counters (R85–R88).
 * Not Prometheus — simple process-local counters with reset for tests.
 * Never stores packs, tokens, or credential material.
 */

export type GitCounterKey =
  | "clone_ok"
  | "clone_error"
  | "fetch_ok"
  | "fetch_error"
  | "push_ok"
  | "push_error";

const KEYS: GitCounterKey[] = [
  "clone_ok",
  "clone_error",
  "fetch_ok",
  "fetch_error",
  "push_ok",
  "push_error",
];

const counters: Record<GitCounterKey, number> = {
  clone_ok: 0,
  clone_error: 0,
  fetch_ok: 0,
  fetch_error: 0,
  push_ok: 0,
  push_error: 0,
};

export function incGitCounter(key: GitCounterKey, n = 1): void {
  if (key in counters) counters[key] += n;
}

export function snapshotGitCounters(): Record<GitCounterKey, number> {
  return { ...counters };
}

export function resetGitCounters(): void {
  for (const k of KEYS) counters[k] = 0;
}

export function recordRemoteResult(op: string, ok: boolean): void {
  const o = String(op || "").toLowerCase();
  if (o === "clone") incGitCounter(ok ? "clone_ok" : "clone_error");
  else if (o === "fetch" || o === "pull")
    incGitCounter(ok ? "fetch_ok" : "fetch_error");
  else if (o === "push") incGitCounter(ok ? "push_ok" : "push_error");
}
