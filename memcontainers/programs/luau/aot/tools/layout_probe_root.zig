//! Link root for the target-compiled Luau layout probe.
//!
//! The observable exports are implemented in C++ because only that boundary may
//! include Luau's private VM headers. This root deliberately contains no runtime.

pub const luau_aot_layout_probe = true;
