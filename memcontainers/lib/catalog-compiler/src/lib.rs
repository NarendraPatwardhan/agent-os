//! Host-side catalog compiler C ABI.
//!
//! This is not a guest program: hosts instantiate the built wasm directly with wasmtime/V8 and call
//! these exports as pure compute. The output bundle is already sharded so the host can copy entries to
//! disk without understanding catalog JSON.

use std::collections::BTreeMap;
use std::slice;
use std::str;

use mc_parse::bundle::{bundle_entries, error_bundle, frame_entries, BundleError};
use mc_parse::openapi::{self, OperationFilter, SourceFormat};
use mc_parse::{google, graphql, mcp, microsoft, registry};
use serde::{Deserialize, Serialize};
use serde_json::json;

pub const BUNDLE_SCHEMA_VERSION: u32 = 1;
const PLACEHOLDER_OWNER: &str = "org";
const PLACEHOLDER_CONNECTION: &str = "main";

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CompileRequest {
    pub format: String,
    #[serde(default)]
    pub source_format: Option<String>,
    pub integration: String,
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub filter: FilterRequest,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub endpoint: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct FilterRequest {
    #[serde(default)]
    pub exact_paths: Vec<String>,
    #[serde(default)]
    pub path_prefixes: Vec<String>,
    #[serde(default)]
    pub tag_prefixes: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct RegistryEntryOut {
    id: &'static str,
    name: &'static str,
    kind: registry::RegistryKind,
    url: Option<&'static str>,
    endpoint: Option<&'static str>,
    #[serde(rename = "defaultGroups")]
    default_groups: Vec<&'static str>,
    groups: BTreeMap<&'static str, RegistryGroupOut>,
    /// Curated egress origins; the host derives a connection's allowlist from these when `origins` is
    /// omitted (so the user names only the capability + key).
    servers: Vec<&'static str>,
}

#[derive(Debug, Clone, Serialize)]
struct RegistryGroupOut {
    filter: FilterOut,
}

#[derive(Debug, Clone, Serialize)]
struct FilterOut {
    exact_paths: Vec<&'static str>,
    path_prefixes: Vec<&'static str>,
    tag_prefixes: Vec<&'static str>,
}

pub fn registry_list_json() -> Vec<u8> {
    let entries: Vec<_> = registry::entries().iter().map(registry_entry_out).collect();
    serde_json::to_vec(&entries).expect("registry entries serialize")
}

pub fn registry_resolve_json(id: &str) -> Vec<u8> {
    match registry::find(id) {
        Some(entry) => {
            serde_json::to_vec(&registry_entry_out(entry)).expect("registry entry serializes")
        }
        None => serde_json::to_vec(&json!({
            "error": {
                "code": "not_found",
                "message": format!("no registry entry `{id}`")
            }
        }))
        .expect("registry error serializes"),
    }
}

pub fn compile_bundle(source: &[u8], opts: &[u8]) -> Vec<u8> {
    match compile_bundle_result(source, opts) {
        Ok(bundle) => bundle,
        Err((code, message)) => error_bundle(code, message),
    }
}

fn registry_entry_out(entry: &'static registry::RegistryEntry) -> RegistryEntryOut {
    let mut groups = BTreeMap::new();
    let has_filter = !(entry.exact_paths.is_empty()
        && entry.path_prefixes.is_empty()
        && entry.tag_prefixes.is_empty());
    if has_filter {
        groups.insert(
            entry.id,
            RegistryGroupOut {
                filter: FilterOut {
                    exact_paths: entry.exact_paths.to_vec(),
                    path_prefixes: entry.path_prefixes.to_vec(),
                    tag_prefixes: entry.tag_prefixes.to_vec(),
                },
            },
        );
    }
    RegistryEntryOut {
        id: entry.id,
        name: entry.name,
        kind: entry.kind,
        url: entry.url,
        endpoint: entry.endpoint,
        default_groups: if has_filter {
            vec![entry.id]
        } else {
            Vec::new()
        },
        groups,
        servers: entry.servers.to_vec(),
    }
}

fn compile_bundle_result(source: &[u8], opts: &[u8]) -> Result<Vec<u8>, (&'static str, String)> {
    let source = str::from_utf8(source)
        .map_err(|e| ("bad_source", format!("source bytes are not UTF-8: {e}")))?;
    let req: CompileRequest = serde_json::from_slice(opts).map_err(|e| {
        (
            "bad_options",
            format!("compile options are not valid JSON: {e}"),
        )
    })?;
    if req.integration.trim().is_empty() {
        return Err(("bad_options", "integration is required".to_string()));
    }

    let out = compile_records(source, &req)?;
    let entries =
        bundle_entries(&req.integration, 0, out.tools, out.diagnostics).map_err(bundle_error)?;
    validate_bundle_entries(&entries)?;
    Ok(frame_entries(entries))
}

fn compile_records(
    source: &str,
    req: &CompileRequest,
) -> Result<openapi::CompileOutput, (&'static str, String)> {
    let source_format = parse_source_format(req.source_format.as_deref())?;
    let openapi_opts = openapi_options(req);
    match req.format.as_str() {
        "openapi" => Ok(openapi::compile(source, source_format, &openapi_opts)),
        "microsoft-graph" | "msgraph" => Ok(microsoft::compile(
            source,
            source_format,
            &openapi_opts,
            &microsoft::CompileOptions {
                preset_ids: req.group.iter().cloned().collect(),
                filter: req.filter.clone().into(),
            },
        )),
        "google-discovery" => Ok(google::compile(
            source,
            source_format,
            &openapi_opts,
            &google::CompileOptions::default(),
        )),
        "graphql" => {
            let endpoint = endpoint(req, "GraphQL")?;
            let out = graphql::compile(
                source,
                &graphql::CompileOptions {
                    integration: req.integration.clone(),
                    owner: PLACEHOLDER_OWNER.to_string(),
                    connection: PLACEHOLDER_CONNECTION.to_string(),
                    auth: "none".to_string(),
                    endpoint,
                    filter: req.filter.clone().into(),
                },
            );
            Ok(openapi::CompileOutput {
                tools: out.tools,
                diagnostics: out.diagnostics,
            })
        }
        "mcp-remote" | "mcp" => {
            let endpoint = endpoint(req, "remote MCP")?;
            let out = mcp::compile(
                source,
                &mcp::CompileOptions {
                    integration: req.integration.clone(),
                    owner: PLACEHOLDER_OWNER.to_string(),
                    connection: PLACEHOLDER_CONNECTION.to_string(),
                    auth: "none".to_string(),
                    endpoint,
                    filter: req.filter.clone().into(),
                },
            );
            Ok(openapi::CompileOutput {
                tools: out.tools,
                diagnostics: out.diagnostics,
            })
        }
        other => Err((
            "unsupported_format",
            format!("unsupported adapter format `{other}`"),
        )),
    }
}

fn openapi_options(req: &CompileRequest) -> openapi::CompileOptions {
    openapi::CompileOptions {
        integration: req.integration.clone(),
        owner: PLACEHOLDER_OWNER.to_string(),
        connection: PLACEHOLDER_CONNECTION.to_string(),
        auth: "none".to_string(),
        base_url: req.base_url.clone(),
        filter: req.filter.clone().into(),
    }
}

fn parse_source_format(value: Option<&str>) -> Result<SourceFormat, (&'static str, String)> {
    match value.unwrap_or("json") {
        "json" => Ok(SourceFormat::Json),
        "yaml" | "yml" => Ok(SourceFormat::Yaml),
        other => Err((
            "bad_options",
            format!("unsupported source_format `{other}`"),
        )),
    }
}

fn endpoint(req: &CompileRequest, label: &str) -> Result<String, (&'static str, String)> {
    req.endpoint
        .clone()
        .or_else(|| req.base_url.clone())
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| {
            (
                "bad_options",
                format!("{label} compile requires endpoint or base_url"),
            )
        })
}

impl From<FilterRequest> for OperationFilter {
    fn from(value: FilterRequest) -> Self {
        OperationFilter {
            exact_paths: value.exact_paths,
            path_prefixes: value.path_prefixes,
            tag_prefixes: value.tag_prefixes,
        }
    }
}

fn bundle_error(err: BundleError) -> (&'static str, String) {
    (err.code(), err.message())
}

fn validate_bundle_entries(
    entries: &BTreeMap<String, Vec<u8>>,
) -> Result<(), (&'static str, String)> {
    let index = entries
        .get("index.json")
        .ok_or_else(|| ("invalid_catalog", "bundle missing index.json".to_string()))?;
    let index = str::from_utf8(index)
        .map_err(|e| ("invalid_catalog", format!("index.json was not UTF-8: {e}")))?;
    let index = toolcore::CatalogIndex::parse(index)
        .map_err(|e| ("invalid_catalog", format!("toolcore rejected index: {e:?}")))?;
    for entry in index.entries() {
        let path = format!("records/{}", entry.sha);
        let shard = entries
            .get(&path)
            .ok_or_else(|| ("invalid_catalog", format!("bundle missing {path}")))?;
        let shard = str::from_utf8(shard)
            .map_err(|e| ("invalid_catalog", format!("{path} was not UTF-8: {e}")))?;
        toolcore::hydrate_record(entry, shard).map_err(|e| {
            (
                "invalid_catalog",
                format!("toolcore rejected {path}: {e:?}"),
            )
        })?;
    }
    Ok(())
}

#[no_mangle]
pub extern "C" fn cc_alloc(len: usize) -> *mut u8 {
    if len == 0 {
        return std::ptr::null_mut();
    }
    // Allocate EXACTLY `len` bytes (a boxed slice, like `alloc_return`) so the matching
    // `cc_free(ptr, len)` reconstructs an identical layout. `Vec::with_capacity` may round the
    // capacity up past `len`; freeing that as `len` would hand the allocator a layout it never
    // allocated — undefined behaviour.
    let boxed: Box<[u8]> = vec![0u8; len].into_boxed_slice();
    Box::into_raw(boxed) as *mut u8
}

#[no_mangle]
pub unsafe extern "C" fn cc_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len != 0 {
        drop(Vec::from_raw_parts(ptr, len, len));
    }
}

