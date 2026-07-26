# AgentOS performance work

This is the implementation backlog for making AgentOS materially faster, smaller, and cheaper in
the operations customers experience. The benchmark suite is the proof mechanism for this work, not
the product objective.

The priorities are:

1. remove avoidable latency from every command;
2. turn snapshots and forks into cheap state operations;
3. preserve compiled and warmed work across machines;
4. reduce browser and hosted overhead;
5. demonstrate each improvement with repeatable p50 and p95 measurements.

This backlog contains implementation work only. Comparisons with other products are not in scope
until they are separately approved.

## What the current results tell us

The existing results expose several concrete system costs:

- Native and JavaScript command drivers pause for one millisecond after every busy tick. A short
  command needs several ticks, so scheduler pacing can add several milliseconds to work that should
  complete almost immediately.
- Every string command creates a new `/bin/sh -c` process. External programs then create another
  guest task and another nested Wasm runtime instance. Simple structured execution pays for shell
  parsing and process construction that it does not need.
- Full snapshots hash and copy the complete linear memory. Incremental snapshots still scan and
  hash the baseline and current memory page by page. A small mutation therefore remains
  proportional to total machine memory.
- The current local fork operation is full snapshot plus full restore. It produces an independent
  machine, but it does not exploit shared immutable state or copy-on-write pages.
- Server-side fork transfers a complete snapshot through the control plane before creating the
  child.
- Large branch populations are created and exercised sequentially. They also duplicate enough
  resident memory to force a normal development host into memory pressure at the 1,000-machine
  scale.
- Browser construction retains a full boot snapshot even when the caller never requests
  incremental snapshots. The renderer also carries the JavaScript module graph, compiled kernel,
  linear memory, artifacts, and snapshot buffers.
- Hosted operations use separate request/response paths and transfer snapshot bytes where stable
  server-side state references would suffice.
- Resident service warm-up is valuable today. Prewarmed Typst restores have reduced first execution
  from seconds to hundreds of milliseconds, and restored SQLite is several times faster than its
  first operation. The product should make this the normal path rather than leave it as benchmark
  knowledge.

Some measurements currently obscure rather than explain system behavior:

- repeated `true` latency drifts upward during a run;
- the resident SQLite workload changes database state on every iteration;
- cancellation can be requested before the guest command has actually started;
- active-memory RSS can be sampled before the long-running command has actually executed;
- different runner lanes can consume different transitioned image artifacts.

Those measurement defects must be corrected as acceptance gates for the related implementation
work. They are not substitutes for fixing the underlying system.

## P0: remove command-path latency

### PERF-001 — Drive runnable work without a fixed sleep

**Problem**

The native host sleeps for one millisecond after every unsuccessful execution poll. The JavaScript
embedded backend does the same while the machine reports itself busy. Short commands commonly need
multiple ticks, so fixed pacing becomes a substantial part of their observed latency.

**Implementation**

- Add one generated kernel work-state result that distinguishes immediately runnable work from work
  waiting on the host; keep kernel exit on its existing bridge event.
- Distinguish a productive fuel slice from a poll dependency inside the scheduler.
- While runnable work exists, drive bounded ticks back-to-back. In JavaScript, yield one macrotask
  after a shared 64-tick burst so cancellation and browser I/O remain responsive.
- Pace only waiting work, and poll the requested result immediately after every tick so completion
  never inherits a trailing sleep.
- Use the same scheduling contract in:
  - the Rust Wasmtime host;
  - the JavaScript embedded backend;
  - the OTP/NIF execution driver;
  - server-side resident-machine execution.
- Remove the old boolean tick API and any scheduler helper that conflates blocked work with runnable
  work.

**Primary paths**

- `memcontainers/kernel/rust/`
- `memcontainers/hosts/wasmtime/src/lib.rs`
- `memcontainers/sdk-js/core/src/embedded.ts`
- the OTP/NIF VM execution loop

**Acceptance**

- Shell builtins, external commands, and pipelines produce identical exit status, stdout, and
  stderr before and after the change.
- Cancellation and host-egress wakeups remain responsive at p95.
- Standard-profile p50 and p95 improve for `true`, external coreutils, and the three-stage pipeline
  in native, JavaScript, browser, and OTP lanes.
- An idle machine consumes no busy-loop CPU.

**Status**

