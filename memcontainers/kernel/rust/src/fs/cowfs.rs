//! Copy-on-Write filesystem - overlays writes on top of a read-only base.

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::collections::BTreeSet;
use alloc::string::String;
use alloc::vec::Vec;

use crate::fs::utils::TarWriter;
use crate::fs::MemFs;
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom, SYSTEM_CALLER,
};

/// One overlay entry gathered for `commit` (pass 1 of `serialize_layer`). `ino`
/// is the overlay inode id for FILES only — two files with the same `ino` are
/// hard links and are serialized as a single set of bytes + tar hard-link entries.
struct OverlayNode {
    path: String,
    node: NodeType,
    mode: u16,
    mtime: i64,
    /// Symlink target text (empty for non-symlinks).
    target: String,
    /// Overlay inode id (files only; `None` for dirs/symlinks).
    ino: Option<u64>,
}

/// Copy-on-Write filesystem
/// Reads check overlay first, then base (unless tombstoned)
/// Writes always go to overlay
/// Deletes add a tombstone
#[allow(dead_code)]
pub struct CowFs {
    /// Base filesystem (read-only, typically TarFs)
    base: Box<dyn FileSystem>,
    /// Overlay filesystem for writes (MemFs)
    overlay: MemFs,
    /// Paths that have been deleted (tombstones)
    tombstones: BTreeSet<String>,
}

#[allow(dead_code)]
impl CowFs {
    pub fn new(base: Box<dyn FileSystem>) -> Self {
        Self {
            base,
            overlay: MemFs::new(),
            tombstones: BTreeSet::new(),
        }
    }

    /// Check if path is tombstoned (deleted)
    fn is_tombstoned(&self, path: &str) -> bool {
        self.tombstones.contains(path)
    }

    /// Add tombstone
    fn add_tombstone(&mut self, path: &str) {
        self.tombstones.insert(String::from(path));
    }

    /// Remove tombstone
    fn remove_tombstone(&mut self, path: &str) {
        self.tombstones.remove(path);
    }

    /// Normalize path
    fn normalize_path(&self, path: &KPath) -> String {
        let s = path.as_str();
        if s.is_empty() || s == "." {
            String::from("/")
        } else {
            String::from(s)
        }
    }

    /// Get parent directory
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

    /// Get file name from path
    fn get_name(&self, path: &str) -> String {
        let trimmed = path.trim_end_matches('/');
        match trimmed.rfind('/') {
            Some(idx) => String::from(&trimmed[idx + 1..]),
            None => String::from(trimmed),
        }
    }

    /// Check if a path exists (in overlay or base, unless tombstoned)
    fn exists(&self, path: &str) -> bool {
        if self.is_tombstoned(path) {
            return false;
        }

        // Check overlay first
        if let Ok(_) = self.overlay.stat(&KPath::new(path)) {
            return true;
        }

        // Then check base
        if let Ok(_) = self.base.stat(&KPath::new(path)) {
            return true;
        }

        false
    }

    /// Mirror every ancestor directory of `path` in the overlay so a
    /// subsequent `overlay.open(..., CREATE)` does not fail with
    /// `NotFound` on the parent. Called by the CoW copy path because
    /// the base image may have a directory chain (e.g. `/etc`) that
    /// the overlay's MemFs has never been told about.
    fn ensure_overlay_parents(&mut self, path: &str) -> Result<()> {
        if path == "/" || path.is_empty() {
            return Ok(());
        }
        let parent = match self.get_parent(path) {
            Some(p) => p,
            None => return Ok(()),
        };
        self.ensure_overlay_parents(&parent)?;
        if self.overlay.stat(&KPath::new(&parent)).is_err() {
            // `_ =` so a race or harmless AlreadyExists does not bubble up.
            // Copy-up bookkeeping acts as the kernel itself (SYSTEM_CALLER), not
            // the requesting task — the overlay (a MemFs) ignores it regardless.
            let _ = self.overlay.mkdir(SYSTEM_CALLER, &KPath::new(&parent));
        }
        Ok(())
    }
}

/// File handle for COW filesystem
#[allow(dead_code)]
pub struct CowFileHandle {
    /// True if this is from the overlay (writable)
    is_overlay: bool,
    /// Path for error messages
    path: String,
    /// Handle to the actual file
    handle: Option<Box<dyn FileHandle>>,
}

