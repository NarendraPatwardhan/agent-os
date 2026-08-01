/**
 * Process-local git remote counters + last-op labels.
 *
 * Not Prometheus — simple in-process tallies with reset for tests. Records
 * outcome counts, duration/pack-byte sums, and a redacted origin label.
 * Never stores packs, tokens, or credential material.
 */

// ── Types ───────────────────────────────────────────────────────────────────

export type GitCounterKey =
  | "clone_ok"
  | "clone_error"
  | "fetch_ok"
  | "fetch_error"
  | "push_ok"
  | "push_error"
  | "allowlist_deny";

export type GitMetricLabelKey =
  | "last_duration_ms"
  | "last_pack_bytes"
  | "last_origin_redacted"
  | "duration_ms_sum"
  | "pack_bytes_sum";

export type GitMetricsSnapshot = Record<GitCounterKey, number> & {
  last_duration_ms: number;
  last_pack_bytes: number;
  last_origin_redacted: string;
  duration_ms_sum: number;
  pack_bytes_sum: number;
};

/** Meta for a single remote op. Never pass tokens or raw Authorization. */
export type RemoteResultMeta = {
  duration_ms?: number;
  pack_bytes?: number;
  /** scheme://host[:port] only */
  origin_redacted?: string;
  allowlist_deny?: boolean;
};

// ── State ───────────────────────────────────────────────────────────────────

const COUNTER_KEYS: GitCounterKey[] = [
  "clone_ok",
  "clone_error",
  "fetch_ok",
  "fetch_error",
  "push_ok",
  "push_error",
  "allowlist_deny",
];

const counters: Record<GitCounterKey, number> = {
  clone_ok: 0,
  clone_error: 0,
  fetch_ok: 0,
  fetch_error: 0,
  push_ok: 0,
  push_error: 0,
  allowlist_deny: 0,
};

let lastDurationMs = 0;
let lastPackBytes = 0;
let lastOriginRedacted = "";
let durationMsSum = 0;
let packBytesSum = 0;

// ── API ─────────────────────────────────────────────────────────────────────

export function incGitCounter(key: GitCounterKey, n = 1): void {
  if (key in counters) counters[key] += n;
}

export function snapshotGitCounters(): GitMetricsSnapshot {
  return {
    ...counters,
    last_duration_ms: lastDurationMs,
    last_pack_bytes: lastPackBytes,
    last_origin_redacted: lastOriginRedacted,
    duration_ms_sum: durationMsSum,
    pack_bytes_sum: packBytesSum,
  };
}

export function resetGitCounters(): void {
  for (const k of COUNTER_KEYS) counters[k] = 0;
  lastDurationMs = 0;
  lastPackBytes = 0;
  lastOriginRedacted = "";
  durationMsSum = 0;
  packBytesSum = 0;
}

export function recordRemoteResult(
  op: string,
  ok: boolean,
  meta: RemoteResultMeta = {},
): void {
  const o = String(op || "").toLowerCase();
  if (o === "clone") incGitCounter(ok ? "clone_ok" : "clone_error");
  else if (o === "fetch" || o === "pull")
    incGitCounter(ok ? "fetch_ok" : "fetch_error");
  else if (o === "push") incGitCounter(ok ? "push_ok" : "push_error");

  const duration =
    typeof meta.duration_ms === "number" && meta.duration_ms >= 0
      ? Math.floor(meta.duration_ms)
      : 0;
  const packBytes =
    typeof meta.pack_bytes === "number" && meta.pack_bytes >= 0
      ? Math.floor(meta.pack_bytes)
      : 0;
  const origin =
    typeof meta.origin_redacted === "string" && meta.origin_redacted
      ? meta.origin_redacted
      : "";

  lastDurationMs = duration;
  lastPackBytes = packBytes;
  lastOriginRedacted = origin;
  durationMsSum += duration;
  packBytesSum += packBytes;

  if (meta.allowlist_deny) {
    incGitCounter("allowlist_deny");
  }
}

/** Redact URL to scheme://host[:port] (no path, query, userinfo). */
export function redactOrigin(url: string): string {
  try {
    const u = new URL(url);
    const port =
      u.port && u.port !== ""
        ? `:${u.port}`
        : "";
    return `${u.protocol}//${u.hostname}${port}`;
  } catch {
    return "remote";
  }
}