#[no_mangle]
pub extern "C" fn cc_registry_list() -> u64 {
    alloc_return(registry_list_json())
}

#[no_mangle]
pub unsafe extern "C" fn cc_registry_resolve(id_ptr: *const u8, id_len: usize) -> u64 {
    let id = str::from_utf8(read(id_ptr, id_len)).unwrap_or("");
    alloc_return(registry_resolve_json(id))
}

#[no_mangle]
pub unsafe extern "C" fn cc_compile(
    src_ptr: *const u8,
    src_len: usize,
    opts_ptr: *const u8,
    opts_len: usize,
) -> u64 {
    alloc_return(compile_bundle(
        read(src_ptr, src_len),
        read(opts_ptr, opts_len),
    ))
}

#[no_mangle]
pub extern "C" fn cc_bundle_schema_version() -> u32 {
    BUNDLE_SCHEMA_VERSION
}

// ── Single-source decision exports (toolcore is the one implementation; the JS host calls these, the
//    wasmtime host calls toolcore natively, so the two cannot drift) ───────────────────────────────

/// Validate a fully-qualified tool address (`integration.owner.tool…`) via `toolcore::parse_address` —
/// the same check the host catalog builder uses, so the JS `toolCatalogBundle` cannot accept an address
/// the Rust host would reject.
#[no_mangle]
pub unsafe extern "C" fn cc_validate_address(ptr: *const u8, len: usize) -> u64 {
    let addr = str::from_utf8(read(ptr, len)).unwrap_or("");
    alloc_return(match toolcore::parse_address(addr) {
        Ok(_) => serde_json::to_vec(&json!({ "ok": true })).expect("ok serializes"),
        Err(_) => serde_json::to_vec(&json!({
            "error": { "code": "invalid_address", "message": format!("invalid tool address `{addr}`") }
        }))
        .expect("address error serializes"),
    })
}

