//! netfs — the network as a file tree. Mounted at `/net`. Opening a path IS
//! opening a connection; `read`/`write`/`poll` drive it. This is the Plan-9
//! "everything is a file" treatment of the network, reframing the existing
//! host-terminated `mc_http_*`/`mc_ws_*` bridge — it is NOT a raw TCP stack (the
//! same kernel runs in a browser that cannot open raw sockets).
//!
//!   /net/ws/<host>/<path…>     → ws://<host>/<path>    (bidirectional)
//!   /net/wss/<host>/<path…>    → wss://<host>/<path>   (bidirectional)
//!   /net/http/<host>/<path…>   → http://<host>/<path>  GET (readable body)
//!   /net/https/<host>/<path…>  → https://<host>/<path> GET (readable body)
//!
//! The agent only ever names a path and gets a kernel fd — never the host handle.
//! The NET capability is checked via the caller; denial (no `CAP_NET`, or the
//! host refusing) surfaces as `PermissionDenied`, exactly like any filesystem
//! error. Structured POST/headers HTTP stays on `mc_sys_http_request` (the
//! hybrid path).

use alloc::boxed::Box;
use alloc::format;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;
use core::ptr::NonNull;

use crate::net::{HttpReq, NetError, NetFileHandle, WsConn};
use crate::task::{CAP_NET, Scheduler};
use crate::vfs::traits::{
    CallerId, DirEntry, FileHandle, FileSystem, FsError, KPath, Metadata, NodeType, OpenFlags,
    Result,
};

const SCHEMES: &[&str] = &["ws", "wss", "http", "https"];

pub struct NetFs {
    scheduler: NonNull<Scheduler>,
}

// The scheduler lives in the kernel's static SystemState, pinned for the
// instance lifetime; cooperative mode is single-threaded.
unsafe impl Send for NetFs {}
unsafe impl Sync for NetFs {}

impl NetFs {
    /// # Safety
    /// `scheduler` MUST outlive this `NetFs` (it is pinned in SystemState).
    pub unsafe fn new(scheduler: *const Scheduler) -> Self {
        NetFs {
            scheduler: NonNull::new(scheduler as *mut Scheduler).expect("scheduler non-null"),
        }
    }

    fn scheduler(&self) -> &Scheduler {
        unsafe { self.scheduler.as_ref() }
    }

    /// Does `caller` hold the NET capability (the kernel policy gate)?
    fn caller_has_net(&self, caller: CallerId) -> bool {
        self.scheduler()
            .get_task(caller)
            .map(|t| t.caps.has(CAP_NET))
            .unwrap_or(false)
    }

    /// Split a netfs-relative path `/scheme/host/rest…` into `(scheme, rest)`.
    fn parse<'a>(path: &'a str) -> Option<(&'a str, &'a str)> {
        let p = path.trim_start_matches('/');
        let mut it = p.splitn(2, '/');
        let scheme = it.next()?;
        if !SCHEMES.contains(&scheme) {
            return None;
        }
        let rest = it.next()?; // host[/path…]
        if rest.is_empty() {
            return None;
        }
        Some((scheme, rest))
    }
}

impl FileSystem for NetFs {
    fn open(
        &mut self,
        path: &KPath,
        _flags: OpenFlags,
        caller: CallerId,
    ) -> Result<Box<dyn FileHandle>> {
        // Capability gate: denial reads as an ordinary fs error.
        if !self.caller_has_net(caller) {
            return Err(FsError::PermissionDenied);
        }
        let (scheme, rest) = Self::parse(path.as_str()).ok_or(FsError::NotFound)?;
        let writes = _flags.write || _flags.create || _flags.truncate || _flags.append;
        if matches!(scheme, "http" | "https") && writes {
            return Err(FsError::PermissionDenied);
        }
        let url = format!("{}://{}", scheme, rest);
        match scheme {
            "ws" | "wss" => match WsConn::connect(&url) {
                Ok(conn) => Ok(Box::new(NetFileHandle::websocket(conn))),
                Err(NetError::Denied) => Err(FsError::PermissionDenied),
                Err(NetError::Failed) => Err(FsError::IoError),
            },
            _ /* http | https */ => {
                let blob = format!("GET {}\n\n", url);
                match HttpReq::start(blob.as_bytes()) {
                    Ok(req) => Ok(Box::new(NetFileHandle::http_get(req))),
                    Err(NetError::Denied) => Err(FsError::PermissionDenied),
                    Err(NetError::Failed) => Err(FsError::IoError),
                }
            }
        }
    }

    fn stat(&self, path: &KPath) -> Result<Metadata> {
        let rel = path.as_str().trim_start_matches('/');
        if rel.is_empty() || SCHEMES.contains(&rel) {
            // `/net` and `/net/<scheme>` are directories.
            return Ok(Metadata::dir());
        }
        // A `/net/<scheme>/<host>/…` path is connectable when opened, but its
        // prefixes must also be searchable so deeper URL paths like
        // `/net/wss/example.com/raw` can be canonicalized. Report them as
        // directory-like, non-enumerable connector nodes; `open` below is still
        // the operation that creates the actual network stream.
        if Self::parse(path.as_str()).is_some() {
            return Ok(Metadata::dir());
        }
        Err(FsError::NotFound)
    }

    fn readdir(&self, path: &KPath, _caller: CallerId) -> Result<Vec<DirEntry>> {
        let rel = path.as_str().trim_start_matches('/');
        if rel.is_empty() {
            // `/net` lists the supported schemes.
            return Ok(SCHEMES
                .iter()
                .map(|s| DirEntry {
                    name: String::from(*s),
                    node_type: NodeType::Dir,
                })
                .collect());
        }
        if SCHEMES.contains(&rel) {
            // netfs MUST NOT enumerate reachable hosts — there is no
            // host-network state to leak.
            return Ok(vec![]);
        }
        if Self::parse(path.as_str()).is_some() {
            // URL prefixes are searchable but not enumerable.
            return Ok(vec![]);
        }
        Err(FsError::NotFound)
    }

    fn mkdir(&mut self, _path: &KPath, _caller: CallerId) -> Result<()> {
        Err(FsError::PermissionDenied)
    }
    fn unlink(&mut self, _path: &KPath, _caller: CallerId) -> Result<()> {
        Err(FsError::PermissionDenied)
    }
    fn rename(&mut self, _from: &KPath, _to: &KPath, _caller: CallerId) -> Result<()> {
        Err(FsError::PermissionDenied)
    }
}
