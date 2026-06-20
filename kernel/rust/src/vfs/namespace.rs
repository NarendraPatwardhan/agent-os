//! The mount namespace — maps mount-point paths to filesystems, resolves any path by
//! longest-prefix matching, and routes the operation to the owning filesystem.
//!
//! The namespace is PER-PROCESS (Plan 9). A [`Namespace`] is a cheap, cloneable *view*:
//! the mount table lives behind an `Rc` shared with the parent at spawn (a pointer
//! copy), and a `bind`/`unmount` copies-on-write so it only affects the acting task.
//! The FILESYSTEMS themselves are shared (`Rc<RefCell<Box<dyn FileSystem>>>`) — `/tmp`'s
//! contents are the same for everyone; only the *view* (what is mounted where) is
//! per-task. `bind` aliases an existing path subtree to another mount point in the
//! caller's own namespace.
//!
//! Single-threaded cooperative discipline: `Rc`/`RefCell`/`UnsafeCell` are sound here as
//! elsewhere in the kernel. Each delegated op clones the `Rc` of the target filesystem
//! (cheap) and `borrow_mut`s it for the call, so no table borrow is held across a
//! filesystem call. This is also the kernel's ONLY symlink-following site, and where
//! `..` is collapsed — closing a path-escape a purely lexical confinement check misses.

use alloc::boxed::Box;
use alloc::collections::{BTreeMap, BTreeSet};
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::{RefCell, UnsafeCell};

use super::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result,
};
// The write-gate capability comes straight from the contract projection, so the VFS does
// not depend on `task` (the bit is selected by the resolved mount; see `write_cap_at`).
use constants_rust::CAP_FS_WRITE;

/// A reference-counted, interior-mutable filesystem shared across every namespace that
/// mounts it.
type SharedFs = Rc<RefCell<Box<dyn FileSystem>>>;

/// One mount-point entry. `sub` is the path WITHIN `fs` that this mount point maps to —
/// `""`/`"/"` for an ordinary mount, or the source subtree for a `bind`. Clone is cheap
/// (clones the `Rc`, sharing the filesystem).
#[derive(Clone)]
struct Mount {
    fs: SharedFs,
    sub: String,
    label: &'static str,
    read_only: bool,
    /// The single capability bit a caller must hold to WRITE this mount. Almost always
    /// `CAP_FS_WRITE`; the per-task `/scratch` tmpfs uses `CAP_SCRATCH` so a `read-only`
    /// tool can spill there without write-anywhere authority. This is how write-authority
    /// stays a capability bit-test (selected by the resolved mount) rather than a path
    /// test in the syscall gate.
    write_cap: u8,
}

/// Result of resolving a path against a namespace.
struct Resolved {
    mount_point: String,
    fs_path: KPath,
    fs: SharedFs,
    read_only: bool,
    write_cap: u8,
}

pub struct Namespace {
    /// The task that owns this view. The root namespace is owned by the agent (pid 1);
    /// children fork it with their own pid.
    owner: CallerId,
    /// The mount table, shared (Rc) with the parent until a `bind`/`unmount` copies-on-
    /// write. `UnsafeCell` for interior mutability under the single-threaded discipline.
    table: UnsafeCell<Rc<BTreeMap<String, Mount>>>,
}

/// The agent owns the root namespace (pid 1, root of its universe).
const AGENT_OWNER: CallerId = 1;

impl Namespace {
    /// Create the empty root namespace (owned by the agent). Boot mounts into it and
    /// every task forks from it.
    pub fn new() -> Self {
        Self {
            owner: AGENT_OWNER,
            table: UnsafeCell::new(Rc::new(BTreeMap::new())),
        }
    }

    /// Fork a per-task view for `owner`, sharing the parent's mount table (a pointer
    /// copy) until the child `bind`s or `unmount`s (copy-on-write).
    pub fn fork(&self, owner: CallerId) -> Namespace {
        Namespace {
            owner,
            table: UnsafeCell::new(Rc::clone(unsafe { &*self.table.get() })),
        }
    }

