//! src/fs/utils.zig — shared filesystem helpers (§2.5).
//!
//! Owns: small helpers reused across fs/* backends (path fragments, metadata builders).
//! Invariants: match the oracle helpers exactly where behavior is observable.
//! Oracle (behavior to match): kernel/rust/src/fs/utils.rs.
//! Not here: backend policy — helpers only.
//!
//! Scaffold status: header-only. Fill as backends need them.

// (intentionally empty — scaffold stub; fill per the header contract above.)
