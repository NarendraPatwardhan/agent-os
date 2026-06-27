import { BRIDGE_IMPORTS } from "@mc/contracts/env";
import type { Mem } from "./memory.js";
import type { HostCallCapability } from "./host_call.js";
import type {
  StreamSink,
  ClockSource,
  RngSource,
  NetCapability,
  PersistCapability,
} from "./types.js";

/** Mutable host state shared by every bridge function — the analogue of the Rust/wasmtime host's
 *  `HostState`. `mem` is assigned right after instantiation, before `mc_init` runs (which is the first
 *  thing to touch memory). */
export interface HostState {
  mem: Mem;
  baseImage: Uint8Array | null;
  /** The image manifest's runtime contract, served via `mc_boot_contract`: tier ordinal
   *  (0=inherit / 1=full / 2=rw / 3=ro / 4=isolated), memory ceiling MiB (≤0 unset), fuel ceiling
   *  (≤0 unset). */
  bootTier: number;
  bootBudgetMib: number;
  bootBudgetFuel: number;
  stdout: StreamSink;
  stderr: StreamSink;
  log: StreamSink;
  clock: ClockSource;
  rng: RngSource;
  net: NetCapability;
  persist: PersistCapability;
  /** Host-call capability — the host side of `mc_sys_host_call`. */
  hostCall: HostCallCapability;
  /** Total bytes written to any stream — the idle-detection signal. */
  bytesWritten: number;
  /** Last two stdout bytes, for `"$ "` prompt detection. */
  stdoutTail: [number, number];
  /** Set by `mc_exit`; the host stops ticking once present. */
  exitCode: number | null;
  /** Worker count the builder advertised (0 = cooperative). */
  workers: number;
  /** Count the kernel actually negotiated via `mc_threads_init`. */
  workersGranted: number;
}

const LOG_PREFIX: Record<number, string> = {
  0: "[DEBUG] ",
  1: "[INFO] ",
  2: "[WARN] ",
  3: "[ERROR] ",
};

/** Build the `env` import object — one handler per row the kernel imports. Return codes and memory
 *  layout match the Rust host exactly (A3).
 *
 *  Descriptor-driven (B2): the set of imports is NOT a hand-maintained list here — it is the generated
 *  `BRIDGE_IMPORTS` (memcontainers/contracts/gen/env.gen.ts), the same table the Rust kernel's
 *  dispatch and the Rust host's `register_bridge` derive from. [`assertBridgeComplete`] checks the
 *  handler set against it both ways, so a contract change that adds an `env` import makes the JS host
 *  throw at startup until a handler exists (the analog of the kernel's exhaustive `match`), and a
 *  stray/typo'd handler is rejected too. The boundary cannot silently desync. */
