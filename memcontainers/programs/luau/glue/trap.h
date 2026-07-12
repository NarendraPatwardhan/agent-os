// trap.h — the kernel-backed protected-call + raise primitives that stand in for C++ exceptions /
// setjmp-longjmp in the Luau guest. This is the C declaration; trap.zig implements them (the
// C/C++ → Zig rewrite described in third_party/luau/SYSTEM.md). The guest is built
// `-fno-exceptions -fno-rtti` and runs under
// wasmi, which has neither the C++ exception runtime nor the wasm exception-handling proposal that
// setjmp/longjmp require. The kernel supplies the unwind instead, via two `mc` syscalls
// (SYSTEMS.md §10.3):
//
//   mc_protected_call(fn, ud)  runs fn(ud) as a NESTED guest call — a trap boundary. Returns 0 if
//                              fn returned normally, or the code passed to mc_raise() if it "threw".
//   mc_raise(code)             records `code` then traps; wasmi unwinds the native stack to the
//                              nearest mc_protected_call boundary. Never returns.
//
// Consumers: the patched VM `ldo.cpp` (luaD_rawrunprotected → mc_protected_call, luaD_throw →
// mc_raise) and error_channel.h's Channel<T>. See third_party/luau/SYSTEM.md.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int mc_protected_call(void (*fn)(void *), void *ud);

__attribute__((noreturn)) void mc_raise(int code);

#ifdef __cplusplus
}
#endif
