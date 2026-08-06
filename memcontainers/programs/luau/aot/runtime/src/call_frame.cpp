// Strict-AOT replacement for the generic call-frame operations currently co-located with Luau's
// bytecode dispatch loop in lvmexecute.cpp. Keep this file pin-sized and mechanically comparable
// with upstream 0.725; generated execution and continuations belong to the Zig runtime/backend.

#include "aot_runtime_v1.h"

#include "lvm.h"

#include "ldebug.h"
#include "ldo.h"
#include "lfunc.h"
#include "lgc.h"
#include "lmem.h"
#include "lstate.h"
#include "lstring.h"
#include "lualib.h"

#include <limits.h>
#include <string.h>

static_assert(MC_LUAU_AOT_V1_MULTRET == LUA_MULTRET, "Luau MULTRET sentinel drift");

// These flag definitions live in lvmexecute.cpp upstream even though retained runtime sources use
// them. The strict archive excludes that translation unit, so the pin adapter owns the definitions.
LUAU_FASTFLAGVARIABLE(LuauDirectFieldGet)
LUAU_FLAGVERSION(LuauDirectFieldGet, 2)
LUAU_FASTFLAGVARIABLE(LuauClosureUsageCounter)
LUAU_FASTFLAGVARIABLE(LuauUdataDirectAccess6)
LUAU_FASTFLAGVARIABLE(DebugLuauUserDefinedClassesRuntime)
LUAU_FASTFLAGVARIABLE(LuauYieldIter2)

LUAU_NOINLINE void luau_callhook(lua_State *L, lua_Hook hook, void *userdata) {
    ptrdiff_t base = savestack(L, L->base);
    ptrdiff_t top = savestack(L, L->top);
    ptrdiff_t ci_top = savestack(L, L->ci->top);
    int status = L->status;

    // A hook invoked externally on a paused thread must be able to make ordinary Luau calls.
    if (status == LUA_YIELD || status == LUA_BREAK) {
        L->status = 0;
        L->base = L->ci->base;
    }

    // AOT frames deliberately have no bytecode pc to advance or translate into a source line.
    // Source IDs enter this ABI with the generated-function continuation protocol; until then the
    // hook receives -1, never a fabricated or dereferenced bytecode location.
    luaD_checkstack(L, LUA_MINSTACK);
    L->ci->top = L->top + LUA_MINSTACK;
    LUAU_ASSERT(L->ci->top <= L->stack_last);

    lua_Debug ar;
    ar.currentline = -1;
    ar.userdata = userdata;

    hook(L, &ar);

    L->ci->top = restorestack(L, ci_top);
    L->top = restorestack(L, top);

    // Restore a pre-existing paused state only when the hook did not establish the same state.
    if (status == LUA_YIELD && L->status != LUA_YIELD) {
        L->status = LUA_YIELD;
        L->base = restorestack(L, base);
    } else if (status == LUA_BREAK) {
        LUAU_ASSERT(L->status != LUA_BREAK);
        L->status = LUA_BREAK;
        L->base = restorestack(L, base);
    }
}

int luau_precall(lua_State *L, StkId func, int nresults) {
    if (!ttisfunction(func)) {
        luaV_tryfuncTM(L, func);
        // L->top is incremented by tryfuncTM.
    }

    Closure *ccl = clvalue(func);

    // The first oracle uses a layout-compatible Proto as immutable AOT metadata. Reject both
    // bytecode-bearing closures and missing AOT metadata before installing a Lua CallInfo: the
    // ordinary Luau error formatter may inspect the active caller's savedpc while raising.
    if (!ccl->isC) {
        Proto *p = ccl->l.p;

        if (p->code != nullptr || p->codeentry != nullptr || p->sizecode != 0)
            luaG_runerror(L, "strict AOT runtime rejected a bytecode-bearing Luau closure");

        if (p->execdata == nullptr)
            luaG_runerror(L, "strict AOT runtime has no compiled entry for Luau closure");

        if (p->source == nullptr)
            luaG_runerror(L, "strict AOT runtime has no source metadata for Luau closure");
    }

    CallInfo *ci = incr_ci(L);
    ci->func = func;
    ci->base = func + 1;
    ci->top = L->top + ccl->stacksize;
    ci->savedpc = nullptr;
    ci->flags = 0;
    ci->nresults = nresults;
    if (FFlag::LuauClosureUsageCounter)
        ccl->usage++;

    L->base = ci->base;
    // Note: L->top is assigned externally.

    luaD_checkstackfornewci(L, ccl->stacksize);
    LUAU_ASSERT(ci->top <= L->stack_last);

    if (!ccl->isC) {
        Proto *p = ccl->l.p;

        // Fill unused parameters with nil exactly as the interpreter does. Proto is retained only
        // for non-executable frame metadata at this stage (parameters, varargs, stack size, etc.).
        StkId argi = L->top;
        StkId argend = L->base + p->numparams;
        while (argi < argend)
            setnilvalue(argi++);
        L->top = p->is_vararg ? argi : ci->top;

        // AOT frames have no bytecode program counter. Native marks the frame as opaque to APIs
        // that would otherwise expose or mutate interpreter registers and locals.
        ci->savedpc = nullptr;
        ci->flags = LUA_CALLINFO_NATIVE;

        return PCRLUA;
    } else {
        lua_CFunction cfunc = ccl->c.f;
        int n = cfunc(L);

        // A negative C result is Luau's yield convention; leave the frame installed for resume.
        if (n < 0)
            return PCRYIELD;

        // ci is our callinfo, cip is our parent.
        CallInfo *ci = L->ci;
        CallInfo *cip = ci - 1;

        if (FFlag::LuauClosureUsageCounter) {
            LUAU_ASSERT(ccl->usage > 0);
            ccl->usage--;
        }

        // Copy return values into the parent stack, bounded by its requested result count, and
        // fill any missing fixed results with nil. LUA_MULTRET is represented by a negative count.
        StkId res = ci->func;
        StkId vali = L->top - n;
        StkId valend = L->top;

        int i;
        for (i = nresults; i != 0 && vali < valend; i--)
            setobj2s(L, res++, vali++);
        while (i-- > 0)
            setnilvalue(res++);

        L->ci = cip;
        L->base = cip->base;
        L->top = res;

        return PCRC;
    }
}