impl FileHandle for CowFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        if let Some(handle) = self.handle.as_mut() {
            handle.read(buf)
        } else {
            Err(FsError::BadFileDescriptor)
        }
    }

    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        if !self.is_overlay {
            return Err(FsError::PermissionDenied);
        }

        if let Some(handle) = self.handle.as_mut() {
            handle.write(buf)
        } else {
            Err(FsError::BadFileDescriptor)
        }
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        if let Some(handle) = self.handle.as_mut() {
            handle.seek(pos)
        } else {
            Err(FsError::BadFileDescriptor)
        }
    }

    fn stat(&self) -> Result<Metadata> {
        if let Some(handle) = self.handle.as_ref() {
            handle.stat()
        } else {
            Err(FsError::BadFileDescriptor)
        }
    }

    fn truncate(&mut self, size: u64) -> Result<()> {
        // A `CowFileHandle` only ever wraps the read-only base layer (writable
        // opens copy-up and return the overlay's MemFs handle directly, which
        // implements `truncate`). Truncating the base is a write — refuse it,
        // mirroring `write`.
        if !self.is_overlay {
            return Err(FsError::PermissionDenied);
        }
        if let Some(handle) = self.handle.as_mut() {
            handle.truncate(size)
        } else {
            Err(FsError::BadFileDescriptor)
        }
    }
}

impl FileSystem for CowFs {
    fn open(
        &mut self,
        caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        let path_str = self.normalize_path(path);

        // Check if tombstoned
        if self.is_tombstoned(&path_str) {
            if flags.create {
                // Create in overlay
                self.remove_tombstone(&path_str);
                return self.overlay.open(caller, path, flags);
            }
            return Err(FsError::NotFound);
        }

        // Check if exists in overlay
        if let Ok(_) = self.overlay.stat(path) {
            // File exists in overlay, use it
            return self.overlay.open(caller, path, flags);
        }

        // Check if exists in base
        match self.base.stat(path) {
            Ok(meta) => {
                // File exists in base
                if flags.write || flags.truncate {
                    // Need to copy-on-write - create in overlay
                    // First, copy base file to overlay
                    if meta.node_type == NodeType::File {
                        self.ensure_overlay_parents(&path_str)?;
                        let mut base_handle = self.base.open(caller, path, OpenFlags::READ)?;
                        let mut overlay_handle =
                            self.overlay.open(caller, path, OpenFlags::CREATE)?;

                        // Copy data
                        let mut buf = [0u8; 4096];
                        loop {
                            match base_handle.read(&mut buf) {
                                Ok(0) => break,
                                Ok(n) => {
                                    overlay_handle.write(&buf[..n])?;
                                }
                                Err(e) => return Err(e),
                            }
                        }
                        drop(overlay_handle);
                        drop(base_handle);
                        // Carry the base file's mode + times onto the copy-up, so
                        // a `chmod`/timestamp survives the first write.
                        let _ = self.overlay.set_mode(path, meta.mode);
                        let _ = self.overlay.set_times(path, meta.atime, meta.mtime);

                        // Re-open with requested flags
                        return self.overlay.open(caller, path, flags);
                    } else {
                        // For directories, just create in overlay
                        return self.overlay.open(caller, path, flags);
                    }
                } else {
                    // Read-only access to base
                    let handle = CowFileHandle {
                        is_overlay: false,
                        path: path_str,
                        handle: Some(self.base.open(caller, path, flags)?),
                    };
                    return Ok(Box::new(handle));
                }
            }
            Err(_) => {
                // Not in base or overlay
                if flags.create {
                    let path_str_create = self.normalize_path(path);
                    self.ensure_overlay_parents(&path_str_create)?;
                    // Create in overlay
                    return self.overlay.open(caller, path, flags);
                }
                Err(FsError::NotFound)
            }
        }
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let path_str = self.normalize_path(path);

        if self.is_tombstoned(&path_str) {
            return Err(FsError::NotFound);
        }

        // Check overlay first
        if let Ok(meta) = self.overlay.stat(path) {
            return Ok(meta);
        }

        // Then check base
        self.base.stat(path)
    }