    fn table(&self) -> &BTreeMap<String, Mount> {
        unsafe { &*self.table.get() }
    }

    /// Mutable mount table, copied-on-write if shared with another view.
    fn table_mut(&self) -> &mut BTreeMap<String, Mount> {
        unsafe { Rc::make_mut(&mut *self.table.get()) }
    }

    /// Mount `fs` at `path` with an observable `label` and a `read_only` flag. Writes to
    /// it require the ordinary `CAP_FS_WRITE`; use [`mount_labeled_caps`] for a mount
    /// gated on a different capability (e.g. the `/scratch` tmpfs gated on `CAP_SCRATCH`).
    pub fn mount_labeled(
        &self,
        path: &str,
        fs: Box<dyn FileSystem>,
        label: &'static str,
        read_only: bool,
    ) {
        self.mount_labeled_caps(path, fs, label, read_only, CAP_FS_WRITE);
    }

    /// Like [`mount_labeled`] but with an explicit `write_cap`: the capability a caller
    /// must hold to write this mount. The per-task `/scratch` tmpfs mounts with
    /// `CAP_SCRATCH` so a `read-only` task (lacking `CAP_FS_WRITE`) may still spill there.
    pub fn mount_labeled_caps(
        &self,
        path: &str,
        fs: Box<dyn FileSystem>,
        label: &'static str,
        read_only: bool,
        write_cap: u8,
    ) {
        self.table_mut().insert(
            normalize(path),
            Mount {
                fs: Rc::new(RefCell::new(fs)),
                sub: String::new(),
                label,
                read_only,
                write_cap,
            },
        );
    }

    /// Serialize the root mount's writable diff into a `.tar` layer (the `commit`
    /// primitive). `None` when the root isn't a CoW overlay. Clones the `Rc` and
    /// `borrow_mut`s it, like every delegated op — no table borrow held across the call.
    pub fn commit_root_layer(&self) -> Option<Vec<u8>> {
        let mount = self.table().get(&normalize("/"))?;
        let fs = Rc::clone(&mount.fs);
        let result = fs.borrow_mut().commit_layer();
        result
    }

    /// `bind` `old` onto `new` in THIS namespace: `new` becomes a mount point resolving
    /// to whatever `old` resolves to (the same filesystem + subtree). Plan-9 `bind`.
    /// Copies-on-write, so it affects only the acting task.
    pub fn bind(&self, old: &str, new: &str) -> Result<()> {
        let r = self.resolve(&KPath::new(old)).ok_or(FsError::NotFound)?;
        let label = self
            .table()
            .get(&r.mount_point)
            .map(|m| m.label)
            .unwrap_or("bind");
        self.table_mut().insert(
            normalize(new),
            Mount {
                fs: r.fs,
                sub: String::from(r.fs_path.as_str()),
                label,
                read_only: r.read_only,
                write_cap: r.write_cap,
            },
        );
        Ok(())
    }

    /// Unmount the filesystem/bind at `path` in THIS namespace. Refuses (`NotEmpty`,
    /// i.e. busy) while a child mount exists under it.
    pub fn unmount(&self, path: &str) -> Result<()> {
        let norm = normalize(path);
        let has_child = self
            .table()
            .keys()
            .any(|mp| mp != &norm && mount_beneath(&norm, mp));
        if has_child {
            return Err(FsError::NotEmpty);
        }
        if self.table_mut().remove(&norm).is_none() {
            return Err(FsError::NotFound);
        }
        Ok(())
    }

    /// Snapshot the mount table as `(path, label, read_only)`, sorted by path — the data
    /// behind `/proc/mounts`.
    pub fn mount_list(&self) -> Vec<(String, &'static str, bool)> {
        self.table()
            .iter()
            .map(|(p, m)| (p.clone(), m.label, m.read_only))
            .collect()
    }

    /// Basenames of every mount whose parent directory is `path` (deduped).
    fn child_mount_basenames(&self, path: &str) -> Vec<String> {
        let norm = normalize(path);
        let mut names = BTreeSet::new();
        for mp in self.table().keys() {
            if let Some(name) = child_mount_name(&norm, mp) {
                names.insert(String::from(name));
            }
        }
        names.into_iter().collect()
    }