Implemented across the kernel, generated contract, Rust/Wasmtime, JavaScript/browser SDK, and
OTP/NIF paths. The old boolean tick result and obsolete `has_work`/`blocked_count` scheduler path
have been removed. Native, JavaScript, and OTP standard populations improved at both p50 and p95;
the browser runtime correctness gate passes. Chromium performance population measurement remains
part of the next controlled benchmark run.

### PERF-002 — Extend structured execution with a direct argv mode

**Problem**

The guest syscall boundary already supports argv-aware process creation through `mc_sys_spawn`, while
host control previously exposed only a shell command string. That forced even a known executable through
shell parsing, expansion, and an extra task. Customers invoking a known executable should be able to
express literal argv directly while retaining the same cwd, environment, stdin, capture, cancellation,
and capability behavior.

**Implementation**

- Replace the old request with `ExecRequest` v2: a required shell/direct discriminator, optional shell
  command, required argv list, and no compatibility decoder or implicit mode.
- Reuse the kernel's existing argv-aware program loading, task creation, capability narrowing, and
  standard-stream machinery; do not introduce a second process implementation.
- Expose `run(program, args, options)` or an equivalent structured form in every SDK.
- Carry environment, cwd, stdin, timeout, and cancellation through the existing structured request
  without serializing them into shell syntax.
- Start external programs directly from the structured request.
- Preserve the current string-command API for pipes, redirections, expansions, and interactive shell
  behavior.
- Route SDK operations that already possess structured arguments through the new path.

**Primary paths**

- kernel control ABI and contracts
- `memcontainers/sdk-js/core/src/memcontainer.ts`
- `memcontainers/sdk-js/core/src/embedded.ts`
- `memcontainers/sdk-js/core/src/remote.ts`
- native and OTP host bindings

**Acceptance**

- Direct execution does not instantiate `/bin/sh`.
- Argument boundaries, empty arguments, cwd, environment, stdin, stdout, stderr, exit status, tick
  budget, and cancellation have end-to-end tests. Text APIs reject embedded NUL and malformed UTF-8
  instead of silently changing argv.
- String shell execution retains its existing behavior.
- Native and hosted benchmark lanes report direct execution separately from shell syntax execution.
- Direct external execution is faster at both p50 and p95 than running that same external program
  through shell command syntax. `exec.direct_minimal.steady` separately reports the smallest direct
  executable path; it is not compared with the resident shell's builtin `true`.

**Status**

Implemented as the single `exec(command, options)` shell API and `run(program, args, options)` direct
API across the control contract, kernel, Wasmtime, JavaScript/browser, remote transport, OTP/NIF, LLB
authoring/serialization/replay, and mutation recording. There is no compatibility decoder or alias.
Native E2E coverage exercises exact and empty arguments, cwd, environment, binary
stdin, stdout/stderr, exit status, tick budget, and cancellation. Contract, browser runtime, server,
LLB replay, and benchmark smoke gates pass. A 30-sample standard browser population also confirms
that direct external execution improves both p50 and p95 over the equivalent shell-mediated external
execution.

### PERF-003 — Keep a resident shell execution context

**Problem**

Commands that genuinely need shell semantics still reconstruct parser and process state for every
request. Repeated shell use should preserve the expensive immutable portion of the shell while
isolating command-local state.

**Implementation**

- Separate reusable parser/module state from per-command file descriptors, environment overlays,
  traps, and exit status.
- Reuse the shell runtime for independent non-interactive commands.
- Reset command-local state deterministically after completion or failure.
- Keep session shells as a distinct stateful mode.
- Make the resident context reconstructible after snapshot restore.

**Acceptance**

- Shell conformance tests produce the same result with resident execution enabled and disabled.
- State that must not leak between independent calls is covered explicitly.
- Repeated shell, expansion, redirection, and pipeline latency improve at p50 and p95.
- A failed or cancelled command cannot poison the next command.

### PERF-004 — Make prewarmed images a product primitive

**Problem**

The current measurements show that restoring a warmed SQLite or Typst machine is dramatically faster
than paying first-use compilation and initialization. Customers should receive that benefit by
default for shipped images.

**Implementation**

- Produce versioned golden templates for images with expensive resident services, initially Atlas
  and Paper.
- Warm the exact service modules, initialize their registries, quiesce the machine, and capture a
  deterministic template during the Bazel release build.
- Bind each template to the kernel and image artifact digests that created it.
- Restore from the template when constructing a compatible machine.
- Fall back safely to ordinary boot when no matching template exists.
- Keep runtime credentials, mounts, connections, and customer data outside the golden template and
  attach them after restore.

