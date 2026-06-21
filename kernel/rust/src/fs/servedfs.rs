//! Guest-served file servers — the deepest Plan 9 idea: a filesystem served by a
//! USER-SPACE guest. A guest calls `mc_sys_serve(path)` to become the server for
//! a subtree; the kernel mounts a `ServedFs` there. When another task opens a
//! path under the mount, the op is turned into a request the server guest
//! receives (`mc_sys_serve_recv`), handles, and answers (`mc_sys_serve_respond`).
//!
//! The cooperative dance is single-threaded: the requester's op enqueues a
//! request and returns `WouldBlock`, so the syscall yields. The server guest is
//! then scheduled, `recv`s the request, and `respond`s. On the requester's next
//! tick the op finds the response and completes. All state lives in linear
//! memory. The server can only ever return bytes to the requester — never a host
//! object.
//!
//! The same dance serves the whole terminal VFS surface, not just `open`: each
//! request carries an `op` (one of `abi::SERVE_OP_*`) so the server learns which
//! operation to perform. `open` returns the file content (then local `read`s
//! drain it — no per-read round trip); `stat` returns a 44-byte metadata record;
//! `readdir` returns typed directory entries; `mkdir`/`unlink`/`rename` return
//! status only. Namespace path resolution remains synchronous: unknown served
//! prefixes are treated as provisional searchable directories there, while
//! user-visible terminal `stat`/`lstat`/`chdir` use `stat_as` and may yield to
//! the server. Dedup is by caller, which makes a yield-retry idempotent (a
//! mutation is applied once, by the server, when it handles the recv).

use alloc::boxed::Box;
use alloc::collections::{BTreeMap, VecDeque};
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::RefCell;

use crate::wasm::abi::{
    SERVE_OP_MKDIR, SERVE_OP_OPEN, SERVE_OP_READDIR, SERVE_OP_RENAME, SERVE_OP_STAT,
    SERVE_OP_UNLINK,
};

use crate::fs::proxy;
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, OpenFlags, Result,
    SeekFrom,
};
use crate::wasm::abi::fs_result_from_errno;

/// A pending request routed to the server guest. `op` is one of `abi::SERVE_OP_*`;
/// `arg` is the secondary path (the `rename` target) and is empty for every
/// other op.
pub struct ServeRequest {
    pub id: u32,
    pub caller: CallerId,
    pub op: u32,
    pub path: String,
    pub arg: String,
}

/// The server guest's answer for one request. `status` is a WASI-style errno
/// (`0` = ok), decoded by [`fs_result_from_errno`]; `data` is op-specific
/// payload (file content for OPEN, stat record for STAT, typed names for
/// READDIR, empty for the mutating ops).
struct ServeResponse {
    status: i32,
    data: Vec<u8>,
}

/// The rendezvous between a `ServedFs` (mounted in the namespace) and the server
/// guest (which holds the same `Rc`). Shared, interior-mutable, single-threaded.
pub struct ServeChannel {
    next_id: u32,
    /// Requests waiting for the server to `recv`.
    requests: VecDeque<ServeRequest>,
    /// Answered requests waiting for the requester to pick up, by request id.
    responses: BTreeMap<u32, ServeResponse>,
    /// The in-flight request id per requester (so a yielding `open` re-poll does
    /// not enqueue twice).
    inflight: BTreeMap<CallerId, u32>,
    /// Metadata the kernel has learned from server answers. The mount root is
    /// always a directory; unknown paths stay provisional for resolution and are
    /// confirmed by terminal STAT.
    meta: BTreeMap<String, Metadata>,
    /// Set once the server guest exits; pending/new requests then fail (`EIO`).
    closed: bool,
}

impl ServeChannel {
    pub fn new() -> Rc<RefCell<ServeChannel>> {
        let mut meta = BTreeMap::new();
        meta.insert(String::from("/"), Metadata::dir());
        Rc::new(RefCell::new(ServeChannel {
            next_id: 1,
            requests: VecDeque::new(),
            responses: BTreeMap::new(),
            inflight: BTreeMap::new(),
            meta,
            closed: false,
        }))
    }

    /// Server side: take the next request to handle, if any.
    pub fn take_request(&mut self) -> Option<ServeRequest> {
        self.requests.pop_front()
    }

    /// Server side: inspect the next request without consuming it. Used so a
    /// too-small server buffer cannot drop a request and strand the caller.
    pub fn peek_request(&self) -> Option<&ServeRequest> {
        self.requests.front()
    }

    /// Server side: record the answer for `req_id`.
    pub fn respond(&mut self, req_id: u32, status: i32, data: Vec<u8>) -> bool {
        if !self.inflight.values().any(|&id| id == req_id) {
            return false;
        }
        self.responses
            .insert(req_id, ServeResponse { status, data });
        true
    }

    /// Server side: the server guest has exited — fail everything pending.
    pub fn close(&mut self) {
        self.closed = true;
    }

    fn cached_meta(&self, path: &str) -> Option<Metadata> {
        proxy::cached_meta(&self.meta, path)
    }

    fn remember_meta(&mut self, path: &str, meta: Metadata) {
        proxy::remember_meta(&mut self.meta, path, meta);
    }

    fn forget_path(&mut self, path: &str) {
        proxy::forget_path(&mut self.meta, path);
    }

    fn rename_path(&mut self, from: &str, to: &str) {
        proxy::rename_path(&mut self.meta, from, to);
    }

    fn forget_children_of(&mut self, dir: &str) {
        proxy::forget_children_of(&mut self.meta, dir);
    }
}

/// A filesystem whose operations are answered by a server guest.
pub struct ServedFs {
    channel: Rc<RefCell<ServeChannel>>,
}

