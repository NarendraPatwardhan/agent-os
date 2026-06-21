//! The hand-written + external-crate applets — one module per tool, each exposing
//! `pub fn uumain(args: impl uucore::Args) -> i32` (the uutils calling convention, so the
//! multicall routes them identically to a `uu_*`). uutils applets (`base64` → `uu_base64`) need
//! no module here — the box routes straight to `uu_*::uumain`. Each is gated to the lowest tier
//! whose capabilities cover it; the cumulative tier features make a higher-tier box include every
//! lower applet, so a box carries EXACTLY its tier's applets (what lets §16.4 hold). Ported from
//! memcontainers' `crates/programs/src/bin/*`.

// isolated — pure compute / cwd-confined, no ambient, no file opens.
#[cfg(feature = "tier_isolated")]
pub mod basename;
#[cfg(feature = "tier_isolated")]
pub mod clear;
#[cfg(feature = "tier_isolated")]
pub mod dirname;
#[cfg(feature = "tier_isolated")]
pub mod echo;
#[cfg(feature = "tier_isolated")]
#[path = "false.rs"]
pub mod r#false;
#[cfg(feature = "tier_isolated")]
pub mod printf;
#[cfg(feature = "tier_isolated")]
pub mod seq;
#[cfg(feature = "tier_isolated")]
pub mod tr;
#[cfg(feature = "tier_isolated")]
#[path = "true.rs"]
pub mod r#true;
#[cfg(feature = "tier_isolated")]
pub mod yes;

// read-only — read arbitrary file paths (so not `isolated`, which confines reads to the cwd
// subtree) but never mutate, spawn, or reach the network.
#[cfg(feature = "tier_readonly")]
pub mod cat;
#[cfg(feature = "tier_readonly")]
pub mod cut;
#[cfg(feature = "tier_readonly")]
pub mod fold;
#[cfg(feature = "tier_readonly")]
pub mod grep;
#[cfg(feature = "tier_readonly")]
pub mod head;
#[cfg(feature = "tier_readonly")]
pub mod ls;
#[cfg(feature = "tier_readonly")]
pub mod nl;
#[cfg(feature = "tier_readonly")]
pub mod printenv;
#[cfg(feature = "tier_readonly")]
pub mod pwd;
#[cfg(feature = "tier_readonly")]
pub mod readlink;
#[cfg(feature = "tier_readonly")]
pub mod realpath;
#[cfg(feature = "tier_readonly")]
pub mod rev;
#[cfg(feature = "tier_readonly")]
pub mod sleep;
#[cfg(feature = "tier_readonly")]
pub mod stat;
#[cfg(feature = "tier_readonly")]
pub mod tac;
#[cfg(feature = "tier_readonly")]
pub mod tail;
#[cfg(feature = "tier_readonly")]
pub mod test;
#[cfg(feature = "tier_readonly")]
pub mod tree;
#[cfg(feature = "tier_readonly")]
pub mod wc;
#[cfg(feature = "tier_readonly")]
pub mod which;

// read-write — mutate the filesystem (FS_WRITE: mkdir/unlink/rename/symlink/link/chmod/utimes/
// open+O_CREATE; the splitters + sort -o / uniq -o write output files).
#[cfg(feature = "tier_readwrite")]
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
#[cfg(feature = "tier_readwrite")]
pub mod rmdir;
#[cfg(feature = "tier_readwrite")]
pub mod sort;
#[cfg(feature = "tier_readwrite")]
pub mod tee;
#[cfg(feature = "tier_readwrite")]
pub mod touch;
#[cfg(feature = "tier_readwrite")]
pub mod truncate;
#[cfg(feature = "tier_readwrite")]
pub mod uniq;

// full — spawn processes (env/find/kill/nice/nohup/time/timeout/xargs) or reach the network
// (fetch/wget/wscat).
#[cfg(feature = "tier_full")]
pub mod env;
#[cfg(feature = "tier_full")]
pub mod fetch;
#[cfg(feature = "tier_full")]
pub mod find;
#[cfg(feature = "tier_full")]
pub mod kill;
#[cfg(feature = "tier_full")]
pub mod nice;
#[cfg(feature = "tier_full")]
pub mod nohup;
#[cfg(feature = "tier_full")]
pub mod time;
#[cfg(feature = "tier_full")]
pub mod timeout;
#[cfg(feature = "tier_full")]
pub mod wget;
#[cfg(feature = "tier_full")]
pub mod wscat;
#[cfg(feature = "tier_full")]
pub mod xargs;