void luau_poscall(lua_State *L, StkId first) {
    // Finish a compiled Luau call. This body is the generic result/frame portion of upstream
    // luau_poscall; it contains no instruction decode or interpreter re-entry.
    CallInfo *ci = L->ci;
    CallInfo *cip = ci - 1;

    if (FFlag::LuauClosureUsageCounter) {
        LUAU_ASSERT(clvalue(ci->func)->usage > 0);
        clvalue(ci->func)->usage--;
    }

    StkId res = ci->func;
    StkId vali = first;
    StkId valend = L->top;

    int i;
    for (i = ci->nresults; i != 0 && vali < valend; i--)
        setobj2s(L, res++, vali++);
    while (i-- > 0)
        setnilvalue(res++);

    L->ci = cip;
    L->base = cip->base;
    L->top = (ci->nresults == LUA_MULTRET) ? res : cip->top;
}

extern "C" const uint8_t mc_luau_aot_v1_layout_sha256[32] = {
    0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
    0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
};

static bool validAotProto(const McLuauAotProtoV1 *metadata);
static char moduleRegistryKey;

enum ModuleInitializationState {
    MODULE_UNINITIALIZED = 0,
    MODULE_INITIALIZING = 1,
    MODULE_INITIALIZED = 2,
    MODULE_FAILED = 3,
};

extern "C" void mc_luau_aot_v1_return(lua_State *L, uint32_t sourceRegister, int32_t resultCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT return helper entered without an active Luau frame");
    if (resultCount < MC_LUAU_AOT_V1_MULTRET)
        luaG_runerror(L, "strict AOT return helper rejected result count %d", resultCount);

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (sourceRegister > proto->maxstacksize)
        luaG_runerror(L, "strict AOT return source is outside the compiled frame");

    uint32_t actualResultCount;
    if (resultCount == MC_LUAU_AOT_V1_MULTRET) {
        StkId first = L->base + sourceRegister;
        if (first > L->top)
            luaG_runerror(L, "strict AOT dynamic return starts above the live stack top");
        ptrdiff_t count = L->top - first;
        if (uint64_t(count) > UINT32_MAX)
            luaG_runerror(L, "strict AOT dynamic return count exceeds the ABI limit");
        actualResultCount = uint32_t(count);
    } else {
        actualResultCount = uint32_t(resultCount);
        if (actualResultCount > uint32_t(proto->maxstacksize) - sourceRegister)
            luaG_runerror(L, "strict AOT fixed return exceeds the compiled frame");
    }

    // A compiled return must never leave UpVal::v pointing into the frame that poscall will pop.
    // Exact CLOSE_UPVALS commands still lower independently for lexical scopes that end earlier.
    if (L->openupval && L->openupval->v >= L->base)
        luaF_close(L, L->base);

    // Poscall consumes results from frame base. Copy low-to-high: the destination never starts
    // above the source, so this also has correct memmove semantics for overlapping register ranges.
    for (uint32_t index = 0; index < actualResultCount; ++index)
        setobj2s(L, L->base + index, L->base + sourceRegister + index);
    L->top = L->base + actualResultCount;
}

extern "C" uint32_t mc_luau_aot_v1_interrupt(lua_State *L, uint32_t pc) {
    // FrontendSnapshotV1 carries the bytecode pc for source-map/continuation work, but strict AOT
    // Protos deliberately carry no bytecode array from which savedpc could be constructed. Keep the
    // value in the ABI now without fabricating a pointer; native-frame debug handling already
    // treats this frame as opaque. The callback can reallocate the stack, so generated code reloads
    // L->base after every successful return from this helper.
    (void)pc;
    if (!L || !L->ci || !isLua(L->ci))
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;

    void (*interrupt)(lua_State *, int) = L->global->cb.interrupt;
    if (!interrupt)
        return MC_LUAU_AOT_V1_OK;

    interrupt(L, -1);
    return L->status == 0 ? MC_LUAU_AOT_V1_OK : MC_LUAU_AOT_V1_YIELDED;
}