    fn readdir(&self, caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        let path_str = self.normalize_path(path);

        if self.is_tombstoned(&path_str) {
            return Err(FsError::NotFound);
        }

        // Read both layers directly. Gating on `readdir` success (not on a
        // prior `stat`) is what lets a directory that exists ONLY in the
        // writable overlay still list — a `stat`-gate missed those and returned
        // NotFound. The directory exists iff at least one layer's `readdir`
        // succeeds; an existing-but-empty dir returns Ok([]).
        let base_result = self.base.readdir(caller, path);
        let overlay_result = self.overlay.readdir(caller, path);
        if base_result.is_err() && overlay_result.is_err() {
            return Err(FsError::NotFound);
        }
        let base_entries = base_result.unwrap_or_default();
        let overlay_entries = overlay_result.unwrap_or_default();

        // Merge entries, excluding tombstoned ones
        let mut result = BTreeMap::new();

        for entry in base_entries {
            let full_path = if path_str.ends_with('/') {
                alloc::format!("{}{}", path_str, entry.name)
            } else {
                alloc::format!("{}/{}", path_str, entry.name)
            };

            if !self.is_tombstoned(&full_path) {
                result.insert(entry.name.clone(), entry);
            }
        }

        for entry in overlay_entries {
            result.insert(entry.name.clone(), entry);
        }

        Ok(result.into_values().collect())
    }

    fn mkdir(&mut self, caller: CallerId, path: &KPath) -> Result<()> {
        let path_str = self.normalize_path(path);

        if self.is_tombstoned(&path_str) {
            // Path was deleted; remove tombstone and allow re-creation.
            self.remove_tombstone(&path_str);
        } else if self.exists(&path_str) {
            // Directory exists in overlay or base and is not tombstoned.
            return Err(FsError::AlreadyExists);
        }

        // Mirror the parent chain into the overlay first — the base image may
        // provide an ancestor (e.g. `/home`) the overlay has never seen, which
        // otherwise makes `mkdir /home/user` (and the boot cwd) fail.
        self.ensure_overlay_parents(&path_str)?;
        self.overlay.mkdir(caller, path)
    }

    fn unlink(&mut self, caller: CallerId, path: &KPath) -> Result<()> {
        let path_str = self.normalize_path(path);

        // Check if exists
        if !self.exists(&path_str) {
            return Err(FsError::NotFound);
        }

        // Remove from overlay if present
        if self.overlay.stat(path).is_ok() {
            self.overlay.unlink(caller, path)?;
        }

        // Add tombstone
        self.add_tombstone(&path_str);

        Ok(())
    }

    fn rename(&mut self, caller: CallerId, from: &KPath, to: &KPath) -> Result<()> {
        let from_str = self.normalize_path(from);
        let to_str = self.normalize_path(to);

        if !self.exists(&from_str) {
            return Err(FsError::NotFound);
        }

        // Materialize the source subtree into the overlay so the overlay's
        // (POSIX) rename can move it; the base copy is hidden by a tombstone
        // below. A base-only destination is materialized too so the overlay
        // applies the right overwrite / type / non-empty-dir checks.
        self.copy_up(&from_str)?;
        if self.exists(&to_str) && self.overlay.stat(to).is_err() {
            self.copy_up(&to_str)?;
        }
        self.ensure_overlay_parents(&to_str)?;

        // POSIX rename within the overlay (overwrite, EISDIR/ENOTDIR/ENOTEMPTY,
        // and directory subtree re-keying all live in MemFs::rename).
        self.overlay.rename(caller, from, to)?;

        // The base still holds the old source path (and its subtree) — tombstone
        // it so nothing re-surfaces under the old name. The destination is now
        // live in the overlay, so clear any tombstone on it.
        self.tombstone_subtree(&from_str);
        self.clear_tombstones_under(&to_str);

        Ok(())
    }

    fn symlink(&mut self, target: &str, link: &KPath) -> Result<()> {
        let link_str = self.normalize_path(link);
        if self.is_tombstoned(&link_str) {
            self.remove_tombstone(&link_str);
        } else if self.exists(&link_str) {
            return Err(FsError::AlreadyExists);
        }
        self.ensure_overlay_parents(&link_str)?;
        self.overlay.symlink(target, link)
    }

