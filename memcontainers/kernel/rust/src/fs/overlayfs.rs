//! Read-only union of N TarFs layers — the substrate for image flavors, stacked
//! as `CowFs(OverlayFs([TarFs…]))`. Layers stack lowest→highest; a higher layer
//! shadows a lower one, and an OCI whiteout `.wh.<name>` in a higher layer hides
//! `<name>` from every lower layer (so a committed deletion round-trips). All
//! mutation is refused — the wrapping `CowFs` provides the writable top.

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use crate::fs::TarFs;
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, Result,
};

pub struct OverlayFs {
    /// Index 0 = lowest (base), last = highest (top wins).
    layers: Vec<TarFs>,
}

impl OverlayFs {
    pub fn new(layers: Vec<TarFs>) -> Self {
        OverlayFs { layers }
    }

    /// The index of the topmost layer that provides `p`, honoring whiteouts:
    /// scanning top-down, a real entry wins in that layer; otherwise any
    /// `.wh.<component>` along `p`'s prefix chain hides the lower subtree
    /// (→ `None`). `None` if absent or hidden.
    fn provider(&self, p: &str) -> Option<usize> {
        let whiteouts = whiteout_prefixes(p);
        for (i, layer) in self.layers.iter().enumerate().rev() {
            if layer.stat(&KPath::new(p)).is_ok() {
                return Some(i);
            }
            if whiteouts
                .iter()
                .any(|wh| layer.stat(&KPath::new(wh)).is_ok())
            {
                return None; // whited-out by this (higher) layer
            }
        }
        None
    }
}

impl FileSystem for OverlayFs {
    fn open(
        &mut self,
        caller: CallerId,
        path: &KPath,
        flags: crate::vfs::traits::OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        if flags.write || flags.create || flags.truncate {
            return Err(FsError::PermissionDenied); // read-only; CowFs provides writes
        }
        match self.provider(path.as_str()) {
            Some(i) => self.layers[i].open(caller, path, flags),
            None => Err(FsError::NotFound),
        }
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        match self.provider(path.as_str()) {
            Some(i) => self.layers[i].stat(path),
            None => Err(FsError::NotFound),
        }
    }

    fn readdir(&self, caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        let p = path.as_str();
        // The directory itself must exist and not be whited-out.
        if self.provider(p).is_none() {
            return Err(FsError::NotFound);
        }
        // Union the layers bottom→top: a higher layer shadows a lower entry; a
        // `.wh.<name>` removes `<name>` from everything below; `.wh.*` entries are
        // themselves hidden from the listing.
        let mut merged: BTreeMap<String, DirEntry> = BTreeMap::new();
        for layer in self.layers.iter() {
            let Ok(entries) = layer.readdir(caller, path) else {
                continue;
            };
            for e in entries {
                if let Some(name) = e.name.strip_prefix(".wh.") {
                    merged.remove(name);
                } else {
                    merged.insert(e.name.clone(), e);
                }
            }
        }
        Ok(merged.into_values().collect())
    }

    fn readlink(&self, path: &KPath) -> Result<String> {
        match self.provider(path.as_str()) {
            Some(i) => self.layers[i].readlink(path),
            None => Err(FsError::NotFound),
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

/// The OCI whiteout paths that can hide `path` from lower layers. For
/// `/a/b/c`, both `/.wh.a` and `/a/.wh.b` hide the subtree before the exact
/// `/a/b/.wh.c` entry is considered.
fn whiteout_prefixes(path: &str) -> Vec<String> {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() || trimmed == "/" {
        return Vec::new();
    }

    let mut out = Vec::new();
    let mut parent = String::new();
    for component in trimmed.trim_start_matches('/').split('/') {
        if component.is_empty() {
            continue;
        }
        if parent.is_empty() {
            out.push(alloc::format!("/.wh.{component}"));
            parent = alloc::format!("/{component}");
        } else {
            out.push(alloc::format!("{parent}/.wh.{component}"));
            parent = alloc::format!("{parent}/{component}");
        }
    }
    out
}
