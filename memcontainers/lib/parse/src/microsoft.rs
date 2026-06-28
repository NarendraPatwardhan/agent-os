//! Microsoft Graph workload normalization.
//!
//! Microsoft Graph publishes one large OpenAPI document. The registry carries smaller workload
//! presets as path filters, so this module trims the source document to the requested presets and then
//! feeds the ordinary OpenAPI compiler. Tool bindings still invoke the OpenAPI adapter path; the
//! Microsoft-specific work is deterministic source selection, not a separate runtime.

use std::collections::BTreeSet;

use serde_json::{json, Map, Value};

use crate::openapi::{self, CompileOutput, SourceFormat};
use crate::registry::{self, RegistryKind};
use crate::Diagnostic;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CompileOptions {
    pub preset_ids: Vec<String>,
}

#[derive(Default)]
struct PresetFilter {
    all_paths: bool,
    ids: Vec<String>,
    exact_paths: BTreeSet<String>,
    path_prefixes: Vec<String>,
    tag_prefixes: Vec<String>,
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
    if !filter.all_paths {
        filter_paths(&mut root, &filter, &mut diagnostics);
    }

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
    let mut out = openapi::compile(&source, SourceFormat::Json, openapi_opts);
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
            filter.exact_paths.insert((*path).to_string());
        }
        for prefix in entry.path_prefixes {
            filter.path_prefixes.push((*prefix).to_string());
        }
        for prefix in entry.tag_prefixes {
            filter.tag_prefixes.push((*prefix).to_string());
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

fn filter_paths(root: &mut Value, filter: &PresetFilter, diagnostics: &mut Vec<Diagnostic>) {
    let Some(paths) = root.get_mut("paths").and_then(Value::as_object_mut) else {
        return;
    };
    let mut kept = Map::new();
    let old = std::mem::take(paths);
    for (path, item) in old {
        if filter.matches_path(&path) {
            kept.insert(path, item);
            continue;
        }
        if let Some(item) = filter_tagged_operations(&item, filter) {
            kept.insert(path, item);
        }
    }
    if kept.is_empty() {
        diagnostics.push(Diagnostic::warn(
            "no_matching_paths",
            "Microsoft Graph preset filters matched no OpenAPI paths",
            None,
        ));
    }
    *paths = kept;
}

fn filter_tagged_operations(item: &Value, filter: &PresetFilter) -> Option<Value> {
    if filter.tag_prefixes.is_empty() {
        return None;
    }
    let obj = item.as_object()?;
    let mut kept = Map::new();
    if let Some(parameters) = obj.get("parameters") {
        kept.insert("parameters".to_string(), parameters.clone());
    }
    for method in [
        "get", "put", "post", "delete", "options", "head", "patch", "trace",
    ] {
        let Some(op) = obj.get(method) else {
            continue;
        };
        if filter.matches_tags(op) {
            kept.insert(method.to_string(), op.clone());
        }
    }
    kept.keys()
        .any(|key| key != "parameters")
        .then_some(Value::Object(kept))
}

impl PresetFilter {
    fn matches_path(&self, path: &str) -> bool {
        self.exact_paths.contains(path)
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

fn path_has_prefix(path: &str, prefix: &str) -> bool {
    if path == prefix {
        return true;
    }
    let Some(rest) = path.strip_prefix(prefix) else {
        return false;
    };
    rest.starts_with('/') || rest.starts_with('(')
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
