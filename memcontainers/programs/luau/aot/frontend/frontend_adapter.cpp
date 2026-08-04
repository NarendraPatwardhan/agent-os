#include "../schema/frontend_snapshot_v1.h"
#include "compiler_error_channel.h"
#include "frontend_identity_v1.h"

#include "lua.h"
#include "lualib.h"
#include "luacode.h"

#include "lapi.h"
#include "lobject.h"
#include "lstate.h"

#include "Luau/CodeGenOptions.h"
#include "Luau/Bytecode.h"
#include "Luau/BytecodeUtils.h"
#include "Luau/IrAnalysis.h"
#include "Luau/IrBuilder.h"
#include "Luau/IrData.h"
#include "Luau/IrUtils.h"
#include "Luau/OptimizeConstProp.h"

#include <algorithm>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

using namespace Luau::CodeGen;

static_assert(sizeof(IrCmd) == 1, "FrontendSnapshotV1 pins IrCmd to one byte");
static_assert(unsigned(IrCmd::JUMP_CMP_PROTOID) == 215, "IrCmd pin drift");
static_assert(unsigned(IrOpKind::VmExit) == 9, "IrOpKind pin drift");
static_assert(unsigned(IrBlockKind::Dead) == 5, "IrBlockKind pin drift");
static_assert(unsigned(IrConstKind::Import) == 5, "IrConstKind pin drift");

namespace {

constexpr size_t kMaxSourceBytes = 16 * 1024 * 1024;
constexpr size_t kMaxBytecodeBytes = 64 * 1024 * 1024;
constexpr size_t kMaxSnapshotBytes = 256 * 1024 * 1024;
constexpr size_t kMaxProtos = 4096;
constexpr size_t kMaxInstructions = 1'048'576;
constexpr size_t kMaxBlocksPerFunction = 32'768;
constexpr size_t kMaxInstructionsPerBlock = 65'536;
constexpr size_t kMaxStrings = 1 * 1024 * 1024;

constexpr uint8_t kLuauPinSha256[32] = {
    0xe5, 0x1e, 0xad, 0x5f, 0x54, 0x16, 0x33, 0x69, 0x3d, 0x54, 0x80, 0x57, 0xe0, 0x43, 0x19, 0x27,
    0xf3, 0x03, 0x6c, 0x13, 0xb1, 0x85, 0xfd, 0xb3, 0x7f, 0xbc, 0x3f, 0x5a, 0x26, 0x1e, 0x66, 0x76,
};

constexpr uint8_t kPatchsetSha256[32] = {
    0x5f, 0xd5, 0xcf, 0x3a, 0x3f, 0xcb, 0x66, 0xa0, 0x04, 0xaa, 0x53, 0x87, 0x94, 0xb0, 0xef, 0x1e,
    0x43, 0x17, 0xed, 0xd6, 0xa3, 0x20, 0x8d, 0xd8, 0x7c, 0xf1, 0x12, 0xa3, 0x10, 0x5c, 0xf1, 0x22,
};

constexpr uint8_t kIrEnumSha256[32] = {
    0x76, 0x5f, 0x91, 0x88, 0xe0, 0x7a, 0x38, 0x86, 0xc2, 0x9b, 0x5b, 0xb1, 0x46, 0x24, 0x12, 0x86,
    0xd1, 0xf9, 0x5c, 0x80, 0x1a, 0x89, 0x07, 0xaa, 0x03, 0x14, 0x7d, 0xf5, 0x24, 0xe7, 0xc3, 0x99,
};

constexpr uint8_t kLayoutSha256[32] = {
    0x42, 0x5d, 0x38, 0xd7, 0x5e, 0xf9, 0xf4, 0xe2, 0x66, 0x93, 0xa6, 0x90, 0xe0, 0x85, 0x7f, 0x90,
    0x2a, 0xa7, 0x6f, 0x1c, 0x18, 0x56, 0x19, 0x6a, 0xc3, 0x0d, 0xc6, 0x23, 0x6e, 0xa4, 0xc4, 0x96,
};

struct SectionData {
    uint16_t kind;
    uint32_t recordSize;
    std::vector<uint8_t> bytes;
};

struct ProtoRef {
    Proto *proto;
    uint32_t parent;
};

struct StringTable {
    SectionData &records;
    SectionData &bytes;
    std::vector<std::string> values;
    bool failed = false;

