-- @generated from contracts/syntax.kdl by //contracts/codegen:projector — do not edit.
local M = {}
M.PROTOCOL_VERSION = 1
M.VOCABULARY_VERSION = 1
M.GRAMMAR_IR_VERSION = 2
M.SEMANTIC_KIND_MODULE = 1
M.SEMANTIC_KIND_DECLARATION = 2
M.SEMANTIC_KIND_FUNCTION = 3
M.SEMANTIC_KIND_PARAMETER = 4
M.SEMANTIC_KIND_CALL = 5
M.SEMANTIC_KIND_MEMBER = 6
M.SEMANTIC_KIND_IDENTIFIER = 7
M.SEMANTIC_KIND_LITERAL = 8
M.SEMANTIC_KIND_TYPE = 9
M.SEMANTIC_KIND_BLOCK = 10
M.SEMANTIC_KIND_ASSIGNMENT = 11
M.SEMANTIC_KIND_BRANCH = 12
M.SEMANTIC_KIND_LOOP = 13
M.SEMANTIC_KIND_RETURN = 14
M.SEMANTIC_KIND_IMPORT = 15
M.SEMANTIC_KIND_TABLE = 16
M.SEMANTIC_KIND_FIELD = 17
M.SEMANTIC_KIND_OPERATOR = 18
M.SEMANTIC_KIND_COMMENT = 19
M.SEMANTIC_ROLE_NAME = 1
M.SEMANTIC_ROLE_BODY = 2
M.SEMANTIC_ROLE_PARAMETERS = 3
M.SEMANTIC_ROLE_RECEIVER = 4
M.SEMANTIC_ROLE_ARGUMENTS = 5
M.SEMANTIC_ROLE_CALLEE = 6
M.SEMANTIC_ROLE_LEFT = 7
M.SEMANTIC_ROLE_RIGHT = 8
M.SEMANTIC_ROLE_CONDITION = 9
M.SEMANTIC_ROLE_RETURN_TYPE = 10
M.SEMANTIC_ROLE_VALUE = 11
M.SEMANTIC_ROLE_SOURCE = 12
M.SEMANTIC_TRAIT_DECLARATION = 1
M.SEMANTIC_TRAIT_SCOPE = 2


local function byte(bytes, at)
  local v = string.byte(bytes, at)
  if v == nil then error("syntax wire: truncated frame", 3) end
  return v
end
local function put_u8(v) return string.char(v % 256) end
local function put_u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function put_u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function put_i32(v) if v < 0 then v = v + 4294967296 end return put_u32(v) end
local function put_i64(v)
  local lo = v % 4294967296
  local hi = math.floor(v / 4294967296)
  if hi < 0 then hi = hi + 4294967296 end
  return put_u32(lo) .. put_u32(hi)
