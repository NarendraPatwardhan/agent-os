#pragma once

// FrontendSnapshotV1 is a byte protocol, not a C struct ABI. Every integer is unsigned
// little-endian and every offset is relative to byte zero of the snapshot. The C++ Luau-pin
// adapter writes this format explicitly; Zig validates it before constructing compiler-owned IR.

#include <stddef.h>
#include <stdint.h>

#define MC_LUAU_FRONTEND_SNAPSHOT_V1_MAGIC "MCLUAOT\0"
#define MC_LUAU_FRONTEND_SNAPSHOT_V1_MAGIC_SIZE 8u
#define MC_LUAU_FRONTEND_SNAPSHOT_V1_VERSION 1u
#define MC_LUAU_FRONTEND_SNAPSHOT_V1_HEADER_SIZE 224u
#define MC_LUAU_FRONTEND_SNAPSHOT_V1_SECTION_SIZE 32u
#define MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID UINT32_C(0xffffffff)

// The snapshot is deliberately taken after upstream dead-block elimination, CFG analysis,
// constant propagation, and block linearization, but before dead-store marking and native
// lowering. Dead-store marking creates target-lowering side tables; the Zig normalizer owns that
// optional optimization instead of importing x64/A64 backend state into this protocol.
#define MC_LUAU_FRONTEND_SNAPSHOT_V1_FLAG_PRE_DSE_IR UINT32_C(0x00000001)
#define MC_LUAU_FRONTEND_SNAPSHOT_V1_REQUIRED_FLAGS MC_LUAU_FRONTEND_SNAPSHOT_V1_FLAG_PRE_DSE_IR

enum McLuauFrontendSnapshotV1HeaderOffset {
    MC_LUAU_SNAPSHOT_V1_H_MAGIC = 0,
    MC_LUAU_SNAPSHOT_V1_H_VERSION = 8,
    MC_LUAU_SNAPSHOT_V1_H_HEADER_SIZE = 10,
    MC_LUAU_SNAPSHOT_V1_H_FLAGS = 12,
    MC_LUAU_SNAPSHOT_V1_H_TOTAL_SIZE = 16,
    MC_LUAU_SNAPSHOT_V1_H_LUAU_PIN_SHA256 = 24,
    MC_LUAU_SNAPSHOT_V1_H_PATCHSET_SHA256 = 56,
    MC_LUAU_SNAPSHOT_V1_H_FRONTEND_BUILD_SHA256 = 88,
    MC_LUAU_SNAPSHOT_V1_H_IR_ENUM_SHA256 = 120,
    MC_LUAU_SNAPSHOT_V1_H_LAYOUT_SHA256 = 152,
    MC_LUAU_SNAPSHOT_V1_H_MODULE_COUNT = 184,
    MC_LUAU_SNAPSHOT_V1_H_PROTO_COUNT = 188,
    MC_LUAU_SNAPSHOT_V1_H_IR_FUNCTION_COUNT = 192,
    MC_LUAU_SNAPSHOT_V1_H_STRING_COUNT = 196,
    MC_LUAU_SNAPSHOT_V1_H_ROOT_PROTO_ID = 200,
    MC_LUAU_SNAPSHOT_V1_H_SECTION_COUNT = 204,
    MC_LUAU_SNAPSHOT_V1_H_RESERVED = 208,
};

enum McLuauFrontendSnapshotV1SectionOffset {
    MC_LUAU_SNAPSHOT_V1_S_KIND = 0,
    MC_LUAU_SNAPSHOT_V1_S_FLAGS = 2,
    MC_LUAU_SNAPSHOT_V1_S_RECORD_SIZE = 4,
    MC_LUAU_SNAPSHOT_V1_S_OFFSET = 8,
    MC_LUAU_SNAPSHOT_V1_S_LENGTH = 16,
    MC_LUAU_SNAPSHOT_V1_S_COUNT = 24,
    MC_LUAU_SNAPSHOT_V1_S_RESERVED = 28,
};

