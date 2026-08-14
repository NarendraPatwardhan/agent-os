use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

use crate::{Config, Layout};

const SNAPSHOT_BASE_LIMIT: usize = 2;

pub fn snapshot_available(config: &Config, key: &str) -> Result<bool, String> {
    let root = snapshot_root(config, key)?;
    let state = root.join("vmstate");
    let memory = root.join("memory");
    if !root.exists() {
        return Ok(false);
    }
    validate_snapshot_file(&state, 0)?;
    validate_snapshot_file(&memory, 0)?;
    Ok(true)
}

pub fn remove_snapshot(config: &Config, key: &str) -> Result<(), String> {
    let root = snapshot_root(config, key)?;
    match fs::remove_dir_all(&root) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("remove prepared snapshot: {error}")),
    }
}

pub fn publish_snapshot(config: &Config, id: &str, key: &str) -> Result<(), String> {
    validate_snapshot_key(key)?;
    if snapshot_available(config, key)? {
        return Ok(());
    }

    let layout = config.layout(id)?;
    let state = layout.root.join("run/prepared.vmstate");
    let memory = layout.root.join("run/prepared.memory");
    validate_snapshot_file(&state, config.runner_uid)?;
    validate_snapshot_file(&memory, config.runner_uid)?;

    let temporary = config
        .snapshot_base
        .join(format!(".{key}-{}", std::process::id()));
    let destination = snapshot_root(config, key)?;
    match fs::create_dir(&temporary) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            fs::remove_dir_all(&temporary)
                .map_err(|remove| format!("remove stale snapshot staging directory: {remove}"))?;
            fs::create_dir(&temporary)
                .map_err(|create| format!("create snapshot staging directory: {create}"))?;
        }
        Err(error) => return Err(format!("create snapshot staging directory: {error}")),
    }

    let published = (|| {
        fs::rename(&state, temporary.join("vmstate"))
            .map_err(|error| format!("stage snapshot state: {error}"))?;
        fs::rename(&memory, temporary.join("memory"))
            .map_err(|error| format!("stage snapshot memory: {error}"))?;
        for path in [temporary.join("vmstate"), temporary.join("memory")] {
            fs::set_permissions(&path, fs::Permissions::from_mode(0o444))
                .map_err(|error| format!("protect snapshot artifact: {error}"))?;
            fs::File::open(&path)
                .and_then(|file| file.sync_all())
                .map_err(|error| format!("sync snapshot artifact: {error}"))?;
        }
        fs::File::open(&temporary)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("sync snapshot directory: {error}"))?;
        match fs::rename(&temporary, &destination) {
            Ok(()) => Ok(()),
            Err(error)
                if error.kind() == std::io::ErrorKind::AlreadyExists
                    && snapshot_available(config, key)? =>
            {
                Ok(())
            }
            Err(error) => Err(format!("publish snapshot: {error}")),
        }
    })();

    if temporary.exists() {
        let _ = fs::remove_dir_all(&temporary);
    }
    published?;
    prune_snapshots(config, key)
}

fn prune_snapshots(config: &Config, keep: &str) -> Result<(), String> {
    let mut snapshots = fs::read_dir(&config.snapshot_base)
        .map_err(|error| format!("read snapshot base: {error}"))?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let key = entry.file_name().into_string().ok()?;
            if key == keep || validate_snapshot_key(&key).is_err() || !entry.path().is_dir() {
                return None;
            }
            let modified = entry.metadata().ok()?.modified().ok()?;
            Some((modified, entry.path()))
        })
        .collect::<Vec<_>>();
    snapshots.sort_by_key(|(modified, _path)| std::cmp::Reverse(*modified));
    for (_modified, path) in snapshots.into_iter().skip(SNAPSHOT_BASE_LIMIT - 1) {
        fs::remove_dir_all(&path)
            .map_err(|error| format!("remove obsolete snapshot {}: {error}", path.display()))?;
    }
    Ok(())
}

pub(crate) fn stage_snapshot(config: &Config, layout: &Layout, key: &str) -> Result<(), String> {
    if !snapshot_available(config, key)? {
        return Err("prepared snapshot is unavailable".into());
    }
    let source = snapshot_root(config, key)?;
    let target = layout.root.join("snapshot");
    fs::create_dir(&target).map_err(|error| format!("create snapshot jail directory: {error}"))?;
    fs::set_permissions(&target, fs::Permissions::from_mode(0o555))
        .map_err(|error| format!("protect snapshot jail directory: {error}"))?;
    fs::hard_link(source.join("vmstate"), target.join("vmstate"))
        .map_err(|error| format!("stage snapshot state: {error}"))?;
    fs::hard_link(source.join("memory"), target.join("memory"))
        .map_err(|error| format!("stage snapshot memory: {error}"))
}

fn snapshot_root(config: &Config, key: &str) -> Result<PathBuf, String> {
    validate_snapshot_key(key)?;
    Ok(config.snapshot_base.join(key))
}

pub(crate) fn validate_snapshot_key(key: &str) -> Result<(), String> {
    if key.len() == 64
        && key
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        Ok(())
    } else {
        Err("invalid prepared snapshot key".into())
    }
}

fn validate_snapshot_file(path: &Path, owner: u32) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|error| format!("inspect snapshot {}: {error}", path.display()))?;
    if metadata.is_file()
        && !metadata.file_type().is_symlink()
        && metadata.len() > 0
        && metadata.uid() == owner
        && metadata.permissions().mode() & 0o022 == 0
    {
        Ok(())
    } else {
        Err(format!("invalid snapshot artifact {}", path.display()))
    }
}
