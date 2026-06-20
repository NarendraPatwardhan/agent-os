//! In-memory filesystem with an inode + reference-count model.
//!
//! Names and nodes are many-to-one: `paths` maps a full path to an inode number,
//! and `inodes` maps that number to the node payload plus its hard-link count.
//! A hard link (`link`) adds a second path pointing at the same inode and bumps
//! `nlink`; the inode (and its bytes) is freed only when the last name is
//! unlinked. Symbolic links are ordinary inodes holding their target text — the
//! filesystem never *follows* them (that is the namespace canonicalizer's job);
//! every method here has lstat semantics. `rename` re-keys `paths` only; inodes
//! never move, so an open file descriptor survives a rename of its path.

use crate::vfs::KPath;
use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::collections::BTreeSet;
use alloc::string::String;
use alloc::vec::Vec;

use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, Metadata, NodeType, OpenFlags, Result,
    SeekFrom,
};

type Ino = u64;

/// An inode's payload: a file's bytes, a directory's child names, or a symbolic
/// link's (unresolved) target text.
#[derive(Debug, Clone)]
enum InodeData {
    File(Vec<u8>),
    Dir(BTreeSet<String>),
    Symlink(String),
}

/// One inode: its payload plus a hard-link count. `nlink` is a real reference
/// count for files and symlinks (a `link` bumps it, an `unlink` drops it, and
/// the inode is freed at zero). Directories are never hard-linked, so their
/// reported link count is computed (`2 + subdirectory count`), not this field.
///
/// `mode`/`mtime`/`atime`/`ctime` are the real, per-node metadata (single
/// subject, so `mode` is the owner triad). Times are ms since the Unix epoch,
/// stamped from the cached wall clock ([`crate::wall_now_ms`]).
#[derive(Debug, Clone)]
struct Inode {
    data: InodeData,
    nlink: u32,
    mode: u16,
    mtime: i64,
    atime: i64,
    ctime: i64,
}

pub struct MemFs {
    inodes: BTreeMap<Ino, Inode>,
    paths: BTreeMap<String, Ino>,
    next_ino: Ino,
}

const ROOT_INO: Ino = 1;

impl MemFs {
    pub fn new() -> Self {
        let now = crate::wall_now_ms();
        let mut inodes = BTreeMap::new();
        inodes.insert(
            ROOT_INO,
            Inode {
                data: InodeData::Dir(BTreeSet::new()),
                nlink: 2,
                mode: crate::vfs::traits::MODE_DIR_DEFAULT,
                mtime: now,
                atime: now,
                ctime: now,
            },
        );
        let mut paths = BTreeMap::new();
        paths.insert(String::from("/"), ROOT_INO);
        Self {
            inodes,
            paths,
            next_ino: ROOT_INO + 1,
        }
    }

    fn normalize_path(&self, path: &KPath) -> String {
        let s = path.as_str();
        if s.is_empty() || s == "." {
            String::from("/")
        } else if s.starts_with('/') {
            String::from(s)
        } else {
            alloc::format!("/{}", s)
        }
    }

    fn get_parent(&self, path: &str) -> Option<String> {
        if path == "/" {
            return None;
        }
        let trimmed = path.trim_end_matches('/');
        match trimmed.rfind('/') {
            Some(0) => Some(String::from("/")),
            Some(idx) => Some(String::from(&trimmed[..idx])),
            None => Some(String::from("/")),
        }
    }

    fn get_name(&self, path: &str) -> String {
        let trimmed = path.trim_end_matches('/');
        match trimmed.rfind('/') {
            Some(idx) => String::from(&trimmed[idx + 1..]),
            None => String::from(trimmed),
        }
    }

    /// The inode number a path currently maps to.
    fn ino_of(&self, path: &str) -> Option<Ino> {
        self.paths.get(path).copied()
    }

