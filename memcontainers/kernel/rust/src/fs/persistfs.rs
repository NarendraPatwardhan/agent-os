//! persistfs — the `/var/persist` filesystem over the async persist bridge.
//!
//! The host store is still a flat whole-value KV: keys are path bytes without
//! the mount's leading slash, directories are implicit in `key/` prefixes, and
//! `mkdir` writes an empty marker key ending in `/`. What changed is the
//! transport. Every host touch now goes through `PersistSource` (`start` → poll
//! → body → close), so this filesystem must behave like `mountfs`: return
//! `WouldBlock` while a host operation is in flight, serve synchronous `stat`
//! from learned metadata, and park `Drop`-time commits for tick-driven draining.
//!
//! A single VFS operation can need several KV requests (`rename`: get → list →
//! put → delete). The channel therefore keeps a *per-caller operation epoch* and
//! memoizes completed low-level request bodies inside that epoch. If the syscall
//! yields after `put`, the retry does not execute the earlier `get` again; it
//! reuses the memoized bodies and drains the same in-flight request. Starting a
//! different VFS operation for that caller clears the epoch. Async backends can
//! interleave between those low-level requests (for example between `rename`'s
//! `put` and `delete`); local disk usually completes without a yield. The
//! concurrency contract is therefore the same as `mountfs`: operations are
//! retry-idempotent, not globally atomic.

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::{RefCell, UnsafeCell};

use crate::fs::proxy;
use crate::persist::{self, PersistRead, PersistSource};
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result, SeekFrom, SYSTEM_CALLER,
};

const STALE_INFLIGHT_PASSES: u32 = 256;

/// GET response tags. Missing is body data, not a transport failure, so a BEAM
/// or browser relay can answer "not found" without abusing `poll == -1`.
const GET_ABSENT: u8 = constants_rust::PERSIST_GET_ABSENT as u8;
const GET_PRESENT: u8 = constants_rust::PERSIST_GET_PRESENT as u8;

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct RequestId {
    op: u32,
    key: Vec<u8>,
    value_fingerprint: u64,
}

#[derive(Clone, PartialEq, Eq)]
struct OpId {
    tag: u8,
    path: String,
    extra: Vec<u8>,
}

struct InflightCall {
    req: RequestId,
    source: PersistSource,
    body: Vec<u8>,
    age: u32,
}

struct PendingCommit {
    source: PersistSource,
}

pub struct PersistChannel {
    inflight: BTreeMap<CallerId, InflightCall>,
    active_ops: BTreeMap<CallerId, OpId>,
    completed: BTreeMap<(CallerId, RequestId), Vec<u8>>,
    meta: BTreeMap<String, Metadata>,
    pending_commits: Vec<PendingCommit>,
}

impl PersistChannel {
    fn new() -> Rc<RefCell<Self>> {
        let mut meta = BTreeMap::new();
        meta.insert(String::from("/"), Metadata::dir());
        Rc::new(RefCell::new(Self {
            inflight: BTreeMap::new(),
            active_ops: BTreeMap::new(),
            completed: BTreeMap::new(),
            meta,
            pending_commits: Vec::new(),
        }))
    }

    fn begin(&mut self, caller: CallerId, op_id: OpId) {
        if self.active_ops.get(&caller) == Some(&op_id) {
            return;
        }
        self.inflight.remove(&caller);
        self.completed.retain(|(c, _), _| *c != caller);
        self.active_ops.insert(caller, op_id);
    }

    fn finish(&mut self, caller: CallerId) {
        self.inflight.remove(&caller);
        self.completed.retain(|(c, _), _| *c != caller);
        self.active_ops.remove(&caller);
    }

