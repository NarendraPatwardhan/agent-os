//! The hand-written + external-crate applets — one module per tool, each exposing
//! `pub fn uumain(args: impl uucore::Args) -> i32` (the uutils calling convention, so the
//! multicall routes them identically to a `uu_*`). uutils applets (`base64` → `uu_base64`) need
//! no module here — the box routes straight to `uu_base64::uumain`. Each is gated to the lowest
//! tier whose capabilities cover it; the cumulative tier features make a higher-tier box include
//! every lower applet, so a box carries EXACTLY its tier's applets (what lets §16.4 hold).

// read-only — read arbitrary file paths (so not `isolated`, which confines reads to the cwd
// subtree) but never mutate, spawn, or reach the network.
#[cfg(feature = "tier_readonly")]
pub mod cat;
#[cfg(feature = "tier_readonly")]
pub mod grep;
