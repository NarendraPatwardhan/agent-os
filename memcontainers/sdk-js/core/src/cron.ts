// vm.cron — a host-side scheduler over the public `vm` surface.
//
// It drives only `vm.exec` / `vm.session` (or a callback handed the VM), so it is
// backend-agnostic: the timer runs in the consumer's process and fires for as
// long as the `vm` handle is alive; `vm.close()` stops every job. This closes the
// old "no built-in timer — drive your own" gap at the client. A *durable*,
// server-resident cron (one that keeps firing after the client disconnects) is a
// future mc-server addition — it would live in the per-VM actor, not here.
//
// Schedules: a standard 5-field cron expression (`min hour dom month dow`, with
// `*`/`,`/`-`/`/step`, month+weekday names, and `?`), the usual macros
// (`@hourly`/`@daily`/`@weekly`/`@monthly`/`@yearly`/`@reboot`), an interval
// (`@every 30s`, `@every 1h30m`), or a raw number of milliseconds. Times are
// local by default (`timezone: "utc"` to switch).

import type { Vm } from "./memcontainer.js";
import type { ExecResult, SessionEvent } from "./types.js";

/** What a cron job does when it fires. A declarative action the VM runs, or
 *  a callback handed the live {@link Vm} (so it can use `vm.fs`, fork, etc.). */
export type CronAction =
  | { type: "exec"; cmd: string }
  | { type: "session"; prompt: string; agentType?: string }
  | ((vm: Vm) => void | Promise<void>);

/** Options for {@link Vm.cron}. */
export interface CronOptions {
  /** Fire once immediately on registration, then continue on the schedule. */
  immediate?: boolean;
  /** Stop automatically after this many firings (e.g. `1` = run once). */
  maxRuns?: number;
  /** Interpret the cron expression in UTC instead of local time. Default local.
   *  (Ignored for interval / `@every` schedules — those are wall-clock deltas.) */
  timezone?: "local" | "utc";
  /** Called after each successful firing with what it produced. */
  onRun?: (result: CronRunResult, handle: CronHandle) => void;
  /** Called if an action throws. Without a handler the error is swallowed so a
   *  single bad run never kills the schedule. */
  onError?: (err: unknown, handle: CronHandle) => void;
}

/** What one firing produced (passed to {@link CronOptions.onRun}). */
export interface CronRunResult {
  /** When this firing ran. */
  at: Date;
  /** The exec result, for an `{ type: "exec" }` action. */
  exec?: ExecResult;
  /** The session events, for a `{ type: "session" }` action. */
  session?: SessionEvent[];
}

/** A live cron job (returned by {@link Vm.cron}). Stop it with `stop()`; inspect
 *  the next fire time with `next()`. */
export interface CronHandle {
  /** Unique id for this job (stable for its lifetime). */
  readonly id: string;
  /** The schedule as registered (a cron string, `@every …`, or `"<n>ms"`). */
  readonly schedule: string;
  /** How many times the action has fired so far. */
  readonly runs: number;
  /** True once the job has stopped (manually, via `maxRuns`, or `@reboot`). */
  readonly stopped: boolean;
  /** The next scheduled fire time, or `null` if the job has stopped. */
  next(): Date | null;
  /** Stop the job (idempotent). Clears the pending timer. */
  stop(): void;
}

let cronSeq = 0;
const MAX_TIMEOUT_MS = 2_147_483_647;

/** Start a cron job bound to `vm`. Internal — reached via {@link Vm.cron}, which
 *  also tracks the handle so {@link Vm.close} can stop it. `onSettled` fires once
 *  when the job becomes permanently stopped (so the VM can untrack it). */