    /// Resolve a path to its filesystem and the path WITHIN that filesystem by
    /// longest-prefix matching. Clones the target filesystem's `Rc` so no table borrow
    /// is held across the subsequent filesystem call.
    fn resolve(&self, path: &KPath) -> Option<Resolved> {
        let path_str = path.as_str();
        let table = self.table();
        let mut best: Option<&String> = None;
        for mount_point in table.keys() {
            // Root matches every absolute path. Sub-mounts require the path to be the
            // mount point itself or to continue with `/` (so `/devfoo` is not routed to
            // a `/dev` mount).
            let matches = if mount_point == "/" {
                path_str.starts_with('/')
            } else {
                path_str == mount_point
                    || (path_str.starts_with(mount_point.as_str())
                        && path_str[mount_point.len()..].starts_with('/'))
            };
            if matches && (best.is_none() || mount_point.len() > best.unwrap().len()) {
                best = Some(mount_point);
            }
        }
        let mount_point = best?.clone();
        let mount = table.get(&mount_point)?;

        // The path relative to the mount point. For the root mount the path is already
        // fs-relative (`/bin/pwd` stays `/bin/pwd`); for a sub-mount we strip the mount
        // point (`/dev/null` → `/null`).
        let rel: &str = if path_str == mount_point {
            "/"
        } else if mount_point == "/" {
            path_str
        } else {
            &path_str[mount_point.len()..]
        };
        // Prepend the mount's `sub` (non-empty only for binds).
        let fs_path = if mount.sub.is_empty() {
            KPath::new(rel)
        } else if rel == "/" {
            KPath::new(&mount.sub)
        } else {
            KPath::new(&alloc::format!("{}{}", mount.sub, rel))
        };

        Some(Resolved {
            mount_point,
            fs_path,
            fs: Rc::clone(&mount.fs),
            read_only: mount.read_only,
            write_cap: mount.write_cap,
        })
    }

    /// The capability bit required to WRITE the mount backing `path` — read off the
    /// mount the path resolves to (so the syscall write-gate stays a pure capability
    /// test, with the bit *selected by the mount*, never a path string). Defaults to
    /// `CAP_FS_WRITE` for an unresolved path (a write there fails at the operation).
    pub fn write_cap_at(&self, path: &KPath) -> u8 {
        self.resolve(path).map_or(CAP_FS_WRITE, |r| r.write_cap)
    }

    // ---- delegated operations ----

    /// Open `path` on behalf of `caller` — identity-aware filesystems use it; plain ones
    /// ignore it.
    pub fn open_as(
        &self,
        caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        let writes = flags.write || flags.create || flags.truncate || flags.append;
        if writes && r.read_only {
            return Err(FsError::PermissionDenied);
        }
        // Owner-triad mode enforcement (single subject), AND-ed with the capability
        // checks already done by the caller. Returns `AccessDenied` (EACCES), distinct
        // from the capability `EPERM`.
        match r.fs.borrow().stat(&r.fs_path) {
            Ok(meta) => {
                if flags.read && !meta.owner_readable() {
                    return Err(FsError::AccessDenied);
                }
                if writes && !meta.owner_writable() {
                    return Err(FsError::AccessDenied);
                }
            }
            // Creating a new node needs write on the *parent* directory.
            Err(FsError::NotFound) if flags.create => {
                if let Some(parent) = r.fs_path.parent() {
                    if let Ok(pm) = r.fs.borrow().stat(&parent) {
                        if !pm.owner_writable() {
                            return Err(FsError::AccessDenied);
                        }
                    }
                }
            }
            // Non-existent without create, or any other stat error: let `open` surface
            // the real error (NotFound, etc.).
            Err(_) => {}
        }
        r.fs.borrow_mut().open(&r.fs_path, flags, caller)
    }

    /// Convenience open as the namespace's own owner (a task's operations act as that
    /// task). Boot/profile use the root namespace, whose owner is the agent.
    pub fn open(&self, path: &KPath, flags: OpenFlags) -> Result<Box<dyn FileHandle>> {
        self.open_as(self.owner, path, flags)
    }

