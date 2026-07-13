// @generated from contracts/control.kdl by //contracts/codegen:projector — do not edit.
#![no_std]
#![allow(dead_code)]

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

/// Structured host-control exec request. `cmd` still runs under /bin/sh -c; cwd/env/stdin are applied by the kernel at spawn.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ExecRequest {
    pub cmd: String,
    pub cwd: Option<String>,
    pub env: BTreeMap<String, String>,
    pub stdin: Option<Vec<u8>>,
}

pub const EXEC_REQUEST_MSG_ID: u16 = 1;
pub const EXEC_REQUEST_VERSION: u8 = 1;
impl ExecRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, EXEC_REQUEST_MSG_ID);
        out.push(EXEC_REQUEST_VERSION);
        ctl_put_str(&mut out, &self.cmd);
        match &self.cwd {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_strmap(&mut out, &self.env);
        match &self.stdin {
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
        if ctl_read_u16(bytes, &mut off)? != EXEC_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != EXEC_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let cmd = ctl_read_str(bytes, &mut off)?;
        let cwd = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let env = ctl_read_strmap(bytes, &mut off)?;
        let stdin = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            cmd,
            cwd,
            env,
            stdin,
        })
    }
}

/// Structured host-control exec result: process exit code plus captured stdout/stderr bytes.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ExecOutcome {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

pub const EXEC_OUTCOME_MSG_ID: u16 = 2;
pub const EXEC_OUTCOME_VERSION: u8 = 1;
impl ExecOutcome {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, EXEC_OUTCOME_MSG_ID);
        out.push(EXEC_OUTCOME_VERSION);
        ctl_put_i32(&mut out, self.exit_code);
        ctl_put_bytes(&mut out, &self.stdout);
        ctl_put_bytes(&mut out, &self.stderr);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != EXEC_OUTCOME_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != EXEC_OUTCOME_VERSION { return Err(WireError::UnsupportedVersion); }
        let exit_code = ctl_read_i32(bytes, &mut off)?;
        let stdout = ctl_read_bytes(bytes, &mut off)?;
        let stderr = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            exit_code,
            stdout,
            stderr,
        })
    }
}

/// Structured host-control stat result. Size is non-negative; hosts reject negative values.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct FileStat {
    pub size: i64,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub nlink: u32,
    pub mode: u32,
}

pub const FILE_STAT_MSG_ID: u16 = 3;
pub const FILE_STAT_VERSION: u8 = 1;
impl FileStat {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, FILE_STAT_MSG_ID);
        out.push(FILE_STAT_VERSION);
        ctl_put_i64(&mut out, self.size);
        ctl_put_bool(&mut out, self.is_dir);
        ctl_put_bool(&mut out, self.is_symlink);
        ctl_put_u32(&mut out, self.nlink);
        ctl_put_u32(&mut out, self.mode);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != FILE_STAT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != FILE_STAT_VERSION { return Err(WireError::UnsupportedVersion); }
        let size = ctl_read_i64(bytes, &mut off)?;
        let is_dir = ctl_read_bool(bytes, &mut off)?;
        let is_symlink = ctl_read_bool(bytes, &mut off)?;
        let nlink = ctl_read_u32(bytes, &mut off)?;
        let mode = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            size,
            is_dir,
            is_symlink,
            nlink,
            mode,
        })
    }
}

/// One structured host-control directory entry.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
}

pub const DIR_ENTRY_MSG_ID: u16 = 4;
pub const DIR_ENTRY_VERSION: u8 = 1;
impl DirEntry {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, DIR_ENTRY_MSG_ID);
        out.push(DIR_ENTRY_VERSION);
        ctl_put_str(&mut out, &self.name);
        ctl_put_bool(&mut out, self.is_dir);
        ctl_put_bool(&mut out, self.is_symlink);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != DIR_ENTRY_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != DIR_ENTRY_VERSION { return Err(WireError::UnsupportedVersion); }
        let name = ctl_read_str(bytes, &mut off)?;
        let is_dir = ctl_read_bool(bytes, &mut off)?;
        let is_symlink = ctl_read_bool(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            name,
            is_dir,
            is_symlink,
        })
    }
}

