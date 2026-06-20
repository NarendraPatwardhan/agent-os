//! Shared substrate for the two PROXY filesystems — `servedfs` (ops answered by a
//! guest server) and `mountfs` (ops answered by a host driver). Both proxy each VFS
//! op to an out-of-kernel server and answer out of the bytes it returns, so the
//! on-the-wire layouts — the 44-byte stat record and the typed READDIR entries —
//! are an ABI contract they MUST agree on. Keeping the decoders here (rather than
//! duplicated per filesystem) is exactly the drift the `abi` SERVE/MOUNT comment
//! warns against. (The network-facing wire protocol is a separate concern — see the
//! `wire` crate; this is the in-kernel fs-op proxy layer.)
//!
//! The metadata cache is the synchronous-`stat` substrate: path resolution needs a
//! non-yielding `stat`, so a host-backed filesystem serves resolution from learned
//! metadata (or a provisional directory) and confirms terminal `stat` via a real
//! (yieldable) request. The helpers here mutate a plain `BTreeMap<String,
//! Metadata>` the filesystem owns.

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use crate::wasm::abi::{SERVE_DIRENT_DIR, SERVE_DIRENT_FILE, SERVE_DIRENT_SYMLINK};

use crate::vfs::traits::{DirEntry, FsError, Metadata, NodeType, Result};

/// The fixed length of a serialized stat record: `[size:u64][node_type:u32]
/// [nlink:u32][mode:u32][mtime:i64][atime:i64][ctime:i64]`, little-endian.
pub const STAT_RECORD_LEN: usize = 44;

fn u32_at(data: &[u8], off: usize) -> Result<u32> {
    let end = off.checked_add(4).ok_or(FsError::IoError)?;
    let bytes = data.get(off..end).ok_or(FsError::IoError)?;
    Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn u64_at(data: &[u8], off: usize) -> Result<u64> {
    let end = off.checked_add(8).ok_or(FsError::IoError)?;
    let bytes = data.get(off..end).ok_or(FsError::IoError)?;
    Ok(u64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]))
}

fn i64_at(data: &[u8], off: usize) -> Result<i64> {
    let end = off.checked_add(8).ok_or(FsError::IoError)?;
    let bytes = data.get(off..end).ok_or(FsError::IoError)?;
    Ok(i64::from_le_bytes([
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    ]))
}

/// Parse a [`STAT_RECORD_LEN`]-byte stat record. A served/host symlink would need
/// a READLINK op too, so we fail rather than cache a symlink whose target the
/// namespace cannot read (matching the dirent rule below).
pub fn parse_metadata(data: &[u8]) -> Result<Metadata> {
    if data.len() != STAT_RECORD_LEN {
        return Err(FsError::IoError);
    }
    let size = u64_at(data, 0)?;
    let node_type = match u32_at(data, 8)? {
        0 => NodeType::File,
        1 => NodeType::Dir,
        2 => return Err(FsError::NotImplemented),
        _ => return Err(FsError::IoError),
    };
    Ok(Metadata {
        node_type,
        size,
        nlink: u32_at(data, 12)?,
        mode: u32_at(data, 16)? as u16,
        mtime: i64_at(data, 20)?,
        atime: i64_at(data, 28)?,
        ctime: i64_at(data, 36)?,
    })
}

fn dirent_meta(kind: u32) -> Result<(NodeType, Metadata)> {
    match kind {
        SERVE_DIRENT_FILE => Ok((NodeType::File, Metadata::file(0))),
        SERVE_DIRENT_DIR => Ok((NodeType::Dir, Metadata::dir())),
        SERVE_DIRENT_SYMLINK => Err(FsError::NotImplemented),
        _ => Err(FsError::IoError),
    }
}

/// Join a server-relative `name` onto its `parent` directory path.
pub fn child_path(parent: &str, name: &str) -> String {
    let mut out = String::from(parent);
    if !out.ends_with('/') {
        out.push('/');
    }
    out.push_str(name);
    out
}

/// Parse a READDIR payload — repeated `[kind:u32][name_len:u32][name…]` — into
/// `(entry, absolute_child_path, learned_metadata)` triples. Rejects empty,
/// `.`/`..`, and names containing `/` or NUL so a malicious server cannot inject
/// a path-escape into the namespace.
pub fn parse_dirents(data: &[u8], parent: &str) -> Result<Vec<(DirEntry, String, Metadata)>> {
    let mut out = Vec::new();
    let mut off = 0usize;
    while off < data.len() {
        let kind = u32_at(data, off)?;
        let len_off = off.checked_add(4).ok_or(FsError::IoError)?;
        let len = u32_at(data, len_off)? as usize;
        let name_start = off.checked_add(8).ok_or(FsError::IoError)?;
        let name_end = name_start.checked_add(len).ok_or(FsError::IoError)?;
        let name_bytes = data.get(name_start..name_end).ok_or(FsError::IoError)?;
        let name = core::str::from_utf8(name_bytes).map_err(|_| FsError::IoError)?;
        if name.is_empty()
            || name == "."
            || name == ".."
            || name.as_bytes().iter().any(|&b| b == 0 || b == b'/')
        {
            return Err(FsError::IoError);
        }
        let (node_type, meta) = dirent_meta(kind)?;
        out.push((
            DirEntry {
                name: String::from(name),
                node_type,
            },
            child_path(parent, name),
            meta,
        ));
        off = name_end;
    }
    Ok(out)
}

// ---- metadata cache helpers (operate on a filesystem-owned map) ----

/// Server-proven metadata for `path`, if learned.
pub fn cached_meta(meta: &BTreeMap<String, Metadata>, path: &str) -> Option<Metadata> {
    meta.get(path).cloned()
}

/// Remember server-proven metadata for `path`.
pub fn remember_meta(meta: &mut BTreeMap<String, Metadata>, path: &str, m: Metadata) {
    meta.insert(String::from(path), m);
}

/// Forget `path` and everything beneath it (after a NotFound / unlink). The mount
/// root is never forgotten.
pub fn forget_path(meta: &mut BTreeMap<String, Metadata>, path: &str) {
    if path == "/" {
        return;
    }
    let mut prefix = String::from(path);
    if !prefix.ends_with('/') {
        prefix.push('/');
    }
    meta.retain(|p, _| p.as_str() != path && !p.starts_with(&prefix));
}

/// Move learned metadata from `from` (and its subtree) to `to` (after a rename).
pub fn rename_path(meta: &mut BTreeMap<String, Metadata>, from: &str, to: &str) {
    if from == "/" {
        return;
    }
    let mut from_prefix = String::from(from);
    if !from_prefix.ends_with('/') {
        from_prefix.push('/');
    }
    let mut moved = Vec::new();
    meta.retain(|p, m| {
        if p.as_str() == from || p.starts_with(&from_prefix) {
            moved.push((String::from(p.as_str()), m.clone()));
            false
        } else {
            true
        }
    });
    for (old, m) in moved {
        let suffix = if old == from { "" } else { &old[from.len()..] };
        let mut new_path = String::from(to);
        new_path.push_str(suffix);
        meta.insert(new_path, m);
    }
}

/// Drop the cached children of `dir` (but keep `dir` itself) before re-seeding
/// them from a fresh readdir.
pub fn forget_children_of(meta: &mut BTreeMap<String, Metadata>, dir: &str) {
    let mut prefix = String::from(dir);
    if !prefix.ends_with('/') {
        prefix.push('/');
    }
    meta.retain(|p, _| p.as_str() == dir || !p.starts_with(&prefix));
}