    fn link(&mut self, existing: &KPath, new: &KPath) -> Result<()> {
        let existing_str = self.normalize_path(existing);
        let new_str = self.normalize_path(new);
        if !self.exists(&existing_str) {
            return Err(FsError::NotFound);
        }
        if self.is_tombstoned(&new_str) {
            self.remove_tombstone(&new_str);
        } else if self.exists(&new_str) {
            return Err(FsError::AlreadyExists);
        }
        // Materialize the source into the overlay so both names share one inode
        // in the writable layer; the hard link then lives entirely in `overlay`.
        self.copy_up(&existing_str)?;
        self.ensure_overlay_parents(&new_str)?;
        self.overlay.link(existing, new)
    }

    fn readlink(&self, path: &KPath) -> Result<String> {
        let path_str = self.normalize_path(path);
        if self.is_tombstoned(&path_str) {
            return Err(FsError::NotFound);
        }
        // Overlay shadows base (same precedence as `stat`).
        if self.overlay.stat(path).is_ok() {
            return self.overlay.readlink(path);
        }
        self.base.readlink(path)
    }

    fn set_mode(&mut self, path: &KPath, mode: u16) -> Result<()> {
        let path_str = self.normalize_path(path);
        if self.is_tombstoned(&path_str) {
            return Err(FsError::NotFound);
        }
        // Materialize into the overlay (the base is read-only), then chmod there.
        self.copy_up(&path_str)?;
        self.overlay.set_mode(path, mode)
    }

    fn set_times(&mut self, path: &KPath, atime: i64, mtime: i64) -> Result<()> {
        let path_str = self.normalize_path(path);
        if self.is_tombstoned(&path_str) {
            return Err(FsError::NotFound);
        }
        self.copy_up(&path_str)?;
        self.overlay.set_times(path, atime, mtime)
    }

    fn commit_layer(&mut self) -> Option<Vec<u8>> {
        Some(self.serialize_layer())
    }
}

impl CowFs {
    /// Recursively materialize `path` (file or directory subtree) into the
    /// overlay, copying base content up. A no-op for parts already present in
    /// the overlay. After this, the whole subtree is writable in the overlay.
    fn copy_up(&mut self, path: &str) -> Result<()> {
        let kp = KPath::new(path);
        let meta = self.stat(&kp)?;
        self.ensure_overlay_parents(path)?;
        match meta.node_type {
            NodeType::File => {
                if self.overlay.stat(&kp).is_err() {
                    let mut bh = self.base.open(SYSTEM_CALLER, &kp, OpenFlags::READ)?;
                    let mut oh = self.overlay.open(SYSTEM_CALLER, &kp, OpenFlags::CREATE)?;
                    let mut buf = [0u8; 4096];
                    loop {
                        match bh.read(&mut buf) {
                            Ok(0) => break,
                            Ok(n) => {
                                oh.write(&buf[..n])?;
                            }
                            Err(e) => return Err(e),
                        }
                    }
                    drop(oh);
                    drop(bh);
                    // Preserve the base node's mode + times across the copy-up.
                    let _ = self.overlay.set_mode(&kp, meta.mode);
                    let _ = self.overlay.set_times(&kp, meta.atime, meta.mtime);
                }
            }
            NodeType::Dir => {
                if self.overlay.stat(&kp).is_err() {
                    self.overlay.mkdir(SYSTEM_CALLER, &kp)?;
                    let _ = self.overlay.set_mode(&kp, meta.mode);
                    let _ = self.overlay.set_times(&kp, meta.atime, meta.mtime);
                }
                for e in self.readdir(SYSTEM_CALLER, &kp)? {
                    let child = join_path(path, &e.name);
                    self.copy_up(&child)?;
                }
            }
            NodeType::Symlink => {
                // A symlink materializes by its target text, not byte content;
                // its mode is always 0o777, so only the times are worth carrying.
                if self.overlay.stat(&kp).is_err() {
                    let target = self.base.readlink(&kp)?;
                    self.overlay.symlink(&target, &kp)?;
                    let _ = self.overlay.set_times(&kp, meta.atime, meta.mtime);
                }
            }
        }
        Ok(())
    }

    /// Tombstone `path` and every base descendant of it, so a moved/removed
    /// base subtree cannot re-surface under the old path.
    fn tombstone_subtree(&mut self, path: &str) {
        if let Ok(entries) = self.base.readdir(SYSTEM_CALLER, &KPath::new(path)) {
            for e in entries {
                let child = join_path(path, &e.name);
                self.tombstone_subtree(&child);
            }
        }
        self.add_tombstone(path);
    }

