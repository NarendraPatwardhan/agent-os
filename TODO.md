# TODO

System-design follow-ups surfaced by the JavaScript host / `@mc/core` port (commit `79fea3c`) and the
Codex review of it. **All are now resolved** — `bazel test //...` is green (47 tests). Kept for
provenance; items reference the invariants in `SYSTEMS.md` §2.2.

---

## Resolved

- **Kernel-metered egress backpressure (was §1) — A1/A3/B5.** The host-side WebSocket send buffer is
  gone. `mc_ws_send` now reports true acceptance — `len` (whole message accepted) / `-EMSGSIZE`
  (oversized beyond the host window; permanent, do not retry) / `-EAGAIN` (would-block, retry; the host
  buffers nothing) / `-1` (closed) — and a new contracted `mc_ws_ready` import lets the kernel gate a
  parked write (the write-side dual of how `recv` probes the read side). A guest write
  that can't be accepted PARKS — its unsent message staying in the guest's own linear memory (B5) — and
  re-drives via the existing scheduler requeue, exactly like a parked read; POLLOUT is gated on real
  writability instead of the old "always writable" lie (`kernel/rust/src/{net/mod.rs,wasm/mod.rs}`,
  `fs/netfs.rs`). Both hosts emit the IDENTICAL contract (A3) and hold at most a bounded flow-control
  window — JS via the browser's `bufferedAmount`, wasmtime via a relay queue, both capped at
  `WS_SEND_MARK` — and a single accepted message can't cross the mark (`hold + len <= mark`), so the
  host hold is strictly bounded, never unbounded heap (A1). `bazel test //...` stays green (the contract
  diff-gates, compilation, and the non-WS e2e/parity); the WS backpressure itself is verified
  structurally as the dual of the in-production read path — the e2e has no WS-capable guest, so a true
  end-to-end WS-flood boot remains the one open hardening gap. The wasmtime host's send sentinels come
  from generated constants (B2). This replaced the removed host-side cap with the proper kernel +
  contract design.
- **Cross-host snapshot parity test (was §2) — A3/A8.** `//memcontainers/hosts/wasmtime:snapshot_fixture`
  (a `rust_binary` over the `host` lib) boots the kernel under the wasmtime host, writes a marker through
  the control channel, and snapshots; a `genrule` runs it over the same kernel + base the e2e boots (B1)
  to produce `cross_host_snapshot.bin`; `//memcontainers/hosts/js:cross_host_test` rehydrates that
  snapshot under the JS host and asserts the marker + a live `exec` survive. The "MCSN is byte-identical
  across hosts" claim is now executable proof, not by-construction.
- **Mount serve-stat layout dedup (was §3) — B2.** The 44-byte record's field offsets + length now live
  once in `contracts/constants.kdl` (the `stat-record` group → `STAT_REC_*`), consumed by both the kernel
  decoder (`kernel/rust/src/fs/proxy.rs`) and the JS encoder (`sdk-js/core/src/mount.ts`); the kernel's
  node-type match also uses the generated `SERVE_DIRENT_*`. No more hand-kept byte layout.
- **Control-export bindings from `EXPORTS` (was §4) — B2.** The JS host's `KernelExports` type is now
  DERIVED from the generated `EXPORTS` rows (`hosts/js/src/host.ts`) — no hand-written ABI, no
  `HOST_KNOWN_EXPORTS` list — and `checkControlExports` validates the booted kernel's actual export
  arities against the contract at startup. Symmetric with the bridge's import-completeness check.