    pub fn stat(&self, path: &KPath) -> Result<Metadata> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        r.fs.borrow().stat(&r.fs_path)
    }

    pub fn stat_as(&self, path: &KPath, caller: CallerId) -> Result<Metadata> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        r.fs.borrow().stat_as(&r.fs_path, caller)
    }

    pub fn readdir(&self, path: &KPath, caller: CallerId) -> Result<Vec<DirEntry>> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        // Listing a directory requires owner-`r` and owner-`x` on the directory itself.
        // (If the dir exists only as a mount parent its `stat` may fail — fall through
        // to the merge below.)
        if let Ok(meta) = r.fs.borrow().stat(&r.fs_path) {
            if !meta.owner_readable() || !meta.owner_executable() {
                return Err(FsError::AccessDenied);
            }
        }
        let fs_entries = r.fs.borrow().readdir(&r.fs_path, caller);
        let children = self.child_mount_basenames(path.as_str());

        let mut merged: BTreeMap<String, DirEntry> = BTreeMap::new();
        match fs_entries {
            Ok(entries) => {
                for e in entries {
                    merged.insert(e.name.clone(), e);
                }
            }
            // A served directory still fetching its listing must propagate the yield so
            // the syscall layer re-polls — never let the mount-parent fallback below mask
            // it as "an empty dir that only hosts mounts".
            Err(FsError::WouldBlock) => return Err(FsError::WouldBlock),
            // The directory may exist only as the parent of a mount point.
            Err(e) => {
                if children.is_empty() {
                    return Err(e);
                }
            }
        }
        for name in children {
            merged.insert(
                name.clone(),
                DirEntry {
                    name,
                    node_type: NodeType::Dir,
                },
            );
        }
        Ok(merged.into_values().collect())
    }

    pub fn mkdir(&self, path: &KPath, caller: CallerId) -> Result<()> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        if r.read_only {
            return Err(FsError::PermissionDenied);
        }
        require_parent_writable(&r)?;
        r.fs.borrow_mut().mkdir(&r.fs_path, caller)
    }

    pub fn unlink(&self, path: &KPath, caller: CallerId) -> Result<()> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        if r.read_only {
            return Err(FsError::PermissionDenied);
        }
        require_parent_writable(&r)?;
        r.fs.borrow_mut().unlink(&r.fs_path, caller)
    }

    pub fn rename(&self, from: &KPath, to: &KPath, caller: CallerId) -> Result<()> {
        let rf = self.resolve(from).ok_or(FsError::NotFound)?;
        let rt = self.resolve(to).ok_or(FsError::NotFound)?;
        if rf.mount_point != rt.mount_point {
            return Err(FsError::CrossDevice); // POSIX EXDEV — `mv` falls back to copy+remove
        }
        if rf.read_only {
            return Err(FsError::PermissionDenied);
        }
        // Both the source and destination directory entries are mutated.
        require_parent_writable(&rf)?;
        require_parent_writable(&rt)?;
        rf.fs.borrow_mut().rename(&rf.fs_path, &rt.fs_path, caller)
    }

    /// Read the target text of the symlink at `path` (no following).
    pub fn readlink(&self, path: &KPath) -> Result<String> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        r.fs.borrow().readlink(&r.fs_path)
    }

    /// Create a symbolic link at `link` with target text `target`.
    pub fn symlink(&self, target: &str, link: &KPath) -> Result<()> {
        let r = self.resolve(link).ok_or(FsError::NotFound)?;
        if r.read_only {
            return Err(FsError::PermissionDenied);
        }
        require_parent_writable(&r)?;
        r.fs.borrow_mut().symlink(target, &r.fs_path)
    }

    /// Set the permission bits at `path` (POSIX `chmod`).
    pub fn set_mode(&self, path: &KPath, mode: u16) -> Result<()> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        if r.read_only {
            return Err(FsError::PermissionDenied);
        }
        r.fs.borrow_mut().set_mode(&r.fs_path, mode)
    }

    /// Set the access+modify times at `path` in ms since the epoch (POSIX `utimes`).
    pub fn set_times(&self, path: &KPath, atime: i64, mtime: i64) -> Result<()> {
        let r = self.resolve(path).ok_or(FsError::NotFound)?;
        if r.read_only {
            return Err(FsError::PermissionDenied);
        }
        r.fs.borrow_mut().set_times(&r.fs_path, atime, mtime)
    }

    /// Create a hard link `new` to the same node as `existing`. Both must live on the
    /// same mount (POSIX `EXDEV` otherwise).
    pub fn link(&self, existing: &KPath, new: &KPath) -> Result<()> {
        let re = self.resolve(existing).ok_or(FsError::NotFound)?;
        let rn = self.resolve(new).ok_or(FsError::NotFound)?;
        if re.mount_point != rn.mount_point {
            return Err(FsError::CrossDevice);
        }
        if rn.read_only {
            return Err(FsError::PermissionDenied);
        }
        require_parent_writable(&rn)?;
        re.fs.borrow_mut().link(&re.fs_path, &rn.fs_path)
    }

    /// `lstat`-equivalent used internally by [`canonicalize`]: the node type at `path`
    /// (no following), plus the link target when it is a symlink. `None` when nothing
    /// resolves there (a missing component).
    fn lstat_kind(&self, path: &str) -> Option<(NodeType, String)> {
        let kp = KPath::new(path);
        let r = self.resolve(&kp)?;
        let md = r.fs.borrow().stat(&r.fs_path).ok()?;
        if md.node_type == NodeType::Symlink {
            let target = r.fs.borrow().readlink(&r.fs_path).unwrap_or_default();
            Some((NodeType::Symlink, target))
        } else {
            Some((md.node_type, String::new()))
        }
    }

    /// Require search (`x`) permission on an already-resolved directory path. Checked
    /// during canonicalization before looking up the next path component, so a symlink
    /// inside a no-search directory cannot be followed to bypass the directory's mode
    /// bits. Synthetic mount-parent directories (a path that only exists because a child
    /// mount lives below it) behave as conventional searchable `0755` directories.
    fn require_search_dir(&self, path: &str) -> Result<()> {
        let kp = KPath::new(path);
        let Some(r) = self.resolve(&kp) else {
            return if self.child_mount_basenames(path).is_empty() {
                Err(FsError::NotFound)
            } else {
                Ok(())
            };
        };
        match r.fs.borrow().stat(&r.fs_path) {
            Ok(meta) => {
                if meta.node_type != NodeType::Dir {
                    return Err(FsError::NotDir);
                }
                if !meta.owner_executable() {
                    return Err(FsError::AccessDenied);
                }
                Ok(())
            }
            Err(FsError::NotFound) if !self.child_mount_basenames(path).is_empty() => Ok(()),
            Err(e) => Err(e),
        }
    }

    /// Resolve `path` to a canonical absolute path: collapse `.`/`..` and follow
    /// symlinks. Every intermediate component is followed; the final component is
    /// followed only when `follow_final` is set (so `lstat`/`readlink`/`unlink`/
    /// `symlink`/`rename` operate on the link itself, while `open`/`stat`/`chdir` see
    /// through it). A missing component is passed through literally, so `ENOENT` and
    /// create semantics are preserved by the eventual operation.
    ///
    /// This is the kernel's ONLY symlink-following site (filesystems never follow). It
    /// is also where `..` is collapsed — closing a path-escape that a purely lexical
    /// confinement check would otherwise miss. There is no TOCTOU window: this and the
    /// operation that consumes the result both run synchronously within one syscall
    /// under the big kernel lock, with no yield in between, so the path that is checked
    /// is exactly the path that is used.
    pub fn canonicalize(&self, path: &KPath, follow_final: bool) -> Result<KPath> {
        // Components still to process. A symlink splices its target in front of whatever
        // remains, so this is a work list, not a simple iterator.
        let mut pending: Vec<String> = path.as_str().split('/').map(String::from).collect();
        let mut out: Vec<String> = Vec::new();
        let mut hops = 0usize;
        let mut idx = 0usize;

        while idx < pending.len() {
            let comp = pending[idx].clone();
            idx += 1;
            if comp.is_empty() {
                continue;
            }
            // Looking up any non-empty component requires search permission on the
            // directory that contains it. This must happen before lstat_kind so
            // symlink-following cannot read through a no-execute directory.
            self.require_search_dir(&abs_join(&out))?;
            if comp == "." {
                continue;
            }
            if comp == ".." {
                out.pop();
                continue;
            }
            let candidate = abs_from(&out, &comp);
            let is_final = idx == pending.len();
            let follow = !is_final || follow_final;
            match if follow {
                self.lstat_kind(&candidate)
            } else {
                None
            } {
                Some((NodeType::Symlink, target)) => {
                    hops += 1;
                    if hops > SYMLOOP_MAX {
                        return Err(FsError::Loop);
                    }
                    // Re-process the target's components, then whatever remained after
                    // this one. An absolute target restarts from the root.
                    let mut next: Vec<String> = target.split('/').map(String::from).collect();
                    next.extend_from_slice(&pending[idx..]);
                    if target.starts_with('/') {
                        out.clear();
                    }
                    pending = next;
                    idx = 0;
                }
                // A real file/dir, or a missing component, or a not-followed final
                // component: keep it verbatim.
                _ => out.push(comp),
            }
        }
        Ok(KPath::new(&abs_join(&out)))
    }
}