    /// The inode number `path` resolves to (lstat semantics; `None` if absent).
    /// Exposed so `commit` can detect hard links — two names sharing one inode —
    /// and serialize them as tar hard-link entries instead of duplicating the
    /// bytes. Inode numbers are filesystem-local (an identity within THIS memfs).
    pub fn inode_id(&self, path: &KPath) -> Option<u64> {
        self.ino_of(&self.normalize_path(path))
    }

    /// The inode a path currently maps to (no symlink following).
    fn node(&self, path: &str) -> Option<&Inode> {
        self.ino_of(path).and_then(|ino| self.inodes.get(&ino))
    }

    fn ensure_dir_exists(&self, path: &str) -> Result<()> {
        match self.node(path) {
            Some(Inode {
                data: InodeData::Dir(_),
                ..
            }) => Ok(()),
            Some(_) => Err(FsError::NotDir),
            None => Err(FsError::NotFound),
        }
    }

    fn alloc_ino(&mut self) -> Ino {
        let ino = self.next_ino;
        self.next_ino += 1;
        ino
    }

    /// Add `name` to the directory at `parent` (idempotent).
    fn add_child(&mut self, parent: &str, name: &str) {
        if let Some(&pino) = self.paths.get(parent) {
            if let Some(Inode {
                data: InodeData::Dir(set),
                ..
            }) = self.inodes.get_mut(&pino)
            {
                set.insert(String::from(name));
            }
        }
    }

    /// Remove `name` from the directory at `parent`.
    fn remove_child(&mut self, parent: &str, name: &str) {
        if let Some(&pino) = self.paths.get(parent) {
            if let Some(Inode {
                data: InodeData::Dir(set),
                ..
            }) = self.inodes.get_mut(&pino)
            {
                set.remove(name);
            }
        }
    }

    /// Detach the name `path` from its inode and free the inode (and its bytes)
    /// once its last hard link goes away. Directories are removed outright (they
    /// are never hard-linked). Does NOT touch parent directory sets — the caller
    /// owns that, because `rename` re-adds the name under a new parent.
    fn drop_path(&mut self, path: &str) {
        let Some(ino) = self.paths.remove(path) else {
            return;
        };
        let free = match self.inodes.get_mut(&ino) {
            Some(inode) if matches!(inode.data, InodeData::Dir(_)) => true,
            Some(inode) => {
                inode.nlink = inode.nlink.saturating_sub(1);
                inode.nlink == 0
            }
            None => false,
        };
        if free {
            self.inodes.remove(&ino);
        }
    }

    /// `2 + (immediate subdirectory count)` — POSIX `st_nlink` for the directory
    /// at `parent` whose child-name set is `entries`.
    fn dir_nlink(&self, parent: &str, entries: &BTreeSet<String>) -> u32 {
        let subdirs = entries
            .iter()
            .filter(|name| {
                matches!(
                    self.node(&join(parent, name)),
                    Some(Inode {
                        data: InodeData::Dir(_),
                        ..
                    })
                )
            })
            .count();
        2 + subdirs as u32
    }

    /// Metadata for `inode` at `path` (no symlink following — lstat semantics).
    fn meta_of(&self, path: &str, inode: &Inode) -> Metadata {
        let base = match &inode.data {
            InodeData::File(data) => Metadata::file_with_nlink(data.len() as u64, inode.nlink),
            InodeData::Dir(entries) => Metadata::dir_with_nlink(self.dir_nlink(path, entries)),
            InodeData::Symlink(target) => {
                Metadata::symlink_with_nlink(target.len() as u64, inode.nlink)
            }
        };
        base.with_mode(inode.mode)
            .with_times(inode.atime, inode.mtime, inode.ctime)
    }

