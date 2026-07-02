// @generated from contracts/llb.kdl by //contracts/codegen:projector — do not edit.
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
fn ctl_read_strmap(bytes: &[u8], off: &mut usize) -> Result<BTreeMap<String, String>, WireError> { let n = ctl_read_u32(bytes, off)? as usize; let mut out = BTreeMap::new(); let mut prev: Option<String> = None; for _ in 0..n { let k = ctl_read_str(bytes, off)?; if prev.as_ref().map_or(false, |p| p >= &k) { return Err(WireError::NonCanonicalMap); } let v = ctl_read_str(bytes, off)?; prev = Some(k.clone()); out.insert(k, v); } Ok(out) }

fn ctl_read_message_list<T, F>(bytes: &[u8], off: &mut usize, mut decode: F) -> Result<Vec<T>, WireError> where F: FnMut(&[u8]) -> Result<T, WireError> { let n = ctl_read_u32(bytes, off)? as usize; let mut out = Vec::with_capacity(n); for _ in 0..n { let frame = ctl_read_bytes(bytes, off)?; out.push(decode(&frame)?); } Ok(out) }

/// One integer edge into a Definition's topologically ordered op array.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BuildInput {
    pub index: u32,
}
pub const BUILD_INPUT_MSG_ID: u16 = 1;
pub const BUILD_INPUT_VERSION: u8 = 1;
impl BuildInput {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BUILD_INPUT_MSG_ID);
        out.push(BUILD_INPUT_VERSION);
        ctl_put_u32(&mut out, self.index);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BUILD_INPUT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BUILD_INPUT_VERSION { return Err(WireError::UnsupportedVersion); }
        let index = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            index,
        })
    }
}

/// One exact path mapping for a multi-stage copy op.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CopyPath {
    pub src_path: String,
    pub dest_path: String,
}

pub const COPY_PATH_MSG_ID: u16 = 4;
pub const COPY_PATH_VERSION: u8 = 1;
impl CopyPath {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, COPY_PATH_MSG_ID);
        out.push(COPY_PATH_VERSION);
        ctl_put_str(&mut out, &self.src_path);
        ctl_put_str(&mut out, &self.dest_path);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != COPY_PATH_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != COPY_PATH_VERSION { return Err(WireError::UnsupportedVersion); }
        let src_path = ctl_read_str(bytes, &mut off)?;
        let dest_path = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            src_path,
            dest_path,
        })
    }
}

/// One portable LLB op. `kind` is the SDK's closed op enum; unused fields must be absent or empty.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BuildOp {
    pub kind: u32,
    pub source_ref: Option<String>,
    pub input: Option<u32>,
    pub src: Option<u32>,
    pub dest: Option<u32>,
    pub a: Option<u32>,
    pub b: Option<u32>,
    pub lower: Option<u32>,
    pub upper: Option<u32>,
    pub parts: Vec<BuildInput>,
    pub copy_paths: Vec<CopyPath>,
    pub path: Option<String>,
    pub local_path: Option<String>,
    pub http_url: Option<String>,
    pub expected_digest: Option<String>,
    pub git_repo: Option<String>,
    pub git_ref: Option<String>,
    pub dest_path: Option<String>,
    pub data_digest: Option<String>,
    pub target: Option<String>,
    pub link: Option<String>,
    pub mode: Option<u32>,
    pub cmd: Option<String>,
    pub cwd: Option<String>,
    pub env: BTreeMap<String, String>,
    pub stdin: Option<Vec<u8>>,
    pub tier: Option<String>,
    pub budget_mib: Option<u32>,
    pub fuel: Option<u32>,
    pub deterministic: Option<bool>,
    pub net: Option<bool>,
    pub mounts: Vec<BuildInput>,
    pub config_tier: Option<String>,
    pub config_budget_mib: Option<u32>,
    pub config_fuel: Option<u32>,
}