extern "C" void mc_luau_aot_v1_do_arith(lua_State *L, uint32_t destinationRegister,
                                        uint32_t lhsRegister, uint32_t rhsRegister,
                                        uint32_t operation) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT arithmetic helper entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (destinationRegister >= proto->maxstacksize || lhsRegister >= proto->maxstacksize ||
        rhsRegister >= proto->maxstacksize)
        luaG_runerror(L, "strict AOT arithmetic helper register is outside the compiled frame");

    switch (operation) {
    case MC_LUAU_AOT_ARITH_V1_ADD:
        luaV_doarithimpl<TM_ADD>(L, L->base + destinationRegister, L->base + lhsRegister,
                                 L->base + rhsRegister);
        return;
    case MC_LUAU_AOT_ARITH_V1_SUB:
        luaV_doarithimpl<TM_SUB>(L, L->base + destinationRegister, L->base + lhsRegister,
                                 L->base + rhsRegister);
        return;
    case MC_LUAU_AOT_ARITH_V1_MUL:
        luaV_doarithimpl<TM_MUL>(L, L->base + destinationRegister, L->base + lhsRegister,
                                 L->base + rhsRegister);
        return;
    case MC_LUAU_AOT_ARITH_V1_DIV:
        luaV_doarithimpl<TM_DIV>(L, L->base + destinationRegister, L->base + lhsRegister,
                                 L->base + rhsRegister);
        return;
    case MC_LUAU_AOT_ARITH_V1_IDIV:
        luaV_doarithimpl<TM_IDIV>(L, L->base + destinationRegister, L->base + lhsRegister,
                                  L->base + rhsRegister);
        return;
    case MC_LUAU_AOT_ARITH_V1_MOD:
        luaV_doarithimpl<TM_MOD>(L, L->base + destinationRegister, L->base + lhsRegister,
                                 L->base + rhsRegister);
        return;
    case MC_LUAU_AOT_ARITH_V1_POW:
        luaV_doarithimpl<TM_POW>(L, L->base + destinationRegister, L->base + lhsRegister,
                                 L->base + rhsRegister);
        return;
    case MC_LUAU_AOT_ARITH_V1_UNM:
        luaV_doarithimpl<TM_UNM>(L, L->base + destinationRegister, L->base + lhsRegister,
                                 L->base + rhsRegister);
        return;
    default:
        luaG_runerror(L, "strict AOT arithmetic helper rejected operation %u", operation);
    }
}

extern "C" uint32_t mc_luau_aot_v1_compare_any(lua_State *L, uint32_t lhsRegister,
                                               uint32_t rhsRegister, uint32_t operation) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT comparison helper entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (lhsRegister >= proto->maxstacksize || rhsRegister >= proto->maxstacksize)
        luaG_runerror(L, "strict AOT comparison helper register is outside the compiled frame");

    const TValue *lhs = L->base + lhsRegister;
    const TValue *rhs = L->base + rhsRegister;
    switch (operation) {
    case MC_LUAU_AOT_COMPARE_V1_EQUAL:
        return ttype(lhs) == ttype(rhs) && luaV_equalval(L, lhs, rhs);
    case MC_LUAU_AOT_COMPARE_V1_LESS:
        return luaV_lessthan(L, lhs, rhs);
    case MC_LUAU_AOT_COMPARE_V1_LESS_EQUAL:
        return luaV_lessequal(L, lhs, rhs);
    default:
        luaG_runerror(L, "strict AOT comparison helper rejected operation %u", operation);
    }
}

static Proto *findDirectAotChild(Proto *parent, uint32_t childProtoId) {
    for (int index = 0; index < parent->sizep; ++index) {
        Proto *candidate = parent->p[index];
        const McLuauAotProtoV1 *metadata =
            candidate ? static_cast<const McLuauAotProtoV1 *>(candidate->execdata) : nullptr;
        if (metadata && metadata->function_id == childProtoId)
            return candidate;
    }
    return nullptr;
}

extern "C" void mc_luau_aot_v1_dupclosure(lua_State *L, uint32_t destinationRegister,
                                          uint32_t childProtoId) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT closure helper entered without an active Luau frame");

    Closure *parentClosure = clvalue(L->ci->func);
    Proto *parent = parentClosure->l.p;
    if (destinationRegister >= parent->maxstacksize)
        luaG_runerror(L, "strict AOT closure destination is outside the compiled frame");

    Proto *child = findDirectAotChild(parent, childProtoId);
    if (!child)
        luaG_runerror(L, "strict AOT closure helper rejected non-child Proto %u", childProtoId);
    if (child->nups != 0)
        luaG_runerror(L, "strict AOT DUPCLOSURE does not support captured upvalues");

    // The active parent closure roots the published Proto graph. Run incremental GC before the
    // allocation, gray a black thread, then make the new white Closure visible in its VM register.
    luaC_checkGC(L);
    luaC_threadbarrier(L);
    Closure *closure = luaF_newLclosure(L, 0, parentClosure->env, child);
    setclvalue(L, L->base + destinationRegister, closure);
    if (L->top <= L->base + destinationRegister)
        L->top = L->base + destinationRegister + 1;
}

extern "C" void mc_luau_aot_v1_newclosure_value(lua_State *L, uint32_t destinationRegister,
                                                uint32_t childProtoId, uint32_t captureRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT value-closure helper entered without an active Luau frame");

    Closure *parentClosure = clvalue(L->ci->func);
    Proto *parent = parentClosure->l.p;
    if (destinationRegister >= parent->maxstacksize || captureRegister >= parent->maxstacksize)
        luaG_runerror(L, "strict AOT value-closure register is outside the compiled frame");

    Proto *child = findDirectAotChild(parent, childProtoId);
    if (!child)
        luaG_runerror(L, "strict AOT value-closure helper rejected non-child Proto %u",
                      childProtoId);
    if (child->nups != 1)
        luaG_runerror(L, "strict AOT value-closure helper requires exactly one child upvalue");

    // luaF_newLclosure does not step GC. Preserve the captured value before publishing into a
    // possibly identical register, gray a black thread, root the new closure, initialize its sole
    // direct-value upref, and only then honor upstream NEWCLOSURE's trailing CHECK_GC safepoint.
    TValue captured;
    setobj(L, &captured, L->base + captureRegister);
    luaC_threadbarrier(L);
    Closure *closure = luaF_newLclosure(L, 1, parentClosure->env, child);
    setclvalue(L, L->base + destinationRegister, closure);
    if (L->top <= L->base + destinationRegister)
        L->top = L->base + destinationRegister + 1;
    setobj(L, &closure->l.uprefs[0], &captured);
    luaC_checkGC(L);
}

