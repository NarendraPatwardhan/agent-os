-- @generated from contracts/sidecar.kdl by //contracts/codegen:projector — do not edit.
local M = {}
M.PROTOCOL_VERSION = 1
M.SIDECAR_MAX_HOSTS = 16
M.SIDECAR_MAX_GRANTS = 32
M.SIDECAR_MAX_INSTANCES_PER_GRANT = 8
M.SIDECAR_MAX_INSTANCES_PER_VM = 32
M.SIDECAR_MAX_INFLIGHT_PER_INSTANCE = 16
M.SIDECAR_MAX_INFLIGHT_PER_VM = 64
M.SIDECAR_MAX_REQUEST_BYTES = 1048576
M.SIDECAR_MAX_RESULT_BYTES = 8388608
M.SIDECAR_MAX_NAME_BYTES = 64
M.SIDECAR_MAX_KIND_BYTES = 96
M.SIDECAR_MAX_DIGEST_BYTES = 96
M.SIDECAR_MAX_OPERATION_BYTES = 128
M.SIDECAR_MAX_IDEMPOTENCY_BYTES = 128
M.SIDECAR_WARNING_BUFFER = 64
M.SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS = 60000
M.SIDECAR_MAX_OPERATION_TIMEOUT_MS = 300000
M.SIDECAR_DEFAULT_LEASE_TTL_MS = 60000
M.SIDECAR_DEFAULT_RENEW_MS = 20000
M.SIDECAR_MIN_LEASE_TTL_MS = 100
M.SIDECAR_MAX_LEASE_TTL_MS = 300000
M.SIDECAR_MIN_RENEW_MS = 10
M.SIDECAR_MAX_RENEW_MS = 30000
M.SIDECAR_HOST_BINDING = "mc.sidecar"
M.SIDECAR_ERROR_CANCELLED = "cancelled"
M.SIDECAR_ERROR_CLOSING = "sidecar_closing"
M.SIDECAR_ERROR_CONTRACT_MISMATCH = "sidecar_contract_mismatch"
M.SIDECAR_ERROR_DETACHED = "sidecar_detached"
M.SIDECAR_ERROR_GRANT_EXISTS = "sidecar_grant_exists"
M.SIDECAR_ERROR_GRANT_MISSING = "sidecar_grant_missing"
M.SIDECAR_ERROR_HOST_MISSING = "sidecar_host_missing"
M.SIDECAR_ERROR_IDEMPOTENCY_CONFLICT = "sidecar_idempotency_conflict"
M.SIDECAR_ERROR_IN_USE = "sidecar_in_use"
M.SIDECAR_ERROR_INVALID_REQUEST = "sidecar_invalid_request"
M.SIDECAR_ERROR_LIMIT = "sidecar_limit"
M.SIDECAR_ERROR_NOT_FOUND = "sidecar_not_found"
M.SIDECAR_ERROR_NOT_READY = "sidecar_not_ready"
M.SIDECAR_ERROR_PERMISSION_DENIED = "sidecar_permission_denied"
M.SIDECAR_ERROR_PROVIDER_FAILED = "sidecar_provider_failed"
M.SIDECAR_ERROR_SCOPE_MISSING = "sidecar_scope_missing"
M.SIDECAR_ERROR_STALE_GENERATION = "sidecar_stale_generation"
M.SIDECAR_ERROR_TIMEOUT = "timeout"
M.SIDECAR_ERROR_UNAVAILABLE = "sidecar_unavailable"
M.SIDECAR_ERROR_UNSUPPORTED_FORK_POLICY = "sidecar_unsupported_fork_policy"
M.SIDECAR_WARNING_FORK_OMITTED = "sidecar_fork_omitted"
M.SIDECAR_STATE_ALLOCATING = 1
M.SIDECAR_STATE_STARTING = 2
M.SIDECAR_STATE_READY = 3
M.SIDECAR_STATE_SUSPENDED = 4
M.SIDECAR_STATE_FAILED = 5
M.SIDECAR_STATE_CLOSING = 6
M.SIDECAR_STATE_CLOSED = 7
M.SIDECAR_STATE_DETACHED = 8
M.SIDECAR_FORK_OMIT = 1
M.SIDECAR_FORK_CLONE = 2


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