pub const BUILD_OP_MSG_ID: u16 = 2;
pub const BUILD_OP_VERSION: u8 = 1;
impl BuildOp {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BUILD_OP_MSG_ID);
        out.push(BUILD_OP_VERSION);
        ctl_put_u32(&mut out, self.kind);
        match &self.source_ref {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.input {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.src {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.dest {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.a {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.b {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.lower {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.upper {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        ctl_put_message_list(&mut out, &self.parts, |v| v.encode());
        ctl_put_message_list(&mut out, &self.copy_paths, |v| v.encode());
        match &self.path {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.local_path {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.http_url {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.expected_digest {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.git_repo {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.git_ref {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.dest_path {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.data_digest {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.target {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.link {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.mode {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.cmd {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
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
        match &self.tier {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.budget_mib {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.fuel {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.deterministic {
            Some(v) => {
                out.push(1);
        ctl_put_bool(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.net {
            Some(v) => {
                out.push(1);
        ctl_put_bool(&mut out, *v);
            }
            None => out.push(0),
        }
        ctl_put_message_list(&mut out, &self.mounts, |v| v.encode());
        match &self.config_tier {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        match &self.config_budget_mib {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.config_fuel {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BUILD_OP_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BUILD_OP_VERSION { return Err(WireError::UnsupportedVersion); }
        let kind = ctl_read_u32(bytes, &mut off)?;
        let source_ref = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let input = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let src = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let dest = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let a = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let b = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let lower = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let upper = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let parts = ctl_read_message_list(bytes, &mut off, BuildInput::decode)?;
        let copy_paths = ctl_read_message_list(bytes, &mut off, CopyPath::decode)?;
        let path = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let local_path = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let http_url = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let expected_digest = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let git_repo = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let git_ref = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let dest_path = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let data_digest = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let target = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let link = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let mode = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let cmd = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
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
        let tier = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let budget_mib = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let fuel = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let deterministic = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bool(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let net = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bool(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let mounts = ctl_read_message_list(bytes, &mut off, BuildInput::decode)?;
        let config_tier = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let config_budget_mib = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let config_fuel = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            kind,
            source_ref,
            input,
            src,
            dest,
            a,
            b,
            lower,
            upper,
            parts,
            copy_paths,
            path,
            local_path,
            http_url,
            expected_digest,
            git_repo,
            git_ref,
            dest_path,
            data_digest,
            target,
            link,
            mode,
            cmd,
            cwd,
            env,
            stdin,
            tier,
            budget_mib,
            fuel,
            deterministic,
            net,
            mounts,
            config_tier,
            config_budget_mib,
            config_fuel,
        })
    }
}

/// One resolved input edge for a cache-key node digest. Roles are stable names such as input, src, dest, or part:0.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DigestEdge {
    pub role: String,
    pub digest: String,
}

pub const DIGEST_EDGE_MSG_ID: u16 = 5;
pub const DIGEST_EDGE_VERSION: u8 = 1;
impl DigestEdge {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, DIGEST_EDGE_MSG_ID);
        out.push(DIGEST_EDGE_VERSION);
        ctl_put_str(&mut out, &self.role);
        ctl_put_str(&mut out, &self.digest);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != DIGEST_EDGE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != DIGEST_EDGE_VERSION { return Err(WireError::UnsupportedVersion); }
        let role = ctl_read_str(bytes, &mut off)?;
        let digest = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            role,
            digest,
        })
    }
}

/// Resolved layer metadata folded into source-node cache keys.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LayerRef {
    pub producer: String,
    pub digest: String,
    pub size: i64,
}

pub const LAYER_REF_MSG_ID: u16 = 6;
pub const LAYER_REF_VERSION: u8 = 1;
impl LayerRef {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, LAYER_REF_MSG_ID);
        out.push(LAYER_REF_VERSION);
        ctl_put_str(&mut out, &self.producer);
        ctl_put_str(&mut out, &self.digest);
        ctl_put_i64(&mut out, self.size);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != LAYER_REF_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != LAYER_REF_VERSION { return Err(WireError::UnsupportedVersion); }
        let producer = ctl_read_str(bytes, &mut off)?;
        let digest = ctl_read_str(bytes, &mut off)?;
        let size = ctl_read_i64(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            producer,
            digest,
            size,
        })
    }
}

/// Canonical cache-key input for one solved LLB vertex: op args, child digests, resolved mutable-source facts, source layers, and kernel identity when a VM is booted.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NodeDigest {
    pub op: BuildOp,
    pub edges: Vec<DigestEdge>,
    pub resolved: BTreeMap<String, String>,
    pub layers: Vec<LayerRef>,
    pub kernel_digest: Option<String>,
}

pub const NODE_DIGEST_MSG_ID: u16 = 7;
pub const NODE_DIGEST_VERSION: u8 = 1;
impl NodeDigest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, NODE_DIGEST_MSG_ID);
        out.push(NODE_DIGEST_VERSION);
        let frame = (&self.op).encode();
        ctl_put_bytes(&mut out, &frame);
        ctl_put_message_list(&mut out, &self.edges, |v| v.encode());
        ctl_put_strmap(&mut out, &self.resolved);
        ctl_put_message_list(&mut out, &self.layers, |v| v.encode());
        match &self.kernel_digest {
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
        if ctl_read_u16(bytes, &mut off)? != NODE_DIGEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != NODE_DIGEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let op = BuildOp::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        let edges = ctl_read_message_list(bytes, &mut off, DigestEdge::decode)?;
        let resolved = ctl_read_strmap(bytes, &mut off)?;
        let layers = ctl_read_message_list(bytes, &mut off, LayerRef::decode)?;
        let kernel_digest = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            op,
            edges,
            resolved,
            layers,
            kernel_digest,
        })
    }
}

/// A portable LLB build graph. `root` indexes into `ops`; edges only point at earlier ops.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Definition {
    pub version: u32,
    pub ops: Vec<BuildOp>,
    pub root: u32,
}

pub const DEFINITION_MSG_ID: u16 = 3;
pub const DEFINITION_VERSION: u8 = 1;
impl Definition {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, DEFINITION_MSG_ID);
        out.push(DEFINITION_VERSION);
        ctl_put_u32(&mut out, self.version);
        ctl_put_message_list(&mut out, &self.ops, |v| v.encode());
        ctl_put_u32(&mut out, self.root);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != DEFINITION_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != DEFINITION_VERSION { return Err(WireError::UnsupportedVersion); }
        let version = ctl_read_u32(bytes, &mut off)?;
        let ops = ctl_read_message_list(bytes, &mut off, BuildOp::decode)?;
        let root = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            version,
            ops,
            root,
        })
    }
}
