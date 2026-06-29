//! `/tools` — a read-only file view of the tool catalog.
//!
//! `/svc/tools` is the authoritative broker for search, describe, catalog mutation, and calls. This
//! filesystem is deliberately smaller: it makes the current sharded checkpoint catalog browsable with
//! ordinary file tools, without creating another egress path or another catalog owner. The tree shape is:
//!
//! ```text
//! /tools/<integration>/<owner>/<connection>/<tool>
//! ```
//!
//! Opening a leaf returns the same JSON catalog record that `tools describe <address>` returns. Listing
//! intermediate directories progressively reveals integrations, owners, connections, and tool names.

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use core::cell::RefCell;
use core::ptr::NonNull;

use toolcore::{CatalogIndex, IndexEntry, ToolRecord};

use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom, SYSTEM_CALLER,
};
use crate::vfs::Namespace;

const CATALOG_INDEX_PATH: &str = "/etc/tools/catalog/index.json";
const CATALOG_DIGEST_PATH: &str = "/etc/tools/catalog/index.sha256";
const CATALOG_RECORDS_DIR: &str = "/etc/tools/catalog/records";
const DIGEST_MAX_BYTES: usize = 128;

pub struct ToolsFs {
    namespace: NonNull<Namespace>,
    cache: RefCell<Option<CachedCatalog>>,
}

// The namespace pointer targets the kernel's pinned boot namespace in SystemState. Kernel execution is
// cooperative; like ProcFs, this synthetic filesystem only dereferences it during one bounded VFS op.
unsafe impl Send for ToolsFs {}
unsafe impl Sync for ToolsFs {}

impl ToolsFs {
    /// # Safety
    /// `namespace` must outlive this filesystem. The boot namespace is pinned for the kernel instance.
    pub unsafe fn new(namespace: *const Namespace) -> Self {
        Self {
            namespace: NonNull::new(namespace as *mut Namespace).expect("namespace non-null"),
            cache: RefCell::new(None),
        }
    }

    fn namespace(&self) -> &Namespace {
        unsafe { self.namespace.as_ref() }
    }

    fn read_index_file(&self) -> Option<Vec<u8>> {
        self.read_file(CATALOG_INDEX_PATH)
    }

