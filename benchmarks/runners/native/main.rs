mod memory;
mod result;
mod runtime;
mod system;

use anyhow::{anyhow, Context, Result};
use host::{ExecOptions, KernelHost};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::process::Command;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use memory::{memory_probe, run_memory_probe};
use result::{
    boolean, dimensions, ms, number, text, Artifact, ArtifactMeta, Profile, Results, Run,
};
use runtime::{artifact, exec_checked, quiet_builder, run_checked};
use system::{command_output, perf_enabled, system_metadata};
/// PERF-013: p50 of first/middle/last third of an ordered sample series (in-order, not sorted).
fn record_sample_thirds(
    results: &mut Results,
    name: &str,
    dims: &BTreeMap<String, serde_json::Value>,
) {
    let values: Vec<f64> = {
        let Some(m) = results
            .doc
            .measurements
            .iter()
            .find(|m| m.name == name && m.dimensions == *dims)
        else {
            return;
        };
        if m.samples.len() < 3 {
            return;
        }
        m.samples.clone()
    };
    let n = values.len();
    let third = (n / 3).max(1);
    let p50 = |slice: &[f64]| {
        let mut s = slice.to_vec();
        s.sort_by(f64::total_cmp);
        s[((0.5 * s.len() as f64).ceil() as usize).max(1) - 1]
    };
    let first_p50 = p50(&values[..third]);
    let last_p50 = p50(&values[n - third..]);
    let middle = &values[third..n - third];
    let middle_p50 = if middle.is_empty() {
        // Degenerate sizes keep first/last; middle falls back to overall mid-sample.
        p50(&values)
    } else {
        p50(middle)
    };
    let mut d = dims.clone();
    d.insert("parent".to_owned(), text(name));
    d.insert("portion".to_owned(), text("first"));
    results.sample("perf.sample_third_p50", "ms", first_p50, d.clone());
    d.insert("portion".to_owned(), text("middle"));
    results.sample("perf.sample_third_p50", "ms", middle_p50, d.clone());
    d.insert("portion".to_owned(), text("last"));
    results.sample("perf.sample_third_p50", "ms", last_p50, d.clone());
    if first_p50 > 0.0 {
        d.insert("portion".to_owned(), text("last_over_first"));
        results.sample("perf.sample_third_ratio", "ratio", last_p50 / first_p50, d);
    }
}

fn sample_command_perf(
    results: &mut Results,
    host: &mut KernelHost,
    parent: &str,
    dims: &BTreeMap<String, serde_json::Value>,
) {
    let Some(p) = host.take_command_perf() else {
        return;
    };
    let mut d = dims.clone();
    d.insert("parent".to_owned(), text(parent));
    results.sample("perf.pace_ms", "ms", p.pace_ms, d.clone());
    results.sample("perf.tick_ms", "ms", p.tick_ms, d.clone());
    results.sample("perf.host_ticks", "count", p.host_ticks as f64, d.clone());
    results.sample(
        "perf.module_cache_misses",
        "count",
        p.module_cache_misses as f64,
        d.clone(),
    );
    results.sample(
        "perf.tasks_spawned",
        "count",
        p.tasks_spawned as f64,
        d.clone(),
    );
    results.sample(
        "perf.pipes_created",
        "count",
        p.pipes_created as f64,
        d.clone(),
    );
    results.sample(
        "perf.kernel_memory_len",
        "bytes",
        p.kernel_memory_len as f64,
        d,
    );
}

fn startup_suite(results: &mut Results, kernel: &Artifact, images: &[&Artifact], profile: Profile) {
    for image in images {
        for iteration in 0..profile.samples {
            let mut host = match quiet_builder(&kernel.bytes, &image.bytes).build() {
                Ok(host) => host,
                Err(error) => {
                    results.failure(
                        "cold_start.shell",
                        "ms",
                        iteration,
                        error,
                        dimensions(&[
                            ("image", text(&image.meta.name)),
                            ("host", text("wasmtime")),
                            ("temperature", text("cold")),
                        ]),
                    );
                    continue;
                }
            };
            let start = Instant::now();
            match exec_checked(&mut host, "true", 20_000) {
                Ok(()) => results.sample(
                    "cold_start.shell",
                    "ms",
                    ms(start),
                    dimensions(&[
                        ("image", text(&image.meta.name)),
                        ("host", text("wasmtime")),
                        ("temperature", text("cold")),
                    ]),
                ),
                Err(error) => results.failure(
                    "cold_start.shell",
                    "ms",
                    iteration,
                    error,
                    dimensions(&[
                        ("image", text(&image.meta.name)),
                        ("host", text("wasmtime")),
                        ("temperature", text("cold")),
                    ]),
                ),
            }
        }
    }
}

