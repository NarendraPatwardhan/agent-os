# AgentOS performance measurement specification

## Scope

The benchmark product answers:

1. How quickly can a fresh environment execute work?
2. How fast is repeated shell, process, pipeline, and filesystem work?
3. How cheaply can live state be snapshotted, restored, and branched?
4. How many machines fit on a host and what happens when they are active?
5. What does AgentOS add to a browser?
6. Do SQLite, documents, and other resident tools benefit from warm state?
7. Is execution deterministic and contained at failure boundaries?

The schema is `agentos.benchmark.v1`. Each runner emits one result document. Aggregation preserves
the source documents and creates no synthetic samples.

Each timed interval begins and ends at the operation boundary defined below.

## Metric contract

### Cold start

`cold_start.shell` is the elapsed time for `true` on a fresh machine. Machine construction happens
before the timer. Every sample uses a different machine. Applicable embedded runners measure Minimal
first, then Posix, Loom, Atlas, and Paper.

`cold_start.process` is the elapsed time for the first external coreutils program on a fresh Posix
machine.

Cold means the first command on a fresh machine. Warm means repeated work on an existing machine.
`restored-warm` means a snapshot taken after service warm-up was restored before the measured command.

### Steady execution

- `exec.shell_builtin.steady`: repeated `true` latency.
- `exec.external_module.steady`: repeated external coreutils latency.
- `exec.direct_minimal.steady`: repeated direct execution of the smallest shipped executable.
- `exec.direct_external.steady`: repeated direct execution of an external coreutils program.
- `exec.pipeline.three_stage`: repeated three-process pipeline latency.
- `filesystem.structured_read`: bytes per second returned through the structured filesystem API.
- `filesystem.structured_write`: bytes per second written through the structured filesystem API.
- `population.active_command_rate`: successful commands per second across a retained branch
  population.

Filesystem dimensions include the exact byte count. Profiles use 4 KiB for smoke; 4 KiB and 1 MiB
for standard; and 4 KiB, 1 MiB, and 16 MiB for stress. The suite emits bandwidth directly.

### State and branching

- `snapshot.full.latency` and `snapshot.full.size`
- `snapshot.incremental.latency` and `snapshot.incremental.size`
- `snapshot.incremental.efficiency`, defined as incremental bytes divided by the exact full snapshot
  baseline
- `snapshot.restore_full`
- `machine.fork`
- `population.branch_create`, the total time to create and retain the profile's branch count

Snapshot latency ends when the byte array is available to the caller. External object-store writes
are not included. Incremental dimensions include the number of mutated bytes.

`machine.fork` measures one independent live child. `population.branch_create` measures the total
time to create and retain 1,000 or 10,000 branches.

### Native memory and density

- `population.idle_rss_per_machine`
- `population.active_rss_per_machine`
- `population.machines_per_gib`

Each native memory sample runs in a fresh process. The probe records process-tree RSS before creating
the retained population, after creating it, and after starting a long-running command in every
machine. The idle and active deltas are divided by the number of retained machines.
`population.machines_per_gib` is one GiB divided by measured idle RSS per machine.
Smoke, standard, and stress use memory populations of 8, 20, and 100 machines respectively. This
population is independent of the 8, 1,000, or 10,000-machine branch-creation scale test.

This is observed native-host density. It is not derived from a configured guest-memory limit,
snapshot size, WebAssembly linear-memory capacity, or a JavaScript runtime's allocator total.

### Browser

- `browser.process_startup`: process launch until Chromium exposes its debugging endpoint.
- `browser.agentos_vm_memory`: additional Chromium process-tree RSS after loading AgentOS and creating
  one idle Posix VM.

Every browser sample launches a fresh Chromium profile. VM memory is a delta from that same process
at `about:blank`; it is not a stale reading after the full benchmark suite and does not use JS heap as
a proxy.

### Resident services

For each shipped service that the profile exercises:

- `resident.<service>.first`
- `resident.<service>.warm`
- `resident.<service>.restored_warm`

Atlas exercises SQLite. Standard and stress also exercise Typst in Paper; smoke records Typst as
skipped to keep the harness check short. A service command must succeed before its latency is
recorded.

### Replay and containment

- `deterministic.replay_rate`: percentage of fixed deterministic transcripts whose output and
  snapshot digest match the first transcript.
- `robustness.cancellation.latency`: time to cancel a running command.
- `robustness.cancellation.post_health`: the machine accepts a command after cancellation.
- `robustness.malformed_snapshot.rejected`: corrupted state is rejected.
- `robustness.malformed_guest.survives`: a malformed guest program cannot damage the host machine.
- `robustness.malformed_kernel.rejected`: the OTP control plane rejects an invalid kernel.
- `robustness.resource_exhaustion.contained`: a command exceeding its execution budget is contained
  and the machine remains usable.

Latency is numeric. Containment outcomes are checks. Rejecting malformed input is a successful check,
not a benchmark failure.

## Runner coverage

| Metric family             | Wasmtime | JS SDK | Browser |     OTP/NIF      |
| ------------------------- | :------: | :----: | :-----: | :--------------: |
| Cold start                |   yes    |  yes   |   yes   |      Posix       |
| Steady commands/pipeline  |   yes    |  yes   |   yes   |       yes        |
| Filesystem bandwidth      |   yes    |  yes   |   yes   |                  |
| Snapshot/restore/fork     |   yes    |  yes   |   yes   |   full/restore   |
| Branch population cost    |   yes    |        |         |                  |
| Native memory/density     |   yes    |        |         |                  |
| Browser startup/VM memory |          |        |   yes   |                  |
| SQLite/Typst warm state   |   yes    |  yes   |   yes   |      SQLite      |
| Replay                    |   yes    |  yes   |         |                  |
| Failure containment       |   yes    |        |         | malformed kernel |

An empty cell means that lane does not emit that metric.

## Statistics

Raw samples remain in order. Numeric summaries contain `count`, p50, and p95. Quantiles use
nearest-rank with one-indexed rank `ceil(q * n)`. Failed observations retain their iteration and
error but do not enter the numeric quantiles.

A standard distribution has at least 30 successful observations of the exact same workload and
dimensions. Smoke uses three observations and validates the harness only. Standard uses 30. Stress
uses 100. Warm-up work happens before the population and is not recorded as its first sample.

No automatic outlier removal is permitted.

## Required metadata and validity

A result identifies UTC time, source revision and dirty state where available, host OS and
architecture, logical CPU count, runtime version, runner, profile, effective sample and branch
counts, command, and artifact SHA-256 digests and sizes.

A valid result:

- conforms to `results/schema.json`;
- contains raw samples for every summary;
- contains no negative values;
- retains failed observations;
- uses release-mode Wasmtime for the native lane;
- never labels provisioning/setup time as cold start;
- never substitutes linear-memory capacity, snapshot size, JS heap, or allocator totals for RSS.