    fn read_file(&self, path: &str) -> Option<Vec<u8>> {
        let path = KPath::new(path);
        let mut handle = self
            .namespace()
            .open_as(SYSTEM_CALLER, &path, OpenFlags::READ)
            .ok()?;
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            match handle.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => out.extend_from_slice(&buf[..n]),
                Err(_) => return None,
            }
        }
        Some(out)
    }

    fn read_digest_file(&self) -> Option<String> {
        let bytes = self.read_file_limited(CATALOG_DIGEST_PATH, DIGEST_MAX_BYTES)?;
        let text = core::str::from_utf8(&bytes).ok()?.trim();
        if text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit()) {
            Some(text.to_ascii_lowercase())
        } else {
            None
        }
    }

    fn read_file_limited(&self, path: &str, limit: usize) -> Option<Vec<u8>> {
        let path = KPath::new(path);
        let mut handle = self
            .namespace()
            .open_as(SYSTEM_CALLER, &path, OpenFlags::READ)
            .ok()?;
        let mut out = Vec::new();
        let mut buf = [0u8; 128];
        loop {
            match handle.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if out.len().saturating_add(n) > limit {
                        return None;
                    }
                    out.extend_from_slice(&buf[..n]);
                }
                Err(_) => return None,
            }
        }
        Some(out)
    }

    fn catalog_meta(&self) -> Option<CatalogMeta> {
        let path = KPath::new(CATALOG_INDEX_PATH);
        let meta = self.namespace().stat_as(SYSTEM_CALLER, &path).ok()?;
        if meta.node_type == NodeType::File {
            Some(CatalogMeta {
                size: meta.size,
                mtime: meta.mtime,
                ctime: meta.ctime,
            })
        } else {
            None
        }
    }

    fn observed_key(&self) -> Option<CacheKey> {
        let meta = self.catalog_meta()?;
        let digest = self.read_digest_file().or_else(|| {
            self.read_index_file()
                .map(|bytes| pkgcore::sha256_hex(&bytes))
        })?;
        Some(CacheKey::Sidecar { meta, digest })
    }

    fn ensure_cache(&self) {
        if let Some(key) = self.observed_key() {
            if self
                .cache
                .borrow()
                .as_ref()
                .map_or(false, |cached| cached.key == key)
            {
                return;
            }
            let view = self
                .read_index_file()
                .as_deref()
                .map(CatalogView::from_bytes)
                .unwrap_or_else(CatalogView::empty);
            *self.cache.borrow_mut() = Some(CachedCatalog { key, view });
            return;
        }

        let Some(bytes) = self.read_index_file() else {
            let key = CacheKey::Missing;
            if self
                .cache
                .borrow()
                .as_ref()
                .map_or(false, |cached| cached.key == key)
            {
                return;
            }
            *self.cache.borrow_mut() = Some(CachedCatalog {
                key,
                view: CatalogView::empty(),
            });
            return;
        };
        let key = CacheKey::Bytes(bytes.clone());
        if self
            .cache
            .borrow()
            .as_ref()
            .map_or(false, |cached| cached.key == key)
        {
            return;
        }
        let view = CatalogView::from_bytes(&bytes);
        *self.cache.borrow_mut() = Some(CachedCatalog { key, view });
    }

    fn with_view<T>(&self, f: impl FnOnce(&CatalogView) -> T) -> T {
        self.ensure_cache();
        let cache = self.cache.borrow();
        f(&cache.as_ref().expect("toolsfs cache populated").view)
    }

    fn record_bytes_for_entry(&self, entry: &IndexEntry) -> Option<Vec<u8>> {
        let path = alloc::format!("{CATALOG_RECORDS_DIR}/{}", entry.sha);
        let bytes = self.read_file(&path)?;
        if pkgcore::sha256_hex(&bytes) != entry.sha {
            return None;
        }
        let text = core::str::from_utf8(&bytes).ok()?;
        let rec = toolcore::hydrate_record(entry, text).ok()?;
        Some(record_bytes(&rec))
    }

    fn parts<'a>(path: &'a str) -> Vec<&'a str> {
        let rel = path.trim_matches('/');
        if rel.is_empty() {
            Vec::new()
        } else {
            rel.split('/').collect()
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
enum CacheKey {
    /// `/svc/tools` writes this small digest sidecar after checkpointing the authoritative index.
    /// It is the shared cache key for the broker and this read-only filesystem.
    Sidecar {
        meta: CatalogMeta,
        digest: String,
    },
    /// Direct sharded index writes, such as boot seeding and tests, may not have the sidecar. In that
    /// case correctness wins over speed: read bytes every VFS op, but reuse the parsed/indexed view
    /// while the bytes are identical.
    Bytes(Vec<u8>),
    Missing,
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct CatalogMeta {
    size: u64,
    mtime: i64,
    ctime: i64,
}

struct CachedCatalog {
    key: CacheKey,
    view: CatalogView,
}

struct CatalogView {
    dirs: BTreeMap<String, Vec<DirEntry>>,
    files: BTreeMap<String, IndexEntry>,
}

impl CatalogView {
    fn empty() -> Self {
        let mut dirs = BTreeMap::new();
        dirs.insert(String::new(), Vec::new());
        Self {
            dirs,
            files: BTreeMap::new(),
        }
    }

    fn from_bytes(bytes: &[u8]) -> Self {
        let Ok(text) = core::str::from_utf8(bytes) else {
            return Self::empty();
        };
        let index = CatalogIndex::parse(text).unwrap_or_else(|_| CatalogIndex::empty());
        Self::from_index(&index)
    }

    fn from_index(index: &CatalogIndex) -> Self {
        let mut view = Self::empty();
        for entry in index.entries() {
            let p1 = entry.integration.clone();
            let p2 = join_key(&[&entry.integration, &entry.owner]);
            let p3 = join_key(&[&entry.integration, &entry.owner, &entry.connection]);
            let p4 = join_key(&[
                &entry.integration,
                &entry.owner,
                &entry.connection,
                &entry.tool,
            ]);
            view.add_child("", &entry.integration, NodeType::Dir);
            view.add_child(&p1, &entry.owner, NodeType::Dir);
            view.add_child(&p2, &entry.connection, NodeType::Dir);
            view.add_child(&p3, &entry.tool, NodeType::File);
            view.files.insert(p4, entry.clone());
        }
        for entries in view.dirs.values_mut() {
            entries.sort_by(|a, b| a.name.cmp(&b.name));
        }
        view
    }

    fn add_child(&mut self, parent: &str, name: &str, node_type: NodeType) {
        let entries = self.dirs.entry(parent.to_string()).or_default();
        if !entries.iter().any(|entry| entry.name == name) {
            entries.push(DirEntry {
                name: name.to_string(),
                node_type,
            });
        }
        if node_type == NodeType::Dir {
            let child = if parent.is_empty() {
                name.to_string()
            } else {
                alloc::format!("{parent}/{name}")
            };
            self.dirs.entry(child).or_default();
        }
    }

    fn is_dir(&self, key: &str) -> bool {
        self.dirs.contains_key(key)
    }

    fn file(&self, key: &str) -> Option<&IndexEntry> {
        self.files.get(key)
    }

    fn children(&self, key: &str) -> Option<Vec<DirEntry>> {
        self.dirs.get(key).cloned()
    }
}

fn record_bytes(rec: &ToolRecord) -> Vec<u8> {
    let mut text = json::to_string(&rec.to_json());
    text.push('\n');
    text.into_bytes()
}

fn join_key(parts: &[&str]) -> String {
    let mut out = String::new();
    for (i, part) in parts.iter().enumerate() {
        if i > 0 {
            out.push('/');
        }
        out.push_str(part);
    }
    out
}

impl FileSystem for ToolsFs {
    fn open(
        &mut self,
        _caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        if flags.write || flags.create || flags.truncate || flags.append {
            return Err(FsError::PermissionDenied);
        }
        let parts = Self::parts(path.as_str());
        let key = join_key(&parts);
        self.with_view(|view| match parts.len() {
            0..=3 if view.is_dir(&key) => Err(FsError::IsDir),
            4 => match view.file(&key).cloned() {
                Some(entry) => match self.record_bytes_for_entry(&entry) {
                    Some(data) => {
                        Ok(Box::new(ToolsFileHandle { data, pos: 0 }) as Box<dyn FileHandle>)
                    }
                    None => Err(FsError::NotFound),
                },
                None => Err(FsError::NotFound),
            },
            _ => Err(FsError::NotFound),
        })
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let parts = Self::parts(path.as_str());
        let key = join_key(&parts);
        self.with_view(|view| match parts.len() {
            0..=3 if view.is_dir(&key) => Ok(Metadata::dir()),
            4 => match view.file(&key).cloned() {
                Some(entry) => match self.record_bytes_for_entry(&entry) {
                    Some(data) => Ok(Metadata::file(data.len() as u64)),
                    None => Err(FsError::NotFound),
                },
                None => Err(FsError::NotFound),
            },
            _ => Err(FsError::NotFound),
        })
    }

    fn readdir(&self, _caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        let parts = Self::parts(path.as_str());
        let key = join_key(&parts);
        self.with_view(|view| match parts.len() {
            0..=3 => view.children(&key).ok_or(FsError::NotFound),
            4 if view.file(&key).is_some() => Err(FsError::NotDir),
            _ => Err(FsError::NotFound),
        })
    }

    fn mkdir(&mut self, _caller: CallerId, _path: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn unlink(&mut self, _caller: CallerId, _path: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn rename(&mut self, _caller: CallerId, _from: &KPath, _to: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }
}

struct ToolsFileHandle {
    data: Vec<u8>,
    pos: usize,
}

impl FileHandle for ToolsFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let n = self.data.len().saturating_sub(self.pos).min(buf.len());
        buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }

    fn write(&mut self, _buf: &[u8]) -> Result<usize> {
        Err(FsError::PermissionDenied)
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let target = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(n) => self.pos as i64 + n,
            SeekFrom::End(n) => self.data.len() as i64 + n,
        };
        self.pos = target.clamp(0, self.data.len() as i64) as usize;
        Ok(self.pos as u64)
    }

    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(self.data.len() as u64))
    }
}
