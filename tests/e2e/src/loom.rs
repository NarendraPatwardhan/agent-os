//! loom — the Luau interpreter (/bin/luau) as a one-binary domain service (§16.5). Boots the loom
//! image (posix + the stamped, pure-mc luau guest) and runs Luau end to end through the interactive
//! shell. The console path: print's `\n` reaches the TTY as ONLCR `\r\n`.

use crate::boot_loom;

/// luau evaluates a `-e` one-liner and prints the result. WHY: this is the whole loom build proven
/// at runtime — the zig c++ Luau (VM + Compiler) + the Zig glue + the wasi→mc adapter + the kernel
/// trap-unwind (Luau's lua_pcall ⇒ mc_protected_call ⇒ mc_sys_pcall ⇒ the kernel re-enters via
/// __mc_pcall_run) — running real bytecode on the real kernel under its mc_budget. GUARANTEES: a
/// bare integer prints with no decimal and the newline is ONLCR-translated.
#[test]
fn luau_evaluates_arithmetic() {
    let mut s = boot_loom();
    assert_eq!(s.run_for_output("luau -e 'print(1+1)'"), "2\r\n");
}

/// luau --version identifies the build (a no-VM path: arg parse + a single write). WHY: confirms the
/// binary loads, the mc_tier/mc_budget sections parse, and argv reaches the guest through the
/// wasi→mc adapter before any interpretation.
#[test]
fn luau_reports_version() {
    let mut s = boot_loom();
    let out = s.run_for_output("luau --version");
    assert!(out.contains("Luau 0.725"), "unexpected --version: {out:?}");
}
