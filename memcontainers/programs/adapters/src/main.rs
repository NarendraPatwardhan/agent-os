//! `adapters` — the mcbox-style resident service for tool adapter formats.
//!
//! The service has one public identity, `/svc/adapters`, and many internal compilers. OpenAPI is the
//! first implementation; GraphQL, Microsoft Graph, and Google discovery should extend the same protocol
//! so serde/YAML/schema costs are paid once per VM. The binary intentionally has no supported CLI face.

use mc_parse::openapi::{self, CompileOptions, SourceFormat};
use mc_parse::{google, graphql, mcp, microsoft, registry};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, VecDeque};
use sysroot as rt;

const SERVICE_NAME: &str = "adapters";
const CONNECTION_HEADER: &str = "X-MC-Connection";
const CAP_NET: u32 = rt::CAP_NET as u32;
const CAP_MOUNT: u32 = rt::CAP_MOUNT as u32;
const CONTROL_CALLER: u32 = 0;
const MAX_REQ: usize = 1024 * 1024 + 64 * 1024;
const CHUNK: usize = 32 * 1024;

#[derive(Debug, Deserialize)]
struct Request {
    op: String,
    #[serde(default)]
    format: Option<String>,
    #[serde(default)]
    source_format: Option<String>,
    #[serde(default)]
    source: Option<String>,
    #[serde(default)]
    source_path: Option<String>,
    #[serde(default)]
    output_path: Option<String>,
    #[serde(default)]
    integration: Option<String>,
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    connection: Option<String>,
    #[serde(default)]
    auth: Option<String>,
    #[serde(default)]
    preset_ids: Option<Vec<String>>,
    #[serde(default)]
    base_url: Option<String>,
    #[serde(default)]
    endpoint: Option<String>,
    #[serde(default)]
    adapter: Option<String>,
    #[serde(default)]
    binding: Option<Value>,
    #[serde(default)]
    args: Option<Value>,
    #[serde(default)]
    id: Option<String>,
}

enum Response {
    Bytes(Vec<u8>),
    Fd(i32),
}

struct OutStream {
    source: StreamSource,
    pending: VecDeque<(Vec<u8>, bool)>,
}

enum StreamSource {
    Bytes { data: Vec<u8>, offset: usize },
    Fd(i32),
    Done,
}

enum Pump {
    Done,
    Parked,
    Failed,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some(rt::SERVICE_MARKER) {
        serve();
    }
    eprintln!("adapters: resident service only");
    std::process::exit(64);
}

fn serve() -> ! {
    let server = match rt::svc_serve(SERVICE_NAME) {
        Ok(fd) => fd,
        Err(_) => std::process::exit(1),
    };
    let mut buf = vec![0u8; MAX_REQ];
    let mut hbuf = [0i32; 0];
    let mut parked: BTreeMap<(u32, u32), OutStream> = BTreeMap::new();

    loop {
        let n = match rt::svc_recv(server, &mut buf, &mut hbuf) {
            Ok(n) => n,
            Err(_) => std::process::exit(0),
        };
        let Some(req) = rt::parse_svc_request(&buf[..n], &hbuf) else {
            continue;
        };
        match req.kind {
            rt::SvcKind::Call => {
                let key = (req.session, req.req_id);
                let response = handle_call(req.blob, req.caller, req.caller_caps);
                let mut stream = stream_for(response);
                match pump(server, key, &mut stream) {
                    Pump::Parked => {
                        parked.insert(key, stream);
                    }
                    Pump::Done | Pump::Failed => {}
                }
            }
            rt::SvcKind::DrainReady => {
                let key = (req.session, req.req_id);
                if let Some(mut stream) = parked.remove(&key) {
                    if let Pump::Parked = pump(server, key, &mut stream) {
                        parked.insert(key, stream);
                    }
                }
            }
            rt::SvcKind::SessionClosed => {
                parked.retain(|&(session, _), stream| {
                    if session == req.session {
                        stream.close();
                        false
                    } else {
                        true
                    }
                });
            }
        }
    }
}