    /// Move the inode at `from` to `to` by re-keying `paths` (the node itself,
    /// plus every descendant when it is a directory). Inodes never move, so open
    /// descriptors survive. Fixes both parents' child-name sets.
    fn move_node(&mut self, from: &str, to: &str, is_dir: bool) {
        let mut moves: Vec<(String, String)> = Vec::new();
        moves.push((String::from(from), String::from(to)));
        if is_dir {
            let prefix = alloc::format!("{from}/");
            for key in self.paths.keys() {
                if key.starts_with(&prefix) {
                    let new_key = alloc::format!("{}{}", to, &key[from.len()..]);
                    moves.push((key.clone(), new_key));
                }
            }
        }
        let mut taken: Vec<(String, Ino)> = Vec::new();
        for (old, new) in &moves {
            if let Some(ino) = self.paths.remove(old) {
                taken.push((new.clone(), ino));
            }
        }
        for (new, ino) in taken {
            self.paths.insert(new, ino);
        }
        if let Some(fp) = self.get_parent(from) {
            let from_name = self.get_name(from);
            self.remove_child(&fp, &from_name);
        }
        if let Some(tp) = self.get_parent(to) {
            let to_name = self.get_name(to);
            self.add_child(&tp, &to_name);
        }
    }
}

/// A file descriptor over a memfs inode. It holds the inode NUMBER (not a path),
/// so it keeps reading the same bytes even after the path is renamed or a
/// sibling hard link is removed.
pub struct MemFileHandle {
    ino: Ino,
    offset: u64,
    append: bool,
    /// Suppress atime updates on read (set for clock-less `isolated` tasks so a
    /// read can't leak the wall clock into atime).
    noatime: bool,
    inodes: *mut BTreeMap<Ino, Inode>,
}

impl FileHandle for MemFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let offset = self.offset as usize;
        let noatime = self.noatime;
        unsafe {
            let inode = match (*self.inodes).get_mut(&self.ino) {
                Some(i) => i,
                None => return Err(FsError::NotFound),
            };
            let to_read = match &inode.data {
                InodeData::File(data) => {
                    if offset >= data.len() {
                        0
                    } else {
                        let end = (offset + buf.len()).min(data.len());
                        let n = end - offset;
                        buf[..n].copy_from_slice(&data[offset..end]);
                        n
                    }
                }
                InodeData::Dir(_) => return Err(FsError::IsDir),
                // A symlink inode is never opened directly (canonicalize resolves
                // it first); reaching here is a misuse.
                InodeData::Symlink(_) => return Err(FsError::InvalidPath),
            };
            self.offset += to_read as u64;
            // relatime: bump atime on a real read only when it predates the last
            // write/change or is a day stale — and never under noatime (isolated).
            if to_read > 0 && !noatime {
                let now = crate::wall_now_ms();
                if inode.atime <= inode.mtime
                    || inode.atime <= inode.ctime
                    || now - inode.atime >= 86_400_000
                {
                    inode.atime = now;
                }
            }
            Ok(to_read)
        }
    }

    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        let append = self.append;
        let offset = self.offset as usize;
        unsafe {
            let inode = match (*self.inodes).get_mut(&self.ino) {
                Some(i) => i,
                None => return Err(FsError::NotFound),
            };
            match &mut inode.data {
                InodeData::File(data) => {
                    if append {
                        data.extend_from_slice(buf);
                        self.offset = data.len() as u64;
                    } else {
                        let start = offset;
                        let end = start + buf.len();
                        if end > data.len() {
                            data.resize(end, 0);
                        }
                        data[start..end].copy_from_slice(buf);
                        self.offset = end as u64;
                    }
                }
                InodeData::Dir(_) => return Err(FsError::IsDir),
                InodeData::Symlink(_) => return Err(FsError::InvalidPath),
            }
            // Content changed: bump modify + change times.
            let now = crate::wall_now_ms();
            inode.mtime = now;
            inode.ctime = now;
            Ok(buf.len())
        }
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let offset = self.offset;
        unsafe {
            let size = match (*self.inodes).get(&self.ino) {
                Some(Inode {
                    data: InodeData::File(data),
                    ..
                }) => data.len() as i64,
                Some(Inode {
                    data: InodeData::Dir(_),
                    ..
                }) => 0,
                Some(Inode {
                    data: InodeData::Symlink(t),
                    ..
                }) => t.len() as i64,
                None => return Err(FsError::NotFound),
            };
            let new_offset = match pos {
                SeekFrom::Start(n) => n as i64,
                SeekFrom::Current(n) => offset as i64 + n,
                SeekFrom::End(n) => size + n,
            };
            if new_offset < 0 {
                return Err(FsError::InvalidPath);
            }
            self.offset = new_offset as u64;
            Ok(self.offset)
        }
    }

    fn stat(&self) -> Result<Metadata> {
        unsafe {
            let inode = (*self.inodes).get(&self.ino).ok_or(FsError::NotFound)?;
            let base = match &inode.data {
                InodeData::File(data) => Metadata::file_with_nlink(data.len() as u64, inode.nlink),
                InodeData::Dir(_) => Metadata::dir(),
                InodeData::Symlink(t) => Metadata::symlink_with_nlink(t.len() as u64, inode.nlink),
            };
            Ok(base
                .with_mode(inode.mode)
                .with_times(inode.atime, inode.mtime, inode.ctime))
        }
    }

    fn truncate(&mut self, size: u64) -> Result<()> {
        unsafe {
            let inode = match (*self.inodes).get_mut(&self.ino) {
                Some(i) => i,
                None => return Err(FsError::NotFound),
            };
            match &mut inode.data {
                // Grow zero-fills; shrink drops the tail. Offset unchanged (POSIX).
                InodeData::File(data) => data.resize(size as usize, 0),
                InodeData::Dir(_) => return Err(FsError::IsDir),
                InodeData::Symlink(_) => return Err(FsError::InvalidPath),
            }
            let now = crate::wall_now_ms();
            inode.mtime = now;
            inode.ctime = now;
            Ok(())
        }
    }
}