/// Validate a tool-policy rule set (owner/action enums + connection-granular patterns) — the construction
/// check both hosts enforce.
#[no_mangle]
pub unsafe extern "C" fn cc_validate_policy(ptr: *const u8, len: usize) -> u64 {
    alloc_return(match parse_policy_rules(read(ptr, len)) {
        Ok(rules) => match toolcore::policy::ToolPolicySet::new(rules) {
            Ok(_) => serde_json::to_vec(&json!({ "ok": true })).expect("ok serializes"),
            Err(err) => policy_error_json(err),
        },
        Err(message) => serde_json::to_vec(&json!({
            "error": { "code": "bad_request", "message": message }
        }))
        .expect("policy parse error serializes"),
    })
}

/// Resolve a policy rule set against a connection address → the action (`approve`/`require_approval`/
/// `block`) or null. Rules are validated at construction (`cc_validate_policy`); a malformed set here
/// resolves to null (fail-open is impossible — the splice still classifies destructiveness).
#[no_mangle]
pub unsafe extern "C" fn cc_policy_resolve(
    rules_ptr: *const u8,
    rules_len: usize,
    addr_ptr: *const u8,
    addr_len: usize,
) -> u64 {
    let address = str::from_utf8(read(addr_ptr, addr_len)).unwrap_or("");
    let action = match parse_policy_rules(read(rules_ptr, rules_len)) {
        Ok(rules) => toolcore::policy::ToolPolicySet::new(rules)
            .ok()
            .and_then(|set| set.resolve(address)),
        Err(_) => None,
    };
    alloc_return(
        serde_json::to_vec(&json!({ "action": policy_action_name(action) }))
            .expect("policy action serializes"),
    )
}