fn first_exec_population(
    results: &mut Results,
    kernel: &Artifact,
    image: &Artifact,
    profile: Profile,
    name: &str,
    command: &str,
    dimensions: BTreeMap<String, serde_json::Value>,
    max_ticks: usize,
) {
    for iteration in 0..profile.samples {
        let mut host = match quiet_builder(&kernel.bytes, &image.bytes).build() {
            Ok(host) => host,
            Err(error) => {
                results.failure(name, "ms", iteration, error, dimensions.clone());
                continue;
            }
        };
        let start = Instant::now();
        match exec_checked(&mut host, command, max_ticks) {
            Ok(()) => results.sample(name, "ms", ms(start), dimensions.clone()),
            Err(error) => results.failure(name, "ms", iteration, error, dimensions.clone()),
        }
    }
}

fn repeated_exec(
    results: &mut Results,
    host: &mut KernelHost,
    name: &str,
    command: &str,
    count: usize,
    dims: BTreeMap<String, serde_json::Value>,
    max_ticks: usize,
) {
    for iteration in 0..count {
        let start = Instant::now();
        match exec_checked(host, command, max_ticks) {
            Ok(()) => {
                results.sample(name, "ms", ms(start), dims.clone());
                sample_command_perf(results, host, name, &dims);
            }
            Err(error) => results.failure(name, "ms", iteration, error, dims.clone()),
        }
    }
}

fn repeated_run(
    results: &mut Results,
    host: &mut KernelHost,
    name: &str,
    program: &str,
    args: &[String],
    count: usize,
    dims: BTreeMap<String, serde_json::Value>,
    max_ticks: usize,
) {
    for iteration in 0..count {
        let start = Instant::now();
        match run_checked(host, program, args, max_ticks) {
            Ok(()) => {
                results.sample(name, "ms", ms(start), dims.clone());
                sample_command_perf(results, host, name, &dims);
            }
            Err(error) => results.failure(name, "ms", iteration, error, dims.clone()),
        }
    }
}