impl FileSystem for MemFs {
    fn open(
        &mut self,
        path: &KPath,
        flags: OpenFlags,
        _caller: CallerId,
    ) -> Result<Box<dyn FileHandle>> {
        let path_str = self.normalize_path(path);
        let inodes_ptr = &mut self.inodes as *mut BTreeMap<Ino, Inode>;

        match self.ino_of(&path_str) {
            Some(ino) => {
                match self.inodes.get(&ino).map(|n| &n.data) {
                    Some(InodeData::Dir(_)) => return Err(FsError::IsDir),
                    // Symlinks are resolved by the namespace before reaching here.
                    Some(InodeData::Symlink(_)) => return Err(FsError::InvalidPath),
                    Some(InodeData::File(_)) => {}
                    None => return Err(FsError::NotFound),
                }
                if flags.truncate {
                    if let Some(inode) = self.inodes.get_mut(&ino) {
                        if let InodeData::File(data) = &mut inode.data {
                            data.clear();
                            let now = crate::wall_now_ms();
                            inode.mtime = now;
                            inode.ctime = now;
                        }
                    }
                }
                let offset = if flags.append {
                    match self.inodes.get(&ino) {
                        Some(Inode {
                            data: InodeData::File(data),
                            ..
                        }) => data.len() as u64,
                        _ => 0,
                    }
                } else {
                    0
                };
                Ok(Box::new(MemFileHandle {
                    ino,
                    offset,
                    append: flags.append,
                    noatime: flags.noatime,
                    inodes: inodes_ptr,
                }))
            }
            None => {
                if !flags.create {
                    return Err(FsError::NotFound);
                }
                let parent = self.get_parent(&path_str).ok_or(FsError::NotFound)?;
                self.ensure_dir_exists(&parent)?;
                let ino = self.alloc_ino();
                let now = crate::wall_now_ms();
                self.inodes.insert(
                    ino,
                    Inode {
                        data: InodeData::File(Vec::new()),
                        nlink: 1,
                        mode: crate::vfs::traits::MODE_FILE_DEFAULT,
                        mtime: now,
                        atime: now,
                        ctime: now,
                    },
                );
                self.paths.insert(path_str.clone(), ino);
                let name = self.get_name(&path_str);
                self.add_child(&parent, &name);
                Ok(Box::new(MemFileHandle {
                    ino,
                    offset: 0,
                    append: flags.append,
                    noatime: flags.noatime,
                    inodes: inodes_ptr,
                }))
            }
        }
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let path_str = self.normalize_path(path);
        let inode = self.node(&path_str).ok_or(FsError::NotFound)?;
        Ok(self.meta_of(&path_str, inode))
    }