end
local function put_bool(v) return put_u8(v and 1 or 0) end
local function put_bytes(v) return put_u32(#v) .. v end
local function put_strmap(values)
  local keys = {}
  for k in values do table.insert(keys, k) end
  table.sort(keys)
  local out = { put_u32(#keys) }
  for _, k in keys do table.insert(out, put_bytes(k)); table.insert(out, put_bytes(values[k])) end
  return table.concat(out)
end
local function put_list(values, encoder)
  local out = { put_u32(#values) }
  for _, value in values do table.insert(out, put_bytes(encoder(value))) end
  return table.concat(out)
end
local function need(bytes, off, n)
  if off + n - 1 > #bytes then error("syntax wire: truncated frame", 3) end
  return string.sub(bytes, off, off + n - 1), off + n
end
local function read_u8(bytes, off) return byte(bytes, off), off + 1 end
local function read_u16(bytes, off)
  return byte(bytes, off) + byte(bytes, off + 1) * 256, off + 2
end
local function read_u32(bytes, off)
  return byte(bytes, off) + byte(bytes, off + 1) * 256 + byte(bytes, off + 2) * 65536 + byte(bytes, off + 3) * 16777216, off + 4
end
local function read_i32(bytes, off)
  local v; v, off = read_u32(bytes, off)
  if v >= 2147483648 then v = v - 4294967296 end
  return v, off
end
local function read_i64(bytes, off)
  local lo, hi; lo, off = read_u32(bytes, off); hi, off = read_u32(bytes, off)
  local v = lo + hi * 4294967296
  if hi >= 2147483648 then v = v - 18446744073709551616 end
  return v, off
end
local function read_bool(bytes, off)
  local v; v, off = read_u8(bytes, off)
  if v ~= 0 and v ~= 1 then error("syntax wire: invalid bool", 3) end
  return v == 1, off
end
local function read_bytes(bytes, off)
  local n; n, off = read_u32(bytes, off)
  return need(bytes, off, n)
end
local function read_strmap(bytes, off)
  local n; n, off = read_u32(bytes, off)
  local out, prev = {}, nil
  for _ = 1, n do
    local k, v; k, off = read_bytes(bytes, off); v, off = read_bytes(bytes, off)
    if prev ~= nil and prev >= k then error("syntax wire: non-canonical map", 3) end
    out[k], prev = v, k
  end
  return out, off
end
local function read_message(bytes, off, decoder)
  local frame; frame, off = read_bytes(bytes, off)
  return decoder(frame), off
end
local function read_list(bytes, off, decoder)
  local n; n, off = read_u32(bytes, off)
  local out = {}
  for i = 1, n do out[i], off = read_message(bytes, off, decoder) end
  return out, off
end
local function header(bytes, expected)
  local id, off = read_u16(bytes, 1)
  local version
  version, off = read_u8(bytes, off)
  if id ~= expected then error("syntax wire: wrong message", 3) end
  if version ~= 1 then error("syntax wire: unsupported version", 3) end
  return off
end
local function finish(bytes, off)
  if off ~= #bytes + 1 then error("syntax wire: trailing bytes", 3) end
end

M.POINT_MSG_ID = 1
M.POINT_VERSION = 1
function M.encode_Point(msg)
  local out = { put_u16(M.POINT_MSG_ID), put_u8(M.POINT_VERSION), put_u32(msg.row), put_u32(msg.column) }
  return table.concat(out)
end
function M.decode_Point(bytes)
  local off = header(bytes, M.POINT_MSG_ID)
  local out = {}
  out.row, off = read_u32(bytes, off)
  out.column, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.RANGE_MSG_ID = 2
M.RANGE_VERSION = 1
function M.encode_Range(msg)
  local out = { put_u16(M.RANGE_MSG_ID), put_u8(M.RANGE_VERSION), put_u32(msg.start_byte), put_u32(msg.end_byte), put_bytes(M.encode_Point(msg.start_point)), put_bytes(M.encode_Point(msg.end_point)) }
  return table.concat(out)
end
function M.decode_Range(bytes)
  local off = header(bytes, M.RANGE_MSG_ID)
  local out = {}
  out.start_byte, off = read_u32(bytes, off)
  out.end_byte, off = read_u32(bytes, off)
  out.start_point, off = read_message(bytes, off, M.decode_Point)
  out.end_point, off = read_message(bytes, off, M.decode_Point)
  finish(bytes, off)
  return out
end

M.SEMANTIC_TRAIT_MSG_ID = 3
M.SEMANTIC_TRAIT_VERSION = 1
function M.encode_SemanticTrait(msg)
  local out = { put_u16(M.SEMANTIC_TRAIT_MSG_ID), put_u8(M.SEMANTIC_TRAIT_VERSION), put_u32(msg.id) }
  return table.concat(out)
end
function M.decode_SemanticTrait(bytes)
  local off = header(bytes, M.SEMANTIC_TRAIT_MSG_ID)
  local out = {}
  out.id, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.DIAGNOSTIC_MSG_ID = 4
M.DIAGNOSTIC_VERSION = 1
function M.encode_Diagnostic(msg)
  local out = { put_u16(M.DIAGNOSTIC_MSG_ID), put_u8(M.DIAGNOSTIC_VERSION), put_bytes(msg.severity), put_bytes(msg.code), put_bytes(msg.message), msg.range == nil and put_u8(0) or (put_u8(1) .. put_bytes(M.encode_Range(msg.range))) }
  return table.concat(out)
end
function M.decode_Diagnostic(bytes)
  local off = header(bytes, M.DIAGNOSTIC_MSG_ID)
  local out = {}
  out.severity, off = read_bytes(bytes, off)
  out.code, off = read_bytes(bytes, off)
  out.message, off = read_bytes(bytes, off)
  local has_range; has_range, off = read_u8(bytes, off)
  if has_range == 1 then out.range, off = read_message(bytes, off, M.decode_Range) elseif has_range ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.LANGUAGE_DESCRIPTOR_MSG_ID = 5
M.LANGUAGE_DESCRIPTOR_VERSION = 1
function M.encode_LanguageDescriptor(msg)
  local out = { put_u16(M.LANGUAGE_DESCRIPTOR_MSG_ID), put_u8(M.LANGUAGE_DESCRIPTOR_VERSION), put_bytes(msg.name), put_bytes(msg.language_version), put_bytes(msg.grammar_version), put_u32(msg.grammar_ir_version), put_u32(msg.vocabulary_version), put_u32(msg.tree_sitter_abi) }
  return table.concat(out)
end
function M.decode_LanguageDescriptor(bytes)
  local off = header(bytes, M.LANGUAGE_DESCRIPTOR_MSG_ID)
  local out = {}
  out.name, off = read_bytes(bytes, off)
  out.language_version, off = read_bytes(bytes, off)
  out.grammar_version, off = read_bytes(bytes, off)
  out.grammar_ir_version, off = read_u32(bytes, off)
  out.vocabulary_version, off = read_u32(bytes, off)
  out.tree_sitter_abi, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.NODE_SUMMARY_MSG_ID = 6
M.NODE_SUMMARY_VERSION = 1
function M.encode_NodeSummary(msg)
  local out = { put_u16(M.NODE_SUMMARY_MSG_ID), put_u8(M.NODE_SUMMARY_VERSION), put_u32(msg.handle), put_bytes(msg.concrete_kind), msg.semantic_kind == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.semantic_kind)), msg.field_role == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.field_role)), put_bytes(M.encode_Range(msg.range)), put_bool(msg.named), put_bool(msg.missing), put_bool(msg.error), put_u32(msg.child_count), put_list(msg.traits, M.encode_SemanticTrait) }
  return table.concat(out)
end
function M.decode_NodeSummary(bytes)
  local off = header(bytes, M.NODE_SUMMARY_MSG_ID)
  local out = {}
  out.handle, off = read_u32(bytes, off)
  out.concrete_kind, off = read_bytes(bytes, off)
  local has_semantic_kind; has_semantic_kind, off = read_u8(bytes, off)
  if has_semantic_kind == 1 then out.semantic_kind, off = read_u32(bytes, off) elseif has_semantic_kind ~= 0 then error("syntax wire: invalid optional", 2) end
  local has_field_role; has_field_role, off = read_u8(bytes, off)
  if has_field_role == 1 then out.field_role, off = read_u32(bytes, off) elseif has_field_role ~= 0 then error("syntax wire: invalid optional", 2) end
  out.range, off = read_message(bytes, off, M.decode_Range)
  out.named, off = read_bool(bytes, off)
  out.missing, off = read_bool(bytes, off)
  out.error, off = read_bool(bytes, off)
  out.child_count, off = read_u32(bytes, off)
  out.traits, off = read_list(bytes, off, M.decode_SemanticTrait)
  finish(bytes, off)
  return out
end

M.CHANGED_RANGE_MSG_ID = 7
M.CHANGED_RANGE_VERSION = 1
function M.encode_ChangedRange(msg)
  local out = { put_u16(M.CHANGED_RANGE_MSG_ID), put_u8(M.CHANGED_RANGE_VERSION), put_bytes(M.encode_Range(msg.range)) }
  return table.concat(out)
end
function M.decode_ChangedRange(bytes)
  local off = header(bytes, M.CHANGED_RANGE_MSG_ID)
  local out = {}
  out.range, off = read_message(bytes, off, M.decode_Range)
  finish(bytes, off)
  return out
end

M.EDIT_MSG_ID = 8
M.EDIT_VERSION = 1
function M.encode_Edit(msg)
  local out = { put_u16(M.EDIT_MSG_ID), put_u8(M.EDIT_VERSION), put_u32(msg.start_byte), put_u32(msg.old_end_byte), put_bytes(msg.replacement) }
  return table.concat(out)
end
function M.decode_Edit(bytes)
  local off = header(bytes, M.EDIT_MSG_ID)
  local out = {}
  out.start_byte, off = read_u32(bytes, off)
  out.old_end_byte, off = read_u32(bytes, off)
  out.replacement, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.REWRITE_EDIT_MSG_ID = 9
M.REWRITE_EDIT_VERSION = 1
function M.encode_RewriteEdit(msg)
  local out = { put_u16(M.REWRITE_EDIT_MSG_ID), put_u8(M.REWRITE_EDIT_VERSION), put_u32(msg.start_byte), put_u32(msg.old_end_byte), put_bytes(msg.expected_sha256), put_bytes(msg.replacement) }
  return table.concat(out)
end
function M.decode_RewriteEdit(bytes)
  local off = header(bytes, M.REWRITE_EDIT_MSG_ID)
  local out = {}
  out.start_byte, off = read_u32(bytes, off)
  out.old_end_byte, off = read_u32(bytes, off)
  out.expected_sha256, off = read_bytes(bytes, off)
  out.replacement, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.CAPTURE_MSG_ID = 10
M.CAPTURE_VERSION = 1
function M.encode_Capture(msg)
  local out = { put_u16(M.CAPTURE_MSG_ID), put_u8(M.CAPTURE_VERSION), put_bytes(msg.name), put_bytes(M.encode_NodeSummary(msg.node)), msg.text == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.text)) }
  return table.concat(out)
