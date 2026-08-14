# AgentOS benchmarks

This directory contains the reproducible AgentOS benchmark suite. It measures shipped AgentOS
artifacts through the native Wasmtime host, the public JavaScript SDK, Chromium, and the OTP/NIF
server path.

## What the benchmarks answer

1. How quickly can a fresh environment execute work?
2. How fast is repeated shell, process, pipeline, and filesystem work?
3. How cheaply can live state be snapshotted, restored, and branched?
4. How many machines fit on a host and what happens when they are active?
5. What does AgentOS add to a browser?
6. Do SQLite, documents, and other resident tools benefit from warm state?
7. Is execution deterministic and contained at failure boundaries?

These measurements cover the decisions that determine whether an execution environment is practical:
how long users wait for work to begin, how much work a host can sustain, how many isolated machines
fit on that host, how efficiently state can be copied and resumed, and whether the system remains
usable under failure.

## Measurement coverage

| Area                  | Measurement                                                                                 |
| --------------------- | ------------------------------------------------------------------------------------------- |
| Startup               | First shell command by image and first external Posix process                               |
| Steady execution      | Shell syntax, direct argv, external process, and three-stage pipeline latency               |
| Filesystem            | Structured read and write bandwidth                                                         |
| State                 | Full and incremental snapshot latency and size, restore latency, and incremental/full ratio |
| Branching             | Single-fork latency and retained-population creation time                                   |
| Native memory         | Idle and active RSS per machine and machines per GiB                                        |
| Browser               | Chromium startup and incremental RSS for one idle Posix VM                                  |
| Resident services     | SQLite and Typst cold, warm, and restored-warm latency                                      |
| Replay and robustness | Replay rate, cancellation, malformed input, and resource exhaustion                         |

## Methodology

The suite measures shipped release artifacts through public AgentOS surfaces. Workloads are small and
recognizable: a shell builtin, an external process, a three-stage pipeline, structured filesystem
operations, SQLite, Typst, snapshot/restore, and retained machine populations. [SPEC.md](SPEC.md)
defines the start and end of every timer.

Results are reported as populations rather than single demonstrations:

- Raw observations remain in the result.
- `n`, p50, and p95 are reported together.
- Failed observations remain attached to the distribution.
- Warm-up work is completed before a steady-state population.
- Cold-start samples use a fresh machine for every observation.
- Native memory samples use fresh host processes and include the host process tree.
- Browser memory is the process-tree RSS added by AgentOS and one Posix VM in a fresh Chromium
  profile.
- Commands, runtime versions, system metadata, source state, and artifact digests travel with the
  result.

Comparisons are based on the job a user is choosing a product to perform, not on whether two products
share an implementation. An in-process WebAssembly runtime, a container sandbox, and a hosted VM can
be relevant alternatives when they provide the same isolated execution outcome. A comparison should
state the workload, timing boundary, product configuration, data source, collection date, and why the
baseline is relevant. Different metrics may use different baselines—for example, the fastest
available alternative for latency and the lowest-cost alternative for economics.

## Runners

- `//benchmarks:native` measures the release native host. It is the authoritative lane for native
  branching, density, and resilience.
- `//benchmarks:embedded` measures the public embedded `@mc/core` API.
- `//benchmarks:browser` measures the browser API and launches fresh Chromium processes for browser
  startup and VM-memory populations.
- `//benchmarks:server` measures the AgentOS OTP control plane and release NIF.

## Quick start

Set `BAZEL_CACHE` to one persistent, writable directory on your machine and use it for every Bazel
command:

```bash
export BAZEL_CACHE=/path/to/agentos-bazel-cache

bazel "--output_user_root=${BAZEL_CACHE}" test //benchmarks:test

bazel "--output_user_root=${BAZEL_CACHE}" run //benchmarks:native -- \
  --profile smoke --output /tmp/agentos-native.json

bazel "--output_user_root=${BAZEL_CACHE}" run //benchmarks:embedded -- \
  --profile smoke --output /tmp/agentos-embedded.json

bazel "--output_user_root=${BAZEL_CACHE}" run //benchmarks:browser -- \
  --profile smoke --output /tmp/agentos-browser.json

bazel "--output_user_root=${BAZEL_CACHE}" test //benchmarks:server
# Result: bazel-testlogs/benchmarks/server/test.outputs/server.json
```

The BEAM target uses the same scoped Erlang/Elixir transition as `//server:mix_test`. Do not select a
repository-wide Elixir platform. Choose a larger BEAM population with
`--test_env=AGENTOS_BENCHMARK_PROFILE=standard` or `stress`.

Chromium defaults to `/usr/bin/chromium`; set `CHROMIUM_BIN` to use another executable.

### Aggregate and validate

```bash
bazel "--output_user_root=${BAZEL_CACHE}" run //benchmarks:aggregate -- \
  --output /tmp/agentos-benchmark-run.json \
  /tmp/agentos-native.json \
  /tmp/agentos-embedded.json \
  /tmp/agentos-browser.json

bazel "--output_user_root=${BAZEL_CACHE}" run //benchmarks:validate -- \
  /tmp/agentos-benchmark-run.json
```

## Profiles and publication

| Profile    | Purpose                         | Samples per distribution | Retained branches | Machines per fresh memory probe |
| ---------- | ------------------------------- | -----------------------: | ----------------: | ------------------------------: |
| `smoke`    | Harness validation only         |                        3 |                 8 |                               8 |
| `standard` | Repeatable single-system result |                       30 |             1,000 |                              20 |
| `stress`   | Explicit scale result           |                      100 |            10,000 |                             100 |

Use `--samples N` and `--branches N` to override a profile. Stress is never selected implicitly.

Every numeric distribution retains the raw samples and reports `n`, p50, and p95. Report all three
together. A cold-start observation is one command on one independently created machine. A browser
startup observation is one independently launched Chromium process. A native memory observation runs
in a fresh process so allocator history from a previous population cannot flatten the result.
The memory probe uses a bounded population distinct from the retained-branch scale test, then derives
per-machine RSS from that observed process delta.

Smoke validates the harness. Use standard or stress results when the exact population has at least
30 successful samples. Failed iterations remain attached to the result.

## Reproducible releases

Use release artifacts, record the exact command and source revision, keep the artifact digests and raw
samples, and run on an otherwise idle host. Attach the JSON to the release or preserve it in benchmark
CI; do not commit a developer-machine result as an authoritative baseline.

See [SPEC.md](SPEC.md) for exact boundaries and metric names.
