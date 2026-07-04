//! src/egress/net.zig — HTTP and WebSocket egress state machines (§2.8).
//!
//! Owns: capability checks, request IDs, polling, body reads, close semantics, and inflight accounting for HTTP + WebSocket.
//! Invariants: A9 (capability denials → errno, never host exceptions/traps), A8 (inflight requests are snapshot blockers surfaced via mc_inflight_egress). ASYNC: shallow Pending (§7.4).
//! Oracle (behavior to match): kernel/rust/src/net/mod.rs.
//! Not here: the /net VFS projection (fs/netfs.zig) — this file is the engine.
//!
//! Scaffold status: header-only. Fill Phase 6.

// (intentionally empty — scaffold stub; fill per the header contract above.)