    uint32_t intern(const char *data, size_t size) {
        if (!data)
            return MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID;

        for (size_t index = 0; index < values.size(); ++index) {
            if (values[index].size() == size && memcmp(values[index].data(), data, size) == 0)
                return uint32_t(index);
        }

        if (values.size() >= kMaxStrings || size > UINT32_MAX ||
            bytes.bytes.size() + size > kMaxSnapshotBytes) {
            failed = true;
            return MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID;
        }

        uint64_t byteOffset = bytes.bytes.size();
        values.emplace_back(data, size);
        bytes.bytes.insert(bytes.bytes.end(), data, data + size);

        size_t record = appendRecord(records);
        putU64(records.bytes, record + MC_LUAU_SNAPSHOT_V1_STRING_BYTE_OFFSET, byteOffset);
        putU32(records.bytes, record + MC_LUAU_SNAPSHOT_V1_STRING_BYTE_LENGTH, uint32_t(size));
        return uint32_t(values.size() - 1);
    }

    uint32_t intern(TString *string) {
        return string ? intern(getstr(string), string->len) : MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID;
    }

    static size_t appendRecord(SectionData &section) {
        size_t offset = section.bytes.size();
        section.bytes.resize(offset + section.recordSize, 0);
        return offset;
    }

    static void putU32(std::vector<uint8_t> &output, size_t offset, uint32_t value) {
        for (unsigned shift = 0; shift < 32; shift += 8)
            output[offset + shift / 8] = uint8_t(value >> shift);
    }

