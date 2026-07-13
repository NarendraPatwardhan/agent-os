// @generated from contracts/syntax.kdl by //contracts/codegen:projector — do not edit.
#![no_std]
#![allow(dead_code)]

pub const PROTOCOL_VERSION: u32 = 1;
pub const VOCABULARY_VERSION: u32 = 1;
pub const GRAMMAR_IR_VERSION: u32 = 2;
pub const SEMANTIC_KIND_MODULE: u32 = 1;
pub const SEMANTIC_KIND_DECLARATION: u32 = 2;
pub const SEMANTIC_KIND_FUNCTION: u32 = 3;
pub const SEMANTIC_KIND_PARAMETER: u32 = 4;
pub const SEMANTIC_KIND_CALL: u32 = 5;
pub const SEMANTIC_KIND_MEMBER: u32 = 6;
pub const SEMANTIC_KIND_IDENTIFIER: u32 = 7;
pub const SEMANTIC_KIND_LITERAL: u32 = 8;
pub const SEMANTIC_KIND_TYPE: u32 = 9;
pub const SEMANTIC_KIND_BLOCK: u32 = 10;
pub const SEMANTIC_KIND_ASSIGNMENT: u32 = 11;
pub const SEMANTIC_KIND_BRANCH: u32 = 12;
pub const SEMANTIC_KIND_LOOP: u32 = 13;
pub const SEMANTIC_KIND_RETURN: u32 = 14;
pub const SEMANTIC_KIND_IMPORT: u32 = 15;
pub const SEMANTIC_KIND_TABLE: u32 = 16;
pub const SEMANTIC_KIND_FIELD: u32 = 17;
pub const SEMANTIC_KIND_OPERATOR: u32 = 18;
pub const SEMANTIC_KIND_COMMENT: u32 = 19;
pub const SEMANTIC_ROLE_NAME: u32 = 1;
pub const SEMANTIC_ROLE_BODY: u32 = 2;
pub const SEMANTIC_ROLE_PARAMETERS: u32 = 3;
pub const SEMANTIC_ROLE_RECEIVER: u32 = 4;
pub const SEMANTIC_ROLE_ARGUMENTS: u32 = 5;
pub const SEMANTIC_ROLE_CALLEE: u32 = 6;
pub const SEMANTIC_ROLE_LEFT: u32 = 7;
pub const SEMANTIC_ROLE_RIGHT: u32 = 8;
pub const SEMANTIC_ROLE_CONDITION: u32 = 9;
pub const SEMANTIC_ROLE_RETURN_TYPE: u32 = 10;
pub const SEMANTIC_ROLE_VALUE: u32 = 11;
pub const SEMANTIC_ROLE_SOURCE: u32 = 12;
pub const SEMANTIC_TRAIT_DECLARATION: u32 = 1;
pub const SEMANTIC_TRAIT_SCOPE: u32 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SemanticRoleSpec { pub name: &'static str, pub id: u32, pub required: bool }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SemanticTraitSpec { pub name: &'static str, pub id: u32 }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SemanticKindSpec {
    pub name: &'static str,
    pub id: u32,
    pub roles: &'static [SemanticRoleSpec],
    pub traits: &'static [SemanticTraitSpec],
}
const SEMANTIC_KIND_MODULE_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "body", id: 2, required: true },
];
const SEMANTIC_KIND_MODULE_TRAITS: &[SemanticTraitSpec] = &[
    SemanticTraitSpec { name: "scope", id: 2 },
];
const SEMANTIC_KIND_DECLARATION_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "name", id: 1, required: true },
];
const SEMANTIC_KIND_DECLARATION_TRAITS: &[SemanticTraitSpec] = &[
    SemanticTraitSpec { name: "declaration", id: 1 },
];
const SEMANTIC_KIND_FUNCTION_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "name", id: 1, required: false },
    SemanticRoleSpec { name: "parameters", id: 3, required: true },
    SemanticRoleSpec { name: "body", id: 2, required: true },
];
const SEMANTIC_KIND_FUNCTION_TRAITS: &[SemanticTraitSpec] = &[
    SemanticTraitSpec { name: "declaration", id: 1 },
    SemanticTraitSpec { name: "scope", id: 2 },
];
const SEMANTIC_KIND_PARAMETER_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "name", id: 1, required: true },
];
const SEMANTIC_KIND_PARAMETER_TRAITS: &[SemanticTraitSpec] = &[
    SemanticTraitSpec { name: "declaration", id: 1 },
];
const SEMANTIC_KIND_CALL_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "callee", id: 6, required: true },
    SemanticRoleSpec { name: "arguments", id: 5, required: true },
];
const SEMANTIC_KIND_CALL_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_MEMBER_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "receiver", id: 4, required: true },
    SemanticRoleSpec { name: "name", id: 1, required: true },
];
const SEMANTIC_KIND_MEMBER_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_IDENTIFIER_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "name", id: 1, required: false },
];
const SEMANTIC_KIND_IDENTIFIER_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_LITERAL_ROLES: &[SemanticRoleSpec] = &[
];
const SEMANTIC_KIND_LITERAL_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_TYPE_ROLES: &[SemanticRoleSpec] = &[
];
const SEMANTIC_KIND_TYPE_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_BLOCK_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "body", id: 2, required: false },
];
const SEMANTIC_KIND_BLOCK_TRAITS: &[SemanticTraitSpec] = &[
    SemanticTraitSpec { name: "scope", id: 2 },
];
const SEMANTIC_KIND_ASSIGNMENT_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "left", id: 7, required: true },
    SemanticRoleSpec { name: "right", id: 8, required: true },
];
const SEMANTIC_KIND_ASSIGNMENT_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_BRANCH_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "condition", id: 9, required: true },
    SemanticRoleSpec { name: "body", id: 2, required: true },
];
const SEMANTIC_KIND_BRANCH_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_LOOP_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "condition", id: 9, required: false },
    SemanticRoleSpec { name: "body", id: 2, required: true },
];
const SEMANTIC_KIND_LOOP_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_RETURN_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "value", id: 11, required: false },
];
const SEMANTIC_KIND_RETURN_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_IMPORT_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "source", id: 12, required: true },
];
const SEMANTIC_KIND_IMPORT_TRAITS: &[SemanticTraitSpec] = &[
    SemanticTraitSpec { name: "declaration", id: 1 },
];
const SEMANTIC_KIND_TABLE_ROLES: &[SemanticRoleSpec] = &[
];
const SEMANTIC_KIND_TABLE_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_FIELD_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "name", id: 1, required: false },
    SemanticRoleSpec { name: "value", id: 11, required: true },
];
const SEMANTIC_KIND_FIELD_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_OPERATOR_ROLES: &[SemanticRoleSpec] = &[
    SemanticRoleSpec { name: "left", id: 7, required: false },
    SemanticRoleSpec { name: "right", id: 8, required: false },
];
const SEMANTIC_KIND_OPERATOR_TRAITS: &[SemanticTraitSpec] = &[
];
const SEMANTIC_KIND_COMMENT_ROLES: &[SemanticRoleSpec] = &[
];
const SEMANTIC_KIND_COMMENT_TRAITS: &[SemanticTraitSpec] = &[
];
pub const SEMANTIC_KINDS: &[SemanticKindSpec] = &[
    SemanticKindSpec { name: "module", id: 1, roles: SEMANTIC_KIND_MODULE_ROLES, traits: SEMANTIC_KIND_MODULE_TRAITS },
    SemanticKindSpec { name: "declaration", id: 2, roles: SEMANTIC_KIND_DECLARATION_ROLES, traits: SEMANTIC_KIND_DECLARATION_TRAITS },
    SemanticKindSpec { name: "function", id: 3, roles: SEMANTIC_KIND_FUNCTION_ROLES, traits: SEMANTIC_KIND_FUNCTION_TRAITS },
    SemanticKindSpec { name: "parameter", id: 4, roles: SEMANTIC_KIND_PARAMETER_ROLES, traits: SEMANTIC_KIND_PARAMETER_TRAITS },
    SemanticKindSpec { name: "call", id: 5, roles: SEMANTIC_KIND_CALL_ROLES, traits: SEMANTIC_KIND_CALL_TRAITS },
    SemanticKindSpec { name: "member", id: 6, roles: SEMANTIC_KIND_MEMBER_ROLES, traits: SEMANTIC_KIND_MEMBER_TRAITS },
    SemanticKindSpec { name: "identifier", id: 7, roles: SEMANTIC_KIND_IDENTIFIER_ROLES, traits: SEMANTIC_KIND_IDENTIFIER_TRAITS },
    SemanticKindSpec { name: "literal", id: 8, roles: SEMANTIC_KIND_LITERAL_ROLES, traits: SEMANTIC_KIND_LITERAL_TRAITS },
    SemanticKindSpec { name: "type", id: 9, roles: SEMANTIC_KIND_TYPE_ROLES, traits: SEMANTIC_KIND_TYPE_TRAITS },
    SemanticKindSpec { name: "block", id: 10, roles: SEMANTIC_KIND_BLOCK_ROLES, traits: SEMANTIC_KIND_BLOCK_TRAITS },
    SemanticKindSpec { name: "assignment", id: 11, roles: SEMANTIC_KIND_ASSIGNMENT_ROLES, traits: SEMANTIC_KIND_ASSIGNMENT_TRAITS },
    SemanticKindSpec { name: "branch", id: 12, roles: SEMANTIC_KIND_BRANCH_ROLES, traits: SEMANTIC_KIND_BRANCH_TRAITS },
    SemanticKindSpec { name: "loop", id: 13, roles: SEMANTIC_KIND_LOOP_ROLES, traits: SEMANTIC_KIND_LOOP_TRAITS },
    SemanticKindSpec { name: "return", id: 14, roles: SEMANTIC_KIND_RETURN_ROLES, traits: SEMANTIC_KIND_RETURN_TRAITS },
    SemanticKindSpec { name: "import", id: 15, roles: SEMANTIC_KIND_IMPORT_ROLES, traits: SEMANTIC_KIND_IMPORT_TRAITS },
    SemanticKindSpec { name: "table", id: 16, roles: SEMANTIC_KIND_TABLE_ROLES, traits: SEMANTIC_KIND_TABLE_TRAITS },
    SemanticKindSpec { name: "field", id: 17, roles: SEMANTIC_KIND_FIELD_ROLES, traits: SEMANTIC_KIND_FIELD_TRAITS },
    SemanticKindSpec { name: "operator", id: 18, roles: SEMANTIC_KIND_OPERATOR_ROLES, traits: SEMANTIC_KIND_OPERATOR_TRAITS },
    SemanticKindSpec { name: "comment", id: 19, roles: SEMANTIC_KIND_COMMENT_ROLES, traits: SEMANTIC_KIND_COMMENT_TRAITS },
];

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
pub struct Point {
    pub row: u32,
    pub column: u32,
}