    fn readdir(&self, path: &KPath, _caller: CallerId) -> Result<Vec<DirEntry>> {
        let path_str = self.normalize_path(path);
        match self.node(&path_str) {
            Some(Inode {
                data: InodeData::Dir(entries),
                ..
            }) => {
                let mut result = Vec::new();
                for name in entries {
                    let child_path = join(&path_str, name);
                    if let Some(inode) = self.node(&child_path) {
                        let node_type = match inode.data {
                            InodeData::File(_) => NodeType::File,
                            InodeData::Dir(_) => NodeType::Dir,
                            InodeData::Symlink(_) => NodeType::Symlink,
                        };
                        result.push(DirEntry {
                            name: name.clone(),
                            node_type,
                        });
                    }
                }
                Ok(result)
            }
            Some(_) => Err(FsError::NotDir),
            None => Err(FsError::NotFound),
        }
    }

    fn mkdir(&mut self, path: &KPath, _caller: CallerId) -> Result<()> {
        let path_str = self.normalize_path(path);
        if self.paths.contains_key(&path_str) {
            return Err(FsError::AlreadyExists);
        }
        let parent = self.get_parent(&path_str).ok_or(FsError::NotFound)?;
        self.ensure_dir_exists(&parent)?;
        let name = self.get_name(&path_str);
        let ino = self.alloc_ino();
        let now = crate::wall_now_ms();
        self.inodes.insert(
            ino,
            Inode {
                data: InodeData::Dir(BTreeSet::new()),
                nlink: 2,
                mode: crate::vfs::traits::MODE_DIR_DEFAULT,
                mtime: now,
                atime: now,
                ctime: now,
            },
        );
        self.paths.insert(path_str.clone(), ino);
        self.add_child(&parent, &name);
        Ok(())
    }

    fn unlink(&mut self, path: &KPath, _caller: CallerId) -> Result<()> {
        let path_str = self.normalize_path(path);
        match self.node(&path_str) {
            Some(Inode {
                data: InodeData::Dir(entries),
                ..
            }) if !entries.is_empty() => return Err(FsError::NotEmpty),
            None => return Err(FsError::NotFound),
            _ => {}
        }
        let parent = self.get_parent(&path_str).ok_or(FsError::NotFound)?;
        let name = self.get_name(&path_str);
        self.remove_child(&parent, &name);
        self.drop_path(&path_str);
        Ok(())
    }

    fn rename(&mut self, from: &KPath, to: &KPath, _caller: CallerId) -> Result<()> {
        let from_str = self.normalize_path(from);
        let to_str = self.normalize_path(to);

        let from_is_dir = match self.node(&from_str) {
            Some(Inode {
                data: InodeData::Dir(_),
                ..
            }) => true,
            Some(_) => false,
            None => return Err(FsError::NotFound),
        };

        // Rename to the same path is a no-op (POSIX).
        if from_str == to_str {
            return Ok(());
        }
        // A directory may not be moved into its own subtree.
        if from_is_dir && to_str.starts_with(&alloc::format!("{from_str}/")) {
            return Err(FsError::InvalidPath);
        }

        // POSIX destination handling.
        match self.node(&to_str) {
            Some(Inode {
                data: InodeData::Dir(entries),
                ..
            }) => {
                if !from_is_dir {
                    return Err(FsError::IsDir); // file onto existing directory
                }
                if !entries.is_empty() {
                    return Err(FsError::NotEmpty); // dir onto non-empty dir
                }
                self.detach_dest(&to_str); // replace the empty directory
            }
            Some(_) => {
                // Existing file or symlink at the destination.
                if from_is_dir {
                    return Err(FsError::NotDir); // dir onto existing file
                }
                self.detach_dest(&to_str); // overwrite (atomic)
            }
            None => {
                let to_parent = self.get_parent(&to_str).ok_or(FsError::NotFound)?;
                self.ensure_dir_exists(&to_parent)?;
            }
        }

        self.move_node(&from_str, &to_str, from_is_dir);
        Ok(())
    }