    static void putU64(std::vector<uint8_t> &output, size_t offset, uint64_t value) {
        for (unsigned shift = 0; shift < 64; shift += 8)
            output[offset + shift / 8] = uint8_t(value >> shift);
    }
};

void putU16(std::vector<uint8_t> &output, size_t offset, uint16_t value) {
    output[offset] = uint8_t(value);
    output[offset + 1] = uint8_t(value >> 8);
}

void putU32(std::vector<uint8_t> &output, size_t offset, uint32_t value) {
    for (unsigned shift = 0; shift < 32; shift += 8)
        output[offset + shift / 8] = uint8_t(value >> shift);
}

void putU64(std::vector<uint8_t> &output, size_t offset, uint64_t value) {
    for (unsigned shift = 0; shift < 64; shift += 8)
        output[offset + shift / 8] = uint8_t(value >> shift);
}

size_t appendRecord(SectionData &section) {
    size_t offset = section.bytes.size();
    section.bytes.resize(offset + section.recordSize, 0);
    return offset;
}

uint32_t recordCount(const SectionData &section) {
    return uint32_t(section.bytes.size() / section.recordSize);
}

void appendU32Record(SectionData &section, uint32_t value) {
    size_t offset = appendRecord(section);
    putU32(section.bytes, offset, value);
}

void appendBytes(SectionData &section, const void *bytes, size_t size) {
    const uint8_t *first = static_cast<const uint8_t *>(bytes);
    section.bytes.insert(section.bytes.end(), first, first + size);
}

uint32_t protoId(const std::vector<ProtoRef> &protos, Proto *wanted) {
    for (size_t index = 0; index < protos.size(); ++index) {
        if (protos[index].proto == wanted)
            return uint32_t(index);
    }
    return MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID;
}

bool collectProtos(Proto *proto, uint32_t parent, std::vector<ProtoRef> &output) {
    if (!proto)
        return false;

    uint32_t existing = protoId(output, proto);
    if (existing != MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID)
        return true;
    if (output.size() >= kMaxProtos)
        return false;

    output.push_back({proto, parent});
    uint32_t current = uint32_t(output.size() - 1);
    for (int index = 0; index < proto->sizep; ++index) {
        if (!collectProtos(proto->p[index], current, output))
            return false;
    }
    return true;
}

bool containsUndecodedImport(const std::vector<ProtoRef> &protos) {
    for (const ProtoRef &item : protos) {
        Proto *proto = item.proto;
        for (int pc = 0; pc < proto->sizecode;) {
            LuauOpcode opcode = LuauOpcode(LUAU_INSN_OP(proto->code[pc]));
            if (opcode == LOP_GETIMPORT)
                return true;
            pc += Luau::getOpLength(opcode);
        }
    }
    return false;
}

void setDiagnostic(McLuauFrontendSnapshotV1Result *result, uint32_t status, const char *data,
                   size_t size) {
    result->status = status;
    result->diagnostic = static_cast<char *>(malloc(size + 1));
    if (!result->diagnostic) {
        result->diagnostic_size = 0;
        return;
    }

    memcpy(result->diagnostic, data, size);
    result->diagnostic[size] = '\0';
    result->diagnostic_size = size;
}

void setDiagnostic(McLuauFrontendSnapshotV1Result *result, uint32_t status,
                   const std::string &message) {
    setDiagnostic(result, status, message.data(), message.size());
}

void setDiagnostic(McLuauFrontendSnapshotV1Result *result, uint32_t status, const char *message) {
    setDiagnostic(result, status, message, strlen(message));
}

std::vector<SectionData> makeSections() {
    const uint32_t sizes[] = {
        MC_LUAU_SNAPSHOT_V1_STRING_SIZE,
        1,
        MC_LUAU_SNAPSHOT_V1_PROTO_SIZE,
        MC_LUAU_SNAPSHOT_V1_CHILD_SIZE,
        MC_LUAU_SNAPSHOT_V1_BYTECODE_WORD_SIZE,
        MC_LUAU_SNAPSHOT_V1_VM_CONSTANT_SIZE,
        MC_LUAU_SNAPSHOT_V1_VM_CONSTANT_ITEM_SIZE,
        MC_LUAU_SNAPSHOT_V1_LOCAL_SIZE,
        MC_LUAU_SNAPSHOT_V1_UPVALUE_NAME_SIZE,
        1,
        1,
        MC_LUAU_SNAPSHOT_V1_ABSLINE_SIZE,
        1,
        MC_LUAU_SNAPSHOT_V1_FEEDBACK_SIZE,
        MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_SIZE,
        MC_LUAU_SNAPSHOT_V1_IR_BLOCK_SIZE,
        MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_SIZE,
        MC_LUAU_SNAPSHOT_V1_IR_OPERAND_SIZE,
        MC_LUAU_SNAPSHOT_V1_IR_CONSTANT_SIZE,
        MC_LUAU_SNAPSHOT_V1_BC_MAPPING_SIZE,
        1,
    };

    std::vector<SectionData> sections;
    sections.reserve(sizeof(sizes) / sizeof(sizes[0]));
    for (uint16_t index = 0; index < sizeof(sizes) / sizeof(sizes[0]); ++index)
        sections.push_back({uint16_t(index + 1), sizes[index], {}});
    return sections;
}

SectionData &section(std::vector<SectionData> &sections, uint16_t kind) {
    return sections[kind - 1];
}

bool serializeVmConstant(const TValue &value, const std::vector<ProtoRef> &protos,
                         StringTable &strings, SectionData &constants, uint32_t &failureStatus,
                         std::string &error) {
    size_t record = appendRecord(constants);

    if (ttisnil(&value)) {
        constants.bytes[record] = MC_LUAU_SNAPSHOT_V1_VM_NIL;
    } else if (ttisboolean(&value)) {
        constants.bytes[record] = MC_LUAU_SNAPSHOT_V1_VM_BOOLEAN;
        putU32(constants.bytes, record + 4, bvalue(&value) ? 1 : 0);
    } else if (ttisnumber(&value)) {
        constants.bytes[record] = MC_LUAU_SNAPSHOT_V1_VM_NUMBER;
        uint64_t bits = 0;
        double number = nvalue(&value);
        memcpy(&bits, &number, sizeof(bits));
        putU64(constants.bytes, record + 24, bits);
    } else if (ttisinteger(&value)) {
        constants.bytes[record] = MC_LUAU_SNAPSHOT_V1_VM_INTEGER;
        putU64(constants.bytes, record + 24, uint64_t(lvalue(&value)));
    } else if (ttisvector(&value)) {
        constants.bytes[record] = MC_LUAU_SNAPSHOT_V1_VM_VECTOR;
        const float *vector = vvalue(&value);
        for (unsigned lane = 0; lane < LUA_VECTOR_SIZE; ++lane) {
            uint32_t bits = 0;
            memcpy(&bits, &vector[lane], sizeof(bits));
            putU32(constants.bytes, record + 4 + lane * 4, bits);
        }
    } else if (ttisstring(&value)) {
        constants.bytes[record] = MC_LUAU_SNAPSHOT_V1_VM_STRING;
        uint32_t id = strings.intern(tsvalue(&value));
        if (id == MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID) {
            failureStatus = MC_LUAU_SNAPSHOT_V1_RESOURCE_LIMIT;
            error = "frontend string table resource limit";
            return false;
        }
        putU32(constants.bytes, record + 4, id);
    } else if (ttisfunction(&value) && !clvalue(&value)->isC) {
        constants.bytes[record] = MC_LUAU_SNAPSHOT_V1_VM_CLOSURE;
        uint32_t id = protoId(protos, clvalue(&value)->l.p);
        if (id == MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID) {
            failureStatus = MC_LUAU_SNAPSHOT_V1_INTERNAL_ERROR;
            error = "closure constant references a Proto outside the closed graph";
            return false;
        }
        putU32(constants.bytes, record + 4, id);
    } else {
        constants.bytes.resize(record);
        error = "compound loader constant is not decoded by FrontendSnapshotV1 yet (TValue tag " +
                std::to_string(ttype(&value)) + ")";
        return false;
    }

    return true;
}

bool serializeProtoMetadata(const std::vector<ProtoRef> &protos, std::vector<SectionData> &sections,
                            StringTable &strings, uint32_t &failureStatus, std::string &error) {
    SectionData &protoRecords = section(sections, MC_LUAU_SNAPSHOT_V1_PROTOS);
    SectionData &children = section(sections, MC_LUAU_SNAPSHOT_V1_PROTO_CHILDREN);
    SectionData &code = section(sections, MC_LUAU_SNAPSHOT_V1_BYTECODE_WORDS);
    SectionData &constants = section(sections, MC_LUAU_SNAPSHOT_V1_VM_CONSTANTS);
    SectionData &locals = section(sections, MC_LUAU_SNAPSHOT_V1_LOCALS);
    SectionData &upvalueNames = section(sections, MC_LUAU_SNAPSHOT_V1_UPVALUE_NAMES);
    SectionData &typeinfo = section(sections, MC_LUAU_SNAPSHOT_V1_TYPEINFO_BYTES);
    SectionData &lineinfo = section(sections, MC_LUAU_SNAPSHOT_V1_LINEINFO_BYTES);
    SectionData &abslineinfo = section(sections, MC_LUAU_SNAPSHOT_V1_ABSLINEINFO);
    SectionData &debugOpcodes = section(sections, MC_LUAU_SNAPSHOT_V1_DEBUG_OPCODES);
    SectionData &feedback = section(sections, MC_LUAU_SNAPSHOT_V1_FEEDBACK);

    for (size_t protoIndex = 0; protoIndex < protos.size(); ++protoIndex) {
        Proto *proto = protos[protoIndex].proto;
        size_t record = appendRecord(protoRecords);
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_ID, uint32_t(protoIndex));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_PARENT_ID,
               protos[protoIndex].parent);
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_SOURCE_STRING_ID,
               strings.intern(proto->source));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_DEBUGNAME_STRING_ID,
               strings.intern(proto->debugname));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_LINE_DEFINED,
               uint32_t(proto->linedefined));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_BYTECODE_ID,
               uint32_t(proto->bytecodeid));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_FUN_ID, proto->funid);
        protoRecords.bytes[record + MC_LUAU_SNAPSHOT_V1_PROTO_FLAGS] = proto->flags;
        protoRecords.bytes[record + MC_LUAU_SNAPSHOT_V1_PROTO_NUPS] = proto->nups;
        protoRecords.bytes[record + MC_LUAU_SNAPSHOT_V1_PROTO_NUM_PARAMS] = proto->numparams;
        protoRecords.bytes[record + MC_LUAU_SNAPSHOT_V1_PROTO_IS_VARARG] = proto->is_vararg;
        protoRecords.bytes[record + MC_LUAU_SNAPSHOT_V1_PROTO_MAX_STACK] = proto->maxstacksize;
        protoRecords.bytes[record + MC_LUAU_SNAPSHOT_V1_PROTO_LINE_GAP_LOG2] =
            proto->lineinfo ? uint8_t(proto->linegaplog2) : 0;

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_CODE_START,
               recordCount(code));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_CODE_COUNT,
               uint32_t(proto->sizecode));
        for (int index = 0; index < proto->sizecode; ++index)
            appendU32Record(code, proto->code[index]);

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_CONSTANT_START,
               recordCount(constants));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_CONSTANT_COUNT,
               uint32_t(proto->sizek));
        for (int index = 0; index < proto->sizek; ++index) {
            if (!serializeVmConstant(proto->k[index], protos, strings, constants, failureStatus,
                                     error))
                return false;
        }

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_CHILD_START,
               recordCount(children));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_CHILD_COUNT,
               uint32_t(proto->sizep));
        for (int index = 0; index < proto->sizep; ++index) {
            uint32_t child = protoId(protos, proto->p[index]);
            if (child == MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID) {
                failureStatus = MC_LUAU_SNAPSHOT_V1_INTERNAL_ERROR;
                error = "Proto child is outside the closed graph";
                return false;
            }
            appendU32Record(children, child);
        }

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_UPVALUE_NAME_START,
               recordCount(upvalueNames));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_UPVALUE_NAME_COUNT,
               uint32_t(proto->sizeupvalues));
        for (int index = 0; index < proto->sizeupvalues; ++index)
            appendU32Record(upvalueNames, strings.intern(proto->upvalues[index]));

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_LOCAL_START,
               recordCount(locals));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_LOCAL_COUNT,
               uint32_t(proto->sizelocvars));
        for (int index = 0; index < proto->sizelocvars; ++index) {
            const LocVar &local = proto->locvars[index];
            size_t localRecord = appendRecord(locals);
            putU32(locals.bytes, localRecord, strings.intern(local.varname));
            putU32(locals.bytes, localRecord + 4, uint32_t(local.startpc));
            putU32(locals.bytes, localRecord + 8, uint32_t(local.endpc));
            locals.bytes[localRecord + 12] = local.reg;
        }

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_TYPEINFO_START,
               recordCount(typeinfo));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_TYPEINFO_COUNT,
               uint32_t(proto->sizetypeinfo));
        if (proto->sizetypeinfo > 0)
            appendBytes(typeinfo, proto->typeinfo, size_t(proto->sizetypeinfo));

        const uint32_t lineCount = proto->lineinfo ? uint32_t(proto->sizecode) : 0;
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_LINEINFO_START,
               recordCount(lineinfo));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_LINEINFO_COUNT, lineCount);
        if (lineCount)
            appendBytes(lineinfo, proto->lineinfo, lineCount);

        const uint32_t absCount = proto->lineinfo && proto->sizecode > 0
                                      ? uint32_t(((proto->sizecode - 1) >> proto->linegaplog2) + 1)
                                      : 0;
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_ABSLINE_START,
               recordCount(abslineinfo));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_ABSLINE_COUNT, absCount);
        for (uint32_t index = 0; index < absCount; ++index)
            appendU32Record(abslineinfo, uint32_t(proto->abslineinfo[index]));

        const uint32_t debugCount = proto->debuginsn ? uint32_t(proto->sizecode) : 0;
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_DEBUG_OPCODE_START,
               recordCount(debugOpcodes));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_DEBUG_OPCODE_COUNT,
               debugCount);
        if (debugCount)
            appendBytes(debugOpcodes, proto->debuginsn, debugCount);

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_FEEDBACK_START,
               recordCount(feedback));
        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_FEEDBACK_COUNT,
               proto->feedbackvecsize);
        for (uint32_t index = 0; index < proto->feedbackvecsize; ++index) {
            size_t feedbackRecord = appendRecord(feedback);
            feedback.bytes[feedbackRecord] = uint8_t(proto->feedbackvec[index].kind);
            putU32(feedback.bytes, feedbackRecord + 4,
                   uint32_t(proto->feedbackvec[index].call_target.pc));
        }

        putU32(protoRecords.bytes, record + MC_LUAU_SNAPSHOT_V1_PROTO_IR_FUNCTION_ID,
               uint32_t(protoIndex));
    }

    return true;
}

