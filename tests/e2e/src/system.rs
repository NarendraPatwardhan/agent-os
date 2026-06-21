//! System programs — the non-coreutils binaries that aren't part of the mcbox multicall: `invoke`
//! (the host-tool bridge over `mc_host_call`) and, as it lands, `pkgfsd` (the `/pkg` serve daemon).
//! These exercise the host_call + serve machinery, not just a tool's output.

use host::MapHostCall;

use crate::boot_posix_with_tools;

/// WHY: `invoke` is the guest→host tool bridge — it packs `name\0args`, fires `mc_host_call`, and
/// streams the host handler's result. GUARANTEES: with a tool registered on the host (MapHostCall),
/// `invoke <tool> <args>` reaches the handler WITH the args and streams its result to the terminal
/// (ONLCR → CRLF). Proves the whole path: guest → kernel host_call.rs → the host bridge → the
/// registered handler → back.
#[test]
fn invoke_calls_a_registered_host_tool() {
    let mut tools = MapHostCall::new();
    tools.register("greet", Box::new(|args: &str| Ok(format!("hello {args}\n").into_bytes())));
    let mut s = boot_posix_with_tools(tools);
    assert_eq!(s.run_for_output("invoke greet world"), "hello world\r\n");
}

/// WHY: default-deny (A9) — an unregistered tool must be REFUSED, not silently succeed. GUARANTEES:
/// `invoke` produces no stdout for an unknown tool (the "host tools unavailable" error goes to
/// stderr, exit 1) — the host opts in per tool, nothing leaks through.
#[test]
fn invoke_refuses_an_unregistered_tool() {
    let tools = MapHostCall::new(); // empty registry → every call refused
    let mut s = boot_posix_with_tools(tools);
    assert_eq!(s.run_for_output("invoke nope {}"), "", "an unregistered tool must produce no stdout");
}