/// How a host acquires a connection's source document, by registry kind — the request bodies are built
/// here so the *logic* is single-source; the host is pure transport (it adds `content-type`, the
/// credential, the MCP session header, and sends the requests through the egress path).
///
/// - `openapi`/`google`: `{"protocol":"static"}` — GET the registry URL (a static spec doc).
/// - `graphql`: `{"protocol":"graphql","url","body"}` — one authenticated introspection POST; the
///   response is the introspection result (`compile` reads `data.__schema`).
/// - `mcp-remote`: `{"protocol":"mcp","url","initialize","initialized","list"}` — the streamable-HTTP
///   handshake: POST `initialize` (capture the `Mcp-Session-Id` response header), POST the
///   `notifications/initialized` notification, then POST `tools/list` (the response is the source;
///   `compile` reads `result.tools`). The host threads the session header through the later POSTs.
#[no_mangle]
pub unsafe extern "C" fn cc_discovery_request(
    kind_ptr: *const u8,
    kind_len: usize,
    endpoint_ptr: *const u8,
    endpoint_len: usize,
) -> u64 {
    let kind = str::from_utf8(read(kind_ptr, kind_len)).unwrap_or("");
    let endpoint = str::from_utf8(read(endpoint_ptr, endpoint_len)).unwrap_or("");
    let to_str = |v: serde_json::Value| serde_json::to_string(&v).expect("discovery body serializes");
    let out = match kind {
        "graphql" => json!({
            "protocol": "graphql",
            "url": endpoint,
            "body": to_str(json!({ "query": mc_parse::graphql::INTROSPECTION_QUERY })),
        }),
        "mcp-remote" => json!({
            "protocol": "mcp",
            "url": endpoint,
            "initialize": to_str(json!({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": { "name": "agent-os", "version": "0" }
                }
            })),
            "initialized": to_str(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })),
            "list": to_str(json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} })),
        }),
        _ => json!({ "protocol": "static" }),
    };
    alloc_return(serde_json::to_vec(&out).expect("discovery request serializes"))
}

