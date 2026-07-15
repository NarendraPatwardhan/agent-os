//! OpenAPI → tool-catalog normalization.
//!
//! The compiler emits only stable, non-secret catalog records. Generated bindings point back to
//! `/svc/adapters invoke`; connection identity is derived later from the tool address so bundles can be
//! reused across owners/connections.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::normalize::{depth_exceeded, sanitize_segment};
use crate::Diagnostic;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceFormat {
    Json,
    Yaml,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompileOptions {
    pub integration: String,
    pub owner: String,
    pub connection: String,
    pub auth: String,
    pub base_url: Option<String>,
    pub filter: OperationFilter,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OperationFilter {
    pub exact_paths: Vec<String>,
    pub path_prefixes: Vec<String>,
    pub tag_prefixes: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CompileOutput {
    pub tools: Vec<Value>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Parameter {
    location: String,
    name: String,
    required: bool,
    schema: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Operation {
    method: String,
    path: String,
    tool_id: String,
    description: String,
    url_template: String,
    parameters: Vec<Parameter>,
    body_schema: Option<Value>,
    body_required: bool,
    response_schema: Option<Value>,
    request_content_type: Option<String>,
    response_content_type: Option<String>,
    operation_id: Option<String>,
    /// `$defs` closure for the input schema (shared by params + request body).
    input_defs: Map<String, Value>,
    /// `$defs` closure for the output (response) schema.
    output_defs: Map<String, Value>,
}

pub fn compile(source: &str, source_format: SourceFormat, opts: &CompileOptions) -> CompileOutput {
    let mut diagnostics = Vec::new();
    if let Err(message) = validate_options(opts) {
        return CompileOutput {
            tools: Vec::new(),
            diagnostics: vec![Diagnostic::error("invalid_options", message, None)],
        };
    }
    let root = match parse_source(source, source_format) {
        Ok(v) => v,
        Err(message) => {
            return CompileOutput {
                tools: Vec::new(),
                diagnostics: vec![Diagnostic::error("parse_failed", message, None)],
            };
        }
    };

    let mut operations = collect_operations(&root, opts, &mut diagnostics);
    assign_collision_suffixes(&mut operations);
    operations.sort_by(|a, b| {
        tool_address(opts, &a.tool_id)
            .cmp(&tool_address(opts, &b.tool_id))
            .then_with(|| a.method.cmp(&b.method))
            .then_with(|| a.path.cmp(&b.path))
    });

    let tools = operations
        .into_iter()
        .map(|op| catalog_record(&root, opts, op))
        .collect();
    CompileOutput { tools, diagnostics }
}

fn parse_source(source: &str, format: SourceFormat) -> Result<Value, String> {
    match format {
        SourceFormat::Json => serde_json::from_str(source).map_err(|e| e.to_string()),
        // Deserialize YAML through a lenient visitor. Straight `serde_yaml::from_str::<Value>` aborts
        // the whole document on a single integer bound outside i64/u64 (e.g. OpenAI declares
        // `seed.minimum: -9223372036854776000`; serde_yaml then hands it over as i128, which neither
        // serde_yaml::Value nor serde_json::Value accepts). `LenientValue` demotes such numbers to
        // f64 instead of failing, so the spec still compiles. Ordinary numbers are preserved exactly.
        SourceFormat::Yaml => serde_yaml::from_str::<LenientValue>(source)
            .map(|v| v.0)
            .map_err(|e| e.to_string()),
    }
}

/// A `serde_json::Value` deserialized leniently: integer scalars wider than i64/u64 (delivered as
/// i128/u128) are demoted to f64 rather than rejected. This only affects out-of-range numbers (which
/// serde_json::Value cannot hold anyway); every other value round-trips unchanged.
struct LenientValue(Value);

impl<'de> Deserialize<'de> for LenientValue {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer
            .deserialize_any(LenientVisitor)
            .map(LenientValue)
    }
}

struct LenientVisitor;

impl<'de> serde::de::Visitor<'de> for LenientVisitor {
    type Value = Value;

    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("any YAML value")
    }

    fn visit_bool<E>(self, v: bool) -> Result<Value, E> {
        Ok(Value::Bool(v))
    }
    fn visit_i64<E>(self, v: i64) -> Result<Value, E> {
        Ok(Value::Number(v.into()))
    }
    fn visit_u64<E>(self, v: u64) -> Result<Value, E> {
        Ok(Value::Number(v.into()))
    }
    fn visit_i128<E>(self, v: i128) -> Result<Value, E> {
        Ok(number_from_f64(v as f64))
    }
    fn visit_u128<E>(self, v: u128) -> Result<Value, E> {
        Ok(number_from_f64(v as f64))
    }
    fn visit_f64<E>(self, v: f64) -> Result<Value, E> {
        Ok(number_from_f64(v))
    }
    fn visit_str<E>(self, v: &str) -> Result<Value, E> {
        Ok(Value::String(v.to_string()))
    }
    fn visit_string<E>(self, v: String) -> Result<Value, E> {
        Ok(Value::String(v))
    }
    fn visit_unit<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_none<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_some<D: serde::Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        d.deserialize_any(LenientVisitor)
    }
    fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let mut out = Vec::new();
        while let Some(LenientValue(v)) = seq.next_element()? {
            out.push(v);
        }
        Ok(Value::Array(out))
    }
    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut out = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            let LenientValue(v) = map.next_value()?;
            out.insert(key, v);
        }
        Ok(Value::Object(out))
    }
}