extern "C" void mc_luau_aot_v1_newclosure_ref(lua_State *L, uint32_t destinationRegister,
                                              uint32_t childProtoId, uint32_t captureRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L,
                      "strict AOT reference-closure helper entered without an active Luau frame");

    Closure *parentClosure = clvalue(L->ci->func);
    Proto *parent = parentClosure->l.p;
    if (destinationRegister >= parent->maxstacksize || captureRegister >= parent->maxstacksize ||
        destinationRegister == captureRegister)
        luaG_runerror(L, "strict AOT reference-closure register is outside the compiled frame");

    Proto *child = findDirectAotChild(parent, childProtoId);
    if (!child)
        luaG_runerror(L, "strict AOT reference-closure helper rejected non-child Proto %u",
                      childProtoId);
    if (child->nups != 1)
        luaG_runerror(L, "strict AOT reference-closure helper requires exactly one child upvalue");

    // Match upstream NEWCLOSURE/LCT_REF order: publish the closure first, intern the open UpVal for
    // the live stack cell, initialize the tagged upref, then honor the trailing GC safepoint.
    luaC_threadbarrier(L);
    Closure *closure = luaF_newLclosure(L, 1, parentClosure->env, child);
    setclvalue(L, L->base + destinationRegister, closure);
    if (L->top <= L->base + destinationRegister)
        L->top = L->base + destinationRegister + 1;
    setupvalue(L, &closure->l.uprefs[0], luaF_findupval(L, L->base + captureRegister));
    luaC_checkGC(L);
}

extern "C" void mc_luau_aot_v1_get_upvalue(lua_State *L, uint32_t destinationRegister,
                                           uint32_t upvalueIndex) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT upvalue helper entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (destinationRegister >= proto->maxstacksize || upvalueIndex >= proto->nups ||
        upvalueIndex >= closure->nupvalues)
        luaG_runerror(L, "strict AOT upvalue access is outside the compiled closure");
    TValue *upvalueRef = &closure->l.uprefs[upvalueIndex];
    const TValue *value = upvalueRef;
    if (ttype(upvalueRef) == LUA_TUPVAL)
        value = upvalue(upvalueRef)->v;

    setobj2s(L, L->base + destinationRegister, value);
}

extern "C" void mc_luau_aot_v1_set_upvalue(lua_State *L, uint32_t upvalueIndex,
                                           uint32_t sourceRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT upvalue mutation entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (sourceRegister >= proto->maxstacksize || upvalueIndex >= proto->nups ||
        upvalueIndex >= closure->nupvalues)
        luaG_runerror(L, "strict AOT upvalue mutation is outside the compiled closure");
    TValue *upvalueRef = &closure->l.uprefs[upvalueIndex];
    if (ttype(upvalueRef) != LUA_TUPVAL)
        luaG_runerror(L, "strict AOT upvalue mutation requires a reference capture");

    UpVal *cell = upvalue(upvalueRef);
    setobj(L, cell->v, L->base + sourceRegister);
    luaC_barrier(L, cell, L->base + sourceRegister);
}

extern "C" void mc_luau_aot_v1_close_upvalues(lua_State *L, uint32_t firstRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT upvalue close entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (firstRegister >= proto->maxstacksize)
        luaG_runerror(L, "strict AOT upvalue close is outside the compiled frame");

    StkId first = L->base + firstRegister;
    if (L->openupval && L->openupval->v >= first)
        luaF_close(L, first);
}

extern "C" uint32_t mc_luau_aot_v1_call(lua_State *L, uint32_t functionRegister,
                                        int32_t parameterCount, int32_t resultCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT call helper entered without an active Luau frame");
    if (parameterCount < MC_LUAU_AOT_V1_MULTRET || resultCount < MC_LUAU_AOT_V1_MULTRET)
        luaG_runerror(L, "strict AOT call rejected %d parameters and %d results", parameterCount,
                      resultCount);

    Closure *caller = clvalue(L->ci->func);
    Proto *callerProto = caller->l.p;
    if (functionRegister >= callerProto->maxstacksize)
        luaG_runerror(L, "strict AOT call target is outside the compiled caller frame");

    StkId function = L->base + functionRegister;
    if (parameterCount == MC_LUAU_AOT_V1_MULTRET) {
        if (L->top < function + 1)
            luaG_runerror(L, "strict AOT dynamic call starts above the live stack top");
    } else if (uint32_t(parameterCount) >= uint32_t(callerProto->maxstacksize) - functionRegister) {
        luaG_runerror(L, "strict AOT fixed call arguments exceed the compiled caller frame");
    }
    if (resultCount != MC_LUAU_AOT_V1_MULTRET &&
        uint32_t(resultCount) > uint32_t(callerProto->maxstacksize) - functionRegister)
        luaG_runerror(L, "strict AOT fixed call results exceed the compiled caller frame");

    if (!ttisfunction(function) || clvalue(function)->isC)
        luaG_runerror(L, "strict AOT call requires a compiled Luau closure");
    Closure *callee = clvalue(function);
    const McLuauAotProtoV1 *metadata =
        callee->l.p ? static_cast<const McLuauAotProtoV1 *>(callee->l.p->execdata) : nullptr;
    if (!validAotProto(metadata))
        luaG_runerror(L, "strict AOT call rejected missing callee metadata");
    if (callee->nupvalues != metadata->nups)
        luaG_runerror(L, "strict AOT call rejected callee closure shape");

    // A dynamic call consumes the exact live range established by a preceding multi-return
    // operation. Fixed calls cut L->top back to their declared arguments so unrelated registers do
    // not become accidental arguments. luau_precall fills missing fixed parameters with nil.
    if (parameterCount != MC_LUAU_AOT_V1_MULTRET)
        L->top = function + parameterCount + 1;
    if (luau_precall(L, function, resultCount) != PCRLUA)
        luaG_runerror(L, "strict AOT call rejected non-Luau callee dispatch");

    const uint32_t status = metadata->entry(L, metadata);
    switch (status) {
    case MC_LUAU_AOT_V1_OK:
        luau_poscall(L, L->base);
        return MC_LUAU_AOT_V1_OK;
    case MC_LUAU_AOT_V1_UNSUPPORTED_TYPE:
        luaG_runerror(L, "strict AOT nested numeric tier received an unsupported value type");
    case MC_LUAU_AOT_V1_YIELDED:
        luaG_runerror(L, "strict AOT nested call yielded without a continuation contract");
    default:
        luaG_runerror(L, "strict AOT nested function returned invalid status %u", status);
    }
}