    fn symlink(&mut self, target: &str, link: &KPath) -> Result<()> {
        let link_str = self.normalize_path(link);
        if self.paths.contains_key(&link_str) {
            return Err(FsError::AlreadyExists);
        }
        let parent = self.get_parent(&link_str).ok_or(FsError::NotFound)?;
        self.ensure_dir_exists(&parent)?;
        let name = self.get_name(&link_str);
        let ino = self.alloc_ino();
        let now = crate::wall_now_ms();
        self.inodes.insert(
            ino,
            Inode {
                data: InodeData::Symlink(String::from(target)),
                nlink: 1,
                mode: crate::vfs::traits::MODE_SYMLINK,
                mtime: now,
                atime: now,
                ctime: now,
            },
        );
        self.paths.insert(link_str.clone(), ino);
        self.add_child(&parent, &name);
        Ok(())
    }

    fn link(&mut self, existing: &KPath, new: &KPath) -> Result<()> {
        let existing_str = self.normalize_path(existing);
        let new_str = self.normalize_path(new);
        let ino = self.ino_of(&existing_str).ok_or(FsError::NotFound)?;
        // POSIX: directories cannot be hard-linked.
        if let Some(Inode {
            data: InodeData::Dir(_),
            ..
        }) = self.inodes.get(&ino)
        {
            return Err(FsError::PermissionDenied);
        }
        if self.paths.contains_key(&new_str) {
            return Err(FsError::AlreadyExists);
        }
        let parent = self.get_parent(&new_str).ok_or(FsError::NotFound)?;
        self.ensure_dir_exists(&parent)?;
        let name = self.get_name(&new_str);
        self.paths.insert(new_str.clone(), ino);
        if let Some(inode) = self.inodes.get_mut(&ino) {
            inode.nlink += 1;
            inode.ctime = crate::wall_now_ms(); // link count changed
        }
        self.add_child(&parent, &name);
        Ok(())
    }

    fn readlink(&self, path: &KPath) -> Result<String> {
        let path_str = self.normalize_path(path);
        match self.node(&path_str) {
            Some(Inode {
                data: InodeData::Symlink(target),
                ..
            }) => Ok(target.clone()),
            Some(_) => Err(FsError::InvalidPath),
            None => Err(FsError::NotFound),
        }
    }

    fn set_mode(&mut self, path: &KPath, mode: u16) -> Result<()> {
        let path_str = self.normalize_path(path);
        let ino = self.ino_of(&path_str).ok_or(FsError::NotFound)?;
        let inode = self.inodes.get_mut(&ino).ok_or(FsError::NotFound)?;
        inode.mode = mode & 0o7777; // permission + special bits only
        inode.ctime = crate::wall_now_ms(); // metadata change
        Ok(())
    }

    fn set_times(&mut self, path: &KPath, atime: i64, mtime: i64) -> Result<()> {
        let path_str = self.normalize_path(path);
        let ino = self.ino_of(&path_str).ok_or(FsError::NotFound)?;
        let inode = self.inodes.get_mut(&ino).ok_or(FsError::NotFound)?;
        inode.atime = atime;
        inode.mtime = mtime;
        inode.ctime = crate::wall_now_ms(); // metadata change
        Ok(())
    }
}

impl MemFs {
    /// Detach a rename destination (an empty dir, or a file/symlink being
    /// overwritten) from its parent and drop its name. `move_node` re-adds the
    /// (same) name afterwards, now pointing at the source inode.
    fn detach_dest(&mut self, dest: &str) {
        let name = self.get_name(dest);
        if let Some(parent) = self.get_parent(dest) {
            self.remove_child(&parent, &name);
        }
        self.drop_path(dest);
    }
}

/// Join a directory path and an entry name with a single `/`.
fn join(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        alloc::format!("{dir}{name}")
    } else {
        alloc::format!("{dir}/{name}")
    }
}
