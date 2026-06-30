//! `toolcore` — pure catalog/search/schema logic for the agent-os tool plane.
//!
//! The resident `/svc/tools` broker owns syscalls and warmth; this crate owns the data contract:
//! dotted tool addresses, sharded catalog parsing, deterministic lexical search, small JSON-Schema
//! validation, and JSON result envelopes. It is intentionally `no_std + alloc` so the
//! same logic can run inside a wasm guest and as a native unit test.

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
pub struct IndexEntry {
    pub address: String,
    pub integration: String,
    pub owner: String,
    pub connection: String,
    pub tool: String,
    pub description: String,
    pub sha: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CatalogIndex {
    generation: u64,
    entries: Vec<IndexEntry>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolError {
    Parse,
    Shape,
    InvalidAddress,
    InvalidBindingName,
    DuplicateAddress,
    UnsupportedBinding,
    Validation,
    InvalidDigest,
    InvalidShard,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub address: String,
    pub integration: String,
    pub description: String,
    pub score: i64,
}

impl CatalogIndex {
    pub fn empty() -> Self {
        Self {
            generation: 0,
            entries: Vec::new(),
        }
    }

    pub fn parse(src: &str) -> Result<Self, ToolError> {
        let doc = json::parse(src).map_err(|_| ToolError::Parse)?;
        Self::parse_json(&doc)
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn entries(&self) -> &[IndexEntry] {
        &self.entries
    }

    pub fn find(&self, address: &str) -> Option<&IndexEntry> {
        self.entries.iter().find(|r| r.address == address)
    }

    /// Resolve a busybox-style command alias from the index alone. The legacy full-record resolver
    /// could also match a host binding name; in the sharded model that name lives in the shard, so alias
    /// lookup intentionally stays address-tail based and hydrates at most one selected record.
    pub fn find_alias(&self, alias: &str) -> Option<&IndexEntry> {
        let mut found = None;
        for entry in &self.entries {
            let leading_tool = entry.tool.split('.').next() == Some(alias);
            if entry.tool == alias || leading_tool {
                if found.is_some() {
                    return None;
                }
                found = Some(entry);
            }
        }
        found
    }

    pub fn search(&self, query: &str, offset: usize, limit: usize) -> (Vec<SearchHit>, usize) {
        let q_tokens = tokenize(query);
        let q_phrase = normalize(query);
        let mut scored = Vec::new();
        for entry in &self.entries {
            let score = score_entry(entry, &q_tokens, &q_phrase);
            if score > 0 || q_tokens.is_empty() {
                scored.push(SearchHit {
                    address: entry.address.clone(),
                    integration: entry.integration.clone(),
                    description: entry.description.clone(),
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

    pub fn to_json(&self) -> Json {
        Json::Obj(vec![
            ("generation".to_string(), Json::Num(self.generation as f64)),
            (
                "tools".to_string(),
                Json::Arr(self.entries.iter().map(IndexEntry::to_json).collect()),
            ),
        ])
    }

    fn parse_json(doc: &Json) -> Result<Self, ToolError> {
        let Json::Obj(_) = doc else {
            return Err(ToolError::Shape);
        };
        let generation = doc
            .get("generation")
            .and_then(Json::as_u64)
            .ok_or(ToolError::Shape)?;
        let tools = doc
            .get("tools")
            .and_then(Json::as_arr)
            .ok_or(ToolError::Shape)?;
        let mut entries = Vec::with_capacity(tools.len());
        for item in tools {
            entries.push(parse_index_entry(item)?);
        }
        entries.sort_by(|a, b| a.address.cmp(&b.address));
        for pair in entries.windows(2) {
            if pair[0].address == pair[1].address {
                return Err(ToolError::DuplicateAddress);
            }
        }
        Ok(Self {
            generation,
            entries,
        })
    }
}

impl IndexEntry {
    pub fn to_json(&self) -> Json {
        Json::Obj(vec![
            ("address".to_string(), Json::Str(self.address.clone())),
            (
                "integration".to_string(),
                Json::Str(self.integration.clone()),
            ),
            (
                "description".to_string(),
                Json::Str(self.description.clone()),
            ),
            ("sha".to_string(), Json::Str(self.sha.clone())),
        ])
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

pub fn hydrate_record(entry: &IndexEntry, src: &str) -> Result<ToolRecord, ToolError> {
    let shard = json::parse(src).map_err(|_| ToolError::Parse)?;
    hydrate_record_json(entry, &shard)
}

pub fn hydrate_record_json(entry: &IndexEntry, shard: &Json) -> Result<ToolRecord, ToolError> {
    if !matches!(shard, Json::Obj(_)) {
        return Err(ToolError::Shape);
    }
    if shard.get("address").is_some()
        || shard.get("description").is_some()
        || contains_key_recursive(shard, "connection_ref")
    {
        return Err(ToolError::InvalidShard);
    }
    let binding_json = shard.get("binding").ok_or(ToolError::Shape)?;
    let binding_type = binding_json
        .get("type")
        .and_then(|t| t.as_str())
        .unwrap_or("host_call");
    let binding = match binding_type {
        "host_call" => parse_host_binding(binding_json, &entry.tool)?,
        "service" => parse_service_binding(binding_json)?,
        _ => return Err(ToolError::UnsupportedBinding),
    };
    Ok(ToolRecord {
        address: entry.address.clone(),
        integration: entry.integration.clone(),
        owner: entry.owner.clone(),
        connection: entry.connection.clone(),
        tool: entry.tool.clone(),
        description: entry.description.clone(),
        input_schema: shard.get("input_schema").cloned(),
        output_schema: shard.get("output_schema").cloned(),
        annotations: shard
            .get("annotations")
            .cloned()
            .unwrap_or_else(|| Json::Obj(Vec::new())),
        binding,
    })
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

pub fn parse_address(address: &str) -> Result<(String, String, String, String), ToolError> {
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

fn parse_index_entry(v: &Json) -> Result<IndexEntry, ToolError> {
    let address = required_str(v, "address")?.to_string();
    let (addr_integration, owner, connection, tool) = parse_address(&address)?;
    let integration = required_str(v, "integration")?.to_string();
    if integration != addr_integration || !valid_segment(&integration) {
        return Err(ToolError::InvalidAddress);
    }
    let sha = required_str(v, "sha")?.to_ascii_lowercase();
    if !valid_sha(&sha) {
        return Err(ToolError::InvalidDigest);
    }
    let description = v
        .get("description")
        .and_then(Json::as_str)
        .unwrap_or("")
        .to_string();
    Ok(IndexEntry {
        address,
        integration,
        owner,
        connection,
        tool,
        description,
        sha,
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

fn valid_segment(s: &str) -> bool {
    !s.is_empty()
        && s.as_bytes()
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

fn valid_sha(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Host-call tool bindings live in a UTF-8 key space separated from raw mount handlers. Raw handlers are
/// keyed by absolute paths and request blobs are NUL-framed, so catalog bindings must be plain non-empty
/// names: no raw-handler `/...` namespace, no framing byte, and no control characters. Public so both
/// hosts validate host-tool bindings against this one definition (no per-host mirror).
pub fn valid_binding_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('/')
        && name.trim() == name
        && !name.as_bytes().iter().any(|b| b.is_ascii_control())
}

/// Validate + split a connection reference `integration.{org|user}.connection` (exactly three valid
/// segments) — the shape the host `X-MC-Connection` marker and the catalog re-prefixer key on. The
/// single source for both hosts (no per-host ref parser).
pub fn parse_connection_ref(reference: &str) -> Result<(String, String, String), ToolError> {
    let parts: Vec<&str> = reference.split('.').collect();
    if parts.len() != 3 || (parts[1] != "org" && parts[1] != "user") {
        return Err(ToolError::InvalidAddress);
    }
    if !parts.iter().all(|p| valid_segment(p)) {
        return Err(ToolError::InvalidAddress);
    }
    Ok((
        parts[0].to_string(),
        parts[1].to_string(),
        parts[2].to_string(),
    ))
}

/// The outcome of a `catalog.apply` compare-and-swap, decided purely from content digests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CatalogApplyDecision {
    /// The incoming catalog already equals the live one — a retry/duplicate is harmless. Commit nothing.
    NoOp,
    /// The caller edited a base the live catalog has since moved past — reject the stale write.
    Conflict,
    /// Proceed to commit the incoming catalog.
    Apply,
}

/// Decide a `catalog.apply` from the incoming content digest, the live digest, and the optional base the
/// caller edited. **Idempotency wins first**: if the result is already live it is a no-op regardless of
/// the base, so a retried apply after a lost response (the caller still holds the old base) is harmless —
/// the digest *is* the version. Only a genuinely new result is gated by the base (compare-and-swap). All
/// three digests must already be normalized (lowercase hex) by the caller.
pub fn catalog_apply_decision(
    incoming: &str,
    live: &str,
    base: Option<&str>,
) -> CatalogApplyDecision {
    if incoming == live {
        return CatalogApplyDecision::NoOp;
    }
    if let Some(base) = base {
        if base != live {
            return CatalogApplyDecision::Conflict;
        }
    }
    CatalogApplyDecision::Apply
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

fn contains_key_recursive(value: &Json, needle: &str) -> bool {
    match value {
        Json::Obj(pairs) => pairs
            .iter()
            .any(|(key, child)| key == needle || contains_key_recursive(child, needle)),
        Json::Arr(items) => items
            .iter()
            .any(|item| contains_key_recursive(item, needle)),
        _ => false,
    }
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

fn score_entry(entry: &IndexEntry, q_tokens: &[String], q_phrase: &str) -> i64 {
    if q_tokens.is_empty() {
        return 1;
    }
    let fields = [
        (&entry.address, 12i64),
        (&entry.tool, 10),
        (&entry.integration, 8),
        (&entry.description, 5),
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

/// The tool-policy engine — the single source of policy logic for BOTH host families. The
/// wasmtime/Elixir host links this natively; the JS host calls it through `catalog-compiler.wasm`
/// (`cc_policy_resolve` / `cc_validate_policy`). There is no second implementation: a Rust copy plus a
/// TypeScript copy was forbidden drift. The host owns only transport + the credential splice; the
/// decision (which pattern matches, most-restrictive resolution, what is a valid pattern) lives here.
pub mod policy {
    use alloc::string::String;
    use alloc::vec::Vec;

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum ToolPolicyAction {
        Approve,
        RequireApproval,
        Block,
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum ToolPolicyOwner {
        Org,
        User,
    }

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct ToolPolicyRule {
        pub owner: ToolPolicyOwner,
        pub pattern: String,
        pub action: ToolPolicyAction,
    }

    #[derive(Debug, Clone, Default)]
    pub struct ToolPolicySet {
        rules: Vec<ToolPolicyRule>,
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum ToolPolicyError {
        InvalidOwner,
        InvalidPattern,
        InvalidAction,
    }

    impl ToolPolicySet {
        pub fn new(rules: Vec<ToolPolicyRule>) -> Result<Self, ToolPolicyError> {
            for rule in &rules {
                validate_rule(rule)?;
            }
            Ok(Self { rules })
        }

        pub fn empty() -> Self {
            Self::default()
        }

        pub fn resolve(&self, address: &str) -> Option<ToolPolicyAction> {
            let mut seen_org = false;
            let mut seen_user = false;
            let mut strongest = None::<ToolPolicyAction>;
            for rule in &self.rules {
                let seen = match rule.owner {
                    ToolPolicyOwner::Org => &mut seen_org,
                    ToolPolicyOwner::User => &mut seen_user,
                };
                if *seen || !pattern_matches(&rule.pattern, address) {
                    continue;
                }
                *seen = true;
                if strongest
                    .map(|current| action_rank(rule.action) > action_rank(current))
                    .unwrap_or(true)
                {
                    strongest = Some(rule.action);
                }
            }
            strongest
        }
    }

    fn validate_rule(rule: &ToolPolicyRule) -> Result<(), ToolPolicyError> {
        match rule.owner {
            ToolPolicyOwner::Org | ToolPolicyOwner::User => {}
        }
        match rule.action {
            ToolPolicyAction::Approve
            | ToolPolicyAction::RequireApproval
            | ToolPolicyAction::Block => {}
        }
        if !valid_policy_pattern(&rule.pattern) {
            return Err(ToolPolicyError::InvalidPattern);
        }
        Ok(())
    }

    fn valid_policy_pattern(pattern: &str) -> bool {
        if pattern == "*" {
            return true;
        }
        // The host authorizes at the egress splice, where it knows the connection
        // (`integration.owner.connection`) and the request's method/origin, but NOT the catalog tool
        // address — so it resolves rules against `integration.owner.connection.*`. A pattern can
        // therefore only match at connection granularity or coarser: a trailing wildcard with at most
        // three concrete segments. A per-tool pattern (a concrete fourth segment) could never match
        // and would silently no-op, so it is rejected at construction rather than left as a fail-open
        // footgun.
        let parts = pattern.split('.').collect::<Vec<_>>();
        parts.len() >= 2
            && parts.len() <= 4
            && parts.last() == Some(&"*")
            && parts.iter().all(|part| *part == "*" || valid_segment(part))
    }

    fn pattern_matches(pattern: &str, address: &str) -> bool {
        if pattern == "*" {
            return true;
        }
        let p = pattern.split('.').collect::<Vec<_>>();
        let a = address.split('.').collect::<Vec<_>>();
        if p.last() == Some(&"*") {
            if a.len() < p.len() - 1 {
                return false;
            }
            return p[..p.len() - 1]
                .iter()
                .zip(a.iter())
                .all(|(p, a)| *p == "*" || p == a);
        }
        p.len() == a.len() && p.iter().zip(a.iter()).all(|(p, a)| *p == "*" || p == a)
    }

    fn valid_segment(value: &str) -> bool {
        !value.is_empty()
            && value
                .bytes()
                .all(|b| matches!(b, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'_' | b'-'))
    }

    fn action_rank(action: ToolPolicyAction) -> u8 {
        match action {
            ToolPolicyAction::Approve => 0,
            ToolPolicyAction::RequireApproval => 1,
            ToolPolicyAction::Block => 2,
        }
    }
}

#[cfg(test)]
mod policy_tests {
    use super::policy::{ToolPolicyAction, ToolPolicyOwner, ToolPolicyRule, ToolPolicySet};

    fn rule(owner: ToolPolicyOwner, pattern: &str, action: ToolPolicyAction) -> ToolPolicyRule {
        ToolPolicyRule {
            owner,
            pattern: pattern.into(),
            action,
        }
    }

    #[test]
    fn resolves_at_connection_granularity() {
        use ToolPolicyAction::*;
        use ToolPolicyOwner::*;
        let addr = "github.org.main.*";
        assert_eq!(ToolPolicySet::new(vec![]).unwrap().resolve(addr), None);
        assert_eq!(
            ToolPolicySet::new(vec![rule(Org, "*", Block)]).unwrap().resolve(addr),
            Some(Block)
        );
        assert_eq!(
            ToolPolicySet::new(vec![rule(Org, "github.*", RequireApproval)]).unwrap().resolve(addr),
            Some(RequireApproval)
        );
        assert_eq!(
            ToolPolicySet::new(vec![rule(User, "github.org.main.*", Approve)]).unwrap().resolve(addr),
            Some(Approve)
        );
        assert_eq!(
            ToolPolicySet::new(vec![rule(Org, "github.org.other.*", Block)]).unwrap().resolve(addr),
            None
        );
    }

    #[test]
    fn first_match_per_owner_then_most_restrictive() {
        use ToolPolicyAction::*;
        use ToolPolicyOwner::*;
        let addr = "github.org.main.*";
        // org: the earlier match (approve) wins for that owner, ignoring the later block.
        assert_eq!(
            ToolPolicySet::new(vec![
                rule(Org, "github.org.main.*", Approve),
                rule(Org, "github.*", Block),
            ])
            .unwrap()
            .resolve(addr),
            Some(Approve)
        );
        // across owners: the most restrictive wins (org approve + user block → block).
        assert_eq!(
            ToolPolicySet::new(vec![
                rule(Org, "github.*", Approve),
                rule(User, "github.org.main.*", Block),
            ])
            .unwrap()
            .resolve(addr),
            Some(Block)
        );
    }

    #[test]
    fn rejects_unenforceable_patterns_accepts_connection_granular() {
        use ToolPolicyAction::Block;
        use ToolPolicyOwner::Org;
        // per-tool (concrete 4th segment), 5-segment, exact (no trailing wildcard), empty segment.
        for pat in [
            "github.org.main.delete-repo",
            "github.org.main.issues.*",
            "github.org.main",
            "github..main.*",
        ] {
            assert!(
                ToolPolicySet::new(vec![rule(Org, pat, Block)]).is_err(),
                "pattern {pat:?} must be rejected at construction"
            );
        }
        for pat in ["*", "github.*", "github.org.*", "github.org.main.*"] {
            assert!(
                ToolPolicySet::new(vec![rule(Org, pat, Block)]).is_ok(),
                "pattern {pat:?} must be accepted"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    fn entry(address: &str, description: &str) -> IndexEntry {
        let (integration, owner, connection, tool) = parse_address(address).unwrap();
        IndexEntry {
            address: address.to_string(),
            integration,
            owner,
            connection,
            tool,
            description: description.to_string(),
            sha: SHA.to_string(),
        }
    }

    #[test]
    fn parses_index_and_ranks_lexically() {
        let index = CatalogIndex::parse(&alloc::format!(
            r#"{{"generation":2,"tools":[
              {{"address":"github.org.main.createIssue","integration":"github","description":"Create a GitHub issue","sha":"{SHA}"}},
              {{"address":"sentry.org.main.listIssues","integration":"sentry","description":"List release-blocker issues","sha":"{SHA}"}}
            ]}}"#
        ))
        .unwrap();
        assert_eq!(index.generation(), 2);
        assert_eq!(index.entries().len(), 2);
        let (hits, total) = index.search("create github issue", 0, 10);
        assert_eq!(total, 2);
        assert_eq!(hits[0].address, "github.org.main.createIssue");
        assert!(hits[0].score > 0);
    }

    #[test]
    fn hydrates_a_shard_with_index_identity() {
        let rec = hydrate_record(
            &entry("petstore.org.main.listPets", "List pets"),
            r#"{"input_schema":{"type":"object"},"annotations":{},
               "binding":{"type":"service","service":"adapters","op":"invoke","adapter":"openapi",
                 "args":"json","request":{"method":"GET","url_template":"https://example.test/pets"}}}"#,
        )
        .unwrap();
        assert_eq!(rec.address, "petstore.org.main.listPets");
        assert_eq!(rec.integration, "petstore");
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
    fn rejects_connection_ref_in_shards() {
        let err = hydrate_record(
            &entry("petstore.org.main.listPets", "List pets"),
            r#"{"binding":{"type":"service","service":"adapters","op":"invoke","adapter":"openapi",
                 "request":{"connection_ref":{"auth":"none"}}}}"#,
        )
        .unwrap_err();
        assert_eq!(err, ToolError::InvalidShard);
    }

    #[test]
    fn resolves_alias_from_index_tail() {
        let index = CatalogIndex::parse(&alloc::format!(
            r#"{{"generation":0,"tools":[
              {{"address":"host.org.main.greet","integration":"host","description":"Greet","sha":"{SHA}"}}
            ]}}"#
        ))
        .unwrap();
        assert_eq!(
            index.find_alias("greet").unwrap().address,
            "host.org.main.greet"
        );
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
    fn rejects_bad_addresses() {
        for bad in [
            "x.main.greet",
            "x.team.main.greet",
            "x.org.main.",
            "x.org.main.greet/now",
        ] {
            let src = alloc::format!(
                r#"{{"generation":0,"tools":[{{"address":"{bad}","integration":"x","sha":"{SHA}"}}]}}"#
            );
            assert!(CatalogIndex::parse(&src).is_err(), "{bad}");
        }
    }

    #[test]
    fn rejects_unsafe_binding_names() {
        for bad in ["", "/mnt/search", " greet", "greet "] {
            let shard = alloc::format!(r#"{{"binding":{{"type":"host_call","name":"{bad}"}}}}"#);
            assert_eq!(
                hydrate_record(&entry("host.org.main.greet", "Greet"), &shard).unwrap_err(),
                ToolError::InvalidBindingName,
                "{bad:?}"
            );
        }

        for bad in ["bad\nname", "bad\0name"] {
            let shard = alloc::format!(r#"{{"binding":{{"type":"host_call","name":"{bad}"}}}}"#);
            assert_eq!(
                hydrate_record(&entry("host.org.main.greet", "Greet"), &shard).unwrap_err(),
                ToolError::InvalidBindingName
            );
        }
    }

    #[test]
    fn catalog_apply_cas_is_idempotency_first() {
        let (a, b) = ("a".repeat(64), "b".repeat(64));
        // Idempotent: the incoming catalog already equals the live one — a no-op regardless of base.
        assert_eq!(catalog_apply_decision(&a, &a, None), CatalogApplyDecision::NoOp);
        assert_eq!(catalog_apply_decision(&a, &a, Some(&a)), CatalogApplyDecision::NoOp);
        // The C1 regression: a retry after a lost response still carries the OLD base, but the live
        // catalog is already the result — this must be a no-op, NOT a conflict.
        assert_eq!(catalog_apply_decision(&a, &a, Some(&b)), CatalogApplyDecision::NoOp);
        // A genuinely new result with no base, or a base that matches live, applies.
        assert_eq!(catalog_apply_decision(&b, &a, None), CatalogApplyDecision::Apply);
        assert_eq!(catalog_apply_decision(&b, &a, Some(&a)), CatalogApplyDecision::Apply);
        // A genuinely new result against a stale base is a lost-update conflict.
        assert_eq!(catalog_apply_decision(&b, &a, Some(&b)), CatalogApplyDecision::Conflict);
    }

    #[test]
    fn rejects_unsafe_service_bindings() {
        let err = hydrate_record(
            &entry("petstore.org.main.listPets", "List pets"),
            r#"{"binding":{"type":"service","service":"/adapters","op":"invoke","adapter":"openapi",
                 "request":{}}}"#,
        )
        .unwrap_err();
        assert_eq!(err, ToolError::InvalidBindingName);
    }

    #[test]
    fn rejects_duplicate_addresses() {
        let err = CatalogIndex::parse(&alloc::format!(
            r#"{{"generation":0,"tools":[
              {{"address":"host.org.main.greet","integration":"host","sha":"{SHA}"}},
              {{"address":"host.org.main.greet","integration":"host","sha":"{SHA}"}}
            ]}}"#
        ))
        .unwrap_err();
        assert_eq!(err, ToolError::DuplicateAddress);
    }

    #[test]
    fn accepts_spaced_binding_names_for_kits() {
        let rec = hydrate_record(
            &entry("host.org.main.weather.get", "Weather"),
            r#"{"binding":{"type":"host_call","name":"weather get","args":"json"}}"#,
        )
        .unwrap();
        match rec.binding {
            Binding::HostCall { name, .. } => assert_eq!(name, "weather get"),
            _ => panic!("expected host call"),
        }
    }
}
