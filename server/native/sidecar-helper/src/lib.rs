use std::collections::BTreeMap;
use std::fs;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

pub const VERSION: &str = "2";
pub const CONFIG_PATH: &str = "/etc/agent-os/sidecar-helper.conf";
const RECONCILE_GRACE: Duration =
    Duration::from_millis(sidecar_rust::SIDECAR_MAX_RENEW_MS as u64 * 2);
const SNAPSHOT_BASE_LIMIT: usize = 2;

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

    pub fn layout(&self, id: &str) -> Result<Layout, String> {
        validate_id(id)?;
        let executable = self
            .firecracker
            .file_name()
            .ok_or("firecracker path has no file name")?;
        let root = self.chroot_base.join(executable).join(id).join("root");
        let lease = root
            .parent()
            .ok_or("jail root has no parent")?
            .join(".agentos-lease");
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
        network_prepare(config, &layout)?;
    } else {
        namespace_prepare(config, &layout)?;
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

pub fn network_host_init(config: &Config) -> Result<(), String> {
    let _lock = NetworkLock::acquire()?;
    validate_uplink(config)?;
    fs::write("/proc/sys/net/ipv4/ip_forward", b"1\n")
        .map_err(|error| format!("enable host IPv4 forwarding: {error}"))?;
    let existing = Command::new(&config.nft)
        .args(["list", "table", "inet", "agentos_sidecars"])
        .output()
        .map_err(|error| format!("inspect sidecar nft table: {error}"))?;
    if existing.status.success() {
        return validate_host_nft_table(&String::from_utf8_lossy(&existing.stdout), &config.uplink);
    }
    let script = format!(
        "table inet agentos_sidecars {{\n  set guests {{ type ifname; }}\n  set non_public_v4 {{ type ipv4_addr; flags interval; elements = {{ 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.31.196.0/24, 192.52.193.0/24, 192.88.99.0/24, 192.168.0.0/16, 192.175.48.0/24, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 }}; }}\n  chain input {{ type filter hook input priority filter; policy accept; iifname @guests drop; }}\n  chain forward {{ type filter hook forward priority filter; policy accept; iifname @guests ip daddr @non_public_v4 drop; iifname @guests oifname \"{}\" accept; iifname \"{}\" oifname @guests ct state established,related accept; iifname @guests drop; oifname @guests drop; }}\n  chain postrouting {{ type nat hook postrouting priority srcnat; policy accept; oifname \"{}\" ip saddr 100.64.0.0/10 masquerade; }}\n}}\n",
        config.uplink, config.uplink, config.uplink
    );
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
        .write_all(script.as_bytes())
        .map_err(|error| format!("write nft: {error}"))?;
    checked_wait(child, "nft host-init")
}

pub fn network_prepare(config: &Config, layout: &Layout) -> Result<(), String> {
    let _lock = NetworkLock::acquire()?;
    validate_uplink(config)?;
    let network = Network::for_id(
        layout
            .netns
            .strip_prefix("agentos-")
            .ok_or("invalid network namespace")?,
    );
    if command_has_output(
        config.ip.as_path(),
        &["-4", "route", "show", "exact", &network.host_address],
    )? {
        return Err("sidecar network address collision".into());
    }
    namespace_prepare(config, layout)?;
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
                "addr",
                "add",
                "172.30.0.1/24",
                "dev",
                "tap0",
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
        )?;
        checked(
            config.ip.as_path(),
            &[
                "link",
                "add",
                &network.host_interface,
                "type",
                "veth",
                "peer",
                "name",
                &network.guest_interface,
            ],
        )?;
        checked(
            config.ip.as_path(),
            &[
                "link",
                "set",
                "dev",
                &network.host_interface,
                "alias",
                &network.alias,
            ],
        )?;
        checked(
            config.ip.as_path(),
            &[
                "link",
                "set",
                &network.guest_interface,
                "netns",
                &layout.netns,
            ],
        )?;
        checked(
            config.ip.as_path(),
            &[
                "addr",
                "add",
                &network.host_address,
                "dev",
                &network.host_interface,
            ],
        )?;
        checked(
            config.ip.as_path(),
            &["link", "set", &network.host_interface, "up"],
        )?;
        for args in [
            vec!["link", "set", "lo", "up"],
            vec!["link", "set", &network.guest_interface, "name", "uplink0"],
            vec!["addr", "add", &network.guest_address, "dev", "uplink0"],
            vec!["link", "set", "uplink0", "up"],
            vec![
                "route",
                "add",
                "default",
                "via",
                &network.host_ip,
                "dev",
                "uplink0",
            ],
        ] {
            let mut command = vec![
                "netns",
                "exec",
                &layout.netns,
                config.ip.to_str().ok_or("invalid ip path")?,
            ];
            command.extend(args);
            checked(config.ip.as_path(), &command)?;
        }
        fs::write(
            Path::new("/proc/sys/net/ipv4/conf")
                .join(&network.host_interface)
                .join("rp_filter"),
            b"0\n",
        )
        .map_err(|error| format!("disable veth reverse-path filter: {error}"))?;
        checked(
            config.ip.as_path(),
            &[
                "netns",
                "exec",
                &layout.netns,
                config.sysctl.to_str().ok_or("invalid sysctl path")?,
                "-qw",
                "net.ipv4.ip_forward=1",
            ],
        )?;
        netns_nft(config, &layout.netns)?;
        let element = format!("{{ \"{}\" }}", network.host_interface);
        checked(
            config.nft.as_path(),
            &[
                "add",
                "element",
                "inet",
                "agentos_sidecars",
                "guests",
                &element,
            ],
        )
    })();
    if configured.is_err() {
        let _ = delete_netns(config, &layout.netns);
        let _ = delete_owned_link(config, &network);
    }
    configured
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
        stage_snapshot(config, &layout, key)?;
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

