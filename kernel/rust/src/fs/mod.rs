//! Filesystem backends — the concrete [`FileSystem`](crate::vfs::traits::FileSystem)
//! implementations the VFS mounts into a namespace (in-memory, copy-on-write,
//! overlay, tar-backed, host-backed, guest-served, network, and the synthetic
//! `dev`/`proc`/`env` trees).

pub mod cowfs;
pub mod devfs;
pub mod envfs;
pub mod memfs;
pub mod mountfs;
pub mod netfs;
pub mod overlayfs;
pub mod persistfs;
pub mod procfs;
pub mod proxy;
pub mod servedfs;
pub mod servicefs;
pub mod tarfs;
pub mod utils;

pub use cowfs::CowFs;
pub use devfs::DevFs;
pub use envfs::EnvFs;
pub use memfs::MemFs;
pub use mountfs::MountFs;
pub use netfs::NetFs;
pub use overlayfs::OverlayFs;
pub use persistfs::PersistFs;
pub use procfs::ProcFs;
pub use servedfs::{ServeChannel, ServedFs};
pub use tarfs::TarFs;