extern "C" void mc_luau_aot_v1_prep_varargs(lua_State *L, uint32_t fixedParameterCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT PREPVARARGS entered without an active Luau frame");

    CallInfo *ci = L->ci;
    Closure *closure = clvalue(ci->func);
    Proto *proto = closure->l.p;
    if (!proto->is_vararg || fixedParameterCount != proto->numparams || ci->base != ci->func + 1 ||
        L->top < ci->base + fixedParameterCount)
        luaG_runerror(L, "strict AOT PREPVARARGS rejected the active frame shape");

    // Match LOP_PREPVARARGS: reserve the relocated frame first, then reload every stack pointer
    // because luaD_checkstack may move the stack. The original argument range remains rooted.
    luaD_checkstack(L, int(closure->stacksize) + int(fixedParameterCount));
    ci = L->ci;
    StkId fixed = ci->base;
    StkId relocated = L->top;
    for (uint32_t index = 0; index < fixedParameterCount; ++index) {
        setobj2s(L, relocated + index, fixed + index);
        setnilvalue(fixed + index);
    }

    ci->base = relocated;
    ci->top = relocated + closure->stacksize;
    L->base = relocated;
    L->top = ci->top;
}

static uint32_t varargCount(lua_State *L, Proto *proto) {
    ptrdiff_t count = L->base - L->ci->func - proto->numparams - 1;
    if (count < 0 || uint64_t(count) > UINT32_MAX)
        luaG_runerror(L, "strict AOT GETVARARGS rejected the active frame shape");
    return uint32_t(count);
}

extern "C" void mc_luau_aot_v1_get_varargs_fixed(lua_State *L, uint32_t destinationRegister,
                                                 uint32_t resultCount) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT GETVARARGS entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (!proto->is_vararg || destinationRegister > proto->maxstacksize ||
        resultCount > uint32_t(proto->maxstacksize) - destinationRegister)
        luaG_runerror(L, "strict AOT fixed GETVARARGS exceeds the compiled frame");

    uint32_t count = varargCount(L, proto);
    uint32_t copied = count < resultCount ? count : resultCount;
    StkId source = L->base - count;
    for (uint32_t index = 0; index < copied; ++index)
        setobj2s(L, L->base + destinationRegister + index, source + index);
    for (uint32_t index = copied; index < resultCount; ++index)
        setnilvalue(L->base + destinationRegister + index);
}

extern "C" void mc_luau_aot_v1_get_varargs_multret(lua_State *L, uint32_t destinationRegister) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT GETVARARGS entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    if (!proto->is_vararg || destinationRegister > proto->maxstacksize)
        luaG_runerror(L, "strict AOT dynamic GETVARARGS starts outside the compiled frame");

    uint32_t count = varargCount(L, proto);
    if (count > INT_MAX)
        luaG_runerror(L, "strict AOT dynamic GETVARARGS count exceeds the runtime limit");

    // Match LOP_GETVARARGS B=0. Stack growth can relocate both the vararg source and destination,
    // so compute the count first and reload all pointers afterward.
    luaD_checkstack(L, int(count));
    StkId source = L->base - count;
    StkId destination = L->base + destinationRegister;
    for (uint32_t index = 0; index < count; ++index)
        setobj2s(L, destination + index, source + index);
    L->top = destination + count;
}

static bool pushModuleRecord(lua_State *L, uint32_t moduleId) {
    lua_pushlightuserdata(L, &moduleRegistryKey);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return false;
    }

    lua_rawgeti(L, -1, 0);
    int moduleCount = lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (moduleCount < 0 || moduleId >= uint32_t(moduleCount)) {
        lua_pop(L, 1);
        return false;
    }

    lua_rawgeti(L, -1, int(moduleId) + 1);
    lua_remove(L, -2);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return false;
    }
    return true;
}

static int moduleRecordStatus(lua_State *L, int recordIndex) {
    lua_rawgeti(L, recordIndex, 2);
    int isNumber = 0;
    int status = lua_tointegerx(L, -1, &isNumber);
    lua_pop(L, 1);
    return isNumber ? status : -1;
}

static void setModuleRecordStatus(lua_State *L, int recordIndex, int status) {
    lua_pushinteger(L, status);
    lua_rawseti(L, recordIndex, 2);
}