    fn request(&mut self, caller: CallerId, op: u32, key: &[u8], value: &[u8]) -> Result<Vec<u8>> {
        self.drain_commits();
        let req = RequestId {
            op,
            key: key.to_vec(),
            value_fingerprint: request_value_fingerprint(value),
        };
        if let Some(body) = self.completed.get(&(caller, req.clone())) {
            return Ok(body.clone());
        }

        if let Some(call) = self.inflight.get(&caller) {
            if call.req != req {
                self.inflight.remove(&caller);
            }
        }
        if !self.inflight.contains_key(&caller) {
            let source =
                PersistSource::start(op, key, value).map_err(|_| FsError::PermissionDenied)?;
            self.inflight.insert(
                caller,
                InflightCall {
                    req: req.clone(),
                    source,
                    body: Vec::new(),
                    age: 0,
                },
            );
        }

        enum Outcome {
            Pending,
            Done,
            Failed,
        }
        let outcome = {
            let call = self
                .inflight
                .get_mut(&caller)
                .expect("inflight just ensured");
            call.age = 0;
            let mut tmp = [0u8; 4096];
            loop {
                match call.source.read_into(&mut tmp) {
                    PersistRead::Pending => break Outcome::Pending,
                    PersistRead::Got(n) => call.body.extend_from_slice(&tmp[..n]),
                    PersistRead::Eof => break Outcome::Done,
                    PersistRead::Failed => break Outcome::Failed,
                }
            }
        };

        match outcome {
            Outcome::Pending => Err(FsError::WouldBlock),
            Outcome::Done => {
                let call = self.inflight.remove(&caller).expect("present");
                let body = call.body;
                self.completed.insert((caller, req), body.clone());
                Ok(body)
            }
            Outcome::Failed => {
                self.inflight.remove(&caller);
                Err(FsError::IoError)
            }
        }
    }

    fn drain_commits(&mut self) {
        let mut scratch = [0u8; 256];
        self.pending_commits.retain_mut(|commit| loop {
            match commit.source.read_into(&mut scratch) {
                PersistRead::Pending => break true,
                PersistRead::Got(_) => continue,
                PersistRead::Eof | PersistRead::Failed => break false,
            }
        });
    }

    fn evict_stale_inflight(&mut self, is_alive: &impl Fn(CallerId) -> bool) {
        let mut dead_callers = Vec::new();
        self.inflight.retain(|&caller, call| {
            let keep = if caller == SYSTEM_CALLER {
                call.age = call.age.saturating_add(1);
                call.age <= STALE_INFLIGHT_PASSES
            } else {
                is_alive(caller)
            };
            if !keep {
                dead_callers.push(caller);
            }
            keep
        });
        for caller in dead_callers {
            self.finish(caller);
        }
        let dead: Vec<CallerId> = self
            .active_ops
            .keys()
            .copied()
            .filter(|&caller| caller != SYSTEM_CALLER && !is_alive(caller))
            .collect();
        for caller in dead {
            self.finish(caller);
        }
    }
}

struct PersistRegistry(UnsafeCell<Vec<Rc<RefCell<PersistChannel>>>>);
unsafe impl Sync for PersistRegistry {}
impl PersistRegistry {
    const fn new() -> Self {
        Self(UnsafeCell::new(Vec::new()))
    }
    #[allow(clippy::mut_from_ref)]
    unsafe fn get(&self) -> &mut Vec<Rc<RefCell<PersistChannel>>> {
        unsafe { &mut *self.0.get() }
    }
}
static PERSIST_REGISTRY: PersistRegistry = PersistRegistry::new();

pub fn drain_all(is_caller_alive: impl Fn(CallerId) -> bool) {
    let reg = unsafe { PERSIST_REGISTRY.get() };
    reg.retain(|ch| {
        let still_pending = {
            let mut c = ch.borrow_mut();
            c.evict_stale_inflight(&is_caller_alive);
            c.drain_commits();
            !c.pending_commits.is_empty()
        };
        Rc::strong_count(ch) > 1 || still_pending
    });
}

pub fn pending_commit_count() -> usize {
    let reg = unsafe { PERSIST_REGISTRY.get() };
    reg.iter().map(|ch| ch.borrow().pending_commits.len()).sum()
}

