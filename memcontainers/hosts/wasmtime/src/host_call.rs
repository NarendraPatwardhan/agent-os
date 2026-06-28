//! Host-call capability: the host side of `mc_sys_host_call`. The kernel hands
//! the host an opaque request blob (`name\0args`, from the tool broker); the host
//! routes it to a registered handler and streams back a result. Poll-based,
//! mirroring the net capability: `start` → handle, `poll` → readiness, `body` →
//! result bytes, `close`. Default-deny (A9): without an installed capability,
//! every call is refused, so host tools are unavailable to a VM unless the host
//! opts in.

use std::collections::HashMap;

/// The host-side host-call surface, gated like `NetCapability`.
pub trait HostCallCapability: Send + 'static {
    /// Start a call from the request blob; return an opaque handle ≥ 0, or -1 to
    /// refuse (no handler / denied).
    fn start(&mut self, req: &[u8]) -> i32;
    /// Readiness: `0` in flight, `1` ready, `-1` failed/unknown.
    fn poll(&mut self, handle: i32) -> i32;
    /// Stream result bytes into `buf`: `n > 0` bytes, `0` = EOF, `-1` = error.
    fn body(&mut self, handle: i32, buf: &mut [u8]) -> i32;
    /// Release the handle.
    fn close(&mut self, handle: i32);
}

/// Default: refuse every host call (no tools installed).
pub struct DeniedHostCall;

impl HostCallCapability for DeniedHostCall {
    fn start(&mut self, _req: &[u8]) -> i32 {
        -1
    }
    fn poll(&mut self, _handle: i32) -> i32 {
        -1
    }
    fn body(&mut self, _handle: i32, _buf: &mut [u8]) -> i32 {
        -1
    }
    fn close(&mut self, _handle: i32) {}
}

/// A synchronous handler: given the args string, return a result or an error.
pub type ToolFn = Box<dyn FnMut(&str) -> Result<Vec<u8>, String> + Send>;

/// A binary-safe handler: given the request body (the bytes after `name\0`,
/// verbatim — no UTF-8 decode, no trailing-NUL trim), return a result. Used by
/// host-backed mount drivers, whose WRITE op carries binary file content.
pub type RawToolFn = Box<dyn FnMut(&[u8]) -> Result<Vec<u8>, String> + Send>;

struct Slot {
    result: Vec<u8>,
    offset: usize,
    failed: bool,
}

/// A registry of named synchronous handlers — the host-call capability for the
/// native host (tests, the in-process embedded path). Handlers run immediately
/// in `start`, so `poll` reports ready at once.
pub struct MapHostCall {
    tools: HashMap<String, ToolFn>,
    raw: HashMap<String, RawToolFn>,
    slots: HashMap<i32, Slot>,
    next: i32,
}

impl MapHostCall {
    pub fn new() -> Self {
        Self {
            tools: HashMap::new(),
            raw: HashMap::new(),
            slots: HashMap::new(),
            next: 1,
        }
    }

    /// Register a handler for `name` (the first NUL-separated field of the blob).
    pub fn register(&mut self, name: &str, f: ToolFn) {
        self.tools.insert(name.to_string(), f);
    }

    /// Register a binary-safe handler for `name` (a host-backed mount, keyed by
    /// its absolute mount path). Checked before the UTF-8 `tools` map.
    pub fn register_raw(&mut self, name: &str, f: RawToolFn) {
        self.raw.insert(name.to_string(), f);
    }

    /// Drop a previously-registered handler (mount unmounted / tool removed).
    pub fn unregister(&mut self, name: &str) {
        self.tools.remove(name);
        self.raw.remove(name);
    }
}

impl Default for MapHostCall {
    fn default() -> Self {
        Self::new()
    }
}

/// Split a blob into `(name, body)` without trimming trailing NULs — the name is
/// the bytes up to the first NUL, the body is everything after it, verbatim. Used
/// for binary-safe (mount) handlers, where the WRITE body can legitimately end in
/// `0x00`.
fn split_req_raw(req: &[u8]) -> (&str, &[u8]) {
    let nul = req.iter().position(|&b| b == 0).unwrap_or(req.len());
    let name = std::str::from_utf8(&req[..nul]).unwrap_or("");
    let body = if nul < req.len() {
        &req[nul + 1..]
    } else {
        &[]
    };
    (name, body)
}

fn split_req(req: &[u8]) -> (&str, &str) {
    // argv blobs are NUL-terminated, so trim any trailing NUL(s) before splitting
    // — otherwise the args string carries a stray `\0` that breaks JSON parsing.
    let end = req
        .iter()
        .rposition(|&b| b != 0)
        .map(|i| i + 1)
        .unwrap_or(0);
    let req = &req[..end];
    let nul = req.iter().position(|&b| b == 0).unwrap_or(req.len());
    let name = std::str::from_utf8(&req[..nul]).unwrap_or("");
    let args = if nul < req.len() {
        std::str::from_utf8(&req[nul + 1..]).unwrap_or("")
    } else {
        ""
    };
    (name, args)
}

impl HostCallCapability for MapHostCall {
    fn start(&mut self, req: &[u8]) -> i32 {
        // Mount drivers register binary-safe handlers keyed by absolute path; tools
        // register UTF-8 handlers keyed by bare name. The two key spaces are
        // disjoint (mount names start with `/`), so checking raw first is safe.
        let (raw_name, raw_body) = split_req_raw(req);
        if self.raw.contains_key(raw_name) {
            let body = raw_body.to_vec();
            let f = self.raw.get_mut(raw_name).expect("just checked");
            let handle = self.next;
            self.next = self.next.wrapping_add(1).max(1);
            let slot = match f(&body) {
                Ok(result) => Slot {
                    result,
                    offset: 0,
                    failed: false,
                },
                Err(_) => Slot {
                    result: Vec::new(),
                    offset: 0,
                    failed: true,
                },
            };
            self.slots.insert(handle, slot);
            return handle;
        }

        let (name, args) = split_req(req);
        let Some(f) = self.tools.get_mut(name) else {
            return -1; // unknown tool → refuse
        };
        let handle = self.next;
        self.next = self.next.wrapping_add(1).max(1);
        let slot = match f(args) {
            Ok(result) => Slot {
                result,
                offset: 0,
                failed: false,
            },
            Err(_) => Slot {
                result: Vec::new(),
                offset: 0,
                failed: true,
            },
        };
        self.slots.insert(handle, slot);
        handle
    }

    fn poll(&mut self, handle: i32) -> i32 {
        match self.slots.get(&handle) {
            Some(s) if s.failed => -1,
            Some(_) => 1,
            None => -1,
        }
    }

    fn body(&mut self, handle: i32, buf: &mut [u8]) -> i32 {
        match self.slots.get_mut(&handle) {
            Some(s) if s.failed => -1,
            Some(s) => {
                let remaining = &s.result[s.offset..];
                let n = remaining.len().min(buf.len());
                buf[..n].copy_from_slice(&remaining[..n]);
                s.offset += n;
                n as i32
            }
            None => -1,
        }
    }

    fn close(&mut self, handle: i32) {
        self.slots.remove(&handle);
    }
}
