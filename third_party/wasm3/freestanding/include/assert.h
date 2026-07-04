#ifndef AGENT_OS_WASM3_ASSERT_H
#define AGENT_OS_WASM3_ASSERT_H

#ifdef NDEBUG
#define assert(expr) ((void)0)
#else
#define assert(expr) ((expr) ? (void)0 : __builtin_trap())
#endif

#endif