bool serializeIr(const std::vector<ProtoRef> &protos, std::vector<SectionData> &sections,
                 uint32_t &failureStatus, std::string &error) {
    SectionData &functions = section(sections, MC_LUAU_SNAPSHOT_V1_IR_FUNCTIONS);
    SectionData &blocks = section(sections, MC_LUAU_SNAPSHOT_V1_IR_BLOCKS);
    SectionData &instructions = section(sections, MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTIONS);
    SectionData &operands = section(sections, MC_LUAU_SNAPSHOT_V1_IR_OPERANDS);
    SectionData &constants = section(sections, MC_LUAU_SNAPSHOT_V1_IR_CONSTANTS);
    SectionData &mapping = section(sections, MC_LUAU_SNAPSHOT_V1_BC_MAPPING);

    size_t totalInstructions = 0;
    HostIrHooks hooks{};

    for (size_t functionIndex = 0; functionIndex < protos.size(); ++functionIndex) {
        Proto *proto = protos[functionIndex].proto;
        IrBuilder builder(hooks);
        builder.buildFunctionIr(proto);

        if (totalInstructions + builder.function.instructions.size() >= kMaxInstructions) {
            failureStatus = MC_LUAU_SNAPSHOT_V1_RESOURCE_LIMIT;
            error = "frontend IR instruction resource limit";
            return false;
        }
        totalInstructions += builder.function.instructions.size();

        // This is the target-neutral prefix of pinned upstream lowerFunction. The frontend options
        // are pinned to upstream defaults: DebugCodegenOptSize=false, so linearization is always
        // enabled here. The instruction/block limits above are likewise contract values. There are
        // no fixture-dependent switches and no native-backend passes.
        killUnusedBlocks(builder.function);

        size_t liveBlocks = 0;
        size_t maxBlockInstructions = 0;
        for (const IrBlock &block : builder.function.blocks) {
            liveBlocks += block.kind != IrBlockKind::Dead;
            maxBlockInstructions =
                std::max(maxBlockInstructions, size_t(block.finish - block.start));
        }
        if (liveBlocks >= kMaxBlocksPerFunction ||
            maxBlockInstructions >= kMaxInstructionsPerBlock) {
            failureStatus = MC_LUAU_SNAPSHOT_V1_RESOURCE_LIMIT;
            error = "frontend IR block resource limit";
            return false;
        }

        computeCfgInfo(builder.function);
        constPropInBlockChains(builder);
        createLinearBlocks(builder);
        computeCfgBlockEdges(builder.function);
        updateUseCounts(builder.function);

        size_t functionRecord = appendRecord(functions);
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_ID,
               uint32_t(functionIndex));
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_PROTO_ID,
               uint32_t(functionIndex));
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_ENTRY_BLOCK,
               builder.function.entryBlock);
        functions.bytes[functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_VARIADIC] =
            builder.function.variadic ? 1 : 0;

        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BLOCK_START,
               recordCount(blocks));
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BLOCK_COUNT,
               uint32_t(builder.function.blocks.size()));
        for (const IrBlock &block : builder.function.blocks) {
            size_t blockRecord = appendRecord(blocks);
            blocks.bytes[blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_KIND] = uint8_t(block.kind);
            blocks.bytes[blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_FLAGS] = block.flags;
            putU16(blocks.bytes, blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_USE_COUNT,
                   block.useCount);
            putU32(blocks.bytes, blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_START, block.start);
            putU32(blocks.bytes, blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_FINISH, block.finish);
            putU32(blocks.bytes, blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_SORT_KEY,
                   block.sortkey);
            putU32(blocks.bytes, blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_CHAIN_KEY,
                   block.chainkey);
            putU32(blocks.bytes, blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_EXPECTED_NEXT,
                   block.expectedNextBlock);
            putU32(blocks.bytes, blockRecord + MC_LUAU_SNAPSHOT_V1_IR_BLOCK_START_PC,
                   block.startpc);
        }

        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_INSTRUCTION_START,
               recordCount(instructions));
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_INSTRUCTION_COUNT,
               uint32_t(builder.function.instructions.size()));
        const uint32_t operandStart = recordCount(operands);
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_OPERAND_START,
               operandStart);
        for (const IrInst &instruction : builder.function.instructions) {
            size_t instructionRecord = appendRecord(instructions);
            instructions.bytes[instructionRecord + MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_CMD] =
                uint8_t(instruction.cmd);
            putU16(instructions.bytes,
                   instructionRecord + MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_USE_COUNT,
                   instruction.useCount);
            putU32(instructions.bytes,
                   instructionRecord + MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_LAST_USE,
                   MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID);
            putU32(instructions.bytes,
                   instructionRecord + MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_OPERAND_START,
                   recordCount(operands));
            putU32(instructions.bytes,
                   instructionRecord + MC_LUAU_SNAPSHOT_V1_IR_INSTRUCTION_OPERAND_COUNT,
                   uint32_t(instruction.ops.size()));
            for (const IrOp &operand : instruction.ops) {
                size_t operandRecord = appendRecord(operands);
                operands.bytes[operandRecord] = uint8_t(operand.kind);
                putU32(operands.bytes, operandRecord + 4, operand.index);
            }
        }
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_OPERAND_COUNT,
               recordCount(operands) - operandStart);

        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_CONSTANT_START,
               recordCount(constants));
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_CONSTANT_COUNT,
               uint32_t(builder.function.constants.size()));
        for (const IrConst &constant : builder.function.constants) {
            size_t constantRecord = appendRecord(constants);
            constants.bytes[constantRecord] = uint8_t(constant.kind);
            uint64_t bits = 0;
            switch (constant.kind) {
            case IrConstKind::Int:
                bits = uint64_t(int64_t(constant.valueInt));
                break;
            case IrConstKind::Int64:
                bits = uint64_t(constant.valueInt64);
                break;
            case IrConstKind::Uint:
            case IrConstKind::Import:
                bits = constant.valueUint;
                break;
            case IrConstKind::Double:
                memcpy(&bits, &constant.valueDouble, sizeof(bits));
                break;
            case IrConstKind::Tag:
                bits = constant.valueTag;
                break;
            }
            putU64(constants.bytes, constantRecord + 8, bits);
        }

        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BC_MAPPING_START,
               recordCount(mapping));
        putU32(functions.bytes, functionRecord + MC_LUAU_SNAPSHOT_V1_IR_FUNCTION_BC_MAPPING_COUNT,
               uint32_t(builder.function.bcMapping.size()));
        for (const BytecodeMapping &entry : builder.function.bcMapping) {
            size_t mappingRecord = appendRecord(mapping);
            putU32(mapping.bytes, mappingRecord, entry.irLocation);
            putU32(mapping.bytes, mappingRecord + 4, entry.asmLocation);
        }
    }

    return true;
}