**Acceptance**

- Golden templates are reproducible from release inputs and rejected on digest mismatch.
- A restored template passes all ordinary boot and service tests.
- Atlas SQLite and Paper Typst first customer operations achieve restored-warm latency without an
  explicit customer warm-up step.
- Template restore improves both p50 and p95 construction-to-first-use latency.

## P1: make state and branching cheap

### PERF-005 — Build a one-pass full snapshot pipeline

**Problem**

Full snapshot creation repeatedly touches linear memory: it computes digests, allocates a complete
output, and copies the full memory image. This consumes memory bandwidth and temporarily duplicates
the machine footprint.

**Implementation**

- Encode snapshot headers and memory into a single output pipeline.
- Compute required digests while copying rather than in separate full-memory passes.
- Reuse capacity from a buffer pool for repeated snapshots.
- Support streaming to a content store so callers need not materialize an additional complete copy.
- Use the fastest available SHA-256 implementation on the host and validate hardware acceleration
  in release builds.

**Acceptance**

- Snapshot bytes remain format-compatible unless a separately versioned format change is required.
- Peak temporary memory during snapshot creation is measured and reduced.
- Full snapshot p50 and p95 latency and allocation volume improve for Minimal, Posix, Atlas, and
  Paper.
- Restore and corruption checks continue to validate the complete state.

### PERF-006 — Track dirty pages instead of scanning all memory

**Problem**

Incremental snapshot time remains proportional to total memory because the host scans and hashes
every page of the current image and its baseline. A four-kilobyte mutation should not require
hundreds of milliseconds of whole-memory work.

**Implementation**

- Introduce page-level dirty tracking at the Wasm memory boundary.
- Maintain cached baseline digest and per-page hashes with the live machine.
- Encode an incremental page manifest containing only changed or newly grown pages.
- Clear or advance the dirty set only after a successful snapshot commit.
- Define behavior for memory growth, restored incrementals, forked children, failed snapshot writes,
  and concurrent host writes.
- Use the same logical format and integrity rules in native and browser hosts.

**Acceptance**

- Incremental snapshot time scales primarily with changed pages, not total linear-memory size.
- A 4 KiB mutation in a large image is materially faster and smaller than a full snapshot at p50 and
  p95.
- Randomized mutation/restore tests compare every restored byte with the source machine.
- Interrupted or rejected incremental snapshots cannot lose dirty state.

### PERF-007 — Separate portable snapshots from local fork

**Problem**

Portable snapshot export and same-host machine creation have different needs. Implementing local
fork as serialize-all plus restore-all makes branch latency and memory proportional to the complete
machine state.

**Implementation**

- Keep the portable snapshot API for durable transfer and storage.
- Add a local template/fork API backed by immutable shared pages and copy-on-write mutable pages.
- Share compiled kernel and guest module code across children.
- Delay materializing private pages until a child writes them.
- Reuse initialized host structures from an instance pool where safe.
- Give local state handles explicit ownership, lifetime, quota, and invalidation semantics.
- Ensure a child can outlive its parent and can later be exported as a portable snapshot.

**Acceptance**

- Parent and child are behaviorally independent after either one mutates memory, filesystem state,
  services, or process state.
- Local fork p50 and p95 are substantially below snapshot-plus-restore.
- Retained idle children consume memory in proportion to dirty/private state rather than the full
  template.
- Portable snapshot compatibility and deterministic replay remain intact.

### PERF-008 — Keep snapshot and template data inside the server

**Problem**

The control plane currently obtains a full snapshot binary and passes it back into child creation.
This copies large state through BEAM and prevents the runtime from exploiting same-node shared
memory.

**Implementation**

- Add opaque server-side snapshot and template handles.
- Fork a child directly from a handle on the owning runtime.
- Store large portable blobs in the content store without routing them through a GenServer process.
- Return bytes only when the caller explicitly exports a snapshot.
- Pin or route dependent operations to the node that owns local state, with an explicit migration
  path through portable snapshots.
- Account handles against tenant quotas and release them deterministically.

**Acceptance**

- Ordinary server fork does not copy the complete snapshot through BEAM.
- Handle ownership, expiry, node loss, quota exhaustion, and explicit export have end-to-end tests.
- Server fork and restore improve at p50 and p95.
- BEAM binary memory remains bounded during large branch creation.

### PERF-009 — Create and exercise branch populations concurrently