pub const POINT_MSG_ID: u16 = 1;
pub const POINT_VERSION: u8 = 1;
impl Point {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, POINT_MSG_ID);
        out.push(POINT_VERSION);
        ctl_put_u32(&mut out, self.row);
        ctl_put_u32(&mut out, self.column);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != POINT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != POINT_VERSION { return Err(WireError::UnsupportedVersion); }
        let row = ctl_read_u32(bytes, &mut off)?;
        let column = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            row,
            column,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Range {
    pub start_byte: u32,
    pub end_byte: u32,
    pub start_point: Point,
    pub end_point: Point,
}

pub const RANGE_MSG_ID: u16 = 2;
pub const RANGE_VERSION: u8 = 1;
impl Range {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, RANGE_MSG_ID);
        out.push(RANGE_VERSION);
        ctl_put_u32(&mut out, self.start_byte);
        ctl_put_u32(&mut out, self.end_byte);
        let frame = (&self.start_point).encode();
        ctl_put_bytes(&mut out, &frame);
        let frame = (&self.end_point).encode();
        ctl_put_bytes(&mut out, &frame);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != RANGE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != RANGE_VERSION { return Err(WireError::UnsupportedVersion); }
        let start_byte = ctl_read_u32(bytes, &mut off)?;
        let end_byte = ctl_read_u32(bytes, &mut off)?;
        let start_point = Point::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        let end_point = Point::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            start_byte,
            end_byte,
            start_point,
            end_point,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SemanticTrait {
    pub id: u32,
}