end
function M.decode_Capture(bytes)
  local off = header(bytes, M.CAPTURE_MSG_ID)
  local out = {}
  out.name, off = read_bytes(bytes, off)
  out.node, off = read_message(bytes, off, M.decode_NodeSummary)
  local has_text; has_text, off = read_u8(bytes, off)
  if has_text == 1 then out.text, off = read_bytes(bytes, off) elseif has_text ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.LANGUAGES_REQUEST_MSG_ID = 100
M.LANGUAGES_REQUEST_VERSION = 1
function M.encode_LanguagesRequest(msg)
  local out = { put_u16(M.LANGUAGES_REQUEST_MSG_ID), put_u8(M.LANGUAGES_REQUEST_VERSION), put_u32(msg.reserved) }
  return table.concat(out)
end
function M.decode_LanguagesRequest(bytes)
  local off = header(bytes, M.LANGUAGES_REQUEST_MSG_ID)
  local out = {}
  out.reserved, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.OPEN_REQUEST_MSG_ID = 101
M.OPEN_REQUEST_VERSION = 1
function M.encode_OpenRequest(msg)
  local out = { put_u16(M.OPEN_REQUEST_MSG_ID), put_u8(M.OPEN_REQUEST_VERSION), put_bytes(msg.language), put_bytes(msg.source) }
  return table.concat(out)