fn handle_call(blob: &[u8], caller: u32, caller_caps: u32) -> Response {
    let req: Request = match serde_json::from_slice(blob) {
        Ok(req) => req,
        Err(_) => return json_response(error("bad_json", "request must be a JSON object")),
    };
    match req.op.as_str() {
        "registry.list" => registry_list(),
        "registry.get" => registry_get(req),
        "compile" => compile(req, caller, caller_caps),
        "invoke" => {
            if !can_call_network(caller, caller_caps) {
                return json_response(error(
                    "permission_denied",
                    "adapter invocation requires CAP_NET",
                ));
            }
            invoke(req)
        }
        _ => json_response(error("bad_request", "unknown adapters operation")),
    }
}

fn registry_list() -> Response {
    match serde_json::to_value(registry::entries()) {
        Ok(items) => json_response(ok(json!({
            "items": items,
        }))),
        Err(_) => json_response(error("internal_error", "could not encode registry")),
    }
}

fn registry_get(req: Request) -> Response {
    let Some(id) = req.id.as_deref() else {
        return json_response(error("bad_request", "registry.get requires id"));
    };
    match registry::find(id) {
        Some(entry) => match serde_json::to_value(entry) {
            Ok(value) => json_response(ok(value)),
            Err(_) => json_response(error("internal_error", "could not encode registry entry")),
        },
        None => json_response(error("not_found", "no registry entry with that id")),
    }
}

fn compile(req: Request, caller: u32, caller_caps: u32) -> Response {
    match req.format.as_deref() {
        Some("openapi") => compile_openapi(req, caller, caller_caps),
        Some("microsoft-graph") | Some("msgraph") => {
            compile_microsoft_graph(req, caller, caller_caps)
        }
        Some("google-discovery") => compile_google_discovery(req, caller, caller_caps),
        Some("graphql") => compile_graphql(req, caller, caller_caps),
        Some("mcp-remote") | Some("mcp") => compile_mcp_remote(req, caller, caller_caps),
        Some(_) => json_response(error("unsupported_format", "unsupported adapter format")),
        None => json_response(error("bad_request", "compile requires format")),
    }
}

fn compile_openapi(req: Request, caller: u32, caller_caps: u32) -> Response {
    let output_path = req.output_path.clone();
    let source = match read_source(&req) {
        Ok(source) => source,
        Err(message) => return json_response(error("bad_source", message)),
    };
    let source_format = match req.source_format.as_deref().unwrap_or("json") {
        "json" => SourceFormat::Json,
        "yaml" | "yml" => SourceFormat::Yaml,
        _ => return json_response(error("bad_request", "source_format must be json or yaml")),
    };
    let opts = CompileOptions {
        integration: req.integration.unwrap_or_else(|| "openapi".to_string()),
        owner: req.owner.unwrap_or_else(|| "org".to_string()),
        connection: req.connection.unwrap_or_else(|| "main".to_string()),
        auth: req.auth.unwrap_or_else(|| "none".to_string()),
        base_url: req.base_url,
    };
    let out = openapi::compile(&source, source_format, &opts);
    compile_response(
        output_path.as_deref(),
        out.tools,
        out.diagnostics,
        caller,
        caller_caps,
    )
}