    /// Serialize the writable diff (overlay live writes + tombstone whiteouts)
    /// into a POSIX-ustar `.tar` layer — the `commit` primitive. Walks the
    /// overlay's OWN tree (not the merged view), so the layer is exactly the diff
    /// since boot; deletions become OCI `.wh.<name>` entries `OverlayFs` honors.
    fn serialize_layer(&mut self) -> Vec<u8> {
        // Pass 1: snapshot the overlay tree (immutable walk) so pass 2 can read
        // file bytes (which needs `&mut overlay`) without a borrow conflict.
        let mut nodes: Vec<OverlayNode> = Vec::new();
        self.collect_overlay("/", &mut nodes);
        // Pass 2: emit entries (parents precede children from the walk order).
        // Files that share an inode (hard links) are emitted once as a regular
        // file; every later name becomes a tar hard-link to that first path, so
        // the bytes are stored once and the link relationship round-trips.
        let mut w = TarWriter::new();
        let mut primary_for_ino: BTreeMap<u64, String> = BTreeMap::new();
        for n in &nodes {
            let secs = n.mtime / 1000;
            match n.node {
                NodeType::Dir => w.append_dir(&n.path, n.mode, secs),
                NodeType::Symlink => w.append_symlink(&n.path, &n.target, secs),
                NodeType::File => {
                    let primary = n.ino.and_then(|ino| primary_for_ino.get(&ino).cloned());
                    match primary {
                        Some(p) => w.append_hardlink(&n.path, &p, n.mode, secs),
                        None => {
                            if let Some(ino) = n.ino {
                                primary_for_ino.insert(ino, n.path.clone());
                            }
                            let bytes = self.read_overlay_file(&n.path);
                            w.append_file(&n.path, &bytes, n.mode, secs);
                        }
                    }
                }
            }
        }
        // Whiteouts for deletions, in sorted (BTreeSet) order.
        for t in &self.tombstones {
            w.append_whiteout(t);
        }
        w.finish()
    }

    /// Recursively gather the overlay's own entries (sorted, parents before
    /// children) into [`OverlayNode`]s. Reads only via the overlay's `&self` ops;
    /// files also carry their inode id (via `MemFs::inode_id`) for hard-link
    /// detection.
    fn collect_overlay(&self, dir: &str, out: &mut Vec<OverlayNode>) {
        let Ok(mut entries) = self.overlay.readdir(SYSTEM_CALLER, &KPath::new(dir)) else {
            return;
        };
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        for e in entries {
            let path = join_path(dir, &e.name);
            let Ok(meta) = self.overlay.stat(&KPath::new(&path)) else {
                continue;
            };
            let target = if e.node_type == NodeType::Symlink {
                self.overlay
                    .readlink(&KPath::new(&path))
                    .unwrap_or_default()
            } else {
                String::new()
            };
            let ino = if e.node_type == NodeType::File {
                self.overlay.inode_id(&KPath::new(&path))
            } else {
                None
            };
            out.push(OverlayNode {
                path: path.clone(),
                node: e.node_type,
                mode: meta.mode,
                mtime: meta.mtime,
                target,
                ino,
            });
            if e.node_type == NodeType::Dir {
                self.collect_overlay(&path, out);
            }
        }
    }

    /// Drain a file's bytes from the overlay (empty on any error).
    fn read_overlay_file(&mut self, path: &str) -> Vec<u8> {
        let mut bytes = Vec::new();
        if let Ok(mut h) = self
            .overlay
            .open(SYSTEM_CALLER, &KPath::new(path), OpenFlags::READ)
        {
            let mut buf = [0u8; 4096];
            loop {
                match h.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => bytes.extend_from_slice(&buf[..n]),
                    Err(_) => break,
                }
            }
        }
        bytes
    }

    /// Drop tombstones on `path` and anything under it (the destination of a
    /// rename is now live in the overlay).
    fn clear_tombstones_under(&mut self, path: &str) {
        let prefix = alloc::format!("{path}/");
        let stale: Vec<String> = self
            .tombstones
            .iter()
            .filter(|t| t.as_str() == path || t.starts_with(&prefix))
            .cloned()
            .collect();
        for t in stale {
            self.remove_tombstone(&t);
        }
    }
}

/// Join a directory path and an entry name with a single `/`.
fn join_path(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        alloc::format!("{dir}{name}")
    } else {
        alloc::format!("{dir}/{name}")
    }
}