impl ServedFs {
    pub fn new(channel: Rc<RefCell<ServeChannel>>) -> Self {
        ServedFs { channel }
    }

    /// The cooperative request/response dance every served op shares. On a
    /// caller's first touch it enqueues a `(op, path, arg)` request
    /// for the server guest and returns `WouldBlock`, so the syscall yields; on a
    /// later tick, once the server has answered, it returns that response (whose
    /// `status` the caller decodes). Dedup is by `caller`: a cooperative guest
    /// runs one syscall at a time, so at most one request per caller is ever in
    /// flight — which is exactly what makes the re-issue on a yield-retry
    /// idempotent (the server performs a mutation once, when it handles the
    /// recv; the caller's re-poll only collects the answer). A `WouldBlock` after
    /// the server has exited becomes `IoError` so no caller parks forever.
    fn request(&self, op: u32, path: &str, arg: &str, caller: CallerId) -> Result<ServeResponse> {
        let mut ch = self.channel.borrow_mut();
        if let Some(&rid) = ch.inflight.get(&caller) {
            if let Some(resp) = ch.responses.remove(&rid) {
                ch.inflight.remove(&caller);
                return Ok(resp);
            }
            if ch.closed {
                ch.inflight.remove(&caller);
                return Err(FsError::IoError);
            }
            return Err(FsError::WouldBlock);
        }
        if ch.closed {
            return Err(FsError::IoError);
        }
        // First touch: enqueue a request for the server, then yield.
        let id = ch.next_id;
        ch.next_id = ch.next_id.wrapping_add(1).max(1);
        ch.requests.push_back(ServeRequest {
            id,
            caller,
            op,
            path: String::from(path),
            arg: String::from(arg),
        });
        ch.inflight.insert(caller, id);
        Err(FsError::WouldBlock)
    }
}

impl FileSystem for ServedFs {
    fn open(
        &mut self,
        caller: CallerId,
        path: &KPath,
        _flags: OpenFlags,
    ) -> Result<Box<dyn FileHandle>> {
        let resp = self.request(SERVE_OP_OPEN, path.as_str(), "", caller)?;
        if let Err(e) = fs_result_from_errno(resp.status) {
            if e == FsError::NotFound {
                self.channel.borrow_mut().forget_path(path.as_str());
            }
            return Err(e);
        }
        self.channel
            .borrow_mut()
            .remember_meta(path.as_str(), Metadata::file(resp.data.len() as u64));
        // The server delivers the whole file at open time; reads drain it
        // locally (no per-read round trip).
        Ok(Box::new(ServedFileHandle {
            data: resp.data,
            offset: 0,
        }))
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        // Synchronous metadata is only for namespace path resolution and mode
        // checks. It must never yield. Cached server-proven metadata wins; an
        // unknown served path is a provisional searchable directory so direct
        // nested remote keys (`/mnt/s3/prefix/object`) can reach the terminal
        // served operation that asks the server for the real answer.
        if let Some(meta) = self.channel.borrow().cached_meta(path.as_str()) {
            return Ok(meta);
        }
        Ok(Metadata::dir())
    }

    fn stat_as(&self, caller: CallerId, path: &KPath) -> Result<Metadata> {
        let resp = self.request(SERVE_OP_STAT, path.as_str(), "", caller)?;
        if let Err(e) = fs_result_from_errno(resp.status) {
            if e == FsError::NotFound {
                self.channel.borrow_mut().forget_path(path.as_str());
            }
            return Err(e);
        }
        let meta = proxy::parse_metadata(&resp.data)?;
        self.channel
            .borrow_mut()
            .remember_meta(path.as_str(), meta.clone());
        Ok(meta)
    }

    fn readdir(&self, caller: CallerId, path: &KPath) -> Result<Vec<DirEntry>> {
        let resp = self.request(SERVE_OP_READDIR, path.as_str(), "", caller)?;
        if let Err(e) = fs_result_from_errno(resp.status) {
            if e == FsError::NotFound {
                self.channel.borrow_mut().forget_path(path.as_str());
            }
            return Err(e);
        }
        let parsed = proxy::parse_dirents(&resp.data, path.as_str())?;
        let mut entries = Vec::new();
        {
            let mut ch = self.channel.borrow_mut();
            ch.forget_children_of(path.as_str());
            for (entry, child, meta) in parsed {
                ch.remember_meta(&child, meta);
                entries.push(entry);
            }
        }
        Ok(entries)
    }

    fn mkdir(&mut self, caller: CallerId, path: &KPath) -> Result<()> {
        let resp = self.request(SERVE_OP_MKDIR, path.as_str(), "", caller)?;
        fs_result_from_errno(resp.status)?;
        self.channel
            .borrow_mut()
            .remember_meta(path.as_str(), Metadata::dir());
        Ok(())
    }

    fn unlink(&mut self, caller: CallerId, path: &KPath) -> Result<()> {
        let resp = self.request(SERVE_OP_UNLINK, path.as_str(), "", caller)?;
        fs_result_from_errno(resp.status)?;
        self.channel.borrow_mut().forget_path(path.as_str());
        Ok(())
    }

    fn rename(&mut self, caller: CallerId, from: &KPath, to: &KPath) -> Result<()> {
        let resp = self.request(SERVE_OP_RENAME, from.as_str(), to.as_str(), caller)?;
        fs_result_from_errno(resp.status)?;
        self.channel
            .borrow_mut()
            .rename_path(from.as_str(), to.as_str());
        Ok(())
    }
}

/// A handle over the content the server returned at open time. Reads drain the
/// buffer locally — no further server round trips.
struct ServedFileHandle {
    data: Vec<u8>,
    offset: usize,
}

impl FileHandle for ServedFileHandle {
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