fn compile_microsoft_graph(req: Request, caller: u32, caller_caps: u32) -> Response {
    let output_path = req.output_path.clone();
    let source = match read_source(&req) {
        Ok(source) => source,
        Err(message) => return json_response(error("bad_source", message)),
    };
    let source_format = match source_format(&req) {
        Ok(format) => format,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let preset_ids = requested_preset_ids(&req);
    let opts = CompileOptions {
        integration: req.integration.unwrap_or_else(|| "microsoft".to_string()),
        owner: req.owner.unwrap_or_else(|| "org".to_string()),
        connection: req.connection.unwrap_or_else(|| "main".to_string()),
        auth: req.auth.unwrap_or_else(|| "bearer".to_string()),
        base_url: req.base_url,
    };
    let out = microsoft::compile(
        &source,
        source_format,
        &opts,
        &microsoft::CompileOptions { preset_ids },
    );
    compile_response(
        output_path.as_deref(),
        out.tools,
        out.diagnostics,
        caller,
        caller_caps,
    )
}

fn compile_google_discovery(req: Request, caller: u32, caller_caps: u32) -> Response {
    let output_path = req.output_path.clone();
    let source = match read_source(&req) {
        Ok(source) => source,
        Err(message) => return json_response(error("bad_source", message)),
    };
    let source_format = match source_format(&req) {
        Ok(format) => format,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let integration = req
        .integration
        .or(req.id)
        .unwrap_or_else(|| "google".to_string());
    let opts = CompileOptions {
        integration,
        owner: req.owner.unwrap_or_else(|| "org".to_string()),
        connection: req.connection.unwrap_or_else(|| "main".to_string()),
        auth: req.auth.unwrap_or_else(|| "bearer".to_string()),
        base_url: req.base_url,
    };
    let out = google::compile(
        &source,
        source_format,
        &opts,
        &google::CompileOptions::default(),
    );
    compile_response(
        output_path.as_deref(),
        out.tools,
        out.diagnostics,
        caller,
        caller_caps,
    )
}

fn compile_graphql(req: Request, caller: u32, caller_caps: u32) -> Response {
    let output_path = req.output_path.clone();
    let endpoint = match adapter_endpoint(&req, "graphql") {
        Ok(endpoint) => endpoint,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let integration = req
        .integration
        .clone()
        .or_else(|| req.id.clone())
        .unwrap_or_else(|| "graphql".to_string());
    let opts = graphql::CompileOptions {
        integration,
        owner: req.owner.clone().unwrap_or_else(|| "org".to_string()),
        connection: req.connection.clone().unwrap_or_else(|| "main".to_string()),
        auth: req.auth.clone().unwrap_or_else(|| "none".to_string()),
        endpoint: endpoint.clone(),
    };
    let source = match read_source(&req) {
        Ok(source) => source,
        Err(_) => {
            if !can_call_network(caller, caller_caps) {
                return json_response(error(
                    "permission_denied",
                    "GraphQL introspection requires CAP_NET",
                ));
            }
            match graphql_introspect(&endpoint, &connection_ref_value(&opts)) {
                Ok(source) => source,
                Err(message) => return json_response(error("discovery_failed", message)),
            }
        }
    };
    let out = graphql::compile(&source, &opts);
    compile_response(
        output_path.as_deref(),
        out.tools,
        out.diagnostics,
        caller,
        caller_caps,
    )
}

fn compile_mcp_remote(req: Request, caller: u32, caller_caps: u32) -> Response {
    let output_path = req.output_path.clone();
    let endpoint = match adapter_endpoint(&req, "remote MCP") {
        Ok(endpoint) => endpoint,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let integration = req
        .integration
        .clone()
        .or_else(|| req.id.clone())
        .unwrap_or_else(|| "mcp".to_string());
    let opts = mcp::CompileOptions {
        integration,
        owner: req.owner.clone().unwrap_or_else(|| "org".to_string()),
        connection: req.connection.clone().unwrap_or_else(|| "main".to_string()),
        auth: req.auth.clone().unwrap_or_else(|| "none".to_string()),
        endpoint: endpoint.clone(),
    };
    let source = match read_source(&req) {
        Ok(source) => source,
        Err(_) => {
            if !can_call_network(caller, caller_caps) {
                return json_response(error(
                    "permission_denied",
                    "remote MCP discovery requires CAP_NET",
                ));
            }
            match mcp_list_tools(&endpoint, &connection_ref_value(&opts)) {
                Ok(source) => source,
                Err(message) => return json_response(error("discovery_failed", message)),
            }
        }
    };
    let out = mcp::compile(&source, &opts);
    compile_response(
        output_path.as_deref(),
        out.tools,
        out.diagnostics,
        caller,
        caller_caps,
    )
}

fn compile_response(
    output_path: Option<&str>,
    tools: Vec<Value>,
    diagnostics: Vec<mc_parse::Diagnostic>,
    caller: u32,
    caller_caps: u32,
) -> Response {
    let tool_count = tools.len();
    let Some(path) = output_path else {
        return json_response(ok(json!({
            "tools": tools,
            "diagnostics": diagnostics,
        })));
    };
    if !can_write_compile_output(caller, caller_caps) {
        return json_response(error(
            "permission_denied",
            "compile output_path requires full filesystem authority",
        ));
    }
    if !valid_output_path(path) {
        return json_response(error(
            "bad_request",
            "output_path must be an absolute guest path",
        ));
    }
    let text = match serde_json::to_string(&json!({ "tools": tools })) {
        Ok(text) => text,
        Err(_) => return json_response(error("internal_error", "could not encode catalog")),
    };
    if let Err(e) = std::fs::write(path, text.as_bytes()) {
        return json_response(error("write_failed", e.to_string()));
    }
    json_response(ok(json!({
        "tool_count": tool_count,
        "tools_path": path,
        "diagnostics": diagnostics,
    })))
}

fn valid_output_path(path: &str) -> bool {
    path.starts_with('/') && !path.as_bytes().contains(&0)
}

fn can_write_compile_output(caller: u32, caller_caps: u32) -> bool {
    caller == CONTROL_CALLER || caller_caps & CAP_MOUNT != 0
}

fn adapter_endpoint(req: &Request, label: &'static str) -> Result<String, String> {
    req.endpoint
        .clone()
        .or_else(|| req.base_url.clone())
        .or_else(|| {
            req.id
                .as_deref()
                .and_then(registry::find)
                .and_then(|entry| entry.endpoint.or(entry.url))
                .map(str::to_string)
        })
        .filter(|endpoint| !endpoint.trim().is_empty())
        .ok_or_else(|| format!("{label} compile requires endpoint"))
}

trait ConnectionOptions {
    fn integration(&self) -> &str;
    fn owner(&self) -> &str;
    fn connection(&self) -> &str;
    fn auth(&self) -> &str;
}

impl ConnectionOptions for graphql::CompileOptions {
    fn integration(&self) -> &str {
        &self.integration
    }
    fn owner(&self) -> &str {
        &self.owner
    }
    fn connection(&self) -> &str {
        &self.connection
    }
    fn auth(&self) -> &str {
        &self.auth
    }
}

impl ConnectionOptions for mcp::CompileOptions {
    fn integration(&self) -> &str {
        &self.integration
    }
    fn owner(&self) -> &str {
        &self.owner
    }
    fn connection(&self) -> &str {
        &self.connection
    }
    fn auth(&self) -> &str {
        &self.auth
    }
}

fn connection_ref_value(opts: &impl ConnectionOptions) -> Value {
    json!({
        "integration": opts.integration(),
        "owner": opts.owner(),
        "name": opts.connection(),
        "auth": opts.auth(),
    })
}

fn source_format(req: &Request) -> Result<SourceFormat, &'static str> {
    match req.source_format.as_deref().unwrap_or("json") {
        "json" => Ok(SourceFormat::Json),
        "yaml" | "yml" => Ok(SourceFormat::Yaml),
        _ => Err("source_format must be json or yaml"),
    }
}

fn requested_preset_ids(req: &Request) -> Vec<String> {
    req.preset_ids
        .clone()
        .unwrap_or_else(|| req.id.iter().cloned().collect())
}

fn read_source(req: &Request) -> Result<String, String> {
    if let Some(source) = &req.source {
        return Ok(source.clone());
    }
    if let Some(path) = &req.source_path {
        return std::fs::read_to_string(path).map_err(|e| e.to_string());
    }
    Err("compile requires source or source_path".to_string())
}

fn graphql_introspect(endpoint: &str, connection_ref: &Value) -> Result<String, String> {
    http_json_post(
        endpoint,
        &json!({ "query": graphql::INTROSPECTION_QUERY }),
        connection_ref,
    )
}

fn mcp_list_tools(endpoint: &str, connection_ref: &Value) -> Result<String, String> {
    let initialize = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {
                "name": "agent-os-adapters",
                "version": "0"
            }
        }
    });
    let _ = http_json_post(endpoint, &initialize, connection_ref)?;
    http_json_post(
        endpoint,
        &json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }),
        connection_ref,
    )
}

