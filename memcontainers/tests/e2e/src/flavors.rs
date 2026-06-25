//! Flavors — the image layering (SYSTEMS.md). `base` (the bare sh + pkgfsd + invoke substrate, the
//! boot test already exercises it) is shared; `minimal` adds the curated ~15-tool coreutils set,
//! `posix` adds the full ~88. This asserts the SET boundary is REAL at runtime — a minimal image
//! runs its curated commands, and a posix-only command simply isn't there.

use crate::boot_minimal;

/// WHY: `minimal` is the four MINIMAL coreutils boxes (only the `["set_min"]`-tagged applets, built
/// over `base`) — NOT the full posix set. GUARANTEES: a curated command runs (cat, from
/// mcbox-min-readonly), and a posix-only command has NO `/bin` entry at all — `wc` never compiled
/// into the minimal boxes, so their roster carried no name and mc-roster emitted no symlink. The set
/// boundary is enforced by what compiled in, not by hiding files.
#[test]
fn minimal_carries_the_curated_set_not_full_posix() {
    let mut s = boot_minimal();
    // A curated command runs end to end (the shell spawns /bin/cat → mcbox-min-readonly).
    s.host.write_file("/tmp/x", b"minimal\n").expect("write /tmp/x");
    assert_eq!(s.run_for_output("cat /tmp/x"), "minimal\r\n");
    // A posix-only command is absent: no roster name → no /bin symlink.
    assert!(s.host.stat("/bin/wc").is_err(), "/bin/wc must be absent in minimal (it is posix-only)");
}
