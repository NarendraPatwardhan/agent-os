use anyhow::{anyhow, Context, Result};
use host::ExecOptions;
use serde::{Deserialize, Serialize};
use std::process::Command;

use crate::result::Artifact;
use crate::runtime::{artifact, quiet_builder};
use crate::system::proc_bytes;

#[derive(Deserialize, Serialize)]
pub(crate) struct MemoryProbe {
    pub(crate) idle_rss_per_machine: f64,
    pub(crate) active_rss_per_machine: f64,
}

pub(crate) fn memory_probe(branches: usize) -> Result<MemoryProbe> {
    let kernel = artifact("kernel.wasm", "MC_KERNEL_WASM")?;
    let posix = artifact("posix", "MC_POSIX_IMAGE")?;
    let mut parent = quiet_builder(&kernel.bytes, &posix.bytes).build()?;
    let baseline = parent.snapshot()?;
    let rss_before = proc_bytes("VmRSS:").ok_or_else(|| anyhow!("VmRSS is unavailable"))?;
    let mut children = Vec::with_capacity(branches);
    for _ in 0..branches {
        children.push(quiet_builder(&kernel.bytes, &posix.bytes).restore(&baseline)?);
    }
    let idle_rss = proc_bytes("VmRSS:").ok_or_else(|| anyhow!("VmRSS is unavailable"))?;
    let mut jobs = Vec::with_capacity(children.len());
    for child in &mut children {
        jobs.push(child.exec_start("sleep 30", ExecOptions::default())?);
    }
    let active_rss = proc_bytes("VmRSS:").ok_or_else(|| anyhow!("VmRSS is unavailable"))?;
    for (child, job) in children.iter_mut().zip(jobs) {
        let _ = child.exec_cancel(job);
    }
    Ok(MemoryProbe {
        idle_rss_per_machine: idle_rss.saturating_sub(rss_before) as f64 / branches as f64,
        active_rss_per_machine: active_rss.saturating_sub(rss_before) as f64 / branches as f64,
    })
}

pub(crate) fn run_memory_probe(
    branches: usize,
    kernel: &Artifact,
    posix: &Artifact,
) -> Result<MemoryProbe> {
    let output = Command::new(std::env::current_exe()?)
        .arg("--memory-probe")
        .arg(branches.to_string())
        .env("MC_KERNEL_WASM", &kernel.path)
        .env("MC_POSIX_IMAGE", &posix.path)
        .output()
        .context("launch isolated memory probe")?;
    if !output.status.success() {
        return Err(anyhow!(
            "memory probe failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    serde_json::from_slice(&output.stdout).context("parse isolated memory probe")
}