static void setModuleRecordValue(lua_State *L, int recordIndex, int valueIndex) {
    lua_pushvalue(L, valueIndex);
    lua_rawseti(L, recordIndex, 3);
}

extern "C" uint32_t mc_luau_aot_v1_require_static(lua_State *L, uint32_t destinationRegister,
                                                  uint32_t targetModuleId) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT static require entered without an active Luau frame");

    Closure *caller = clvalue(L->ci->func);
    Proto *callerProto = caller->l.p;
    if (destinationRegister >= callerProto->maxstacksize)
        luaG_runerror(L, "strict AOT static require destination is outside the compiled frame");
    if (!lua_checkstack(L, 8))
        luaG_runerror(L, "strict AOT static require could not reserve runtime stack space");

    const int originalTop = lua_gettop(L);
    if (!pushModuleRecord(L, targetModuleId))
        luaG_runerror(L, "strict AOT static require rejected module %u", targetModuleId);
    const int recordIndex = lua_gettop(L);
    int status = moduleRecordStatus(L, recordIndex);

    if (status == MODULE_INITIALIZED) {
        lua_rawgeti(L, recordIndex, 3);
        setobj2s(L, L->base + destinationRegister, L->top - 1);
        lua_settop(L, originalTop);
        return MC_LUAU_AOT_V1_OK;
    }
    if (status == MODULE_FAILED) {
        lua_rawgeti(L, recordIndex, 3);
        const char *message = lua_tostring(L, -1);
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u initialization failed: %s", targetModuleId,
                      message ? message : "unknown error");
    }
    if (status == MODULE_INITIALIZING) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT static require cycle reached module %u", targetModuleId);
    }
    if (status != MODULE_UNINITIALIZED) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u has invalid initialization state", targetModuleId);
    }

    lua_rawgeti(L, recordIndex, 1);
    if (!lua_isfunction(L, -1) || clvalue(L->top - 1)->isC) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u has no compiled root closure", targetModuleId);
    }
    Proto *moduleProto = clvalue(L->top - 1)->l.p;
    const McLuauAotProtoV1 *metadata =
        moduleProto ? static_cast<const McLuauAotProtoV1 *>(moduleProto->execdata) : nullptr;
    if (!validAotProto(metadata)) {
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u root metadata is invalid", targetModuleId);
    }

    setModuleRecordStatus(L, recordIndex, MODULE_INITIALIZING);

    // Match the pinned module loader's isolation without loading source or bytecode. The thread is
    // rooted on the requiring state while the module closure executes through ldo's strict AOT
    // gate.
    lua_State *globalThread = lua_mainthread(L);
    lua_State *moduleThread = lua_newthread(globalThread);
    lua_xmove(globalThread, L, 1);
    luaL_sandboxthread(moduleThread);
    if (!lua_checkstack(moduleThread, 1)) {
        setModuleRecordStatus(L, recordIndex, MODULE_FAILED);
        lua_pushliteral(L, "could not reserve module thread stack space");
        setModuleRecordValue(L, recordIndex, -1);
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u could not reserve runtime stack space",
                      targetModuleId);
    }

    luaC_threadbarrier(moduleThread);
    Closure *moduleClosure = luaF_newLclosure(moduleThread, 0, moduleThread->gt, moduleProto);
    setclvalue(moduleThread, moduleThread->top, moduleClosure);
    moduleThread->top++;

    int resumeStatus = lua_resume(moduleThread, L, 0);
    if (resumeStatus != LUA_OK || lua_gettop(moduleThread) != 1) {
        const char *message = resumeStatus == LUA_YIELD
                                  ? "module yielded without a continuation contract"
                              : resumeStatus == LUA_OK ? "module must return a single value"
                                                       : lua_tostring(moduleThread, -1);
        lua_pushstring(L, message ? message : "unknown module error");
        setModuleRecordValue(L, recordIndex, -1);
        setModuleRecordStatus(L, recordIndex, MODULE_FAILED);
        const char *cachedMessage = lua_tostring(L, -1);
        lua_settop(L, originalTop);
        luaG_runerror(L, "strict AOT module %u initialization failed: %s", targetModuleId,
                      cachedMessage ? cachedMessage : "unknown error");
    }

    lua_xmove(moduleThread, L, 1);
    setModuleRecordValue(L, recordIndex, -1);
    setModuleRecordStatus(L, recordIndex, MODULE_INITIALIZED);
    setobj2s(L, L->base + destinationRegister, L->top - 1);
    lua_settop(L, originalTop);
    return MC_LUAU_AOT_V1_OK;
}

static void destroyAotProto(lua_State *, Proto *proto) {
    // AOT metadata is immutable linker-owned data, not a heap allocation owned by Proto.
    proto->execdata = nullptr;
}

static bool validAotProto(const McLuauAotProtoV1 *metadata) {
    return metadata && metadata->abi_version == MC_LUAU_AOT_ABI_V1 &&
           metadata->struct_size == MC_LUAU_AOT_PROTO_V1_SIZE && metadata->entry &&
           metadata->max_stack_size >= metadata->num_params && metadata->nups <= 1 &&
           metadata->is_vararg <= 1 && metadata->reserved == 0 &&
           memcmp(metadata->layout_sha256, mc_luau_aot_v1_layout_sha256,
                  sizeof(metadata->layout_sha256)) == 0;
}