fn execution_state_suite(
    results: &mut Results,
    kernel: &Artifact,
    posix: &Artifact,
    profile: Profile,
) -> Result<()> {
    let common = dimensions(&[("image", text("posix")), ("host", text("wasmtime"))]);
    let with_temp = |temperature: &str| {
        let mut dims = common.clone();
        dims.insert("temperature".to_owned(), text(temperature));
        dims
    };
    first_exec_population(
        results,
        kernel,
        posix,
        profile,
        "cold_start.process",
        "/bin/echo agentos",
        with_temp("cold"),
        20_000,
    );

    let mut host = quiet_builder(&kernel.bytes, &posix.bytes).build()?;
    if perf_enabled() {
        host.set_perf_enabled(true)?;
    }
    repeated_exec(
        results,
        &mut host,
        "exec.shell_builtin.steady",
        "true",
        profile.samples,
        with_temp("steady-state"),
        20_000,
    );
    record_sample_thirds(
        results,
        "exec.shell_builtin.steady",
        &with_temp("steady-state"),
    );
    repeated_exec(
        results,
        &mut host,
        "exec.external_module.steady",
        "/bin/echo agentos",
        profile.samples,
        with_temp("steady-state"),
        20_000,
    );
    repeated_run(
        results,
        &mut host,
        "exec.direct_minimal.steady",
        "true",
        &[],
        profile.samples,
        with_temp("steady-state"),
        20_000,
    );
    repeated_run(
        results,
        &mut host,
        "exec.direct_external.steady",
        "echo",
        &[String::from("agentos")],
        profile.samples,
        with_temp("steady-state"),
        20_000,
    );
    repeated_exec(
        results,
        &mut host,
        "exec.pipeline.three_stage",
        "printf 'c\\na\\nb\\n' | sort | wc -l",
        profile.samples,
        dimensions(&[
            ("image", text("posix")),
            ("host", text("wasmtime")),
            ("temperature", text("steady-state")),
            ("stages", number(3)),
        ]),
        40_000,
    );

    for &bytes in profile.fs_bytes {
        let payload = vec![b'a'; bytes];
        for iteration in 0..profile.samples {
            let path = format!("/tmp/bench-write-{bytes}-{iteration}");
            let start = Instant::now();
            match host.write_file(&path, &payload) {
                Ok(()) => {
                    let elapsed_ms = ms(start);
                    if elapsed_ms > 0.0 {
                        results.sample(
                            "filesystem.structured_write",
                            "bytes_per_second",
                            bytes as f64 / (elapsed_ms / 1000.0),
                            dimensions(&[
                                ("image", text("posix")),
                                ("host", text("wasmtime")),
                                ("bytes", number(bytes)),
                            ]),
                        );
                    } else {
                        results.failure(
                            "filesystem.structured_write",
                            "bytes_per_second",
                            iteration,
                            "monotonic timer returned a zero duration",
                            dimensions(&[
                                ("image", text("posix")),
                                ("host", text("wasmtime")),
                                ("bytes", number(bytes)),
                            ]),
                        );
                    }
                }
                Err(error) => results.failure(
                    "filesystem.structured_write",
                    "bytes_per_second",
                    iteration,
                    error,
                    dimensions(&[
                        ("image", text("posix")),
                        ("host", text("wasmtime")),
                        ("bytes", number(bytes)),
                    ]),
                ),
            }
        }
        let path = format!("/tmp/bench-read-{bytes}");
        host.write_file(&path, &payload)?;
        for iteration in 0..profile.samples {
            let start = Instant::now();
            match host.read_file(&path) {
                Ok(value) if value.len() == bytes => {
                    let elapsed_ms = ms(start);
                    if elapsed_ms > 0.0 {
                        results.sample(
                            "filesystem.structured_read",
                            "bytes_per_second",
                            bytes as f64 / (elapsed_ms / 1000.0),
                            dimensions(&[
                                ("image", text("posix")),
                                ("host", text("wasmtime")),
                                ("bytes", number(bytes)),
                            ]),
                        );
                    } else {
                        results.failure(
                            "filesystem.structured_read",
                            "bytes_per_second",
                            iteration,
                            "monotonic timer returned a zero duration",
                            dimensions(&[
                                ("image", text("posix")),
                                ("host", text("wasmtime")),
                                ("bytes", number(bytes)),
                            ]),
                        );
                    }
                }
                Ok(value) => results.failure(
                    "filesystem.structured_read",
                    "bytes_per_second",
                    iteration,
                    format!("short read: {} != {bytes}", value.len()),
                    dimensions(&[
                        ("image", text("posix")),
                        ("host", text("wasmtime")),
                        ("bytes", number(bytes)),
                    ]),
                ),
                Err(error) => results.failure(
                    "filesystem.structured_read",
                    "bytes_per_second",
                    iteration,
                    error,
                    dimensions(&[
                        ("image", text("posix")),
                        ("host", text("wasmtime")),
                        ("bytes", number(bytes)),
                    ]),
                ),
            }
        }
    }

    let mut full = None;
    for _iteration in 0..profile.samples {
        let start = Instant::now();
        let snapshot = host.snapshot()?;
        results.sample("snapshot.full.latency", "ms", ms(start), common.clone());
        results.sample(
            "snapshot.full.size",
            "bytes",
            snapshot.len() as f64,
            common.clone(),
        );
        if full.is_none() {
            full = Some(snapshot);
        }
    }
    let full = full.ok_or_else(|| anyhow!("full snapshot population was empty"))?;
    for &bytes in profile.fs_bytes {
        for iteration in 0..profile.samples {
            let mut mutated = quiet_builder(&kernel.bytes, &posix.bytes).restore(&full)?;
            mutated.write_file(
                &format!("/tmp/snapshot-mutation-{bytes}-{iteration}"),
                &vec![0; bytes],
            )?;
            let start = Instant::now();
            let delta = mutated.snapshot_incremental(&full)?;
            let dims = dimensions(&[
                ("image", text("posix")),
                ("host", text("wasmtime")),
                ("mutationBytes", number(bytes)),
            ]);
            results.sample(
                "snapshot.incremental.latency",
                "ms",
                ms(start),
                dims.clone(),
            );
            results.sample(
                "snapshot.incremental.size",
                "bytes",
                delta.len() as f64,
                dims.clone(),
            );
            results.sample(
                "snapshot.incremental.efficiency",
                "ratio",
                delta.len() as f64 / full.len() as f64,
                dims,
            );
        }
    }
    for iteration in 0..profile.samples {
        let start = Instant::now();
        match quiet_builder(&kernel.bytes, &posix.bytes).restore(&full) {
            Ok(_) => results.sample("snapshot.restore_full", "ms", ms(start), with_temp("cold")),
            Err(error) => results.failure(
                "snapshot.restore_full",
                "ms",
                iteration,
                error,
                with_temp("cold"),
            ),
        }
    }
    for iteration in 0..profile.samples {
        let start = Instant::now();
        match host
            .snapshot()
            .and_then(|snapshot| quiet_builder(&kernel.bytes, &posix.bytes).restore(&snapshot))
        {
            Ok(_) => results.sample("machine.fork", "ms", ms(start), common.clone()),
            Err(error) => results.failure("machine.fork", "ms", iteration, error, common.clone()),
        }
    }
    Ok(())
}

