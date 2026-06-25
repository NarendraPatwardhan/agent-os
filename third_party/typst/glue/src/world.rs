//! A typst [`World`] over the VM filesystem, split for a resident service: the heavy state — the parsed
//! fonts + the standard library — is loaded ONCE into [`Warm`] and shared by every compile (SERVICES.md
//! §1, the cold-start win), while each request gets a cheap [`CompileWorld`] holding only its root, main,
//! and on-demand source/file caches. Ported from memcontainers `crates/wasi/typst/src/main.rs::McWorld`;
//! the trait bodies are identical — only the warm/per-request split is new.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use typst::diag::{FileError, FileResult, PackageError};
use typst::foundations::{Bytes, Datetime};
use typst::syntax::{FileId, Source, VirtualPath};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};

/// The warm, service-wide state — loaded once at serve start, shared by every [`CompileWorld`]. Parsing
/// the faces and building the [`FontBook`] is the expensive part the service exists to amortize.
pub struct Warm {
    library: LazyHash<Library>,
    book: LazyHash<FontBook>,
    faces: Vec<Font>,
}

impl Warm {
    /// Load the standard library and scan `/usr/share/fonts` (the paper flavor's font layer) for
    /// parseable faces. The engine does NOT embed `typst_assets` — the baseline faces ship as files
    /// there (SERVICES.md §4.2), so they are warmed the same way an agent's own dropped-in fonts are.
    pub fn load() -> Warm {
        let mut faces = Vec::new();
        scan_fonts(Path::new("/usr/share/fonts"), &mut faces);
        let book = FontBook::from_fonts(&faces);
        Warm {
            library: LazyHash::new(Library::default()),
            book: LazyHash::new(book),
            faces,
        }
    }

    /// True if no fonts were found — every compile will fail for lack of a default family, so the serve
    /// loop reports it up front rather than letting each compile fail opaquely.
    pub fn fonts_empty(&self) -> bool {
        self.faces.is_empty()
    }
}

/// Recursively collect parseable font files under `dir`. Best effort — an unreadable dir/file or a face
/// that fails to parse is skipped (a bad file must not abort the scan). The extension gate matches the
/// proven memcontainers scan; `Font::iter` then parses by sfnt magic, not by name.
fn scan_fonts(dir: &Path, faces: &mut Vec<Font>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            scan_fonts(&path, faces);
            continue;
        }
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .map(str::to_ascii_lowercase);
        if matches!(ext.as_deref(), Some("ttf" | "otf" | "ttc" | "otc")) {
            if let Ok(data) = std::fs::read(&path) {
                faces.extend(Font::iter(Bytes::new(data)));
            }
        }
    }
}

/// A per-compile [`World`] borrowing the warm fonts/library. The `main` source is either a real VFS file
/// (`CompileWorld::file`) or a synthetic inline buffer pre-seeded into the cache (`CompileWorld::inline`).
pub struct CompileWorld<'a> {
    warm: &'a Warm,
    /// The compilation root — relative `FileId`s (imports, `#image`, `#include`) resolve against it.
    root: PathBuf,
    main: FileId,
    // `World: Send + Sync`, so the on-demand caches use `Mutex` (not `RefCell`). The guest is
    // single-threaded, so the lock is never contended.
    sources: Mutex<HashMap<FileId, Source>>,
    files: Mutex<HashMap<FileId, Bytes>>,
}

impl<'a> CompileWorld<'a> {
    /// Inline source: a synthetic main pre-seeded with `text`; imports/images resolve against `root`.
    pub fn inline(warm: &'a Warm, text: String, root: PathBuf) -> CompileWorld<'a> {
        let main = FileId::new(None, VirtualPath::new("<inline>.typ"));
        let mut sources = HashMap::new();
        sources.insert(main, Source::new(main, text));
        CompileWorld {
            warm,
            root,
            main,
            sources: Mutex::new(sources),
            files: Mutex::new(HashMap::new()),
        }
    }

    /// A `.typ` file in the VFS as the main; imports/images resolve against `root` (default: the file's
    /// parent directory). When `root` is explicit, the main file id is the main path relative to that root,
    /// so a project root like `/work` can compile `/work/reports/main.typ` without losing `reports/`.
    pub fn file(
        warm: &'a Warm,
        main_path: &Path,
        root: Option<PathBuf>,
    ) -> Result<CompileWorld<'a>, String> {
        if !main_path.exists() {
            return Err(format!("input file not found: {}", main_path.display()));
        }
        let explicit_root = root.is_some();
        let root = root.unwrap_or_else(|| {
            main_path
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("."))
        });
        let vpath = if explicit_root {
            VirtualPath::within_root(main_path, &root).ok_or_else(|| {
                format!(
                    "input path {} is outside root {}",
                    main_path.display(),
                    root.display()
                )
            })?
        } else {
            let name = main_path
                .file_name()
                .ok_or_else(|| format!("invalid input path: {}", main_path.display()))?;
            VirtualPath::new(name)
        };
        let main = FileId::new(None, vpath);
        Ok(CompileWorld {
            warm,
            root,
            main,
            sources: Mutex::new(HashMap::new()),
            files: Mutex::new(HashMap::new()),
        })
    }

    /// Resolve a non-package `FileId` to an on-disk path under the root.
    fn resolve(&self, id: FileId) -> FileResult<PathBuf> {
        if let Some(spec) = id.package() {
            // No network in v1 → the `@preview` package registry is unreachable.
            return Err(FileError::Package(PackageError::NotFound(spec.clone())));
        }
        id.vpath()
            .resolve(&self.root)
            .ok_or(FileError::AccessDenied)
    }
}

impl World for CompileWorld<'_> {
    fn library(&self) -> &LazyHash<Library> {
        &self.warm.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &self.warm.book
    }

    fn main(&self) -> FileId {
        self.main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        if let Some(s) = self.sources.lock().unwrap().get(&id) {
            return Ok(s.clone());
        }
        let path = self.resolve(id)?;
        let text = std::fs::read_to_string(&path).map_err(|e| FileError::from_io(e, &path))?;
        let source = Source::new(id, text);
        self.sources.lock().unwrap().insert(id, source.clone());
        Ok(source)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        if let Some(b) = self.files.lock().unwrap().get(&id) {
            return Ok(b.clone());
        }
        let path = self.resolve(id)?;
        let data = std::fs::read(&path).map_err(|e| FileError::from_io(e, &path))?;
        let bytes = Bytes::new(data);
        self.files.lock().unwrap().insert(id, bytes.clone());
        Ok(bytes)
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.warm.faces.get(index).cloned()
    }

    fn today(&self, offset: Option<i64>) -> Option<Datetime> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?;
        let dt = time::OffsetDateTime::from_unix_timestamp(now.as_secs() as i64).ok()?;
        let dt = match offset {
            None => dt, // no local timezone in the VM → UTC
            Some(hours) => dt.to_offset(time::UtcOffset::from_hms(hours as i8, 0, 0).ok()?),
        };
        Datetime::from_ymd_hms(
            dt.year(),
            dt.month() as u8,
            dt.day(),
            dt.hour(),
            dt.minute(),
            dt.second(),
        )
    }
}
