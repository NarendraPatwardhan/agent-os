use std::path::PathBuf;

use crate::Config;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Layout {
    pub root: PathBuf,
    pub lease: PathBuf,
    pub api: PathBuf,
    pub vsock: PathBuf,
    pub cgroup: PathBuf,
    pub netns: String,
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

impl Config {
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