**Problem**

The current large-population path restores and executes every machine sequentially. That measures a
serial harness and magnifies memory pressure instead of demonstrating useful aggregate capacity.

**Implementation**

- Create branches through a bounded worker pool.
- Execute population workloads with configurable bounded concurrency.
- Stream completion and failure accounting instead of retaining unnecessary per-operation buffers.
- Combine this with local copy-on-write templates so immutable pages are shared.
- Apply backpressure before the host enters swap or allocation failure.
- Expose branch throughput, time-to-ready, active command throughput, queue depth, and rejected work.

**Acceptance**

- The implementation retains exactly the requested number of independent machines.
- Concurrency limits are honored and overload produces explicit errors rather than host collapse.
- A 1,000-branch standard run completes without swap-induced multi-second command latency on the
  documented benchmark class of host.
- Total creation time, p50 and p95 per-branch readiness, aggregate command rate, and memory are
  captured.

## P2: preserve compiled work and reduce deployment overhead

### PERF-010 — Reuse or pretranslate nested guest modules

**Problem**

External programs and resident services run through the kernel's nested Wasm runtime. Eager
translation avoids a known lazy-translation correctness issue but makes first use expensive. The
in-kernel cache helps only after the cost has already been paid within that machine.

**Implementation**

- Evaluate the current `wasmi` release against the lazy-translation failure that forced eager mode.
- If corrected, enable and verify lazy translation.
- Otherwise pretranslate shipped guest modules during the release build into a versioned,
  reconstructible representation.
- Share immutable translated module data across machines where the host architecture permits it.
- Persist only stable cache identity in portable snapshots; reconstruct process-local pointers and
  runtime objects after restore.
- Bound the cache and expose hit, miss, translation-time, and retained-byte metrics.

**Acceptance**

- The historical lazy-translation failure has a permanent regression test.
- First external command and first resident-service operation improve at p50 and p95.
- Warm performance does not regress.
- A corrupted, incompatible, or stale translated artifact is rejected and rebuilt safely.

### PERF-011 — Share browser compilation and runtime infrastructure

**Problem**

One browser VM currently adds the renderer, JavaScript SDK graph, compiled kernel, linear memory,
image artifacts, and retained snapshot buffers. Repeated VM construction can duplicate immutable
work.

**Implementation**

- Cache `WebAssembly.Module` objects once per kernel digest.
- Reuse a bounded pool of runtime workers where isolation permits it.
- Share immutable image and template buffers across machines.
- Do not capture or retain a full boot snapshot unless incremental snapshots or local fork require
  it.
- Retain baseline digest and page metadata lazily.
- Transfer buffer ownership between workers instead of copying large `ArrayBuffer` values.
- Audit linear-memory initial size and growth policy per image.
- Release disposed workers, memories, snapshots, and object URLs promptly.

**Acceptance**

- Creating additional compatible machines does not recompile the kernel.
- A VM that never snapshots does not retain an unused full boot snapshot.
- Browser startup, first command, idle VM memory, and incremental per-VM memory improve at p50 and
  p95.
- Disposal returns memory close to the pre-VM renderer baseline after garbage collection settles.
- Multi-VM isolation and cancellation tests pass.

### PERF-012 — Use one efficient hosted execution channel

**Problem**

Hosted lifecycle, execution, filesystem, and snapshot operations use separate request paths.
Snapshot-based operations transfer state bytes even when both operations occur inside the AgentOS
service.

**Implementation**

- Use a multiplexed WebSocket or equivalent persistent binary transport for lifecycle, exec,
  streaming I/O, structured filesystem calls, cancellation, and service operations.
- Reference snapshots and templates by content or server-local handle instead of uploading and
  downloading bytes for every operation.
- Route a warm machine to its owning node.
- Prewarm machine pools for common images and replenish them asynchronously.
- Add a batched short-episode operation for customers running many small independent jobs.
- Preserve idempotency and replay-safe request identifiers across reconnects.

**Acceptance**

- A normal same-service fork transfers no snapshot body over the client connection.
- Hosted execution supports streamed stdout/stderr and prompt cancellation without polling.
- Warm create, first command, repeated command, fork, and batched-episode p50 and p95 improve.
- Reconnect, duplicate request, partial frame, node loss, and cancellation behavior have end-to-end
  coverage.

## P3: prove the system improvements

These tasks are required to know whether the engineering work above succeeded. They should be done
alongside the relevant implementation, not treated as a documentation project.