export function startCron(
  vm: Vm,
  schedule: string | number,
  action: CronAction,
  opts: CronOptions = {},
  onSettled?: () => void,
): CronHandle {
  const parsed = parseSchedule(schedule, opts.timezone === "utc");
  const id = `cron-${++cronSeq}`;
  const scheduleStr = typeof schedule === "number" ? `${schedule}ms` : schedule;

  let runs = 0;
  let stopped = false;
  let nextAt: Date | null = null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let settled = false;

  const settle = (): void => {
    if (settled) return;
    settled = true;
    stopped = true;
    nextAt = null;
    if (timer !== undefined) clearTimeout(timer);
    onSettled?.();
  };

  const handle: CronHandle = {
    id,
    schedule: scheduleStr,
    get runs() {
      return runs;
    },
    get stopped() {
      return stopped;
    },
    next() {
      return stopped ? null : nextAt;
    },
    stop() {
      settle();
    },
  };

  const fire = async (): Promise<void> => {
    if (stopped) return;
    runs++;
    const at = new Date();
    try {
      const result: CronRunResult = { at };
      if (typeof action === "function") {
        await action(vm);
      } else if (action.type === "exec") {
        result.exec = await vm.exec(action.cmd);
      } else {
        result.session = await vm.session(action.agentType).prompt(action.prompt);
      }
      opts.onRun?.(result, handle);
    } catch (err) {
      // A throwing job must not kill the schedule; surface it if a handler exists.
      if (opts.onError) opts.onError(err, handle);
    }
  };

  const tick = async (): Promise<void> => {
    if (stopped) return;
    await fire();
    if (stopped) return; // a firing (or its handlers) may have called stop()
    if (parsed.once) return settle();
    if (opts.maxRuns !== undefined && runs >= opts.maxRuns) return settle();
    scheduleNext();
  };

  const armTimer = (): void => {
    if (stopped || !nextAt) return;
    const delay = nextAt.getTime() - Date.now();
    timer = setTimeout(
      () => {
        timer = undefined;
        if (stopped || !nextAt) return;
        if (Date.now() < nextAt.getTime()) armTimer();
        else void tick();
      },
      Math.max(0, Math.min(delay, MAX_TIMEOUT_MS)),
    );
  };

  const scheduleNext = (): void => {
    const now = new Date();
    const at = parsed.next!(now);
    nextAt = at;
    armTimer();
  };

  if (opts.maxRuns !== undefined && opts.maxRuns <= 0) {
    // Degenerate (never runs) — settle on the next tick, never synchronously, so
    // `onSettled` can't fire before the caller has the handle.
    timer = setTimeout(() => settle(), 0);
  } else if (parsed.once || opts.immediate) {
    // `@reboot` / `immediate`: fire on the next tick of the event loop.
    nextAt = new Date();
    timer = setTimeout(() => void tick(), 0);
  } else {
    scheduleNext();
  }

  return handle;
}

// ── Schedule parsing ────────────────────────────────────────────────────────

/** A parsed schedule: a `next(from)` computer, or a one-shot (`@reboot`). */
interface ParsedSchedule {
  next?: (from: Date) => Date;
  once?: boolean;
}

const MACROS: Record<string, string> = {
  "@yearly": "0 0 1 1 *",
  "@annually": "0 0 1 1 *",
  "@monthly": "0 0 1 * *",
  "@weekly": "0 0 * * 0",
  "@daily": "0 0 * * *",
  "@midnight": "0 0 * * *",
  "@hourly": "0 * * * *",
};

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
const DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/** Parse a schedule into a `next`-computer (or a one-shot). Throws on a malformed
 *  expression so misconfiguration surfaces at registration, not at fire time. */
export function parseSchedule(schedule: string | number, utc: boolean): ParsedSchedule {
  if (typeof schedule === "number") {
    if (!Number.isFinite(schedule) || schedule <= 0) {
      throw new Error(`cron: interval must be a positive number of ms, got ${schedule}`);
    }
    return intervalSchedule(schedule);
  }
  const s = schedule.trim();
  if (s === "@reboot") return { once: true };
  if (s.startsWith("@every")) {
    return intervalSchedule(parseDuration(s.slice("@every".length).trim()));
  }
  const lower = s.toLowerCase();
  const expr = MACROS[lower] ?? s;
  return cronSchedule(expr, utc);
}

