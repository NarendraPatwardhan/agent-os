use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

pub const VERSION: &str = "1";
pub const CONFIG_PATH: &str = "/etc/agent-os/sidecar-helper.conf";
const RECONCILE_GRACE: Duration =
    Duration::from_millis(sidecar_rust::SIDECAR_MAX_RENEW_MS as u64 * 2);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub runner_uid: u32,
    pub runner_gid: u32,
    pub chroot_base: PathBuf,
    pub firecracker: PathBuf,
    pub jailer: PathBuf,
    pub kernel: PathBuf,
    pub initramfs: PathBuf,
    pub ip: PathBuf,
    pub nft: PathBuf,
    pub rm: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Layout {
    pub root: PathBuf,
    pub lease: PathBuf,
    pub api: PathBuf,
    pub vsock: PathBuf,
    pub cgroup: PathBuf,
    pub netns: String,
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        validate_trusted_ancestors(path)?;
        let metadata = fs::metadata(path).map_err(|error| format!("read config metadata: {error}"))?;
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
            if !matches!(
                key,
                "runner_uid"
                    | "runner_gid"
                    | "chroot_base"
                    | "firecracker"
                    | "jailer"
                    | "kernel"
                    | "initramfs"
                    | "ip"
                    | "nft"
                    | "rm"
            ) {
                return Err(format!("unknown config key {key}"));
            }
            if key.is_empty() || value.is_empty() || values.insert(key, value).is_some() {
                return Err(format!("invalid config line {}", index + 1));
            }
        }

        let get = |key| values.get(key).copied().ok_or_else(|| format!("missing {key}"));
        let path = |key| -> Result<PathBuf, String> {
            let out = PathBuf::from(get(key)?);
            if !out.is_absolute()
                || out.components().any(|part| {
                    matches!(
                        part,
                        std::path::Component::ParentDir | std::path::Component::CurDir
                    )
                })
            {
                return Err(format!("{key} must be an absolute normalized path"));
            }
            Ok(out)
        };

        let config = Self {
            runner_uid: get("runner_uid")?.parse().map_err(|_| "invalid runner_uid")?,
            runner_gid: get("runner_gid")?.parse().map_err(|_| "invalid runner_gid")?,
            chroot_base: path("chroot_base")?,
            firecracker: path("firecracker")?,
            jailer: path("jailer")?,
            kernel: path("kernel")?,
            initramfs: path("initramfs")?,
            ip: path("ip")?,
            nft: path("nft")?,
            rm: path("rm")?,
        };

        if config.runner_uid == 0 || config.runner_gid == 0 {
            return Err("runner uid/gid must be non-root".into());
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
            ("rm", &self.rm, true),
        ] {
            validate_trusted_ancestors(path).map_err(|error| format!("{label}: {error}"))?;
            let metadata = fs::metadata(path).map_err(|error| format!("{label}: {error}"))?;
            if !metadata.is_file()
                || metadata.uid() != 0
                || metadata.permissions().mode() & 0o022 != 0
            {
                return Err(format!(
                    "{label} must be a root-owned regular file not writable by group/other"
                ));
            }
            if executable && metadata.permissions().mode() & 0o111 == 0 {
                return Err(format!("{label} is not executable"));
            }
        }
        for (label, path) in [("chroot_base", &self.chroot_base)] {
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

    pub fn layout(&self, id: &str) -> Result<Layout, String> {
        validate_id(id)?;
        let executable = self
            .firecracker
            .file_name()
            .ok_or("firecracker path has no file name")?;
        let root = self.chroot_base.join(executable).join(id).join("root");
        let lease = root.parent().ok_or("jail root has no parent")?.join(".agentos-lease");
        Ok(Layout {
            api: root.join("run/firecracker.socket"),
            vsock: root.join("run/vsock.socket"),
            cgroup: PathBuf::from("/sys/fs/cgroup/agentos-sidecars")
                .join(executable)
                .join(id),
            netns: format!("agentos-{id}"),
            lease,
            root,
        })
    }
}

pub fn validate_id(id: &str) -> Result<(), String> {
    let valid = id.len() >= 15
        && id.len() <= 64
        && id.starts_with("sc_")
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-');
    if valid {
        Ok(())
    } else {
        Err("invalid sidecar id".into())
    }
}