static bool validAotModule(const McLuauAotModuleV1 *module) {
    return module && module->abi_version == MC_LUAU_AOT_ABI_V1 &&
           module->struct_size == MC_LUAU_AOT_MODULE_V1_SIZE && module->flags == 0 &&
           module->reserved == 0 &&
           memcmp(module->layout_sha256, mc_luau_aot_v1_layout_sha256,
                  sizeof(module->layout_sha256)) == 0;
}

static void initializeAotProto(Proto *proto, const McLuauAotProtoV1 *metadata,
                               TString *sourceName) {
    proto->source = sourceName;
    proto->debugname = sourceName;
    proto->maxstacksize = metadata->max_stack_size;
    proto->numparams = metadata->num_params;
    proto->nups = metadata->nups;
    proto->is_vararg = metadata->is_vararg;
    proto->funid = metadata->function_id;
    proto->execdata = const_cast<McLuauAotProtoV1 *>(metadata);
}

static void publishRootClosure(lua_State *L, Proto *proto) {
    Closure *closure = luaF_newLclosure(L, 0, L->gt, proto);
    setclvalue(L, L->top, closure);
    LUAU_ASSERT(L->top < L->ci->top);
    L->top++;
}

static void publishModuleRegistry(lua_State *L, const McLuauAotProgramV1 *program, Proto **protos) {
    const int originalTop = lua_gettop(L);
    const int anchorBase = originalTop + 1;

    // Root every independent Proto tree before any table allocation can advance GC.
    luaC_threadbarrier(L);
    for (uint32_t id = 0; id < program->module_count; ++id) {
        Proto *root = protos[program->modules[id].root_proto_id];
        Closure *anchor = luaF_newLclosure(L, 0, L->gt, root);
        setclvalue(L, L->top, anchor);
        L->top++;
    }

    lua_createtable(L, int(program->module_count), 0);
    const int registryIndex = lua_gettop(L);
    lua_pushinteger(L, int(program->module_count));
    lua_rawseti(L, registryIndex, 0);

    for (uint32_t id = 0; id < program->module_count; ++id) {
        lua_createtable(L, 3, 0);
        const int recordIndex = lua_gettop(L);
        lua_pushvalue(L, anchorBase + int(id));
        lua_rawseti(L, recordIndex, 1);
        // The entry chunk is executed by the existing push_program caller, not require_static.
        // Mark it active up front so a dependency that reaches back to the entry fails as a cycle
        // instead of starting a duplicate initializer.
        lua_pushinteger(L, id == program->entry_module_id ? MODULE_INITIALIZING
                                                          : MODULE_UNINITIALIZED);
        lua_rawseti(L, recordIndex, 2);
        lua_rawseti(L, registryIndex, int(id) + 1);
    }

    lua_pushlightuserdata(L, &moduleRegistryKey);
    lua_pushvalue(L, registryIndex);
    lua_rawset(L, LUA_REGISTRYINDEX);

    // Preserve push_program's existing contract: leave exactly the entry root closure on top.
    lua_pushvalue(L, anchorBase + int(program->entry_module_id));
    lua_replace(L, anchorBase);
    lua_settop(L, anchorBase);
}

extern "C" uint32_t mc_luau_aot_v1_push_root(lua_State *L, const McLuauAotProtoV1 *metadata,
                                             const char *source, size_t sourceSize) {
    if (!L || !source || sourceSize == 0 || !validAotProto(metadata) ||
        metadata->parent_id != MC_LUAU_AOT_V1_NO_ID ||
        metadata->flags != MC_LUAU_AOT_PROTO_V1_ROOT || metadata->nups != 0)
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;

    if (L->global->ecb.destroy && L->global->ecb.destroy != destroyAotProto)
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;
    L->global->ecb.destroy = destroyAotProto;

    // Match the public API publication contract for newly-created collectables: reserve the stack
    // slot, advance incremental GC, then gray a black inactive thread before installing a white
    // Closure into its stack. GC does not run inside the allocations below.
    if (!lua_checkstack(L, 1))
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;
    luaC_checkGC(L);
    luaC_threadbarrier(L);

    TString *sourceName = luaS_newlstr(L, source, sourceSize);
    Proto *proto = luaF_newproto(L);
    initializeAotProto(proto, metadata, sourceName);
    publishRootClosure(L, proto);
    return MC_LUAU_AOT_V1_OK;
}