pub const SEMANTIC_TRAIT_MSG_ID: u16 = 3;
pub const SEMANTIC_TRAIT_VERSION: u8 = 1;
impl SemanticTrait {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, SEMANTIC_TRAIT_MSG_ID);
        out.push(SEMANTIC_TRAIT_VERSION);
        ctl_put_u32(&mut out, self.id);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != SEMANTIC_TRAIT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != SEMANTIC_TRAIT_VERSION { return Err(WireError::UnsupportedVersion); }
        let id = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            id,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Diagnostic {
    pub severity: String,
    pub code: String,
    pub message: String,
    pub range: Option<Range>,
}

pub const DIAGNOSTIC_MSG_ID: u16 = 4;
pub const DIAGNOSTIC_VERSION: u8 = 1;
impl Diagnostic {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, DIAGNOSTIC_MSG_ID);
        out.push(DIAGNOSTIC_VERSION);
        ctl_put_str(&mut out, &self.severity);
        ctl_put_str(&mut out, &self.code);
        ctl_put_str(&mut out, &self.message);
        match &self.range {
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
        if ctl_read_u16(bytes, &mut off)? != DIAGNOSTIC_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != DIAGNOSTIC_VERSION { return Err(WireError::UnsupportedVersion); }
        let severity = ctl_read_str(bytes, &mut off)?;
        let code = ctl_read_str(bytes, &mut off)?;
        let message = ctl_read_str(bytes, &mut off)?;
        let range = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(Range::decode(&ctl_read_bytes(bytes, &mut off)?)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            severity,
            code,
            message,
            range,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LanguageDescriptor {
    pub name: String,
    pub language_version: String,
    pub grammar_version: String,
    pub grammar_ir_version: u32,
    pub vocabulary_version: u32,
    pub tree_sitter_abi: u32,
}

pub const LANGUAGE_DESCRIPTOR_MSG_ID: u16 = 5;
pub const LANGUAGE_DESCRIPTOR_VERSION: u8 = 1;
impl LanguageDescriptor {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, LANGUAGE_DESCRIPTOR_MSG_ID);
        out.push(LANGUAGE_DESCRIPTOR_VERSION);
        ctl_put_str(&mut out, &self.name);
        ctl_put_str(&mut out, &self.language_version);
        ctl_put_str(&mut out, &self.grammar_version);
        ctl_put_u32(&mut out, self.grammar_ir_version);
        ctl_put_u32(&mut out, self.vocabulary_version);
        ctl_put_u32(&mut out, self.tree_sitter_abi);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != LANGUAGE_DESCRIPTOR_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != LANGUAGE_DESCRIPTOR_VERSION { return Err(WireError::UnsupportedVersion); }
        let name = ctl_read_str(bytes, &mut off)?;
        let language_version = ctl_read_str(bytes, &mut off)?;
        let grammar_version = ctl_read_str(bytes, &mut off)?;
        let grammar_ir_version = ctl_read_u32(bytes, &mut off)?;
        let vocabulary_version = ctl_read_u32(bytes, &mut off)?;
        let tree_sitter_abi = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            name,
            language_version,
            grammar_version,
            grammar_ir_version,
            vocabulary_version,
            tree_sitter_abi,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NodeSummary {
    pub handle: u32,
    pub concrete_kind: String,
    pub semantic_kind: Option<u32>,
    pub field_role: Option<u32>,
    pub range: Range,
    pub named: bool,
    pub missing: bool,
    pub error: bool,
    pub child_count: u32,
    pub traits: Vec<SemanticTrait>,
}

pub const NODE_SUMMARY_MSG_ID: u16 = 6;
pub const NODE_SUMMARY_VERSION: u8 = 1;
impl NodeSummary {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, NODE_SUMMARY_MSG_ID);
        out.push(NODE_SUMMARY_VERSION);
        ctl_put_u32(&mut out, self.handle);
        ctl_put_str(&mut out, &self.concrete_kind);
        match &self.semantic_kind {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        match &self.field_role {
            Some(v) => {
                out.push(1);
        ctl_put_u32(&mut out, *v);
            }
            None => out.push(0),
        }
        let frame = (&self.range).encode();
        ctl_put_bytes(&mut out, &frame);
        ctl_put_bool(&mut out, self.named);
        ctl_put_bool(&mut out, self.missing);
        ctl_put_bool(&mut out, self.error);
        ctl_put_u32(&mut out, self.child_count);
        ctl_put_message_list(&mut out, &self.traits, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != NODE_SUMMARY_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != NODE_SUMMARY_VERSION { return Err(WireError::UnsupportedVersion); }
        let handle = ctl_read_u32(bytes, &mut off)?;
        let concrete_kind = ctl_read_str(bytes, &mut off)?;
        let semantic_kind = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let field_role = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let range = Range::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        let named = ctl_read_bool(bytes, &mut off)?;
        let missing = ctl_read_bool(bytes, &mut off)?;
        let error = ctl_read_bool(bytes, &mut off)?;
        let child_count = ctl_read_u32(bytes, &mut off)?;
        let traits = ctl_read_message_list(bytes, &mut off, SemanticTrait::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            handle,
            concrete_kind,
            semantic_kind,
            field_role,
            range,
            named,
            missing,
            error,
            child_count,
            traits,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ChangedRange {
    pub range: Range,
}

pub const CHANGED_RANGE_MSG_ID: u16 = 7;
pub const CHANGED_RANGE_VERSION: u8 = 1;
impl ChangedRange {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, CHANGED_RANGE_MSG_ID);
        out.push(CHANGED_RANGE_VERSION);
        let frame = (&self.range).encode();
        ctl_put_bytes(&mut out, &frame);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != CHANGED_RANGE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != CHANGED_RANGE_VERSION { return Err(WireError::UnsupportedVersion); }
        let range = Range::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            range,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Edit {
    pub start_byte: u32,
    pub old_end_byte: u32,
    pub replacement: Vec<u8>,
}

pub const EDIT_MSG_ID: u16 = 8;
pub const EDIT_VERSION: u8 = 1;
impl Edit {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, EDIT_MSG_ID);
        out.push(EDIT_VERSION);
        ctl_put_u32(&mut out, self.start_byte);
        ctl_put_u32(&mut out, self.old_end_byte);
        ctl_put_bytes(&mut out, &self.replacement);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != EDIT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != EDIT_VERSION { return Err(WireError::UnsupportedVersion); }
        let start_byte = ctl_read_u32(bytes, &mut off)?;
        let old_end_byte = ctl_read_u32(bytes, &mut off)?;
        let replacement = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            start_byte,
            old_end_byte,
            replacement,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RewriteEdit {
    pub start_byte: u32,
    pub old_end_byte: u32,
    pub expected_sha256: Vec<u8>,
    pub replacement: Vec<u8>,
}

pub const REWRITE_EDIT_MSG_ID: u16 = 9;
pub const REWRITE_EDIT_VERSION: u8 = 1;
impl RewriteEdit {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, REWRITE_EDIT_MSG_ID);
        out.push(REWRITE_EDIT_VERSION);
        ctl_put_u32(&mut out, self.start_byte);
        ctl_put_u32(&mut out, self.old_end_byte);
        ctl_put_bytes(&mut out, &self.expected_sha256);
        ctl_put_bytes(&mut out, &self.replacement);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != REWRITE_EDIT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != REWRITE_EDIT_VERSION { return Err(WireError::UnsupportedVersion); }
        let start_byte = ctl_read_u32(bytes, &mut off)?;
        let old_end_byte = ctl_read_u32(bytes, &mut off)?;
        let expected_sha256 = ctl_read_bytes(bytes, &mut off)?;
        let replacement = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            start_byte,
            old_end_byte,
            expected_sha256,
            replacement,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Capture {
    pub name: String,
    pub node: NodeSummary,
    pub text: Option<Vec<u8>>,
}

pub const CAPTURE_MSG_ID: u16 = 10;
pub const CAPTURE_VERSION: u8 = 1;
impl Capture {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, CAPTURE_MSG_ID);
        out.push(CAPTURE_VERSION);
        ctl_put_str(&mut out, &self.name);
        let frame = (&self.node).encode();
        ctl_put_bytes(&mut out, &frame);
        match &self.text {
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
        if ctl_read_u16(bytes, &mut off)? != CAPTURE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != CAPTURE_VERSION { return Err(WireError::UnsupportedVersion); }
        let name = ctl_read_str(bytes, &mut off)?;
        let node = NodeSummary::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        let text = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_bytes(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            name,
            node,
            text,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LanguagesRequest {
    pub reserved: u32,
}

pub const LANGUAGES_REQUEST_MSG_ID: u16 = 100;
pub const LANGUAGES_REQUEST_VERSION: u8 = 1;
impl LanguagesRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, LANGUAGES_REQUEST_MSG_ID);
        out.push(LANGUAGES_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.reserved);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != LANGUAGES_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != LANGUAGES_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let reserved = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            reserved,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OpenRequest {
    pub language: String,
    pub source: Vec<u8>,
}

pub const OPEN_REQUEST_MSG_ID: u16 = 101;
pub const OPEN_REQUEST_VERSION: u8 = 1;
impl OpenRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, OPEN_REQUEST_MSG_ID);
        out.push(OPEN_REQUEST_VERSION);
        ctl_put_str(&mut out, &self.language);
        ctl_put_bytes(&mut out, &self.source);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != OPEN_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != OPEN_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let language = ctl_read_str(bytes, &mut off)?;
        let source = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            language,
            source,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CloseRequest {
    pub document: u32,
}

pub const CLOSE_REQUEST_MSG_ID: u16 = 102;
pub const CLOSE_REQUEST_VERSION: u8 = 1;
impl CloseRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, CLOSE_REQUEST_MSG_ID);
        out.push(CLOSE_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != CLOSE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != CLOSE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TreeRequest {
    pub document: u32,
    pub revision: u32,
    pub view: String,
    pub max_depth: u32,
    pub limit: u32,
    pub cursor: Option<u32>,
}

pub const TREE_REQUEST_MSG_ID: u16 = 103;
pub const TREE_REQUEST_VERSION: u8 = 1;
impl TreeRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, TREE_REQUEST_MSG_ID);
        out.push(TREE_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_str(&mut out, &self.view);
        ctl_put_u32(&mut out, self.max_depth);
        ctl_put_u32(&mut out, self.limit);
        match &self.cursor {
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
        if ctl_read_u16(bytes, &mut off)? != TREE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != TREE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let view = ctl_read_str(bytes, &mut off)?;
        let max_depth = ctl_read_u32(bytes, &mut off)?;
        let limit = ctl_read_u32(bytes, &mut off)?;
        let cursor = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            view,
            max_depth,
            limit,
            cursor,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NodeRequest {
    pub document: u32,
    pub revision: u32,
    pub node: u32,
    pub view: String,
}

pub const NODE_REQUEST_MSG_ID: u16 = 104;
pub const NODE_REQUEST_VERSION: u8 = 1;
impl NodeRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, NODE_REQUEST_MSG_ID);
        out.push(NODE_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_u32(&mut out, self.node);
        ctl_put_str(&mut out, &self.view);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != NODE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != NODE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let node = ctl_read_u32(bytes, &mut off)?;
        let view = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            node,
            view,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ChildrenRequest {
    pub document: u32,
    pub revision: u32,
    pub node: u32,
    pub view: String,
    pub named_only: bool,
    pub limit: u32,
    pub cursor: Option<u32>,
}

pub const CHILDREN_REQUEST_MSG_ID: u16 = 105;
pub const CHILDREN_REQUEST_VERSION: u8 = 1;
impl ChildrenRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, CHILDREN_REQUEST_MSG_ID);
        out.push(CHILDREN_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_u32(&mut out, self.node);
        ctl_put_str(&mut out, &self.view);
        ctl_put_bool(&mut out, self.named_only);
        ctl_put_u32(&mut out, self.limit);
        match &self.cursor {
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
        if ctl_read_u16(bytes, &mut off)? != CHILDREN_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != CHILDREN_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let node = ctl_read_u32(bytes, &mut off)?;
        let view = ctl_read_str(bytes, &mut off)?;
        let named_only = ctl_read_bool(bytes, &mut off)?;
        let limit = ctl_read_u32(bytes, &mut off)?;
        let cursor = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            node,
            view,
            named_only,
            limit,
            cursor,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct QueryCompileRequest {
    pub language: String,
    pub source: String,
    pub view: String,
}

pub const QUERY_COMPILE_REQUEST_MSG_ID: u16 = 106;
pub const QUERY_COMPILE_REQUEST_VERSION: u8 = 1;
impl QueryCompileRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, QUERY_COMPILE_REQUEST_MSG_ID);
        out.push(QUERY_COMPILE_REQUEST_VERSION);
        ctl_put_str(&mut out, &self.language);
        ctl_put_str(&mut out, &self.source);
        ctl_put_str(&mut out, &self.view);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != QUERY_COMPILE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != QUERY_COMPILE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let language = ctl_read_str(bytes, &mut off)?;
        let source = ctl_read_str(bytes, &mut off)?;
        let view = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            language,
            source,
            view,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct QueryRequest {
    pub document: u32,
    pub revision: u32,
    pub query: u32,
    pub range: Option<Range>,
    pub include_text: bool,
    pub limit: u32,
    pub cursor: Option<u32>,
}

pub const QUERY_REQUEST_MSG_ID: u16 = 107;
pub const QUERY_REQUEST_VERSION: u8 = 1;
impl QueryRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, QUERY_REQUEST_MSG_ID);
        out.push(QUERY_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_u32(&mut out, self.query);
        match &self.range {
            Some(v) => {
                out.push(1);
        let frame = (v).encode();
        ctl_put_bytes(&mut out, &frame);
            }
            None => out.push(0),
        }
        ctl_put_bool(&mut out, self.include_text);
        ctl_put_u32(&mut out, self.limit);
        match &self.cursor {
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
        if ctl_read_u16(bytes, &mut off)? != QUERY_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != QUERY_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let query = ctl_read_u32(bytes, &mut off)?;
        let range = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(Range::decode(&ctl_read_bytes(bytes, &mut off)?)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let include_text = ctl_read_bool(bytes, &mut off)?;
        let limit = ctl_read_u32(bytes, &mut off)?;
        let cursor = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            query,
            range,
            include_text,
            limit,
            cursor,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EditRequest {
    pub document: u32,
    pub revision: u32,
    pub edits: Vec<Edit>,
}

pub const EDIT_REQUEST_MSG_ID: u16 = 108;
pub const EDIT_REQUEST_VERSION: u8 = 1;
impl EditRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, EDIT_REQUEST_MSG_ID);
        out.push(EDIT_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_message_list(&mut out, &self.edits, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != EDIT_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != EDIT_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let edits = ctl_read_message_list(bytes, &mut off, Edit::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            edits,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RewriteRequest {
    pub document: u32,
    pub revision: u32,
    pub validation: String,
    pub edits: Vec<RewriteEdit>,
}

pub const REWRITE_REQUEST_MSG_ID: u16 = 109;
pub const REWRITE_REQUEST_VERSION: u8 = 1;
impl RewriteRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, REWRITE_REQUEST_MSG_ID);
        out.push(REWRITE_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_str(&mut out, &self.validation);
        ctl_put_message_list(&mut out, &self.edits, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != REWRITE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != REWRITE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let validation = ctl_read_str(bytes, &mut off)?;
        let edits = ctl_read_message_list(bytes, &mut off, RewriteEdit::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            validation,
            edits,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TextRequest {
    pub document: u32,
    pub revision: u32,
    pub range: Option<Range>,
}

pub const TEXT_REQUEST_MSG_ID: u16 = 110;
pub const TEXT_REQUEST_VERSION: u8 = 1;
impl TextRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, TEXT_REQUEST_MSG_ID);
        out.push(TEXT_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        match &self.range {
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
        if ctl_read_u16(bytes, &mut off)? != TEXT_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != TEXT_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let range = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(Range::decode(&ctl_read_bytes(bytes, &mut off)?)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            range,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DiagnosticsRequest {
    pub document: u32,
    pub revision: u32,
}

pub const DIAGNOSTICS_REQUEST_MSG_ID: u16 = 111;
pub const DIAGNOSTICS_REQUEST_VERSION: u8 = 1;
impl DiagnosticsRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, DIAGNOSTICS_REQUEST_MSG_ID);
        out.push(DIAGNOSTICS_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != DIAGNOSTICS_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != DIAGNOSTICS_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct QueryCloseRequest {
    pub query: u32,
}

pub const QUERY_CLOSE_REQUEST_MSG_ID: u16 = 112;
pub const QUERY_CLOSE_REQUEST_VERSION: u8 = 1;
impl QueryCloseRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, QUERY_CLOSE_REQUEST_MSG_ID);
        out.push(QUERY_CLOSE_REQUEST_VERSION);
        ctl_put_u32(&mut out, self.query);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != QUERY_CLOSE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != QUERY_CLOSE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let query = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            query,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ErrorResponse {
    pub code: String,
    pub message: String,
    pub current_revision: Option<u32>,
}

pub const ERROR_RESPONSE_MSG_ID: u16 = 200;
pub const ERROR_RESPONSE_VERSION: u8 = 1;
impl ErrorResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, ERROR_RESPONSE_MSG_ID);
        out.push(ERROR_RESPONSE_VERSION);
        ctl_put_str(&mut out, &self.code);
        ctl_put_str(&mut out, &self.message);
        match &self.current_revision {
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
        if ctl_read_u16(bytes, &mut off)? != ERROR_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != ERROR_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let code = ctl_read_str(bytes, &mut off)?;
        let message = ctl_read_str(bytes, &mut off)?;
        let current_revision = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            code,
            message,
            current_revision,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct LanguagesResponse {
    pub languages: Vec<LanguageDescriptor>,
}

pub const LANGUAGES_RESPONSE_MSG_ID: u16 = 201;
pub const LANGUAGES_RESPONSE_VERSION: u8 = 1;
impl LanguagesResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, LANGUAGES_RESPONSE_MSG_ID);
        out.push(LANGUAGES_RESPONSE_VERSION);
        ctl_put_message_list(&mut out, &self.languages, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != LANGUAGES_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != LANGUAGES_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let languages = ctl_read_message_list(bytes, &mut off, LanguageDescriptor::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            languages,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OpenResponse {
    pub document: u32,
    pub revision: u32,
    pub root: NodeSummary,
    pub diagnostics: Vec<Diagnostic>,
}

pub const OPEN_RESPONSE_MSG_ID: u16 = 202;
pub const OPEN_RESPONSE_VERSION: u8 = 1;
impl OpenResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, OPEN_RESPONSE_MSG_ID);
        out.push(OPEN_RESPONSE_VERSION);
        ctl_put_u32(&mut out, self.document);
        ctl_put_u32(&mut out, self.revision);
        let frame = (&self.root).encode();
        ctl_put_bytes(&mut out, &frame);
        ctl_put_message_list(&mut out, &self.diagnostics, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != OPEN_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != OPEN_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let document = ctl_read_u32(bytes, &mut off)?;
        let revision = ctl_read_u32(bytes, &mut off)?;
        let root = NodeSummary::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        let diagnostics = ctl_read_message_list(bytes, &mut off, Diagnostic::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            document,
            revision,
            root,
            diagnostics,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CloseResponse {
    pub reserved: u32,
}

pub const CLOSE_RESPONSE_MSG_ID: u16 = 203;
pub const CLOSE_RESPONSE_VERSION: u8 = 1;
impl CloseResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, CLOSE_RESPONSE_MSG_ID);
        out.push(CLOSE_RESPONSE_VERSION);
        ctl_put_u32(&mut out, self.reserved);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != CLOSE_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != CLOSE_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let reserved = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            reserved,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TreeResponse {
    pub nodes: Vec<NodeSummary>,
    pub cursor: Option<u32>,
}

pub const TREE_RESPONSE_MSG_ID: u16 = 204;
pub const TREE_RESPONSE_VERSION: u8 = 1;
impl TreeResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, TREE_RESPONSE_MSG_ID);
        out.push(TREE_RESPONSE_VERSION);
        ctl_put_message_list(&mut out, &self.nodes, |v| v.encode());
        match &self.cursor {
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
        if ctl_read_u16(bytes, &mut off)? != TREE_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != TREE_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let nodes = ctl_read_message_list(bytes, &mut off, NodeSummary::decode)?;
        let cursor = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            nodes,
            cursor,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct NodeResponse {
    pub node: NodeSummary,
}

pub const NODE_RESPONSE_MSG_ID: u16 = 205;
pub const NODE_RESPONSE_VERSION: u8 = 1;
impl NodeResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, NODE_RESPONSE_MSG_ID);
        out.push(NODE_RESPONSE_VERSION);
        let frame = (&self.node).encode();
        ctl_put_bytes(&mut out, &frame);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != NODE_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != NODE_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let node = NodeSummary::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            node,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ChildrenResponse {
    pub nodes: Vec<NodeSummary>,
    pub cursor: Option<u32>,
}

pub const CHILDREN_RESPONSE_MSG_ID: u16 = 206;
pub const CHILDREN_RESPONSE_VERSION: u8 = 1;
impl ChildrenResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, CHILDREN_RESPONSE_MSG_ID);
        out.push(CHILDREN_RESPONSE_VERSION);
        ctl_put_message_list(&mut out, &self.nodes, |v| v.encode());
        match &self.cursor {
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
        if ctl_read_u16(bytes, &mut off)? != CHILDREN_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != CHILDREN_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let nodes = ctl_read_message_list(bytes, &mut off, NodeSummary::decode)?;
        let cursor = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            nodes,
            cursor,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct QueryCompileResponse {
    pub query: u32,
    pub diagnostics: Vec<Diagnostic>,
}

pub const QUERY_COMPILE_RESPONSE_MSG_ID: u16 = 207;
pub const QUERY_COMPILE_RESPONSE_VERSION: u8 = 1;
impl QueryCompileResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, QUERY_COMPILE_RESPONSE_MSG_ID);
        out.push(QUERY_COMPILE_RESPONSE_VERSION);
        ctl_put_u32(&mut out, self.query);
        ctl_put_message_list(&mut out, &self.diagnostics, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != QUERY_COMPILE_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != QUERY_COMPILE_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let query = ctl_read_u32(bytes, &mut off)?;
        let diagnostics = ctl_read_message_list(bytes, &mut off, Diagnostic::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            query,
            diagnostics,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct QueryResponse {
    pub captures: Vec<Capture>,
    pub cursor: Option<u32>,
}

pub const QUERY_RESPONSE_MSG_ID: u16 = 208;
pub const QUERY_RESPONSE_VERSION: u8 = 1;
impl QueryResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, QUERY_RESPONSE_MSG_ID);
        out.push(QUERY_RESPONSE_VERSION);
        ctl_put_message_list(&mut out, &self.captures, |v| v.encode());
        match &self.cursor {
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
        if ctl_read_u16(bytes, &mut off)? != QUERY_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != QUERY_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let captures = ctl_read_message_list(bytes, &mut off, Capture::decode)?;
        let cursor = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_u32(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            captures,
            cursor,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EditResponse {
    pub revision: u32,
    pub changed: Vec<ChangedRange>,
    pub diagnostics: Vec<Diagnostic>,
}

pub const EDIT_RESPONSE_MSG_ID: u16 = 209;
pub const EDIT_RESPONSE_VERSION: u8 = 1;
impl EditResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, EDIT_RESPONSE_MSG_ID);
        out.push(EDIT_RESPONSE_VERSION);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_message_list(&mut out, &self.changed, |v| v.encode());
        ctl_put_message_list(&mut out, &self.diagnostics, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != EDIT_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != EDIT_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let revision = ctl_read_u32(bytes, &mut off)?;
        let changed = ctl_read_message_list(bytes, &mut off, ChangedRange::decode)?;
        let diagnostics = ctl_read_message_list(bytes, &mut off, Diagnostic::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            revision,
            changed,
            diagnostics,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RewriteResponse {
    pub revision: u32,
    pub changed: Vec<ChangedRange>,
    pub diagnostics: Vec<Diagnostic>,
}

pub const REWRITE_RESPONSE_MSG_ID: u16 = 210;
pub const REWRITE_RESPONSE_VERSION: u8 = 1;
impl RewriteResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, REWRITE_RESPONSE_MSG_ID);
        out.push(REWRITE_RESPONSE_VERSION);
        ctl_put_u32(&mut out, self.revision);
        ctl_put_message_list(&mut out, &self.changed, |v| v.encode());
        ctl_put_message_list(&mut out, &self.diagnostics, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != REWRITE_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != REWRITE_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let revision = ctl_read_u32(bytes, &mut off)?;
        let changed = ctl_read_message_list(bytes, &mut off, ChangedRange::decode)?;
        let diagnostics = ctl_read_message_list(bytes, &mut off, Diagnostic::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            revision,
            changed,
            diagnostics,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TextResponse {
    pub text: Vec<u8>,
}

pub const TEXT_RESPONSE_MSG_ID: u16 = 211;
pub const TEXT_RESPONSE_VERSION: u8 = 1;
impl TextResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, TEXT_RESPONSE_MSG_ID);
        out.push(TEXT_RESPONSE_VERSION);
        ctl_put_bytes(&mut out, &self.text);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != TEXT_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != TEXT_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let text = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            text,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DiagnosticsResponse {
    pub diagnostics: Vec<Diagnostic>,
}

pub const DIAGNOSTICS_RESPONSE_MSG_ID: u16 = 212;
pub const DIAGNOSTICS_RESPONSE_VERSION: u8 = 1;
impl DiagnosticsResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, DIAGNOSTICS_RESPONSE_MSG_ID);
        out.push(DIAGNOSTICS_RESPONSE_VERSION);
        ctl_put_message_list(&mut out, &self.diagnostics, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != DIAGNOSTICS_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != DIAGNOSTICS_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let diagnostics = ctl_read_message_list(bytes, &mut off, Diagnostic::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            diagnostics,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct QueryCloseResponse {
    pub reserved: u32,
}

pub const QUERY_CLOSE_RESPONSE_MSG_ID: u16 = 213;
pub const QUERY_CLOSE_RESPONSE_VERSION: u8 = 1;
impl QueryCloseResponse {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, QUERY_CLOSE_RESPONSE_MSG_ID);
        out.push(QUERY_CLOSE_RESPONSE_VERSION);
        ctl_put_u32(&mut out, self.reserved);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != QUERY_CLOSE_RESPONSE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != QUERY_CLOSE_RESPONSE_VERSION { return Err(WireError::UnsupportedVersion); }
        let reserved = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            reserved,
        })
    }
}
