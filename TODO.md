# TODO

System-design follow-ups surfaced by the JavaScript host / `@mc/core` port (commit `79fea3c`) and the
Codex review of it. None is a bug in the committed port — `bazel test //...` is green. Items reference
the invariants in `SYSTEMS.md` §2.2.

---

## 1. Kernel-metered egress backpressure (the right home for the removed WS queue cap)

**Why this exists.** A browser `WebSocket` opens asynchronously, so the JS host must buffer
`mc_ws_send` bytes that arrive before the socket is OPEN and flush them in `onopen` (`hosts/js/src/net.ts`).
The wasmtime host has no such async window. A host-side cap on that buffer was added during the port and
then **removed**, because it:
- put resource *policy* in the host — SYSTEMS.md is explicit that the host is "a driver, not a
  participant… it performs effects and never makes policy";
- diverged the two hosts (broke **A3** — same `kernel.wasm`, identical behavior); and
- overloaded `-1` (which already means *socket closed* in the net bridge) to mean *queue full*, so a
  guest misread backpressure as a dead connection.

**The gap it leaves.** A contained guest that floods a never-opening socket can grow the **host's** heap
without bound — and the host is the *uncontained* side (**A1**: the guest must not reach out and harm us).

**The fix (kernel + contract, mirrored in both hosts):**
- Bound egress buffering in the **kernel**, against the guest's own (accounted, snapshot-safe) linear
  memory and per-guest budget (**B5**). The kernel already tracks `mc_inflight_egress`, so the resource
  awareness is in the right place.
- Add a distinct, contracted **backpressure return code** — a "would-block / queue-full" value, NOT
  `-1` (= closed) — to the net bridge in `contracts/bridge.kdl`, projected to every host. The guest then
  sees a real "retry later" and blocks/retries, the poll-based pattern the net bridge already uses.
- Implement it identically in `hosts/wasmtime` and `hosts/js` so behavior stays host-identical (**A3**),
  and the bytes live in bounded *kernel* memory rather than unbounded *host* memory.

---

## Resolved

Solved after the Codex review (suite green at 47 tests); kept here for provenance.

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
