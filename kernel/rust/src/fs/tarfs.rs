//! Read-only TAR filesystem (supports .tar and .tar.gz).

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom,
};

/// TAR entry types (POSIX ustar typeflag byte)
const TAR_TYPE_HARDLINK: u8 = 0x31; // '1' - hard link to another archived entry
const TAR_TYPE_SYMLINK: u8 = 0x32; // '2' - symbolic link (target in linkname field)
const TAR_TYPE_DIR: u8 = 0x35; // '5' - directory

/// An entry in the tar archive
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct TarEntry {
    pub path: String,
    pub data_offset: usize, // Offset into tar_data where file content starts
    pub size: usize,
    pub entry_type: NodeType,
    pub mode: u32,
    pub mtime: i64,
    /// Hard-link count (POSIX `st_nlink`): the number of archive names that
    /// resolve to this inode's bytes. `1` for an unlinked file; computed for
    /// hard-link groups after indexing (entries sharing a `data_offset`).
    pub nlink: u32,
    /// Symbolic-link target text (verbatim, for `Symlink` entries); empty
    /// otherwise. Hard-link targets are resolved to bytes at index time.
    pub target: String,
}

/// Read-only TAR filesystem
#[allow(dead_code)]
pub struct TarFs {
    /// Raw tar data (could be compressed or uncompressed)
    data: Vec<u8>,
    /// Index of entries by path
    entries: BTreeMap<String, TarEntry>,
    /// Is the data gzip compressed?
    compressed: bool,
}

impl TarFs {
    /// Create a new TarFs from tar data
    /// If the data starts with gzip magic, it will be treated as compressed
    pub fn new(data: Vec<u8>) -> Result<Self> {
        let compressed = data.len() >= 2 && data[0] == 0x1f && data[1] == 0x8b;

        let mut fs = Self {
            data,
            entries: BTreeMap::new(),
            compressed,
        };

        fs.build_index()?;

        // Ensure root directory exists
        if !fs.entries.contains_key("/") {
            fs.entries.insert(
                String::from("/"),
                TarEntry {
                    path: String::from("/"),
                    data_offset: 0,
                    size: 0,
                    entry_type: NodeType::Dir,
                    mode: 0o755,
                    mtime: 0,
                    nlink: 1,
                    target: String::new(),
                },
            );
        }

        Ok(fs)
    }

    /// Parse a TAR header and extract info
    fn parse_header(&self, offset: usize) -> Option<(TarEntry, usize)> {
        if offset + 512 > self.data.len() {
            return None;
        }

        let header = &self.data[offset..offset + 512];

        // Check for end-of-archive (two zero blocks)
        if header.iter().all(|&b| b == 0) {
            return None;
        }

        // Read name (bytes 0-99) plus the optional ustar prefix (345-499).
        let name = self.read_path(header);

        // Read size (bytes 124-135, octal)
        let size_str = self.read_string(header, 124, 12);
        let size = u64::from_str_radix(&size_str.trim(), 8).unwrap_or(0) as usize;

        // Read type flag (byte 156)
        let typeflag = header.get(156).copied().unwrap_or(0x30);
        let entry_type = match typeflag {
            TAR_TYPE_DIR => NodeType::Dir,
            TAR_TYPE_SYMLINK => NodeType::Symlink,
            _ => NodeType::File,
        };

        // Link target (bytes 157-256). A symlink stores its target verbatim; a
        // hard link names another archived entry (normalized to a path here and
        // resolved to that entry's bytes in `build_index`).
        let linkname = self.read_string(header, 157, 100);
        let target = match typeflag {
            TAR_TYPE_SYMLINK => linkname,
            TAR_TYPE_HARDLINK => tar_path(&linkname),
            _ => String::new(),
        };

        // Read mode (bytes 100-107, octal)
        let mode_str = self.read_string(header, 100, 8);
        let mode = u32::from_str_radix(&mode_str.trim(), 8).unwrap_or(0o644);

        // Read mtime (bytes 136-147, octal)
        let mtime_str = self.read_string(header, 136, 12);
        let mtime = i64::from_str_radix(&mtime_str.trim(), 8).unwrap_or(0);

        // Calculate data offset (after header, rounded up to 512)
        let data_offset = offset + 512;
        let next_offset = data_offset + ((size + 511) / 512) * 512;

        let path = tar_path(&name);

        let entry = TarEntry {
            path: path.clone(),
            data_offset,
            size,
            entry_type,
            mode,
            mtime,
            nlink: 1,
            target,
        };

        Some((entry, next_offset))
    }

