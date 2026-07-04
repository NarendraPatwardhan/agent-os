//! wasm3/raw.zig — the `m3ApiRawFunction` handlers that record a generated `Pending`
//! (ZIG_KERNEL §2.7, §7.1, §4.1).
//!
//! Owns: one raw handler per `mc_sys_*` (generated registration, §5.1). A handler reads
//!   the guest's args with m3ApiGetArg*, bounds-checks every guest pointer with
//!   m3ApiCheckMem (out-of-bounds → errno, never a wasm3 trap that escapes to the host),
//!   records "guest requested syscall X with args Y" as a `Pending`, and returns —
//!   SHALLOW, so no deep frame is live at a suspend (§7.4). Fulfillment happens later in
//!   syscall.zig.
//! Invariants: A4 (adds no imports), §4.3 (guest fault → errno). These handlers are ON
//!   the Asyncify only-list (thin trampoline); syscall.zig fulfillment is OFF it.
//! Consumes: bindings.zig (the C surface), :mc_zig (the `Pending` union + arg structs).
//! Not here: syscall POLICY/fulfillment (syscall.zig); suspend/resume (guest.zig). A raw
//!   handler must NOT decide whether a syscall is permitted or whether to snapshot — it
//!   records and returns (§7.1).
//!
//! Scaffold status: header-only until the wasm3 cherry-pick (§15.5).

// (intentionally empty until //third_party/wasm3 is linked in Phase 5.)
