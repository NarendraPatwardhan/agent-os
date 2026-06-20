//! persistfs — a capability-backed filesystem mounted at
//! `/var/persist`. Its files are key/value entries in the host store reached via
//! `crate::persist` (the persistence bridge). This is the agent-visible shape
//! of persistence: the shell uses `cat`/`echo`/`ls`/`rm` and wasm guests use
//! `mc_sys_open`/`read`/`write` — both persist across kernel restarts through
//! one mechanism, with no host path or handle ever visible.
//!
//! The store is a flat KV (whole-value get/put), so a file handle buffers the
//! entire value and commits it on `Drop` (the `FileHandle` trait has no close;
//! `Drop` is the flush hook). When the host denies the capability every
//! operation returns `PermissionDenied`, surfaced to the agent as an ordinary
//! filesystem error — the kernel never aborts.

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use crate::persist::{self, PersistError};
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom,
};

/// Map a persist-layer error to a VFS error. Denial degrades to
/// `PermissionDenied` so it reads as a normal fs error.
fn fs_err(_e: PersistError) -> FsError {
    FsError::PermissionDenied
}

/// The key for a path relative to the mount. The namespace hands us paths like
/// `/`, `/foo`, `/a/b`; the key is that path without the leading slash (`""`
/// for the mount root itself).
fn key_of(rel: &KPath) -> Vec<u8> {
    rel.as_str()
        .trim_start_matches('/')
        .trim_end_matches('/')
        .as_bytes()
        .to_vec()
}

fn dir_prefix(key: &[u8]) -> Vec<u8> {
    let mut prefix = key.to_vec();
    if !prefix.is_empty() {
        prefix.push(b'/');
    }
    prefix
}

fn dir_exists(key: &[u8]) -> Result<bool> {
    if key.is_empty() {
        return Ok(true);
    }
    let prefix = dir_prefix(key);
    Ok(!persist::list(&prefix).map_err(fs_err)?.is_empty())
}

pub struct PersistFs;

impl PersistFs {
    pub fn new() -> Self {
        PersistFs
    }
}

impl Default for PersistFs {
    fn default() -> Self {
        Self::new()
    }
}

impl FileSystem for PersistFs {
    fn open(
        &mut self,
        path: &KPath,
        flags: OpenFlags,
        _caller: CallerId,
    ) -> Result<Box<dyn FileHandle>> {
        let key = key_of(path);
        if key.is_empty() {
            return Err(FsError::IsDir); // the mount root is a directory
        }
        // Probe the store: this both loads any existing value (for read /
        // append) and detects denial up front, so a denied write fails at
        // `open` rather than silently at flush.
        let existing = persist::get(&key).map_err(fs_err)?;
        let existed = existing.is_some();
        let buf = match existing {
            Some(_) if flags.truncate => Vec::new(),
            Some(v) => v,
            None if dir_exists(&key)? => return Err(FsError::IsDir),
            None if flags.create => Vec::new(),
            None => return Err(FsError::NotFound),
        };
        let offset = if flags.append { buf.len() as u64 } else { 0 };
        // A create/truncate open commits even an empty value (POSIX `>` makes
        // the key exist); a pure read open never writes.
        let dirty = flags.truncate || (flags.create && !existed);
        Ok(Box::new(PersistFileHandle {
            key,
            buf,
            offset,
            dirty,
        }))
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let key = key_of(path);
        if key.is_empty() {
            return Ok(Metadata::dir());
        }
        match persist::get(&key).map_err(fs_err)? {
            Some(v) => Ok(Metadata::file(v.len() as u64)),
            None if dir_exists(&key)? => Ok(Metadata::dir()),
            None => Err(FsError::NotFound),
        }
    }

