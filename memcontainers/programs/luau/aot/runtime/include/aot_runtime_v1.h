#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lua_State lua_State;
typedef struct McLuauAotProtoV1 McLuauAotProtoV1;
typedef struct McLuauAotProgramV1 McLuauAotProgramV1;

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

enum McLuauAotIdsV1 {
    MC_LUAU_AOT_V1_NO_ID = UINT32_MAX,
};

// Stable AOT helper operations. These values are independent of Luau's internal TMS enum; the
// compiler frontend pin maps upstream TMS values onto this versioned runtime ABI.
enum McLuauAotArithOpV1 {
    MC_LUAU_AOT_ARITH_V1_ADD = 0,
    MC_LUAU_AOT_ARITH_V1_SUB = 1,
    MC_LUAU_AOT_ARITH_V1_MUL = 2,
    MC_LUAU_AOT_ARITH_V1_DIV = 3,
    MC_LUAU_AOT_ARITH_V1_IDIV = 4,
    MC_LUAU_AOT_ARITH_V1_MOD = 5,
    MC_LUAU_AOT_ARITH_V1_POW = 6,
    MC_LUAU_AOT_ARITH_V1_UNM = 7,
};

enum McLuauAotCompareOpV1 {
    MC_LUAU_AOT_COMPARE_V1_EQUAL = 0,
    MC_LUAU_AOT_COMPARE_V1_LESS = 1,
    MC_LUAU_AOT_COMPARE_V1_LESS_EQUAL = 2,
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
    uint32_t parent_id;
    uint32_t flags;
    uint8_t num_params;
    uint8_t nups;
    uint8_t is_vararg;
    uint8_t max_stack_size;
    uint32_t reserved;
};

// One immutable descriptor covers the entire canonical FrontendSnapshotV1 Proto graph. Proto IDs
// are dense array indices; parents precede children, so scanning equal parent_id values preserves
// the frontend's declared child order without a second mutable table.
struct McLuauAotProgramV1 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint8_t layout_sha256[32];
    const McLuauAotProtoV1 *protos;
    uint32_t proto_count;
    uint32_t root_proto_id;
    uint32_t flags;
};

enum {
    MC_LUAU_AOT_ABI_V1 = 1,
    MC_LUAU_AOT_PROTO_V1_SIZE = 64,
    MC_LUAU_AOT_PROGRAM_V1_SIZE = 56,
};

extern const uint8_t mc_luau_aot_v1_layout_sha256[32];

// Generated-code/runtime surface. Keep it versioned, unmangled, and narrow.
void mc_luau_aot_v1_enter(lua_State *state);
void mc_luau_aot_v1_finish_yielded_op(lua_State *state);
void mc_luau_aot_v1_return_fixed(lua_State *state, uint32_t source_register,
                                  uint32_t result_count);
uint32_t mc_luau_aot_v1_interrupt(lua_State *state, uint32_t pc);
void mc_luau_aot_v1_do_arith(lua_State *state, uint32_t destination_register,
                             uint32_t lhs_register, uint32_t rhs_register,
                             uint32_t operation);
uint32_t mc_luau_aot_v1_compare_any(lua_State *state, uint32_t lhs_register,
                                    uint32_t rhs_register, uint32_t operation);
void mc_luau_aot_v1_dupclosure(lua_State *state, uint32_t destination_register,
                               uint32_t child_proto_id);
void mc_luau_aot_v1_newclosure_value(lua_State *state, uint32_t destination_register,
                                     uint32_t child_proto_id, uint32_t capture_register);
void mc_luau_aot_v1_newclosure_ref(lua_State *state, uint32_t destination_register,
                                   uint32_t child_proto_id, uint32_t capture_register);
void mc_luau_aot_v1_get_upvalue(lua_State *state, uint32_t destination_register,
                                uint32_t upvalue_index);
void mc_luau_aot_v1_set_upvalue(lua_State *state, uint32_t upvalue_index,
                                uint32_t source_register);
void mc_luau_aot_v1_close_upvalues(lua_State *state, uint32_t first_register);
uint32_t mc_luau_aot_v1_call_fixed(lua_State *state, uint32_t function_register,
                                   uint32_t parameter_count, uint32_t result_count);
uint32_t mc_luau_aot_v1_push_root(lua_State *state, const McLuauAotProtoV1 *metadata,
                                  const char *source, size_t source_size);
uint32_t mc_luau_aot_v1_push_program(lua_State *state, const McLuauAotProgramV1 *program,
                                     const char *source, size_t source_size);

#ifdef __cplusplus
}

#if defined(__wasm32__)
static_assert(sizeof(McLuauAotProtoV1) == MC_LUAU_AOT_PROTO_V1_SIZE,
              "McLuauAotProtoV1 wasm32 layout drift");
static_assert(offsetof(McLuauAotProtoV1, entry) == 40, "McLuauAotProtoV1 entry offset drift");
static_assert(offsetof(McLuauAotProtoV1, num_params) == 56,
              "McLuauAotProtoV1 parameter offset drift");
static_assert(sizeof(McLuauAotProgramV1) == MC_LUAU_AOT_PROGRAM_V1_SIZE,
              "McLuauAotProgramV1 wasm32 layout drift");
static_assert(offsetof(McLuauAotProgramV1, protos) == 40,
              "McLuauAotProgramV1 Proto pointer offset drift");
#endif
#endif
