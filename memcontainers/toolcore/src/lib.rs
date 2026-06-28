//! `toolcore` — pure catalog/search/schema logic for the agent-os tool plane.
//!
//! The resident `/svc/tools` broker owns syscalls and warmth; this crate owns the data contract:
//! dotted tool addresses, catalog parsing, deterministic lexical search, small JSON-Schema validation,
//! and JSON result envelopes. It is intentionally `no_std + alloc` so the same logic can run inside a
//! wasm guest and as a native unit test.

#![cfg_attr(not(test), no_std)]

extern crate alloc;

use alloc::string::{String, ToString};
use alloc::vec;
use alloc::vec::Vec;
use core::cmp::Ordering;

use json::Json;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgsMode {
    Json,
    Raw,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Binding {
    HostCall {
        name: String,
        args_mode: ArgsMode,
    },
    Service {
        service: String,
        op: String,
        adapter: String,
        args_mode: ArgsMode,
        request: Json,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolRecord {
    pub address: String,
    pub integration: String,
    pub owner: String,
    pub connection: String,
    pub tool: String,
    pub description: String,
    pub input_schema: Option<Json>,
    pub output_schema: Option<Json>,
    pub annotations: Json,
    pub binding: Binding,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Catalog {
    records: Vec<ToolRecord>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolConfig {
    pub catalog: Catalog,
    pub policies: PolicySet,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyAction {
    Approve,
    RequireApproval,
    Block,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PolicyRule {
    pub id: String,
    pub owner: String,
    pub pattern: String,
    pub action: PolicyAction,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PolicySet {
    rules: Vec<PolicyRule>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicySource {
    Default,
    Annotation,
    Policy,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PolicyDecision {
    pub action: PolicyAction,
    pub source: PolicySource,
    pub policy_id: Option<String>,
    pub pattern: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolError {
    Parse,
    Shape,
    InvalidAddress,
    InvalidBindingName,
    InvalidPolicy,
    DuplicateAddress,
    UnsupportedBinding,
    Validation,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub address: String,
    pub integration: String,
    pub description: String,
    pub score: i64,
}

impl Catalog {
    pub fn empty() -> Self {
        Self {
            records: Vec::new(),
        }
    }

    pub fn parse(src: &str) -> Result<Self, ToolError> {
        let doc = json::parse(src).map_err(|_| ToolError::Parse)?;
        Self::parse_json(&doc)
    }

    pub fn records(&self) -> &[ToolRecord] {
        &self.records
    }

    pub fn find(&self, address: &str) -> Option<&ToolRecord> {
        self.records.iter().find(|r| r.address == address)
    }

    /// Resolve a busybox-style command alias. Exact host-call binding names win; otherwise the final
    /// address segment may resolve only when it is unambiguous. Service-backed tools intentionally do
    /// not get a second raw binding-name namespace: their callable identity is the catalog address.
    pub fn find_alias(&self, alias: &str) -> Option<&ToolRecord> {
        if let Some(r) = self
            .records
            .iter()
            .find(|r| matches!(&r.binding, Binding::HostCall { name, .. } if name == alias))
        {
            return Some(r);
        }
        let mut found = None;
        for r in &self.records {
            let leading_binding = match &r.binding {
                Binding::HostCall { name, .. } => name.split_whitespace().next() == Some(alias),
                Binding::Service { .. } => false,
            };
            if r.tool == alias || leading_binding {
                if found.is_some() {
                    return None;
                }
                found = Some(r);
            }
        }
        found
    }

    pub fn search(&self, query: &str, offset: usize, limit: usize) -> (Vec<SearchHit>, usize) {
        let q_tokens = tokenize(query);
        let q_phrase = normalize(query);
        let mut scored = Vec::new();
        for rec in &self.records {
            let score = score_record(rec, &q_tokens, &q_phrase);
            if score > 0 || q_tokens.is_empty() {
                scored.push(SearchHit {
                    address: rec.address.clone(),
                    integration: rec.integration.clone(),
                    description: rec.description.clone(),
                    score,
                });
            }
        }
        scored.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| a.address.cmp(&b.address))
                .then(Ordering::Equal)
        });
        let total = scored.len();
        let start = offset.min(total);
        let end = start.saturating_add(limit).min(total);
        (scored[start..end].to_vec(), total)
    }
}

impl ToolConfig {
    pub fn empty() -> Self {
        Self {
            catalog: Catalog::empty(),
            policies: PolicySet::empty(),
        }
    }

    pub fn parse(src: &str) -> Result<Self, ToolError> {
        let doc = json::parse(src).map_err(|_| ToolError::Parse)?;
        let catalog = Catalog::parse_json(&doc)?;
        let policies = PolicySet::parse_json(&doc)?;
        Ok(Self { catalog, policies })
    }
}

impl PolicySet {
    pub fn empty() -> Self {
        Self { rules: Vec::new() }
    }

    pub fn parse(src: &str) -> Result<Self, ToolError> {
        let doc = json::parse(src).map_err(|_| ToolError::Parse)?;
        let rules = match &doc {
            Json::Arr(items) => parse_policy_rules(items)?,
            Json::Obj(_) => {
                let Some(policies) = doc.get("policies") else {
                    return Ok(Self::empty());
                };
                parse_policy_rules(policies.as_arr().ok_or(ToolError::InvalidPolicy)?)?
            }
            _ => return Err(ToolError::Shape),
        };
        Ok(Self { rules })
    }

    pub fn rules(&self) -> &[PolicyRule] {
        &self.rules
    }

    pub fn resolve(&self, rec: &ToolRecord) -> PolicyDecision {
        let mut matched_owners: Vec<String> = Vec::new();
        let mut by_owner: Vec<PolicyDecision> = Vec::new();
        for rule in &self.rules {
            if !pattern_matches(&rule.pattern, &rec.address) {
                continue;
            }
            if matched_owners.iter().any(|owner| owner == &rule.owner) {
                continue;
            }
            matched_owners.push(rule.owner.clone());
            by_owner.push(PolicyDecision {
                action: rule.action,
                source: PolicySource::Policy,
                policy_id: if rule.id.is_empty() {
                    None
                } else {
                    Some(rule.id.clone())
                },
                pattern: Some(rule.pattern.clone()),
            });
        }

        let mut strongest: Option<PolicyDecision> = None;
        for decision in by_owner {
            if strongest
                .as_ref()
                .map(|current| policy_rank(decision.action) > policy_rank(current.action))
                .unwrap_or(true)
            {
                strongest = Some(decision);
            }
        }
        if let Some(decision) = strongest {
            return decision;
        }

        if annotation_requires_approval(&rec.annotations) {
            return PolicyDecision {
                action: PolicyAction::RequireApproval,
                source: PolicySource::Annotation,
                policy_id: None,
                pattern: None,
            };
        }
        PolicyDecision {
            action: PolicyAction::Approve,
            source: PolicySource::Default,
            policy_id: None,
            pattern: None,
        }
    }

    pub fn to_json(&self) -> Json {
        Json::Arr(self.rules.iter().map(PolicyRule::to_json).collect())
    }

    fn parse_json(doc: &Json) -> Result<Self, ToolError> {
        let policies = match doc {
            Json::Arr(_) => &[][..],
            Json::Obj(_) => match doc.get("policies") {
                Some(v) => v.as_arr().ok_or(ToolError::InvalidPolicy)?,
                None => &[][..],
            },
            _ => return Err(ToolError::Shape),
        };
        Ok(Self {
            rules: parse_policy_rules(policies)?,
        })
    }
}

impl PolicyRule {
    pub fn to_json(&self) -> Json {
        let mut pairs = vec![
            ("owner".to_string(), Json::Str(self.owner.clone())),
            ("pattern".to_string(), Json::Str(self.pattern.clone())),
            (
                "action".to_string(),
                Json::Str(policy_action_name(self.action)),
            ),
        ];
        if !self.id.is_empty() {
            pairs.push(("id".to_string(), Json::Str(self.id.clone())));
        }
        Json::Obj(pairs)
    }
}

impl PolicyAction {
    pub fn as_str(self) -> &'static str {
        match self {
            PolicyAction::Approve => "approve",
            PolicyAction::RequireApproval => "require_approval",
            PolicyAction::Block => "block",
        }
    }
}

impl PolicySource {
    pub fn as_str(self) -> &'static str {
        match self {
            PolicySource::Default => "default",
            PolicySource::Annotation => "annotation",
            PolicySource::Policy => "policy",
        }
    }
}

impl ToolRecord {
    pub fn to_json(&self) -> Json {
        let mut pairs = Vec::new();
        pairs.push(("address".to_string(), Json::Str(self.address.clone())));
        pairs.push((
            "integration".to_string(),
            Json::Str(self.integration.clone()),
        ));
        pairs.push(("owner".to_string(), Json::Str(self.owner.clone())));
        pairs.push(("connection".to_string(), Json::Str(self.connection.clone())));
        pairs.push(("tool".to_string(), Json::Str(self.tool.clone())));
        pairs.push((
            "description".to_string(),
            Json::Str(self.description.clone()),
        ));
        if let Some(schema) = &self.input_schema {
            pairs.push(("input_schema".to_string(), schema.clone()));
        }
        if let Some(schema) = &self.output_schema {
            pairs.push(("output_schema".to_string(), schema.clone()));
        }
        pairs.push(("annotations".to_string(), self.annotations.clone()));
        pairs.push(("binding".to_string(), self.binding.to_json()));
        Json::Obj(pairs)
    }
}

impl Binding {
    pub fn args_mode(&self) -> ArgsMode {
        match self {
            Binding::HostCall { args_mode, .. } | Binding::Service { args_mode, .. } => *args_mode,
        }
    }

    pub fn to_json(&self) -> Json {
        match self {
            Binding::HostCall { name, args_mode } => Json::Obj(vec![
                ("type".to_string(), Json::Str("host_call".to_string())),
                ("name".to_string(), Json::Str(name.clone())),
                ("args".to_string(), Json::Str(args_mode_name(*args_mode))),
            ]),
            Binding::Service {
                service,
                op,
                adapter,
                args_mode,
                request,
            } => Json::Obj(vec![
                ("type".to_string(), Json::Str("service".to_string())),
                ("service".to_string(), Json::Str(service.clone())),
                ("op".to_string(), Json::Str(op.clone())),
                ("adapter".to_string(), Json::Str(adapter.clone())),
                ("args".to_string(), Json::Str(args_mode_name(*args_mode))),
                ("request".to_string(), request.clone()),
            ]),
        }
    }
}

impl Catalog {
    fn parse_json(doc: &Json) -> Result<Self, ToolError> {
        let tools = match doc {
            Json::Arr(items) => items.as_slice(),
            Json::Obj(_) => doc
                .get("tools")
                .and_then(|v| v.as_arr())
                .ok_or(ToolError::Shape)?,
            _ => return Err(ToolError::Shape),
        };
        let mut records = Vec::with_capacity(tools.len());
        for item in tools {
            records.push(parse_record(item)?);
        }
        records.sort_by(|a, b| a.address.cmp(&b.address));
        for pair in records.windows(2) {
            if pair[0].address == pair[1].address {
                return Err(ToolError::DuplicateAddress);
            }
        }
        Ok(Self { records })
    }
}

pub fn ok_json(data: Json) -> Json {
    Json::Obj(vec![
        ("ok".to_string(), Json::Bool(true)),
        ("data".to_string(), data),
    ])
}

pub fn err_json(code: &str, message: &str) -> Json {
    Json::Obj(vec![
        ("ok".to_string(), Json::Bool(false)),
        (
            "err".to_string(),
            Json::Obj(vec![
                ("code".to_string(), Json::Str(code.to_string())),
                ("message".to_string(), Json::Str(message.to_string())),
            ]),
        ),
    ])
}

pub fn search_page_json(items: &[SearchHit], total: usize, offset: usize, limit: usize) -> Json {
    let arr = items
        .iter()
        .map(|hit| {
            Json::Obj(vec![
                ("address".to_string(), Json::Str(hit.address.clone())),
                (
                    "integration".to_string(),
                    Json::Str(hit.integration.clone()),
                ),
                (
                    "description".to_string(),
                    Json::Str(hit.description.clone()),
                ),
                ("score".to_string(), Json::Num(hit.score as f64)),
            ])
        })
        .collect();
    let next = offset.saturating_add(limit);
    Json::Obj(vec![
        ("items".to_string(), Json::Arr(arr)),
        ("total".to_string(), Json::Num(total as f64)),
        ("hasMore".to_string(), Json::Bool(next < total)),
        (
            "nextOffset".to_string(),
            if next < total {
                Json::Num(next as f64)
            } else {
                Json::Null
            },
        ),
    ])
}

pub fn validate_args(schema: Option<&Json>, args: &Json) -> Result<(), ToolError> {
    if let Some(schema) = schema {
        validate(schema, args).map_err(|_| ToolError::Validation)
    } else {
        Ok(())
    }
}

pub fn annotation_requires_approval(annotations: &Json) -> bool {
    annotations
        .get("requires_approval")
        .and_then(Json::as_bool)
        == Some(true)
}

pub fn approval_description(rec: &ToolRecord) -> String {
    rec.annotations
        .get("approval_description")
        .and_then(Json::as_str)
        .unwrap_or(&rec.description)
        .to_string()
}

fn parse_policy_rules(policies: &[Json]) -> Result<Vec<PolicyRule>, ToolError> {
    let mut rules = Vec::with_capacity(policies.len());
    for item in policies {
        rules.push(parse_policy_rule(item)?);
    }
    Ok(rules)
}

fn parse_policy_rule(v: &Json) -> Result<PolicyRule, ToolError> {
    let owner = required_str(v, "owner")?;
    let pattern = required_str(v, "pattern")?;
    let action = parse_policy_action(required_str(v, "action")?)?;
    let id = v.get("id").and_then(Json::as_str).unwrap_or("");
    if !valid_segment(owner) || !valid_policy_pattern(pattern) {
        return Err(ToolError::InvalidPolicy);
    }
    if !id.is_empty() && !valid_policy_id(id) {
        return Err(ToolError::InvalidPolicy);
    }
    Ok(PolicyRule {
        id: id.to_string(),
        owner: owner.to_string(),
        pattern: pattern.to_string(),
        action,
    })
}

fn parse_policy_action(action: &str) -> Result<PolicyAction, ToolError> {
    match action {
        "approve" => Ok(PolicyAction::Approve),
        "require_approval" => Ok(PolicyAction::RequireApproval),
        "block" => Ok(PolicyAction::Block),
        _ => Err(ToolError::InvalidPolicy),
    }
}

fn policy_action_name(action: PolicyAction) -> String {
    action.as_str().to_string()
}

fn policy_rank(action: PolicyAction) -> u8 {
    match action {
        PolicyAction::Approve => 0,
        PolicyAction::RequireApproval => 1,
        PolicyAction::Block => 2,
    }
}

fn valid_policy_id(id: &str) -> bool {
    !id.is_empty()
        && id.trim() == id
        && !id.as_bytes().iter().any(|b| b.is_ascii_control())
}

fn valid_policy_pattern(pattern: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    let parts: Vec<&str> = pattern.split('.').collect();
    if parts.len() < 2 {
        return false;
    }
    parts.iter().all(|part| *part == "*" || valid_segment(part))
}

fn pattern_matches(pattern: &str, address: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    let p: Vec<&str> = pattern.split('.').collect();
    let a: Vec<&str> = address.split('.').collect();
    if p.last() == Some(&"*") {
        if p.len() == 1 || a.len() < p.len() - 1 {
            return false;
        }
        return p[..p.len() - 1]
            .iter()
            .zip(a.iter())
            .all(|(pp, aa)| *pp == "*" || pp == aa);
    }
    p.len() == a.len()
        && p.iter()
            .zip(a.iter())
            .all(|(pp, aa)| *pp == "*" || pp == aa)
}

fn parse_record(v: &Json) -> Result<ToolRecord, ToolError> {
    let address = required_str(v, "address")?.to_string();
    let (integration, owner, connection, tool) = parse_address(&address)?;
    let description = v
        .get("description")
        .and_then(|d| d.as_str())
        .unwrap_or("")
        .to_string();
    let binding_json = v.get("binding").ok_or(ToolError::Shape)?;
    let binding_type = binding_json
        .get("type")
        .and_then(|t| t.as_str())
        .unwrap_or("host_call");
    let binding = match binding_type {
        "host_call" => parse_host_binding(binding_json, &tool)?,
        "service" => parse_service_binding(binding_json)?,
        _ => return Err(ToolError::UnsupportedBinding),
    };
    Ok(ToolRecord {
        address,
        integration,
        owner,
        connection,
        tool,
        description,
        input_schema: v.get("input_schema").cloned(),
        output_schema: v.get("output_schema").cloned(),
        annotations: v
            .get("annotations")
            .cloned()
            .unwrap_or_else(|| Json::Obj(Vec::new())),
        binding,
    })
}

fn parse_host_binding(binding_json: &Json, tool: &str) -> Result<Binding, ToolError> {
    let binding_name = binding_json
        .get("name")
        .and_then(|n| n.as_str())
        .unwrap_or(tool);
    if !valid_binding_name(binding_name) {
        return Err(ToolError::InvalidBindingName);
    }
    Ok(Binding::HostCall {
        name: binding_name.to_string(),
        args_mode: parse_args_mode(binding_json)?,
    })
}

fn parse_service_binding(binding_json: &Json) -> Result<Binding, ToolError> {
    let service = required_str(binding_json, "service")?;
    let op = required_str(binding_json, "op")?;
    let adapter = required_str(binding_json, "adapter")?;
    if !valid_service_name(service) || !valid_op_name(op) || !valid_segment(adapter) {
        return Err(ToolError::InvalidBindingName);
    }
    let request = binding_json
        .get("request")
        .cloned()
        .unwrap_or_else(|| Json::Obj(Vec::new()));
    if !matches!(request, Json::Obj(_)) {
        return Err(ToolError::Shape);
    }
    Ok(Binding::Service {
        service: service.to_string(),
        op: op.to_string(),
        adapter: adapter.to_string(),
        args_mode: parse_args_mode(binding_json)?,
        request,
    })
}

fn parse_args_mode(binding_json: &Json) -> Result<ArgsMode, ToolError> {
    match binding_json
        .get("args")
        .and_then(|a| a.as_str())
        .unwrap_or("json")
    {
        "raw" => Ok(ArgsMode::Raw),
        "json" => Ok(ArgsMode::Json),
        _ => Err(ToolError::UnsupportedBinding),
    }
}

fn args_mode_name(mode: ArgsMode) -> String {
    match mode {
        ArgsMode::Json => "json",
        ArgsMode::Raw => "raw",
    }
    .to_string()
}

fn required_str<'a>(v: &'a Json, key: &str) -> Result<&'a str, ToolError> {
    v.get(key).and_then(|s| s.as_str()).ok_or(ToolError::Shape)
}

fn parse_address(address: &str) -> Result<(String, String, String, String), ToolError> {
    let parts: Vec<&str> = address.split('.').collect();
    if parts.len() < 4 {
        return Err(ToolError::InvalidAddress);
    }
    for part in &parts {
        if !valid_segment(part) {
            return Err(ToolError::InvalidAddress);
        }
    }
    if parts[1] != "org" && parts[1] != "user" {
        return Err(ToolError::InvalidAddress);
    }
    Ok((
        parts[0].to_string(),
        parts[1].to_string(),
        parts[2].to_string(),
        parts[3..].join("."),
    ))
}

fn valid_segment(s: &str) -> bool {
    !s.is_empty()
        && s.as_bytes()
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

/// Host-call tool bindings live in a UTF-8 key space separated from raw mount handlers. Raw handlers are
/// keyed by absolute paths and request blobs are NUL-framed, so catalog bindings must be plain non-empty
/// names: no raw-handler `/...` namespace, no framing byte, and no control characters.
fn valid_binding_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('/')
        && name.trim() == name
        && !name.as_bytes().iter().any(|b| b.is_ascii_control())
}

fn valid_service_name(name: &str) -> bool {
    valid_segment(name)
}

fn valid_op_name(name: &str) -> bool {
    !name.is_empty()
        && name.trim() == name
        && !name.as_bytes().iter().any(|b| b.is_ascii_control())
        && name
            .as_bytes()
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'.' || *b == b'_' || *b == b'-')
}

fn normalize(s: &str) -> String {
    let mut out = String::new();
    let mut prev_lower_or_digit = false;
    let mut prev_space = true;
    for c in s.chars() {
        if c.is_ascii_uppercase() {
            if prev_lower_or_digit && !prev_space {
                out.push(' ');
            }
            out.push(c.to_ascii_lowercase());
            prev_lower_or_digit = false;
            prev_space = false;
        } else if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            prev_lower_or_digit = c.is_ascii_lowercase() || c.is_ascii_digit();
            prev_space = false;
        } else {
            if !prev_space {
                out.push(' ');
            }
            prev_lower_or_digit = false;
            prev_space = true;
        }
    }
    out.trim().to_string()
}

fn tokenize(s: &str) -> Vec<String> {
    normalize(s)
        .split_whitespace()
        .map(|p| p.to_string())
        .collect()
}

fn score_record(rec: &ToolRecord, q_tokens: &[String], q_phrase: &str) -> i64 {
    if q_tokens.is_empty() {
        return 1;
    }
    let fields = [
        (&rec.address, 12i64),
        (&rec.tool, 10),
        (&rec.integration, 8),
        (&rec.description, 5),
    ];
    let mut score = 0;
    let mut covered = 0;
    for token in q_tokens {
        let mut hit = false;
        for (field, weight) in &fields {
            let f = normalize(field);
            if f.split_whitespace().any(|p| p == token) {
                score += *weight;
                hit = true;
            } else if f.split_whitespace().any(|p| p.starts_with(token)) {
                score += *weight / 2;
                hit = true;
            }
            if !q_phrase.is_empty() && f.contains(q_phrase) {
                score += *weight * 2;
            }
        }
        if hit {
            covered += 1;
        }
    }
    if covered == q_tokens.len() {
        score += 25;
    }
    score
}

fn validate(schema: &Json, value: &Json) -> Result<(), ()> {
    if let Some(types) = schema.get("type") {
        match types {
            Json::Str(t) => validate_type(t, schema, value)?,
            Json::Arr(options) => {
                let mut ok = false;
                for opt in options {
                    if let Some(t) = opt.as_str() {
                        if validate_type(t, schema, value).is_ok() {
                            ok = true;
                            break;
                        }
                    }
                }
                if !ok {
                    return Err(());
                }
            }
            _ => return Err(()),
        }
    }
    if let Some(enums) = schema.get("enum").and_then(|e| e.as_arr()) {
        if !enums.iter().any(|candidate| candidate == value) {
            return Err(());
        }
    }
    Ok(())
}

fn validate_type(t: &str, schema: &Json, value: &Json) -> Result<(), ()> {
    match t {
        "object" => validate_object(schema, value),
        "array" => validate_array(schema, value),
        "string" => value.as_str().map(|_| ()).ok_or(()),
        "boolean" => value.as_bool().map(|_| ()).ok_or(()),
        "number" => value.as_f64().map(|_| ()).ok_or(()),
        "integer" => match value.as_f64() {
            Some(n) if n.is_finite() && n == (n as i64) as f64 => Ok(()),
            _ => Err(()),
        },
        "null" => match value {
            Json::Null => Ok(()),
            _ => Err(()),
        },
        _ => Ok(()), // Unknown JSON-Schema type keywords are left to host-side validators.
    }
}

fn validate_object(schema: &Json, value: &Json) -> Result<(), ()> {
    let Json::Obj(pairs) = value else {
        return Err(());
    };
    if let Some(required) = schema.get("required").and_then(|r| r.as_arr()) {
        for req in required {
            let Some(name) = req.as_str() else {
                return Err(());
            };
            if !pairs.iter().any(|(k, _)| k == name) {
                return Err(());
            }
        }
    }
    let props = schema.get("properties").and_then(|p| p.as_obj());
    if schema.get("additionalProperties").and_then(|p| p.as_bool()) == Some(false) {
        for (k, _) in pairs {
            let declared = props
                .map(|p| p.iter().any(|(pk, _)| pk == k))
                .unwrap_or(false);
            if !declared {
                return Err(());
            }
        }
    }
    if let Some(props) = props {
        for (k, v) in pairs {
            if let Some((_, ps)) = props.iter().find(|(pk, _)| pk == k) {
                validate(ps, v)?;
            }
        }
    }
    Ok(())
}

fn validate_array(schema: &Json, value: &Json) -> Result<(), ()> {
    let Json::Arr(items) = value else {
        return Err(());
    };
    if let Some(item_schema) = schema.get("items") {
        for item in items {
            validate(item_schema, item)?;
        }
    }
    Ok(())
}

pub fn parse_json_or_string(src: &str) -> Json {
    let trimmed = src.trim();
    if trimmed.starts_with('{')
        || trimmed.starts_with('[')
        || trimmed.starts_with('"')
        || trimmed == "true"
        || trimmed == "false"
        || trimmed == "null"
        || trimmed.parse::<f64>().is_ok()
    {
        if let Ok(v) = json::parse(trimmed) {
            return v;
        }
    }
    Json::Str(src.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_catalog_and_ranks_lexically() {
        let catalog = Catalog::parse(
            r#"{"tools":[
              {"address":"github.org.main.createIssue","description":"Create a GitHub issue",
               "binding":{"type":"host_call","name":"github.issue","args":"json"}},
              {"address":"sentry.org.main.listIssues","description":"List release-blocker issues",
               "binding":{"type":"host_call","name":"sentry.list","args":"json"}}
            ]}"#,
        )
        .unwrap();
        assert_eq!(catalog.records().len(), 2);
        let (hits, total) = catalog.search("create github issue", 0, 10);
        assert_eq!(total, 2);
        assert_eq!(hits[0].address, "github.org.main.createIssue");
        assert!(hits[0].score > 0);
    }

    #[test]
    fn validates_small_schema_subset() {
        let schema = json::parse(
            r#"{"type":"object","required":["repo","title"],"additionalProperties":false,
                "properties":{"repo":{"type":"string"},"title":{"type":"string"},"n":{"type":"integer"}}}"#,
        )
        .unwrap();
        let good = json::parse(r#"{"repo":"acme/web","title":"bug","n":2}"#).unwrap();
        let missing = json::parse(r#"{"repo":"acme/web"}"#).unwrap();
        let extra = json::parse(r#"{"repo":"acme/web","title":"bug","x":1}"#).unwrap();
        assert_eq!(validate_args(Some(&schema), &good), Ok(()));
        assert_eq!(
            validate_args(Some(&schema), &missing),
            Err(ToolError::Validation)
        );
        assert_eq!(
            validate_args(Some(&schema), &extra),
            Err(ToolError::Validation)
        );
    }

    #[test]
    fn resolves_alias_without_legacy_names() {
        let catalog = Catalog::parse(
            r#"{"tools":[{"address":"host.org.main.greet","description":"Greet",
               "binding":{"type":"host_call","name":"greet","args":"raw"}}]}"#,
        )
        .unwrap();
        assert_eq!(
            catalog.find_alias("greet").unwrap().address,
            "host.org.main.greet"
        );
    }

    #[test]
    fn parses_service_bindings_without_host_call_names() {
        let catalog = Catalog::parse(
            r#"{"tools":[{"address":"petstore.org.main.listPets","description":"List pets",
               "binding":{"type":"service","service":"adapters","op":"invoke","adapter":"openapi",
                 "args":"json","request":{"method":"GET","url_template":"https://example.test/pets"}}}]}"#,
        )
        .unwrap();
        let rec = catalog.find("petstore.org.main.listPets").unwrap();
        match &rec.binding {
            Binding::Service {
                service,
                op,
                adapter,
                request,
                ..
            } => {
                assert_eq!(service, "adapters");
                assert_eq!(op, "invoke");
                assert_eq!(adapter, "openapi");
                assert_eq!(request.get("method").and_then(Json::as_str), Some("GET"));
            }
            other => panic!("expected service binding, got {other:?}"),
        }
        assert_eq!(
            rec.to_json()
                .get("binding")
                .and_then(|b| b.get("service"))
                .and_then(Json::as_str),
            Some("adapters")
        );
    }

    #[test]
    fn policy_resolution_uses_annotations_as_defaults() {
        let config = ToolConfig::parse(
            r#"{"tools":[{"address":"github.org.main.deleteIssue","description":"Delete issue",
               "annotations":{"requires_approval":true,"approval_description":"DELETE /issues/{id}"},
               "binding":{"type":"host_call","name":"github.delete","args":"json"}}]}"#,
        )
        .unwrap();
        let rec = config.catalog.find("github.org.main.deleteIssue").unwrap();
        let decision = config.policies.resolve(rec);
        assert_eq!(decision.action, PolicyAction::RequireApproval);
        assert_eq!(decision.source, PolicySource::Annotation);
        assert_eq!(approval_description(rec), "DELETE /issues/{id}");
    }

    #[test]
    fn policy_resolution_is_first_match_per_owner_then_most_restrictive() {
        let config = ToolConfig::parse(
            r#"{"tools":[{"address":"github.org.main.deleteIssue","description":"Delete issue",
               "annotations":{"requires_approval":true},
               "binding":{"type":"host_call","name":"github.delete","args":"json"}}],
               "policies":[
                 {"id":"org-approve","owner":"org","pattern":"github.org.main.*","action":"approve"},
                 {"id":"org-block-later","owner":"org","pattern":"github.org.main.deleteIssue","action":"block"},
                 {"id":"user-require","owner":"user","pattern":"github.*","action":"require_approval"}
               ]}"#,
        )
        .unwrap();
        let rec = config.catalog.find("github.org.main.deleteIssue").unwrap();
        let decision = config.policies.resolve(rec);
        assert_eq!(decision.action, PolicyAction::RequireApproval);
        assert_eq!(decision.source, PolicySource::Policy);
        assert_eq!(decision.policy_id.as_deref(), Some("user-require"));
        assert_eq!(decision.pattern.as_deref(), Some("github.*"));
    }

    #[test]
    fn rejects_partial_wildcard_policy_patterns() {
        let err = ToolConfig::parse(
            r#"{"tools":[],"policies":[
              {"owner":"org","pattern":"github.org.main.del*","action":"block"}
            ]}"#,
        )
        .unwrap_err();
        assert_eq!(err, ToolError::InvalidPolicy);
    }

    #[test]
    fn rejects_malformed_policy_block() {
        let err = ToolConfig::parse(r#"{"tools":[],"policies":{}}"#).unwrap_err();
        assert_eq!(err, ToolError::InvalidPolicy);
    }

    #[test]
    fn rejects_bad_addresses() {
        for bad in [
            "x.main.greet",
            "x.team.main.greet",
            "x.org.main.",
            "x.org.main.greet/now",
        ] {
            let src = format!(
                r#"{{"tools":[{{"address":"{bad}","binding":{{"type":"host_call","name":"x"}}}}]}}"#
            );
            assert!(Catalog::parse(&src).is_err(), "{bad}");
        }
    }

    #[test]
    fn rejects_unsafe_binding_names() {
        for bad in ["", "/mnt/search", " greet", "greet "] {
            let src = format!(
                r#"{{"tools":[{{"address":"host.org.main.greet","binding":{{"type":"host_call","name":"{bad}"}}}}]}}"#
            );
            assert_eq!(
                Catalog::parse(&src).unwrap_err(),
                ToolError::InvalidBindingName,
                "{bad:?}"
            );
        }

        for bad in ["bad\nname", "bad\0name"] {
            assert_eq!(
                parse_record(&record_with_binding_name(bad)).unwrap_err(),
                ToolError::InvalidBindingName
            );
        }
    }

    #[test]
    fn rejects_unsafe_service_bindings() {
        let err = Catalog::parse(
            r#"{"tools":[{"address":"petstore.org.main.listPets",
               "binding":{"type":"service","service":"/adapters","op":"invoke","adapter":"openapi",
                 "request":{}}}]}"#,
        )
        .unwrap_err();
        assert_eq!(err, ToolError::InvalidBindingName);
    }

    #[test]
    fn rejects_duplicate_addresses() {
        let err = Catalog::parse(
            r#"{"tools":[
              {"address":"host.org.main.greet","binding":{"type":"host_call","name":"greet"}},
              {"address":"host.org.main.greet","binding":{"type":"host_call","name":"greet-again"}}
            ]}"#,
        )
        .unwrap_err();
        assert_eq!(err, ToolError::DuplicateAddress);
    }

    #[test]
    fn accepts_spaced_binding_names_for_kits() {
        let catalog = Catalog::parse(
            r#"{"tools":[{"address":"host.org.main.weather.get","description":"Weather",
               "binding":{"type":"host_call","name":"weather get","args":"json"}}]}"#,
        )
        .unwrap();
        assert_eq!(
            catalog.find_alias("weather").unwrap().address,
            "host.org.main.weather.get"
        );
    }

    fn record_with_binding_name(name: &str) -> Json {
        Json::Obj(vec![
            (
                "address".to_string(),
                Json::Str("host.org.main.greet".to_string()),
            ),
            (
                "binding".to_string(),
                Json::Obj(vec![
                    ("type".to_string(), Json::Str("host_call".to_string())),
                    ("name".to_string(), Json::Str(name.to_string())),
                ]),
            ),
        ])
    }
}