M.SIDECAR_STRING_MSG_ID = 1
M.SIDECAR_STRING_VERSION = 1
function M.encode_SidecarString(msg)
  local out = { put_u16(M.SIDECAR_STRING_MSG_ID), put_u8(M.SIDECAR_STRING_VERSION), put_bytes(msg.value) }
  return table.concat(out)
end
function M.decode_SidecarString(bytes)
  local off = header(bytes, M.SIDECAR_STRING_MSG_ID)
  local out = {}
  out.value, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_STRINGS_MSG_ID = 2
M.SIDECAR_STRINGS_VERSION = 1
function M.encode_SidecarStrings(msg)
  local out = { put_u16(M.SIDECAR_STRINGS_MSG_ID), put_u8(M.SIDECAR_STRINGS_VERSION), put_list(msg.items, M.encode_SidecarString) }
  return table.concat(out)
end
function M.decode_SidecarStrings(bytes)
  local off = header(bytes, M.SIDECAR_STRINGS_MSG_ID)
  local out = {}
  out.items, off = read_list(bytes, off, M.decode_SidecarString)
  finish(bytes, off)
  return out
end

M.SIDECAR_GRANT_MSG_ID = 3
M.SIDECAR_GRANT_VERSION = 1
function M.encode_SidecarGrant(msg)
  local out = { put_u16(M.SIDECAR_GRANT_MSG_ID), put_u8(M.SIDECAR_GRANT_VERSION), put_bytes(msg.name), put_bytes(msg.kind), put_u32(msg.version), put_bytes(msg.contract_digest), put_bool(msg.guest), put_u32(msg.max_instances), put_u32(msg.fork_policy), put_bytes(msg.config) }
  return table.concat(out)
end
function M.decode_SidecarGrant(bytes)
  local off = header(bytes, M.SIDECAR_GRANT_MSG_ID)
  local out = {}
  out.name, off = read_bytes(bytes, off)
  out.kind, off = read_bytes(bytes, off)
  out.version, off = read_u32(bytes, off)
  out.contract_digest, off = read_bytes(bytes, off)
  out.guest, off = read_bool(bytes, off)
  out.max_instances, off = read_u32(bytes, off)
  out.fork_policy, off = read_u32(bytes, off)
  out.config, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_CAPABILITY_MSG_ID = 4
M.SIDECAR_CAPABILITY_VERSION = 1
function M.encode_SidecarCapability(msg)
  local out = { put_u16(M.SIDECAR_CAPABILITY_MSG_ID), put_u8(M.SIDECAR_CAPABILITY_VERSION), put_bytes(msg.kind), put_u32(msg.version), put_bytes(msg.contract_digest), put_bytes(M.encode_SidecarStrings(msg.placements)), put_u32(msg.fork_policy), put_u32(msg.max_instances_per_vm) }
  return table.concat(out)