/// Structured host-control directory listing.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DirEntries {
    pub entries: Vec<DirEntry>,
}

pub const DIR_ENTRIES_MSG_ID: u16 = 5;
pub const DIR_ENTRIES_VERSION: u8 = 1;
impl DirEntries {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, DIR_ENTRIES_MSG_ID);
        out.push(DIR_ENTRIES_VERSION);
        ctl_put_message_list(&mut out, &self.entries, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != DIR_ENTRIES_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != DIR_ENTRIES_VERSION { return Err(WireError::UnsupportedVersion); }
        let entries = ctl_read_message_list(bytes, &mut off, DirEntry::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            entries,
        })
    }
}

/// Structured host-control resident-service request.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SvcRequest {
    pub service: String,
    pub request: Vec<u8>,
}

pub const SVC_REQUEST_MSG_ID: u16 = 6;
pub const SVC_REQUEST_VERSION: u8 = 1;
impl SvcRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SVC_REQUEST_MSG_ID);
        out.push(SVC_REQUEST_VERSION);
        ctl_put_str(&mut out, &self.service);
        ctl_put_bytes(&mut out, &self.request);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SVC_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SVC_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let service = ctl_read_str(bytes, &mut off)?;
        let request = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            service,
            request,
        })
    }
}

/// Structured host-control resident-service response. Status 0 means the service handled the call; nonzero is a transport errno.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SvcResponse {
    pub status: i32,
    pub body: Vec<u8>,
}

pub const SVC_RESPONSE_MSG_ID: u16 = 7;
pub const SVC_RESPONSE_VERSION: u8 = 1;
impl SvcResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SVC_RESPONSE_MSG_ID);
        out.push(SVC_RESPONSE_VERSION);
        ctl_put_i32(&mut out, self.status);
        ctl_put_bytes(&mut out, &self.body);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SVC_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SVC_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let status = ctl_read_i32(bytes, &mut off)?;
        let body = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            status,
            body,
        })
    }
}

/// Structured BEAM egress relay event. `kind` selects which optional payload fields are present.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RelayEvent {
    pub kind: String,
    pub handle: i32,
    pub request: Option<Vec<u8>>,
    pub name: Option<String>,
    pub body: Option<Vec<u8>>,
    pub key: Option<Vec<u8>>,
    pub value: Option<Vec<u8>>,
    pub prefix: Option<Vec<u8>>,
    pub url: Option<String>,
    pub data: Option<Vec<u8>>,
    pub connection: Option<String>,
    pub method: Option<String>,
    pub origin: Option<String>,
    pub args_digest: Option<String>,
}

