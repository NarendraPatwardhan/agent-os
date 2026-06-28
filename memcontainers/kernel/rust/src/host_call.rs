//! Kernel-side wrapper over the host-call bridge imports. A guest invokes a
//! host-resident function (the tool broker, a host-backed mount driver) via
//! `mc_sys_host_call`; the host routes the opaque request blob to a registered
//! handler and streams back a result. Exactly like `net::HttpReq`, the raw `i32`
//! handle is a kernel↔host contract that MUST NOT reach the guest — the guest
//! only ever sees an ordinary readable fd. Owns the handle, drives the
//! poll/body/close calls, and closes on `Drop`. Host calls count toward the
//! same in-flight-egress total as the network (a snapshot must not capture a
//! live host handle); see `net::inflight_egress`.

use crate::bridge;
use crate::net::{egress_dec, egress_inc};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostCallError {
    /// The host refused (no handler / capability denied) — `-1` at start.
    Denied,
    /// A failure after the call started.
    Failed,
}

enum CallPoll {
    Pending,
    Ready,
    Failed,
}

/// An in-flight host call. Owns the host handle; closes it on `Drop`.
struct HostCall {
    handle: i32,
}

impl HostCall {
    fn start(req: &[u8]) -> Result<HostCall, HostCallError> {
        let h = unsafe { bridge::mc_host_call(req.as_ptr(), req.len()) };
        if h < 0 {
            Err(HostCallError::Denied)
        } else {
            egress_inc();
            Ok(HostCall { handle: h })
        }
    }

    fn poll(&mut self) -> CallPoll {
        // The host reports readiness without consuming the body (buf unused).
        let n = unsafe { bridge::mc_host_call_poll(self.handle, core::ptr::null_mut(), 0) };
        if n < 0 {
            CallPoll::Failed
        } else if n == 0 {
            CallPoll::Pending
        } else {
            CallPoll::Ready
        }
    }

    fn read_body(&mut self, out: &mut [u8]) -> Result<usize, HostCallError> {
        let n = unsafe { bridge::mc_host_call_body(self.handle, out.as_mut_ptr(), out.len()) };
        if n < 0 {
            Err(HostCallError::Failed)
        } else {
            Ok((n as usize).min(out.len()))
        }
    }
}

impl Drop for HostCall {
    fn drop(&mut self) {
        unsafe { bridge::mc_host_call_close(self.handle) };
        egress_dec();
    }
}

enum Phase {
    Polling,
    Body,
    Eof,
    Failed,
}

/// Outcome of pulling bytes from a `HostCallSource`.
pub enum HostCallRead {
    /// The host is still computing the result — yield and retry.
    Pending,
    Got(usize),
    Eof,
    Failed,
}

/// A readable host-call result, driven by `mc_sys_read` — poll for readiness
/// (yielding while in flight), then stream the result body, then EOF.
pub struct HostCallSource {
    call: HostCall,
    phase: Phase,
}

impl HostCallSource {
    /// Begin a host call from a request blob; `Denied` if the host refused.
    pub fn start(req: &[u8]) -> Result<HostCallSource, HostCallError> {
        Ok(HostCallSource {
            call: HostCall::start(req)?,
            phase: Phase::Polling,
        })
    }

    pub fn read_into(&mut self, buf: &mut [u8]) -> HostCallRead {
        loop {
            match self.phase {
                Phase::Polling => match self.call.poll() {
                    CallPoll::Pending => return HostCallRead::Pending,
                    CallPoll::Ready => self.phase = Phase::Body,
                    CallPoll::Failed => {
                        self.phase = Phase::Failed;
                        return HostCallRead::Failed;
                    }
                },
                Phase::Body => {
                    return match self.call.read_body(buf) {
                        Ok(0) => {
                            self.phase = Phase::Eof;
                            HostCallRead::Eof
                        }
                        Ok(n) => HostCallRead::Got(n),
                        Err(_) => {
                            self.phase = Phase::Failed;
                            HostCallRead::Failed
                        }
                    };
                }
                Phase::Eof => return HostCallRead::Eof,
                Phase::Failed => return HostCallRead::Failed,
            }
        }
    }

    /// Non-destructive readiness (advance past the poll only).
    pub fn poll_readable(&mut self) -> bool {
        if let Phase::Polling = self.phase {
            match self.call.poll() {
                CallPoll::Pending => return false,
                CallPoll::Ready => self.phase = Phase::Body,
                CallPoll::Failed => self.phase = Phase::Failed,
            }
        }
        true
    }
}
