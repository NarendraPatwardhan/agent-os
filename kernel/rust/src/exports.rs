//! The kernel's exported entry points — the host→kernel CONTROL boundary's kernel half,
//! GENERATED from contracts/control.kdl. Each `#[unsafe(no_mangle)]` shim is the contract
//! signature (cptr/mptr/void mapped to Rust extern types); its body forwards to the
//! same-named handler at crate root, where the logic lives. Adding a row to control.kdl
//! generates a shim that calls a handler which does not exist yet — a compile error until
//! the kernel implements it (B2: drift = compile error). The host's import side is
//! generated from the same contract, so host and kernel cannot drift either.

/// Map a control ABI type token to its Rust extern type — the bridge's mapper restricted
/// to the types the control surface uses (exports return `()`, an `i32`, or a buffer
/// pointer; no `noreturn`/`i64` here). A future row needing another type fails to compile
/// here, pointing at the one place to extend.
macro_rules! ctl_ty {
    (u32) => { u32 };
    (i32) => { i32 };
    (len) => { usize };
    (cptr) => { *const u8 };
    (mptr) => { *mut u8 };
    (void) => { () };
}

/// `$emit` for the control table: one `#[no_mangle]` shim per export, forwarding to its
/// crate-root handler. The leading `$(#[$attr])*` carries the contract's row metadata —
/// the threads-only exports gate here via `#[cfg(feature = "threads")]`, and their
/// handlers carry the same cfg, so the coop kernel omits both shim and handler.
macro_rules! emit_ctl_exports {
    ( $( $(#[$attr:meta])* $name:ident => $variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        $(
            $(#[$attr])*
            #[unsafe(no_mangle)]
            pub extern "C" fn $name($($arg: ctl_ty!($ty)),*) -> ctl_ty!($ret) {
                super::$name($($arg),*)
            }
        )*
    };
}

ctl_rust::mc_control_table!(emit_ctl_exports);
