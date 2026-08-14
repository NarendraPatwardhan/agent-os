use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::process::Command;
use std::time::{Duration, SystemTime};

use crate::{network, snapshot, validate_id, Config, Layout};

const RECONCILE_GRACE: Duration =
    Duration::from_millis(sidecar_rust::SIDECAR_MAX_RENEW_MS as u64 * 2);

pub fn prepare(
    config: &Config,
    id: &str,
    profile: Option<&str>,
    network: bool,
) -> Result<Layout, String> {
    config.validate_installation()?;
    let layout = config.layout(id)?;
    cleanup(config, id)?;
    if network {
        network::prepare(config, &layout)?;
    } else {
        network::namespace_prepare(config, &layout)?;
    }
    let staged = (|| {
        fs::create_dir_all(layout.root.join("run"))
            .map_err(|error| format!("create jail root: {error}"))?;
        create_lease(&layout.lease)?;
        copy_root_owned(&config.kernel, &layout.root.join("kernel"), 0o444)?;
        copy_root_owned(
            config.initramfs(profile)?,
            &layout.root.join("initramfs"),
            0o444,
        )?;
        Ok(layout.clone())
    })();
    if staged.is_err() {
        let _ = cleanup(config, id);
    }
    staged
}

pub fn launch(
    config: &Config,
    id: &str,
    profile: Option<&str>,
    network: bool,
    snapshot_key: Option<&str>,
) -> Result<i32, String> {
    let layout = prepare(config, id, profile, network)?;
    if let Some(key) = snapshot_key {
        snapshot::stage_snapshot(config, &layout, key)?;
    }
    let status = Command::new(&config.ip)
        .args(["netns", "exec", &layout.netns])
        .arg(&config.jailer)
        .args([
            "--id",
            id,
            "--exec-file",
            config
                .firecracker
                .to_str()
                .ok_or("invalid firecracker path")?,
            "--uid",
            &config.runner_uid.to_string(),
            "--gid",
            &config.runner_gid.to_string(),
            "--chroot-base-dir",
            config.chroot_base.to_str().ok_or("invalid chroot base")?,
            "--cgroup-version",
            "2",
            "--parent-cgroup",
            "agentos-sidecars",
            "--new-pid-ns",
            "--",
            "--api-sock",
            "/run/firecracker.socket",
        ])
        .status()
        .map_err(|error| format!("start jailer: {error}"))?;
    Ok(status.code().unwrap_or(125))
}

pub fn cleanup(config: &Config, id: &str) -> Result<(), String> {
    let layout = config.layout(id)?;
    if layout.cgroup.join("cgroup.kill").exists() {
        fs::write(layout.cgroup.join("cgroup.kill"), b"1\n")
            .map_err(|error| format!("kill cgroup: {error}"))?;
    }
    wait_for_empty_cgroup(&layout.cgroup)?;
    network::cleanup(config, id, &layout.netns)?;
    remove_cgroup(&layout.cgroup)?;
    if let Some(instance_root) = layout.root.parent().filter(|path| path.exists()) {
        checked(
            config.rm.as_path(),
            &[
                "-rf",
                "--one-file-system",
                "--",
                instance_root.to_str().ok_or("invalid jail path")?,
            ],
        )?;
    }
    Ok(())
}

pub fn renew(config: &Config, id: &str) -> Result<(), String> {
    let layout = config.layout(id)?;
    let metadata = fs::symlink_metadata(&layout.lease)
        .map_err(|error| format!("inspect sidecar lease: {error}"))?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 0
        || metadata.permissions().mode() & 0o022 != 0
    {
        return Err(
            "sidecar lease must be a root-owned regular file not writable by group/other".into(),
        );
    }
    fs::write(&layout.lease, b"1\n").map_err(|error| format!("renew sidecar lease: {error}"))
}

pub fn reconcile(config: &Config) -> Result<(), String> {
    let executable = config
        .firecracker
        .file_name()
        .ok_or("invalid firecracker path")?;
    let instances = config.chroot_base.join(executable);
    let entries = match fs::read_dir(&instances) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("read jail root: {error}")),
    };
    for entry in entries {
        let entry = entry.map_err(|error| format!("read jail entry: {error}"))?;
        let id = entry.file_name();
        let id = id.to_str().ok_or("non-utf8 jail id")?;
        if validate_id(id).is_err() {
            continue;
        }
        let layout = config.layout(id)?;
        let recent = match fs::metadata(&layout.lease)
            .and_then(|metadata| metadata.modified())
            .or_else(|_| entry.metadata().and_then(|metadata| metadata.modified()))
        {
            Ok(modified) => SystemTime::now()
                .duration_since(modified)
                .map_or(true, |age| age < RECONCILE_GRACE),
            Err(_) => true,
        };
        if !recent {
            cleanup(config, id)?;
        }
    }
    Ok(())
}

fn copy_root_owned(source: &Path, target: &Path, mode: u32) -> Result<(), String> {
    let temporary = target.with_extension("tmp");
    fs::copy(source, &temporary).map_err(|error| format!("stage {}: {error}", source.display()))?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(mode))
        .map_err(|error| format!("chmod {}: {error}", temporary.display()))?;
    fs::rename(&temporary, target).map_err(|error| format!("publish {}: {error}", target.display()))
}

fn create_lease(path: &Path) -> Result<(), String> {
    use std::fs::OpenOptions;
    use std::io::Write;

    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .map_err(|error| format!("create sidecar lease: {error}"))?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("chmod sidecar lease: {error}"))?;
    file.write_all(b"1\n")
        .map_err(|error| format!("initialize sidecar lease: {error}"))
}

fn wait_for_empty_cgroup(path: &Path) -> Result<(), String> {
    for _ in 0..50 {
        match fs::read_to_string(path.join("cgroup.procs")) {
            Ok(contents) if contents.trim().is_empty() => return Ok(()),
            Ok(_) => std::thread::sleep(Duration::from_millis(10)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(format!("inspect cgroup: {error}")),
        }
    }
    Err("sidecar cgroup did not become empty".into())
}

fn remove_cgroup(path: &Path) -> Result<(), String> {
    match fs::remove_dir(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("remove cgroup: {error}")),
    }
}

fn checked(program: &Path, args: &[&str]) -> Result<(), String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| format!("start {}: {error}", program.display()))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{} failed: {}",
            program.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}
