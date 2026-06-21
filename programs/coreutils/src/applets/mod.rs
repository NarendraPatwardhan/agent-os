//! The hand-written + external-crate applets — one module per tool, each exposing
//! `pub fn uumain(args: impl uucore::Args) -> i32` (the uutils calling convention, so the multicall
//! routes them identically to a `uu_*`). uutils applets (`base64` → `uu_base64`) need no module
//! here — the box routes straight to `uu_*::uumain`. Ported from memcontainers'
//! `crates/programs/src/bin/*`.
//!
//! Module compilation is gated on the SAME two axes as the `mcbox!` dispatch (src/main.rs), so a
//! box compiles EXACTLY the applets it routes — no dead modules, no spurious dead_code warnings:
//!   - tier — each box enables one of `tier_isolated`…`tier_full` (disjoint); a module carries its.
//!   - set  — posix boxes set `set_full` (every applet); the minimal boxes set `set_min` (only the
//!            `["set_min"]`-tagged applets, src/main.rs). A full-only applet additionally carries
//!            `not(feature = "set_min")` so it is EXCLUDED from the minimal boxes; the tagged
//!            applets have no set guard, so they compile in both. A divergence from main.rs's tags
//!            is a COMPILE error (the dispatch would name an uncompiled module) — they can't drift.

// isolated — pure compute / cwd-confined, no ambient, no file opens.
#[cfg(all(feature = "tier_isolated", not(feature = "set_min")))]
pub mod basename;
#[cfg(all(feature = "tier_isolated", not(feature = "set_min")))]
pub mod clear;
#[cfg(all(feature = "tier_isolated", not(feature = "set_min")))]
pub mod dirname;
#[cfg(feature = "tier_isolated")]
pub mod echo;
#[cfg(feature = "tier_isolated")]
#[path = "false.rs"]
pub mod r#false;
#[cfg(feature = "tier_isolated")]
pub mod printf;
#[cfg(all(feature = "tier_isolated", not(feature = "set_min")))]
pub mod seq;
#[cfg(all(feature = "tier_isolated", not(feature = "set_min")))]
pub mod tr;
#[cfg(feature = "tier_isolated")]
#[path = "true.rs"]
pub mod r#true;
#[cfg(all(feature = "tier_isolated", not(feature = "set_min")))]
pub mod yes;

// read-only — read arbitrary file paths (so not `isolated`, which confines reads to the cwd
// subtree) but never mutate, spawn, or reach the network.
#[cfg(feature = "tier_readonly")]
pub mod cat;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod cut;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod fold;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod grep;
// external-crate read-only tools (clap CLI over a library crate)
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod diff;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod file;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod jq;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod head;
#[cfg(feature = "tier_readonly")]
pub mod ls;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod nl;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod printenv;
#[cfg(feature = "tier_readonly")]
pub mod pwd;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod readlink;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod realpath;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod rev;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod sleep;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod stat;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod tac;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod tail;
#[cfg(feature = "tier_readonly")]
pub mod test;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod tree;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod wc;
#[cfg(all(feature = "tier_readonly", not(feature = "set_min")))]
pub mod which;

// read-write — mutate the filesystem (FS_WRITE: mkdir/unlink/rename/symlink/link/chmod/utimes/
// open+O_CREATE; the splitters + sort -o / uniq -o write output files). External-crate tools that
// write (awk `print >`, gzip, tar, zip, unzip) live here too.
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod awk;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod gzip;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod tar;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod unzip;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod zip;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod chmod;
#[cfg(feature = "tier_readwrite")]
pub mod cp;
#[cfg(feature = "tier_readwrite")]
pub mod ln;
#[cfg(feature = "tier_readwrite")]
pub mod mkdir;
#[cfg(feature = "tier_readwrite")]
pub mod mv;
#[cfg(feature = "tier_readwrite")]
pub mod rm;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod rmdir;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod sort;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod tee;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod touch;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod truncate;
#[cfg(all(feature = "tier_readwrite", not(feature = "set_min")))]
pub mod uniq;

// full — spawn processes (env/find/kill/nice/nohup/time/timeout/xargs) or reach the network
// (fetch/wget/wscat).
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod env;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod fetch;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod find;
#[cfg(feature = "tier_full")]
pub mod kill;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod nice;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod nohup;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod time;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod timeout;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod wget;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod wscat;
#[cfg(all(feature = "tier_full", not(feature = "set_min")))]
pub mod xargs;
