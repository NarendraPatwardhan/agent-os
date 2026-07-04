//! src/service/registry.zig — the resident-service registry, sessions, and request/response lifecycle (§2.8).
//!
//! Owns: the registry of resident services, their sessions, and the request/response lifecycle behind /svc and mc_ctl_svc_call_*.
//! Invariants: A7 (deterministic activation/retry ordering), A8 (in-flight service requests + delegated handles are snapshot blockers). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/fs/servicefs.rs + service activation in kernel/rust/src/init.rs.
//! Not here: the /svc VFS projection (fs/servicefs.zig); the control-call façade (control.zig). This file is the engine.
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
