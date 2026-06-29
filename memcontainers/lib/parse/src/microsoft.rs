//! Microsoft Graph workload normalization.
//!
//! Microsoft Graph publishes one large OpenAPI document. The registry carries smaller workload
//! presets as path filters, so this module trims the source document to the requested presets and then
//! feeds the ordinary OpenAPI compiler. Tool bindings still invoke the OpenAPI adapter path; the
//! Microsoft-specific work is deterministic source selection, not a separate runtime.

use serde_json::{json, Value};

use crate::openapi::{self, CompileOutput, OperationFilter, SourceFormat};
use crate::registry::{self, RegistryKind};
use crate::Diagnostic;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CompileOptions {
    pub preset_ids: Vec<String>,
    pub filter: OperationFilter,
}

#[derive(Default)]
struct PresetFilter {
    all_paths: bool,
    ids: Vec<String>,
    filter: OperationFilter,
}

pub fn compile(
    source: &str,
    source_format: SourceFormat,
    openapi_opts: &openapi::CompileOptions,
    opts: &CompileOptions,
) -> CompileOutput {
    let mut diagnostics = Vec::new();
    let mut root = match parse_source(source, source_format) {
        Ok(value) => value,
        Err(message) => {
            return CompileOutput {
                tools: Vec::new(),
                diagnostics: vec![Diagnostic::error("parse_failed", message, None)],
            }
        }
    };
    let filter = match preset_filter(opts) {
        Ok(filter) => filter,
        Err(message) => {
            return CompileOutput {
                tools: Vec::new(),
                diagnostics: vec![Diagnostic::error("invalid_preset", message, None)],
            }
        }
    };

    ensure_graph_server(&mut root, openapi_opts.base_url.as_deref());

    let source = match serde_json::to_string(&root) {
        Ok(source) => source,
        Err(_) => {
            return CompileOutput {
                tools: Vec::new(),
                diagnostics: vec![Diagnostic::error(
                    "normalize_failed",
                    "could not encode normalized Microsoft Graph OpenAPI document",
                    None,
                )],
            }
        }
    };
    let mut openapi_opts = openapi_opts.clone();
    openapi_opts.filter = if filter.all_paths {
        opts.filter.clone()
    } else {
        filter.filter.merged(&opts.filter)
    };
    let mut out = openapi::compile(&source, SourceFormat::Json, &openapi_opts);
    if !filter.all_paths && out.tools.is_empty() {
        diagnostics.push(Diagnostic::warn(
            "no_matching_paths",
            "Microsoft Graph preset filters matched no OpenAPI paths",
            None,
        ));
    }
    diagnostics.append(&mut out.diagnostics);
    out.diagnostics = diagnostics;
    annotate_tools(&mut out.tools, &filter.ids);
    out
}

fn parse_source(source: &str, format: SourceFormat) -> Result<Value, String> {
    match format {
        SourceFormat::Json => serde_json::from_str(source).map_err(|e| e.to_string()),
        SourceFormat::Yaml => serde_yaml::from_str(source).map_err(|e| e.to_string()),
    }
}

fn preset_filter(opts: &CompileOptions) -> Result<PresetFilter, String> {
    let mut filter = PresetFilter::default();
    let ids: Vec<&str> = if opts.preset_ids.is_empty() {
        vec!["microsoft"]
    } else {
        opts.preset_ids.iter().map(String::as_str).collect()
    };
    for id in ids {
        let Some(entry) = registry::find(id) else {
            return Err(format!("unknown Microsoft Graph preset `{id}`"));
        };
        if entry.kind != RegistryKind::MicrosoftGraph {
            return Err(format!(
                "registry entry `{id}` is not a Microsoft Graph preset"
            ));
        }
        filter.ids.push(entry.id.to_string());
        if entry.id == "microsoft"
            || (entry.exact_paths.is_empty()
                && entry.path_prefixes.is_empty()
                && entry.tag_prefixes.is_empty())
        {
            filter.all_paths = true;
            continue;
        }
        for path in entry.exact_paths {
            if !filter.filter.exact_paths.iter().any(|p| p == path) {
                filter.filter.exact_paths.push((*path).to_string());
            }
        }
        for prefix in entry.path_prefixes {
            filter.filter.path_prefixes.push((*prefix).to_string());
        }
        for prefix in entry.tag_prefixes {
            filter.filter.tag_prefixes.push((*prefix).to_string());
        }
    }
    Ok(filter)
}

fn ensure_graph_server(root: &mut Value, base_url: Option<&str>) {
    let Some(obj) = root.as_object_mut() else {
        return;
    };
    if let Some(base_url) = base_url {
        obj.insert("servers".to_string(), json!([{ "url": base_url }]));
        return;
    }
    if !obj.contains_key("servers") {
        obj.insert(
            "servers".to_string(),
            json!([{ "url": "https://graph.microsoft.com/v1.0" }]),
        );
    }
}

fn annotate_tools(tools: &mut [Value], presets: &[String]) {
    for tool in tools {
        let Some(annotations) = tool.get_mut("annotations").and_then(Value::as_object_mut) else {
            continue;
        };
        annotations.insert(
            "sourceFormat".to_string(),
            Value::String("microsoft-graph".to_string()),
        );
        annotations.insert(
            "registryPresets".to_string(),
            Value::Array(presets.iter().cloned().map(Value::String).collect()),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn openapi_opts() -> openapi::CompileOptions {
        openapi::CompileOptions {
            integration: "microsoft".to_string(),
            owner: "org".to_string(),
            connection: "main".to_string(),
            auth: "bearer".to_string(),
            base_url: None,
            filter: OperationFilter::default(),
        }
    }

    #[test]
    fn filters_graph_openapi_by_registry_preset() {
        let source = r#"{
          "openapi": "3.0.3",
          "info": { "title": "Graph", "version": "v1.0" },
          "paths": {
            "/me/messages": {
              "get": {
                "operationId": "listMessages",
                "responses": { "200": { "description": "ok" } }
              }
            },
            "/me/events": {
              "get": {
                "operationId": "listEvents",
                "responses": { "200": { "description": "ok" } }
              }
            }
          }
        }"#;
        let opts = CompileOptions {
            preset_ids: vec!["mail".to_string()],
            filter: OperationFilter::default(),
        };

        let out = compile(source, SourceFormat::Json, &openapi_opts(), &opts);
        assert_eq!(out.diagnostics, Vec::new());
        assert_eq!(out.tools.len(), 1);
        assert_eq!(out.tools[0]["address"], "microsoft.org.main.listMessages");
        assert_eq!(
            out.tools[0]["binding"]["request"]["url_template"],
            "https://graph.microsoft.com/v1.0/me/messages"
        );
        assert_eq!(
            out.tools[0]["annotations"]["sourceFormat"],
            "microsoft-graph"
        );
    }

    #[test]
    fn malformed_source_is_a_parse_error() {
        let out = compile(
            "{",
            SourceFormat::Json,
            &openapi_opts(),
            &CompileOptions::default(),
        );
        assert_eq!(out.tools, Vec::<Value>::new());
        assert_eq!(out.diagnostics[0].code, "parse_failed");
    }

    #[test]
    fn unknown_preset_is_an_invalid_preset_error() {
        let out = compile(
            "{}",
            SourceFormat::Json,
            &openapi_opts(),
            &CompileOptions {
                preset_ids: vec!["not-a-preset".to_string()],
                filter: OperationFilter::default(),
            },
        );
        assert_eq!(out.tools, Vec::<Value>::new());
        assert_eq!(out.diagnostics[0].code, "invalid_preset");
    }
}