fn invoke(req: Request) -> Response {
    match req.adapter.as_deref() {
        Some("openapi") => invoke_openapi(req),
        Some("graphql") => invoke_graphql(req),
        Some("mcp-remote") | Some("mcp") => invoke_mcp_remote(req),
        _ => json_response(error("unsupported_adapter", "unsupported adapter")),
    }
}

fn invoke_openapi(req: Request) -> Response {
    let Some(binding) = req.binding else {
        return json_response(error("bad_request", "invoke requires binding"));
    };
    let args = req.args.unwrap_or_else(|| json!({}));
    let request = match openapi_http_request(&binding, &args) {
        Ok(request) => request,
        Err(message) => return json_response(error("bad_request", message)),
    };
    match rt::http_request(&request) {
        Ok(fd) => Response::Fd(fd),
        Err(e) if e == rt::EPERM => {
            json_response(error("permission_denied", "host request denied"))
        }
        Err(_) => json_response(error("host_call_failed", "host request failed")),
    }
}

fn invoke_graphql(req: Request) -> Response {
    let Some(binding) = req.binding else {
        return json_response(error("bad_request", "invoke requires binding"));
    };
    let endpoint = match str_field(&binding, "endpoint") {
        Ok(endpoint) => endpoint,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let document = match str_field(&binding, "document") {
        Ok(document) => document,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let mut body = Map::new();
    body.insert("query".to_string(), Value::String(document.to_string()));
    if let Some(operation) = binding.get("operationName").and_then(Value::as_str) {
        body.insert(
            "operationName".to_string(),
            Value::String(operation.to_string()),
        );
    }
    body.insert(
        "variables".to_string(),
        req.args.unwrap_or_else(|| json!({})),
    );
    let connection = binding
        .get("connection_ref")
        .cloned()
        .unwrap_or_else(|| json!({"auth":"none"}));
    match http_json_post(endpoint, &Value::Object(body), &connection) {
        Ok(text) => Response::Bytes(text.into_bytes()),
        Err(message) => json_response(error("host_call_failed", message)),
    }
}

fn invoke_mcp_remote(req: Request) -> Response {
    let Some(binding) = req.binding else {
        return json_response(error("bad_request", "invoke requires binding"));
    };
    let endpoint = match str_field(&binding, "endpoint") {
        Ok(endpoint) => endpoint,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let tool_name = match str_field(&binding, "tool_name") {
        Ok(name) => name,
        Err(message) => return json_response(error("bad_request", message)),
    };
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": req.args.unwrap_or_else(|| json!({})),
        }
    });
    let connection = binding
        .get("connection_ref")
        .cloned()
        .unwrap_or_else(|| json!({"auth":"none"}));
    match http_json_post(endpoint, &body, &connection) {
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(resp) => {
                if let Some(error_value) = resp.get("error") {
                    json_response(error("mcp_error", error_value.to_string()))
                } else if let Some(result) = resp.get("result") {
                    json_response(ok(result.clone()))
                } else {
                    json_response(error("mcp_error", "MCP response had no result"))
                }
            }
            Err(_) => json_response(error("mcp_error", "MCP response was not JSON")),
        },
        Err(message) => json_response(error("host_call_failed", message)),
    }
}

