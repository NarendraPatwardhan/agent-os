use std::fs;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::process::{Command, Stdio};

use crate::{Config, Layout};

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

pub(crate) fn prepare(config: &Config, layout: &Layout) -> Result<(), String> {
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

pub(crate) fn cleanup(config: &Config, id: &str, netns: &str) -> Result<(), String> {
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

pub(crate) struct Network {
    pub(crate) host_interface: String,
    pub(crate) guest_interface: String,
    pub(crate) alias: String,
    host_ip: String,
    pub(crate) host_address: String,
    guest_address: String,
}

impl Network {
    pub(crate) fn for_id(id: &str) -> Self {
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

pub(crate) fn namespace_prepare(config: &Config, layout: &Layout) -> Result<(), String> {
    delete_netns(config, &layout.netns)?;
    checked(config.ip.as_path(), &["netns", "add", &layout.netns])
}

fn delete_netns(config: &Config, name: &str) -> Result<(), String> {
    if Path::new("/run/netns").join(name).exists() {
        checked(config.ip.as_path(), &["netns", "del", name])?;
    }
    Ok(())
}

pub(crate) fn validate_host_nft_table(table: &str, uplink: &str) -> Result<(), String> {
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
