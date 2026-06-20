//! The kernel exports the host calls — the host's view of the `mc_ctl_*` / lifecycle
//! CONTROL boundary, GENERATED from `contracts/control.kdl` (projected to `ctl_rust`), the
//! same contract the kernel's export shims are generated from (B2). `mc_control_table!`
//! hands every export to `kernel_exports`, which emits a `TypedFunc` field + a `.ok()`
//! lookup per row. Add a control export and this struct gains its field — the host's view
//! cannot drift from the contract.
//!
//! Each field is `Option`: the host loads `kernel.wasm` at RUNTIME, so it cannot know at
//! compile time which exports a given artifact has (the threading/snapshot exports gate on
//! the kernel's `threads` feature). For that reason the host's `$emit` deliberately
//! IGNORES the contract's `cfg` row metadata — it always emits the field and looks the
//! export up, gracefully handling an absent one — whereas the kernel applies the cfg to
//! omit the export entirely. Same contract, consumer-specific projection.

use anyhow::{Result, anyhow};
use wasmtime::{Instance, Store, TypedFunc};

use crate::HostState;

/// Map a contract ABI type token to the wasm value type the host sees (a guest pointer or
/// length is an `i32` at the wasm boundary; `void` is the unit result).
macro_rules! host_ty {
    (u32) => { i32 };
    (i32) => { i32 };
    (i64) => { i64 };
    (len) => { i32 };
    (cptr) => { i32 };
    (mptr) => { i32 };
    (void) => { () };
}

/// Map a row's argument types to wasmtime's `Params`: `()` for zero args, the bare type
/// for one (wasmtime has no 1-tuple `Params`), a tuple for two or more.
macro_rules! params_ty {
    () => { () };
    ($t:tt) => { host_ty!($t) };
    ($($t:tt),+ $(,)?) => { ( $(host_ty!($t)),+ ) };
}

/// `$emit` for the control table: a `TypedFunc` field per kernel export, plus the grouped
/// `.ok()` lookup. The `$(#[$attr])*` row metadata is matched but NOT applied (see the
/// module doc — the host looks up at runtime, it does not cfg on the kernel's features).
macro_rules! kernel_exports {
    ( $( $(#[$attr:meta])* $name:ident => $variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        // A complete mirror of the control surface; this host doesn't call every export
        // (e.g. mc_init is invoked at boot before the struct exists, mc_resize is unused).
        #[allow(dead_code)]
        pub struct KernelExports {
            $( pub $name: Option<TypedFunc<params_ty!($($ty),*), host_ty!($ret)>>, )*
        }

        impl KernelExports {
            pub fn lookup(instance: &Instance, store: &mut Store<HostState>) -> Self {
                Self {
                    $( $name: instance.get_typed_func(&mut *store, stringify!($name)).ok(), )*
                }
            }
        }
    };
}

ctl_rust::mc_control_table!(kernel_exports);

/// Accessors for the exports the host treats as MANDATORY: absent ⇒ a clear error rather
/// than a panic. The optional exports (threading worker/quiesce, snapshot counters, exec
/// peek, commit) are read directly off the struct as `Option`.
impl KernelExports {
    fn require<T: Clone>(f: &Option<T>, name: &str) -> Result<T> {
        f.clone()
            .ok_or_else(|| anyhow!("this kernel artifact lacks the `{name}` export; rebuild the kernel"))
    }

    pub(crate) fn require_tick(&self) -> Result<TypedFunc<(), i32>> {
        Self::require(&self.mc_tick, "mc_tick")
    }
    pub(crate) fn require_input(&self) -> Result<TypedFunc<(i32, i32), ()>> {
        Self::require(&self.mc_input, "mc_input")
    }
    pub(crate) fn require_ctl_buf(&self) -> Result<TypedFunc<i32, i32>> {
        Self::require(&self.mc_ctl_buf, "mc_ctl_buf")
    }
    pub(crate) fn require_ctl_read(&self) -> Result<TypedFunc<(i32, i32), i32>> {
        Self::require(&self.mc_ctl_read, "mc_ctl_read")
    }
    pub(crate) fn require_ctl_write(&self) -> Result<TypedFunc<(i32, i32, i32, i32), i32>> {
        Self::require(&self.mc_ctl_write, "mc_ctl_write")
    }
    pub(crate) fn require_ctl_readdir(&self) -> Result<TypedFunc<(i32, i32), i32>> {
        Self::require(&self.mc_ctl_readdir, "mc_ctl_readdir")
    }
    pub(crate) fn require_ctl_stat(&self) -> Result<TypedFunc<(i32, i32), i32>> {
        Self::require(&self.mc_ctl_stat, "mc_ctl_stat")
    }
    pub(crate) fn require_ctl_mkdir(&self) -> Result<TypedFunc<(i32, i32), i32>> {
        Self::require(&self.mc_ctl_mkdir, "mc_ctl_mkdir")
    }
    pub(crate) fn require_ctl_unlink(&self) -> Result<TypedFunc<(i32, i32), i32>> {
        Self::require(&self.mc_ctl_unlink, "mc_ctl_unlink")
    }
    pub(crate) fn require_ctl_symlink(&self) -> Result<TypedFunc<(i32, i32, i32, i32), i32>> {
        Self::require(&self.mc_ctl_symlink, "mc_ctl_symlink")
    }
    pub(crate) fn require_ctl_mount(&self) -> Result<TypedFunc<(i32, i32, i32), i32>> {
        Self::require(&self.mc_ctl_mount, "mc_ctl_mount")
    }
    pub(crate) fn require_ctl_unmount(&self) -> Result<TypedFunc<(i32, i32), i32>> {
        Self::require(&self.mc_ctl_unmount, "mc_ctl_unmount")
    }
    pub(crate) fn require_ctl_exec_start(&self) -> Result<TypedFunc<i32, i32>> {
        Self::require(&self.mc_ctl_exec_start, "mc_ctl_exec_start")
    }
    pub(crate) fn require_ctl_exec_poll(&self) -> Result<TypedFunc<i32, i32>> {
        Self::require(&self.mc_ctl_exec_poll, "mc_ctl_exec_poll")
    }
    pub(crate) fn require_ctl_exec_close(&self) -> Result<TypedFunc<i32, i32>> {
        Self::require(&self.mc_ctl_exec_close, "mc_ctl_exec_close")
    }
}
