// error_channel.h — a kernel-trap-backed replacement for the handful of C++ try/catch/throw sites in
// Luau's Parser and Compiler (was loom/src/mc_eh.h). Stays C++: it is a C++ template included into
// the patched Luau source, so it cannot be Zig — but the unwind it rides on lives in trap.zig.
//
// WHY THIS EXISTS
// --------------
// The Luau guest is built `-fno-exceptions -fno-rtti` (zig's wasm32-wasi libc++ ships no C++
// exception runtime; the kernel's wasmi implements neither the EH proposal nor the setjmp/longjmp it
// needs). So the kernel provides the unwind, via trap.h's mc_protected_call / mc_raise. The
// Parser/Compiler need only carry a C++ error *payload* across that boundary — that's Channel<T>.
//
// CAVEAT (documented, not hidden)
// -------------------------------
// The unwind is a wasm trap, which does not run the C++ destructors of the frames it discards. Luau's
// parser/compiler allocate AST nodes from an arena (Luau::Allocator) that lives in the *catch* frame
// and is freed normally, so the only objects skipped are short-lived STL temporaries on the
// recursive-descent stack — a bounded, one-shot leak on the *error* path (a syntax/compile error),
// reclaimed at process exit (script mode) and bounded by `mc_budget.mem` in the REPL. See
// third_party/luau/PLAN.md.
#pragma once

#include "trap.h"

#include <new>

namespace mc_eh {

// The nonzero code the Parser/Compiler "raise" with. Its value is irrelevant to these channels (they
// read the typed payload, not the code) — they only test whether the protected body raised.
inline constexpr int kRaiseCode = 1;

// A typed error channel: inline storage for one in-flight C++ error payload plus the trap-backed
// raise/catch. Single-threaded wasm guest → one global per type.
template <typename T>
struct Channel {
    alignas(T) unsigned char slot[sizeof(T)];

    // Run `body()` under a kernel trap boundary. Returns true if `body` raised on THIS channel (then
    // call take()), false if it completed normally. The innermost mc_protected_call catches the trap,
    // so nesting matches the original C++ try/catch as long as each raise() is dynamically within run().
    template <typename F>
    bool run(F&& body) {
        Thunk<F> t{&body};
        return mc_protected_call(&Thunk<F>::call, &t) != 0;
    }

    // Raise: copy the payload into the slot, then trap to the nearest run() on this (or any) channel.
    // The matching run() returns true; take() recovers the value.
    [[noreturn]] void raise(const T& value) {
        ::new (static_cast<void*>(slot)) T(value);
        mc_raise(kRaiseCode);
    }

    // Move the payload out of the slot. Call exactly once, in the handler.
    T take() {
        T* p = reinterpret_cast<T*>(slot);
        T value(*p);
        p->~T();
        return value;
    }

private:
    // Adapts a capturing lambda to the `void(void*)` thunk mc_protected_call wants.
    template <typename F>
    struct Thunk {
        F* body;
        static void call(void* p) { (*static_cast<Thunk*>(p)->body)(); }
    };
};

}  // namespace mc_eh
