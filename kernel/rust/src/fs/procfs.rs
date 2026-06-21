//! Process filesystem - a read-only synthetic FS exposing kernel state.
//!
//! Layout (initial cut):
//!   /proc/uptime                 monotonic ms since boot, "<sec>.<ms>\n"
//!   /proc/[pid]/cmdline          null-separated argv (command, args...)
//!   /proc/[pid]/status           Name/Pid/PPid/State/Cwd, one per line
//!   /proc/[pid]/cwd              cwd as plain text (Linux uses a symlink; this
//!                                synthetic file intentionally stays text)
//!
//! On open(), the full file body is rendered into a buffer that backs the
//! FileHandle. This gives readers a stable snapshot for a single open and
//! avoids holding a borrow into the scheduler across reads.

use alloc::boxed::Box;
use alloc::format;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;
use core::ptr::NonNull;

use crate::bridge;
use crate::task::{Scheduler, TaskState};
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom,
};

/// The agent's identity: pid 1 (the shell) is root of its universe and may
/// control any task via `/proc/[pid]/ctl`.
const AGENT_PID: CallerId = 1;
use crate::vfs::Namespace;

pub struct ProcFs {
    scheduler: NonNull<Scheduler>,
    namespace: NonNull<Namespace>,
}

// Scheduler lives in the kernel's static SystemState alongside the
// Namespace that owns this ProcFs; both are pinned for the kernel's
// lifetime. Cooperative mode is single-threaded; the threaded build
// will gate scheduler state behind its own synchronization.
unsafe impl Send for ProcFs {}
unsafe impl Sync for ProcFs {}

impl ProcFs {
    /// # Safety
    /// `scheduler` and `namespace` MUST outlive this `ProcFs`. In the kernel's
    /// static SystemState all three are pinned for the instance lifetime.
    pub unsafe fn new(scheduler: *const Scheduler, namespace: *const Namespace) -> Self {
        Self {
            scheduler: NonNull::new(scheduler as *mut Scheduler).expect("scheduler non-null"),
            namespace: NonNull::new(namespace as *mut Namespace).expect("namespace non-null"),
        }
    }

    fn scheduler(&self) -> &Scheduler {
        unsafe { self.scheduler.as_ref() }
    }

    fn namespace(&self) -> &Namespace {
        unsafe { self.namespace.as_ref() }
    }

    /// Render `/proc/mounts`: one line per mount, `<path> <label> <ro|rw>`.
    /// Reads only the namespace's disjoint mount metadata, so it is safe even
    /// though this very call is reached *through* the namespace.
    fn render_mounts_from(&self, namespace: &Namespace) -> Vec<u8> {
        let mut out = String::new();
        for (path, label, read_only) in namespace.mount_list() {
            let mode = if read_only { "ro" } else { "rw" };
            out.push_str(&format!("{} {} {}\n", path, label, mode));
        }
        out.into_bytes()
    }

    /// Render `/proc/mounts` from the caller's per-process namespace. Falls
    /// back to the root namespace for pid 1/system callers.
    fn render_mounts_for(&self, caller: CallerId) -> Vec<u8> {
        if let Some(task) = self.scheduler().get_task(caller) {
            if let Some(ns) = task.namespace() {
                return self.render_mounts_from(ns);
            }
        }
        self.render_mounts_from(self.namespace())
    }

