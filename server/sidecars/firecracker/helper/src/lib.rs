mod config;
mod layout;
mod lifecycle;
mod network;
mod snapshot;

pub use config::Config;
pub use layout::{validate_id, Layout};
pub use lifecycle::{cleanup, launch, prepare, reconcile, renew};
pub use network::network_host_init;
pub use snapshot::{publish_snapshot, remove_snapshot, snapshot_available};

pub const VERSION: &str = "2";
pub const CONFIG_PATH: &str = "/etc/agent-os/sidecar-helper.conf";
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

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
        assert!(snapshot::validate_snapshot_key(&"a".repeat(64)).is_ok());
        assert!(snapshot::validate_snapshot_key(&"A".repeat(64)).is_err());
        assert!(snapshot::validate_snapshot_key("../snapshot").is_err());
    }

    #[test]
    fn network_identity_is_deterministic_and_interface_safe() {
        let first = network::Network::for_id("sc_abcdefghijkl");
        let same = network::Network::for_id("sc_abcdefghijkl");
        let other = network::Network::for_id("sc_mnopqrstuvwx");
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
        assert!(network::validate_host_nft_table(valid, "eth0").is_ok());
        assert!(network::validate_host_nft_table(
            &valid.replace("oifname @guests drop", ""),
            "eth0"
        )
        .is_err());
        assert!(network::validate_host_nft_table(
            &valid.replace("hook input", "hook output"),
            "eth0"
        )
        .is_err());
        assert!(network::validate_host_nft_table(valid, "ens5").is_err());
    }
}
