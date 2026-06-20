//! The `env` bridge — the ONLY functions the kernel calls on the host (the A4 boundary).
//! Every host (wasmtime, browser) must implement all of them.
//!
//! This extern block is GENERATED from contracts/bridge.kdl (projected to `env_rust`):
//! `mc_bridge_table!` hands each import to the kernel's `$emit` below, which maps the
//! contract's ABI type tokens (cptr/mptr/len/void/noreturn/i32/i64) to Rust extern types
//! and assembles the `#[link(wasm_import_module = "env")]` block. The host's matching
//! import table is generated from the same contract, so the two cannot drift — no
//! hand-written ABI remains on the import side (B2).

/// Map a contract ABI type token to its Rust extern type. `cptr`/`mptr` carry the
/// pointer mutability the kernel needs (bytes handed OUT vs a buffer the host fills);
/// `void`/`noreturn` become the unit and never types.
macro_rules! env_ty {
    (cptr) => { *const u8 };
    (mptr) => { *mut u8 };
    (len) => { usize };
    (i32) => { i32 };
    (i64) => { i64 };
    (void) => { () };
    (noreturn) => { ! };
}

/// `$emit` for the bridge table: assemble the kernel's `env` import block. The `$variant`
/// label is unused here (the host's import table keys on it). `dead_code` is allowed
/// because the threading imports are only referenced under the `threads` feature.
macro_rules! emit_env_imports {
    ( $( $name:ident => $variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        #[allow(dead_code)]
        #[link(wasm_import_module = "env")]
        unsafe extern "C" {
            $( pub fn $name($($arg: env_ty!($ty)),*) -> env_ty!($ret); )*
        }
    };
}

env_rust::mc_bridge_table!(emit_env_imports);