    /// Strip a leading "/proc" if present, then a leading '/'.
    fn rel<'a>(&self, path: &'a str) -> &'a str {
        let s = path.strip_prefix("/proc").unwrap_or(path);
        s.strip_prefix('/').unwrap_or(s)
    }

    fn render_uptime(&self) -> Vec<u8> {
        let ms = unsafe { bridge::mc_time_monotonic() };
        let ms = if ms < 0 { 0 } else { ms };
        let whole = ms / 1000;
        let frac = ms % 1000;
        format!("{}.{:03}\n", whole, frac).into_bytes()
    }

    fn state_label(state: TaskState) -> &'static str {
        match state {
            TaskState::Ready => "R (ready)",
            TaskState::Running => "R (running)",
            TaskState::Blocked(_) => "S (blocked)",
            TaskState::Zombie => "Z (zombie)",
        }
    }

    fn render_pid_file(&self, pid: u32, leaf: &str) -> Option<Vec<u8>> {
        let task = self.scheduler().get_task(pid)?;
        match leaf {
            "cmdline" => {
                let mut buf = Vec::new();
                buf.extend_from_slice(task.command.as_bytes());
                for arg in &task.args {
                    buf.push(0);
                    buf.extend_from_slice(arg.as_bytes());
                }
                buf.push(0);
                Some(buf)
            }
            "status" => {
                let s = format!(
                    "Name:\t{}\nPid:\t{}\nPPid:\t{}\nState:\t{}\nCwd:\t{}\n",
                    task.name,
                    task.id,
                    task.parent_id.unwrap_or(0),
                    Self::state_label(task.state),
                    task.get_cwd(),
                );
                Some(s.into_bytes())
            }
            "cwd" => {
                let mut s = String::from(task.get_cwd());
                s.push('\n');
                Some(s.into_bytes())
            }
            _ => None,
        }
    }

    /// Returns (is_file, body) for a path within procfs, or None if the
    /// path does not exist as a *file*. Directories return None here and
    /// are recognized via `kind_at`.
    fn render_file(&self, path: &str) -> Option<Vec<u8>> {
        let rel = self.rel(path);
        if rel == "uptime" {
            return Some(self.render_uptime());
        }
        if rel == "mounts" {
            return Some(self.render_mounts_from(self.namespace()));
        }
        let mut parts = rel.splitn(2, '/');
        let pid_str = parts.next()?;
        let leaf = parts.next()?;
        let pid: u32 = pid_str.parse().ok()?;
        self.render_pid_file(pid, leaf)
    }

    /// Classify a path as Dir, File, or absent.
    fn kind_at(&self, path: &str) -> Option<NodeType> {
        let rel = self.rel(path);
        if rel.is_empty() {
            return Some(NodeType::Dir); // /proc itself
        }
        // Top-level synthetic files.
        if rel == "uptime" || rel == "mounts" {
            return Some(NodeType::File);
        }
        // "/proc/<pid>" or "/proc/<pid>/<leaf>"
        let mut parts = rel.splitn(2, '/');
        let pid_str = parts.next()?;
        let pid: u32 = pid_str.parse().ok()?;
        if self.scheduler().get_task(pid).is_none() {
            return None;
        }
        match parts.next() {
            None => Some(NodeType::Dir),
            Some("") => Some(NodeType::Dir),
            Some(leaf) if matches!(leaf, "cmdline" | "status" | "cwd" | "ctl") => {
                Some(NodeType::File)
            }
            _ => None,
        }
    }

    /// Parse a `/proc/<pid>/<leaf>` path into `(pid, leaf)`, or `None`.
    fn parse_pid_leaf<'a>(&self, path: &'a str) -> Option<(u32, &'a str)> {
        let rel = self.rel(path);
        let mut parts = rel.splitn(2, '/');
        let pid: u32 = parts.next()?.parse().ok()?;
        let leaf = parts.next()?;
        Some((pid, leaf))
    }
}

/// In-memory read-only handle backed by a pre-rendered buffer.
pub struct ProcFileHandle {
    data: Vec<u8>,
    offset: usize,
}

impl FileHandle for ProcFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let remaining = self.data.len().saturating_sub(self.offset);
        let n = core::cmp::min(buf.len(), remaining);
        buf[..n].copy_from_slice(&self.data[self.offset..self.offset + n]);
        self.offset += n;
        Ok(n)
    }

    fn write(&mut self, _buf: &[u8]) -> Result<usize> {
        Err(FsError::PermissionDenied)
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let new = match pos {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::Current(n) => self.offset as i64 + n,
            SeekFrom::End(n) => self.data.len() as i64 + n,
        };
        if new < 0 || (new as usize) > self.data.len() {
            return Err(FsError::InvalidPath);
        }
        self.offset = new as usize;
        Ok(self.offset as u64)
    }

    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(self.data.len() as u64))
    }
}

/// Writable control file `/proc/[pid]/ctl`. Buffers written
/// bytes and executes each complete newline-terminated command immediately
/// (`kill`, `stop`, `cont`); any trailing unterminated command is run on `Drop`
/// (so `echo -n kill` also works). This is the Plan-9 `ctl`/`data` pattern: the
/// control plane is a file you write commands to — signal-free.
pub struct ProcCtlHandle {
    scheduler: NonNull<Scheduler>,
    target: u32,
    line: Vec<u8>,
}

impl ProcCtlHandle {
    fn new(scheduler: NonNull<Scheduler>, target: u32) -> Self {
        Self {
            scheduler,
            target,
            line: Vec::new(),
        }
    }

    fn sched(&self) -> &Scheduler {
        unsafe { self.scheduler.as_ref() }
    }

    /// Execute one command; returns `false` for an unrecognized command.
    fn exec(&self, cmd: &str) -> bool {
        match cmd.trim() {
            "" => true,
            "kill" => {
                self.sched().kill_task(self.target, 137);
                true
            }
            "stop" => {
                self.sched().set_frozen(self.target, true);
                true
            }
            "cont" => {
                self.sched().set_frozen(self.target, false);
                true
            }
            _ => false,
        }
    }
}

