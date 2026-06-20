//! Kernel-side wrappers over the host network capability imports.
//!
//! Containment: the raw `i32` handle the host returns is a transport contract
//! between kernel and host. It MUST NOT reach the agent. These types own the
//! handle, drive the poll/read/close calls, bounds-check every buffer that
//! crosses the bridge, and close the handle on `Drop`. The agent only ever
//! observes a builtin's stdout / stderr / exit code — it never sees the
//! integer, so a kernel network operation is indistinguishable from any other
//! command.
//!
//! The host performs the actual HTTP/WebSocket work, including TLS, on the
//! kernel's behalf through the bridge capability. The current agent surface is
//! command-level (`fetch`/`wscat`); the fd-level `/net` surface is deferred. The
//! kernel never speaks TLS or sockets itself, which keeps it `no_std` and
//! identical across the wasmtime and (future) browser hosts.

#![allow(dead_code)]

use alloc::vec::Vec;
use core::cell::RefCell;
use core::sync::atomic::{AtomicI32, Ordering};

use crate::bridge;
use crate::vfs::traits::{FileHandle, FsError, Metadata, Result as VfsResult, SeekFrom};

/// Largest response head (status line + headers) we will accept in one poll.
const HEAD_BUF: usize = 16 * 1024;

/// Count of open host-egress handles (HTTP requests + WebSocket connections)
/// across all guests. Each open connection owns a raw host handle that is
/// meaningless after a snapshot is restored into a fresh host, so a snapshot
/// must be taken at a no-egress-in-flight boundary. The host reads this via the
/// `mc_inflight_egress` export and refuses to snapshot while it is non-zero
/// (eviction correctness). Relaxed ordering suffices: the kernel is
/// single-threaded / BKL-serialized.
static INFLIGHT_EGRESS: AtomicI32 = AtomicI32::new(0);

/// Open host-egress handle count (read by the host before a snapshot).
pub fn inflight_egress() -> i32 {
    INFLIGHT_EGRESS.load(Ordering::Relaxed)
}

pub(crate) fn egress_inc() {
    INFLIGHT_EGRESS.fetch_add(1, Ordering::Relaxed);
}

