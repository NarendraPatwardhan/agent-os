use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub runner_uid: u32,
    pub runner_gid: u32,
    pub chroot_base: PathBuf,
    pub firecracker: PathBuf,
    pub jailer: PathBuf,
    pub kernel: PathBuf,
    pub initramfs: PathBuf,
    pub snapshot_base: PathBuf,
    pub profiles: BTreeMap<String, PathBuf>,
    pub uplink: String,
    pub ip: PathBuf,
    pub nft: PathBuf,
    pub sysctl: PathBuf,
    pub rm: PathBuf,
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        validate_trusted_ancestors(path)?;
        let metadata =
            fs::metadata(path).map_err(|error| format!("read config metadata: {error}"))?;
        if metadata.uid() != 0 || metadata.permissions().mode() & 0o022 != 0 {
            return Err("config must be root-owned and not group/other writable".into());
        }
        Self::parse(&fs::read_to_string(path).map_err(|error| format!("read config: {error}"))?)
    }

    pub fn parse(contents: &str) -> Result<Self, String> {
        let mut values = BTreeMap::new();
        for (index, raw) in contents.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| format!("invalid config line {}", index + 1))?;
            if !key.starts_with("profile.")
                && !matches!(
                    key,
                    "runner_uid"
                        | "runner_gid"
                        | "chroot_base"
                        | "firecracker"
                        | "jailer"
                        | "kernel"
                        | "initramfs"
                        | "snapshot_base"
                        | "uplink"
                        | "ip"
                        | "nft"
                        | "sysctl"
                        | "rm"
                )
            {
                return Err(format!("unknown config key {key}"));
            }
            if key.is_empty() || value.is_empty() || values.insert(key, value).is_some() {
                return Err(format!("invalid config line {}", index + 1));
            }
        }

        let get = |key| {
            values
                .get(key)
                .copied()
                .ok_or_else(|| format!("missing {key}"))
        };
        let path = |key| -> Result<PathBuf, String> {
            let out = PathBuf::from(get(key)?);
            validate_normalized_path(&out, key)?;
            Ok(out)
        };

        let profiles = values
            .iter()
            .filter_map(|(key, value)| key.strip_prefix("profile.").map(|name| (name, *value)))
            .map(|(name, value)| {
                validate_profile(name)?;
                let out = PathBuf::from(value);
                validate_normalized_path(&out, "profile initramfs")?;
                Ok((name.to_owned(), out))
            })
            .collect::<Result<BTreeMap<_, _>, String>>()?;

        let config = Self {
            runner_uid: get("runner_uid")?
                .parse()
                .map_err(|_| "invalid runner_uid")?,
            runner_gid: get("runner_gid")?
                .parse()
                .map_err(|_| "invalid runner_gid")?,
            chroot_base: path("chroot_base")?,
            firecracker: path("firecracker")?,
            jailer: path("jailer")?,
            kernel: path("kernel")?,
            initramfs: path("initramfs")?,
            snapshot_base: path("snapshot_base")?,
            profiles,
            uplink: get("uplink")?.to_owned(),
            ip: path("ip")?,
            nft: path("nft")?,
            sysctl: path("sysctl")?,
            rm: path("rm")?,
        };

        if config.runner_uid == 0 || config.runner_gid == 0 {
            return Err("runner uid/gid must be non-root".into());
        }
        if config.uplink.is_empty()
            || config.uplink.len() > 15
            || !config
                .uplink
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
        {
            return Err("uplink must be a valid interface name".into());
        }
        Ok(config)
    }

    pub fn validate_installation(&self) -> Result<(), String> {
        for (label, path, executable) in [
            ("firecracker", &self.firecracker, true),
            ("jailer", &self.jailer, true),
            ("kernel", &self.kernel, false),
            ("initramfs", &self.initramfs, false),
            ("ip", &self.ip, true),
            ("nft", &self.nft, true),
            ("sysctl", &self.sysctl, true),
            ("rm", &self.rm, true),
        ] {
            validate_artifact(label, path, executable)?;
        }
        for (profile, path) in &self.profiles {
            validate_artifact(&format!("profile.{profile}"), path, false)?;
        }
        for (label, path) in [
            ("chroot_base", &self.chroot_base),
            ("snapshot_base", &self.snapshot_base),
        ] {
            validate_trusted_ancestors(path).map_err(|error| format!("{label}: {error}"))?;
            let metadata = fs::metadata(path).map_err(|error| format!("{label}: {error}"))?;
            if !metadata.is_dir()
                || metadata.uid() != 0
                || metadata.permissions().mode() & 0o022 != 0
            {
                return Err(format!(
                    "{label} must be a root-owned directory not writable by group/other"
                ));
            }
        }
        Ok(())
    }

    pub fn initramfs(&self, profile: Option<&str>) -> Result<&Path, String> {
        match profile {
            Some(name) => {
                validate_profile(name)?;
                self.profiles
                    .get(name)
                    .map(PathBuf::as_path)
                    .ok_or_else(|| format!("unknown runner profile {name}"))
            }
            None => Ok(&self.initramfs),
        }
    }
}

fn validate_artifact(label: &str, path: &Path, executable: bool) -> Result<(), String> {
    validate_trusted_ancestors(path).map_err(|error| format!("{label}: {error}"))?;
    let metadata = fs::metadata(path).map_err(|error| format!("{label}: {error}"))?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.permissions().mode() & 0o022 != 0 {
        return Err(format!(
            "{label} must be a root-owned regular file not writable by group/other"
        ));
    }
    if executable && metadata.permissions().mode() & 0o111 == 0 {
        return Err(format!("{label} is not executable"));
    }
    Ok(())
}

fn validate_normalized_path(path: &Path, label: &str) -> Result<(), String> {
    if !path.is_absolute()
        || path.components().any(|part| {
            matches!(
                part,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )
        })
    {
        return Err(format!("{label} must be an absolute normalized path"));
    }
    Ok(())
}

fn validate_profile(profile: &str) -> Result<(), String> {
    if !profile.is_empty()
        && profile.len() <= 32
        && profile
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        Ok(())
    } else {
        Err("invalid runner profile".into())
    }
}

fn validate_trusted_ancestors(path: &Path) -> Result<(), String> {
    let mut current = path.parent();
    while let Some(directory) = current {
        let metadata = fs::metadata(directory)
            .map_err(|error| format!("inspect {}: {error}", directory.display()))?;
        if !metadata.is_dir() || metadata.uid() != 0 || metadata.permissions().mode() & 0o022 != 0 {
            return Err(format!(
                "{} must be a root-owned directory not writable by group/other",
                directory.display()
            ));
        }
        current = directory.parent();
    }
    Ok(())
}