fn stage_snapshot(config: &Config, layout: &Layout, key: &str) -> Result<(), String> {
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

fn validate_snapshot_key(key: &str) -> Result<(), String> {
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

pub fn cleanup(config: &Config, id: &str) -> Result<(), String> {
    let layout = config.layout(id)?;
    if layout.cgroup.join("cgroup.kill").exists() {
        fs::write(layout.cgroup.join("cgroup.kill"), b"1\n")
            .map_err(|error| format!("kill cgroup: {error}"))?;
    }
    wait_for_empty_cgroup(&layout.cgroup)?;
    network_cleanup(config, id, &layout.netns)?;
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

fn network_cleanup(config: &Config, id: &str, netns: &str) -> Result<(), String> {
    let _lock = NetworkLock::acquire()?;
    let network = Network::for_id(id);
    let ownership = link_ownership(&network)?;
    if ownership != LinkOwnership::Foreign {
        let element = format!("{{ \"{}\" }}", network.host_interface);
        let _ = checked(
            config.nft.as_path(),
            &[
                "delete",
                "element",
                "inet",
                "agentos_sidecars",
                "guests",
                &element,
            ],
        );
    }
    delete_netns(config, netns)?;
    delete_owned_link(config, &network)
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

struct Network {
    host_interface: String,
    guest_interface: String,
    alias: String,
    host_ip: String,
    host_address: String,
    guest_address: String,
}

impl Network {
    fn for_id(id: &str) -> Self {
        let hash = id.bytes().fold(0x811c9dc5_u32, |value, byte| {
            (value ^ u32::from(byte)).wrapping_mul(0x01000193)
        });
        let slot = hash & 0x001f_ffff;
        let first = u32::from_be_bytes([100, 64, 0, 0]) + slot * 2;
        let host_ip = ipv4(first);
        let guest_ip = ipv4(first + 1);
        Self {
            host_interface: format!("aoh{hash:08x}"),
            guest_interface: format!("aon{hash:08x}"),
            alias: format!("agentos:{id}"),
            host_address: format!("{host_ip}/31"),
            guest_address: format!("{guest_ip}/31"),
            host_ip,
        }
    }
}

fn ipv4(value: u32) -> String {
    let bytes = value.to_be_bytes();
    format!("{}.{}.{}.{}", bytes[0], bytes[1], bytes[2], bytes[3])
}

struct NetworkLock(fs::File);

impl NetworkLock {
    fn acquire() -> Result<Self, String> {
        const LOCK_EX: i32 = 2;
        const O_CLOEXEC: i32 = 0o2000000;
        const O_NOFOLLOW: i32 = 0o400000;
        let file = fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(O_CLOEXEC | O_NOFOLLOW)
            .open("/run/agent-os-sidecar-network.lock")
            .map_err(|error| format!("open network lock: {error}"))?;
        let metadata = file
            .metadata()
            .map_err(|error| format!("inspect network lock: {error}"))?;
        if !metadata.is_file() || metadata.uid() != 0 || metadata.permissions().mode() & 0o077 != 0
        {
            return Err("network lock must be a root-owned private regular file".into());
        }
        if unsafe { flock(file.as_raw_fd(), LOCK_EX) } != 0 {
            return Err("lock sidecar network state failed".into());
        }
        Ok(Self(file))
    }
}

impl Drop for NetworkLock {
    fn drop(&mut self) {
        const LOCK_UN: i32 = 8;
        let _ = unsafe { flock(self.0.as_raw_fd(), LOCK_UN) };
    }
}

extern "C" {
    fn flock(fd: i32, operation: i32) -> i32;
}

fn owns_link(network: &Network) -> Result<bool, String> {
    Ok(link_ownership(network)? == LinkOwnership::Owned)
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum LinkOwnership {
    Missing,
    Owned,
    Foreign,
}

fn link_ownership(network: &Network) -> Result<LinkOwnership, String> {
    let alias = Path::new("/sys/class/net")
        .join(&network.host_interface)
        .join("ifalias");
    match fs::read_to_string(alias) {
        Ok(value) if value.trim_end() == network.alias => Ok(LinkOwnership::Owned),
        Ok(_) => Ok(LinkOwnership::Foreign),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(LinkOwnership::Missing),
        Err(error) => Err(format!("inspect sidecar veth alias: {error}")),
    }
}

fn delete_owned_link(config: &Config, network: &Network) -> Result<(), String> {
    if owns_link(network)? {
        checked(
            config.ip.as_path(),
            &["link", "delete", &network.host_interface],
        )?;
    }
    Ok(())
}

fn netns_nft(config: &Config, netns: &str) -> Result<(), String> {
    let script = b"table ip agentos_guest { chain postrouting { type nat hook postrouting priority srcnat; policy accept; oifname \"uplink0\" ip saddr 172.30.0.0/24 masquerade; } }\n";
    let mut child = Command::new(&config.ip)
        .args(["netns", "exec", netns])
        .arg(&config.nft)
        .args(["-f", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("start netns nft: {error}"))?;
    use std::io::Write;
    child
        .stdin
        .take()
        .ok_or("netns nft stdin was not piped")?
        .write_all(script)
        .map_err(|error| format!("write netns nft: {error}"))?;
    checked_wait(child, "netns nft")
}

fn validate_uplink(config: &Config) -> Result<(), String> {
    if Path::new("/sys/class/net").join(&config.uplink).is_dir() {
        Ok(())
    } else {
        Err(format!("uplink interface {} does not exist", config.uplink))
    }
}

fn namespace_prepare(config: &Config, layout: &Layout) -> Result<(), String> {
    delete_netns(config, &layout.netns)?;
    checked(config.ip.as_path(), &["netns", "add", &layout.netns])
}

fn delete_netns(config: &Config, name: &str) -> Result<(), String> {
    if Path::new("/run/netns").join(name).exists() {
        checked(config.ip.as_path(), &["netns", "del", name])?;
    }
    Ok(())
}

fn validate_host_nft_table(table: &str, uplink: &str) -> Result<(), String> {
    let uplink = format!("\"{uplink}\"");
    let required = [
        "set guests",
        "type ifname",
        "set non_public_v4",
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.0.0.0/24",
        "192.0.2.0/24",
        "192.31.196.0/24",
        "192.52.193.0/24",
        "192.88.99.0/24",
        "192.168.0.0/16",
        "192.175.48.0/24",
        "198.18.0.0/15",
        "198.51.100.0/24",
        "203.0.113.0/24",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "iifname @guests ip daddr @non_public_v4 drop",
        "chain input",
        "hook input",
        "hook forward",
        "hook postrouting",
        "iifname @guests drop",
        "oifname @guests drop",
        "ct state established,related accept",
        "ip saddr 100.64.0.0/10 masquerade",
    ];
    if required.iter().all(|fragment| table.contains(fragment))
        && table.matches("iifname @guests drop").count() >= 2
        && table.matches(&uplink).count() >= 3
    {
        Ok(())
    } else {
        Err("existing agentos_sidecars nft table does not match this helper configuration; stop sidecars, remove the table, and run network-host-init again".into())
    }
}

fn command_has_output(program: &Path, args: &[&str]) -> Result<bool, String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| format!("start {}: {error}", program.display()))?;
    if !output.status.success() {
        return Err(format!(
            "{} failed: {}",
            program.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(!output.stdout.is_empty())
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
    let output = child
        .wait_with_output()
        .map_err(|error| format!("wait for {label}: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{label} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> &'static str {
        "runner_uid=1000\nrunner_gid=1000\nchroot_base=/var/lib/agent-os/jailer\nfirecracker=/opt/agent-os/firecracker\njailer=/opt/agent-os/jailer\nkernel=/opt/agent-os/vmlinux\ninitramfs=/opt/agent-os/initramfs\nsnapshot_base=/var/lib/agent-os/snapshots\nuplink=eth0\nip=/usr/bin/ip\nnft=/usr/bin/nft\nsysctl=/usr/sbin/sysctl\nrm=/usr/bin/rm\n"
    }

    #[test]
    fn parses_strict_rooted_configuration() {
        let config = Config::parse(sample()).unwrap();
        assert_eq!(config.runner_uid, 1000);
        assert_eq!(
            config.layout("sc_abcdefghijkl").unwrap().netns,
            "agentos-sc_abcdefghijkl"
        );
        assert_eq!(
            config.snapshot_base,
            PathBuf::from("/var/lib/agent-os/snapshots")
        );
    }

    #[test]
    fn parses_named_runner_profiles() {
        let config = Config::parse(
            &(sample().to_owned()
                + "profile.browser=/opt/agent-os/sidecars/browser-initramfs.cpio\n"),
        )
        .unwrap();
        assert_eq!(
            config.initramfs(Some("browser")).unwrap(),
            Path::new("/opt/agent-os/sidecars/browser-initramfs.cpio")
        );
        assert!(config.initramfs(Some("missing")).is_err());
    }

    #[test]
    fn rejects_traversal_duplicate_keys_and_untrusted_ids() {
        assert!(
            Config::parse(&sample().replace("/var/lib/agent-os/jailer", "/var/lib/../tmp"))
                .is_err()
        );
        assert!(Config::parse(&(sample().to_owned() + "runner_uid=1001\n")).is_err());
        assert!(Config::parse(&(sample().to_owned() + "typo=/tmp\n")).is_err());
        assert!(Config::parse(&sample().replace("uplink=eth0", "uplink=../eth0")).is_err());
        assert!(Config::parse(&(sample().to_owned() + "profile.Bad=/tmp/rootfs\n")).is_err());
        assert!(validate_id("../../escape").is_err());
        assert!(validate_snapshot_key(&"a".repeat(64)).is_ok());
        assert!(validate_snapshot_key(&"A".repeat(64)).is_err());
        assert!(validate_snapshot_key("../snapshot").is_err());
    }

    #[test]
    fn network_identity_is_deterministic_and_interface_safe() {
        let first = Network::for_id("sc_abcdefghijkl");
        let same = Network::for_id("sc_abcdefghijkl");
        let other = Network::for_id("sc_mnopqrstuvwx");
        assert_eq!(first.host_interface, same.host_interface);
        assert_eq!(first.host_address, same.host_address);
        assert_ne!(first.host_interface, other.host_interface);
        assert!(first.host_interface.len() <= 15);
        assert!(first.guest_interface.len() <= 15);
        assert_eq!(first.alias, "agentos:sc_abcdefghijkl");
    }

    #[test]
    fn existing_network_table_must_keep_outbound_only_rules() {
        let valid = r#"
            table inet agentos_sidecars {
              set guests { type ifname; }
              set non_public_v4 { type ipv4_addr; flags interval; elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.31.196.0/24, 192.52.193.0/24, 192.88.99.0/24, 192.168.0.0/16, 192.175.48.0/24, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 } }
              chain input { type filter hook input priority filter; policy accept; iifname @guests drop }
              chain forward { type filter hook forward priority filter; policy accept;
                iifname @guests ip daddr @non_public_v4 drop
                iifname @guests oifname "eth0" accept
                iifname "eth0" oifname @guests ct state established,related accept
                iifname @guests drop
                oifname @guests drop
              }
              chain postrouting { type nat hook postrouting priority srcnat; policy accept; oifname "eth0" ip saddr 100.64.0.0/10 masquerade }
            }
        "#;
        assert!(validate_host_nft_table(valid, "eth0").is_ok());
        assert!(
            validate_host_nft_table(&valid.replace("oifname @guests drop", ""), "eth0").is_err()
        );
        assert!(
            validate_host_nft_table(&valid.replace("hook input", "hook output"), "eth0").is_err()
        );
        assert!(validate_host_nft_table(valid, "ens5").is_err());
    }
}