end
function M.decode_OpenRequest(bytes)
  local off = header(bytes, M.OPEN_REQUEST_MSG_ID)
  local out = {}
  out.language, off = read_bytes(bytes, off)
  out.source, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.CLOSE_REQUEST_MSG_ID = 102
M.CLOSE_REQUEST_VERSION = 1
function M.encode_CloseRequest(msg)
  local out = { put_u16(M.CLOSE_REQUEST_MSG_ID), put_u8(M.CLOSE_REQUEST_VERSION), put_u32(msg.document) }
  return table.concat(out)
end
function M.decode_CloseRequest(bytes)
  local off = header(bytes, M.CLOSE_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.TREE_REQUEST_MSG_ID = 103
M.TREE_REQUEST_VERSION = 1
function M.encode_TreeRequest(msg)
  local out = { put_u16(M.TREE_REQUEST_MSG_ID), put_u8(M.TREE_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision), put_bytes(msg.view), put_u32(msg.max_depth), put_u32(msg.limit), msg.cursor == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.cursor)) }
  return table.concat(out)
end
function M.decode_TreeRequest(bytes)
  local off = header(bytes, M.TREE_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  out.view, off = read_bytes(bytes, off)
  out.max_depth, off = read_u32(bytes, off)
  out.limit, off = read_u32(bytes, off)
  local has_cursor; has_cursor, off = read_u8(bytes, off)
  if has_cursor == 1 then out.cursor, off = read_u32(bytes, off) elseif has_cursor ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.NODE_REQUEST_MSG_ID = 104
M.NODE_REQUEST_VERSION = 1
function M.encode_NodeRequest(msg)
  local out = { put_u16(M.NODE_REQUEST_MSG_ID), put_u8(M.NODE_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision), put_u32(msg.node), put_bytes(msg.view) }
  return table.concat(out)
end
function M.decode_NodeRequest(bytes)
  local off = header(bytes, M.NODE_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  out.node, off = read_u32(bytes, off)
  out.view, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.CHILDREN_REQUEST_MSG_ID = 105
M.CHILDREN_REQUEST_VERSION = 1
function M.encode_ChildrenRequest(msg)
  local out = { put_u16(M.CHILDREN_REQUEST_MSG_ID), put_u8(M.CHILDREN_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision), put_u32(msg.node), put_bytes(msg.view), put_bool(msg.named_only), put_u32(msg.limit), msg.cursor == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.cursor)) }
  return table.concat(out)