fn resident_suite(
    results: &mut Results,
    kernel: &Artifact,
    image: &Artifact,
    service: &str,
    profile: Profile,
) -> Result<()> {
    let command = match service {
        "sqlite" => {
            "sqlite /tmp/bench.db \"CREATE TABLE IF NOT EXISTS t(n INTEGER); INSERT INTO t VALUES (1); SELECT count(*) FROM t\""
        }
        "typst" => {
            "printf '= AgentOS benchmark' > /tmp/bench.typ; typst compile /tmp/bench.typ /tmp/bench.pdf"
        }
        _ => return Err(anyhow!("unknown resident service {service}")),
    };
    let max_ticks = if service == "typst" {
        1_000_000
    } else {
        200_000
    };
    let first_dimensions = dimensions(&[
        ("image", text(&image.meta.name)),
        ("temperature", text("cold")),
        ("host", text("wasmtime")),
    ]);
    first_exec_population(
        results,
        kernel,
        image,
        profile,
        &format!("resident.{service}.first"),
        command,
        first_dimensions,
        max_ticks,
    );
    let mut host = quiet_builder(&kernel.bytes, &image.bytes).build()?;
    exec_checked(&mut host, command, max_ticks)?;
    repeated_exec(
        results,
        &mut host,
        &format!("resident.{service}.warm"),
        command,
        profile.samples,
        dimensions(&[
            ("image", text(&image.meta.name)),
            ("temperature", text("warm")),
            ("host", text("wasmtime")),
        ]),
        max_ticks,
    );
    let warm = host.snapshot()?;
    let restored_dimensions = dimensions(&[
        ("image", text(&image.meta.name)),
        ("temperature", text("restored-warm")),
        ("host", text("wasmtime")),
    ]);
    for iteration in 0..profile.samples {
        let mut restored = quiet_builder(&kernel.bytes, &image.bytes).restore(&warm)?;
        let start = Instant::now();
        match exec_checked(&mut restored, command, max_ticks) {
            Ok(()) => results.sample(
                &format!("resident.{service}.restored_warm"),
                "ms",
                ms(start),
                restored_dimensions.clone(),
            ),
            Err(error) => results.failure(
                &format!("resident.{service}.restored_warm"),
                "ms",
                iteration,
                error,
                restored_dimensions.clone(),
            ),
        }
    }
    Ok(())
}

