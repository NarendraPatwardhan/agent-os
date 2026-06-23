// analysis_eh_shim.h — force-included into every vendored Luau Analysis TU so the
// 80kLOC type checker compiles `-fno-exceptions -fno-rtti` for the wasm guest
// (ctx/LUAU.md §8.6 / PATCHES.md). Three mechanisms:
//
//   * Luau's THROW sites are rewritten (patch 0002) to `mc_analysis_abort(...)`: a
//     noreturn, GRACEFUL exit(70) carrying a CATEGORIZED message — out of memory / time
//     limit / recursion / normalization-complexity limit / internal-compiler-error
//     (ICE) — so a rare non-data failure is diagnosable, never UB or a wrong answer.
//     Type errors in Luau are DATA (CheckResult.errors), not exceptions, so ordinary
//     checking is unaffected and the RESULT is never silently wrong: a throw becomes an
//     abort, never a mis-continue. (In practice these paths are nearly input-unreachable
//     — the constraint solver checks even pathologically deep types lazily; see the
//     loom e2e `luau_analyze_survives_pathological_depth`.)
//   * Luau's TRY/CATCH sites are neutralized by the macros below. This is safe to
//     force-include even before libc++ headers: under -fno-exceptions libc++ emits
//     NO raw `try`/`catch` tokens (they're `#if`'d out behind its own macros), so
//     nothing in the standard library is affected. The one place this elides a REAL
//     recovery is TypeFunctionRuntime's `catch (CompileError&)` (patch 0003): a type
//     function whose BODY fails to compile aborts (categorized ICE) instead of yielding
//     a FailedToCompile diagnostic. Recovering it requires Luau's Compiler error path
//     converted to explicit returns — it cannot be caught under -fno-exceptions — and is
//     deferred: the path needs a type-function body to hit a hard compiler limit, which
//     real type functions never do. Every other elided catch is an ICE/limit re-raise.
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
