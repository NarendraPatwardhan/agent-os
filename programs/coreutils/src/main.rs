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

// The box: ONE applet list, compiled per-tier (each line gated by its tier feature). Three
// origins, routed uniformly: hand-written (`applets::<name>::uumain`, over //sysroot + the
// facade), external-crate (`grep`, over ripgrep), and uutils used AS-IS (`uu_<name>::uumain`).
mcbox! {
    // hand-written + external-crate slice
    "cat" @ "tier_readonly" => applets::cat::uumain,
    "grep" @ "tier_readonly" => applets::grep::uumain,
    // uutils, read-only family — hash/checksum, base-N, text format/join, compute, misc
    "base64" @ "tier_readonly" => uu_base64::uumain,
    "sha256sum" @ "tier_readonly" => uu_sha256sum::uumain,
    "sha1sum" @ "tier_readonly" => uu_sha1sum::uumain,
    "sha512sum" @ "tier_readonly" => uu_sha512sum::uumain,
    "md5sum" @ "tier_readonly" => uu_md5sum::uumain,
    "b2sum" @ "tier_readonly" => uu_b2sum::uumain,
    "cksum" @ "tier_readonly" => uu_cksum::uumain,
    "sum" @ "tier_readonly" => uu_sum::uumain,
    "base32" @ "tier_readonly" => uu_base32::uumain,
    "basenc" @ "tier_readonly" => uu_basenc::uumain,
    "comm" @ "tier_readonly" => uu_comm::uumain,
    "join" @ "tier_readonly" => uu_join::uumain,
    "paste" @ "tier_readonly" => uu_paste::uumain,
    "fmt" @ "tier_readonly" => uu_fmt::uumain,
    "expand" @ "tier_readonly" => uu_expand::uumain,
    "unexpand" @ "tier_readonly" => uu_unexpand::uumain,
    "od" @ "tier_readonly" => uu_od::uumain,
    "factor" @ "tier_readonly" => uu_factor::uumain,
    "numfmt" @ "tier_readonly" => uu_numfmt::uumain,
    "tsort" @ "tier_readonly" => uu_tsort::uumain,
    "date" @ "tier_readonly" => uu_date::uumain,
    "shuf" @ "tier_readonly" => uu_shuf::uumain,
    "pathchk" @ "tier_readonly" => uu_pathchk::uumain,
    // uutils, read-write family — the splitters write output files
    "split" @ "tier_readwrite" => uu_split::uumain,
    "csplit" @ "tier_readwrite" => uu_csplit::uumain,
    // external-crate (vendored): uutils sed — its own clap CLI (uu_app) gives the detailed --help
    "sed" @ "tier_readwrite" => sed::sed::uumain,

    // ---- hand-written (ported from memcontainers' programs::*), by tier ----
    // isolated — pure compute / cwd-confined
    "basename" @ "tier_isolated" => applets::basename::uumain,
    "dirname" @ "tier_isolated" => applets::dirname::uumain,
    "echo" @ "tier_isolated" => applets::echo::uumain,
    "false" @ "tier_isolated" => applets::r#false::uumain,
    "printf" @ "tier_isolated" => applets::printf::uumain,
    "seq" @ "tier_isolated" => applets::seq::uumain,
    "tr" @ "tier_isolated" => applets::tr::uumain,
    "true" @ "tier_isolated" => applets::r#true::uumain,
    "clear" @ "tier_isolated" => applets::clear::uumain,
    "yes" @ "tier_isolated" => applets::yes::uumain,
    // read-only — read arbitrary paths, no mutation
    "cut" @ "tier_readonly" => applets::cut::uumain,
    "fold" @ "tier_readonly" => applets::fold::uumain,
    "head" @ "tier_readonly" => applets::head::uumain,
    "ls" @ "tier_readonly" => applets::ls::uumain,
    "nl" @ "tier_readonly" => applets::nl::uumain,
    "printenv" @ "tier_readonly" => applets::printenv::uumain,
    "pwd" @ "tier_readonly" => applets::pwd::uumain,
    "readlink" @ "tier_readonly" => applets::readlink::uumain,
    "realpath" @ "tier_readonly" => applets::realpath::uumain,
    "rev" @ "tier_readonly" => applets::rev::uumain,
    "sleep" @ "tier_readonly" => applets::sleep::uumain,
    "stat" @ "tier_readonly" => applets::stat::uumain,
    "tac" @ "tier_readonly" => applets::tac::uumain,
    "tail" @ "tier_readonly" => applets::tail::uumain,
    "test" @ "tier_readonly" => applets::test::uumain,
    "[" @ "tier_readonly" => applets::test::uumain,
    "tree" @ "tier_readonly" => applets::tree::uumain,
    "wc" @ "tier_readonly" => applets::wc::uumain,
    "which" @ "tier_readonly" => applets::which::uumain,
    // read-write — mutate the filesystem
    "chmod" @ "tier_readwrite" => applets::chmod::uumain,
    "cp" @ "tier_readwrite" => applets::cp::uumain,
    "ln" @ "tier_readwrite" => applets::ln::uumain,
    "mkdir" @ "tier_readwrite" => applets::mkdir::uumain,
    "mv" @ "tier_readwrite" => applets::mv::uumain,
    "rm" @ "tier_readwrite" => applets::rm::uumain,
    "rmdir" @ "tier_readwrite" => applets::rmdir::uumain,
    "sort" @ "tier_readwrite" => applets::sort::uumain,
    "tee" @ "tier_readwrite" => applets::tee::uumain,
    "touch" @ "tier_readwrite" => applets::touch::uumain,
    "truncate" @ "tier_readwrite" => applets::truncate::uumain,
    "uniq" @ "tier_readwrite" => applets::uniq::uumain,
    // full — spawn / network
    "env" @ "tier_full" => applets::env::uumain,
    "fetch" @ "tier_full" => applets::fetch::uumain,
    "find" @ "tier_full" => applets::find::uumain,
    "kill" @ "tier_full" => applets::kill::uumain,
    "nice" @ "tier_full" => applets::nice::uumain,
    "nohup" @ "tier_full" => applets::nohup::uumain,
    "time" @ "tier_full" => applets::time::uumain,
    "timeout" @ "tier_full" => applets::timeout::uumain,
    "wget" @ "tier_full" => applets::wget::uumain,
    "wscat" @ "tier_full" => applets::wscat::uumain,
    "xargs" @ "tier_full" => applets::xargs::uumain,
}
