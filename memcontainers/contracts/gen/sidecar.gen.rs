// @generated from contracts/sidecar.kdl by //contracts/codegen:projector — do not edit.
#![no_std]
#![allow(dead_code)]

pub const PROTOCOL_VERSION: u32 = 1;
pub const SIDECAR_MAX_HOSTS: u32 = 16;
pub const SIDECAR_MAX_GRANTS: u32 = 32;
pub const SIDECAR_MAX_INSTANCES_PER_GRANT: u32 = 8;
pub const SIDECAR_MAX_INSTANCES_PER_VM: u32 = 32;
pub const SIDECAR_MAX_INFLIGHT_PER_INSTANCE: u32 = 16;
pub const SIDECAR_MAX_INFLIGHT_PER_VM: u32 = 64;
pub const SIDECAR_MAX_REQUEST_BYTES: u32 = 1048576;
pub const SIDECAR_MAX_RESULT_BYTES: u32 = 8388608;
pub const SIDECAR_MAX_NAME_BYTES: u32 = 64;
pub const SIDECAR_MAX_KIND_BYTES: u32 = 96;
pub const SIDECAR_MAX_DIGEST_BYTES: u32 = 96;
pub const SIDECAR_MAX_OPERATION_BYTES: u32 = 128;
pub const SIDECAR_MAX_IDEMPOTENCY_BYTES: u32 = 128;
pub const SIDECAR_WARNING_BUFFER: u32 = 64;
pub const SIDECAR_DEFAULT_OPERATION_TIMEOUT_MS: u32 = 60000;
pub const SIDECAR_MAX_OPERATION_TIMEOUT_MS: u32 = 300000;
pub const SIDECAR_DEFAULT_LEASE_TTL_MS: u32 = 60000;
pub const SIDECAR_DEFAULT_RENEW_MS: u32 = 20000;
pub const SIDECAR_MIN_LEASE_TTL_MS: u32 = 100;
pub const SIDECAR_MAX_LEASE_TTL_MS: u32 = 300000;
pub const SIDECAR_MIN_RENEW_MS: u32 = 10;
pub const SIDECAR_MAX_RENEW_MS: u32 = 30000;
pub const SIDECAR_HOST_BINDING: &str = "mc.sidecar";
pub const SIDECAR_ERROR_CANCELLED: &str = "cancelled";
pub const SIDECAR_ERROR_CLOSING: &str = "sidecar_closing";
pub const SIDECAR_ERROR_CONTRACT_MISMATCH: &str = "sidecar_contract_mismatch";
pub const SIDECAR_ERROR_DETACHED: &str = "sidecar_detached";
pub const SIDECAR_ERROR_GRANT_EXISTS: &str = "sidecar_grant_exists";
pub const SIDECAR_ERROR_GRANT_MISSING: &str = "sidecar_grant_missing";
pub const SIDECAR_ERROR_HOST_MISSING: &str = "sidecar_host_missing";
pub const SIDECAR_ERROR_IDEMPOTENCY_CONFLICT: &str = "sidecar_idempotency_conflict";
pub const SIDECAR_ERROR_IN_USE: &str = "sidecar_in_use";
pub const SIDECAR_ERROR_INVALID_REQUEST: &str = "sidecar_invalid_request";
pub const SIDECAR_ERROR_LIMIT: &str = "sidecar_limit";
pub const SIDECAR_ERROR_NOT_FOUND: &str = "sidecar_not_found";
pub const SIDECAR_ERROR_NOT_READY: &str = "sidecar_not_ready";
pub const SIDECAR_ERROR_PERMISSION_DENIED: &str = "sidecar_permission_denied";
pub const SIDECAR_ERROR_PROVIDER_FAILED: &str = "sidecar_provider_failed";
pub const SIDECAR_ERROR_SCOPE_MISSING: &str = "sidecar_scope_missing";
pub const SIDECAR_ERROR_STALE_GENERATION: &str = "sidecar_stale_generation";
pub const SIDECAR_ERROR_TIMEOUT: &str = "timeout";
pub const SIDECAR_ERROR_UNAVAILABLE: &str = "sidecar_unavailable";
pub const SIDECAR_ERROR_UNSUPPORTED_FORK_POLICY: &str = "sidecar_unsupported_fork_policy";
pub const SIDECAR_WARNING_FORK_OMITTED: &str = "sidecar_fork_omitted";
pub const SIDECAR_STATE_ALLOCATING: u32 = 1;
pub const SIDECAR_STATE_STARTING: u32 = 2;
pub const SIDECAR_STATE_READY: u32 = 3;
pub const SIDECAR_STATE_SUSPENDED: u32 = 4;
pub const SIDECAR_STATE_FAILED: u32 = 5;
pub const SIDECAR_STATE_CLOSING: u32 = 6;
pub const SIDECAR_STATE_CLOSED: u32 = 7;
pub const SIDECAR_STATE_DETACHED: u32 = 8;
pub const SIDECAR_FORK_OMIT: u32 = 1;
pub const SIDECAR_FORK_CLONE: u32 = 2;