end
function M.decode_SidecarCapability(bytes)
  local off = header(bytes, M.SIDECAR_CAPABILITY_MSG_ID)
  local out = {}
  out.kind, off = read_bytes(bytes, off)
  out.version, off = read_u32(bytes, off)
  out.contract_digest, off = read_bytes(bytes, off)
  out.placements, off = read_message(bytes, off, M.decode_SidecarStrings)
  out.fork_policy, off = read_u32(bytes, off)
  out.max_instances_per_vm, off = read_u32(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_INSTANCE_MSG_ID = 5
M.SIDECAR_INSTANCE_VERSION = 1
function M.encode_SidecarInstance(msg)
  local out = { put_u16(M.SIDECAR_INSTANCE_MSG_ID), put_u8(M.SIDECAR_INSTANCE_VERSION), put_bytes(msg.id), put_bytes(msg.grant), put_bytes(msg.kind), put_u32(msg.generation), put_u32(msg.state), put_i64(msg.created_at_ms), put_i64(msg.expires_at_ms), put_bytes(msg.metadata) }
  return table.concat(out)
end
function M.decode_SidecarInstance(bytes)
  local off = header(bytes, M.SIDECAR_INSTANCE_MSG_ID)
  local out = {}
  out.id, off = read_bytes(bytes, off)
  out.grant, off = read_bytes(bytes, off)
  out.kind, off = read_bytes(bytes, off)
  out.generation, off = read_u32(bytes, off)
  out.state, off = read_u32(bytes, off)
  out.created_at_ms, off = read_i64(bytes, off)
  out.expires_at_ms, off = read_i64(bytes, off)
  out.metadata, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_INSTANCES_MSG_ID = 6
M.SIDECAR_INSTANCES_VERSION = 1
function M.encode_SidecarInstances(msg)
  local out = { put_u16(M.SIDECAR_INSTANCES_MSG_ID), put_u8(M.SIDECAR_INSTANCES_VERSION), put_list(msg.items, M.encode_SidecarInstance) }
  return table.concat(out)
end
function M.decode_SidecarInstances(bytes)
  local off = header(bytes, M.SIDECAR_INSTANCES_MSG_ID)
  local out = {}
  out.items, off = read_list(bytes, off, M.decode_SidecarInstance)
  finish(bytes, off)
  return out
end

M.SIDECAR_CREATE_MSG_ID = 7
M.SIDECAR_CREATE_VERSION = 1
function M.encode_SidecarCreate(msg)
  local out = { put_u16(M.SIDECAR_CREATE_MSG_ID), put_u8(M.SIDECAR_CREATE_VERSION), put_bytes(msg.grant), put_bytes(msg.kind), put_bytes(msg.body), put_bytes(msg.idempotency_key), put_i64(msg.timeout_ms) }
  return table.concat(out)
end
function M.decode_SidecarCreate(bytes)
  local off = header(bytes, M.SIDECAR_CREATE_MSG_ID)
  local out = {}
  out.grant, off = read_bytes(bytes, off)
  out.kind, off = read_bytes(bytes, off)
  out.body, off = read_bytes(bytes, off)
  out.idempotency_key, off = read_bytes(bytes, off)
  out.timeout_ms, off = read_i64(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_CALL_MSG_ID = 8
M.SIDECAR_CALL_VERSION = 1
function M.encode_SidecarCall(msg)
  local out = { put_u16(M.SIDECAR_CALL_MSG_ID), put_u8(M.SIDECAR_CALL_VERSION), put_bytes(msg.id), put_u32(msg.generation), put_bytes(msg.grant), put_bytes(msg.kind), put_bytes(msg.operation), put_bytes(msg.body), msg.idempotency_key == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.idempotency_key)), put_i64(msg.timeout_ms) }
  return table.concat(out)
end
function M.decode_SidecarCall(bytes)
  local off = header(bytes, M.SIDECAR_CALL_MSG_ID)
  local out = {}
  out.id, off = read_bytes(bytes, off)
  out.generation, off = read_u32(bytes, off)
  out.grant, off = read_bytes(bytes, off)
  out.kind, off = read_bytes(bytes, off)
  out.operation, off = read_bytes(bytes, off)
  out.body, off = read_bytes(bytes, off)
  local has_idempotency_key; has_idempotency_key, off = read_u8(bytes, off)
  if has_idempotency_key == 1 then out.idempotency_key, off = read_bytes(bytes, off) elseif has_idempotency_key ~= 0 then error("syntax wire: invalid optional", 2) end
  out.timeout_ms, off = read_i64(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_ERROR_MSG_ID = 9
M.SIDECAR_ERROR_VERSION = 1
function M.encode_SidecarError(msg)
  local out = { put_u16(M.SIDECAR_ERROR_MSG_ID), put_u8(M.SIDECAR_ERROR_VERSION), put_bytes(msg.code), put_bytes(msg.message), put_bool(msg.retryable), msg.details == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.details)) }
  return table.concat(out)
end
function M.decode_SidecarError(bytes)
  local off = header(bytes, M.SIDECAR_ERROR_MSG_ID)
  local out = {}
  out.code, off = read_bytes(bytes, off)
  out.message, off = read_bytes(bytes, off)
  out.retryable, off = read_bool(bytes, off)
  local has_details; has_details, off = read_u8(bytes, off)
  if has_details == 1 then out.details, off = read_bytes(bytes, off) elseif has_details ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.SIDECAR_RESULT_MSG_ID = 10
M.SIDECAR_RESULT_VERSION = 1
function M.encode_SidecarResult(msg)
  local out = { put_u16(M.SIDECAR_RESULT_MSG_ID), put_u8(M.SIDECAR_RESULT_VERSION), put_bool(msg.ok), put_bytes(msg.body), msg.error == nil and put_u8(0) or (put_u8(1) .. put_bytes(M.encode_SidecarError(msg.error))) }
  return table.concat(out)