extern "C" uint32_t mc_luau_aot_v1_push_program(lua_State *L, const McLuauAotProgramV1 *program,
                                                const char *source, size_t sourceSize) {
    const bool hasExtendedProgram = program && program->struct_size == MC_LUAU_AOT_PROGRAM_V1_SIZE;
    const bool hasLegacyProgram =
        program && program->struct_size == MC_LUAU_AOT_PROGRAM_V1_LEGACY_SIZE;
    if (!L || !program || !source || sourceSize == 0 || !program->protos ||
        program->abi_version != MC_LUAU_AOT_ABI_V1 || (!hasExtendedProgram && !hasLegacyProgram) ||
        program->proto_count == 0 || program->proto_count > INT_MAX ||
        program->root_proto_id >= program->proto_count || program->flags != 0 ||
        memcmp(program->layout_sha256, mc_luau_aot_v1_layout_sha256,
               sizeof(program->layout_sha256)) != 0)
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;

    const uint32_t moduleCount = hasExtendedProgram ? program->module_count : 0;
    if ((moduleCount == 0 && hasExtendedProgram &&
         (program->modules != nullptr || program->entry_module_id != 0)) ||
        (moduleCount != 0 && (!program->modules || moduleCount > uint32_t(INT_MAX - 8) ||
                              program->entry_module_id >= moduleCount)))
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;

    if (moduleCount != 0) {
        for (uint32_t id = 0; id < moduleCount; ++id) {
            const McLuauAotModuleV1 *module = &program->modules[id];
            if (!validAotModule(module) || module->module_id != id ||
                module->root_proto_id >= program->proto_count)
                return MC_LUAU_AOT_V1_INTERNAL_ERROR;
            for (uint32_t previous = 0; previous < id; ++previous)
                if (program->modules[previous].root_proto_id == module->root_proto_id)
                    return MC_LUAU_AOT_V1_INTERNAL_ERROR;
        }
        if (program->root_proto_id != program->modules[program->entry_module_id].root_proto_id)
            return MC_LUAU_AOT_V1_INTERNAL_ERROR;
    }

    for (uint32_t id = 0; id < program->proto_count; ++id) {
        const McLuauAotProtoV1 *metadata = &program->protos[id];
        bool isRoot = id == program->root_proto_id;
        if (moduleCount != 0) {
            isRoot = false;
            for (uint32_t moduleId = 0; moduleId < moduleCount; ++moduleId)
                isRoot = isRoot || program->modules[moduleId].root_proto_id == id;
        }
        if (!validAotProto(metadata) || metadata->function_id != id ||
            metadata->flags != (isRoot ? MC_LUAU_AOT_PROTO_V1_ROOT : 0) ||
            (isRoot && metadata->nups != 0) ||
            (isRoot ? metadata->parent_id != MC_LUAU_AOT_V1_NO_ID : metadata->parent_id >= id))
            return MC_LUAU_AOT_V1_INTERNAL_ERROR;
    }

    if (L->global->ecb.destroy && L->global->ecb.destroy != destroyAotProto)
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;
    L->global->ecb.destroy = destroyAotProto;

    if (!lua_checkstack(L, moduleCount == 0 ? 1 : int(moduleCount) + 8))
        return MC_LUAU_AOT_V1_INTERNAL_ERROR;
    if (moduleCount != 0) {
        lua_pushlightuserdata(L, &moduleRegistryKey);
        lua_rawget(L, LUA_REGISTRYINDEX);
        const bool alreadyPublished = !lua_isnil(L, -1);
        lua_pop(L, 1);
        if (alreadyPublished)
            return MC_LUAU_AOT_V1_INTERNAL_ERROR;
    }
    luaC_checkGC(L);
    luaC_threadbarrier(L);

    const int protoCount = int(program->proto_count);
    const uint8_t memoryCategory = L->activememcat;
    Proto **protos = luaM_newarray(L, protoCount, Proto *, memoryCategory);
    uint32_t *childCounts = luaM_newarray(L, protoCount, uint32_t, memoryCategory);
    memset(childCounts, 0, sizeof(uint32_t) * protoCount);

    TString *sourceName = luaS_newlstr(L, source, sourceSize);
    for (int id = 0; id < protoCount; ++id) {
        protos[id] = luaF_newproto(L);
        initializeAotProto(protos[id], &program->protos[id], sourceName);
        if (program->protos[id].parent_id != MC_LUAU_AOT_V1_NO_ID)
            childCounts[program->protos[id].parent_id]++;
    }

    for (int id = 0; id < protoCount; ++id) {
        const uint32_t count = childCounts[id];
        if (count > INT_MAX)
            luaG_runerror(L, "strict AOT Proto child count exceeds runtime limit");
        if (count != 0) {
            protos[id]->p = luaM_newarray(L, int(count), Proto *, protos[id]->memcat);
            protos[id]->sizep = int(count);
        }
        childCounts[id] = 0;
    }
    for (int id = 0; id < protoCount; ++id) {
        if (program->protos[id].parent_id == MC_LUAU_AOT_V1_NO_ID)
            continue;
        const uint32_t parent = program->protos[id].parent_id;
        protos[parent]->p[childCounts[parent]++] = protos[id];
    }

    if (moduleCount == 0)
        publishRootClosure(L, protos[program->root_proto_id]);
    else
        publishModuleRegistry(L, program, protos);
    luaM_freearray(L, childCounts, protoCount, uint32_t, memoryCategory);
    luaM_freearray(L, protos, protoCount, Proto *, memoryCategory);
    return MC_LUAU_AOT_V1_OK;
}

extern "C" void mc_luau_aot_v1_enter(lua_State *L) {
    if (!L || !L->ci || !isLua(L->ci))
        luaG_runerror(L, "strict AOT entered without an active Luau frame");

    Closure *closure = clvalue(L->ci->func);
    Proto *proto = closure->l.p;
    const McLuauAotProtoV1 *metadata = static_cast<const McLuauAotProtoV1 *>(proto->execdata);
    if (!validAotProto(metadata))
        luaG_runerror(L, "strict AOT metadata ABI/layout mismatch");

    uint32_t status = metadata->entry(L, metadata);
    switch (status) {
    case MC_LUAU_AOT_V1_OK:
        luau_poscall(L, L->base);
        return;
    case MC_LUAU_AOT_V1_UNSUPPORTED_TYPE:
        luaG_runerror(L, "strict AOT numeric tier received an unsupported value type");
    case MC_LUAU_AOT_V1_YIELDED:
        luaG_runerror(L, "strict AOT yielded without a continuation contract");
    default:
        luaG_runerror(L, "strict AOT generated function returned invalid status %u", status);
    }
}

extern "C" void mc_luau_aot_v1_finish_yielded_op(lua_State *L) {
    luaG_runerror(L, "strict AOT yielded operation resumption is not implemented");
}