fn number_from_f64(f: f64) -> Value {
    serde_json::Number::from_f64(f)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

fn collect_operations(
    root: &Value,
    opts: &CompileOptions,
    diagnostics: &mut Vec<Diagnostic>,
) -> Vec<Operation> {
    let mut out = Vec::new();
    let Some(paths) = root.get("paths").and_then(Value::as_object) else {
        diagnostics.push(Diagnostic::error(
            "missing_paths",
            "OpenAPI document has no paths object",
            None,
        ));
        return out;
    };

    for (path, path_item) in paths {
        let path_params = collect_parameters(root, path_item.get("parameters"), diagnostics, None);
        let path_matches = opts.filter.matches_path(path);
        for method in [
            "get", "put", "post", "delete", "options", "head", "patch", "trace",
        ] {
            let Some(op_value) = path_item.get(method) else {
                continue;
            };
            if !opts.filter.is_empty() && !path_matches && !opts.filter.matches_tags(op_value) {
                continue;
            }
            let op_name = operation_name(method, path, op_value);
            match compile_operation(
                root,
                opts,
                path,
                path_item,
                method,
                op_value,
                &path_params,
                diagnostics,
            ) {
                Some(op) => out.push(op),
                None => diagnostics.push(Diagnostic::warn(
                    "operation_skipped",
                    "operation uses an unsupported or incomplete shape",
                    Some(op_name),
                )),
            }
        }
    }
    out
}

impl OperationFilter {
    pub fn is_empty(&self) -> bool {
        self.exact_paths.is_empty() && self.path_prefixes.is_empty() && self.tag_prefixes.is_empty()
    }

    pub fn merged(&self, other: &OperationFilter) -> OperationFilter {
        let mut merged = self.clone();
        append_unique(&mut merged.exact_paths, &other.exact_paths);
        append_unique(&mut merged.path_prefixes, &other.path_prefixes);
        append_unique(&mut merged.tag_prefixes, &other.tag_prefixes);
        merged
    }

    pub fn matches_parts(&self, path: &str, tags: &[&str]) -> bool {
        self.is_empty()
            || self.matches_path(path)
            || tags.iter().any(|tag| {
                self.tag_prefixes
                    .iter()
                    .any(|prefix| *tag == prefix || tag.starts_with(prefix))
            })
    }

    fn matches_path(&self, path: &str) -> bool {
        self.exact_paths.iter().any(|candidate| candidate == path)
            || self
                .path_prefixes
                .iter()
                .any(|prefix| path_has_prefix(path, prefix))
    }

    fn matches_tags(&self, op: &Value) -> bool {
        let Some(tags) = op.get("tags").and_then(Value::as_array) else {
            return false;
        };
        tags.iter().filter_map(Value::as_str).any(|tag| {
            self.tag_prefixes
                .iter()
                .any(|prefix| tag == prefix || tag.starts_with(prefix))
        })
    }
}

fn append_unique(out: &mut Vec<String>, extra: &[String]) {
    for item in extra {
        if !out.iter().any(|existing| existing == item) {
            out.push(item.clone());
        }
    }
}

fn path_has_prefix(path: &str, prefix: &str) -> bool {
    if path == prefix {
        return true;
    }
    let Some(rest) = path.strip_prefix(prefix) else {
        return false;
    };
    rest.starts_with('/') || rest.starts_with('(')
}

fn compile_operation(
    root: &Value,
    opts: &CompileOptions,
    path: &str,
    path_item: &Value,
    method: &str,
    op_value: &Value,
    path_params: &[Parameter],
    diagnostics: &mut Vec<Diagnostic>,
) -> Option<Operation> {
    let operation_id = op_value
        .get("operationId")
        .and_then(Value::as_str)
        .map(str::to_string);
    let tool_id = operation_id
        .as_deref()
        .and_then(sanitize_operation_id)
        .unwrap_or_else(|| derived_tool_id(method, path));
    let description = op_value
        .get("summary")
        .or_else(|| op_value.get("description"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("{} {}", method.to_ascii_uppercase(), path));
    let server = choose_server(root, path_item, op_value, opts, diagnostics, &tool_id)?;
    let url_template = join_url(&server, path);

    let mut params = BTreeMap::<(String, String), Parameter>::new();
    for p in path_params {
        params.insert((p.location.clone(), p.name.clone()), p.clone());
    }
    for p in collect_parameters(
        root,
        op_value.get("parameters"),
        diagnostics,
        Some(tool_id.clone()),
    ) {
        params.insert((p.location.clone(), p.name.clone()), p);
    }
    let mut parameters: Vec<Parameter> = params.into_values().collect();

    // One `$defs` closure per side. Parameters + request body share the input closure; the response
    // owns the output closure. `normalize_schema` records referenced components into the closure and
    // rewrites `$ref`s to point at them, so nothing is inlined (and nothing balloons).
    let mut input_defs = Map::new();
    for p in &mut parameters {
        let raw = p.schema.clone();
        p.schema = normalize_schema(root, &raw, SchemaUse::Input, 0, &mut input_defs);
    }
    let (body_schema, body_required, request_content_type) = request_body(
        root,
        op_value.get("requestBody"),
        diagnostics,
        &tool_id,
        &mut input_defs,
    )?;

    let mut output_defs = Map::new();
    let (response_schema, response_content_type) =
        response_schema(root, op_value, &mut output_defs);

    Some(Operation {
        method: method.to_ascii_uppercase(),
        path: path.to_string(),
        tool_id,
        description,
        url_template,
        parameters,
        body_schema,
        body_required,
        response_schema,
        request_content_type,
        response_content_type,
        operation_id,
        input_defs,
        output_defs,
    })
}

fn collect_parameters(
    root: &Value,
    value: Option<&Value>,
    diagnostics: &mut Vec<Diagnostic>,
    operation: Option<String>,
) -> Vec<Parameter> {
    let Some(Value::Array(items)) = value else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in items {
        let Some(param) = resolve_ref_or_self(root, item) else {
            diagnostics.push(Diagnostic::warn(
                "bad_ref",
                "parameter $ref could not be resolved",
                operation.clone(),
            ));
            continue;
        };
        let Some(name) = param.get("name").and_then(Value::as_str) else {
            continue;
        };
        let Some(location) = param.get("in").and_then(Value::as_str) else {
            continue;
        };
        if !matches!(location, "path" | "query" | "header" | "cookie") {
            continue;
        }
        let required = location == "path"
            || param
                .get("required")
                .and_then(Value::as_bool)
                .unwrap_or(false);
        // Raw schema; normalized (with the operation's shared `$defs`) in compile_operation.
        let schema = param
            .get("schema")
            .cloned()
            .unwrap_or_else(|| json!({"type":"string"}));
        out.push(Parameter {
            location: location.to_string(),
            name: name.to_string(),
            required,
            schema,
        });
    }
    out
}

fn request_body(
    root: &Value,
    value: Option<&Value>,
    diagnostics: &mut Vec<Diagnostic>,
    operation: &str,
    defs: &mut Map<String, Value>,
) -> Option<(Option<Value>, bool, Option<String>)> {
    let Some(body) = value else {
        return Some((None, false, None));
    };
    let body = resolve_ref_or_self(root, body)?;
    let required = body
        .get("required")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let content = body.get("content").and_then(Value::as_object)?;
    // Emit JSON, form-urlencoded, and multipart bodies (Stripe et al. are entirely form-encoded);
    // the chosen media type rides along so the executor serializes the arguments correctly.
    let Some((content_type, media)) = [
        "application/json",
        "application/x-www-form-urlencoded",
        "multipart/form-data",
    ]
    .into_iter()
    .find_map(|ct| content.get(ct).map(|m| (ct, m))) else {
        diagnostics.push(Diagnostic::warn(
            "unsupported_request_body",
            "only application/json, application/x-www-form-urlencoded, and multipart/form-data request bodies are emitted in the first adapter slice",
            Some(operation.to_string()),
        ));
        return None;
    };
    let schema = media
        .get("schema")
        .map(|s| normalize_schema(root, s, SchemaUse::Input, 0, defs))
        .unwrap_or_else(|| json!({"type":"object"}));
    Some((Some(schema), required, Some(content_type.to_string())))
}

fn response_schema(
    root: &Value,
    op_value: &Value,
    defs: &mut Map<String, Value>,
) -> (Option<Value>, Option<String>) {
    let Some(responses) = op_value.get("responses").and_then(Value::as_object) else {
        return (None, None);
    };
    let mut keys: Vec<&String> = responses
        .keys()
        .filter(|k| k.starts_with('2') || k.as_str() == "default")
        .collect();
    keys.sort();
    for key in keys {
        let Some(resp) = responses
            .get(key)
            .and_then(|r| resolve_ref_or_self(root, r))
        else {
            continue;
        };
        let Some(content) = resp.get("content").and_then(Value::as_object) else {
            continue;
        };
        if let Some(media) = content.get("application/json") {
            return (
                media
                    .get("schema")
                    .map(|s| normalize_schema(root, s, SchemaUse::Output, 0, defs)),
                Some("application/json".to_string()),
            );
        }
    }
    (None, None)
}

#[derive(Clone, Copy)]
enum SchemaUse {
    Input,
    Output,
}

fn normalize_schema(
    root: &Value,
    schema: &Value,
    use_case: SchemaUse,
    depth: usize,
    defs: &mut Map<String, Value>,
) -> Value {
    if depth_exceeded(depth) {
        return json!({});
    }
    // Reference-preserving normalization. Entity specs (Microsoft Graph, Stripe, Google) have wide,
    // cyclically cross-referential component graphs. Inlining every `$ref` turns that compact graph
    // into a tree — a DAG inlines to exponential size, a cycle to infinite size — which is what made a
    // single `GET /me` balloon past the 4 GB wasm ceiling. Instead, normalize each referenced
    // component ONCE into a shared `$defs` map and point at it with a rewritten `$ref`. Output is then
    // linear in the referenced-component count, and a recursive entity is represented exactly (its
    // self-reference is just a `$ref`) — nothing is lost and nothing balloons.
    if let Some(reference) = schema.get("$ref").and_then(Value::as_str) {
        let Some(pointer) = reference.strip_prefix('#') else {
            return schema.clone(); // external ref: cannot resolve locally, keep verbatim
        };
        let key = def_key(pointer);
        if !defs.contains_key(&key) {
            // Register a placeholder BEFORE recursing so a cyclic component terminates at the `$ref`.
            defs.insert(key.clone(), json!({}));
            let normalized = match root.pointer(pointer) {
                // A component is a top-level definition: normalize it at depth 0 so its result is
                // independent of where it was first referenced. Termination is guaranteed by the
                // placeholder above, not by the depth cap.
                Some(target) => normalize_resolved(root, &target.clone(), use_case, 0, defs),
                None => json!({}),
            };
            defs.insert(key.clone(), normalized);
        }
        return json!({ "$ref": format!("#/$defs/{key}") });
    }
    normalize_resolved(root, schema, use_case, depth, defs)
}

/// Turn a `#/components/schemas/microsoft.graph.user` pointer into a slash-free `$defs` key
/// (`components.schemas.microsoft.graph.user`) so the rewritten `#/$defs/<key>` resolves in one hop.
fn def_key(pointer: &str) -> String {
    pointer.trim_start_matches('/').replace('/', ".")
}

fn normalize_resolved(
    root: &Value,
    schema: &Value,
    use_case: SchemaUse,
    depth: usize,
    defs: &mut Map<String, Value>,
) -> Value {
    let Some(obj) = schema.as_object() else {
        return schema.clone();
    };
    let mut out = Map::new();
    for (key, value) in obj {
        if key == "nullable" || key == "$ref" {
            continue;
        }
        if matches!(use_case, SchemaUse::Input) && key == "readOnly" {
            continue;
        }
        if matches!(use_case, SchemaUse::Output) && key == "writeOnly" {
            continue;
        }
        let normalized = match key.as_str() {
            "properties" => normalize_properties(root, value, use_case, depth + 1, defs),
            "items" | "additionalProperties" => {
                normalize_schema(root, value, use_case, depth + 1, defs)
            }
            // Composition keywords are preserved as arrays of normalized (ref-preserving) branches,
            // rather than merged, so `allOf: [{$ref: base}, {inline}]` keeps both without inlining.
            "allOf" | "oneOf" | "anyOf" => {
                normalize_schema_array(root, value, use_case, depth + 1, defs)
            }
            _ => value.clone(),
        };
        out.insert(key.clone(), normalized);
    }
    if obj.get("nullable").and_then(Value::as_bool) == Some(true) {
        add_null_type(&mut out);
    }
    Value::Object(out)
}

fn normalize_properties(
    root: &Value,
    value: &Value,
    use_case: SchemaUse,
    depth: usize,
    defs: &mut Map<String, Value>,
) -> Value {
    let Some(props) = value.as_object() else {
        return value.clone();
    };
    let mut out = Map::new();
    for (name, schema) in props {
        out.insert(
            name.clone(),
            normalize_schema(root, schema, use_case, depth, defs),
        );
    }
    Value::Object(out)
}

fn normalize_schema_array(
    root: &Value,
    value: &Value,
    use_case: SchemaUse,
    depth: usize,
    defs: &mut Map<String, Value>,
) -> Value {
    let Some(items) = value.as_array() else {
        return value.clone();
    };
    Value::Array(
        items
            .iter()
            .map(|item| normalize_schema(root, item, use_case, depth, defs))
            .collect(),
    )
}

fn add_null_type(out: &mut Map<String, Value>) {
    match out.get_mut("type") {
        Some(Value::String(t)) if t != "null" => {
            let old = t.clone();
            out.insert("type".to_string(), json!([old, "null"]));
        }
        Some(Value::Array(items)) => {
            if !items.iter().any(|v| v.as_str() == Some("null")) {
                items.push(Value::String("null".to_string()));
            }
        }
        _ => {
            out.insert("type".to_string(), json!(["object", "null"]));
        }
    }
}

fn resolve_ref<'a>(root: &'a Value, value: &'a Value) -> Option<&'a Value> {
    let reference = value.get("$ref").and_then(Value::as_str)?;
    let pointer = reference.strip_prefix('#')?;
    root.pointer(pointer)
}

fn resolve_ref_or_self<'a>(root: &'a Value, value: &'a Value) -> Option<&'a Value> {
    if value.get("$ref").is_some() {
        resolve_ref(root, value)
    } else {
        Some(value)
    }
}

fn choose_server(
    root: &Value,
    path_item: &Value,
    op_value: &Value,
    opts: &CompileOptions,
    diagnostics: &mut Vec<Diagnostic>,
    operation: &str,
) -> Option<String> {
    for source in [
        op_value.get("servers"),
        path_item.get("servers"),
        root.get("servers"),
    ] {
        if let Some(server) = first_server_url(source) {
            return expand_server(server, diagnostics, operation).or_else(|| opts.base_url.clone());
        }
    }
    opts.base_url.clone()
}

fn first_server_url(value: Option<&Value>) -> Option<&Value> {
    value
        .and_then(Value::as_array)
        .and_then(|servers| servers.first())
        .and_then(|server| server.get("url"))
}

fn expand_server(
    value: &Value,
    diagnostics: &mut Vec<Diagnostic>,
    operation: &str,
) -> Option<String> {
    let url = value.as_str()?.to_string();
    if !url.contains('{') {
        return Some(url);
    }
    diagnostics.push(Diagnostic::warn(
        "server_variables_unsupported",
        "server variables require an explicit base_url in the first adapter slice",
        Some(operation.to_string()),
    ));
    None
}

fn join_url(base: &str, path: &str) -> String {
    match (base.ends_with('/'), path.starts_with('/')) {
        (true, true) => format!("{}{}", base.trim_end_matches('/'), path),
        (false, false) => format!("{base}/{path}"),
        _ => format!("{base}{path}"),
    }
}

fn catalog_record(root: &Value, opts: &CompileOptions, op: Operation) -> Value {
    let input_schema = input_schema(&op);
    let mut record = Map::new();
    record.insert(
        "address".to_string(),
        Value::String(tool_address(opts, &op.tool_id)),
    );
    record.insert(
        "description".to_string(),
        Value::String(op.description.clone()),
    );
    if !empty_object(&input_schema) {
        record.insert("input_schema".to_string(), input_schema);
    }
    if let Some(mut schema) = op.response_schema.clone() {
        // Attach the response `$defs` closure so the (ref-preserving) output schema is self-contained.
        if !op.output_defs.is_empty() {
            if let Some(obj) = schema.as_object_mut() {
                obj.insert("$defs".to_string(), Value::Object(op.output_defs.clone()));
            }
        }
        record.insert("output_schema".to_string(), schema);
    }
    let destructive = matches!(op.method.as_str(), "POST" | "PUT" | "PATCH" | "DELETE");
    let mut annotations = Map::new();
    annotations.insert("adapter".to_string(), Value::String("openapi".to_string()));
    annotations.insert("method".to_string(), Value::String(op.method.clone()));
    annotations.insert("path".to_string(), Value::String(op.path.clone()));
    annotations.insert("operationId".to_string(), json!(op.operation_id));
    annotations.insert(
        "responseContentType".to_string(),
        json!(op.response_content_type),
    );
    if destructive {
        annotations.insert("requires_approval".to_string(), Value::Bool(true));
        annotations.insert(
            "approval_description".to_string(),
            Value::String(format!("{} {}", op.method, op.path)),
        );
    }
    record.insert("annotations".to_string(), Value::Object(annotations));
    record.insert("binding".to_string(), binding(root, &op));
    Value::Object(record)
}

fn binding(_root: &Value, op: &Operation) -> Value {
    let params: Vec<Value> = op
        .parameters
        .iter()
        .map(|p| {
            json!({
                "in": p.location,
                "name": p.name,
                "required": p.required,
            })
        })
        .collect();
    let mut request = Map::new();
    request.insert("method".to_string(), Value::String(op.method.clone()));
    request.insert(
        "url_template".to_string(),
        Value::String(op.url_template.clone()),
    );
    request.insert("parameters".to_string(), Value::Array(params));
    request.insert(
        "request_body".to_string(),
        op.request_content_type
            .as_ref()
            .map(|content_type| json!({"content_type": content_type}))
            .unwrap_or(Value::Null),
    );
    json!({
        "type": "service",
        "service": "adapters",
        "op": "invoke",
        "adapter": "openapi",
        "args": "json",
        "request": Value::Object(request)
    })
}

fn input_schema(op: &Operation) -> Value {
    let mut root_props = Map::new();
    let mut root_required = Vec::new();
    for (group, location) in [
        ("path", "path"),
        ("query", "query"),
        ("headers", "header"),
        ("cookies", "cookie"),
    ] {
        let params: Vec<&Parameter> = op
            .parameters
            .iter()
            .filter(|p| p.location == location)
            .collect();
        if params.is_empty() {
            continue;
        }
        let mut props = Map::new();
        let mut required = Vec::new();
        for p in params {
            props.insert(p.name.clone(), p.schema.clone());
            if p.required {
                required.push(Value::String(p.name.clone()));
            }
        }
        let mut group_schema = Map::new();
        group_schema.insert("type".to_string(), Value::String("object".to_string()));
        group_schema.insert("additionalProperties".to_string(), Value::Bool(false));
        group_schema.insert("properties".to_string(), Value::Object(props));
        if !required.is_empty() {
            group_schema.insert("required".to_string(), Value::Array(required));
            root_required.push(Value::String(group.to_string()));
        }
        root_props.insert(group.to_string(), Value::Object(group_schema));
    }
    if let Some(body) = &op.body_schema {
        root_props.insert("body".to_string(), body.clone());
        if op.body_required {
            root_required.push(Value::String("body".to_string()));
        }
    }

    let mut schema = Map::new();
    schema.insert("type".to_string(), Value::String("object".to_string()));
    schema.insert("additionalProperties".to_string(), Value::Bool(false));
    schema.insert("properties".to_string(), Value::Object(root_props));
    if !root_required.is_empty() {
        schema.insert("required".to_string(), Value::Array(root_required));
    }
    // Attach the input `$defs` closure so the (ref-preserving) input schema is self-contained.
    if !op.input_defs.is_empty() {
        schema.insert("$defs".to_string(), Value::Object(op.input_defs.clone()));
    }
    Value::Object(schema)
}

fn empty_object(value: &Value) -> bool {
    value
        .get("properties")
        .and_then(Value::as_object)
        .map(Map::is_empty)
        .unwrap_or(false)
}

fn tool_address(opts: &CompileOptions, tool_id: &str) -> String {
    format!(
        "{}.{}.{}.{}",
        sanitize_segment(&opts.integration),
        opts.owner,
        sanitize_segment(&opts.connection),
        tool_id
    )
}

fn validate_options(opts: &CompileOptions) -> Result<(), String> {
    if sanitize_segment(&opts.integration).is_empty() {
        return Err("integration must contain at least one address-safe character".to_string());
    }
    if opts.owner != "org" && opts.owner != "user" {
        return Err("owner must be `org` or `user`".to_string());
    }
    if sanitize_segment(&opts.connection).is_empty() {
        return Err("connection must contain at least one address-safe character".to_string());
    }
    if !matches!(opts.auth.as_str(), "none" | "bearer" | "header" | "query") {
        return Err("auth must be `none`, `bearer`, `header`, or `query`".to_string());
    }
    Ok(())
}

fn operation_name(method: &str, path: &str, op_value: &Value) -> String {
    op_value
        .get("operationId")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| format!("{} {}", method.to_ascii_uppercase(), path))
}

fn sanitize_operation_id(value: &str) -> Option<String> {
    let clean = sanitize_segment(value);
    (!clean.is_empty()).then_some(clean)
}

fn derived_tool_id(method: &str, path: &str) -> String {
    let mut parts = vec![sanitize_segment(method)];
    for raw in path.split('/') {
        let raw = raw.trim_matches('{').trim_matches('}');
        let clean = sanitize_segment(raw);
        if !clean.is_empty() {
            parts.push(clean);
        }
    }
    parts.join(".")
}

fn assign_collision_suffixes(operations: &mut [Operation]) {
    let mut counts = BTreeMap::<String, usize>::new();
    for op in operations.iter() {
        *counts.entry(op.tool_id.clone()).or_default() += 1;
    }
    for op in operations.iter_mut() {
        if counts.get(&op.tool_id).copied().unwrap_or(0) > 1 {
            let suffix = stable_hash8(&format!("{} {}", op.method, op.path));
            op.tool_id = format!("{}.{}", op.tool_id, suffix);
        }
    }
}

fn stable_hash8(value: &str) -> String {
    let mut hash = 0xcbf29ce484222325u64;
    for b in value.as_bytes() {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")[..8].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PETSTORE: &str = r##"{
      "openapi": "3.0.3",
      "info": { "title": "Pets", "version": "1.0.0" },
      "servers": [{ "url": "https://pets.example.test/v1" }],
      "paths": {
        "/pets": {
          "get": {
            "operationId": "listPets",
            "summary": "List pets",
            "parameters": [
              { "name": "limit", "in": "query", "schema": { "type": "integer" } }
            ],
            "responses": {
              "200": {
                "description": "ok",
                "content": {
                  "application/json": {
                    "schema": {
                      "type": "array",
                      "items": { "$ref": "#/components/schemas/Pet" }
                    }
                  }
                }
              }
            }
          }
        },
        "/pets/{petId}": {
          "get": {
            "summary": "Show pet",
            "parameters": [
              { "name": "petId", "in": "path", "required": true, "schema": { "type": "string" } }
            ],
            "responses": { "200": { "description": "ok" } }
          }
        }
      },
      "components": {
        "schemas": {
          "Pet": {
            "type": "object",
            "required": ["id"],
            "properties": {
              "id": { "type": "string" },
              "name": { "type": "string", "nullable": true }
            }
          }
        }
      }
    }"##;

    fn opts() -> CompileOptions {
        CompileOptions {
            integration: "petstore".to_string(),
            owner: "org".to_string(),
            connection: "main".to_string(),
            auth: "none".to_string(),
            base_url: None,
            filter: OperationFilter::default(),
        }
    }

    #[test]
    fn emits_deterministic_openapi_catalog_records() {
        let out = compile(PETSTORE, SourceFormat::Json, &opts());
        assert_eq!(out.diagnostics, Vec::new());
        assert_eq!(out.tools.len(), 2);
        let rendered = serde_json::to_string(&out.tools).unwrap();
        assert!(rendered.contains("\"address\":\"petstore.org.main.get.pets.petId\""));
        assert!(rendered.contains("\"address\":\"petstore.org.main.listPets\""));
        assert!(rendered.contains("\"service\":\"adapters\""));
        assert!(rendered.contains("\"adapter\":\"openapi\""));
        assert!(!rendered.contains("connection_ref"));
        assert!(!rendered.to_ascii_lowercase().contains("authorization"));
    }

    #[test]
    fn yaml_input_uses_the_same_normalizer() {
        let source = r#"
openapi: 3.0.3
info: { title: Demo, version: 1.0.0 }
servers:
  - url: https://demo.example.test
paths:
  /ping:
    get:
      operationId: ping
      responses:
        "200":
          description: ok
"#;
        let out = compile(source, SourceFormat::Yaml, &opts());
        assert_eq!(out.diagnostics, Vec::new());
        assert_eq!(out.tools[0]["address"], "petstore.org.main.ping");
    }

    #[test]
    fn rejects_options_that_cannot_emit_valid_tool_addresses() {
        let mut bad = opts();
        bad.owner = "team".to_string();
        let out = compile(PETSTORE, SourceFormat::Json, &bad);
        assert_eq!(out.tools, Vec::<Value>::new());
        assert_eq!(out.diagnostics[0].code, "invalid_options");
    }

    #[test]
    fn explicit_base_url_overrides_unsupported_variable_servers() {
        let source = r#"
openapi: 3.0.3
info: { title: Demo, version: 1.0.0 }
servers:
  - url: https://{tenant}.example.test
paths:
  /ping:
    get:
      operationId: ping
      responses:
        "200":
          description: ok
"#;
        let mut opts = opts();
        opts.base_url = Some("https://fixed.example.test".to_string());
        let out = compile(source, SourceFormat::Yaml, &opts);
        assert_eq!(out.tools.len(), 1);
        let binding = &out.tools[0]["binding"]["request"];
        assert_eq!(binding["url_template"], "https://fixed.example.test/ping");
        assert_eq!(out.diagnostics[0].code, "server_variables_unsupported");
    }

    #[test]
    fn generic_filter_keeps_path_and_tag_subsets() {
        let source = r#"{
          "openapi": "3.0.3",
          "info": { "title": "Demo", "version": "1.0.0" },
          "servers": [{ "url": "https://demo.example.test" }],
          "paths": {
            "/repos/{owner}/{repo}/issues": {
              "get": {
                "operationId": "listIssues",
                "tags": ["issues"],
                "responses": { "200": { "description": "ok" } }
              }
            },
            "/repos/{owner}/{repo}/pulls": {
              "get": {
                "operationId": "listPulls",
                "tags": ["pulls"],
                "responses": { "200": { "description": "ok" } }
              }
            },
            "/user/issues": {
              "get": {
                "operationId": "listUserIssues",
                "tags": ["user.issues"],
                "responses": { "200": { "description": "ok" } }
              }
            }
          }
        }"#;
        let mut opts = opts();
        opts.filter = OperationFilter {
            exact_paths: Vec::new(),
            path_prefixes: vec!["/repos/{owner}/{repo}/issues".to_string()],
            tag_prefixes: vec!["user.".to_string()],
        };
        let out = compile(source, SourceFormat::Json, &opts);
        assert_eq!(out.diagnostics, Vec::new());
        assert_eq!(out.tools.len(), 2);
        let rendered = serde_json::to_string(&out.tools).unwrap();
        assert!(rendered.contains("listIssues"));
        assert!(rendered.contains("listUserIssues"));
        assert!(!rendered.contains("listPulls"));
    }
}