end
function M.decode_ChildrenRequest(bytes)
  local off = header(bytes, M.CHILDREN_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  out.node, off = read_u32(bytes, off)
  out.view, off = read_bytes(bytes, off)
  out.named_only, off = read_bool(bytes, off)
  out.limit, off = read_u32(bytes, off)
  local has_cursor; has_cursor, off = read_u8(bytes, off)
  if has_cursor == 1 then out.cursor, off = read_u32(bytes, off) elseif has_cursor ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.QUERY_COMPILE_REQUEST_MSG_ID = 106
M.QUERY_COMPILE_REQUEST_VERSION = 1
function M.encode_QueryCompileRequest(msg)
  local out = { put_u16(M.QUERY_COMPILE_REQUEST_MSG_ID), put_u8(M.QUERY_COMPILE_REQUEST_VERSION), put_bytes(msg.language), put_bytes(msg.source), put_bytes(msg.view) }
  return table.concat(out)
end
function M.decode_QueryCompileRequest(bytes)
  local off = header(bytes, M.QUERY_COMPILE_REQUEST_MSG_ID)
  local out = {}
  out.language, off = read_bytes(bytes, off)
  out.source, off = read_bytes(bytes, off)
  out.view, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.QUERY_REQUEST_MSG_ID = 107
M.QUERY_REQUEST_VERSION = 1
function M.encode_QueryRequest(msg)
  local out = { put_u16(M.QUERY_REQUEST_MSG_ID), put_u8(M.QUERY_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision), put_u32(msg.query), msg.range == nil and put_u8(0) or (put_u8(1) .. put_bytes(M.encode_Range(msg.range))), put_bool(msg.include_text), put_u32(msg.limit), msg.cursor == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.cursor)) }
  return table.concat(out)
