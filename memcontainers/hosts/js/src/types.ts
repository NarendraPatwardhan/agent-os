// The pluggable capability interfaces the host composes — a 1:1 mirror of the Rust/wasmtime host's
// traits (`StreamSink`, `ClockSource`, `RngSource`, `NetCapability`, `PersistCapability` in
// memcontainers/hosts/wasmtime/src/lib.rs). Keeping the same shape lets the JS host swap
// implementations the same way the native builder does, and is what makes the two hosts behave
// identically (A3).

/** A sink for kernel stdout/stderr/log bytes (mirrors Rust `StreamSink`). */
export interface StreamSink {
  write(bytes: Uint8Array): void;
}

/** Wall-clock + monotonic time in milliseconds (mirrors Rust `ClockSource`).
 *  Returns `bigint` because the bridge functions are wasm `i64`. */
export interface ClockSource {
  nowMillis(): bigint;
  monotonicMillis(): bigint;
}

/** Fills a buffer with random bytes (mirrors Rust `RngSource`). */
export interface RngSource {
  fill(buf: Uint8Array): void;
}

/** The poll-based network capability (mirrors Rust `NetCapability`). All return codes match the
 *  `env` bridge contract (memcontainers/contracts/bridge.kdl, the http_ and ws_ rows). */
export interface NetCapability {
  /** Start a request from the `METHOD URL\n<headers>\n\n<body>` blob; returns a
   *  handle ≥ 1, or -1 to refuse. */
  httpRequest(req: Uint8Array): number;
  /** 0 while in flight; once ready, write the head and return its length; -1 on
   *  transport failure. */
  httpPoll(handle: number, buf: Uint8Array): number;
  /** Body bytes (> 0), 0 = EOF/not-ready, -1 = error. */
  httpBody(handle: number, buf: Uint8Array): number;
  httpClose(handle: number): void;
  /** Connect; returns a handle ≥ 1 or -1. */
  wsConnect(url: string): number;
  /** Bytes queued, or -1 if closed. */
  wsSend(handle: number, data: Uint8Array): number;
  /** Bytes read (> 0), 0 = none pending, -1 = closed. */
  wsRecv(handle: number, buf: Uint8Array): number;
  wsClose(handle: number): void;
}

/** Host-side key/value store behind `/var/persist` (mirrors Rust `PersistCapability`). Return codes
 *  match the bridge contract (the persist_* rows). */
export interface PersistCapability {
  /** -1 denied/error, -2 not-found, else the FULL value length (writes
   *  min(n, out.length)). */
  get(key: Uint8Array, out: Uint8Array): number;
  /** -1 denied/error, ≥ 0 ok. */
  put(key: Uint8Array, val: Uint8Array): number;
  /** -1 denied/error, 0 ok (missing key is ok). */
  delete(key: Uint8Array): number;
  /** -1 denied/error, else the FULL byte length of NUL-separated sorted keys. */
  list(prefix: Uint8Array, out: Uint8Array): number;
}