    fn readdir(&self, path: &KPath, _caller: CallerId) -> Result<Vec<DirEntry>> {
        let key = key_of(path);
        if !key.is_empty() && persist::get(&key).map_err(fs_err)?.is_some() {
            return Err(FsError::NotDir);
        }

        // Root lists top-level keys; a non-root path lists immediate children
        // under `key/`. Directories are implicit in key prefixes, with empty
        // directory markers written by `mkdir`.
        let prefix = dir_prefix(&key);
        let keys = persist::list(&prefix).map_err(fs_err)?;
        if !key.is_empty() && keys.is_empty() {
            return Err(FsError::NotFound);
        }
        let mut entries: BTreeMap<String, NodeType> = BTreeMap::new();
        for k in keys {
            if !k.starts_with(&prefix) {
                continue;
            }
            let name_bytes = &k[prefix.len()..];
            if name_bytes.is_empty() {
                continue; // directory marker for `path` itself
            }
            let (name_bytes, kind) = match name_bytes.iter().position(|&b| b == b'/') {
                Some(0) => continue,
                Some(idx) => (&name_bytes[..idx], NodeType::Dir),
                None => (name_bytes, NodeType::File),
            };
            if let Ok(name) = core::str::from_utf8(name_bytes) {
                let name = String::from(name);
                entries
                    .entry(name)
                    .and_modify(|existing| {
                        if matches!(kind, NodeType::Dir) {
                            *existing = NodeType::Dir;
                        }
                    })
                    .or_insert(kind);
            }
        }
        Ok(entries
            .into_iter()
            .map(|(name, node_type)| DirEntry { name, node_type })
            .collect())
    }

    fn mkdir(&mut self, path: &KPath, _caller: CallerId) -> Result<()> {
        let key = key_of(path);
        if key.is_empty() {
            return Ok(());
        }
        if persist::get(&key).map_err(fs_err)?.is_some() {
            return Err(FsError::AlreadyExists);
        }
        let marker = dir_prefix(&key);
        persist::put(&marker, &[]).map_err(fs_err)
    }

    fn unlink(&mut self, path: &KPath, _caller: CallerId) -> Result<()> {
        let key = key_of(path);
        if key.is_empty() {
            return Err(FsError::IsDir);
        }
        if persist::get(&key).map_err(fs_err)?.is_some() {
            return persist::delete(&key).map_err(fs_err);
        }
        if dir_exists(&key)? {
            return Err(FsError::IsDir);
        }
        Err(FsError::NotFound)
    }

    fn rename(&mut self, from: &KPath, to: &KPath, _caller: CallerId) -> Result<()> {
        let from_key = key_of(from);
        let to_key = key_of(to);
        if from_key.is_empty() || to_key.is_empty() {
            return Err(FsError::IsDir);
        }
        let value = match persist::get(&from_key).map_err(fs_err)? {
            Some(v) => v,
            None if dir_exists(&from_key)? => return Err(FsError::IsDir),
            None => return Err(FsError::NotFound),
        };
        if dir_exists(&to_key)? {
            return Err(FsError::IsDir);
        }
        persist::put(&to_key, &value).map_err(fs_err)?;
        persist::delete(&from_key).map_err(fs_err)
    }
}

/// An open persistfs entry: the whole value is buffered; writes mutate the
/// buffer and the final value is committed to the KV store on `Drop`.
struct PersistFileHandle {
    key: Vec<u8>,
    buf: Vec<u8>,
    offset: u64,
    dirty: bool,
}

impl FileHandle for PersistFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let start = (self.offset as usize).min(self.buf.len());
        let n = (self.buf.len() - start).min(buf.len());
        buf[..n].copy_from_slice(&self.buf[start..start + n]);
        self.offset += n as u64;
        Ok(n)
    }

    fn write(&mut self, data: &[u8]) -> Result<usize> {
        let start = self.offset as usize;
        let end = start + data.len();
        if end > self.buf.len() {
            self.buf.resize(end, 0);
        }
        self.buf[start..end].copy_from_slice(data);
        self.offset = end as u64;
        self.dirty = true;
        Ok(data.len())
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let len = self.buf.len() as i64;
        let new = match pos {
            SeekFrom::Start(o) => o as i64,
            SeekFrom::Current(d) => self.offset as i64 + d,
            SeekFrom::End(d) => len + d,
        };
        if new < 0 {
            return Err(FsError::InvalidPath);
        }
        self.offset = new as u64;
        Ok(self.offset)
    }

    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(self.buf.len() as u64))
    }

    fn truncate(&mut self, size: u64) -> Result<()> {
        // Grow zero-fills, shrink drops the tail; committed to the KV store on
        // Drop. The offset is left unchanged (POSIX ftruncate semantics).
        self.buf.resize(size as usize, 0);
        self.dirty = true;
        Ok(())
    }
}

impl Drop for PersistFileHandle {
    fn drop(&mut self) {
        // Commit the whole value on close. Best-effort: `Drop` cannot report
        // an error, and a denied capability was already rejected at `open`.
        if self.dirty {
            let _ = persist::put(&self.key, &self.buf);
        }
    }
}