bool buildWireImage(std::vector<SectionData> &sections, uint32_t protoCount, uint32_t stringCount,
                    std::vector<uint8_t> &output, std::string &error) {
    const size_t directoryBytes = sections.size() * MC_LUAU_FRONTEND_SNAPSHOT_V1_SECTION_SIZE;
    size_t totalSize = MC_LUAU_FRONTEND_SNAPSHOT_V1_HEADER_SIZE + directoryBytes;
    for (const SectionData &item : sections) {
        if (item.bytes.size() % item.recordSize != 0 ||
            totalSize + item.bytes.size() > kMaxSnapshotBytes) {
            error = "frontend snapshot resource or record-size limit";
            return false;
        }
        totalSize += item.bytes.size();
    }

    output.assign(MC_LUAU_FRONTEND_SNAPSHOT_V1_HEADER_SIZE + directoryBytes, 0);
    memcpy(output.data() + MC_LUAU_SNAPSHOT_V1_H_MAGIC, MC_LUAU_FRONTEND_SNAPSHOT_V1_MAGIC, 8);
    putU16(output, MC_LUAU_SNAPSHOT_V1_H_VERSION, MC_LUAU_FRONTEND_SNAPSHOT_V1_VERSION);
    putU16(output, MC_LUAU_SNAPSHOT_V1_H_HEADER_SIZE, MC_LUAU_FRONTEND_SNAPSHOT_V1_HEADER_SIZE);
    putU32(output, MC_LUAU_SNAPSHOT_V1_H_FLAGS, MC_LUAU_FRONTEND_SNAPSHOT_V1_REQUIRED_FLAGS);
    putU64(output, MC_LUAU_SNAPSHOT_V1_H_TOTAL_SIZE, totalSize);
    memcpy(output.data() + MC_LUAU_SNAPSHOT_V1_H_LUAU_PIN_SHA256, kLuauPinSha256, 32);
    memcpy(output.data() + MC_LUAU_SNAPSHOT_V1_H_PATCHSET_SHA256, kPatchsetSha256, 32);
    memcpy(output.data() + MC_LUAU_SNAPSHOT_V1_H_FRONTEND_BUILD_SHA256, kFrontendBuildSha256, 32);
    memcpy(output.data() + MC_LUAU_SNAPSHOT_V1_H_IR_ENUM_SHA256, kIrEnumSha256, 32);
    memcpy(output.data() + MC_LUAU_SNAPSHOT_V1_H_LAYOUT_SHA256, kLayoutSha256, 32);
    putU32(output, MC_LUAU_SNAPSHOT_V1_H_MODULE_COUNT, 1);
    putU32(output, MC_LUAU_SNAPSHOT_V1_H_PROTO_COUNT, protoCount);
    putU32(output, MC_LUAU_SNAPSHOT_V1_H_IR_FUNCTION_COUNT, protoCount);
    putU32(output, MC_LUAU_SNAPSHOT_V1_H_STRING_COUNT, stringCount);
    putU32(output, MC_LUAU_SNAPSHOT_V1_H_ROOT_PROTO_ID, 0);
    putU32(output, MC_LUAU_SNAPSHOT_V1_H_SECTION_COUNT, uint32_t(sections.size()));

    uint64_t payloadOffset = output.size();
    for (size_t index = 0; index < sections.size(); ++index) {
        const SectionData &item = sections[index];
        size_t directory = MC_LUAU_FRONTEND_SNAPSHOT_V1_HEADER_SIZE +
                           index * MC_LUAU_FRONTEND_SNAPSHOT_V1_SECTION_SIZE;
        putU16(output, directory + MC_LUAU_SNAPSHOT_V1_S_KIND, item.kind);
        putU32(output, directory + MC_LUAU_SNAPSHOT_V1_S_RECORD_SIZE, item.recordSize);
        putU64(output, directory + MC_LUAU_SNAPSHOT_V1_S_OFFSET, payloadOffset);
        putU64(output, directory + MC_LUAU_SNAPSHOT_V1_S_LENGTH, item.bytes.size());
        putU32(output, directory + MC_LUAU_SNAPSHOT_V1_S_COUNT, recordCount(item));
        output.insert(output.end(), item.bytes.begin(), item.bytes.end());
        payloadOffset += item.bytes.size();
    }

    return output.size() == totalSize;
}

} // namespace