/// POSIX `SYMLOOP_MAX`: the most symlinks a single resolution may traverse before it is
/// declared a loop (`ELOOP`).
const SYMLOOP_MAX: usize = 40;

/// Owner-`w` on the parent directory of a resolved path — required to create, remove, or
/// rename an entry there (POSIX needs `w` on the containing dir, not on the entry).
/// Permissive if the parent can't be stat'd: the underlying op then surfaces the real
/// error (e.g. `NotFound`). Single subject = owner triad.
fn require_parent_writable(r: &Resolved) -> Result<()> {
    if let Some(parent) = r.fs_path.parent() {
        if let Ok(pm) = r.fs.borrow().stat(&parent) {
            if !pm.owner_writable() {
                return Err(FsError::AccessDenied);
            }
        }
    }
    Ok(())
}

/// Build `/<out…>/<comp>` from a resolved component stack and one more name.
fn abs_from(out: &[String], comp: &str) -> String {
    let mut s = abs_join(out);
    if s != "/" {
        s.push('/');
    }
    s.push_str(comp);
    s
}

/// Join a resolved component stack into an absolute path (`/` when empty).
fn abs_join(components: &[String]) -> String {
    if components.is_empty() {
        return String::from("/");
    }
    let mut s = String::new();
    for c in components {
        s.push('/');
        s.push_str(c);
    }
    s
}

impl Default for Namespace {
    fn default() -> Self {
        Self::new()
    }
}

/// Normalize a path for mount comparisons: strip a trailing slash (except root).
fn normalize(path: &str) -> String {
    if path.len() > 1 {
        String::from(path.trim_end_matches('/'))
    } else {
        String::from(path)
    }
}

/// True when `child` is a mount point below `parent`, at any depth.
fn mount_beneath(parent: &str, child: &str) -> bool {
    if parent == "/" {
        return child != "/" && child.starts_with('/');
    }
    child
        .strip_prefix(parent)
        .is_some_and(|rest| rest.starts_with('/'))
}

/// The immediate child entry under `parent` needed to reach mount point `mp`. For
/// example, `/a/b/c` contributes `b` when listing `/a`, and `a` when listing `/`.
fn child_mount_name<'a>(parent: &str, mp: &'a str) -> Option<&'a str> {
    if mp == parent {
        return None;
    }
    let rest = if parent == "/" {
        mp.strip_prefix('/')?
    } else {
        mp.strip_prefix(parent)?.strip_prefix('/')?
    };
    if rest.is_empty() {
        return None;
    }
    Some(rest.split('/').next().unwrap_or(rest))
}
