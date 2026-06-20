//! mountfs — a host-backed filesystem. `vm.mount(path, driver)` installs a
//! `MountFs` into the root namespace; each VFS op is proxied to a host-resident
//! driver (`s3`/`hostDir`/`vectorStore`) over the `mc_host_call` bridge. It is a
//! generalization of persistfs/netfs over a host callback: like `persistfs` it
//! buffers a whole value and commits a write on `Drop`; like `servedfs` it runs a
//! per-op request/response dance, returns `WouldBlock` while a call is in flight,
//! and serves a synchronous `stat` from a learned-metadata cache (a real,
//! yieldable `stat_as` confirms terminal metadata). The host driver only ever
//! returns bytes to the guest — never a host object; a driver that is absent or
//! denies surfaces as an ordinary filesystem error.
//!
//! The transport is `HostCallSource` (the same poll/body machinery the host
//! control channel and `netfs` use). Dedup is by `CallerId`: a cooperative guest runs one syscall at a
//! time, so at most one call per caller is ever in flight — which is what makes the
//! re-issue on a yield-retry idempotent (the driver performs a mutation exactly
//! once, when the host runs the handler; the caller's re-poll only drains the
//! answer). Because the host call is asynchronous (a `Drop`-time write cannot
//! yield), a committed write is parked in `pending_commits` and drained
//! opportunistically — on the next op against the same mount and once per
//! `mc_tick` via the mount registry (see `drain_all`). An in-flight call holds a
//! host handle and counts toward `inflight_egress`, so a snapshot correctly refuses
//! while any read or commit is mid-flight (exactly like `netfs`).

use alloc::boxed::Box;
use alloc::collections::BTreeMap;
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::{RefCell, UnsafeCell};

use crate::wasm::abi::{
    MOUNT_OP_MKDIR, MOUNT_OP_OPEN, MOUNT_OP_READDIR, MOUNT_OP_RENAME, MOUNT_OP_STAT,
    MOUNT_OP_UNLINK, MOUNT_OP_WRITE,
};

use crate::fs::proxy;
use crate::host_call::{HostCallRead, HostCallSource};
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, OpenFlags, Result,
    SYSTEM_CALLER, SeekFrom,
};
use crate::wasm::abi::fs_result_from_errno;

// ---------------------------------------------------------------------------
// Wire codec (kernel → host driver). The request is
// `<mount_path>\0[op:u32][path_len:u32][path][arg_len:u32][arg][data…]`; the
// leading `<name>\0` matches the host-call router's `name\0args` split (the name
// is the absolute mount path, which never contains a NUL). The response is
// `[status:i32][payload…]` (abi MOUNT_OP_* block).
// ---------------------------------------------------------------------------

fn encode_request(driver: &str, op: u32, path: &str, arg: &str, data: &[u8]) -> Vec<u8> {
    let mut blob = Vec::with_capacity(driver.len() + 1 + 12 + path.len() + arg.len() + data.len());
    blob.extend_from_slice(driver.as_bytes());
    blob.push(0);
    blob.extend_from_slice(&op.to_le_bytes());
    blob.extend_from_slice(&(path.len() as u32).to_le_bytes());
    blob.extend_from_slice(path.as_bytes());
    blob.extend_from_slice(&(arg.len() as u32).to_le_bytes());
    blob.extend_from_slice(arg.as_bytes());
    blob.extend_from_slice(data);
    blob
}

fn decode_response(body: &[u8]) -> Result<(i32, Vec<u8>)> {
    if body.len() < 4 {
        return Err(FsError::IoError);
    }
    let status = i32::from_le_bytes([body[0], body[1], body[2], body[3]]);
    Ok((status, body[4..].to_vec()))
}

// ---------------------------------------------------------------------------
// The channel: in-flight calls + learned metadata, shared between the MountFs
// (mounted in the namespace) and its writable handles (which park commits).
// ---------------------------------------------------------------------------

/// How many `drain_all` passes an in-flight call may go untouched before it is
/// reclaimed as abandoned. A call being actively re-polled (a guest yield-retry,
/// or the host's ctl EAGAIN-retry) resets its age every `request`, so only a call
/// nobody is draining any more ages out. This is the backstop that keeps an
/// abandoned `SYSTEM_CALLER` (control-channel) call — which has no owning task to
/// die and trigger eviction — from pinning `inflight_egress` (and thus blocking
/// every future snapshot) forever.
const STALE_INFLIGHT_PASSES: u32 = 256;