extern "C" uint32_t mc_luau_frontend_snapshot_v1_compile(const uint8_t *source, size_t sourceSize,
                                                         const uint8_t *chunkName,
                                                         size_t chunkNameSize,
                                                         McLuauFrontendSnapshotV1Result *result) {
    if (!result)
        return MC_LUAU_SNAPSHOT_V1_INVALID_ARGUMENT;
    memset(result, 0, sizeof(*result));

    if ((!source && sourceSize != 0) || (!chunkName && chunkNameSize != 0) ||
        sourceSize > kMaxSourceBytes || chunkNameSize > 4096) {
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_INVALID_ARGUMENT,
                      "invalid frontend source or chunk name");
        return result->status;
    }
    if (chunkName && memchr(chunkName, 0, chunkNameSize)) {
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_INVALID_ARGUMENT, "chunk name contains NUL");
        return result->status;
    }

    size_t bytecodeSize = 0;
    const char *sourceBytes = sourceSize ? reinterpret_cast<const char *>(source) : "";
    char *bytecode = luau_compile(sourceBytes, sourceSize, nullptr, &bytecodeSize);
    if (!bytecode || bytecodeSize == 0 || bytecodeSize > kMaxBytecodeBytes) {
        free(bytecode);
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_COMPILE_ERROR,
                      "luau_compile failed or exceeded bytecode limit");
        return result->status;
    }
    if (bytecode[0] == 0) {
        size_t messageOffset = 1;
        size_t messageSize = bytecodeSize > messageOffset ? bytecodeSize - messageOffset : 0;
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_COMPILE_ERROR, bytecode + messageOffset,
                      messageSize);
        free(bytecode);
        return result->status;
    }

    lua_State *state = luaL_newstate();
    if (!state) {
        free(bytecode);
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_INTERNAL_ERROR, "luaL_newstate failed");
        return result->status;
    }

    std::string chunk = chunkNameSize
                            ? std::string(reinterpret_cast<const char *>(chunkName), chunkNameSize)
                            : std::string("=aot");
    int loadStatus = luau_load(state, chunk.c_str(), bytecode, bytecodeSize, 0);
    if (loadStatus != 0) {
        const char *message = lua_tostring(state, -1);
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_LOAD_ERROR,
                      message ? message : "luau_load failed");
        lua_close(state);
        free(bytecode);
        return result->status;
    }

    const TValue *loaded = luaA_toobject(state, -1);
    if (!loaded || !ttisfunction(loaded) || clvalue(loaded)->isC || !clvalue(loaded)->l.p) {
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_INTERNAL_ERROR, "loaded chunk has no Luau Proto");
        lua_close(state);
        free(bytecode);
        return result->status;
    }

    std::vector<ProtoRef> protos;
    if (!collectProtos(clvalue(loaded)->l.p, MC_LUAU_FRONTEND_SNAPSHOT_V1_NO_ID, protos)) {
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_RESOURCE_LIMIT,
                      "Proto graph is invalid or exceeds limit");
        lua_close(state);
        free(bytecode);
        return result->status;
    }

    std::vector<SectionData> sections = makeSections();
    SectionData &compiledBytecode = section(sections, MC_LUAU_SNAPSHOT_V1_COMPILED_BYTECODE);
    appendBytes(compiledBytecode, bytecode, bytecodeSize);

    StringTable strings{
        section(sections, MC_LUAU_SNAPSHOT_V1_STRINGS),
        section(sections, MC_LUAU_SNAPSHOT_V1_STRING_BYTES),
        {},
        false,
    };
    std::string error;
    uint32_t failureStatus = MC_LUAU_SNAPSHOT_V1_UNSUPPORTED_FRONTEND_VALUE;
    bool ok = !containsUndecodedImport(protos);
    if (!ok)
        error = "import constant decoding is not implemented in FrontendSnapshotV1";
    if (ok)
        ok = serializeProtoMetadata(protos, sections, strings, failureStatus, error);
    if (ok && strings.failed) {
        failureStatus = MC_LUAU_SNAPSHOT_V1_RESOURCE_LIMIT;
        error = "frontend string table resource limit";
        ok = false;
    }
    if (ok)
        ok = serializeIr(protos, sections, failureStatus, error);

    lua_close(state);
    free(bytecode);

    if (!ok) {
        setDiagnostic(result, failureStatus, error);
        return result->status;
    }

    std::vector<uint8_t> snapshot;
    if (!buildWireImage(sections, uint32_t(protos.size()), uint32_t(strings.values.size()),
                        snapshot, error)) {
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_RESOURCE_LIMIT, error);
        return result->status;
    }

    result->data = static_cast<uint8_t *>(malloc(snapshot.size()));
    if (!result->data) {
        setDiagnostic(result, MC_LUAU_SNAPSHOT_V1_INTERNAL_ERROR, "snapshot allocation failed");
        return result->status;
    }
    memcpy(result->data, snapshot.data(), snapshot.size());
    result->size = snapshot.size();
    result->status = MC_LUAU_SNAPSHOT_V1_OK;
    return result->status;
}

extern "C" void mc_luau_frontend_snapshot_v1_free(McLuauFrontendSnapshotV1Result *result) {
    if (!result)
        return;
    free(result->data);
    free(result->diagnostic);
    memset(result, 0, sizeof(*result));
}

extern "C" const char *mc_luau_frontend_snapshot_v1_last_raise_message() {
    return mc_eh::g_sticky_raise;
}

extern "C" size_t mc_luau_frontend_snapshot_v1_last_raise_message_size() {
    return mc_eh::g_sticky_raise_len;
}
