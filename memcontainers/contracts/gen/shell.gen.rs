// @generated from contracts/shell.kdl by //contracts/codegen:projector — do not edit.
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

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Candidate {
    pub value: String,
    pub kind: String,
}

pub const CANDIDATE_MSG_ID: u16 = 1;
pub const CANDIDATE_VERSION: u8 = 1;
impl Candidate {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, CANDIDATE_MSG_ID);
        out.push(CANDIDATE_VERSION);
        ctl_put_str(&mut out, &self.value);
        ctl_put_str(&mut out, &self.kind);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != CANDIDATE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != CANDIDATE_VERSION { return Err(WireError::UnsupportedVersion); }
        let value = ctl_read_str(bytes, &mut off)?;
        let kind = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            value,
            kind,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ProbeRequest {
    pub source: Vec<u8>,
    pub cursor: u32,
    pub interactive: bool,
}

pub const PROBE_REQUEST_MSG_ID: u16 = 2;
pub const PROBE_REQUEST_VERSION: u8 = 1;
impl ProbeRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, PROBE_REQUEST_MSG_ID);
        out.push(PROBE_REQUEST_VERSION);
        ctl_put_bytes(&mut out, &self.source);
        ctl_put_u32(&mut out, self.cursor);
        ctl_put_bool(&mut out, self.interactive);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != PROBE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != PROBE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let source = ctl_read_bytes(bytes, &mut off)?;
        let cursor = ctl_read_u32(bytes, &mut off)?;
        let interactive = ctl_read_bool(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            source,
            cursor,
            interactive,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ProbeResponse {
    pub replace_start: u32,
    pub replace_end: u32,
    pub prefix: String,
    pub context: String,
    pub quote: String,
    pub shell_candidates: Vec<Candidate>,
    pub truncated: bool,
    pub continuation: bool,
}

pub const PROBE_RESPONSE_MSG_ID: u16 = 3;
pub const PROBE_RESPONSE_VERSION: u8 = 1;
impl ProbeResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, PROBE_RESPONSE_MSG_ID);
        out.push(PROBE_RESPONSE_VERSION);
        ctl_put_u32(&mut out, self.replace_start);
        ctl_put_u32(&mut out, self.replace_end);
        ctl_put_str(&mut out, &self.prefix);
        ctl_put_str(&mut out, &self.context);
        ctl_put_str(&mut out, &self.quote);
        ctl_put_message_list(&mut out, &self.shell_candidates, |v| v.encode());
        ctl_put_bool(&mut out, self.truncated);
        ctl_put_bool(&mut out, self.continuation);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != PROBE_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != PROBE_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let replace_start = ctl_read_u32(bytes, &mut off)?;
        let replace_end = ctl_read_u32(bytes, &mut off)?;
        let prefix = ctl_read_str(bytes, &mut off)?;
        let context = ctl_read_str(bytes, &mut off)?;
        let quote = ctl_read_str(bytes, &mut off)?;
        let shell_candidates = ctl_read_message_list(bytes, &mut off, Candidate::decode)?;
        let truncated = ctl_read_bool(bytes, &mut off)?;
        let continuation = ctl_read_bool(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            replace_start,
            replace_end,
            prefix,
            context,
            quote,
            shell_candidates,
            truncated,
            continuation,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RenderRequest {
    pub replace_start: u32,
    pub replace_end: u32,
    pub quote: String,
    pub candidates: Vec<Candidate>,
    pub truncated: bool,
}

pub const RENDER_REQUEST_MSG_ID: u16 = 4;
pub const RENDER_REQUEST_VERSION: u8 = 1;
impl RenderRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, RENDER_REQUEST_MSG_ID);
        out.push(RENDER_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.replace_start);
        ctl_put_u32(&mut out, self.replace_end);
        ctl_put_str(&mut out, &self.quote);
        ctl_put_message_list(&mut out, &self.candidates, |v| v.encode());
        ctl_put_bool(&mut out, self.truncated);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != RENDER_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != RENDER_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let replace_start = ctl_read_u32(bytes, &mut off)?;
        let replace_end = ctl_read_u32(bytes, &mut off)?;
        let quote = ctl_read_str(bytes, &mut off)?;
        let candidates = ctl_read_message_list(bytes, &mut off, Candidate::decode)?;
        let truncated = ctl_read_bool(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            replace_start,
            replace_end,
            quote,
            candidates,
            truncated,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Item {
    pub label: String,
    pub value: String,
    pub kind: String,
}

pub const ITEM_MSG_ID: u16 = 5;
pub const ITEM_VERSION: u8 = 1;
impl Item {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, ITEM_MSG_ID);
        out.push(ITEM_VERSION);
        ctl_put_str(&mut out, &self.label);
        ctl_put_str(&mut out, &self.value);
        ctl_put_str(&mut out, &self.kind);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != ITEM_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != ITEM_VERSION { return Err(WireError::UnsupportedVersion); }
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

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CompletionResult {
    pub replace_start: u32,
    pub replace_end: u32,
    pub common_prefix: String,
    pub items: Vec<Item>,
    pub truncated: bool,
}

pub const COMPLETION_RESULT_MSG_ID: u16 = 6;
pub const COMPLETION_RESULT_VERSION: u8 = 1;
impl CompletionResult {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, COMPLETION_RESULT_MSG_ID);
        out.push(COMPLETION_RESULT_VERSION);
        ctl_put_u32(&mut out, self.replace_start);
        ctl_put_u32(&mut out, self.replace_end);
        ctl_put_str(&mut out, &self.common_prefix);
        ctl_put_message_list(&mut out, &self.items, |v| v.encode());
        ctl_put_bool(&mut out, self.truncated);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != COMPLETION_RESULT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != COMPLETION_RESULT_VERSION { return Err(WireError::UnsupportedVersion); }
        let replace_start = ctl_read_u32(bytes, &mut off)?;
        let replace_end = ctl_read_u32(bytes, &mut off)?;
        let common_prefix = ctl_read_str(bytes, &mut off)?;
        let items = ctl_read_message_list(bytes, &mut off, Item::decode)?;
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


pub const SHELL_EXPORT_NAMES: &[&str] = &[
    "mc_sh_buf",
    "mc_sh_autocomplete",
];

/// The canonical table. A consumer hands its own `$emit!` callback (the kernel's
/// dispatch, the sysroot's extern block, the host's import table) and cannot drift.
#[macro_export]
macro_rules! mc_shell_table {
    ($emit:path) => { $emit! {
        mc_sh_buf => ShBuf (len: u32) [u32];
        mc_sh_autocomplete => ShAutocomplete (request_len: u32) [i32];
    } };
}
pub const CONTEXT_COMMAND: &str = "command";
pub const CONTEXT_PATH: &str = "path";
pub const CONTEXT_DIRECTORY: &str = "directory";
pub const CONTEXT_VARIABLE: &str = "variable";
pub const QUOTE_BARE: &str = "bare";
pub const QUOTE_SINGLE: &str = "single";
pub const QUOTE_DOUBLE: &str = "double";