extern crate alloc;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WireError { WrongMessage, UnsupportedVersion, Truncated, InvalidUtf8, NonCanonicalMap, InvalidPresence, TrailingBytes }

fn ctl_put_u16(out: &mut Vec<u8>, v: u16) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_u32(out: &mut Vec<u8>, v: u32) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_i32(out: &mut Vec<u8>, v: i32) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_i64(out: &mut Vec<u8>, v: i64) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_bool(out: &mut Vec<u8>, v: bool) { out.push(if v { 1 } else { 0 }); }
fn ctl_put_bytes(out: &mut Vec<u8>, v: &[u8]) { ctl_put_u32(out, v.len() as u32); out.extend_from_slice(v); }
fn ctl_put_str(out: &mut Vec<u8>, v: &str) { ctl_put_bytes(out, v.as_bytes()); }
fn ctl_put_strmap(out: &mut Vec<u8>, v: &BTreeMap<String, String>) { ctl_put_u32(out, v.len() as u32); for (k, val) in v { ctl_put_str(out, k); ctl_put_str(out, val); } }
fn ctl_put_message_list<T, F>(out: &mut Vec<u8>, values: &[T], mut encode: F) where F: FnMut(&T) -> Vec<u8> { ctl_put_u32(out, values.len() as u32); for value in values { let frame = encode(value); ctl_put_bytes(out, &frame); } }
fn ctl_need<'a>(bytes: &'a [u8], off: &mut usize, len: usize) -> Result<&'a [u8], WireError> { let end = off.checked_add(len).ok_or(WireError::Truncated)?; if end > bytes.len() { return Err(WireError::Truncated); } let out = &bytes[*off..end]; *off = end; Ok(out) }
fn ctl_read_u8(bytes: &[u8], off: &mut usize) -> Result<u8, WireError> { Ok(ctl_need(bytes, off, 1)?[0]) }
fn ctl_read_u16(bytes: &[u8], off: &mut usize) -> Result<u16, WireError> { let b = ctl_need(bytes, off, 2)?; Ok(u16::from_le_bytes([b[0], b[1]])) }
fn ctl_read_u32(bytes: &[u8], off: &mut usize) -> Result<u32, WireError> { let b = ctl_need(bytes, off, 4)?; Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]])) }
fn ctl_read_i32(bytes: &[u8], off: &mut usize) -> Result<i32, WireError> { let b = ctl_need(bytes, off, 4)?; Ok(i32::from_le_bytes([b[0], b[1], b[2], b[3]])) }
fn ctl_read_i64(bytes: &[u8], off: &mut usize) -> Result<i64, WireError> { let b = ctl_need(bytes, off, 8)?; Ok(i64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])) }
fn ctl_read_bool(bytes: &[u8], off: &mut usize) -> Result<bool, WireError> { match ctl_read_u8(bytes, off)? { 0 => Ok(false), 1 => Ok(true), _ => Err(WireError::InvalidPresence) } }
fn ctl_read_bytes(bytes: &[u8], off: &mut usize) -> Result<Vec<u8>, WireError> { let len = ctl_read_u32(bytes, off)? as usize; Ok(ctl_need(bytes, off, len)?.to_vec()) }
fn ctl_read_str(bytes: &[u8], off: &mut usize) -> Result<String, WireError> { String::from_utf8(ctl_read_bytes(bytes, off)?).map_err(|_| WireError::InvalidUtf8) }
fn ctl_read_strmap(bytes: &[u8], off: &mut usize) -> Result<BTreeMap<String, String>, WireError> { let n = ctl_read_u32(bytes, off)? as usize; if n > bytes.len().saturating_sub(*off) / 8 { return Err(WireError::Truncated); } let mut out = BTreeMap::new(); let mut prev: Option<String> = None; for _ in 0..n { let k = ctl_read_str(bytes, off)?; if prev.as_ref().map_or(false, |p| p >= &k) { return Err(WireError::NonCanonicalMap); } let v = ctl_read_str(bytes, off)?; prev = Some(k.clone()); out.insert(k, v); } Ok(out) }