// Sections are serialized in this exact increasing order. Fixed-record sections have the stated
// record size; byte blobs use record_size=1 and count=length. Unknown kinds are rejected in V1.
enum McLuauFrontendSnapshotV1SectionKind {
    MC_LUAU_SNAPSHOT_V1_STRINGS = 1,
    MC_LUAU_SNAPSHOT_V1_STRING_BYTES = 2,
    MC_LUAU_SNAPSHOT_V1_PROTOS = 3,
    MC_LUAU_SNAPSHOT_V1_PROTO_CHILDREN = 4,
    MC_LUAU_SNAPSHOT_V1_BYTECODE_WORDS = 5,
    MC_LUAU_SNAPSHOT_V1_VM_CONSTANTS = 6,
    MC_LUAU_SNAPSHOT_V1_VM_CONSTANT_ITEMS = 7,
    MC_LUAU_SNAPSHOT_V1_LOCALS = 8,
    MC_LUAU_SNAPSHOT_V1_UPVALUE_NAMES = 9,
    MC_LUAU_SNAPSHOT_V1_TYPEINFO_BYTES = 10,
    MC_LUAU_SNAPSHOT_V1_LINEINFO_BYTES = 11,
    MC_LUAU_SNAPSHOT_V1_ABSLINEINFO = 12,
    MC_LUAU_SNAPSHOT_V1_DEBUG_OPCODES = 13,
    MC_LUAU_SNAPSHOT_V1_FEEDBACK = 14,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTIONS = 15,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCKS = 16,
    MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTIONS = 17,
    MC_LUAU_SNAPSHOT_V1_IR_OPERANDS = 18,
    MC_LUAU_SNAPSHOT_V1_IR_CONSTANTS = 19,
    MC_LUAU_SNAPSHOT_V1_BC_MAPPING = 20,
    // The original luau_compile output is evidence and permits a future pin-adapter decoder to
    // cross-check loader-only compound constant descriptors. It is never executable input to the
    // target guest or an invitation to duplicate the pinned loader in Zig.
    MC_LUAU_SNAPSHOT_V1_COMPILED_BYTECODE = 21,
};

enum McLuauFrontendSnapshotV1RecordSize {
    MC_LUAU_SNAPSHOT_V1_STRING_SIZE = 16,
    MC_LUAU_SNAPSHOT_V1_PROTO_SIZE = 128,
    MC_LUAU_SNAPSHOT_V1_CHILD_SIZE = 4,
    MC_LUAU_SNAPSHOT_V1_BYTECODE_WORD_SIZE = 4,
    MC_LUAU_SNAPSHOT_V1_VM_CONSTANT_SIZE = 40,
    MC_LUAU_SNAPSHOT_V1_VM_CONSTANT_ITEM_SIZE = 8,
    MC_LUAU_SNAPSHOT_V1_LOCAL_SIZE = 20,
    MC_LUAU_SNAPSHOT_V1_UPVALUE_NAME_SIZE = 4,
    MC_LUAU_SNAPSHOT_V1_ABSLINE_SIZE = 4,
    MC_LUAU_SNAPSHOT_V1_FEEDBACK_SIZE = 12,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_SIZE = 64,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_SIZE = 32,
    MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_SIZE = 24,
    MC_LUAU_SNAPSHOT_V1_IR_OPERAND_SIZE = 8,
    MC_LUAU_SNAPSHOT_V1_IR_CONSTANT_SIZE = 16,
    MC_LUAU_SNAPSHOT_V1_BC_MAPPING_SIZE = 8,
};

// VmConstantV1 uses kind:u8 at byte 0, four u32 payload words at bytes 4..19, and two u64 bit
// payloads at bytes 24..39. Compound records index VM_CONSTANT_ITEMS with (start,count): imports
// carry 1..3 ordered name-constant IDs; tables carry ordered (key,value-or-NO_ID) pairs; class
// shapes carry classname in payload0, item start in payload1, and property/method counts in 2/3.

