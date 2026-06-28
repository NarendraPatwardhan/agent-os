//! `/tools` — a read-only file view of the tool catalog.
//!
//! `/svc/tools` is the authoritative broker for search, describe, catalog mutation, and calls. This
//! filesystem is deliberately smaller: it makes the current checkpoint catalog browsable with ordinary
//! file tools, without creating another egress path or another catalog owner. The tree shape is:
//!
//! ```text
//! /tools/<integration>/<owner>/<connection>/<tool>
//! ```
//!
//! Opening a leaf returns the same JSON catalog record that `tools describe <address>` returns. Listing
//! intermediate directories progressively reveals integrations, owners, connections, and tool names.

use alloc::boxed::Box;
use alloc::string::ToString;
use alloc::vec::Vec;
use core::ptr::NonNull;

use toolcore::{Catalog, ToolRecord};

use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom, SYSTEM_CALLER,
};
use crate::vfs::Namespace;

const CATALOG_PATH: &str = "/etc/tools/catalog.json";

pub struct ToolsFs {
    namespace: NonNull<Namespace>,
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
        }
    }

    fn namespace(&self) -> &Namespace {
        unsafe { self.namespace.as_ref() }
    }

    fn catalog(&self) -> Catalog {
        let Some(bytes) = self.read_catalog_file() else {
            return Catalog::empty();
        };
        let Ok(text) = core::str::from_utf8(&bytes) else {
            return Catalog::empty();
        };
        Catalog::parse(text).unwrap_or_else(|_| Catalog::empty())
    }

    fn read_catalog_file(&self) -> Option<Vec<u8>> {
        let path = KPath::new(CATALOG_PATH);
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

    fn parts<'a>(path: &'a str) -> Vec<&'a str> {
        let rel = path.trim_matches('/');
        if rel.is_empty() {
            Vec::new()
        } else {
            rel.split('/').collect()
        }
    }

    fn record_at<'a>(catalog: &'a Catalog, parts: &[&str]) -> Option<&'a ToolRecord> {
        if parts.len() != 4 {
            return None;
        }
        catalog.records().iter().find(|rec| {
            rec.integration == parts[0]
                && rec.owner == parts[1]
                && rec.connection == parts[2]
                && rec.tool == parts[3]
        })
    }

    fn prefix_exists(catalog: &Catalog, parts: &[&str]) -> bool {
        match parts {
            [] => true,
            [integration] => catalog
                .records()
                .iter()
                .any(|rec| rec.integration == *integration),
            [integration, owner] => catalog
                .records()
                .iter()
                .any(|rec| rec.integration == *integration && rec.owner == *owner),
            [integration, owner, connection] => catalog.records().iter().any(|rec| {
                rec.integration == *integration
                    && rec.owner == *owner
                    && rec.connection == *connection
            }),
            [integration, owner, connection, tool] => catalog.records().iter().any(|rec| {
                rec.integration == *integration
                    && rec.owner == *owner
                    && rec.connection == *connection
                    && rec.tool == *tool
            }),
            _ => false,
        }
    }

    fn child_entries(catalog: &Catalog, parts: &[&str]) -> Vec<DirEntry> {
        let mut entries: Vec<DirEntry> = Vec::new();
        for rec in catalog.records() {
            let (name, node_type) = match parts {
                [] => (rec.integration.as_str(), NodeType::Dir),
                [integration] if rec.integration == *integration => {
                    (rec.owner.as_str(), NodeType::Dir)
                }
                [integration, owner] if rec.integration == *integration && rec.owner == *owner => {
                    (rec.connection.as_str(), NodeType::Dir)
                }
                [integration, owner, connection]
                    if rec.integration == *integration
                        && rec.owner == *owner
                        && rec.connection == *connection =>
                {
                    (rec.tool.as_str(), NodeType::File)
                }
                _ => continue,
            };
            if !entries.iter().any(|entry| entry.name == name) {
                entries.push(DirEntry {
                    name: name.to_string(),
                    node_type,
                });
            }
        }
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        entries
    }

    fn record_bytes(rec: &ToolRecord) -> Vec<u8> {
        let mut text = json::to_string(&rec.to_json());
        text.push('\n');
        text.into_bytes()
    }
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
        let catalog = self.catalog();
        let parts = Self::parts(path.as_str());
        match parts.len() {
            0..=3 if Self::prefix_exists(&catalog, &parts) => Err(FsError::IsDir),
            4 => match Self::record_at(&catalog, &parts) {
                Some(rec) => Ok(Box::new(ToolsFileHandle {
                    data: Self::record_bytes(rec),
                    pos: 0,
                })),
                None => Err(FsError::NotFound),
            },
            _ => Err(FsError::NotFound),
        }
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let catalog = self.catalog();
        let parts = Self::parts(path.as_str());
        match parts.len() {
            0..=3 if Self::prefix_exists(&catalog, &parts) => Ok(Metadata::dir()),
            4 => match Self::record_at(&catalog, &parts) {
                Some(rec) => Ok(Metadata::file(Self::record_bytes(rec).len() as u64)),
                None => Err(FsError::NotFound),
            },
            _ => Err(FsError::NotFound),
        }
    }

    fn readdir(&self, _caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        let catalog = self.catalog();
        let parts = Self::parts(path.as_str());
        match parts.len() {
            0..=3 if Self::prefix_exists(&catalog, &parts) => {
                Ok(Self::child_entries(&catalog, &parts))
            }
            4 if Self::record_at(&catalog, &parts).is_some() => Err(FsError::NotDir),
            _ => Err(FsError::NotFound),
        }
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