fn ctl_read_message_list<T, F>(bytes: &[u8], off: &mut usize, mut decode: F) -> Result<Vec<T>, WireError> where F: FnMut(&[u8]) -> Result<T, WireError> { let n = ctl_read_u32(bytes, off)? as usize; if n > bytes.len().saturating_sub(*off) / 4 { return Err(WireError::Truncated); } let mut out = Vec::with_capacity(n); for _ in 0..n { let frame = ctl_read_bytes(bytes, off)?; out.push(decode(&frame)?); } Ok(out) }

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarString {
    pub value: String,
}

pub const SIDECAR_STRING_MSG_ID: u16 = 1;
pub const SIDECAR_STRING_VERSION: u8 = 1;
impl SidecarString {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_STRING_MSG_ID);
        out.push(SIDECAR_STRING_VERSION);
        ctl_put_str(&mut out, &self.value);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_STRING_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_STRING_VERSION { return Err(WireError::UnsupportedVersion); }
        let value = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            value,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarStrings {
    pub items: Vec<SidecarString>,
}

pub const SIDECAR_STRINGS_MSG_ID: u16 = 2;
pub const SIDECAR_STRINGS_VERSION: u8 = 1;
impl SidecarStrings {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_STRINGS_MSG_ID);
        out.push(SIDECAR_STRINGS_VERSION);
        ctl_put_message_list(&mut out, &self.items, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_STRINGS_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_STRINGS_VERSION { return Err(WireError::UnsupportedVersion); }
        let items = ctl_read_message_list(bytes, &mut off, SidecarString::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            items,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarGrant {
    pub name: String,
    pub kind: String,
    pub version: u32,
    pub contract_digest: String,
    pub guest: bool,
    pub max_instances: u32,
    pub fork_policy: u32,
    pub config: Vec<u8>,
}

pub const SIDECAR_GRANT_MSG_ID: u16 = 3;
pub const SIDECAR_GRANT_VERSION: u8 = 1;
impl SidecarGrant {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_GRANT_MSG_ID);
        out.push(SIDECAR_GRANT_VERSION);
        ctl_put_str(&mut out, &self.name);
        ctl_put_str(&mut out, &self.kind);
        ctl_put_u32(&mut out, self.version);
        ctl_put_str(&mut out, &self.contract_digest);
        ctl_put_bool(&mut out, self.guest);
        ctl_put_u32(&mut out, self.max_instances);
        ctl_put_u32(&mut out, self.fork_policy);
        ctl_put_bytes(&mut out, &self.config);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_GRANT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_GRANT_VERSION { return Err(WireError::UnsupportedVersion); }
        let name = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        let version = ctl_read_u32(bytes, &mut off)?;
        let contract_digest = ctl_read_str(bytes, &mut off)?;
        let guest = ctl_read_bool(bytes, &mut off)?;
        let max_instances = ctl_read_u32(bytes, &mut off)?;
        let fork_policy = ctl_read_u32(bytes, &mut off)?;
        let config = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            name,
            kind,
            version,
            contract_digest,
            guest,
            max_instances,
            fork_policy,
            config,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarCapability {
    pub kind: String,
    pub version: u32,
    pub contract_digest: String,
    pub placements: SidecarStrings,
    pub fork_policy: u32,
    pub max_instances_per_vm: u32,
}

pub const SIDECAR_CAPABILITY_MSG_ID: u16 = 4;
pub const SIDECAR_CAPABILITY_VERSION: u8 = 1;
impl SidecarCapability {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_CAPABILITY_MSG_ID);
        out.push(SIDECAR_CAPABILITY_VERSION);
        ctl_put_str(&mut out, &self.kind);
        ctl_put_u32(&mut out, self.version);
        ctl_put_str(&mut out, &self.contract_digest);
        let frame = (&self.placements).encode();
        ctl_put_bytes(&mut out, &frame);
        ctl_put_u32(&mut out, self.fork_policy);
        ctl_put_u32(&mut out, self.max_instances_per_vm);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_CAPABILITY_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_CAPABILITY_VERSION { return Err(WireError::UnsupportedVersion); }
        let kind = ctl_read_str(bytes, &mut off)?;
        let version = ctl_read_u32(bytes, &mut off)?;
        let contract_digest = ctl_read_str(bytes, &mut off)?;
        let placements = SidecarStrings::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        let fork_policy = ctl_read_u32(bytes, &mut off)?;
        let max_instances_per_vm = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            kind,
            version,
            contract_digest,
            placements,
            fork_policy,
            max_instances_per_vm,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarInstance {
    pub id: String,
    pub grant: String,
    pub kind: String,
    pub generation: u32,
    pub state: u32,
    pub created_at_ms: i64,
    pub expires_at_ms: i64,
    pub metadata: Vec<u8>,
}

pub const SIDECAR_INSTANCE_MSG_ID: u16 = 5;
pub const SIDECAR_INSTANCE_VERSION: u8 = 1;
impl SidecarInstance {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_INSTANCE_MSG_ID);
        out.push(SIDECAR_INSTANCE_VERSION);
        ctl_put_str(&mut out, &self.id);
        ctl_put_str(&mut out, &self.grant);
        ctl_put_str(&mut out, &self.kind);
        ctl_put_u32(&mut out, self.generation);
        ctl_put_u32(&mut out, self.state);
        ctl_put_i64(&mut out, self.created_at_ms);
        ctl_put_i64(&mut out, self.expires_at_ms);
        ctl_put_bytes(&mut out, &self.metadata);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_INSTANCE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_INSTANCE_VERSION { return Err(WireError::UnsupportedVersion); }
        let id = ctl_read_str(bytes, &mut off)?;
        let grant = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        let generation = ctl_read_u32(bytes, &mut off)?;
        let state = ctl_read_u32(bytes, &mut off)?;
        let created_at_ms = ctl_read_i64(bytes, &mut off)?;
        let expires_at_ms = ctl_read_i64(bytes, &mut off)?;
        let metadata = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            id,
            grant,
            kind,
            generation,
            state,
            created_at_ms,
            expires_at_ms,
            metadata,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarInstances {
    pub items: Vec<SidecarInstance>,
}

pub const SIDECAR_INSTANCES_MSG_ID: u16 = 6;
pub const SIDECAR_INSTANCES_VERSION: u8 = 1;
impl SidecarInstances {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_INSTANCES_MSG_ID);
        out.push(SIDECAR_INSTANCES_VERSION);
        ctl_put_message_list(&mut out, &self.items, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_INSTANCES_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_INSTANCES_VERSION { return Err(WireError::UnsupportedVersion); }
        let items = ctl_read_message_list(bytes, &mut off, SidecarInstance::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            items,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarCreate {
    pub grant: String,
    pub kind: String,
    pub body: Vec<u8>,
    pub idempotency_key: String,
    pub timeout_ms: i64,
}

pub const SIDECAR_CREATE_MSG_ID: u16 = 7;
pub const SIDECAR_CREATE_VERSION: u8 = 1;
impl SidecarCreate {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_CREATE_MSG_ID);
        out.push(SIDECAR_CREATE_VERSION);
        ctl_put_str(&mut out, &self.grant);
        ctl_put_str(&mut out, &self.kind);
        ctl_put_bytes(&mut out, &self.body);
        ctl_put_str(&mut out, &self.idempotency_key);
        ctl_put_i64(&mut out, self.timeout_ms);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_CREATE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_CREATE_VERSION { return Err(WireError::UnsupportedVersion); }
        let grant = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        let body = ctl_read_bytes(bytes, &mut off)?;
        let idempotency_key = ctl_read_str(bytes, &mut off)?;
        let timeout_ms = ctl_read_i64(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            grant,
            kind,
            body,
            idempotency_key,
            timeout_ms,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarCall {
    pub id: String,
    pub generation: u32,
    pub grant: String,
    pub kind: String,
    pub operation: String,
    pub body: Vec<u8>,
    pub idempotency_key: Option<String>,
    pub timeout_ms: i64,
}

pub const SIDECAR_CALL_MSG_ID: u16 = 8;
pub const SIDECAR_CALL_VERSION: u8 = 1;
impl SidecarCall {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_CALL_MSG_ID);
        out.push(SIDECAR_CALL_VERSION);
        ctl_put_str(&mut out, &self.id);
        ctl_put_u32(&mut out, self.generation);
        ctl_put_str(&mut out, &self.grant);
        ctl_put_str(&mut out, &self.kind);
        ctl_put_str(&mut out, &self.operation);
        ctl_put_bytes(&mut out, &self.body);
        match &self.idempotency_key {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_i64(&mut out, self.timeout_ms);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_CALL_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_CALL_VERSION { return Err(WireError::UnsupportedVersion); }
        let id = ctl_read_str(bytes, &mut off)?;
        let generation = ctl_read_u32(bytes, &mut off)?;
        let grant = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        let operation = ctl_read_str(bytes, &mut off)?;
        let body = ctl_read_bytes(bytes, &mut off)?;
        let idempotency_key = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let timeout_ms = ctl_read_i64(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            id,
            generation,
            grant,
            kind,
            operation,
            body,
            idempotency_key,
            timeout_ms,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarError {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    pub details: Option<Vec<u8>>,
}

pub const SIDECAR_ERROR_MSG_ID: u16 = 9;
pub const SIDECAR_ERROR_VERSION: u8 = 1;
impl SidecarError {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_ERROR_MSG_ID);
        out.push(SIDECAR_ERROR_VERSION);
        ctl_put_str(&mut out, &self.code);
        ctl_put_str(&mut out, &self.message);
        ctl_put_bool(&mut out, self.retryable);
        match &self.details {
            Some(v) => {
                out.push(1);
        ctl_put_bytes(&mut out, v);
            }
            None => out.push(0),
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_ERROR_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_ERROR_VERSION { return Err(WireError::UnsupportedVersion); }
        let code = ctl_read_str(bytes, &mut off)?;
        let message = ctl_read_str(bytes, &mut off)?;
        let retryable = ctl_read_bool(bytes, &mut off)?;
        let details = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            code,
            message,
            retryable,
            details,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarResult {
    pub ok: bool,
    pub body: Vec<u8>,
    pub error: Option<SidecarError>,
}

pub const SIDECAR_RESULT_MSG_ID: u16 = 10;
pub const SIDECAR_RESULT_VERSION: u8 = 1;
impl SidecarResult {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_RESULT_MSG_ID);
        out.push(SIDECAR_RESULT_VERSION);
        ctl_put_bool(&mut out, self.ok);
        ctl_put_bytes(&mut out, &self.body);
        match &self.error {
            Some(v) => {
                out.push(1);
        let frame = (v).encode();
        ctl_put_bytes(&mut out, &frame);
            }
            None => out.push(0),
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_RESULT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_RESULT_VERSION { return Err(WireError::UnsupportedVersion); }
        let ok = ctl_read_bool(bytes, &mut off)?;
        let body = ctl_read_bytes(bytes, &mut off)?;
        let error = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(SidecarError::decode(&ctl_read_bytes(bytes, &mut off)?)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            ok,
            body,
            error,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarWarning {
    pub code: String,
    pub message: String,
    pub kind: Option<String>,
    pub grant: Option<String>,
    pub id: Option<String>,
}

pub const SIDECAR_WARNING_MSG_ID: u16 = 11;
pub const SIDECAR_WARNING_VERSION: u8 = 1;
impl SidecarWarning {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_WARNING_MSG_ID);
        out.push(SIDECAR_WARNING_VERSION);
        ctl_put_str(&mut out, &self.code);
        ctl_put_str(&mut out, &self.message);
        match &self.kind {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.grant {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_WARNING_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_WARNING_VERSION { return Err(WireError::UnsupportedVersion); }
        let code = ctl_read_str(bytes, &mut off)?;
        let message = ctl_read_str(bytes, &mut off)?;
        let kind = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let grant = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            code,
            message,
            kind,
            grant,
            id,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarDelete {
    pub id: String,
    pub generation: u32,
    pub grant: String,
    pub kind: String,
}

pub const SIDECAR_DELETE_MSG_ID: u16 = 12;
pub const SIDECAR_DELETE_VERSION: u8 = 1;
impl SidecarDelete {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_DELETE_MSG_ID);
        out.push(SIDECAR_DELETE_VERSION);
        ctl_put_str(&mut out, &self.id);
        ctl_put_u32(&mut out, self.generation);
        ctl_put_str(&mut out, &self.grant);
        ctl_put_str(&mut out, &self.kind);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_DELETE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_DELETE_VERSION { return Err(WireError::UnsupportedVersion); }
        let id = ctl_read_str(bytes, &mut off)?;
        let generation = ctl_read_u32(bytes, &mut off)?;
        let grant = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            id,
            generation,
            grant,
            kind,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarGet {
    pub id: String,
    pub generation: u32,
    pub grant: String,
    pub kind: String,
}

pub const SIDECAR_GET_MSG_ID: u16 = 13;
pub const SIDECAR_GET_VERSION: u8 = 1;
impl SidecarGet {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_GET_MSG_ID);
        out.push(SIDECAR_GET_VERSION);
        ctl_put_str(&mut out, &self.id);
        ctl_put_u32(&mut out, self.generation);
        ctl_put_str(&mut out, &self.grant);
        ctl_put_str(&mut out, &self.kind);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_GET_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_GET_VERSION { return Err(WireError::UnsupportedVersion); }
        let id = ctl_read_str(bytes, &mut off)?;
        let generation = ctl_read_u32(bytes, &mut off)?;
        let grant = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            id,
            generation,
            grant,
            kind,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SidecarList {
    pub grant: String,
    pub kind: String,
}

pub const SIDECAR_LIST_MSG_ID: u16 = 14;
pub const SIDECAR_LIST_VERSION: u8 = 1;
impl SidecarList {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SIDECAR_LIST_MSG_ID);
        out.push(SIDECAR_LIST_VERSION);
        ctl_put_str(&mut out, &self.grant);
        ctl_put_str(&mut out, &self.kind);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SIDECAR_LIST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SIDECAR_LIST_VERSION { return Err(WireError::UnsupportedVersion); }
        let grant = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            grant,
            kind,
        })
    }
}