    /// Read a null-terminated string from header
    fn read_string(&self, header: &[u8], start: usize, max_len: usize) -> String {
        let end = (start..start + max_len)
            .find(|&i| header.get(i).copied() == Some(0))
            .unwrap_or(start + max_len);

        String::from(String::from_utf8_lossy(&header[start..end]))
    }

    /// Read a ustar path from `name` (0-99) and the optional `prefix` (345-499).
    /// The `prefix` field only exists in STRICT POSIX ustar headers (magic
    /// `"ustar\0"`, which `utils` emits); GNU headers (the xtask base image)
    /// reuse bytes 345+ for atime/ctime, so reading a prefix there would corrupt
    /// the path. Gate on the magic: GNU/non-ustar headers use the name field only
    /// (their long paths, if any, ride a separate GNU long-name record).
    fn read_path(&self, header: &[u8]) -> String {
        let name = self.read_string(header, 0, 100);
        let posix_ustar = header.len() >= 263 && &header[257..263] == b"ustar\0";
        if !posix_ustar {
            return name;
        }
        let prefix = self.read_string(header, 345, 155);
        if prefix.is_empty() {
            name
        } else if name.is_empty() {
            prefix
        } else {
            alloc::format!("{prefix}/{name}")
        }
    }

    /// Build index of all entries
    fn build_index(&mut self) -> Result<()> {
        let mut offset = 0usize;

        while offset < self.data.len() {
            if let Some((mut entry, next_offset)) = self.parse_header(offset) {
                // Resolve a hard link ('1') to the bytes of its (already-indexed)
                // target so both names read the same content.
                if entry.entry_type == NodeType::File && !entry.target.is_empty() {
                    if let Some(target) = self.entries.get(&entry.target) {
                        entry.data_offset = target.data_offset;
                        entry.size = target.size;
                    }
                    entry.target = String::new();
                }
                self.entries.insert(entry.path.clone(), entry);
                offset = next_offset;
            } else {
                break;
            }
        }

        // Hard-link counts: file entries that share a resolved `data_offset` are
        // the same inode (a hard-link group from `utils::append_hardlink`), so
        // report `st_nlink` = the group size. Only regular files participate.
        let mut links: BTreeMap<usize, u32> = BTreeMap::new();
        for entry in self.entries.values() {
            if entry.entry_type == NodeType::File {
                *links.entry(entry.data_offset).or_insert(0) += 1;
            }
        }
        for entry in self.entries.values_mut() {
            if entry.entry_type == NodeType::File {
                if let Some(&n) = links.get(&entry.data_offset) {
                    entry.nlink = n;
                }
            }
        }

        Ok(())
    }

    /// Get entry by path
    fn get_entry(&self, path: &str) -> Option<&TarEntry> {
        self.entries.get(path)
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
}

/// File handle for reading from tar
#[allow(dead_code)]
pub struct TarFileHandle {
    path: String,
    offset: u64,
    entry: TarEntry,
    data: *const Vec<u8>,
}

impl FileHandle for TarFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let start = self.offset as usize;
        let data_offset = self.entry.data_offset;
        let size = self.entry.size;

        if start >= size {
            return Ok(0);
        }

        let end = (start + buf.len()).min(size);
        let to_read = end - start;

        unsafe {
            let data = &*self.data;
            buf[..to_read].copy_from_slice(&data[data_offset + start..data_offset + end]);
        }

        self.offset += to_read as u64;
        Ok(to_read)
    }

    fn write(&mut self, _buf: &[u8]) -> Result<usize> {
        Err(FsError::PermissionDenied) // Read-only filesystem
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let size = self.entry.size as i64;
        let new_offset = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(n) => self.offset as i64 + n,
            SeekFrom::End(n) => size + n,
        };

        if new_offset < 0 {
            return Err(FsError::InvalidPath);
        }

        self.offset = new_offset as u64;
        Ok(self.offset)
    }

    fn stat(&self) -> Result<Metadata> {
        // A handle is only ever created over a regular file (open rejects
        // directories and symlinks).
        Ok(entry_meta(&self.entry))
    }
}

