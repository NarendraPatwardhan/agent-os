use anyhow::{anyhow, Context, Result};
use host::{CaptureSink, ExecOptions, KernelHost, KernelHostBuilder};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;

use crate::result::{Artifact, ArtifactMeta};

pub(crate) fn runfiles_root() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("RUNFILES_DIR") {
        return Ok(path.into());
    }

    // `host_release_binary` re-exports the transitioned executable as a symlink. Bazel supplies
    // the wrapper's runfiles tree, but some `bazel run` versions omit RUNFILES_DIR for that shape.
    // argv[0] retains the wrapper path even though current_exe() resolves to the transitioned bin.
    if let Some(executable) = std::env::args_os().next() {
        let mut candidate = executable;
        candidate.push(".runfiles");
        let candidate = PathBuf::from(candidate);
        if candidate.is_dir() {
            return Ok(candidate);
        }
    }

    Err(anyhow!(
        "RUNFILES_DIR is not set and the executable runfiles tree was not found; run through Bazel"
    ))
}

pub(crate) fn artifact(name: &str, env: &str) -> Result<Artifact> {
    let path = match std::env::var(env) {
        Ok(path) => PathBuf::from(path),
        Err(_) => {
            let relative = if name == "kernel.wasm" {
                "memcontainers/kernel/rust/kernel.wasm".to_owned()
            } else {
                format!("memcontainers/images/{name}.tar")
            };
            let root = runfiles_root().with_context(|| format!("{env} is not set"))?;
            let main = root.join("_main").join(&relative);
            if main.exists() {
                main
            } else {
                root.join(relative)
            }
        }
    };
    let bytes =
        fs::read(&path).with_context(|| format!("read {name} artifact at {}", path.display()))?;
    let sha256 = format!("{:x}", Sha256::digest(&bytes));
    Ok(Artifact {
        meta: ArtifactMeta {
            name: name.to_owned(),
            sha256,
            bytes: bytes.len(),
        },
        bytes,
        path,
    })
}

pub(crate) fn quiet_builder(kernel: &[u8], image: &[u8]) -> KernelHostBuilder {
    let (stdout, _) = CaptureSink::new();
    let (stderr, _) = CaptureSink::new();
    let (log, _) = CaptureSink::new();
    KernelHostBuilder::new(kernel.to_vec())
        .with_base_image(Some(image.to_vec()))
        .with_stdout(Box::new(stdout))
        .with_stderr(Box::new(stderr))
        .with_log(Box::new(log))
        .with_workers(0)
        .deterministic()
}

pub(crate) fn exec_checked(host: &mut KernelHost, command: &str, max_ticks: usize) -> Result<()> {
    let result = host.exec(command, max_ticks, ExecOptions::default())?;
    if result.exit_code != 0 {
        return Err(anyhow!(
            "{command:?} exited {}: {}",
            result.exit_code,
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    Ok(())
}

pub(crate) fn run_checked(
    host: &mut KernelHost,
    program: &str,
    args: &[String],
    max_ticks: usize,
) -> Result<()> {
    let result = host.run(program, args, max_ticks, ExecOptions::default())?;
    if result.exit_code != 0 {
        return Err(anyhow!(
            "{program:?} direct exec exited {}: {}",
            result.exit_code,
            String::from_utf8_lossy(&result.stderr)
        ));
    }
    Ok(())
}