function intervalSchedule(ms: number): ParsedSchedule {
  return { next: (from) => new Date(from.getTime() + ms) };
}

/** Parse a duration like `30s`, `5m`, `1h30m`, `250ms`, `2d` into milliseconds. */
function parseDuration(text: string): number {
  const units: Record<string, number> = {
    ms: 1,
    s: 1000,
    m: 60_000,
    h: 3_600_000,
    d: 86_400_000,
    w: 604_800_000,
  };
  // Bare number → ms.
  if (/^\d+(\.\d+)?$/.test(text)) return Number(text);
  const re = /(\d+(?:\.\d+)?)(ms|s|m|h|d|w)/g;
  let total = 0;
  let matched = "";
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    total += Number(m[1]) * units[m[2]!]!;
    matched += m[0];
  }
  if (total <= 0 || matched !== text.replace(/\s+/g, "")) {
    throw new Error(`cron: invalid @every duration "${text}" (try 30s, 5m, 1h30m, 250ms)`);
  }
  return total;
}

/** A compiled 5-field cron expression. */
interface CronFields {
  minute: Set<number>;
  hour: Set<number>;
  dom: Set<number>;
  month: Set<number>;
  dow: Set<number>;
  /** True when day-of-month is unrestricted (`*`/`?`) — affects the OR rule. */
  domStar: boolean;
  /** True when day-of-week is unrestricted (`*`/`?`). */
  dowStar: boolean;
}

function cronSchedule(expr: string, utc: boolean): ParsedSchedule {
  const fields = parseCron(expr);
  return { next: (from) => nextCronDate(fields, from, utc) };
}

function parseCron(expr: string): CronFields {
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) {
    throw new Error(
      `cron: expected 5 fields (min hour dom month dow), got ${parts.length} in "${expr}"`,
    );
  }
  const [min, hr, dom, mon, dow] = parts;
  const domStar = dom === "*" || dom === "?";
  const dowStar = dow === "*" || dow === "?";
  return {
    minute: expandField(min!, 0, 59, "minute"),
    hour: expandField(hr!, 0, 23, "hour"),
    dom: expandField(dom!, 1, 31, "day-of-month"),
    month: expandField(mon!, 1, 12, "month", MONTHS, 1),
    // Day-of-week: 0 and 7 are both Sunday; normalize 7→0.
    dow: normalizeDow(expandField(dow!, 0, 7, "day-of-week", DAYS, 0)),
    domStar,
    dowStar,
  };
}

function normalizeDow(set: Set<number>): Set<number> {
  if (set.has(7)) {
    set.delete(7);
    set.add(0);
  }
  return set;
}

/** Expand one field — `*`, `a`, `a-b`, a step (`a-b/n`, or `*` with `/n`), and
 *  comma lists `a,b,c` (names allowed) — into the set of matching integers.
 *  `names`/`nameBase` map e.g. `jan`→1, `sun`→0. */
function expandField(
  field: string,
  lo: number,
  hi: number,
  label: string,
  names?: string[],
  nameBase = 0,
): Set<number> {
  const out = new Set<number>();
  const num = (tok: string): number => {
    const t = tok.toLowerCase();
    const idx = names?.indexOf(t.slice(0, 3));
    const v = idx !== undefined && idx >= 0 ? idx + nameBase : Number(tok);
    if (!Number.isInteger(v)) throw new Error(`cron: invalid ${label} token "${tok}"`);
    return v;
  };
  for (const part of field.split(",")) {
    if (part === "") throw new Error(`cron: empty ${label} term in "${field}"`);
    const [rangePart, stepPart] = part.split("/");
    const step = stepPart === undefined ? 1 : Number(stepPart);
    if (!Number.isInteger(step) || step <= 0) {
      throw new Error(`cron: invalid ${label} step "${stepPart}"`);
    }
    let start = lo;
    let end = hi;
    if (rangePart !== "*" && rangePart !== "?") {
      const bounds = rangePart!.split("-");
      if (bounds.length === 1) {
        start = end = num(bounds[0]!);
        // A bare value with a step (`5/10`) means "from 5 to max, step".
        if (stepPart !== undefined) end = hi;
      } else if (bounds.length === 2) {
        start = num(bounds[0]!);
        end = num(bounds[1]!);
      } else {
        throw new Error(`cron: invalid ${label} range "${rangePart}"`);
      }
    }
    if (start < lo || end > hi || start > end) {
      throw new Error(`cron: ${label} out of range [${lo}-${hi}] in "${part}"`);
    }
    for (let v = start; v <= end; v += step) out.add(v);
  }
  return out;
}