/// One in-flight host call for a caller, plus the body accumulated across the
/// re-polls of a yielding op.
struct InflightCall {
    op: u32,
    path: String,
    arg: String,
    data_fingerprint: u64,
    source: HostCallSource,
    body: Vec<u8>,
    /// `drain_all` passes since this call was last touched by `request` (the
    /// abandonment backstop above).
    age: u32,
}

fn request_data_fingerprint(data: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for &b in data {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// A write committed at `Drop` but not yet acknowledged by the host driver. Held
/// until drained (so the host handle — and its egress count — lives until the
/// write lands).
struct PendingCommit {
    source: HostCallSource,
}

pub struct MountChannel {
    /// The host-call routing key — the absolute mount path (`/mnt/data`).
    driver: String,
    /// In-flight calls keyed by caller, so a yield-retry collects the SAME call.
    inflight: BTreeMap<CallerId, InflightCall>,
    /// Metadata learned from driver answers (the synchronous-`stat` substrate).
    meta: BTreeMap<String, Metadata>,
    /// Writes awaiting host acknowledgement.
    pending_commits: Vec<PendingCommit>,
}

impl MountChannel {
    fn new(driver: &str) -> Rc<RefCell<MountChannel>> {
        let mut meta = BTreeMap::new();
        meta.insert(String::from("/"), Metadata::dir());
        Rc::new(RefCell::new(MountChannel {
            driver: String::from(driver),
            inflight: BTreeMap::new(),
            meta,
            pending_commits: Vec::new(),
        }))
    }

    /// Drive parked write-commits forward; drop each once the host acknowledges
    /// (EOF) or fails. Best-effort: a `Drop`-time write cannot report an error, so
    /// a failed commit is dropped like a write error on `close` (the read-only and
    /// no-write-capability cases are rejected earlier — see the mount setup).
    fn drain_commits(&mut self) {
        let mut scratch = [0u8; 256];
        self.pending_commits.retain_mut(|c| {
            loop {
                match c.source.read_into(&mut scratch) {
                    HostCallRead::Pending => break true,
                    HostCallRead::Got(_) => continue,
                    HostCallRead::Eof | HostCallRead::Failed => break false,
                }
            }
        });
    }

    /// Reclaim stranded in-flight calls so their host handles (and the
    /// `inflight_egress` they pin, which blocks every future snapshot) don't leak.
    ///
    /// Two distinct policies, because the two caller kinds strand differently:
    /// - A **guest** call (`caller != SYSTEM_CALLER`) is reclaimed exactly when its
    ///   task is gone. A live task that yielded on `WouldBlock` is re-stepped every
    ///   round and re-polls (so it never needs aging); a *stopped* task will resume
    ///   and re-poll the SAME call, so it must NOT be aged out (that would restart
    ///   the driver op — a double-execute). Dead-task eviction is both sufficient
    ///   and necessary here.
    /// - The **control channel** (`SYSTEM_CALLER`) has no task to die, so it's the
    ///   one caller that can strand an abandoned call (the host's ctl retry gave up
    ///   / a driver hung). It ages by one pass per `drain_all`; a call nobody has
    ///   re-polled for [`STALE_INFLIGHT_PASSES`] is reclaimed. An actively-retried
    ///   ctl call resets its age in [`MountFs::request`], so it never ages out while
    ///   in progress.
    fn evict_stale_inflight(&mut self, is_alive: &impl Fn(CallerId) -> bool) {
        self.inflight.retain(|&caller, call| {
            if caller == SYSTEM_CALLER {
                call.age = call.age.saturating_add(1);
                call.age <= STALE_INFLIGHT_PASSES
            } else {
                is_alive(caller)
            }
        });
    }
}

// ---------------------------------------------------------------------------
// The mount registry: every live MountChannel, so `mc_tick` can drain parked
// commits and reclaim dead in-flight calls once per tick. Single-threaded
// cooperative discipline (the same UnsafeCell+Sync pattern as the kernel's other
// statics); captured by a snapshot along with the rest of linear memory.
// ---------------------------------------------------------------------------

struct MountRegistry(UnsafeCell<Vec<Rc<RefCell<MountChannel>>>>);
unsafe impl Sync for MountRegistry {}
impl MountRegistry {
    const fn new() -> Self {
        MountRegistry(UnsafeCell::new(Vec::new()))
    }
    #[allow(clippy::mut_from_ref)]
    unsafe fn get(&self) -> &mut Vec<Rc<RefCell<MountChannel>>> {
        unsafe { &mut *self.0.get() }
    }
}
static MOUNT_REGISTRY: MountRegistry = MountRegistry::new();

/// Per-tick maintenance for every mount: drain parked write-commits and reclaim
/// in-flight calls left by dead callers. A channel is forgotten once nothing else
/// references it (the mount was unmounted, so the namespace dropped its `Rc`) and
/// it has no pending commits. Called from `mc_tick` after the ready round.
pub fn drain_all(is_caller_alive: impl Fn(CallerId) -> bool) {
    let reg = unsafe { MOUNT_REGISTRY.get() };
    reg.retain(|ch| {
        let still_pending = {
            let mut c = ch.borrow_mut();
            c.evict_stale_inflight(&is_caller_alive);
            c.drain_commits();
            !c.pending_commits.is_empty()
        };
        // Keep while still mounted (another `Rc` holds it) or a commit is in flight.
        Rc::strong_count(ch) > 1 || still_pending
    });
}

/// Total parked (not-yet-acknowledged) write-commits across every mount. The host
/// uses this — NOT the global `inflight_egress` — to know when a mount write is
/// durable, so a write's durability isn't coupled to unrelated egress (an open
/// WebSocket, a concurrent HTTP fetch) that would otherwise keep egress non-zero.
pub fn pending_commit_count() -> usize {
    let reg = unsafe { MOUNT_REGISTRY.get() };
    reg.iter().map(|ch| ch.borrow().pending_commits.len()).sum()
}

// ---------------------------------------------------------------------------
// MountFs
// ---------------------------------------------------------------------------

pub struct MountFs {
    channel: Rc<RefCell<MountChannel>>,
}

impl MountFs {
    /// Create a host-backed mount whose driver is reached under the host-call name
    /// `driver` (the absolute mount path). Registers the channel for per-tick
    /// commit draining.
    pub fn new(driver: &str) -> Self {
        let channel = MountChannel::new(driver);
        unsafe { MOUNT_REGISTRY.get().push(Rc::clone(&channel)) };
        MountFs { channel }
    }

    /// One host-call round trip for `(op, path, arg, data)` on behalf of `caller`.
    /// Returns the decoded `(status, payload)` once the host answers, or
    /// `WouldBlock` while in flight (so the syscall yields and re-polls). The first
    /// touch starts a `HostCallSource` and records it; later touches drain it.
    fn request(
        &self,
        op: u32,
        path: &str,
        arg: &str,
        data: &[u8],
        caller: CallerId,
    ) -> Result<(i32, Vec<u8>)> {
        let mut ch = self.channel.borrow_mut();
        // Opportunistically flush parked writes before the next op.
        ch.drain_commits();

        // A different in-flight op for this caller means the previous one was
        // abandoned (e.g. a ctl retry gave up); reclaim it before starting fresh.
        let data_fingerprint = request_data_fingerprint(data);
        if let Some(call) = ch.inflight.get(&caller) {
            if call.op != op
                || call.path != path
                || call.arg != arg
                || call.data_fingerprint != data_fingerprint
            {
                ch.inflight.remove(&caller);
            }
        }
        if !ch.inflight.contains_key(&caller) {
            let blob = encode_request(&ch.driver, op, path, arg, data);
            // `Denied` = no driver registered under this name → PermissionDenied,
            // an ordinary fs error.
            let source = HostCallSource::start(&blob).map_err(|_| FsError::PermissionDenied)?;
            ch.inflight.insert(
                caller,
                InflightCall {
                    op,
                    path: String::from(path),
                    arg: String::from(arg),
                    data_fingerprint,
                    source,
                    body: Vec::new(),
                    age: 0,
                },
            );
        }

        // Drain the call without holding a borrow across the map mutation below.
        enum Outcome {
            Pending,
            Done,
            Failed,
        }
        let outcome = {
            let call = ch.inflight.get_mut(&caller).expect("inflight just ensured");
            // Touching the call resets its abandonment age (it's being driven).
            call.age = 0;
            let mut tmp = [0u8; 4096];
            loop {
                match call.source.read_into(&mut tmp) {
                    HostCallRead::Pending => break Outcome::Pending,
                    HostCallRead::Got(n) => call.body.extend_from_slice(&tmp[..n]),
                    HostCallRead::Eof => break Outcome::Done,
                    HostCallRead::Failed => break Outcome::Failed,
                }
            }
        };
        match outcome {
            Outcome::Pending => Err(FsError::WouldBlock),
            Outcome::Done => {
                let call = ch.inflight.remove(&caller).expect("present");
                decode_response(&call.body)
            }
            Outcome::Failed => {
                ch.inflight.remove(&caller);
                Err(FsError::IoError)
            }
        }
    }

    fn remember_meta(&self, path: &str, m: Metadata) {
        proxy::remember_meta(&mut self.channel.borrow_mut().meta, path, m);
    }
    fn forget_path(&self, path: &str) {
        proxy::forget_path(&mut self.channel.borrow_mut().meta, path);
    }

    /// Decode `status`; on `NotFound` forget any cached metadata for `path`.
    fn check_status(&self, status: i32, path: &str) -> Result<()> {
        if let Err(e) = fs_result_from_errno(status) {
            if e == FsError::NotFound {
                self.forget_path(path);
            }
            return Err(e);
        }
        Ok(())
    }
}

impl FileSystem for MountFs {
    fn open(
        &mut self,
        path: &KPath,
        flags: OpenFlags,
        caller: CallerId,
    ) -> Result<Box<dyn FileHandle>> {
        let writes = flags.write || flags.create || flags.truncate || flags.append;
        if writes {
            // A write-intent open buffers locally and commits on Drop. Truncate
            // starts empty; otherwise we OPEN to load existing bytes so append and
            // read-modify-write are correct.
            let (initial, existed) = if flags.truncate {
                let (status, body) = self.request(MOUNT_OP_STAT, path.as_str(), "", &[], caller)?;
                match fs_result_from_errno(status) {
                    Ok(()) => {
                        let meta = proxy::parse_metadata(&body)?;
                        if meta.node_type == crate::vfs::traits::NodeType::Dir {
                            return Err(FsError::IsDir);
                        }
                        self.remember_meta(path.as_str(), meta);
                        (Vec::new(), true)
                    }
                    Err(FsError::NotFound) if flags.create => {
                        self.forget_path(path.as_str());
                        (Vec::new(), false)
                    }
                    Err(e) => {
                        if e == FsError::NotFound {
                            self.forget_path(path.as_str());
                        }
                        return Err(e);
                    }
                }
            } else {
                let (status, body) = self.request(MOUNT_OP_OPEN, path.as_str(), "", &[], caller)?;
                match fs_result_from_errno(status) {
                    Ok(()) => {
                        self.remember_meta(path.as_str(), Metadata::file(body.len() as u64));
                        (body, true)
                    }
                    Err(FsError::NotFound) if flags.create => {
                        self.forget_path(path.as_str());
                        (Vec::new(), false)
                    }
                    Err(e) => {
                        if e == FsError::NotFound {
                            self.forget_path(path.as_str());
                        }
                        return Err(e);
                    }
                }
            };
            let offset = if flags.append {
                initial.len() as u64
            } else {
                0
            };
            // Commit even an empty value for a fresh create/truncate (POSIX `>`
            // makes the file exist); a pure-append of existing content does not
            // rewrite until something is written (matches persistfs).
            let dirty = flags.truncate || (flags.create && !existed);
            return Ok(Box::new(MountFileHandle {
                channel: Rc::clone(&self.channel),
                path: String::from(path.as_str()),
                buf: initial,
                offset,
                dirty,
            }));
        }

        // Read open: fetch the whole file; reads drain it locally.
        let (status, body) = self.request(MOUNT_OP_OPEN, path.as_str(), "", &[], caller)?;
        self.check_status(status, path.as_str())?;
        self.remember_meta(path.as_str(), Metadata::file(body.len() as u64));
        Ok(Box::new(MountReadHandle {
            data: body,
            offset: 0,
        }))
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        // Synchronous metadata is only for path resolution and mode checks — it
        // must never yield. Cached driver-proven metadata wins; an unknown path is
        // a provisional searchable directory so nested keys (`/mnt/s3/p/object`)
        // can reach the terminal op that asks the driver for the real answer.
        if let Some(meta) = proxy::cached_meta(&self.channel.borrow().meta, path.as_str()) {
            return Ok(meta);
        }
        Ok(Metadata::dir())
    }

    fn stat_as(&self, path: &KPath, caller: CallerId) -> Result<Metadata> {
        let (status, body) = self.request(MOUNT_OP_STAT, path.as_str(), "", &[], caller)?;
        self.check_status(status, path.as_str())?;
        let meta = proxy::parse_metadata(&body)?;
        self.remember_meta(path.as_str(), meta.clone());
        Ok(meta)
    }

    fn readdir(&self, path: &KPath, caller: CallerId) -> Result<Vec<DirEntry>> {
        let (status, body) = self.request(MOUNT_OP_READDIR, path.as_str(), "", &[], caller)?;
        self.check_status(status, path.as_str())?;
        let parsed = proxy::parse_dirents(&body, path.as_str())?;
        let mut entries = Vec::new();
        {
            let mut ch = self.channel.borrow_mut();
            proxy::forget_children_of(&mut ch.meta, path.as_str());
            for (entry, child, meta) in parsed {
                proxy::remember_meta(&mut ch.meta, &child, meta);
                entries.push(entry);
            }
        }
        Ok(entries)
    }

    fn mkdir(&mut self, path: &KPath, caller: CallerId) -> Result<()> {
        let (status, _) = self.request(MOUNT_OP_MKDIR, path.as_str(), "", &[], caller)?;
        fs_result_from_errno(status)?;
        self.remember_meta(path.as_str(), Metadata::dir());
        Ok(())
    }

    fn unlink(&mut self, path: &KPath, caller: CallerId) -> Result<()> {
        let (status, _) = self.request(MOUNT_OP_UNLINK, path.as_str(), "", &[], caller)?;
        fs_result_from_errno(status)?;
        self.forget_path(path.as_str());
        Ok(())
    }

    fn rename(&mut self, from: &KPath, to: &KPath, caller: CallerId) -> Result<()> {
        let (status, _) = self.request(MOUNT_OP_RENAME, from.as_str(), to.as_str(), &[], caller)?;
        fs_result_from_errno(status)?;
        proxy::rename_path(
            &mut self.channel.borrow_mut().meta,
            from.as_str(),
            to.as_str(),
        );
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// File handles
// ---------------------------------------------------------------------------

/// A read handle over the content the driver returned at open time. Reads drain
/// the buffer locally — no further round trips.
struct MountReadHandle {
    data: Vec<u8>,
    offset: usize,
}

impl FileHandle for MountReadHandle {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        let start = self.offset.min(self.data.len());
        let n = (self.data.len() - start).min(buf.len());
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

/// A writable handle: the whole value is buffered; writes mutate the buffer and
/// the final value is committed to the driver on `Drop` (the `FileHandle` trait
/// has no `close`, so `Drop` is the flush hook — like persistfs). Because the
/// commit is an asynchronous host call, it is parked in the channel's
/// `pending_commits` rather than completed inline.
///
/// Semantics are deliberate **whole-value, last-writer-wins** (an object-store
/// PUT, not a byte-range write): each handle snapshots the file at its own open
/// and commits the whole buffer, so two writers to one path race and the last
/// commit wins. That matches `s3`/`hostDir` (replace the object); it is NOT POSIX
/// shared-write coherence.
struct MountFileHandle {
    channel: Rc<RefCell<MountChannel>>,
    path: String,
    buf: Vec<u8>,
    offset: u64,
    dirty: bool,
}

impl FileHandle for MountFileHandle {
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

impl Drop for MountFileHandle {
    fn drop(&mut self) {
        if !self.dirty {
            return;
        }
        let mut ch = self.channel.borrow_mut();
        let blob = encode_request(&ch.driver, MOUNT_OP_WRITE, &self.path, "", &self.buf);
        if let Ok(source) = HostCallSource::start(&blob) {
            ch.pending_commits.push(PendingCommit { source });
        }
        // The committed size differs from any cached metadata for this path.
        proxy::forget_path(&mut ch.meta, &self.path);
    }
}