fn fnv(seed: u64, bytes: &[u8]) -> u64 {
    let mut h = seed;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn request_value_fingerprint(data: &[u8]) -> u64 {
    fnv(0xcbf2_9ce4_8422_2325, data)
}

fn op_id(tag: u8, path: &str, extra: &[u8]) -> OpId {
    OpId {
        tag,
        path: String::from(path),
        extra: extra.to_vec(),
    }
}

fn open_flags_id(flags: OpenFlags) -> [u8; 1] {
    [((flags.read as u8) << 0)
        | ((flags.write as u8) << 1)
        | ((flags.create as u8) << 2)
        | ((flags.truncate as u8) << 3)
        | ((flags.append as u8) << 4)]
}

fn key_of(rel: &KPath) -> Vec<u8> {
    rel.as_str()
        .trim_start_matches('/')
        .trim_end_matches('/')
        .as_bytes()
        .to_vec()
}

fn dir_prefix(key: &[u8]) -> Vec<u8> {
    let mut prefix = key.to_vec();
    if !prefix.is_empty() {
        prefix.push(b'/');
    }
    prefix
}

fn decode_get(body: &[u8]) -> Result<Option<Vec<u8>>> {
    match body.split_first() {
        Some((&GET_ABSENT, rest)) if rest.is_empty() => Ok(None),
        Some((&GET_PRESENT, rest)) => Ok(Some(rest.to_vec())),
        _ => Err(FsError::IoError),
    }
}

fn decode_list(body: &[u8]) -> Vec<Vec<u8>> {
    body.split(|&b| b == 0)
        .filter(|k| !k.is_empty())
        .map(|k| k.to_vec())
        .collect()
}

pub struct PersistFs {
    channel: Rc<RefCell<PersistChannel>>,
}

impl PersistFs {
    pub fn new() -> Self {
        let channel = PersistChannel::new();
        unsafe { PERSIST_REGISTRY.get().push(Rc::clone(&channel)) };
        Self { channel }
    }

    fn begin(&self, caller: CallerId, id: OpId) {
        self.channel.borrow_mut().begin(caller, id);
    }

    fn finish_unless_blocked<T>(&self, caller: CallerId, result: &Result<T>) {
        if !matches!(result, Err(FsError::WouldBlock)) {
            self.channel.borrow_mut().finish(caller);
        }
    }

    fn request(&self, caller: CallerId, op: u32, key: &[u8], value: &[u8]) -> Result<Vec<u8>> {
        self.channel.borrow_mut().request(caller, op, key, value)
    }

    fn get(&self, caller: CallerId, key: &[u8]) -> Result<Option<Vec<u8>>> {
        decode_get(&self.request(caller, persist::OP_GET, key, &[])?)
    }

    fn put(&self, caller: CallerId, key: &[u8], value: &[u8]) -> Result<()> {
        let _ = self.request(caller, persist::OP_PUT, key, value)?;
        Ok(())
    }

    fn delete(&self, caller: CallerId, key: &[u8]) -> Result<()> {
        let _ = self.request(caller, persist::OP_DELETE, key, &[])?;
        Ok(())
    }

    fn list(&self, caller: CallerId, prefix: &[u8]) -> Result<Vec<Vec<u8>>> {
        Ok(decode_list(&self.request(
            caller,
            persist::OP_LIST,
            prefix,
            &[],
        )?))
    }

    fn dir_exists(&self, caller: CallerId, key: &[u8]) -> Result<bool> {
        if key.is_empty() {
            return Ok(true);
        }
        Ok(!self.list(caller, &dir_prefix(key))?.is_empty())
    }

    fn remember_meta(&self, path: &str, meta: Metadata) {
        proxy::remember_meta(&mut self.channel.borrow_mut().meta, path, meta);
    }

    fn forget_path(&self, path: &str) {
        proxy::forget_path(&mut self.channel.borrow_mut().meta, path);
    }

    fn stat_impl(&self, caller: CallerId, path: &KPath) -> Result<Metadata> {
        let key = key_of(path);
        if key.is_empty() {
            return Ok(Metadata::dir());
        }
        match self.get(caller, &key)? {
            Some(value) => {
                let meta = Metadata::file(value.len() as u64);
                self.remember_meta(path.as_str(), meta.clone());
                Ok(meta)
            }
            None if self.dir_exists(caller, &key)? => {
                self.remember_meta(path.as_str(), Metadata::dir());
                Ok(Metadata::dir())
            }
            None => {
                self.forget_path(path.as_str());
                Err(FsError::NotFound)
            }
        }
    }
}

impl Default for PersistFs {
    fn default() -> Self {
        Self::new()
    }
}

impl FileSystem for PersistFs {
    fn open(
        &mut self,
        caller: CallerId,
        path: &KPath,
        flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        self.begin(caller, op_id(b'o', path.as_str(), &open_flags_id(flags)));
        let result = (|| {
            let key = key_of(path);
            if key.is_empty() {
                return Err(FsError::IsDir);
            }
            let existing = self.get(caller, &key)?;
            let existed = existing.is_some();
            let buf = match existing {
                Some(_) if flags.truncate => Vec::new(),
                Some(value) => value,
                None if self.dir_exists(caller, &key)? => return Err(FsError::IsDir),
                None if flags.create => Vec::new(),
                None => return Err(FsError::NotFound),
            };
            let offset = if flags.append { buf.len() as u64 } else { 0 };
            let dirty = flags.truncate || (flags.create && !existed);
            self.remember_meta(path.as_str(), Metadata::file(buf.len() as u64));
            Ok(Box::new(PersistFileHandle {
                channel: Rc::clone(&self.channel),
                path: String::from(path.as_str()),
                key,
                buf,
                offset,
                dirty,
            }) as Box<dyn FileHandle>)
        })();
        self.finish_unless_blocked(caller, &result);
        result
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        if path.as_str() == "/" {
            return Ok(Metadata::dir());
        }
        if let Some(meta) = proxy::cached_meta(&self.channel.borrow().meta, path.as_str()) {
            return Ok(meta);
        }
        // Synchronous path resolution cannot yield. Unknown paths are treated as
        // provisional directories, so a nested key can reach the terminal op that
        // performs the real async store lookup.
        Ok(Metadata::dir())
    }

    fn stat_as(&self, caller: CallerId, path: &KPath) -> Result<Metadata> {
        self.begin(caller, op_id(b's', path.as_str(), &[]));
        let result = self.stat_impl(caller, path);
        self.finish_unless_blocked(caller, &result);
        result
    }

    fn readdir(&self, caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        self.begin(caller, op_id(b'r', path.as_str(), &[]));
        let result = (|| {
            let key = key_of(path);
            if !key.is_empty() && self.get(caller, &key)?.is_some() {
                return Err(FsError::NotDir);
            }
            let prefix = dir_prefix(&key);
            let keys = self.list(caller, &prefix)?;
            if !key.is_empty() && keys.is_empty() {
                self.forget_path(path.as_str());
                return Err(FsError::NotFound);
            }

            let mut entries: BTreeMap<String, NodeType> = BTreeMap::new();
            let mut child_paths: BTreeMap<String, NodeType> = BTreeMap::new();
            for k in keys {
                if !k.starts_with(&prefix) {
                    continue;
                }
                let name_bytes = &k[prefix.len()..];
                if name_bytes.is_empty() {
                    continue;
                }
                let (name_bytes, kind) = match name_bytes.iter().position(|&b| b == b'/') {
                    Some(0) => continue,
                    Some(idx) => (&name_bytes[..idx], NodeType::Dir),
                    None => (name_bytes, NodeType::File),
                };
                if let Ok(name) = core::str::from_utf8(name_bytes) {
                    let child = proxy::child_path(path.as_str(), name);
                    child_paths.insert(child, kind);
                    entries
                        .entry(String::from(name))
                        .and_modify(|existing| {
                            if matches!(kind, NodeType::Dir) {
                                *existing = NodeType::Dir;
                            }
                        })
                        .or_insert(kind);
                }
            }
            {
                let mut ch = self.channel.borrow_mut();
                proxy::forget_children_of(&mut ch.meta, path.as_str());
                proxy::remember_meta(&mut ch.meta, path.as_str(), Metadata::dir());
                for (child, kind) in child_paths {
                    let meta = match kind {
                        NodeType::Dir => Metadata::dir(),
                        NodeType::File => Metadata::file(0),
                        NodeType::Symlink => Metadata::symlink(0),
                    };
                    proxy::remember_meta(&mut ch.meta, &child, meta);
                }
            }
            Ok(entries
                .into_iter()
                .map(|(name, node_type)| DirEntry { name, node_type })
                .collect())
        })();
        self.finish_unless_blocked(caller, &result);
        result
    }

    fn mkdir(&mut self, caller: CallerId, path: &KPath) -> Result<()> {
        self.begin(caller, op_id(b'm', path.as_str(), &[]));
        let result = (|| {
            let key = key_of(path);
            if key.is_empty() {
                return Ok(());
            }
            if self.get(caller, &key)?.is_some() {
                return Err(FsError::AlreadyExists);
            }
            self.put(caller, &dir_prefix(&key), &[])?;
            self.remember_meta(path.as_str(), Metadata::dir());
            Ok(())
        })();
        self.finish_unless_blocked(caller, &result);
        result
    }

    fn unlink(&mut self, caller: CallerId, path: &KPath) -> Result<()> {
        self.begin(caller, op_id(b'u', path.as_str(), &[]));
        let result = (|| {
            let key = key_of(path);
            if key.is_empty() {
                return Err(FsError::IsDir);
            }
            if self.get(caller, &key)?.is_some() {
                self.delete(caller, &key)?;
                self.forget_path(path.as_str());
                return Ok(());
            }
            if self.dir_exists(caller, &key)? {
                return Err(FsError::IsDir);
            }
            Err(FsError::NotFound)
        })();
        self.finish_unless_blocked(caller, &result);
        result
    }

    fn rename(&mut self, caller: CallerId, from: &KPath, to: &KPath) -> Result<()> {
        let mut extra = Vec::from(to.as_str().as_bytes());
        extra.push(0);
        self.begin(caller, op_id(b'n', from.as_str(), &extra));
        let result = (|| {
            let from_key = key_of(from);
            let to_key = key_of(to);
            if from_key.is_empty() || to_key.is_empty() {
                return Err(FsError::IsDir);
            }
            let value = match self.get(caller, &from_key)? {
                Some(value) => value,
                None if self.dir_exists(caller, &from_key)? => return Err(FsError::IsDir),
                None => return Err(FsError::NotFound),
            };
            if self.dir_exists(caller, &to_key)? {
                return Err(FsError::IsDir);
            }
            self.put(caller, &to_key, &value)?;
            self.delete(caller, &from_key)?;
            proxy::rename_path(
                &mut self.channel.borrow_mut().meta,
                from.as_str(),
                to.as_str(),
            );
            Ok(())
        })();
        self.finish_unless_blocked(caller, &result);
        result
    }
}

struct PersistFileHandle {
    channel: Rc<RefCell<PersistChannel>>,
    path: String,
    key: Vec<u8>,
    buf: Vec<u8>,
    offset: u64,
    dirty: bool,
}

impl FileHandle for PersistFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let start = (self.offset as usize).min(self.buf.len());
        let n = (self.buf.len() - start).min(buf.len());
        buf[..n].copy_from_slice(&self.buf[start..start + n]);
        self.offset += n as u64;
        Ok(n)
    }

    fn write(&mut self, data: &[u8]) -> Result<usize> {
        let start = self.offset as usize;
        let end = start + data.len();
        if end > self.buf.len() {
            self.buf.resize(end, 0);
        }
        self.buf[start..end].copy_from_slice(data);
        self.offset = end as u64;
        self.dirty = true;
        Ok(data.len())
    }

    fn seek(&mut self, pos: SeekFrom) -> Result<u64> {
        let len = self.buf.len() as i64;
        let new = match pos {
            SeekFrom::Start(o) => o as i64,
            SeekFrom::Current(d) => self.offset as i64 + d,
            SeekFrom::End(d) => len + d,
        };
        if new < 0 {
            return Err(FsError::InvalidPath);
        }
        self.offset = new as u64;
        Ok(self.offset)
    }

    fn stat(&self) -> Result<Metadata> {
        Ok(Metadata::file(self.buf.len() as u64))
    }

    fn truncate(&mut self, size: u64) -> Result<()> {
        self.buf.resize(size as usize, 0);
        self.dirty = true;
        Ok(())
    }
}

impl Drop for PersistFileHandle {
    fn drop(&mut self) {
        if !self.dirty {
            return;
        }
        let mut ch = self.channel.borrow_mut();
        if let Ok(source) = PersistSource::start(persist::OP_PUT, &self.key, &self.buf) {
            ch.pending_commits.push(PendingCommit { source });
        }
        proxy::forget_path(&mut ch.meta, &self.path);
    }
}