/// Build `Metadata` from a tar entry, surfacing the archived permission bits and
/// mtime (tar stores mtime in **seconds**; we use ms). The archive is read-only,
/// so `atime = ctime = mtime`.
fn entry_meta(entry: &TarEntry) -> Metadata {
    let ms = entry.mtime.saturating_mul(1000);
    let base = match entry.entry_type {
        NodeType::Dir => Metadata::dir(),
        // Report the real hard-link count so a committed hard-link group surfaces
        // as `st_nlink > 1` (e.g. `stat` "Links: 2") after a stacked boot.
        NodeType::File => Metadata::file_with_nlink(entry.size as u64, entry.nlink),
        NodeType::Symlink => Metadata::symlink(entry.target.len() as u64),
    };
    base.with_mode((entry.mode & 0o7777) as u16)
        .with_times(ms, ms, ms)
}

/// Normalize a tar entry name to an absolute VFS path: strip a leading `./`,
/// ensure a leading `/`, and drop any trailing `/`.
fn tar_path(name: &str) -> String {
    if name.starts_with("./") {
        let stripped = name[1..].trim_end_matches('/');
        if stripped.is_empty() {
            String::from("/")
        } else {
            String::from(stripped)
        }
    } else if name.starts_with('/') {
        String::from(name.trim_end_matches('/'))
    } else {
        alloc::format!("/{}", name.trim_end_matches('/'))
    }
}

impl FileSystem for TarFs {
    fn open(
        &mut self,
        _caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        let path_str = self.normalize_path(path);

        // Check if file exists
        let entry = self
            .get_entry(&path_str)
            .cloned()
            .ok_or(FsError::NotFound)?;

        // Check if trying to write
        if flags.write || flags.create || flags.truncate {
            return Err(FsError::PermissionDenied); // Read-only
        }

        // Directories and symlinks are not opened as byte streams (a symlink
        // would have been resolved by the namespace before reaching here).
        match entry.entry_type {
            NodeType::Dir => return Err(FsError::IsDir),
            NodeType::Symlink => return Err(FsError::InvalidPath),
            NodeType::File => {}
        }

        let handle = TarFileHandle {
            path: path_str,
            offset: 0,
            entry,
            data: &self.data as *const Vec<u8>,
        };

        Ok(Box::new(handle))
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let path_str = self.normalize_path(path);
        let entry = self.get_entry(&path_str).ok_or(FsError::NotFound)?;
        Ok(entry_meta(entry))
    }

    fn readdir(&self, _caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        let path_str = self.normalize_path(path);

        // Find entries that are direct children of this path
        let prefix = if path_str.ends_with('/') {
            path_str.clone()
        } else {
            alloc::format!("{}/", path_str)
        };

        let mut result = Vec::new();

        for (entry_path, entry) in &self.entries {
            if entry_path == &path_str {
                continue; // Skip self
            }

            if entry_path.starts_with(&prefix) {
                // Get the relative name
                let relative = &entry_path[prefix.len()..];

                // Only include direct children (no slashes in relative path)
                if !relative.contains('/') {
                    result.push(DirEntry {
                        name: String::from(relative),
                        node_type: entry.entry_type,
                    });
                }
            }
        }

        Ok(result)
    }

    fn mkdir(&mut self, _caller: CallerId, _path: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied) // Read-only
    }

    fn unlink(&mut self, _caller: CallerId, _path: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied) // Read-only
    }

    fn rename(&mut self, _caller: CallerId, _from: &KPath, _to: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied) // Read-only
    }

    fn readlink(&self, path: &KPath) -> Result<String> {
        let path_str = self.normalize_path(path);
        let entry = self.get_entry(&path_str).ok_or(FsError::NotFound)?;
        if entry.entry_type == NodeType::Symlink {
            Ok(entry.target.clone())
        } else {
            Err(FsError::InvalidPath)
        }
    }
}
