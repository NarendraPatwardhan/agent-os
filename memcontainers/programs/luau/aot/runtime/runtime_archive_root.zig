//! Root module required by rules_zig's static-library rule.
//!
//! Runtime behavior lives in retained Luau C++ translation units and small pin adapters until the
//! generated-function dispatcher is implemented in Zig. Keeping this module empty also makes the
//! archive's language boundary visible in its member inventory.