end
function M.decode_QueryRequest(bytes)
  local off = header(bytes, M.QUERY_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  out.query, off = read_u32(bytes, off)
  local has_range; has_range, off = read_u8(bytes, off)
  if has_range == 1 then out.range, off = read_message(bytes, off, M.decode_Range) elseif has_range ~= 0 then error("syntax wire: invalid optional", 2) end
  out.include_text, off = read_bool(bytes, off)
  out.limit, off = read_u32(bytes, off)
  local has_cursor; has_cursor, off = read_u8(bytes, off)
  if has_cursor == 1 then out.cursor, off = read_u32(bytes, off) elseif has_cursor ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.EDIT_REQUEST_MSG_ID = 108
M.EDIT_REQUEST_VERSION = 1
function M.encode_EditRequest(msg)
  local out = { put_u16(M.EDIT_REQUEST_MSG_ID), put_u8(M.EDIT_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision), put_list(msg.edits, M.encode_Edit) }
  return table.concat(out)
end
function M.decode_EditRequest(bytes)
  local off = header(bytes, M.EDIT_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  out.edits, off = read_list(bytes, off, M.decode_Edit)
  finish(bytes, off)
  return out
end

M.REWRITE_REQUEST_MSG_ID = 109
M.REWRITE_REQUEST_VERSION = 1
function M.encode_RewriteRequest(msg)
  local out = { put_u16(M.REWRITE_REQUEST_MSG_ID), put_u8(M.REWRITE_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision), put_bytes(msg.validation), put_list(msg.edits, M.encode_RewriteEdit) }
  return table.concat(out)
end
function M.decode_RewriteRequest(bytes)
  local off = header(bytes, M.REWRITE_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  out.validation, off = read_bytes(bytes, off)
  out.edits, off = read_list(bytes, off, M.decode_RewriteEdit)
  finish(bytes, off)
  return out
end

M.TEXT_REQUEST_MSG_ID = 110
M.TEXT_REQUEST_VERSION = 1
function M.encode_TextRequest(msg)
  local out = { put_u16(M.TEXT_REQUEST_MSG_ID), put_u8(M.TEXT_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision), msg.range == nil and put_u8(0) or (put_u8(1) .. put_bytes(M.encode_Range(msg.range))) }
  return table.concat(out)
end
function M.decode_TextRequest(bytes)
  local off = header(bytes, M.TEXT_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  local has_range; has_range, off = read_u8(bytes, off)
  if has_range == 1 then out.range, off = read_message(bytes, off, M.decode_Range) elseif has_range ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.DIAGNOSTICS_REQUEST_MSG_ID = 111
M.DIAGNOSTICS_REQUEST_VERSION = 1
function M.encode_DiagnosticsRequest(msg)
  local out = { put_u16(M.DIAGNOSTICS_REQUEST_MSG_ID), put_u8(M.DIAGNOSTICS_REQUEST_VERSION), put_u32(msg.document), put_u32(msg.revision) }
  return table.concat(out)
end
function M.decode_DiagnosticsRequest(bytes)
  local off = header(bytes, M.DIAGNOSTICS_REQUEST_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.QUERY_CLOSE_REQUEST_MSG_ID = 112
M.QUERY_CLOSE_REQUEST_VERSION = 1
function M.encode_QueryCloseRequest(msg)
  local out = { put_u16(M.QUERY_CLOSE_REQUEST_MSG_ID), put_u8(M.QUERY_CLOSE_REQUEST_VERSION), put_u32(msg.query) }
  return table.concat(out)
end
function M.decode_QueryCloseRequest(bytes)
  local off = header(bytes, M.QUERY_CLOSE_REQUEST_MSG_ID)
  local out = {}
  out.query, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.ERROR_RESPONSE_MSG_ID = 200
M.ERROR_RESPONSE_VERSION = 1
function M.encode_ErrorResponse(msg)
  local out = { put_u16(M.ERROR_RESPONSE_MSG_ID), put_u8(M.ERROR_RESPONSE_VERSION), put_bytes(msg.code), put_bytes(msg.message), msg.current_revision == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.current_revision)) }
  return table.concat(out)
end
function M.decode_ErrorResponse(bytes)
  local off = header(bytes, M.ERROR_RESPONSE_MSG_ID)
  local out = {}
  out.code, off = read_bytes(bytes, off)
  out.message, off = read_bytes(bytes, off)
  local has_current_revision; has_current_revision, off = read_u8(bytes, off)
  if has_current_revision == 1 then out.current_revision, off = read_u32(bytes, off) elseif has_current_revision ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.LANGUAGES_RESPONSE_MSG_ID = 201
M.LANGUAGES_RESPONSE_VERSION = 1
function M.encode_LanguagesResponse(msg)
  local out = { put_u16(M.LANGUAGES_RESPONSE_MSG_ID), put_u8(M.LANGUAGES_RESPONSE_VERSION), put_list(msg.languages, M.encode_LanguageDescriptor) }
  return table.concat(out)
end
function M.decode_LanguagesResponse(bytes)
  local off = header(bytes, M.LANGUAGES_RESPONSE_MSG_ID)
  local out = {}
  out.languages, off = read_list(bytes, off, M.decode_LanguageDescriptor)
  finish(bytes, off)
  return out
end

M.OPEN_RESPONSE_MSG_ID = 202
M.OPEN_RESPONSE_VERSION = 1
function M.encode_OpenResponse(msg)
  local out = { put_u16(M.OPEN_RESPONSE_MSG_ID), put_u8(M.OPEN_RESPONSE_VERSION), put_u32(msg.document), put_u32(msg.revision), put_bytes(M.encode_NodeSummary(msg.root)), put_list(msg.diagnostics, M.encode_Diagnostic) }
  return table.concat(out)
end
function M.decode_OpenResponse(bytes)
  local off = header(bytes, M.OPEN_RESPONSE_MSG_ID)
  local out = {}
  out.document, off = read_u32(bytes, off)
  out.revision, off = read_u32(bytes, off)
  out.root, off = read_message(bytes, off, M.decode_NodeSummary)
  out.diagnostics, off = read_list(bytes, off, M.decode_Diagnostic)
  finish(bytes, off)
  return out
end

M.CLOSE_RESPONSE_MSG_ID = 203
M.CLOSE_RESPONSE_VERSION = 1
function M.encode_CloseResponse(msg)
  local out = { put_u16(M.CLOSE_RESPONSE_MSG_ID), put_u8(M.CLOSE_RESPONSE_VERSION), put_u32(msg.reserved) }
  return table.concat(out)
end
function M.decode_CloseResponse(bytes)
  local off = header(bytes, M.CLOSE_RESPONSE_MSG_ID)
  local out = {}
  out.reserved, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.TREE_RESPONSE_MSG_ID = 204
M.TREE_RESPONSE_VERSION = 1
function M.encode_TreeResponse(msg)
  local out = { put_u16(M.TREE_RESPONSE_MSG_ID), put_u8(M.TREE_RESPONSE_VERSION), put_list(msg.nodes, M.encode_NodeSummary), msg.cursor == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.cursor)) }
  return table.concat(out)
end
function M.decode_TreeResponse(bytes)
  local off = header(bytes, M.TREE_RESPONSE_MSG_ID)
  local out = {}
  out.nodes, off = read_list(bytes, off, M.decode_NodeSummary)
  local has_cursor; has_cursor, off = read_u8(bytes, off)
  if has_cursor == 1 then out.cursor, off = read_u32(bytes, off) elseif has_cursor ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.NODE_RESPONSE_MSG_ID = 205
M.NODE_RESPONSE_VERSION = 1
function M.encode_NodeResponse(msg)
  local out = { put_u16(M.NODE_RESPONSE_MSG_ID), put_u8(M.NODE_RESPONSE_VERSION), put_bytes(M.encode_NodeSummary(msg.node)) }
  return table.concat(out)
end
function M.decode_NodeResponse(bytes)
  local off = header(bytes, M.NODE_RESPONSE_MSG_ID)
  local out = {}
  out.node, off = read_message(bytes, off, M.decode_NodeSummary)
  finish(bytes, off)
  return out
end

M.CHILDREN_RESPONSE_MSG_ID = 206
M.CHILDREN_RESPONSE_VERSION = 1
function M.encode_ChildrenResponse(msg)
  local out = { put_u16(M.CHILDREN_RESPONSE_MSG_ID), put_u8(M.CHILDREN_RESPONSE_VERSION), put_list(msg.nodes, M.encode_NodeSummary), msg.cursor == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.cursor)) }
  return table.concat(out)
