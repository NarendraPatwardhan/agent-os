//! Google Discovery normalization.
//!
//! Google APIs publish Discovery documents instead of OpenAPI. This module converts the Discovery
//! method/resource tree into a compact OpenAPI 3 document, then reuses the OpenAPI catalog compiler so
//! request binding, schemas, and host-side credential markers stay consistent across adapters.

use serde_json::{json, Map, Value};

use crate::normalize::depth_exceeded;
use crate::openapi::{self, CompileOutput, SourceFormat};
use crate::Diagnostic;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CompileOptions {}

pub fn compile(
    source: &str,
    source_format: SourceFormat,
    openapi_opts: &openapi::CompileOptions,
    _opts: &CompileOptions,
) -> CompileOutput {
    let root = match parse_source(source, source_format) {
        Ok(value) => value,
        Err(message) => {
            return CompileOutput {
                tools: Vec::new(),
                diagnostics: vec![Diagnostic::error("parse_failed", message, None)],
            }
        }
    };
    let mut diagnostics = Vec::new();
    let normalized = normalize_discovery(&root, openapi_opts.base_url.as_deref(), &mut diagnostics);
    let source = match serde_json::to_string(&normalized) {
        Ok(source) => source,
        Err(_) => {
            return CompileOutput {
                tools: Vec::new(),
                diagnostics: vec![Diagnostic::error(
                    "normalize_failed",
                    "could not encode normalized Google Discovery document",
                    None,
                )],
            }
        }
    };
    let mut out = openapi::compile(&source, SourceFormat::Json, openapi_opts);
    diagnostics.append(&mut out.diagnostics);
    out.diagnostics = diagnostics;
    annotate_tools(&mut out.tools);
    out
}

fn parse_source(source: &str, format: SourceFormat) -> Result<Value, String> {
    match format {
        SourceFormat::Json => serde_json::from_str(source).map_err(|e| e.to_string()),
        SourceFormat::Yaml => serde_yaml::from_str(source).map_err(|e| e.to_string()),
    }
}

fn normalize_discovery(
    root: &Value,
    base_url: Option<&str>,
    diagnostics: &mut Vec<Diagnostic>,
) -> Value {
    let mut paths = Map::new();
    collect_methods(root, &mut paths, diagnostics, 0);
    if paths.is_empty() {
        diagnostics.push(Diagnostic::warn(
            "no_methods",
            "Google Discovery document contained no methods",
            None,
        ));
    }

    let mut components = Map::new();
    if let Some(schemas) = root.get("schemas").and_then(Value::as_object) {
        for (name, schema) in schemas {
            components.insert(name.clone(), discovery_schema(schema, 0));
        }
    }

    json!({
        "openapi": "3.0.3",
        "info": {
            "title": text_field(root, "title")
                .or_else(|| text_field(root, "name"))
                .unwrap_or_else(|| "Google API".to_string()),
            "version": text_field(root, "version").unwrap_or_else(|| "v1".to_string()),
        },
        "servers": [{ "url": discovery_base_url(root, base_url) }],
        "paths": paths,
        "components": { "schemas": components },
    })
}

fn collect_methods(
    node: &Value,
    paths: &mut Map<String, Value>,
    diagnostics: &mut Vec<Diagnostic>,
    depth: usize,
) {
    if depth_exceeded(depth) {
        diagnostics.push(Diagnostic::warn(
            "max_depth_exceeded",
            "Google Discovery resource tree exceeded the supported nesting depth",
            None,
        ));
        return;
    }

    if let Some(methods) = node.get("methods").and_then(Value::as_object) {
        let mut names: Vec<&String> = methods.keys().collect();
        names.sort();
        for name in names {
            if let Some(method) = methods.get(name) {
                insert_method(name, method, paths, diagnostics);
            }
        }
    }
    if let Some(resources) = node.get("resources").and_then(Value::as_object) {
        let mut names: Vec<&String> = resources.keys().collect();
        names.sort();
        for name in names {
            if let Some(resource) = resources.get(name) {
                collect_methods(resource, paths, diagnostics, depth + 1);
            }
        }
    }
}