end
function M.decode_SidecarResult(bytes)
  local off = header(bytes, M.SIDECAR_RESULT_MSG_ID)
  local out = {}
  out.ok, off = read_bool(bytes, off)
  out.body, off = read_bytes(bytes, off)
  local has_error; has_error, off = read_u8(bytes, off)
  if has_error == 1 then out.error, off = read_message(bytes, off, M.decode_SidecarError) elseif has_error ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.SIDECAR_WARNING_MSG_ID = 11
M.SIDECAR_WARNING_VERSION = 1
function M.encode_SidecarWarning(msg)
  local out = { put_u16(M.SIDECAR_WARNING_MSG_ID), put_u8(M.SIDECAR_WARNING_VERSION), put_bytes(msg.code), put_bytes(msg.message), msg.kind == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.kind)), msg.grant == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.grant)), msg.id == nil and put_u8(0) or (put_u8(1) .. put_bytes(msg.id)) }
  return table.concat(out)
end
function M.decode_SidecarWarning(bytes)
  local off = header(bytes, M.SIDECAR_WARNING_MSG_ID)
  local out = {}
  out.code, off = read_bytes(bytes, off)
  out.message, off = read_bytes(bytes, off)
  local has_kind; has_kind, off = read_u8(bytes, off)
  if has_kind == 1 then out.kind, off = read_bytes(bytes, off) elseif has_kind ~= 0 then error("syntax wire: invalid optional", 2) end
  local has_grant; has_grant, off = read_u8(bytes, off)
  if has_grant == 1 then out.grant, off = read_bytes(bytes, off) elseif has_grant ~= 0 then error("syntax wire: invalid optional", 2) end
  local has_id; has_id, off = read_u8(bytes, off)
  if has_id == 1 then out.id, off = read_bytes(bytes, off) elseif has_id ~= 0 then error("syntax wire: invalid optional", 2) end
  finish(bytes, off)
  return out
end

M.SIDECAR_DELETE_MSG_ID = 12
M.SIDECAR_DELETE_VERSION = 1
function M.encode_SidecarDelete(msg)
  local out = { put_u16(M.SIDECAR_DELETE_MSG_ID), put_u8(M.SIDECAR_DELETE_VERSION), put_bytes(msg.id), put_u32(msg.generation), put_bytes(msg.grant), put_bytes(msg.kind) }
  return table.concat(out)
end
function M.decode_SidecarDelete(bytes)
  local off = header(bytes, M.SIDECAR_DELETE_MSG_ID)
  local out = {}
  out.id, off = read_bytes(bytes, off)
  out.generation, off = read_u32(bytes, off)
  out.grant, off = read_bytes(bytes, off)
  out.kind, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_GET_MSG_ID = 13
M.SIDECAR_GET_VERSION = 1
function M.encode_SidecarGet(msg)
  local out = { put_u16(M.SIDECAR_GET_MSG_ID), put_u8(M.SIDECAR_GET_VERSION), put_bytes(msg.id), put_u32(msg.generation), put_bytes(msg.grant), put_bytes(msg.kind) }
  return table.concat(out)
end
function M.decode_SidecarGet(bytes)
  local off = header(bytes, M.SIDECAR_GET_MSG_ID)
  local out = {}
  out.id, off = read_bytes(bytes, off)
  out.generation, off = read_u32(bytes, off)
  out.grant, off = read_bytes(bytes, off)
  out.kind, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

M.SIDECAR_LIST_MSG_ID = 14
M.SIDECAR_LIST_VERSION = 1
function M.encode_SidecarList(msg)
  local out = { put_u16(M.SIDECAR_LIST_MSG_ID), put_u8(M.SIDECAR_LIST_VERSION), put_bytes(msg.grant), put_bytes(msg.kind) }
  return table.concat(out)
end
function M.decode_SidecarList(bytes)
  local off = header(bytes, M.SIDECAR_LIST_MSG_ID)
  local out = {}
  out.grant, off = read_bytes(bytes, off)
  out.kind, off = read_bytes(bytes, off)
  finish(bytes, off)
  return out
end

return M