pub fn prepare(config: &Config, id: &str) -> Result<Layout, String> {
    config.validate_installation()?;
    let layout = config.layout(id)?;
    cleanup(config, id)?;
    network_prepare(config, &layout)?;
    let staged = (|| {
        fs::create_dir_all(layout.root.join("run"))
            .map_err(|error| format!("create jail root: {error}"))?;
        create_lease(&layout.lease)?;
        copy_root_owned(&config.kernel, &layout.root.join("kernel"), 0o444)?;
        copy_root_owned(&config.initramfs, &layout.root.join("initramfs"), 0o444)?;
        Ok(layout.clone())
    })();
    if staged.is_err() {
        let _ = cleanup(config, id);
    }
    staged
}

pub fn network_host_init(config: &Config) -> Result<(), String> {
    let _ = checked(
        config.nft.as_path(),
        &["delete", "table", "inet", "agentos_sidecars"],
    );
    let script = b"table inet agentos_sidecars { chain forward { type filter hook forward priority 0; policy drop; } }\n";
    let mut child = Command::new(&config.nft)
        .args(["-f", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("start nft: {error}"))?;
    use std::io::Write;
    child
        .stdin
        .take()
        .ok_or("nft host-init stdin was not piped")?
        .write_all(script)
        .map_err(|error| format!("write nft: {error}"))?;
    checked_wait(child, "nft host-init")
}

pub fn network_prepare(config: &Config, layout: &Layout) -> Result<(), String> {
    delete_netns(config, &layout.netns)?;
    checked(config.ip.as_path(), &["netns", "add", &layout.netns])?;
    let configured = (|| {
        checked(
            config.ip.as_path(),
            &[
                "netns",
                "exec",
                &layout.netns,
                config.ip.to_str().ok_or("invalid ip path")?,
                "tuntap",
                "add",
                "dev",
                "tap0",
                "mode",
                "tap",
                "user",
                &config.runner_uid.to_string(),
            ],
        )?;
        checked(
            config.ip.as_path(),
            &[
                "netns",
                "exec",
                &layout.netns,
                config.ip.to_str().ok_or("invalid ip path")?,
                "link",
                "set",
                "tap0",
                "up",
            ],
        )
    })();
    if configured.is_err() {
        let _ = delete_netns(config, &layout.netns);
    }
    configured
}

pub fn launch(config: &Config, id: &str) -> Result<i32, String> {
    let layout = prepare(config, id)?;
    let status = Command::new(&config.ip)
        .args(["netns", "exec", &layout.netns])
        .arg(&config.jailer)
        .args([
            "--id",
            id,
            "--exec-file",
            config.firecracker.to_str().ok_or("invalid firecracker path")?,
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
    delete_netns(config, &layout.netns)?;
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
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.uid() != 0
        || metadata.permissions().mode() & 0o022 != 0
    {
        return Err("sidecar lease must be a root-owned regular file not writable by group/other".into());
    }
    fs::write(&layout.lease, b"1\n").map_err(|error| format!("renew sidecar lease: {error}"))
}

pub fn reconcile(config: &Config) -> Result<(), String> {
    let executable = config.firecracker.file_name().ok_or("invalid firecracker path")?;
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

fn delete_netns(config: &Config, name: &str) -> Result<(), String> {
    if Path::new("/run/netns").join(name).exists() {
        checked(config.ip.as_path(), &["netns", "del", name])?;
    }
    Ok(())
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

fn checked_wait(child: std::process::Child, label: &str) -> Result<(), String> {
    let output = child.wait_with_output().map_err(|error| format!("wait for {label}: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!("{label} failed: {}", String::from_utf8_lossy(&output.stderr).trim()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> &'static str {
        "runner_uid=1000\nrunner_gid=1000\nchroot_base=/var/lib/agent-os/jailer\nfirecracker=/opt/agent-os/firecracker\njailer=/opt/agent-os/jailer\nkernel=/opt/agent-os/vmlinux\ninitramfs=/opt/agent-os/initramfs\nip=/usr/bin/ip\nnft=/usr/bin/nft\nrm=/usr/bin/rm\n"
    }

    #[test]
    fn parses_strict_rooted_configuration() {
        let config = Config::parse(sample()).unwrap();
        assert_eq!(config.runner_uid, 1000);
        assert_eq!(config.layout("sc_abcdefghijkl").unwrap().netns, "agentos-sc_abcdefghijkl");
    }

    #[test]
    fn rejects_traversal_duplicate_keys_and_untrusted_ids() {
        assert!(Config::parse(&sample().replace("/var/lib/agent-os/jailer", "/var/lib/../tmp")).is_err());
        assert!(Config::parse(&(sample().to_owned() + "runner_uid=1001\n")).is_err());
        assert!(Config::parse(&(sample().to_owned() + "typo=/tmp\n")).is_err());
        assert!(validate_id("../../escape").is_err());
    }
}