fn insert_method(
    fallback_name: &str,
    method: &Value,
    paths: &mut Map<String, Value>,
    diagnostics: &mut Vec<Diagnostic>,
) {
    let operation_id = text_field(method, "id").unwrap_or_else(|| fallback_name.to_string());
    let Some(path) = text_field(method, "path").map(|path| ensure_leading_slash(&path)) else {
        diagnostics.push(Diagnostic::warn(
            "method_skipped",
            "Google Discovery method has no path",
            Some(operation_id),
        ));
        return;
    };
    let verb = text_field(method, "httpMethod")
        .unwrap_or_else(|| "GET".to_string())
        .to_ascii_lowercase();
    if !matches!(
        verb.as_str(),
        "get" | "put" | "post" | "delete" | "options" | "head" | "patch" | "trace"
    ) {
        diagnostics.push(Diagnostic::warn(
            "method_skipped",
            "Google Discovery method uses an unsupported HTTP method",
            Some(operation_id),
        ));
        return;
    }

    let mut op = Map::new();
    op.insert(
        "operationId".to_string(),
        Value::String(operation_id.clone()),
    );
    if let Some(description) = text_field(method, "description") {
        op.insert("description".to_string(), Value::String(description));
    }
    let parameters = discovery_parameters(method);
    if !parameters.is_empty() {
        op.insert("parameters".to_string(), Value::Array(parameters));
    }
    if let Some(body) = discovery_body(method) {
        op.insert("requestBody".to_string(), body);
    }
    op.insert("responses".to_string(), discovery_responses(method));

    let entry = paths
        .entry(path)
        .or_insert_with(|| Value::Object(Map::new()));
    let Some(path_item) = entry.as_object_mut() else {
        diagnostics.push(Diagnostic::warn(
            "method_skipped",
            "Google Discovery path collided with a non-object path item",
            Some(operation_id),
        ));
        return;
    };
    if path_item.insert(verb, Value::Object(op)).is_some() {
        diagnostics.push(Diagnostic::warn(
            "method_replaced",
            "Google Discovery contained duplicate HTTP methods for one path",
            Some(operation_id),
        ));
    }
}

fn discovery_parameters(method: &Value) -> Vec<Value> {
    let Some(parameters) = method.get("parameters").and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut names: Vec<&String> = parameters.keys().collect();
    names.sort();
    names
        .into_iter()
        .filter_map(|name| {
            let param = parameters.get(name)?;
            let location = text_field(param, "location").unwrap_or_else(|| "query".to_string());
            if !matches!(location.as_str(), "path" | "query" | "header" | "cookie") {
                return None;
            }
            let mut out = Map::new();
            out.insert("name".to_string(), Value::String(name.clone()));
            out.insert("in".to_string(), Value::String(location.clone()));
            if location == "path" || param.get("required").and_then(Value::as_bool) == Some(true) {
                out.insert("required".to_string(), Value::Bool(true));
            }
            out.insert("schema".to_string(), discovery_parameter_schema(param));
            Some(Value::Object(out))
        })
        .collect()
}

fn discovery_parameter_schema(param: &Value) -> Value {
    let schema = discovery_schema(param, 0);
    if param.get("repeated").and_then(Value::as_bool) == Some(true) {
        json!({
            "type": "array",
            "items": schema,
        })
    } else {
        schema
    }
}

fn discovery_body(method: &Value) -> Option<Value> {
    let request = method.get("request")?;
    Some(json!({
        "required": true,
        "content": {
            "application/json": {
                "schema": discovery_schema(request, 0),
            }
        }
    }))
}

fn discovery_responses(method: &Value) -> Value {
    let schema = method
        .get("response")
        .map(|schema| discovery_schema(schema, 0))
        .unwrap_or_else(|| json!({ "type": "object" }));
    json!({
        "200": {
            "description": "ok",
            "content": {
                "application/json": {
                    "schema": schema,
                }
            }
        }
    })
}

fn discovery_schema(schema: &Value, depth: usize) -> Value {
    if depth_exceeded(depth) {
        return json!({});
    }

    if let Some(reference) = text_field(schema, "$ref") {
        return json!({ "$ref": format!("#/components/schemas/{reference}") });
    }

    let Some(obj) = schema.as_object() else {
        return json!({});
    };
    let mut out = Map::new();
    for key in [
        "type",
        "format",
        "description",
        "enum",
        "default",
        "minimum",
        "maximum",
        "pattern",
    ] {
        if let Some(value) = obj.get(key) {
            if key == "type" && value.as_str() == Some("any") {
                continue;
            }
            out.insert(key.to_string(), value.clone());
        }
    }
    if let Some(properties) = obj.get("properties").and_then(Value::as_object) {
        let mut props = Map::new();
        let mut names: Vec<&String> = properties.keys().collect();
        names.sort();
        for name in names {
            if let Some(property) = properties.get(name) {
                props.insert(name.clone(), discovery_schema(property, depth + 1));
            }
        }
        out.insert("properties".to_string(), Value::Object(props));
        out.entry("type".to_string())
            .or_insert_with(|| Value::String("object".to_string()));
    }
    if let Some(items) = obj.get("items") {
        out.insert("items".to_string(), discovery_schema(items, depth + 1));
    }
    if let Some(additional) = obj.get("additionalProperties") {
        let value = match additional {
            Value::Bool(_) => additional.clone(),
            _ => discovery_schema(additional, depth + 1),
        };
        out.insert("additionalProperties".to_string(), value);
    }
    if out.is_empty() {
        json!({})
    } else {
        Value::Object(out)
    }
}

