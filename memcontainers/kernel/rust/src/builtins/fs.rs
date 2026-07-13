//! Path resolution shared by kernel control operations and guest syscalls.

use alloc::format;
use alloc::string::String;

use crate::vfs::KPath;

pub fn resolve_path(cwd: &str, path: &str) -> KPath {
    let normalized_path = path.strip_prefix("./").unwrap_or(path);
    // "." (or "./") denotes the cwd itself — resolve to it exactly rather than
    // appending a trailing "/." the VFS cannot resolve.
    if normalized_path == "." || normalized_path.is_empty() {
        return KPath::new(cwd);
    }
    if normalized_path.starts_with('/') {
        KPath::new(normalized_path)
    } else {
        let s: String = if cwd.ends_with('/') {
            format!("{}{}", cwd, normalized_path)
        } else {
            format!("{}/{}", cwd, normalized_path)
        };
        KPath::new(&s)
    }
}