fn robustness_suite(
    results: &mut Results,
    kernel: &Artifact,
    posix: &Artifact,
    profile: Profile,
) -> Result<()> {
    let mut post_cancel_healthy = true;
    for iteration in 0..profile.samples {
        let mut host = quiet_builder(&kernel.bytes, &posix.bytes).build()?;
        let job = host.exec_start("sleep 30", ExecOptions::default())?;
        let start = Instant::now();
        match host.exec_cancel(job) {
            Ok(()) => results.sample(
                "robustness.cancellation.latency",
                "ms",
                ms(start),
                dimensions(&[("host", text("wasmtime")), ("image", text("posix"))]),
            ),
            Err(error) => {
                post_cancel_healthy = false;
                results.failure(
                    "robustness.cancellation.latency",
                    "ms",
                    iteration,
                    error,
                    dimensions(&[("host", text("wasmtime")), ("image", text("posix"))]),
                );
            }
        }
        post_cancel_healthy &= exec_checked(&mut host, "true", 20_000).is_ok();
    }
    results.check(
        "robustness.cancellation.post_health",
        post_cancel_healthy,
        None,
    );

    let mut host = quiet_builder(&kernel.bytes, &posix.bytes).build()?;
    let mut snapshot = host.snapshot()?;
    if let Some(last) = snapshot.last_mut() {
        *last ^= 0xff;
    }
    let malformed_rejected = quiet_builder(&kernel.bytes, &posix.bytes)
        .restore(&snapshot)
        .is_err();
    results.check(
        "robustness.malformed_snapshot.rejected",
        malformed_rejected,
        None,
    );

    host.write_file("/tmp/malformed.wasm", b"not a wasm module")?;
    host.chmod("/tmp/malformed.wasm", 0o755)?;
    let malformed_exec = host.exec("/tmp/malformed.wasm", 20_000, ExecOptions::default());
    let survived = malformed_exec
        .map(|result| result.exit_code != 0)
        .unwrap_or(true)
        && exec_checked(&mut host, "true", 20_000).is_ok();
    results.check("robustness.malformed_guest.survives", survived, None);
    let exhausted = host.exec("while true; do :; done", 1_000, ExecOptions::default());
    let contained = exhausted
        .map(|execution| execution.exit_code != 0)
        .unwrap_or(true)
        && exec_checked(&mut host, "true", 20_000).is_ok();
    results.check("robustness.resource_exhaustion.contained", contained, None);
    Ok(())
}

fn branch_suite(
    results: &mut Results,
    kernel: &Artifact,
    posix: &Artifact,
    profile: Profile,
) -> Result<()> {
    for _population_iteration in 0..profile.samples {
        let mut parent = quiet_builder(&kernel.bytes, &posix.bytes).build()?;
        let baseline = parent.snapshot()?;
        let start = Instant::now();
        let mut children = Vec::with_capacity(profile.branches);
        for iteration in 0..profile.branches {
            match quiet_builder(&kernel.bytes, &posix.bytes).restore(&baseline) {
                Ok(child) => children.push(child),
                Err(error) => {
                    results.failure(
                        "population.branch_create",
                        "ms",
                        iteration,
                        error,
                        dimensions(&[
                            ("image", text("posix")),
                            ("requestedBranches", number(profile.branches)),
                            ("completedBranches", number(children.len())),
                            ("retained", boolean(true)),
                            ("host", text("wasmtime")),
                        ]),
                    );
                    break;
                }
            }
        }
        let duration = ms(start);
        results.sample(
            "population.branch_create",
            "ms",
            duration,
            dimensions(&[
                ("image", text("posix")),
                ("branches", number(children.len())),
                ("retained", boolean(true)),
                ("host", text("wasmtime")),
            ]),
        );
        let active_start = Instant::now();
        let mut active_ok = 0usize;
        for child in &mut children {
            if exec_checked(child, "true", 20_000).is_ok() {
                active_ok += 1;
            }
        }
        let active_ms = ms(active_start);
        if active_ms > 0.0 {
            results.sample(
                "population.active_command_rate",
                "ops_per_second",
                active_ok as f64 / (active_ms / 1000.0),
                dimensions(&[
                    ("image", text("posix")),
                    ("machines", number(children.len())),
                    ("concurrency", number(1)),
                    ("host", text("wasmtime")),
                ]),
            );
        }
        drop(children);
    }

    for iteration in 0..profile.samples {
        match run_memory_probe(profile.memory_machines, kernel, posix) {
            Ok(probe) => {
                let dims = dimensions(&[
                    ("image", text("posix")),
                    ("machines", number(profile.memory_machines)),
                    ("host", text("wasmtime")),
                    ("isolation", text("fresh-process")),
                ]);
                results.sample(
                    "population.idle_rss_per_machine",
                    "bytes",
                    probe.idle_rss_per_machine,
                    dims.clone(),
                );
                results.sample(
                    "population.active_rss_per_machine",
                    "bytes",
                    probe.active_rss_per_machine,
                    dims.clone(),
                );
                if probe.idle_rss_per_machine > 0.0 {
                    results.sample(
                        "population.machines_per_gib",
                        "count",
                        1024f64.powi(3) / probe.idle_rss_per_machine,
                        dims,
                    );
                }
            }
            Err(error) => results.failure(
                "population.idle_rss_per_machine",
                "bytes",
                iteration,
                error,
                dimensions(&[
                    ("image", text("posix")),
                    ("machines", number(profile.memory_machines)),
                    ("host", text("wasmtime")),
                    ("isolation", text("fresh-process")),
                ]),
            ),
        }
    }
    Ok(())
}

