//! `coreutils` — the per-tier multicall `/bin` (VISION §16.3). ONE std crate, built for
//! `wasm32-wasi` and compiled four times (cfg tiers) into `mcbox-{isolated,readonly,readwrite,
//! full}`; the `//wasi-adapter` then rewrites each box's `wasi_snapshot_preview1` imports to
//! `mc`. `argv[0]` (or `argv[1]`) selects an applet and calls its `uumain` — hand-written
//! (`cat`, over `//sysroot` + the facade), external-crate (`grep`, over ripgrep), or uutils
//! (`base64` = `uu_base64::uumain`, as-is). clap + uucore are linked for the uutils applets
//! regardless, so the hand-written tools REUSE them (no parallel CLI); the facade
//! (`fsutil`/`textio`/`spool`) is the only hand-written-specific code, for mc-shaped I/O.

// The facade is ported from no_std mc-native code and addresses `alloc::*` directly; bring the
// crate into the extern prelude so those paths resolve inside a std crate.
extern crate alloc;

// The facade modules are `pub` so the crate-internal `prelude` can re-export them (a binary
// crate has no external API, so this only affects intra-crate paths).
pub mod fsutil;
pub mod spool;
pub mod textio;

mod applets;
mod mcbox;
mod prelude;

// The box: ONE applet list, compiled per-tier. cat/base64/grep read arbitrary paths but never
// mutate → read-only (the slice's isolated/readwrite/full boxes build too, carrying these via
// the cumulative features; isolated carries none until isolated applets land).
mcbox! {
    "cat" @ "tier_readonly" => applets::cat::uumain,
    "base64" @ "tier_readonly" => uu_base64::uumain,
    "grep" @ "tier_readonly" => applets::grep::uumain,
}