### PERF-013 — Explain command latency with runtime instrumentation

- Record kernel ticks, runnable batches, host yields, timer waits, I/O waits, tasks created, pipes
  created, nested module cache hits/misses, linear-memory length, and per-command allocations.
- Record host CPU frequency, governor, thermal throttling, major faults, and swap activity as run
  metadata.
- Correlate the first, middle, and last portions of long sample populations.
- Investigate and eliminate the observed rise in repeated `true` latency across a run.
- Keep instrumentation cheap enough to disable or sample in production.

**Done when:** the remaining p50/p95 cost of a shell builtin, direct external command, shell
pipeline, and resident service can be attributed to measured stages rather than inferred from wall
time.

### PERF-014 — Measure equivalent cold and warm workloads

- Explicitly warm the exact command, module, filesystem size, and service operation before recording
  a warm population.
- Interleave fresh-machine and retained-machine samples when comparing cold and warm paths so host
  drift does not become a temperature effect.
- Use non-mutating queries for repeated SQLite latency, or restore identical database state before
  every mutating observation.
- Report first, warm, and restored-warm only when command, input, database state, image digest, and
  runner artifact are equivalent.
- Retain raw sample order and p50/p95 summaries.

**Done when:** a warm/cold inversion either disappears or is explained by stage-level telemetry and
reproduces under an interleaved run.

### PERF-015 — Use identical release artifacts across lanes

- Resolve every image and kernel through one release manifest.
- Record and compare the SHA-256 digest and byte size used by native, JavaScript, browser, OTP, and
  hosted runners.
- Fail a cross-lane aggregate when supposedly identical workload dimensions use different
  artifacts.
- Keep intentional platform variants explicit in dimensions rather than silently comparing them.

**Done when:** a cross-runtime performance difference cannot be caused by an unnoticed Bazel
transition or stale image artifact.

### PERF-016 — Measure genuinely active machines

- Add a guest-visible barrier proving that the long-running command has begun and touched its working
  set.
- Tick every machine until it reaches that barrier before reading active RSS.
- Use a bounded workload that exercises task stacks, pipes, filesystem pages, and service state
  representative of an active customer machine.
- Sample the full process-tree RSS after it stabilizes.
- Report idle and active deltas from separate fresh host processes.

**Done when:** active RSS cannot be recorded from jobs that have only been enqueued.

### PERF-017 — Cancel work that is demonstrably running

- Add a running-state barrier before starting the cancellation timer.
- Include CPU-bound, sleeping, blocked-I/O, pipeline, and resident-service cases.
- Measure cancellation request to job completion and then execute a health-check command.
- Record p50 and p95 latency plus post-cancellation machine health.

**Done when:** cancellation latency measures interruption of live guest work, not cancellation of an
unstarted job.

### PERF-018 — Run release measurements on a controlled host

- Use optimized release artifacts.
- Use a dedicated host with enough physical memory for the requested population.
- Set a stable performance governor and record frequency and thermal state.
- Prevent swap from turning branch creation into disk-I/O latency.
- Run at least 30 successful samples per exact standard workload and 100 for stress investigations.
- Store raw results, artifact digests, host metadata, and suite revision together.
- Run the hosted standard and stress profiles against a dedicated server rather than a developer
  process competing with local builds.

**Done when:** repeated runs on the same release and host class have stable p50 and p95 values, and
performance regressions can be distinguished from host pressure.

## Delivery order

1. PERF-013 instrumentation and the execution-state portions of PERF-014 establish where each
   command spends time.
2. PERF-001 and PERF-002 remove fixed scheduling and shell-construction costs.
3. PERF-003 and PERF-010 preserve shell and guest-module work.
4. PERF-004 makes prewarmed service performance the default.
5. PERF-005 and PERF-006 reduce snapshot copying and whole-memory scanning.
6. PERF-007 and PERF-008 introduce fast local and server-side state handles.
7. PERF-009 makes branch populations useful at customer scale.
8. PERF-011 and PERF-012 reduce browser and hosted overhead.
9. PERF-015 through PERF-018 close the release-quality proof for each completed group.

Each implementation task is complete only after:

- its correctness and isolation tests pass;
- it improves the intended customer operation at p50 and p95;
- it does not move equivalent cost into machine creation, memory, or another hidden stage;
- the raw results and exact release artifact digests are retained;
- failure, cancellation, and resource-exhaustion behavior remain contained.
