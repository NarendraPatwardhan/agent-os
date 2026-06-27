//! Kernel-side wrapper over the host persistence bridge.
//!
//! Persistence used to be the last synchronous egress boundary: `get`, `put`,
//! `delete`, and `list` ran to completion inside a single host import. That made
//! the Rust-local disk backend easy, but it made any host that naturally answers
//! through an owner process (BEAM, browser durable storage, remote control plane)
//! either block the import or fake synchrony. The ABI is now shaped like `net`
//! and `host_call`: `start` returns an opaque handle, `poll` reports readiness,
//! `body` streams the answer, and `close` releases the handle.
//!
//! This module owns that raw handle. The rest of the kernel sees only a
//! [`PersistSource`] that yields `Pending` until the host answers and that closes
//! on `Drop`. While the handle is live it counts toward `inflight_egress`, so a
//! snapshot cannot capture a VM whose persistent write/read depends on host
//! state that would not survive restore.

#![allow(dead_code)]

use alloc::vec::Vec;

use crate::bridge;
use crate::net::{egress_dec, egress_inc};

/// Persist request opcodes. The request body is
/// `[op:u32][key_len:u32][key][value...]`; `value` is present only for `PUT`.
pub const OP_GET: u32 = constants_rust::PERSIST_OP_GET;
pub const OP_PUT: u32 = constants_rust::PERSIST_OP_PUT;
pub const OP_DELETE: u32 = constants_rust::PERSIST_OP_DELETE;
pub const OP_LIST: u32 = constants_rust::PERSIST_OP_LIST;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PersistError {
    /// The host refused the capability (`-1` at start).
    Denied,
    /// A failure after the operation started.
    Failed,
}

enum PersistPoll {
    Pending,
    Ready,
    Failed,
}

/// An in-flight persist operation. Owns the host handle.
struct PersistCall {
    handle: i32,
}

impl PersistCall {
    fn start(req: &[u8]) -> Result<Self, PersistError> {
        let h = unsafe { bridge::mc_persist_start(req.as_ptr(), req.len()) };
        if h < 0 {
            Err(PersistError::Denied)
        } else {
            egress_inc();
            Ok(Self { handle: h })
        }
    }

    fn poll(&mut self) -> PersistPoll {
        match unsafe { bridge::mc_persist_poll(self.handle) } {
            0 => PersistPoll::Pending,
            1.. => PersistPoll::Ready,
            _ => PersistPoll::Failed,
        }
    }

    fn read_body(&mut self, out: &mut [u8]) -> Result<usize, PersistError> {
        let n = unsafe { bridge::mc_persist_body(self.handle, out.as_mut_ptr(), out.len()) };
        if n < 0 {
            Err(PersistError::Failed)
        } else {
            Ok((n as usize).min(out.len()))
        }
    }
}

impl Drop for PersistCall {
    fn drop(&mut self) {
        unsafe { bridge::mc_persist_close(self.handle) };
        egress_dec();
    }
}

enum Phase {
    Polling,
    Body,
    Eof,
    Failed,
}

pub enum PersistRead {
    Pending,
    Got(usize),
    Eof,
    Failed,
}

/// A readable async persist result.
pub struct PersistSource {
    call: PersistCall,
    phase: Phase,
}

impl PersistSource {
    pub fn start(op: u32, key: &[u8], value: &[u8]) -> Result<Self, PersistError> {
        let mut req = Vec::with_capacity(8 + key.len() + value.len());
        req.extend_from_slice(&op.to_le_bytes());
        req.extend_from_slice(&(key.len() as u32).to_le_bytes());
        req.extend_from_slice(key);
        req.extend_from_slice(value);
        Ok(Self {
            call: PersistCall::start(&req)?,
            phase: Phase::Polling,
        })
    }

    pub fn read_into(&mut self, buf: &mut [u8]) -> PersistRead {
        loop {
            match self.phase {
                Phase::Polling => match self.call.poll() {
                    PersistPoll::Pending => return PersistRead::Pending,
                    PersistPoll::Ready => self.phase = Phase::Body,
                    PersistPoll::Failed => {
                        self.phase = Phase::Failed;
                        return PersistRead::Failed;
                    }
                },
                Phase::Body => {
                    return match self.call.read_body(buf) {
                        Ok(0) => {
                            self.phase = Phase::Eof;
                            PersistRead::Eof
                        }
                        Ok(n) => PersistRead::Got(n),
                        Err(_) => {
                            self.phase = Phase::Failed;
                            PersistRead::Failed
                        }
                    };
                }
                Phase::Eof => return PersistRead::Eof,
                Phase::Failed => return PersistRead::Failed,
            }
        }
    }
}
