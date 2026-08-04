#pragma once

// Compiler-lane implementation for the VM materializer. The host capability has no mc imports;
// successful loading executes the callback directly. An exceptional VM path traps the compiler
// invocation and is reported by the host as a failed capability call.

#ifdef __cplusplus
extern "C" {
#endif

static inline int mc_protected_call(void (*callback)(void *), void *context) {
    callback(context);
    return 0;
}

__attribute__((noreturn)) static inline void mc_raise(int status) {
    (void)status;
    __builtin_trap();
}

#ifdef __cplusplus
}
#endif