fn http_json_post(endpoint: &str, body: &Value, connection_ref: &Value) -> Result<String, String> {
    let body_text = serde_json::to_string(body).map_err(|e| e.to_string())?;
    let mut headers = Map::new();
    headers.insert(
        "Content-Type".to_string(),
        Value::String("application/json".to_string()),
    );
    if let Some(connection) = connection_marker(&json!({ "connection_ref": connection_ref }))? {
        headers.insert(CONNECTION_HEADER.to_string(), Value::String(connection));
    }
    let request = serialize_http_request("POST", endpoint, &headers, Some(&body_text));
    let fd = match rt::http_request(&request) {
        Ok(fd) => fd,
        Err(e) if e == rt::EPERM => return Err("host request denied".to_string()),
        Err(_) => return Err("host request failed".to_string()),
    };
    let status = rt::http_status(fd).unwrap_or(200);
    let out = read_all_fd(fd);
    let _ = rt::close(fd);
    if status >= 400 {
        return Err(format!("host returned HTTP {status}"));
    }
    let bytes = out.map_err(|_| "host response failed".to_string())?;
    String::from_utf8(bytes).map_err(|_| "host response was not UTF-8".to_string())
}

fn read_all_fd(fd: i32) -> Result<Vec<u8>, i32> {
    let mut out = Vec::new();
    let mut buf = [0u8; 8192];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => return Ok(out),
            Ok(n) => out.extend_from_slice(&buf[..n]),
            Err(e) => return Err(e),
        }
    }
}

