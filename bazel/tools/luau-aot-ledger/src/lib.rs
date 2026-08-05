use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const ENUMS: [(&str, &str, &str); 3] = [
    ("commands", "IrCmd", "uint8_t"),
    ("operand_kinds", "IrOpKind", "uint32_t"),
    ("block_kinds", "IrBlockKind", "uint8_t"),
];

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Member {
    pub name: String,
    pub value: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct EnumLedger {
    pub name: String,
    pub underlying_type: String,
    pub members: Vec<Member>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Extraction {
    pub schema_version: u32,
    pub source_sha256: String,
    pub commands: EnumLedger,
    pub operand_kinds: EnumLedger,
    pub block_kinds: EnumLedger,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub schema_version: u32,
    pub generator_version: String,
    pub pin: String,
    pub input_sha256: String,
    pub commands: Vec<CommandPolicy>,
    pub operand_kinds: Vec<KindPolicy>,
    pub block_kinds: Vec<KindPolicy>,
    pub canonical_hash: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommandPolicy {
    pub command: String,
    pub value: u32,
    pub class: String,
    pub wasm_features: Vec<String>,
    pub runtime_symbols: Vec<String>,
    pub may_allocate: Option<bool>,
    pub may_raise: Option<bool>,
    pub may_call_luau: Option<bool>,
    pub safepoint: Option<bool>,
    pub rejoins: Option<bool>,
    pub oracle: String,
    pub tests: Vec<String>,
    pub status: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KindPolicy {
    pub kind: String,
    pub value: u32,
    pub treatment: String,
    pub status: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum Token {
    Ident(String),
    Punct(char),
    Literal,
    Directive,
}

fn tokenize(source: &str) -> Result<Vec<Token>, String> {
    let bytes = source.as_bytes();
    let mut result = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b if b.is_ascii_whitespace() => i += 1,
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                i += 2;
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                let start = i;
                i += 2;
                while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                    i += 1;
                }
                if i + 1 == bytes.len() {
                    return Err(format!("unterminated block comment at byte {start}"));
                }
                i += 2;
            }
            b if b == b'_' || b.is_ascii_alphabetic() => {
                let start = i;
                i += 1;
                while i < bytes.len() && (bytes[i] == b'_' || bytes[i].is_ascii_alphanumeric()) {
                    i += 1;
                }
                result.push(Token::Ident(source[start..i].to_owned()));
            }
            b'#' => {
                result.push(Token::Directive);
                i += 1;
                loop {
                    while i < bytes.len() && bytes[i] != b'\n' {
                        i += 1;
                    }
                    let continued = i > 0 && bytes[i.saturating_sub(1)] == b'\\';
                    if i < bytes.len() {
                        i += 1;
                    }
                    if !continued {
                        break;
                    }
                }
            }
            quote @ (b'"' | b'\'') => {
                let start = i;
                i += 1;
                let mut closed = false;
                while i < bytes.len() {
                    if bytes[i] == b'\\' {
                        i += 2;
                    } else if bytes[i] == quote {
                        i += 1;
                        closed = true;
                        break;
                    } else {
                        i += 1;
                    }
                }
                if !closed {
                    return Err(format!("unterminated literal at byte {start}"));
                }
                result.push(Token::Literal);
            }
            b => {
                result.push(Token::Punct(char::from(b)));
                i += 1;
            }
        }
    }
    Ok(result)
}

fn ident(token: Option<&Token>) -> Option<&str> {
    match token {
        Some(Token::Ident(value)) => Some(value),
        _ => None,
    }
}

fn parse_enum(tokens: &[Token], name: &str, expected_type: &str) -> Result<EnumLedger, String> {
    let mut starts = Vec::new();
    for i in 0..tokens.len().saturating_sub(2) {
        if ident(tokens.get(i)) == Some("enum")
            && ident(tokens.get(i + 1)) == Some("class")
            && ident(tokens.get(i + 2)) == Some(name)
        {
            starts.push(i);
        }
    }
    if starts.len() != 1 {
        return Err(format!(
            "expected exactly one definition of {name}, found {}",
            starts.len()
        ));
    }
    let mut i = starts[0] + 3;
    if tokens.get(i) != Some(&Token::Punct(':')) {
        return Err(format!("{name}: missing underlying type"));
    }
    i += 1;
    let actual_type =
        ident(tokens.get(i)).ok_or_else(|| format!("{name}: malformed underlying type"))?;
    if actual_type != expected_type {
        return Err(format!(
            "{name}: expected underlying type {expected_type}, found {actual_type}"
        ));
    }
    i += 1;
    if tokens.get(i) != Some(&Token::Punct('{')) {
        return Err(format!("{name}: expected definition body"));
    }
    i += 1;

    let mut members = Vec::new();
    let mut expect_member = true;
    loop {
        match tokens.get(i) {
            Some(Token::Punct('}')) if !members.is_empty() && !expect_member => break,
            Some(Token::Punct('}')) if !members.is_empty() => break, // trailing comma
            Some(Token::Ident(member)) if expect_member => {
                if members.iter().any(|old: &Member| old.name == *member) {
                    return Err(format!("{name}: duplicate member {member}"));
                }
                members.push(Member {
                    name: member.clone(),
                    value: members.len() as u32,
                });
                expect_member = false;
                i += 1;
            }
            Some(Token::Punct('=')) => {
                return Err(format!(
                    "{name}: explicit values and aliases are not allowed"
                ));
            }
            Some(Token::Directive) => {
                return Err(format!("{name}: preprocessor directives are not allowed"));
            }
            Some(Token::Punct(',')) if !expect_member => {
                expect_member = true;
                i += 1;
            }
            Some(token) => return Err(format!("{name}: malformed enum row near {token:?}")),
            None => return Err(format!("{name}: unterminated definition")),
        }
    }
    if members.is_empty() {
        return Err(format!("{name}: empty enum is not allowed"));
    }
    Ok(EnumLedger {
        name: name.to_owned(),
        underlying_type: expected_type.to_owned(),
        members,
    })
}

pub fn extract(source: &str) -> Result<Extraction, String> {
    let tokens = tokenize(source)?;
    let mut parsed = Vec::new();
    for (_, name, ty) in ENUMS {
        parsed.push(parse_enum(&tokens, name, ty)?);
    }
    Ok(Extraction {
        schema_version: 1,
        source_sha256: format!("{:x}", Sha256::digest(source.as_bytes())),
        commands: parsed.remove(0),
        operand_kinds: parsed.remove(0),
        block_kinds: parsed.remove(0),
    })
}

pub fn canonical_json(extraction: &Extraction) -> Result<String, String> {
    serde_json::to_string_pretty(extraction)
        .map(|value| value + "\n")
        .map_err(|e| e.to_string())
}

fn exact_members(kind: &str, actual: &[Member], policy: &[Member]) -> Result<(), String> {
    fn keyed(kind: &str, rows: &[Member]) -> Result<BTreeMap<String, u32>, String> {
        let mut result = BTreeMap::new();
        for row in rows {
            if result.insert(row.name.clone(), row.value).is_some() {
                return Err(format!("policy {kind}: duplicate member {}", row.name));
            }
        }
        Ok(result)
    }
    let actual = keyed(kind, actual)?;
    let policy = keyed(kind, policy)?;
    if actual == policy {
        return Ok(());
    }
    let missing: Vec<_> = actual
        .keys()
        .filter(|key| !policy.contains_key(*key))
        .cloned()
        .collect();
    let extra: Vec<_> = policy
        .keys()
        .filter(|key| !actual.contains_key(*key))
        .cloned()
        .collect();
    let wrong_values: Vec<_> = actual
        .iter()
        .filter_map(|(key, value)| {
            policy
                .get(key)
                .filter(|other| *other != value)
                .map(|other| format!("{key}: expected {value}, policy has {other}"))
        })
        .collect();
    Err(format!(
        "{kind} policy drift: missing={missing:?}, extra={extra:?}, wrong_values={wrong_values:?}"
    ))
}

fn canonical_value(value: &serde_json::Value, output: &mut String) {
    match value {
        serde_json::Value::Null => output.push_str("null"),
        serde_json::Value::Bool(value) => output.push_str(if *value { "true" } else { "false" }),
        serde_json::Value::Number(value) => output.push_str(&value.to_string()),
        serde_json::Value::String(value) => {
            output.push_str(&serde_json::to_string(value).expect("serializing string cannot fail"))
        }
        serde_json::Value::Array(values) => {
            output.push('[');
            for (index, value) in values.iter().enumerate() {
                if index != 0 {
                    output.push(',');
                }
                canonical_value(value, output);
            }
            output.push(']');
        }
        serde_json::Value::Object(values) => {
            output.push('{');
            let mut entries: Vec<_> = values.iter().collect();
            entries.sort_unstable_by(|left, right| left.0.cmp(right.0));
            for (index, (key, value)) in entries.into_iter().enumerate() {
                if index != 0 {
                    output.push(',');
                }
                output.push_str(&serde_json::to_string(key).expect("serializing key cannot fail"));
                output.push(':');
                canonical_value(value, output);
            }
            output.push('}');
        }
    }
}

pub fn canonical_policy_hash(value: &serde_json::Value) -> Result<String, String> {
    let mut hash_input = value.clone();
    hash_input
        .as_object_mut()
        .ok_or_else(|| "policy root must be an object".to_owned())?
        .remove("canonical_hash");
    let mut canonical = String::new();
    canonical_value(&hash_input, &mut canonical);
    Ok(format!("{:x}", Sha256::digest(canonical.as_bytes())))
}

pub fn validate_policy(extraction: &Extraction, policy_json: &str) -> Result<(), String> {
    let raw: serde_json::Value =
        serde_json::from_str(policy_json).map_err(|e| format!("invalid policy JSON: {e}"))?;
    let policy: Policy =
        serde_json::from_str(policy_json).map_err(|e| format!("invalid policy JSON: {e}"))?;
    if policy.schema_version != 1 {
        return Err(format!(
            "unsupported policy schema version {}",
            policy.schema_version
        ));
    }
    if policy.pin != "luau-0.725+agentos-patches" {
        return Err(format!("unexpected policy pin {}", policy.pin));
    }
    if policy.input_sha256 != extraction.source_sha256 {
        return Err(format!(
            "policy input digest mismatch: extracted={}, policy={}",
            extraction.source_sha256, policy.input_sha256
        ));
    }
    if policy.generator_version.trim().is_empty() {
        return Err("empty generator version".to_owned());
    }
    let actual_canonical_hash = canonical_policy_hash(&raw)?;
    if policy.canonical_hash != actual_canonical_hash {
        return Err(format!(
            "canonical policy hash mismatch: expected={}, actual={}",
            policy.canonical_hash, actual_canonical_hash
        ));
    }

    let required_command_fields = [
        "command",
        "value",
        "class",
        "wasm_features",
        "runtime_symbols",
        "may_allocate",
        "may_raise",
        "may_call_luau",
        "safepoint",
        "rejoins",
        "oracle",
        "tests",
        "status",
    ];
    let raw_commands = raw
        .get("commands")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "commands must be an array".to_owned())?;
    for (index, row) in raw_commands.iter().enumerate() {
        let object = row
            .as_object()
            .ok_or_else(|| format!("commands[{index}] must be an object"))?;
        for field in required_command_fields {
            if !object.contains_key(field) {
                return Err(format!("commands[{index}] missing required field {field}"));
            }
        }
    }

    const CLASSES: [&str; 10] = [
        "direct",
        "layout",
        "control",
        "runtime_helper",
        "guard_slowpath",
        "call_protocol",
        "gc_protocol",
        "compile_only",
        "rewrite_required",
        "unsupported",
    ];
    for row in &policy.commands {
        if !CLASSES.contains(&row.class.as_str()) {
            return Err(format!(
                "{}: unknown lowering class {}",
                row.command, row.class
            ));
        }
        if row.status != "unimplemented"
            && row.status != "implemented"
            && !row.status.starts_with("partial_")
        {
            return Err(format!("{}: invalid status {}", row.command, row.status));
        }
        if row.oracle.trim().is_empty() {
            return Err(format!("{}: empty oracle", row.command));
        }
        // Reading the fields here is deliberate: serde validates their types and the
        // explicit raw-key check above proves nullable effect fields were not omitted.
        let _ = (
            &row.wasm_features,
            &row.runtime_symbols,
            row.may_allocate,
            row.may_raise,
            row.may_call_luau,
            row.safepoint,
            row.rejoins,
            &row.tests,
        );
    }
    for row in policy.operand_kinds.iter().chain(&policy.block_kinds) {
        if row.treatment.trim().is_empty() {
            return Err(format!("{}: empty kind treatment", row.kind));
        }
        if row.status != "unimplemented" && row.status != "implemented" {
            return Err(format!("{}: invalid kind status {}", row.kind, row.status));
        }
    }

    let command_members: Vec<Member> = policy
        .commands
        .iter()
        .map(|row| Member {
            name: row.command.clone(),
            value: row.value,
        })
        .collect();
    let operand_members: Vec<Member> = policy
        .operand_kinds
        .iter()
        .map(|row| Member {
            name: row.kind.clone(),
            value: row.value,
        })
        .collect();
    let block_members: Vec<Member> = policy
        .block_kinds
        .iter()
        .map(|row| Member {
            name: row.kind.clone(),
            value: row.value,
        })
        .collect();

    exact_members("commands", &extraction.commands.members, &command_members)?;
    exact_members(
        "operand_kinds",
        &extraction.operand_kinds.members,
        &operand_members,
    )?;
    exact_members(
        "block_kinds",
        &extraction.block_kinds.members,
        &block_members,
    )
}