impl FileHandle for ProcCtlHandle {
    fn read(&mut self, _buf: &mut [u8]) -> Result<usize> {
        Ok(0) // the control file is write-only in spirit; reads see EOF
    }

    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        self.line.extend_from_slice(buf);
        let mut ok = true;
        // Execute each complete (newline-terminated) command.
        while let Some(pos) = self.line.iter().position(|&b| b == b'\n') {
            let cmd: Vec<u8> = self.line.drain(..=pos).collect();
            let s = core::str::from_utf8(&cmd[..cmd.len() - 1]).unwrap_or("");
            if !self.exec(s) {
                ok = false;
            }
        }
        if ok {
            Ok(buf.len())
        } else {
            Err(FsError::InvalidPath) // unrecognized ctl command → EINVAL
        }
    }

    fn seek(&mut self, _pos: SeekFrom) -> Result<u64> {
        Err(FsError::NotImplemented)
    }

    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(0))
    }
}

impl Drop for ProcCtlHandle {
    fn drop(&mut self) {
        if !self.line.is_empty() {
            // Run a final unterminated command (e.g. `echo -n kill`).
            if let Ok(s) = core::str::from_utf8(&self.line) {
                let s = String::from(s);
                let _ = self.exec(&s);
            }
        }
    }
}

impl FileSystem for ProcFs {
    fn open(
        &mut self,
        caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        let writes = flags.write || flags.create || flags.truncate || flags.append;

        // `/proc/[pid]/ctl` — the one writable proc file.
        // Writing a command controls the target task; reading yields an empty
        // body so `cat` does not error.
        if let Some((pid, "ctl")) = self.parse_pid_leaf(path.as_str()) {
            if self.scheduler().get_task(pid).is_none() {
                return Err(FsError::NotFound);
            }
            if !writes {
                return Ok(Box::new(ProcFileHandle {
                    data: Vec::new(),
                    offset: 0,
                }));
            }
            // Permission: the agent (pid 1) may control anything; otherwise you
            // may control only yourself or a descendant.
            let allowed = caller == AGENT_PID
                || caller == pid
                || self.scheduler().is_ancestor_of(caller, pid);
            if !allowed {
                return Err(FsError::PermissionDenied);
            }
            return Ok(Box::new(ProcCtlHandle::new(self.scheduler, pid)));
        }

        // Everything else under /proc is read-only.
        if writes {
            return Err(FsError::PermissionDenied);
        }
        if self.rel(path.as_str()) == "mounts" {
            return Ok(Box::new(ProcFileHandle {
                data: self.render_mounts_for(caller),
                offset: 0,
            }));
        }
        let data = self.render_file(path.as_str()).ok_or(FsError::NotFound)?;
        Ok(Box::new(ProcFileHandle { data, offset: 0 }))
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let kind = self.kind_at(path.as_str()).ok_or(FsError::NotFound)?;
        let size = match kind {
            NodeType::Dir => 0,
            NodeType::File => self
                .render_file(path.as_str())
                .map(|v| v.len() as u64)
                .unwrap_or(0),
            NodeType::Symlink => 0, // procfs never synthesizes symlinks
        };
        // Synthetic node: the conventional mode defaults (file 0o644 / dir 0o755)
        // keep the mode check a no-op so procfs's own access logic stays
        // authoritative (e.g. the writable `ctl` file, read-only data files).
        Ok(match kind {
            NodeType::Dir => Metadata::dir(),
            NodeType::File => Metadata::file(size),
            NodeType::Symlink => Metadata::symlink(0),
        })
    }

    fn readdir(&self, _caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        let rel = self.rel(path.as_str());
        // /proc root
        if rel.is_empty() {
            let mut entries = vec![
                DirEntry {
                    name: String::from("uptime"),
                    node_type: NodeType::File,
                },
                DirEntry {
                    name: String::from("mounts"),
                    node_type: NodeType::File,
                },
            ];
            for id in self.scheduler().task_ids() {
                entries.push(DirEntry {
                    name: format!("{}", id),
                    node_type: NodeType::Dir,
                });
            }
            return Ok(entries);
        }
        // /proc/[pid]/
        let pid_str = rel.trim_end_matches('/');
        if let Ok(pid) = pid_str.parse::<u32>() {
            if self.scheduler().get_task(pid).is_some() {
                return Ok(vec![
                    DirEntry {
                        name: String::from("cmdline"),
                        node_type: NodeType::File,
                    },
                    DirEntry {
                        name: String::from("status"),
                        node_type: NodeType::File,
                    },
                    DirEntry {
                        name: String::from("cwd"),
                        node_type: NodeType::File,
                    },
                    DirEntry {
                        name: String::from("ctl"),
                        node_type: NodeType::File,
                    },
                ]);
            }
        }
        Err(FsError::NotFound)
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