export function makeBridge(st: HostState): WebAssembly.ModuleImports {
  const enc = new TextEncoder();

  const trackStdout = (bytes: Uint8Array): void => {
    st.bytesWritten += bytes.length;
    const tail = bytes.subarray(Math.max(0, bytes.length - 2));
    for (const b of tail) st.stdoutTail = [st.stdoutTail[1], b];
  };

  /** Drain a capability that writes into a host-side temp buffer, then copy the written prefix into
   *  guest memory at `buf` — the pattern shared by http_poll/http_body/ws_recv/host_call_body/
   *  persist_body. */
  const drainInto = (
    buf: number,
    cap: number,
    call: (tmp: Uint8Array) => number,
  ): number => {
    if (!st.mem.canAccess(buf, cap)) return -1;
    const tmp = new Uint8Array(cap);
    const n = call(tmp);
    if (n > 0) st.mem.write(buf, tmp.subarray(0, Math.min(n, cap)));
    return n;
  };

  const readOrNull = (ptr: number, len: number): Uint8Array | null => st.mem.tryRead(ptr, len);
  const readOrEmpty = (ptr: number, len: number): Uint8Array => readOrNull(ptr, len) ?? new Uint8Array(0);

  const env: Record<string, WebAssembly.ImportValue> = {
    // ---- terminal I/O ------------------------------------------------------
    mc_stdout_write: (ptr: number, len: number) => {
      const bytes = readOrNull(ptr, len);
      if (!bytes) return;
      trackStdout(bytes);
      st.stdout.write(bytes);
    },
    mc_stderr_write: (ptr: number, len: number) => {
      const bytes = readOrNull(ptr, len);
      if (bytes) st.stderr.write(bytes);
    },
    mc_stdin_read: (_buf: number, _len: number): number => 0, // push-model input

    // ---- time --------------------------------------------------------------
    mc_time_now: (): bigint => st.clock.nowMillis(),
    mc_time_monotonic: (): bigint => st.clock.monotonicMillis(),

    // ---- randomness --------------------------------------------------------
    mc_random: (ptr: number, len: number) => {
      if (!st.mem.canAccess(ptr, len)) return;
      const buf = new Uint8Array(len);
      st.rng.fill(buf);
      st.mem.write(ptr, buf);
    },

    // ---- HTTP (poll-based) -------------------------------------------------
    mc_http_request: (ptr: number, len: number): number => {
      const req = readOrNull(ptr, len);
      return req ? st.net.httpRequest(req) : -1;
    },
    mc_http_response_poll: (h: number, buf: number, len: number): number =>
      drainInto(buf, len, (tmp) => st.net.httpPoll(h, tmp)),
    mc_http_response_body: (h: number, buf: number, len: number): number =>
      drainInto(buf, len, (tmp) => st.net.httpBody(h, tmp)),
    mc_http_request_close: (h: number) => st.net.httpClose(h),

    // ---- WebSocket ---------------------------------------------------------
    mc_ws_connect: (ptr: number, len: number): number => {
      const url = readOrNull(ptr, len);
      return url ? st.net.wsConnect(new TextDecoder().decode(url)) : -1;
    },
    mc_ws_send: (h: number, ptr: number, len: number): number => {
      const data = readOrNull(ptr, len);
      return data ? st.net.wsSend(h, data) : -1;
    },
    mc_ws_ready: (h: number): number => st.net.wsReady(h),
    mc_ws_recv: (h: number, buf: number, len: number): number =>
      drainInto(buf, len, (tmp) => st.net.wsRecv(h, tmp)),
    mc_ws_close: (h: number) => st.net.wsClose(h),

    // ---- host call ---------------------------------------------------------
    mc_host_call: (ptr: number, len: number): number => {
      const req = readOrNull(ptr, len);
      return req ? st.hostCall.start(req) : -1;
    },
    mc_host_call_poll: (h: number, _buf: number, _len: number): number => st.hostCall.poll(h),
    mc_host_call_body: (h: number, buf: number, len: number): number =>
      drainInto(buf, len, (tmp) => st.hostCall.body(h, tmp)),
    mc_host_call_close: (h: number) => st.hostCall.close(h),

    // ---- persistence -------------------------------------------------------
    mc_persist_start: (ptr: number, len: number): number => {
      const req = readOrNull(ptr, len);
      return req ? st.persist.start(req) : -1;
    },
    mc_persist_poll: (h: number): number => st.persist.poll(h),
    mc_persist_body: (h: number, buf: number, len: number): number =>
      drainInto(buf, len, (tmp) => st.persist.body(h, tmp)),
    mc_persist_close: (h: number) => st.persist.close(h),

    // ---- threading (cooperative-backed) ------------------------------------
    mc_threads_init: (max: number): number => {
      const granted = Math.max(0, Math.min(st.workers, Math.max(0, max)));
      st.workersGranted = granted;
      return granted;
    },
    mc_thread_spawn: (_entry: number, _arg: number): number => -1,
    mc_thread_park: (_timeout: number): number => 0,
    mc_thread_unpark: (_handle: number) => {},

    // ---- control -----------------------------------------------------------
    mc_yield: () => {},
    mc_exit: (code: number) => {
      st.exitCode = code; // recorded; the host stops on the next tick
    },
    mc_log: (level: number, ptr: number, len: number) => {
      const prefix = LOG_PREFIX[level] ?? "[LOG] ";
      const body = readOrEmpty(ptr, len);
      const needsNl = body.length === 0 || body[body.length - 1] !== 0x0a;
      const prefixBytes = enc.encode(prefix);
      const line = new Uint8Array(prefixBytes.length + body.length + (needsNl ? 1 : 0));
      line.set(prefixBytes, 0);
      line.set(body, prefixBytes.length);
      if (needsNl) line[line.length - 1] = 0x0a;
      st.bytesWritten += line.length;
      st.log.write(line);
    },

    // ---- base image --------------------------------------------------------
    mc_load_base_image: (buf: number, bufLen: number): number => {
      if (!st.baseImage) return -1;
      if (!st.mem.canAccess(buf, bufLen)) return -1;
      const toCopy = Math.min(st.baseImage.length, bufLen);
      if (toCopy > 0 && !st.mem.write(buf, st.baseImage.subarray(0, toCopy))) return -1;
      // Return the FULL image length (not just what fit): the kernel probes with a zero-length read to
      // size its buffer, then reads the whole image. Returning only what fit would silently truncate.
      return st.baseImage.length;
    },

    // The image manifest's runtime contract: `[i32 tier][i32 mem_mib][i64 fuel]` (LE, 16 bytes).
    // `0` ⇒ no contract.
    mc_boot_contract: (buf: number, bufLen: number): number => {
      if (st.bootTier === 0 && st.bootBudgetMib <= 0 && st.bootBudgetFuel <= 0) return 0;
      if (bufLen < 16) return -1;
      const out = new Uint8Array(16);
      const dv = new DataView(out.buffer);
      dv.setInt32(0, st.bootTier, true);
      dv.setInt32(4, st.bootBudgetMib, true);
      dv.setBigInt64(8, BigInt(st.bootBudgetFuel), true);
      return st.mem.write(buf, out) ? 16 : -1;
    },
  };

  assertBridgeComplete(env);
  return env;
}

/** The boundary check (B2): the handler set in [`makeBridge`] must equal the generated
 *  `BRIDGE_IMPORTS` exactly — no missing handler (a contract import the host forgot) and no stray one
 *  (a typo or a removed import). Either is a hard startup error, never a silent mismatch the kernel
 *  discovers at instantiation as a dangling import. */
function assertBridgeComplete(env: Record<string, unknown>): void {
  const declared = new Set<string>(BRIDGE_IMPORTS);
  for (const name of declared) {
    if (typeof env[name] !== "function") {
      throw new Error(
        `env bridge: no handler for declared import "${name}" — a contract change added an env ` +
          `import the JS host hasn't implemented (the analog of the kernel's exhaustive match).`,
      );
    }
  }
  for (const name of Object.keys(env)) {
    if (!declared.has(name)) {
      throw new Error(
        `env bridge: handler "${name}" is not a declared import (contracts/gen/env.gen.ts) — ` +
          `remove it or fix the name.`,
      );
    }
  }
}