pub(crate) fn egress_dec() {
    INFLIGHT_EGRESS.fetch_sub(1, Ordering::Relaxed);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetError {
    /// The host refused the capability (`-1` at request/connect time).
    Denied,
    /// A transport failure after the request started (DNS / connect / TLS /
    /// read error).
    Failed,
}

/// Result of polling an in-flight HTTP request for its response head.
pub enum HttpPoll {
    /// Not ready yet — the caller should yield and retry next tick.
    Pending,
    /// Head received: the raw `"<status> <reason>\r\n<headers>\r\n\r\n"` bytes.
    Head(Vec<u8>),
    /// The request failed at the transport level.
    Failed,
}

/// An in-flight HTTP request. Owns the host handle; closes it on `Drop`.
pub struct HttpReq {
    handle: i32,
}

impl HttpReq {
    /// Begin a request from a serialized blob (`METHOD URL\n` + header lines
    /// + blank line + body). Returns `Denied` if the host refused.
    pub fn start(req: &[u8]) -> Result<HttpReq, NetError> {
        let h = unsafe { bridge::mc_http_request(req.as_ptr(), req.len()) };
        if h < 0 {
            Err(NetError::Denied)
        } else {
            egress_inc();
            Ok(HttpReq { handle: h })
        }
    }

    /// Poll for the response head. The host returns `0` until the response is
    /// ready, so this is non-consuming until then — it composes with the
    /// cooperative scheduler (poll once per tick).
    pub fn poll(&mut self) -> HttpPoll {
        let mut buf = [0u8; HEAD_BUF];
        let n = unsafe { bridge::mc_http_response_poll(self.handle, buf.as_mut_ptr(), buf.len()) };
        if n < 0 {
            HttpPoll::Failed
        } else if n == 0 {
            HttpPoll::Pending
        } else {
            let len = (n as usize).min(buf.len());
            HttpPoll::Head(buf[..len].to_vec())
        }
    }

    /// Read up to `out.len()` body bytes. `Ok(0)` is EOF.
    pub fn read_body(&mut self, out: &mut [u8]) -> Result<usize, NetError> {
        let n = unsafe { bridge::mc_http_response_body(self.handle, out.as_mut_ptr(), out.len()) };
        if n < 0 {
            Err(NetError::Failed)
        } else {
            Ok((n as usize).min(out.len()))
        }
    }
}

impl Drop for HttpReq {
    fn drop(&mut self) {
        unsafe { bridge::mc_http_request_close(self.handle) };
        egress_dec();
    }
}

/// An open WebSocket connection. Owns the host handle; closes it on `Drop`.
pub struct WsConn {
    handle: i32,
}

impl WsConn {
    /// Open a WebSocket to `url` (`ws://` or `wss://`). The host performs the
    /// handshake (and TLS for `wss`). Returns `Denied` if the host refused.
    pub fn connect(url: &str) -> Result<WsConn, NetError> {
        let h = unsafe { bridge::mc_ws_connect(url.as_ptr(), url.len()) };
        if h < 0 {
            Err(NetError::Denied)
        } else {
            egress_inc();
            Ok(WsConn { handle: h })
        }
    }

    /// Send one message. Returns the number of bytes accepted.
    pub fn send(&mut self, data: &[u8]) -> Result<usize, NetError> {
        let n = unsafe { bridge::mc_ws_send(self.handle, data.as_ptr(), data.len()) };
        if n < 0 {
            Err(NetError::Failed)
        } else {
            Ok((n as usize).min(data.len()))
        }
    }

    /// Try to receive a message. `Ok(Some(n))` on data, `Ok(None)` when
    /// nothing is pending (caller should yield), `Err(Failed)` when the
    /// connection is closed or errored.
    pub fn recv(&mut self, out: &mut [u8]) -> Result<Option<usize>, NetError> {
        let n = unsafe { bridge::mc_ws_recv(self.handle, out.as_mut_ptr(), out.len()) };
        if n < 0 {
            Err(NetError::Failed)
        } else if n == 0 {
            Ok(None)
        } else {
            Ok(Some((n as usize).min(out.len())))
        }
    }
}

impl Drop for WsConn {
    fn drop(&mut self) {
        unsafe { bridge::mc_ws_close(self.handle) };
        egress_dec();
    }
}

// ---------------------------------------------------------------------------
// netfs connection-as-a-file
//
// `NetFileHandle` presents a host connection as an ordinary VFS file: a
// streaming HTTP GET body (read-only) or a bidirectional WebSocket. It relies
// on the `FsError::WouldBlock` + `FileHandle::poll_readable` mechanism so the
// connection can live behind a normal `GuestFd::File` and yield while the host
// fetches. (The guest egress syscalls use the parallel `SharedNet`/`SharedWs`
// wrappers in `wasm/mod.rs`; the logic is intentionally small and
// self-contained here so the file-tree surface and the syscall surface can
// evolve independently.)
// ---------------------------------------------------------------------------

/// Largest single WebSocket message buffered per `recv`.
const NET_MSG_BUF: usize = 16 * 1024;

enum HttpPhase {
    Polling,
    Body,
    Eof,
    Failed,
}

enum Conn {
    Http {
        req: HttpReq,
        phase: HttpPhase,
    },
    Ws {
        conn: WsConn,
        pending: Vec<u8>,
        poff: usize,
        failed: bool,
    },
}

/// A network connection exposed as a VFS file handle.
pub struct NetFileHandle {
    conn: RefCell<Conn>,
}

impl NetFileHandle {
    /// A readable streaming HTTP GET body.
    pub fn http_get(req: HttpReq) -> Self {
        NetFileHandle {
            conn: RefCell::new(Conn::Http {
                req,
                phase: HttpPhase::Polling,
            }),
        }
    }

    /// A bidirectional WebSocket (`read` = recv a message, `write` = send one).
    pub fn websocket(conn: WsConn) -> Self {
        NetFileHandle {
            conn: RefCell::new(Conn::Ws {
                conn,
                pending: Vec::new(),
                poff: 0,
                failed: false,
            }),
        }
    }
}

/// Drive an HTTP body read; `WouldBlock` while the head is still in flight.
fn http_read(req: &mut HttpReq, phase: &mut HttpPhase, buf: &mut [u8]) -> VfsResult<usize> {
    loop {
        match phase {
            HttpPhase::Polling => match req.poll() {
                HttpPoll::Pending => return Err(FsError::WouldBlock),
                HttpPoll::Head(_) => *phase = HttpPhase::Body,
                HttpPoll::Failed => {
                    *phase = HttpPhase::Failed;
                    return Err(FsError::IoError);
                }
            },
            HttpPhase::Body => {
                return match req.read_body(buf) {
                    Ok(0) => {
                        *phase = HttpPhase::Eof;
                        Ok(0)
                    }
                    Ok(n) => Ok(n),
                    Err(_) => {
                        *phase = HttpPhase::Failed;
                        Err(FsError::IoError)
                    }
                };
            }
            HttpPhase::Eof => return Ok(0),
            HttpPhase::Failed => return Err(FsError::IoError),
        }
    }
}

/// Non-destructive readiness for an HTTP body (advance past the head only).
fn http_ready(req: &mut HttpReq, phase: &mut HttpPhase) -> bool {
    if let HttpPhase::Polling = phase {
        match req.poll() {
            HttpPoll::Pending => return false,
            HttpPoll::Head(_) => *phase = HttpPhase::Body,
            HttpPoll::Failed => *phase = HttpPhase::Failed,
        }
    }
    true
}

/// Receive into `pending` if empty; drain into `buf`. `WouldBlock` if no message
/// is ready; `Ok(0)` (EOF) once the connection has closed/errored and drained.
fn ws_read(
    conn: &mut WsConn,
    pending: &mut Vec<u8>,
    poff: &mut usize,
    failed: &mut bool,
    buf: &mut [u8],
) -> VfsResult<usize> {
    if *poff >= pending.len() && !*failed {
        let mut tmp = [0u8; NET_MSG_BUF];
        match conn.recv(&mut tmp) {
            Ok(Some(n)) => {
                *pending = tmp[..n].to_vec();
                *poff = 0;
            }
            Ok(None) => return Err(FsError::WouldBlock),
            Err(_) => {
                *failed = true;
                return Ok(0);
            }
        }
    }
    if *poff < pending.len() {
        let avail = pending.len() - *poff;
        let n = avail.min(buf.len());
        buf[..n].copy_from_slice(&pending[*poff..*poff + n]);
        *poff += n;
        Ok(n)
    } else {
        Ok(0) // failed + drained → EOF
    }
}

/// Non-destructive WebSocket readiness (buffer a message without consuming it).
fn ws_ready(conn: &mut WsConn, pending: &mut Vec<u8>, poff: &mut usize, failed: &mut bool) -> bool {
    if *poff < pending.len() || *failed {
        return true;
    }
    let mut tmp = [0u8; NET_MSG_BUF];
    match conn.recv(&mut tmp) {
        Ok(Some(n)) => {
            *pending = tmp[..n].to_vec();
            *poff = 0;
            true
        }
        Ok(None) => false,
        Err(_) => {
            *failed = true;
            true
        }
    }
}

impl FileHandle for NetFileHandle {
    fn read(&mut self, buf: &mut [u8]) -> VfsResult<usize> {
        match &mut *self.conn.borrow_mut() {
            Conn::Http { req, phase } => http_read(req, phase, buf),
            Conn::Ws {
                conn,
                pending,
                poff,
                failed,
            } => ws_read(conn, pending, poff, failed, buf),
        }
    }

    fn write(&mut self, buf: &[u8]) -> VfsResult<usize> {
        match &mut *self.conn.borrow_mut() {
            // The HTTP response body is read-only.
            Conn::Http { .. } => Err(FsError::BadFileDescriptor),
            Conn::Ws { conn, .. } => conn
                .send(buf)
                .map(|_| buf.len())
                .map_err(|_| FsError::IoError),
        }
    }

    fn seek(&mut self, _pos: SeekFrom) -> VfsResult<u64> {
        Err(FsError::NotImplemented)
    }

    fn stat(&self) -> VfsResult<Metadata> {
        Ok(Metadata::file(0))
    }

    fn poll_readable(&self) -> bool {
        match &mut *self.conn.borrow_mut() {
            Conn::Http { req, phase } => http_ready(req, phase),
            Conn::Ws {
                conn,
                pending,
                poff,
                failed,
            } => ws_ready(conn, pending, poff, failed),
        }
    }
    // poll_writable defaults to true: a ws send is buffered host-side; an HTTP
    // body fd is not writable but never blocks (writes return EBADF).
}