fn discovery_base_url(root: &Value, override_url: Option<&str>) -> String {
    if let Some(url) = override_url {
        return url.trim_end_matches('/').to_string();
    }
    if let Some(url) = text_field(root, "baseUrl") {
        return url.trim_end_matches('/').to_string();
    }
    let root_url =
        text_field(root, "rootUrl").unwrap_or_else(|| "https://www.googleapis.com/".to_string());
    let service_path = text_field(root, "servicePath").unwrap_or_default();
    let joined = format!(
        "{}/{}",
        root_url.trim_end_matches('/'),
        service_path.trim_matches('/')
    );
    joined.trim_end_matches('/').to_string()
}

fn ensure_leading_slash(path: &str) -> String {
    if path.starts_with('/') {
        path.to_string()
    } else {
        format!("/{path}")
    }
}

fn text_field(value: &Value, field: &str) -> Option<String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn annotate_tools(tools: &mut [Value]) {
    for tool in tools {
        let Some(annotations) = tool.get_mut("annotations").and_then(Value::as_object_mut) else {
            continue;
        };
        annotations.insert(
            "sourceFormat".to_string(),
            Value::String("google-discovery".to_string()),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::normalize::MAX_NORMALIZATION_DEPTH;

    fn openapi_opts() -> openapi::CompileOptions {
        openapi::CompileOptions {
            integration: "google".to_string(),
            owner: "org".to_string(),
            connection: "main".to_string(),
            auth: "bearer".to_string(),
            base_url: None,
            filter: openapi::OperationFilter::default(),
        }
    }

    #[test]
    fn emits_catalog_records_from_discovery_methods() {
        let source = r#"{
          "title": "Drive API",
          "version": "v3",
          "rootUrl": "https://www.googleapis.com/",
          "servicePath": "drive/v3/",
          "methods": {
            "files.list": {
              "id": "drive.files.list",
              "path": "files",
              "httpMethod": "GET",
              "parameters": {
                "pageSize": { "type": "integer", "location": "query" }
              },
              "response": { "$ref": "FileList" }
            }
          },
          "schemas": {
            "FileList": {
              "type": "object",
              "properties": {
                "files": { "type": "array", "items": { "$ref": "File" } }
              }
            },
            "File": {
              "type": "object",
              "properties": { "id": { "type": "string" } }
            }
          }
        }"#;

        let out = compile(
            source,
            SourceFormat::Json,
            &openapi_opts(),
            &CompileOptions {},
        );
        assert_eq!(out.diagnostics, Vec::new());
        assert_eq!(out.tools.len(), 1);
        assert_eq!(out.tools[0]["address"], "google.org.main.drive-files-list");
        assert_eq!(
            out.tools[0]["annotations"]["sourceFormat"],
            "google-discovery"
        );
        assert_eq!(
            out.tools[0]["binding"]["request"]["url_template"],
            "https://www.googleapis.com/drive/v3/files"
        );
    }

    #[test]
    fn resource_collection_stops_at_the_depth_limit() {
        let mut node = json!({
            "methods": {
                "deep.get": {
                    "id": "deep.get",
                    "path": "deep",
                    "httpMethod": "GET"
                }
            }
        });
        for i in 0..=MAX_NORMALIZATION_DEPTH {
            node = json!({ "resources": { format!("r{i}"): node } });
        }
        let source = serde_json::to_string(&node).unwrap();

        let out = compile(
            &source,
            SourceFormat::Json,
            &openapi_opts(),
            &CompileOptions {},
        );
        assert_eq!(out.tools, Vec::<Value>::new());
        assert!(out
            .diagnostics
            .iter()
            .any(|diag| diag.code == "max_depth_exceeded"));
        assert!(out.diagnostics.iter().any(|diag| diag.code == "no_methods"));
    }

    #[test]
    fn schema_normalization_stops_at_the_depth_limit() {
        let mut schema = json!({ "type": "string" });
        for i in (0..40).rev() {
            schema = json!({
                "type": "object",
                "properties": {
                    format!("p{i}"): schema
                }
            });
        }

        let normalized = discovery_schema(&schema, 0);
        let rendered = serde_json::to_string(&normalized).unwrap();
        assert!(rendered.contains("\"p0\""));
        assert!(rendered.contains("\"p32\""));
        assert!(!rendered.contains("\"p33\""));
    }
}