const get = {
  minute: (d: Date, utc: boolean) => (utc ? d.getUTCMinutes() : d.getMinutes()),
  hour: (d: Date, utc: boolean) => (utc ? d.getUTCHours() : d.getHours()),
  dom: (d: Date, utc: boolean) => (utc ? d.getUTCDate() : d.getDate()),
  month: (d: Date, utc: boolean) => (utc ? d.getUTCMonth() : d.getMonth()) + 1,
  dow: (d: Date, utc: boolean) => (utc ? d.getUTCDay() : d.getDay()),
};

/** The next instant strictly after `from` that matches `f`. Searches minute-by-
 *  minute but skips whole months/days/hours that can't match, so it stays cheap.
 *  Bounded to ~5 years to reject impossible expressions (e.g. `0 0 30 2 *`). */
function nextCronDate(f: CronFields, from: Date, utc: boolean): Date {
  const d = new Date(from.getTime());
  if (utc) {
    d.setUTCSeconds(0, 0);
    d.setUTCMinutes(d.getUTCMinutes() + 1);
  } else {
    d.setSeconds(0, 0);
    d.setMinutes(d.getMinutes() + 1);
  }
  const limit = new Date(from.getTime());
  if (utc) limit.setUTCFullYear(limit.getUTCFullYear() + 5);
  else limit.setFullYear(limit.getFullYear() + 5);

  while (d.getTime() <= limit.getTime()) {
    if (!f.month.has(get.month(d, utc))) {
      // Jump to the first day of next month at 00:00.
      if (utc) {
        d.setUTCMonth(d.getUTCMonth() + 1, 1);
        d.setUTCHours(0, 0, 0, 0);
      } else {
        d.setMonth(d.getMonth() + 1, 1);
        d.setHours(0, 0, 0, 0);
      }
      continue;
    }
    if (!dayMatches(f, d, utc)) {
      if (utc) {
        d.setUTCDate(d.getUTCDate() + 1);
        d.setUTCHours(0, 0, 0, 0);
      } else {
        d.setDate(d.getDate() + 1);
        d.setHours(0, 0, 0, 0);
      }
      continue;
    }
    if (!f.hour.has(get.hour(d, utc))) {
      if (utc) {
        d.setUTCHours(d.getUTCHours() + 1, 0, 0, 0);
      } else {
        d.setHours(d.getHours() + 1, 0, 0, 0);
      }
      continue;
    }
    if (!f.minute.has(get.minute(d, utc))) {
      if (utc) d.setUTCMinutes(d.getUTCMinutes() + 1);
      else d.setMinutes(d.getMinutes() + 1);
      continue;
    }
    return d;
  }
  throw new Error("cron: no matching time within 5 years (impossible schedule?)");
}

/** Cron's day-matching OR rule: when both day-of-month and day-of-week are
 *  restricted, either matching is enough; a `*` field defers to the other. */
function dayMatches(f: CronFields, date: Date, utc: boolean): boolean {
  const domOk = f.dom.has(get.dom(date, utc));
  const dowOk = f.dow.has(get.dow(date, utc));
  if (f.domStar && f.dowStar) return true;
  if (f.domStar) return dowOk;
  if (f.dowStar) return domOk;
  return domOk || dowOk;
}