fn deterministic_suite(
    results: &mut Results,
    kernel: &Artifact,
    posix: &Artifact,
    repetitions: usize,
) -> Result<()> {
    let mut snapshot_digests = Vec::new();
    let mut outputs = Vec::new();
    for _ in 0..repetitions {
        let mut host = quiet_builder(&kernel.bytes, &posix.bytes).build()?;
        let execution = host.exec(
            "printf deterministic-agentos",
            20_000,
            ExecOptions::default(),
        )?;
        outputs.push(execution.stdout);
        snapshot_digests.push(Sha256::digest(host.snapshot()?).to_vec());
    }
    let matching = outputs
        .iter()
        .zip(&snapshot_digests)
        .filter(|(output, digest)| *output == &outputs[0] && *digest == &snapshot_digests[0])
        .count();
    let matches = matching == repetitions;
    results.check(
        "deterministic.replay",
        matches,
        Some(format!("{repetitions} complete transcripts")),
    );
    results.sample(
        "deterministic.replay_rate",
        "percent",
        matching as f64 / repetitions as f64 * 100.0,
        dimensions(&[
            ("repetitions", number(repetitions)),
            ("host", text("wasmtime")),
        ]),
    );
    Ok(())
}

struct Args {
    profile: Profile,
    output: Option<String>,
}

fn parse_args() -> Result<Args> {
    const SMOKE_BYTES: &[usize] = &[4 * 1024];
    const STANDARD_BYTES: &[usize] = &[4 * 1024, 1024 * 1024];
    const STRESS_BYTES: &[usize] = &[4 * 1024, 1024 * 1024, 16 * 1024 * 1024];
    let profiles = |name| match name {
        "smoke" => Some(Profile {
            name: "smoke",
            samples: 3,
            branches: 8,
            memory_machines: 8,
            fs_bytes: SMOKE_BYTES,
        }),
        "standard" => Some(Profile {
            name: "standard",
            samples: 30,
            branches: 1_000,
            memory_machines: 20,
            fs_bytes: STANDARD_BYTES,
        }),
        "stress" => Some(Profile {
            name: "stress",
            samples: 100,
            branches: 10_000,
            memory_machines: 100,
            fs_bytes: STRESS_BYTES,
        }),
        _ => None,
    };
    let mut profile = profiles("smoke").unwrap();
    let mut output = None;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let value = args.get(i + 1);
        match (args[i].as_str(), value) {
            ("--profile", Some(value)) => {
                profile = profiles(value).ok_or_else(|| anyhow!("unknown profile {value:?}"))?;
                i += 2;
            }
            ("--samples", Some(value)) => {
                profile.samples = value
                    .parse()
                    .context("--samples must be a positive integer")?;
                if profile.samples == 0 {
                    return Err(anyhow!("--samples must be positive"));
                }
                i += 2;
            }
            ("--branches", Some(value)) => {
                profile.branches = value
                    .parse()
                    .context("--branches must be a positive integer")?;
                if profile.branches == 0 {
                    return Err(anyhow!("--branches must be positive"));
                }
                i += 2;
            }
            ("--output", Some(value)) => {
                output = Some(value.clone());
                i += 2;
            }
            _ => return Err(anyhow!("unknown or incomplete argument {:?}", args[i])),
        }
    }
    Ok(Args { profile, output })
}

