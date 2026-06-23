// force_extern_c.h — force-included (copts -include) into every Luau C++ TU so Luau's public C API
// gets `extern "C"` linkage. The Zig entry/bindings @cImport the headers in C mode (translate-c
// can't parse Luau's C++-tainted internal headers), producing UNMANGLED symbol references; without
// this the Luau definitions are C++-mangled (_Z…) and don't link → the API resolves to bogus `env`
// imports and the whole VM is dead-stripped. LUA_API / LUACODE_API are #ifndef-guarded so these
// pre-definitions win; LUALIB_API derives from LUA_API. See third_party/luau/SYSTEM.md.
#pragma once
#define LUA_API extern "C"
#define LUACODE_API extern "C"
