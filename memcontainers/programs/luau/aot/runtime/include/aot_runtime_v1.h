#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lua_State lua_State;
typedef struct McLuauAotProtoV1 McLuauAotProtoV1;

typedef uint32_t (*McLuauAotFunctionV1)(lua_State *state, const McLuauAotProtoV1 *proto);

enum McLuauAotStatusV1 {
    MC_LUAU_AOT_V1_OK = 0,
    MC_LUAU_AOT_V1_UNSUPPORTED_TYPE = 1,
    MC_LUAU_AOT_V1_INTERNAL_ERROR = 2,
    MC_LUAU_AOT_V1_YIELDED = 3,
};

enum McLuauAotProtoFlagsV1 {
    MC_LUAU_AOT_PROTO_V1_ROOT = 1u << 0,
};

// Immutable metadata attached to Proto::execdata by the AOT image initializer. The generated
// function pointer uses the Wasm table index representation selected by the canonical toolchain;
// generated code itself receives this record as linear-memory data and never dereferences Proto.
struct McLuauAotProtoV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint8_t layout_sha256[32];
    McLuauAotFunctionV1 entry;
    uint32_t function_id;
    uint32_t flags;
};

enum {
    MC_LUAU_AOT_ABI_V1 = 1,
    MC_LUAU_AOT_PROTO_V1_SIZE = 52,
};

extern const uint8_t mc_luau_aot_v1_layout_sha256[32];

// Generated-code/runtime surface. Keep it versioned, unmangled, and narrow.
void mc_luau_aot_v1_enter(lua_State *state);
void mc_luau_aot_v1_finish_yielded_op(lua_State *state);
void mc_luau_aot_v1_commit_number(lua_State *state, double value);
uint32_t mc_luau_aot_v1_interrupt(lua_State *state, uint32_t pc);
uint32_t mc_luau_aot_v1_push_root(lua_State *state, const McLuauAotProtoV1 *metadata,
                                  const char *source, size_t source_size, uint8_t num_params,
                                  uint8_t max_stack_size);

#ifdef __cplusplus
}

#if defined(__wasm32__)
static_assert(sizeof(McLuauAotProtoV1) == MC_LUAU_AOT_PROTO_V1_SIZE,
              "McLuauAotProtoV1 wasm32 layout drift");
static_assert(offsetof(McLuauAotProtoV1, entry) == 40, "McLuauAotProtoV1 entry offset drift");
#endif
#endif