fn git_metadata() -> serde_json::Value {
    let workspace = std::env::var("BUILD_WORKSPACE_DIRECTORY").ok();
    let run = |args: &[&str]| -> Option<String> {
        let mut command = Command::new("git");
        command.args(args);
        if let Some(workspace) = &workspace {
            command.current_dir(workspace);
        }
        let output = command.output().ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
    };
    let status = run(&["status", "--porcelain"]);
    serde_json::json!({
        "commit": run(&["rev-parse", "HEAD"]).unwrap_or_else(|| "unknown".to_owned()),
        "dirty": status.as_deref().map(|s| !s.is_empty())
    })
}

fn main() -> Result<()> {
    let argv: Vec<String> = std::env::args().collect();
    if argv.get(1).map(String::as_str) == Some("--memory-probe") {
        let branches = argv
            .get(2)
            .context("--memory-probe requires a branch count")?
            .parse::<usize>()
            .context("--memory-probe branch count must be an integer")?;
        if branches == 0 {
            return Err(anyhow!("--memory-probe branch count must be positive"));
        }
        println!("{}", serde_json::to_string(&memory_probe(branches)?)?);
        return Ok(());
    }
    let args = parse_args()?;
    let kernel = artifact("kernel.wasm", "MC_KERNEL_WASM")?;
    let minimal = artifact("minimal", "MC_MINIMAL_IMAGE")?;
    let posix = artifact("posix", "MC_POSIX_IMAGE")?;
    let loom = artifact("loom", "MC_LOOM_IMAGE")?;
    let atlas = artifact("atlas", "MC_ATLAS_IMAGE")?;
    let paper = artifact("paper", "MC_PAPER_IMAGE")?;
    let timestamp = command_output("date", &["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_owned());
    let run = Run {
        id: format!(
            "{}-{}",
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_millis(),
            std::process::id()
        ),
        timestamp,
        runner: "benchmarks/runners/native/main".to_owned(),
        runtime: "release Wasmtime native host".to_owned(),
        profile: args.profile.name.to_owned(),
        sample_count: args.profile.samples,
        branch_count: args.profile.branches,
        system: system_metadata(),
        artifacts: [&kernel, &minimal, &posix, &loom, &atlas, &paper]
            .iter()
            .map(|artifact| ArtifactMeta {
                name: artifact.meta.name.clone(),
                sha256: artifact.meta.sha256.clone(),
                bytes: artifact.meta.bytes,
            })
            .collect(),
        git: git_metadata(),
        command: std::env::args().collect(),
        semantics: serde_json::json!({
            "coldStart": "first command on a fresh machine",
            "wasmtimeCompilationMode": "opt",
            "memoryPopulation": args.profile.memory_machines
        }),
    };
    let mut results = Results::new(run);
    startup_suite(
        &mut results,
        &kernel,
        &[&minimal, &posix, &loom, &atlas, &paper],
        args.profile,
    );
    if let Err(error) = execution_state_suite(&mut results, &kernel, &posix, args.profile) {
        results.check("suite.execution_state", false, Some(error.to_string()));
    }
    if let Err(error) = resident_suite(&mut results, &kernel, &atlas, "sqlite", args.profile) {
        results.check("suite.resident.sqlite", false, Some(error.to_string()));
    }
    if args.profile.name == "smoke" {
        results.skip(
            "resident.typst",
            "paper compile is intentionally excluded from the smoke profile",
        );
    } else if let Err(error) = resident_suite(&mut results, &kernel, &paper, "typst", args.profile)
    {
        results.check("suite.resident.typst", false, Some(error.to_string()));
    }
    if let Err(error) = robustness_suite(&mut results, &kernel, &posix, args.profile) {
        results.check("suite.robustness", false, Some(error.to_string()));
    }
    if let Err(error) = branch_suite(&mut results, &kernel, &posix, args.profile) {
        results.check("suite.branch", false, Some(error.to_string()));
    }
    if let Err(error) = deterministic_suite(&mut results, &kernel, &posix, args.profile.samples) {
        results.check("suite.deterministic", false, Some(error.to_string()));
    }
    let json = serde_json::to_string_pretty(&results.doc)? + "\n";
    if let Some(path) = args.output {
        fs::write(&path, json).with_context(|| format!("write benchmark result {path}"))?;
    } else {
        print!("{json}");
    }
    Ok(())
}
