//! The virtual filesystem: the [`FileSystem`]/[`FileHandle`] traits (`traits`) and the
//! per-process namespace — a Plan 9-style copy-on-write mount table (`namespace`,
//! forthcoming). Concrete backends live in `fs/`.
//!
//! Port status: the trait layer has landed; `namespace` follows.

pub mod traits;

pub use traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom, SYSTEM_CALLER,
};
