//! The virtual filesystem: the [`FileSystem`]/[`FileHandle`] traits (`traits`) and the
//! per-process namespace — a Plan 9-style copy-on-write mount table (`namespace`,
//! forthcoming). Concrete backends live in `fs/`.
//!
pub mod namespace;
pub mod traits;

pub use namespace::Namespace;
pub use traits::*;
