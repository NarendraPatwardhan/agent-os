//! envfs — the shell environment as files (Plan 9 `/env`).
//! Mounted at `/env`; each variable is a file whose contents are its value.
//! Reading inspects a variable (`cat /env/PATH`); writing sets one; `unlink`
//! removes one.
//!
//! Environment is **per task** (POSIX): a child inherits a *copy* of its
//! parent's env at spawn, so a temporary `FOO=bar cmd` reaches only `cmd` and
//! never sibling/background tasks. envfs resolves each operation against the
//! **calling** task's env via the scheduler. `open` is handed a `CallerId`
//! directly; the methods that are not (stat/readdir/unlink) use the
//! currently-running task (sound under the single-threaded cooperative
//! discipline). A `SYSTEM_CALLER` or unknown caller falls back to the kernel
//! boot env map (`STATE.env`).

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;
use core::ptr::NonNull;

use crate::task::Scheduler;
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom, SYSTEM_CALLER,
};

pub struct EnvFs {
    sched: *const Scheduler,
    fallback: NonNull<BTreeMap<String, String>>,
}

unsafe impl Send for EnvFs {}
unsafe impl Sync for EnvFs {}

impl EnvFs {
    /// # Safety
    /// `sched` MUST point at the kernel's scheduler and `fallback` at the boot
    /// env map (`STATE.env`), both pinned in SystemState for the instance
    /// lifetime.
    pub unsafe fn new(sched: *const Scheduler, fallback: *mut BTreeMap<String, String>) -> Self {
        EnvFs {
            sched,
            fallback: NonNull::new(fallback).expect("fallback env map non-null"),
        }
    }

    /// Resolve the env map for `caller`: the task's own env, or the boot
    /// fallback for `SYSTEM_CALLER` / an unknown pid. `SYSTEM_CALLER` (the
    /// caller-less FS methods pass it) resolves to the currently-running task.
    fn map_ptr(&self, caller: CallerId) -> *mut BTreeMap<String, String> {
        unsafe {
            let pid = if caller != SYSTEM_CALLER {
                caller
            } else {
                self.sched
                    .as_ref()
                    .and_then(|s| s.current_pid())
                    .unwrap_or(SYSTEM_CALLER)
            };
            if pid != SYSTEM_CALLER {
                if let Some(s) = self.sched.as_ref() {
                    if let Some(t) = s.get_task(pid) {
                        return t.env_ptr();
                    }
                }
            }
            self.fallback.as_ptr()
        }
    }

    /// The variable name for a path (`/PATH` → `PATH`); `None` for the root.
    fn var_name(path: &str) -> Option<&str> {
        let name = path.trim_start_matches('/');
        if name.is_empty() || name.contains('/') {
            None
        } else {
            Some(name)
        }
    }
}

impl FileSystem for EnvFs {
    fn open(
        &mut self,
        caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        let name = Self::var_name(path.as_str()).ok_or(FsError::IsDir)?;
        let writes = flags.write || flags.create || flags.truncate || flags.append;
        // A host control-channel WRITE (`SYSTEM_CALLER`, e.g. the consumer's
        // `vm.fs.write("/env/CEREBRAS_API_KEY", key)`) sets the BOOT environment
        // in `STATE.env` — which pid 1 and every task spawned or `mc_ctl_exec`'d
        // afterward clone (POSIX inheritance). Resolving it to the transient
        // "current" task instead would make the value invisible to a later
        // `exec`'d agent. A GUEST write (a real caller pid) still targets that
        // task's own private env. Reads/stat/readdir keep the running-task view.
        let map = if writes && caller == SYSTEM_CALLER {
            self.fallback.as_ptr()
        } else {
            self.map_ptr(caller)
        };
        if writes {
            let initial = if flags.append {
                unsafe { (*map).get(name).cloned().unwrap_or_default() }
            } else {
                String::new()
            };
            return Ok(Box::new(EnvWriteHandle {
                map,
                name: String::from(name),
                buf: initial.into_bytes(),
            }));
        }
        let value = unsafe { (*map).get(name).ok_or(FsError::NotFound)?.clone() };
        Ok(Box::new(EnvReadHandle {
            data: value.into_bytes(),
            offset: 0,
        }))
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let map = self.map_ptr(SYSTEM_CALLER);
        match Self::var_name(path.as_str()) {
            None => Ok(Metadata::dir()),
            Some(name) => match unsafe { (*map).get(name) } {
                Some(v) => Ok(Metadata::file(v.len() as u64)),
                None => Err(FsError::NotFound),
            },
        }
    }

    fn readdir(&self, _caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        if Self::var_name(path.as_str()).is_some()
            || !path.as_str().trim_start_matches('/').is_empty()
        {
            return Err(FsError::NotDir);
        }
        let map = self.map_ptr(SYSTEM_CALLER);
        Ok(unsafe { &*map }
            .keys()
            .map(|k| DirEntry {
                name: k.clone(),
                node_type: NodeType::File,
            })
            .collect())
    }

    fn mkdir(&mut self, _caller: CallerId, _path: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn unlink(&mut self, _caller: CallerId, path: &KPath) -> Result<()> {
        let name = Self::var_name(path.as_str()).ok_or(FsError::IsDir)?;
        let map = self.map_ptr(SYSTEM_CALLER);
        if unsafe { (*map).remove(name) }.is_some() {
            Ok(())
        } else {
            Err(FsError::NotFound)
        }
    }

    fn rename(&mut self, _caller: CallerId, _from: &KPath, _to: &KPath) -> Result<()> {
        Err(FsError::PermissionDenied)
    }
}

/// Read handle: a snapshot of the variable's value at open time.
struct EnvReadHandle {
    data: Vec<u8>,
    offset: usize,
}

impl FileHandle for EnvReadHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let n = (self.data.len() - self.offset.min(self.data.len())).min(buf.len());
        let start = self.offset.min(self.data.len());
        buf[..n].copy_from_slice(&self.data[start..start + n]);
        self.offset = start + n;
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
        if new < 0 {
            return Err(FsError::InvalidPath);
        }
        self.offset = new as usize;
        Ok(self.offset as u64)
    }
    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(self.data.len() as u64))
    }
}

/// Write handle: accumulates bytes; commits to the calling task's env map on
/// `Drop` (the `FileHandle` trait has no close — `Drop` is the flush hook). The
/// target map pointer is resolved at *open* time and is stable: a task's env
/// (or the fallback) outlives the fd table that holds this handle.
struct EnvWriteHandle {
    map: *mut BTreeMap<String, String>,
    name: String,
    buf: Vec<u8>,
}

impl FileHandle for EnvWriteHandle {
    fn read(&mut self, _buf: &mut [u8]) -> Result<usize> {
        Ok(0)
    }
    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        self.buf.extend_from_slice(buf);
        Ok(buf.len())
    }
    fn seek(&mut self, _pos: SeekFrom) -> Result<u64> {
        Err(FsError::NotImplemented)
    }
    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(self.buf.len() as u64))
    }
}

impl Drop for EnvWriteHandle {
    fn drop(&mut self) {
        // Commit the value, trimming a trailing newline (`\n` or `\r\n`) so
        // `echo v > /env/X` stores `v`, not `v\r\n`.
        let mut bytes = core::mem::take(&mut self.buf);
        if bytes.last() == Some(&b'\n') {
            bytes.pop();
        }
        if bytes.last() == Some(&b'\r') {
            bytes.pop();
        }
        if let Ok(value) = String::from_utf8(bytes) {
            unsafe { (*self.map).insert(self.name.clone(), value) };
        }
    }
}