fn parse_policy_rules(bytes: &[u8]) -> Result<Vec<toolcore::policy::ToolPolicyRule>, String> {
    use toolcore::policy::{ToolPolicyAction, ToolPolicyOwner, ToolPolicyRule};
    let value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid policy rules JSON: {e}"))?;
    let array = value
        .as_array()
        .ok_or_else(|| "policy rules must be a JSON array".to_string())?;
    let mut out = Vec::with_capacity(array.len());
    for rule in array {
        let owner = match rule.get("owner").and_then(|v| v.as_str()) {
            Some("org") => ToolPolicyOwner::Org,
            Some("user") => ToolPolicyOwner::User,
            other => return Err(format!("invalid tool policy owner {other:?}")),
        };
        let action = match rule.get("action").and_then(|v| v.as_str()) {
            Some("approve") => ToolPolicyAction::Approve,
            Some("require_approval") => ToolPolicyAction::RequireApproval,
            Some("block") => ToolPolicyAction::Block,
            other => return Err(format!("invalid tool policy action {other:?}")),
        };
        let pattern = rule
            .get("pattern")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "tool policy rule is missing `pattern`".to_string())?
            .to_string();
        out.push(ToolPolicyRule {
            owner,
            pattern,
            action,
        });
    }
    Ok(out)
}

fn policy_action_name(action: Option<toolcore::policy::ToolPolicyAction>) -> Option<&'static str> {
    use toolcore::policy::ToolPolicyAction;
    action.map(|a| match a {
        ToolPolicyAction::Approve => "approve",
        ToolPolicyAction::RequireApproval => "require_approval",
        ToolPolicyAction::Block => "block",
    })
}

fn policy_error_json(err: toolcore::policy::ToolPolicyError) -> Vec<u8> {
    use toolcore::policy::ToolPolicyError;
    let (code, message) = match err {
        ToolPolicyError::InvalidOwner => ("invalid_owner", "tool policy rule has an invalid owner"),
        ToolPolicyError::InvalidPattern => (
            "invalid_pattern",
            "tool policy pattern must be connection-granular (`*`, or a trailing-wildcard with at most three concrete segments)",
        ),
        ToolPolicyError::InvalidAction => {
            ("invalid_action", "tool policy rule has an invalid action")
        }
    };
    serde_json::to_vec(&json!({ "error": { "code": code, "message": message } }))
        .expect("policy error serializes")
}

fn alloc_return(bytes: Vec<u8>) -> u64 {
    let len = bytes.len() as u32;
    let boxed = bytes.into_boxed_slice();
    let ptr = Box::into_raw(boxed) as *mut u8 as u32;
    ((len as u64) << 32) | ptr as u64
}

