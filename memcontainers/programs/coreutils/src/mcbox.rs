//! The per-tier multicall — std, routed exactly like uutils' own `coreutils` binary: pick an
//! applet from `argv[0]`'s basename (or `argv[1]` in bundle form) and call its
//! `uumain(args) -> i32`. From ONE applet list, [`mcbox!`] emits this `main`, the box's
//! `mc_applets` roster (the source of the generated `/bin` symlinks), and its `mc_tier`
//! stamp; the cfg features select which applets a box carries. Ported from memcontainers'
//! `wasi::multicall::multicall!`, generalized to mixed applet origins (hand-written +
//! external-crate + uutils) and four cfg-tiered boxes.

use std::ffi::OsString;

/// Last path component of an argv token (`/bin/cat` → `cat`).
pub fn basename(p: &OsString) -> String {
    let s = p.to_string_lossy();
    s.rsplit(['/', '\\']).next().unwrap_or("").to_string()
}

/// Assemble a multicall box from an applet list `"<name>" @ "<tier_feature>" ["<set_feature>"]? =>
/// <uumain_path>`. Names are string literals (keyword-safe: `"true"`/`"false"` are real applets);
/// the path is the applet's `uumain` — `applets::cat::uumain`, `uu_base64::uumain`, …
///
/// TWO selection axes, both cfg features the box build sets:
///   - tier  (`tier_isolated`…`tier_full`) — least privilege; each box enables exactly one.
///   - set   (`set_full` = posix / everything, `set_min` = the minimal flavor's curated subset).
/// Every applet is in `set_full`; an optional `["set_min"]` tag ALSO puts it in `set_min`. A box
/// carries `<name>` iff its tier feature matches AND its set feature is one the applet belongs to —
/// so the same crate + macro yields the posix boxes (`set_full`) and the minimal boxes (`set_min`).
#[macro_export]
macro_rules! mcbox {
    ( $( $name:literal @ $tier:literal $( [ $set:literal ] )? => $run:path ),+ $(,)? ) => {
        // The box's tier = the HIGHEST enabled tier feature → the `mc_tier` section the kernel
        // reads at exec to narrow this box's capabilities.
        #[cfg(feature = "tier_full")]
        const __BOX_TIER: &str = "full";
        #[cfg(all(feature = "tier_readwrite", not(feature = "tier_full")))]
        const __BOX_TIER: &str = "read-write";
        #[cfg(all(feature = "tier_readonly", not(feature = "tier_readwrite")))]
        const __BOX_TIER: &str = "read-only";
        #[cfg(all(feature = "tier_isolated", not(feature = "tier_readonly")))]
        const __BOX_TIER: &str = "isolated";

        #[link_section = "mc_tier"]
        #[used]
        static __MC_TIER: [u8; __BOX_TIER.len()] = {
            let src = __BOX_TIER.as_bytes();
            let mut out = [0u8; __BOX_TIER.len()];
            let mut i = 0;
            while i < out.len() {
                out[i] = src[i];
                i += 1;
            }
            out
        };

        // The roster: each ENABLED applet contributes "<name>\n" to `mc_applets`; the linker
        // concatenates them, so the roster — and the generated /bin symlinks — come from this
        // one list, never a hand-kept copy. Each entry lives in its own anonymous const block.
        $(
            #[cfg(all(feature = $tier, any(feature = "set_full" $(, feature = $set)?)))]
            const _: () = {
                #[link_section = "mc_applets"]
                #[used]
                static ENTRY: [u8; $name.len() + 1] = {
                    let src = $name.as_bytes();
                    let mut out = [0u8; $name.len() + 1];
                    let mut i = 0;
                    while i < $name.len() {
                        out[i] = src[i];
                        i += 1;
                    }
                    out[$name.len()] = b'\n';
                    out
                };
            };
        )+

        fn main() {
            const NAMES: &[&str] =
                &[$( #[cfg(all(feature = $tier, any(feature = "set_full" $(, feature = $set)?)))] $name, )+];
            let argv: ::std::vec::Vec<::std::ffi::OsString> = ::std::env::args_os().collect();
            let arg0 = argv.first().cloned().unwrap_or_default();
            let base = $crate::mcbox::basename(&arg0);

            // Direct form: invoked under an applet name (the staged `/bin/<applet>`). Bundle
            // form: invoked as the box itself → the applet is `argv[1]`, handed an argv whose
            // `[0]` is its own name.
            let (applet, args): (::std::string::String, ::std::vec::Vec<::std::ffi::OsString>) =
                if NAMES.contains(&base.as_str()) {
                    (base, argv)
                } else if argv.len() >= 2 {
                    ($crate::mcbox::basename(&argv[1]), argv[1..].to_vec())
                } else {
                    ::std::eprintln!(
                        "mcbox: usage: <applet> [args...]  (applets: {})",
                        NAMES.join(", ")
                    );
                    ::std::process::exit(2);
                };

            // Initialize uucore's Fluent localization so a `uu_*` applet's `--help` resolves to
            // real strings instead of message keys (best-effort; a clap-based hand-written
            // applet ignores it).
            let _ = ::uucore::locale::setup_localization(&applet);

            // A box whose tier enables no applet arms (e.g. an empty `isolated`) never consumes
            // `args`; touch it so that case does not warn.
            let _ = &args;
            let code = match applet.as_str() {
                $( #[cfg(all(feature = $tier, any(feature = "set_full" $(, feature = $set)?)))]
                   $name => $run(args.into_iter()), )+
                other => {
                    ::std::eprintln!("{other}: applet not in this box");
                    127
                }
            };
            ::std::process::exit(code);
        }
    };
}