pub const RELAY_EVENT_MSG_ID: u16 = 8;
pub const RELAY_EVENT_VERSION: u8 = 1;
impl RelayEvent {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, RELAY_EVENT_MSG_ID);
        out.push(RELAY_EVENT_VERSION);
        ctl_put_str(&mut out, &self.kind);
        ctl_put_i32(&mut out, self.handle);
        match &self.request {
            Some(v) => {
                out.push(1);
        ctl_put_bytes(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.name {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.body {
            Some(v) => {
                out.push(1);
        ctl_put_bytes(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.key {
            Some(v) => {
                out.push(1);
        ctl_put_bytes(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.value {
            Some(v) => {
                out.push(1);
        ctl_put_bytes(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.prefix {
            Some(v) => {
                out.push(1);
        ctl_put_bytes(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.url {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.data {
            Some(v) => {
                out.push(1);
        ctl_put_bytes(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.connection {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.method {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.origin {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.args_digest {
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
        if ctl_read_u16(bytes, &mut off)? != RELAY_EVENT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != RELAY_EVENT_VERSION { return Err(WireError::UnsupportedVersion); }
        let kind = ctl_read_str(bytes, &mut off)?;
        let handle = ctl_read_i32(bytes, &mut off)?;
        let request = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let name = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let body = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let key = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let value = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let prefix = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let url = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let data = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let connection = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let method = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let origin = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let args_digest = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            kind,
            handle,
            request,
            name,
            body,
            key,
            value,
            prefix,
            url,
            data,
            connection,
            method,
            origin,
            args_digest,
        })
    }
}

/// Side-effect-free shell autocomplete query. Cursor is a UTF-8 byte offset; cwd/env overlay the live login-shell context.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AutocompleteRequest {
    pub source: Vec<u8>,
    pub cursor: u32,
    pub cwd: Option<String>,
    pub env: BTreeMap<String, String>,
    pub limit: u32,
}

pub const AUTOCOMPLETE_REQUEST_MSG_ID: u16 = 9;
pub const AUTOCOMPLETE_REQUEST_VERSION: u8 = 1;
impl AutocompleteRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, AUTOCOMPLETE_REQUEST_MSG_ID);
        out.push(AUTOCOMPLETE_REQUEST_VERSION);
        ctl_put_bytes(&mut out, &self.source);
        ctl_put_u32(&mut out, self.cursor);
        match &self.cwd {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_strmap(&mut out, &self.env);
        ctl_put_u32(&mut out, self.limit);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != AUTOCOMPLETE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != AUTOCOMPLETE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let source = ctl_read_bytes(bytes, &mut off)?;
        let cursor = ctl_read_u32(bytes, &mut off)?;
        let cwd = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let env = ctl_read_strmap(bytes, &mut off)?;
        let limit = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            source,
            cursor,
            cwd,
            env,
            limit,
        })
    }
}

/// One autocomplete candidate. Value is quote-safe replacement text; label is presentation text.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AutocompleteItem {
    pub label: String,
    pub value: String,
    pub kind: String,
}

pub const AUTOCOMPLETE_ITEM_MSG_ID: u16 = 10;
pub const AUTOCOMPLETE_ITEM_VERSION: u8 = 1;
impl AutocompleteItem {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, AUTOCOMPLETE_ITEM_MSG_ID);
        out.push(AUTOCOMPLETE_ITEM_VERSION);
        ctl_put_str(&mut out, &self.label);
        ctl_put_str(&mut out, &self.value);
        ctl_put_str(&mut out, &self.kind);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != AUTOCOMPLETE_ITEM_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != AUTOCOMPLETE_ITEM_VERSION { return Err(WireError::UnsupportedVersion); }
        let label = ctl_read_str(bytes, &mut off)?;
        let value = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            label,
            value,
            kind,
        })
    }
}

/// Bounded autocomplete result over the exact source range the caller should replace.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct AutocompleteResult {
    pub replace_start: u32,
    pub replace_end: u32,
    pub common_prefix: String,
    pub items: Vec<AutocompleteItem>,
    pub truncated: bool,
}

pub const AUTOCOMPLETE_RESULT_MSG_ID: u16 = 11;
pub const AUTOCOMPLETE_RESULT_VERSION: u8 = 1;
impl AutocompleteResult {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, AUTOCOMPLETE_RESULT_MSG_ID);
        out.push(AUTOCOMPLETE_RESULT_VERSION);
        ctl_put_u32(&mut out, self.replace_start);
        ctl_put_u32(&mut out, self.replace_end);
        ctl_put_str(&mut out, &self.common_prefix);
        ctl_put_message_list(&mut out, &self.items, |v| v.encode());
        ctl_put_bool(&mut out, self.truncated);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != AUTOCOMPLETE_RESULT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != AUTOCOMPLETE_RESULT_VERSION { return Err(WireError::UnsupportedVersion); }
        let replace_start = ctl_read_u32(bytes, &mut off)?;
        let replace_end = ctl_read_u32(bytes, &mut off)?;
        let common_prefix = ctl_read_str(bytes, &mut off)?;
        let items = ctl_read_message_list(bytes, &mut off, AutocompleteItem::decode)?;
        let truncated = ctl_read_bool(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            replace_start,
            replace_end,
            common_prefix,
            items,
            truncated,
        })
    }
}


pub const CONTROL_EXPORTS: &[&str] = &[
    "mc_init",
    "mc_tick",
    "mc_input",
    "mc_resize",
    "mc_ctl_buf",
    "mc_ctl_read",
    "mc_ctl_readlink",
    "mc_ctl_write",
    "mc_ctl_readdir",
    "mc_ctl_stat",
    "mc_ctl_mkdir",
    "mc_ctl_unlink",
    "mc_ctl_chmod",
    "mc_ctl_symlink",
    "mc_ctl_mount",
    "mc_ctl_unmount",
    "mc_ctl_exec_start",
    "mc_ctl_exec_poll",
    "mc_ctl_exec_peek",
    "mc_ctl_exec_close",
    "mc_ctl_autocomplete",
    "mc_ctl_svc_call_start",
    "mc_ctl_svc_call_poll",
    "mc_ctl_svc_call_close",
    "mc_commit_layer",
    "mc_inflight_egress",
    "mc_pending_commits",
    "mc_worker_count",
    "mc_quiesce_request",
    "mc_quiesce_release",
    "mc_worker_entry",
];

/// The canonical table. A consumer hands its own `$emit!` callback (the kernel's
/// dispatch, the sysroot's extern block, the host's import table) and cannot drift.
#[macro_export]
macro_rules! mc_control_table {
    ($emit:path) => { $emit! {
        mc_init => Init () [i32];
        mc_tick => Tick () [i32];
        mc_input => Input (ptr: cptr, len: len) [void];
        mc_resize => Resize (cols: i32, rows: i32) [void];
        mc_ctl_buf => Buf (len: len) [mptr];
        mc_ctl_read => Read (path_ptr: u32, path_len: u32) [i32];
        mc_ctl_readlink => Readlink (path_ptr: u32, path_len: u32) [i32];
        mc_ctl_write => Write (path_ptr: u32, path_len: u32, data_ptr: u32, data_len: u32) [i32];
        mc_ctl_readdir => Readdir (path_ptr: u32, path_len: u32) [i32];
        mc_ctl_stat => Stat (path_ptr: u32, path_len: u32) [i32];
        mc_ctl_mkdir => Mkdir (path_ptr: u32, path_len: u32) [i32];
        mc_ctl_unlink => Unlink (path_ptr: u32, path_len: u32) [i32];
        mc_ctl_chmod => Chmod (path_ptr: u32, path_len: u32, mode: u32) [i32];
        mc_ctl_symlink => Symlink (target_ptr: u32, target_len: u32, link_ptr: u32, link_len: u32) [i32];
        mc_ctl_mount => Mount (path_ptr: u32, path_len: u32, read_only: i32) [i32];
        mc_ctl_unmount => Unmount (path_ptr: u32, path_len: u32) [i32];
        mc_ctl_exec_start => ExecStart (request_len: u32) [i32];
        mc_ctl_exec_poll => ExecPoll (job_id: u32) [i32];
        mc_ctl_exec_peek => ExecPeek (job_id: u32) [i32];
        mc_ctl_exec_close => ExecClose (job_id: u32) [i32];
        mc_ctl_autocomplete => Autocomplete (request_len: u32) [i32];
        mc_ctl_svc_call_start => SvcCallStart (request_len: u32) [i32];
        mc_ctl_svc_call_poll => SvcCallPoll (job_id: u32) [i32];
        mc_ctl_svc_call_close => SvcCallClose (job_id: u32) [i32];
        mc_commit_layer => CommitLayer () [i32];
        mc_inflight_egress => InflightEgress () [i32];
        mc_pending_commits => PendingCommits () [i32];
        mc_worker_count => WorkerCount () [i32];
        #[cfg(feature = "threads")] mc_quiesce_request => QuiesceRequest () [i32];
        #[cfg(feature = "threads")] mc_quiesce_release => QuiesceRelease () [i32];
        #[cfg(feature = "threads")] mc_worker_entry => WorkerEntry (arg: i32) [i32];
    } };
}