enum McLuauFrontendSnapshotV1StringOffset {
    MC_LUAU_SNAPSHOT_V1_STRING_BYTE_OFFSET = 0,
    MC_LUAU_SNAPSHOT_V1_STRING_BYTE_LENGTH = 8,
    MC_LUAU_SNAPSHOT_V1_STRING_FLAGS = 12,
};

enum McLuauFrontendSnapshotV1ProtoOffset {
    MC_LUAU_SNAPSHOT_V1_PROTO_ID = 0,
    MC_LUAU_SNAPSHOT_V1_PROTO_PARENT_ID = 4,
    MC_LUAU_SNAPSHOT_V1_PROTO_SOURCE_STRING_ID = 8,
    MC_LUAU_SNAPSHOT_V1_PROTO_DEBUGNAME_STRING_ID = 12,
    MC_LUAU_SNAPSHOT_V1_PROTO_LINE_DEFINED = 16,
    MC_LUAU_SNAPSHOT_V1_PROTO_BYTECODE_ID = 20,
    MC_LUAU_SNAPSHOT_V1_PROTO_FUN_ID = 24,
    MC_LUAU_SNAPSHOT_V1_PROTO_FLAGS = 28,
    MC_LUAU_SNAPSHOT_V1_PROTO_NUPS = 29,
    MC_LUAU_SNAPSHOT_V1_PROTO_NUM_PARAMS = 30,
    MC_LUAU_SNAPSHOT_V1_PROTO_IS_VARARG = 31,
    MC_LUAU_SNAPSHOT_V1_PROTO_MAX_STACK = 32,
    MC_LUAU_SNAPSHOT_V1_PROTO_LINE_GAP_LOG2 = 33,
    MC_LUAU_SNAPSHOT_V1_PROTO_CODE_START = 36,
    MC_LUAU_SNAPSHOT_V1_PROTO_CODE_COUNT = 40,
    MC_LUAU_SNAPSHOT_V1_PROTO_CONSTANT_START = 44,
    MC_LUAU_SNAPSHOT_V1_PROTO_CONSTANT_COUNT = 48,
    MC_LUAU_SNAPSHOT_V1_PROTO_CHILD_START = 52,
    MC_LUAU_SNAPSHOT_V1_PROTO_CHILD_COUNT = 56,
    MC_LUAU_SNAPSHOT_V1_PROTO_UPVALUE_NAME_START = 60,
    MC_LUAU_SNAPSHOT_V1_PROTO_UPVALUE_NAME_COUNT = 64,
    MC_LUAU_SNAPSHOT_V1_PROTO_LOCAL_START = 68,
    MC_LUAU_SNAPSHOT_V1_PROTO_LOCAL_COUNT = 72,
    MC_LUAU_SNAPSHOT_V1_PROTO_TYPEINFO_START = 76,
    MC_LUAU_SNAPSHOT_V1_PROTO_TYPEINFO_COUNT = 80,
    MC_LUAU_SNAPSHOT_V1_PROTO_LINEINFO_START = 84,
    MC_LUAU_SNAPSHOT_V1_PROTO_LINEINFO_COUNT = 88,
    MC_LUAU_SNAPSHOT_V1_PROTO_ABSLINE_START = 92,
    MC_LUAU_SNAPSHOT_V1_PROTO_ABSLINE_COUNT = 96,
    MC_LUAU_SNAPSHOT_V1_PROTO_DEBUG_OPCODE_START = 100,
    MC_LUAU_SNAPSHOT_V1_PROTO_DEBUG_OPCODE_COUNT = 104,
    MC_LUAU_SNAPSHOT_V1_PROTO_FEEDBACK_START = 108,
    MC_LUAU_SNAPSHOT_V1_PROTO_FEEDBACK_COUNT = 112,
    MC_LUAU_SNAPSHOT_V1_PROTO_IR_FUNCTION_ID = 116,
};