fn openapi_http_request(binding: &Value, args: &Value) -> Result<Vec<u8>, String> {
    let method = str_field(binding, "method")?.to_string();
    let template = str_field(binding, "url_template")?;
    let params = binding
        .get("parameters")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut url = template.to_string();
    let mut query = Vec::new();
    let mut headers = Map::new();
    for param in params {
        let Some(name) = param.get("name").and_then(Value::as_str) else {
            continue;
        };
        let Some(location) = param.get("in").and_then(Value::as_str) else {
            continue;
        };
        let required = param
            .get("required")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let Some(value) = arg_group_value(args, location, name) else {
            if required {
                return Err(format!("missing required {location} parameter `{name}`"));
            }
            continue;
        };
        let encoded = encode_component(&scalar_string(value));
        match location {
            "path" => {
                url = url.replace(&format!("{{{name}}}"), &encoded);
            }
            "query" => query.push(format!("{}={}", encode_component(name), encoded)),
            "header" => {
                headers.insert(name.to_string(), Value::String(scalar_string(value)));
            }
            "cookie" => {
                headers.insert(
                    "Cookie".to_string(),
                    Value::String(format!("{name}={}", scalar_string(value))),
                );
            }
            _ => {}
        }
    }
    if !query.is_empty() {
        let sep = if url.contains('?') { '&' } else { '?' };
        url.push(sep);
        url.push_str(&query.join("&"));
    }

    let body = args.get("body").filter(|v| !v.is_null()).cloned();
    if body.is_some() {
        headers
            .entry("Content-Type".to_string())
            .or_insert_with(|| Value::String("application/json".to_string()));
    }
    let body_text = match body {
        Some(value) => Some(serde_json::to_string(&value).map_err(|_| "could not encode body")?),
        None => None,
    };

    if let Some(connection) = connection_marker(binding)? {
        headers.insert(CONNECTION_HEADER.to_string(), Value::String(connection));
    }
    Ok(serialize_http_request(
        &method,
        &url,
        &headers,
        body_text.as_deref(),
    ))
}

fn str_field<'a>(value: &'a Value, name: &str) -> Result<&'a str, String> {
    value
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("binding missing `{name}`"))
}

fn arg_group_value<'a>(args: &'a Value, location: &str, name: &str) -> Option<&'a Value> {
    let group = match location {
        "path" => "path",
        "query" => "query",
        "header" => "headers",
        "cookie" => "cookies",
        _ => return None,
    };
    args.get(group)?.get(name)
}

