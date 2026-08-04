#pragma once

// The host compiler is a zero-import Wasm capability and cannot use AgentOS guest trap imports.
// Ordinary Luau syntax errors are returned by luau_compile. The pinned wasm32 toolchain cannot
// catch Luau's exceptional deep-limit path without Wasm EH, so preserve its message and trap; the
// host treats that trap as a failed compiler invocation and can read the sticky diagnostic from a
// fresh/recovered instance. This is an explicit pin limitation, not target-guest behavior.

#include <new>
#include <string.h>

namespace mc_eh {

inline char g_sticky_raise[1024] = {};
inline size_t g_sticky_raise_len = 0;

inline void stickyStore(const char *message) {
    if (!message)
        message = "Luau frontend raised";

    size_t size = 0;
    while (message[size] && size + 1 < sizeof(g_sticky_raise))
        ++size;

    memcpy(g_sticky_raise, message, size);
    g_sticky_raise[size] = '\0';
    g_sticky_raise_len = size;
}

template <typename T> struct Channel {
    alignas(T) unsigned char storage[sizeof(T)];
    bool hasPayload = false;

    template <typename F> bool run(F &&body) {
        body();
        return false;
    }

    [[noreturn]] void raise(const T &value) {
        if (hasPayload)
            reinterpret_cast<T *>(storage)->~T();

        ::new (static_cast<void *>(storage)) T(value);
        hasPayload = true;
        stickyStore(value.what());
        __builtin_trap();
    }

    T take() {
        T *payload = reinterpret_cast<T *>(storage);
        T value(*payload);
        payload->~T();
        hasPayload = false;
        return value;
    }
};

} // namespace mc_eh