end
function M.decode_ChildrenResponse(bytes)
  local off = header(bytes, M.CHILDREN_RESPONSE_MSG_ID)
  local out = {}
  out.nodes, off = read_list(bytes, off, M.decode_NodeSummary)
  local has_cursor; has_cursor, off = read_u8(bytes, off)
  if has_cursor == 1 then out.cursor, off = read_u32(bytes, off) elseif has_cursor ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.QUERY_COMPILE_RESPONSE_MSG_ID = 207
M.QUERY_COMPILE_RESPONSE_VERSION = 1
function M.encode_QueryCompileResponse(msg)
  local out = { put_u16(M.QUERY_COMPILE_RESPONSE_MSG_ID), put_u8(M.QUERY_COMPILE_RESPONSE_VERSION), put_u32(msg.query), put_list(msg.diagnostics, M.encode_Diagnostic) }
  return table.concat(out)
end
function M.decode_QueryCompileResponse(bytes)
  local off = header(bytes, M.QUERY_COMPILE_RESPONSE_MSG_ID)
  local out = {}
  out.query, off = read_u32(bytes, off)
  out.diagnostics, off = read_list(bytes, off, M.decode_Diagnostic)
  finish(bytes, off)
  return out
end

M.QUERY_RESPONSE_MSG_ID = 208
M.QUERY_RESPONSE_VERSION = 1
function M.encode_QueryResponse(msg)
  local out = { put_u16(M.QUERY_RESPONSE_MSG_ID), put_u8(M.QUERY_RESPONSE_VERSION), put_list(msg.captures, M.encode_Capture), msg.cursor == nil and put_u8(0) or (put_u8(1) .. put_u32(msg.cursor)) }
  return table.concat(out)
