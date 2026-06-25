//! End-to-end suite — EXTENDED (B6). The heavy DOMAIN services, split out of the core suite.
//!
//! Same constitution as [the core suite](../lib.rs) and the SAME [`harness`] (boot helpers + the
//! `Session` driver) — re-exported here so `sqlite`/`typst` read `boot_atlas()`/`boot_paper()` exactly
//! as the core groups read `boot_posix()`. The reason this is a separate target: these tests run REAL
//! engine work (a typst compile is millions of fuel slices under wasmi; a sqlite workload builds and
//! queries a live DB), so they boot the large `atlas`/`paper` images and use the heavy tick budget.
//! Keeping them off the core target lets `bazel test //memcontainers/tests/e2e:core` stay sub-second
//! and lets CI gate the fast invariants independently of the slow domain proofs.

mod harness;
pub use harness::*;

mod sqlite;
mod typst;