unsafe fn read<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 {
        &[]
    } else {
        slice::from_raw_parts(ptr, len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn decode_bundle(bytes: &[u8]) -> BTreeMap<String, Vec<u8>> {
        let mut pos = 0usize;
        let count = read_u32(bytes, &mut pos) as usize;
        let mut entries = BTreeMap::new();
        for _ in 0..count {
            let path_len = read_u32(bytes, &mut pos) as usize;
            let byte_len = read_u32(bytes, &mut pos) as usize;
            let path = str::from_utf8(&bytes[pos..pos + path_len])
                .unwrap()
                .to_string();
            pos += path_len;
            let body = bytes[pos..pos + byte_len].to_vec();
            pos += byte_len;
            entries.insert(path, body);
        }
        assert_eq!(pos, bytes.len());
        entries
    }

    fn read_u32(bytes: &[u8], pos: &mut usize) -> u32 {
        let mut buf = [0u8; 4];
        buf.copy_from_slice(&bytes[*pos..*pos + 4]);
        *pos += 4;
        u32::from_le_bytes(buf)
    }

    #[test]
    fn sharded_bundle_has_index_and_connection_free_records() {
        let source = br#"{
          "openapi": "3.0.3",
          "info": { "title": "GitHub", "version": "1" },
          "servers": [{ "url": "https://api.github.com" }],
          "paths": {
            "/repos/{owner}/{repo}/issues": {
              "post": {
                "operationId": "issues/create",
                "summary": "Create an issue",
                "tags": ["issues"],
                "requestBody": {
                  "required": true,
                  "content": {
                    "application/json": {
                      "schema": {
                        "type": "object",
                        "required": ["title"],
                        "properties": { "title": { "type": "string" } }
                      }
                    }
                  }
                },
                "responses": { "201": { "description": "created" } }
              }
            },
            "/repos/{owner}/{repo}/pulls": {
              "get": {
                "operationId": "pulls/list",
                "tags": ["pulls"],
                "responses": { "200": { "description": "ok" } }
              }
            }
          }
        }"#;
        let opts = br#"{
          "format": "openapi",
          "source_format": "json",
          "integration": "github",
          "group": "issues",
          "filter": { "tag_prefixes": ["issues"] }
        }"#;
        let bundle = compile_bundle(source, opts);
        let entries = decode_bundle(&bundle);
        let index: Value = serde_json::from_slice(entries.get("index.json").unwrap()).unwrap();
        assert_eq!(index["generation"], 0);
        assert_eq!(index["tools"].as_array().unwrap().len(), 1);
        assert_eq!(
            index["tools"][0]["address"],
            "github.org.main.issues-create"
        );
        let sha = index["tools"][0]["sha"].as_str().unwrap();
        let record = entries.get(&format!("records/{sha}")).unwrap();
        let record_text = str::from_utf8(record).unwrap();
        assert!(record_text
            .contains("\"url_template\":\"https://api.github.com/repos/{owner}/{repo}/issues\""));
        assert!(!record_text.contains("connection_ref"));
        assert!(!record_text.contains("\"address\""));
    }

    #[test]
    fn golden_bundles_are_byte_stable() {
        struct Golden {
            name: &'static str,
            source: &'static [u8],
            opts: &'static [u8],
            sha256: &'static str,
            tool_count: usize,
        }

        let goldens = [
            Golden {
                name: "github/issues",
                source: include_bytes!("../data/github_issues.openapi.json"),
                opts: include_bytes!("../data/github_issues.opts.json"),
                sha256: "5a6af4c0aa0de721d7038d04613f69ff86e7934334465661570b40c1407ebb86",
                tool_count: 2,
            },
            Golden {
                name: "google-discovery",
                source: include_bytes!("../data/google.discovery.json"),
                opts: include_bytes!("../data/google.opts.json"),
                sha256: "3a05e7f4f0dab9a419adb84e742181ec0806ed96c134797dba9959b9ba07187b",
                tool_count: 1,
            },
            Golden {
                name: "microsoft-graph",
                source: include_bytes!("../data/microsoft.openapi.json"),
                opts: include_bytes!("../data/microsoft.opts.json"),
                sha256: "3f18e5e5509a74b40a925b57a72cd9588e2694cb6cd9cee39158cb6ffc5c7dce",
                tool_count: 1,
            },
            Golden {
                name: "graphql",
                source: include_bytes!("../data/graphql.introspection.json"),
                opts: include_bytes!("../data/graphql.opts.json"),
                sha256: "53e6e8343966734e7bdb47e822a3eac7f2c02131708156116cabcdb6c6e2f286",
                tool_count: 2,
            },
            Golden {
                name: "mcp-remote",
                source: include_bytes!("../data/mcp.tools.json"),
                opts: include_bytes!("../data/mcp.opts.json"),
                sha256: "fb1de7e0abec0d673625e079fb4b5399cda1f725399e1cf29d3d0f4ebf384b98",
                tool_count: 2,
            },
        ];

        let mut updates = Vec::new();
        for golden in goldens {
            let bundle = compile_bundle(golden.source, golden.opts);
            let got = pkgcore::sha256_hex(&bundle);
            let entries = decode_bundle(&bundle);
            assert!(entries.contains_key("index.json"), "{}", golden.name);
            let index: Value = serde_json::from_slice(entries.get("index.json").unwrap()).unwrap();
            assert_eq!(
                index["tools"].as_array().unwrap().len(),
                golden.tool_count,
                "{}",
                golden.name
            );
            assert!(
                !bundle
                    .windows("connection_ref".len())
                    .any(|w| w == b"connection_ref"),
                "{} leaked connection_ref",
                golden.name
            );
            if golden.sha256 == "UPDATE" || golden.sha256 != got {
                updates.push(format!("{} {}", golden.name, got));
            }
        }
        assert!(
            updates.is_empty(),
            "golden bundle hashes:\n{}",
            updates.join("\n")
        );
    }
}