end
function M.decode_QueryResponse(bytes)
  local off = header(bytes, M.QUERY_RESPONSE_MSG_ID)
  local out = {}
  out.captures, off = read_list(bytes, off, M.decode_Capture)
  local has_cursor; has_cursor, off = read_u8(bytes, off)
  if has_cursor == 1 then out.cursor, off = read_u32(bytes, off) elseif has_cursor ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.EDIT_RESPONSE_MSG_ID = 209
M.EDIT_RESPONSE_VERSION = 1
function M.encode_EditResponse(msg)
  local out = { put_u16(M.EDIT_RESPONSE_MSG_ID), put_u8(M.EDIT_RESPONSE_VERSION), put_u32(msg.revision), put_list(msg.changed, M.encode_ChangedRange), put_list(msg.diagnostics, M.encode_Diagnostic) }
  return table.concat(out)
end
function M.decode_EditResponse(bytes)
  local off = header(bytes, M.EDIT_RESPONSE_MSG_ID)
  local out = {}
  out.revision, off = read_u32(bytes, off)
  out.changed, off = read_list(bytes, off, M.decode_ChangedRange)
  out.diagnostics, off = read_list(bytes, off, M.decode_Diagnostic)
  finish(bytes, off)
  return out
end

M.REWRITE_RESPONSE_MSG_ID = 210
M.REWRITE_RESPONSE_VERSION = 1
function M.encode_RewriteResponse(msg)
  local out = { put_u16(M.REWRITE_RESPONSE_MSG_ID), put_u8(M.REWRITE_RESPONSE_VERSION), put_u32(msg.revision), put_list(msg.changed, M.encode_ChangedRange), put_list(msg.diagnostics, M.encode_Diagnostic) }
  return table.concat(out)
end
function M.decode_RewriteResponse(bytes)
  local off = header(bytes, M.REWRITE_RESPONSE_MSG_ID)
  local out = {}
  out.revision, off = read_u32(bytes, off)
  out.changed, off = read_list(bytes, off, M.decode_ChangedRange)
  out.diagnostics, off = read_list(bytes, off, M.decode_Diagnostic)
  finish(bytes, off)
  return out
end

M.TEXT_RESPONSE_MSG_ID = 211
M.TEXT_RESPONSE_VERSION = 1
function M.encode_TextResponse(msg)
  local out = { put_u16(M.TEXT_RESPONSE_MSG_ID), put_u8(M.TEXT_RESPONSE_VERSION), put_bytes(msg.text) }
  return table.concat(out)
end
function M.decode_TextResponse(bytes)
  local off = header(bytes, M.TEXT_RESPONSE_MSG_ID)
  local out = {}
  out.text, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.DIAGNOSTICS_RESPONSE_MSG_ID = 212
M.DIAGNOSTICS_RESPONSE_VERSION = 1
function M.encode_DiagnosticsResponse(msg)
  local out = { put_u16(M.DIAGNOSTICS_RESPONSE_MSG_ID), put_u8(M.DIAGNOSTICS_RESPONSE_VERSION), put_list(msg.diagnostics, M.encode_Diagnostic) }
  return table.concat(out)
end
function M.decode_DiagnosticsResponse(bytes)
  local off = header(bytes, M.DIAGNOSTICS_RESPONSE_MSG_ID)
  local out = {}
  out.diagnostics, off = read_list(bytes, off, M.decode_Diagnostic)
  finish(bytes, off)
  return out
end

M.QUERY_CLOSE_RESPONSE_MSG_ID = 213
M.QUERY_CLOSE_RESPONSE_VERSION = 1
function M.encode_QueryCloseResponse(msg)
  local out = { put_u16(M.QUERY_CLOSE_RESPONSE_MSG_ID), put_u8(M.QUERY_CLOSE_RESPONSE_VERSION), put_u32(msg.reserved) }
  return table.concat(out)
end
function M.decode_QueryCloseResponse(bytes)
  local off = header(bytes, M.QUERY_CLOSE_RESPONSE_MSG_ID)
  local out = {}
  out.reserved, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

return M