enum McLuauFrontendSnapshotV1IrFunctionOffset {
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_ID = 0,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_PROTO_ID = 4,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_ENTRY_BLOCK = 8,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_VARIADIC = 12,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BLOCK_START = 16,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BLOCK_COUNT = 20,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_INSTRUCTION_START = 24,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_INSTRUCTION_COUNT = 28,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_OPERAND_START = 32,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_OPERAND_COUNT = 36,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_CONSTANT_START = 40,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_CONSTANT_COUNT = 44,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BC_MAPPING_START = 48,
    MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BC_MAPPING_COUNT = 52,
};

enum McLuauFrontendSnapshotV1IrBlockOffset {
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_KIND = 0,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_FLAGS = 1,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_USE_COUNT = 2,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_START = 4,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_FINISH = 8,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_SORT_KEY = 12,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_CHAIN_KEY = 16,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_EXPECTED_NEXT = 20,
    MC_LUAU_SNAPSHOT_V1_IR_BLOCK_START_PC = 24,
};

enum McLuauFrontendSnapshotV1IrInstructionOffset {
    MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_CMD = 0,
    MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_USE_COUNT = 2,
    MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_LAST_USE = 4,
    MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_OPERAND_START = 8,
    MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_OPERAND_COUNT = 12,
};

enum McLuauFrontendSnapshotV1VmConstantKind {
    MC_LUAU_SNAPSHOT_V1_VM_NIL = 0,
    MC_LUAU_SNAPSHOT_V1_VM_BOOLEAN = 1,
    MC_LUAU_SNAPSHOT_V1_VM_NUMBER = 2,
    MC_LUAU_SNAPSHOT_V1_VM_VECTOR = 3,
    MC_LUAU_SNAPSHOT_V1_VM_STRING = 4,
    MC_LUAU_SNAPSHOT_V1_VM_INTEGER = 5,
    MC_LUAU_SNAPSHOT_V1_VM_IMPORT = 6,
    MC_LUAU_SNAPSHOT_V1_VM_TABLE = 7,
    MC_LUAU_SNAPSHOT_V1_VM_CLOSURE = 8,
    MC_LUAU_SNAPSHOT_V1_VM_CLASS_SHAPE = 9,
};

// The narrow ownership ABI. A successful result owns `data`; both success and failure may own a
// diagnostic. Nothing returns a Proto, IrFunction, STL object, or pointer into the temporary VM.
typedef struct McLuauFrontendSnapshotV1Result {
    uint8_t *data;
    size_t size;
    char *diagnostic;
    size_t diagnostic_size;
    uint32_t status;
} McLuauFrontendSnapshotV1Result;

// These statuses describe invocations that return normally. A deep patched-Luau raise or a
// nonrecoverable allocator failure traps the zero-import frontend capability; the host must treat
// that trap as a failed invocation and instantiate a fresh compiler capability.
enum McLuauFrontendSnapshotV1Status {
    MC_LUAU_SNAPSHOT_V1_OK = 0,
    MC_LUAU_SNAPSHOT_V1_INVALID_ARGUMENT = 1,
    MC_LUAU_SNAPSHOT_V1_COMPILE_ERROR = 2,
    MC_LUAU_SNAPSHOT_V1_LOAD_ERROR = 3,
    MC_LUAU_SNAPSHOT_V1_UNSUPPORTED_FRONTEND_VALUE = 4,
    MC_LUAU_SNAPSHOT_V1_RESOURCE_LIMIT = 5,
    MC_LUAU_SNAPSHOT_V1_INTERNAL_ERROR = 6,
};

#ifdef __cplusplus
extern "C" {
#endif

uint32_t mc_luau_frontend_snapshot_v1_compile(const uint8_t *source, size_t source_size,
                                              const uint8_t *chunk_name, size_t chunk_name_size,
                                              McLuauFrontendSnapshotV1Result *out_result);

void mc_luau_frontend_snapshot_v1_free(McLuauFrontendSnapshotV1Result *result);

#ifdef __cplusplus
}
#endif
