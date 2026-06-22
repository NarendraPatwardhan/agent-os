// analysis_eh_shim.h — force-included into every vendored Luau Analysis TU so the
// 80kLOC type checker compiles `-fno-exceptions -fno-rtti` for the wasm guest
// (ctx/LUAU.md §8.6 / PATCHES.md). Three mechanisms:
//
//   * Luau's THROW sites are sed-rewritten to `mc_analysis_abort(...)` (a noreturn
//     graceful exit). Type errors in Luau are DATA (CheckResult.errors), not
//     exceptions — only internal/resource-limit conditions throw — so ordinary
//     type checking is unaffected; only pathological inputs (deep-recursion / ICE)
//     abort instead of degrading. Documented, not hidden.
//   * Luau's TRY/CATCH sites are neutralized by the macros below. This is safe to
//     force-include even before libc++ headers: under -fno-exceptions libc++ emits
//     NO raw `try`/`catch` tokens (they're `#if`'d out behind its own macros), so
//     nothing in the standard library is affected.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif
// Print `what` to stderr and exit non-zero. Defined in luau_analyze.cpp.
__attribute__((noreturn)) void mc_analysis_abort(const char* what);
#ifdef __cplusplus
}
#endif

// Neutralize the handful of try/catch sites (all but a few catch NO variable; the
// few named ones are hand-patched to not reference it — see PATCHES.md).
#define try if (true)
#define catch(...) else if (false)

#ifdef __cplusplus
// No-op std::mutex/condition_variable/lock stand-ins. Zig's wasm32-wasi libc++ is
// single-threaded (no std::mutex etc.); the only uses are in Frontend's PARALLEL
// module-check path, which luau-analyze never takes (it checks one file
// synchronously). The `std::` uses in Frontend.{h,cpp} are redirected here; these
// only need to TYPE-CHECK. (std::atomic works on wasm and is left alone.)
namespace mc_nothread {
struct mutex {
    void lock() {}
    void unlock() {}
    bool try_lock() { return true; }
};
struct condition_variable {
    template <class L>
    void wait(L&) {}
    template <class L, class P>
    void wait(L&, P) {}
    void notify_one() {}
    void notify_all() {}
};
struct scoped_lock {
    template <class... A>
    explicit scoped_lock(A&&...) {}
};
struct unique_lock {
    unique_lock() = default;
    template <class... A>
    explicit unique_lock(A&&...) {}
    void lock() {}
    void unlock() {}
};
}  // namespace mc_nothread
// Frontend's one std::mutex use is redirected to mc_nothread::mutex by 0004-mc-frontend-nothread.patch
// (a proper upstream patch, B3 — not a using-declaration into namespace std, which is UB).
#endif