fn scalar_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn connection_marker(binding: &Value) -> Result<Option<String>, String> {
    let Some(connection) = binding.get("connection_ref") else {
        return Ok(None);
    };
    if connection
        .get("auth")
        .and_then(Value::as_str)
        .unwrap_or("none")
        == "none"
    {
        return Ok(None);
    }
    let integration = connection
        .get("integration")
        .and_then(Value::as_str)
        .ok_or("connection_ref missing integration")?;
    let owner = connection
        .get("owner")
        .and_then(Value::as_str)
        .ok_or("connection_ref missing owner")?;
    let name = connection
        .get("name")
        .and_then(Value::as_str)
        .ok_or("connection_ref missing name")?;
    Ok(Some(format!("{integration}.{owner}.{name}")))
}

fn serialize_http_request(
    method: &str,
    url: &str,
    headers: &Map<String, Value>,
    body: Option<&str>,
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(method.as_bytes());
    out.push(b' ');
    out.extend_from_slice(url.as_bytes());
    out.push(b'\n');
    for (name, value) in headers {
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(b": ");
        out.extend_from_slice(scalar_string(value).as_bytes());
        out.push(b'\n');
    }
    out.push(b'\n');
    if let Some(body) = body {
        out.extend_from_slice(body.as_bytes());
    }
    out
}

fn encode_component(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn can_call_network(caller: u32, caller_caps: u32) -> bool {
    caller == CONTROL_CALLER || caller_caps & CAP_NET != 0
}

fn ok(data: Value) -> Value {
    json!({ "ok": true, "data": data })
}

fn error(code: &str, message: impl Into<String>) -> Value {
    json!({
        "ok": false,
        "err": {
            "code": code,
            "message": message.into(),
        }
    })
}

fn json_response(value: Value) -> Response {
    Response::Bytes(serde_json::to_vec(&value).unwrap_or_else(|_| b"{\"ok\":false}".to_vec()))
}

fn stream_for(response: Response) -> OutStream {
    match response {
        Response::Bytes(data) => OutStream {
            source: StreamSource::Bytes { data, offset: 0 },
            pending: VecDeque::new(),
        },
        Response::Fd(fd) => OutStream {
            source: StreamSource::Fd(fd),
            pending: VecDeque::new(),
        },
    }
}

fn pump(server: i32, key: (u32, u32), stream: &mut OutStream) -> Pump {
    loop {
        if let Some((chunk, last)) = stream.pending.pop_front() {
            match rt::svc_respond(server, key.0, key.1, 0, &chunk, last) {
                Ok(()) if last => {
                    stream.close();
                    return Pump::Done;
                }
                Ok(()) => continue,
                Err(e) if e == rt::EAGAIN => {
                    stream.pending.push_front((chunk, last));
                    return Pump::Parked;
                }
                Err(_) => {
                    stream.close();
                    return Pump::Failed;
                }
            }
        }

        match &mut stream.source {
            StreamSource::Bytes { data, offset } => {
                let remaining = data.len().saturating_sub(*offset);
                let n = remaining.min(CHUNK);
                let last = *offset + n == data.len();
                let chunk = data[*offset..*offset + n].to_vec();
                *offset += n;
                stream.pending.push_back((chunk, last));
            }
            StreamSource::Fd(fd) => {
                let mut buf = vec![0u8; CHUNK];
                match rt::read(*fd, &mut buf) {
                    Ok(0) => {
                        stream.pending.push_back((Vec::new(), true));
                        stream.source = StreamSource::Done;
                    }
                    Ok(n) => {
                        buf.truncate(n);
                        stream.pending.push_back((buf, false));
                    }
                    Err(_) => {
                        stream.close();
                        return Pump::Failed;
                    }
                }
            }
            StreamSource::Done => {
                stream.close();
                return Pump::Done;
            }
        }
    }
}

impl OutStream {
    fn close(&mut self) {
        if let StreamSource::Fd(fd) = self.source {
            let _ = rt::close(fd);
        }
        self.source = StreamSource::Done;
        self.pending.clear();
    }
}
