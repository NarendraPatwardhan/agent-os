//! mc guest sysroot — the safe `mc` syscall surface for wasm guest programs.
//!
//! A guest links this `no_std` rlib to get three things: the `mc` import block
//! GENERATED from the syscall contract (so a guest can never import a syscall the kernel
//! doesn't serve — drift = compile error, B2); an ergonomic safe-wrapper skin over those
//! raw `i32` imports (`read`/`write_all`/`open`/`spawn`/… as `Result<T, errno>`); and the `entry!`
//! macro that exports `_start`. A guest's load-time metadata (`mc_tier`/`mc_budget`/`mc_service`) is
//! NOT declared here — both guest lanes declare it in the BUILD and stamp it post-link (`mc_program`
//! for Zig/C++, `mc_rust_program` for Rust), so the build graph is its single source. Built for
//! wasm32-unknown-unknown; every guest pointer is an offset into the guest's OWN linear
//! memory, never a host object (A6).

#![no_std]

// The projected constants — errno, the `O_*` open flags, `TIER_*`, `SEEK_*`, `WNOHANG`,
// the `SIG*` signals, the `CAP_*` bits — from the SAME constants.kdl the kernel derives
// from (B2). Re-exported so a guest writes `rt::ENOENT` / `rt::O_READ`, never a hand-typed
// magic number that could drift from the kernel's.
pub use constants_rust::*;

/// The `mc` import block, projected from `contracts/syscalls.kdl`: a guest `$emit` on the
/// SAME `mc_syscall_table!` the kernel's dispatch (`Pending` enum + wasmi registration)
/// derives from. Every argument and return is an `i32` on the wire — a guest pointer
/// is the i32 offset into the guest's own linear memory; the safe wrappers in [`sys`] cast.
/// The `[$ret]` metadata is the kernel's concern (some syscalls return a value, most an
/// errno); to the guest the import is always `(…i32) -> i32`. Add a syscall and this block
/// regenerates; a wrapper that calls a renamed/removed import fails to compile.
macro_rules! mc_guest_externs {
    ( $( $ident:ident => $Variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        #[link(wasm_import_module = "mc")]
        unsafe extern "C" {
            // A COMPLETE mirror of the contract; not every syscall has a Rust wrapper — the
            // C/C++ trap-unwind shims (mc_sys_pcall / mc_sys_set_throw) are invoked from the
            // Zig glue, not from Rust guests — so the unwrapped imports are expected.
            $( #[allow(dead_code)] pub(crate) fn $ident($($arg: i32),*) -> i32; )*
        }
    };
}
mc_rust::mc_syscall_table!(mc_guest_externs);

// The safe-wrapper skin + the entry/tier/budget macros + the panic handler. Ported from
// memcontainers' sysroot over the generated imports above (generate the boundary,
// port the comfort).
mod sys;
pub use sys::*;
// `abi_version` exists in both `constants_rust` (the compile-time version the guest was
// built against, still reachable as `constants_rust::abi_version`) and `sys` (the runtime
// syscall that asks the kernel). The runtime wrapper is the guest-facing one, so re-export
// it explicitly — an explicit re-export wins over the two ambiguous globs.
pub use sys::abi_version;
