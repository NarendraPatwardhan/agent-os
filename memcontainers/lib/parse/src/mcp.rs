//! Remote MCP `tools/list` → tool-catalog normalization.
//!
//! Remote MCP tools are lifted as service-backed tool records. The address uses a sanitized stable id;
//! the real MCP name and upstream hints remain in annotations. `destructiveHint` maps to descriptive
//! `requires_approval` metadata; enforcement happens at the host egress boundary.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::normalize::{sanitize_segment_or, valid_segment};
use crate::openapi::OperationFilter;
use crate::Diagnostic;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompileOptions {
    pub integration: String,
    pub owner: String,
    pub connection: String,
    pub auth: String,
    pub endpoint: String,
    pub filter: OperationFilter,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CompileOutput {
    pub tools: Vec<Value>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Debug, Clone)]
struct McpTool {
    name: String,
    address_id: String,
    description: String,
    input_schema: Value,
    annotations: Value,
}

pub fn compile(source: &str, opts: &CompileOptions) -> CompileOutput {
    if let Err(message) = validate_options(opts) {
        return CompileOutput {
            tools: Vec::new(),
            diagnostics: vec![Diagnostic::error("invalid_options", message, None)],
        };
    }
    let root: Value = match serde_json::from_str(source) {
        Ok(value) => value,
        Err(e) => {
            return CompileOutput {
                tools: Vec::new(),
                diagnostics: vec![Diagnostic::error("parse_failed", e.to_string(), None)],
            }
        }
    };
    let Some(items) = tools_array(&root) else {
        return CompileOutput {
            tools: Vec::new(),
            diagnostics: vec![Diagnostic::error(
                "missing_tools",
                "MCP tools/list result has no tools array",
                None,
            )],
        };
    };

    let mut diagnostics = Vec::new();
    let mut tools = Vec::new();
    for item in items {
        let Some(name) = item.get("name").and_then(Value::as_str) else {
            diagnostics.push(Diagnostic::warn(
                "tool_skipped",
                "MCP tool had no name",
                None,
            ));
            continue;
        };
        tools.push(McpTool {
            name: name.to_string(),
            address_id: sanitize_segment_or(name, "tool"),
            description: item
                .get("description")
                .or_else(|| item.get("title"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            input_schema: item
                .get("inputSchema")
                .cloned()
                .unwrap_or_else(|| json!({"type":"object"})),
            annotations: item
                .get("annotations")
                .cloned()
                .unwrap_or_else(|| Value::Object(Map::new())),
        });
    }
    tools.retain(|tool| {
        let path = format!("/{}", tool.name);
        let mut tags = vec![tool.name.as_str(), tool.address_id.as_str()];
        if hint_bool(&tool.annotations, "destructiveHint") == Some(true) {
            tags.push("destructive");
        }
        if hint_bool(&tool.annotations, "readOnlyHint") == Some(true) {
            tags.push("readOnly");
        }
        opts.filter.matches_parts(&path, &tags)
    });
    assign_collision_suffixes(&mut tools);
    tools.sort_by(|a, b| {
        a.address_id
            .cmp(&b.address_id)
            .then_with(|| a.name.cmp(&b.name))
    });
    let records = tools
        .iter()
        .map(|tool| catalog_record(opts, tool))
        .collect();
    CompileOutput {
        tools: records,
        diagnostics,
    }
}

fn validate_options(opts: &CompileOptions) -> Result<(), &'static str> {
    for part in [&opts.integration, &opts.owner, &opts.connection] {
        if !valid_segment(part) {
            return Err("integration, owner, and connection must be address-safe segments");
        }
    }
    if opts.owner != "org" && opts.owner != "user" {
        return Err("owner must be org or user");
    }
    if opts.endpoint.trim().is_empty() {
        return Err("remote MCP compile requires endpoint");
    }
    Ok(())
}

fn tools_array(root: &Value) -> Option<&[Value]> {
    if let Some(items) = root.as_array() {
        return Some(items);
    }
    root.get("tools")
        .and_then(Value::as_array)
        .or_else(|| {
            root.get("result")
                .and_then(|r| r.get("tools"))
                .and_then(Value::as_array)
        })
        .map(Vec::as_slice)
}

fn catalog_record(opts: &CompileOptions, tool: &McpTool) -> Value {
    let destructive = hint_bool(&tool.annotations, "destructiveHint") == Some(true);
    let mut mcp = Map::new();
    mcp.insert("toolName".to_string(), Value::String(tool.name.clone()));
    if let Some(obj) = tool.annotations.as_object() {
        for key in [
            "title",
            "destructiveHint",
            "readOnlyHint",
            "idempotentHint",
            "openWorldHint",
        ] {
            if let Some(value) = obj.get(key) {
                mcp.insert(key.to_string(), value.clone());
            }
        }
    }

    let mut annotations = Map::new();
    annotations.insert(
        "adapter".to_string(),
        Value::String("mcp-remote".to_string()),
    );
    annotations.insert("mcp".to_string(), Value::Object(mcp));
    if destructive {
        annotations.insert("requires_approval".to_string(), Value::Bool(true));
        annotations.insert(
            "approval_description".to_string(),
            Value::String(
                tool.annotations
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or(&tool.name)
                    .to_string(),
            ),
        );
    }

    let mut record = Map::new();
    record.insert(
        "address".to_string(),
        Value::String(format!(
            "{}.{}.{}.{}",
            opts.integration, opts.owner, opts.connection, tool.address_id
        )),
    );
    record.insert(
        "description".to_string(),
        Value::String(if tool.description.is_empty() {
            format!("Remote MCP tool {}", tool.name)
        } else {
            tool.description.clone()
        }),
    );
    record.insert("input_schema".to_string(), tool.input_schema.clone());
    record.insert("annotations".to_string(), Value::Object(annotations));
    let mut request = Map::new();
    request.insert("endpoint".to_string(), Value::String(opts.endpoint.clone()));
    request.insert("tool_name".to_string(), Value::String(tool.name.clone()));
    record.insert(
        "binding".to_string(),
        json!({
            "type": "service",
            "service": "adapters",
            "op": "invoke",
            "adapter": "mcp-remote",
            "args": "json",
            "request": Value::Object(request)
        }),
    );
    Value::Object(record)
}

fn hint_bool(annotations: &Value, name: &str) -> Option<bool> {
    annotations.get(name).and_then(Value::as_bool)
}

fn assign_collision_suffixes(tools: &mut [McpTool]) {
    let mut counts = BTreeMap::<String, usize>::new();
    for tool in tools.iter() {
        *counts.entry(tool.address_id.clone()).or_default() += 1;
    }
    let mut seen = BTreeMap::<String, usize>::new();
    for tool in tools {
        if counts.get(&tool.address_id).copied().unwrap_or(0) <= 1 {
            continue;
        }
        let n = seen.entry(tool.address_id.clone()).or_default();
        *n += 1;
        tool.address_id = format!("{}-{}", tool.address_id, *n);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts() -> CompileOptions {
        CompileOptions {
            integration: "deepwiki".to_string(),
            owner: "org".to_string(),
            connection: "main".to_string(),
            auth: "none".to_string(),
            endpoint: "https://mcp.example.test/mcp".to_string(),
            filter: OperationFilter::default(),
        }
    }

    #[test]
    fn emits_remote_mcp_tools_and_destructive_metadata() {
        let source = r#"{"jsonrpc":"2.0","id":2,"result":{"tools":[
          {"name":"repo.search","description":"Search docs","inputSchema":{"type":"object","properties":{"q":{"type":"string"}}},
           "annotations":{"readOnlyHint":true}},
          {"name":"repo.delete","description":"Delete docs","inputSchema":{"type":"object"},
           "annotations":{"title":"Delete docs","destructiveHint":true}}
        ]}}"#;
        let out = compile(source, &opts());
        assert_eq!(out.diagnostics, Vec::new());
        assert_eq!(out.tools.len(), 2);
        let text = serde_json::to_string(&out.tools).unwrap();
        assert!(text.contains("\"address\":\"deepwiki.org.main.repo-search\""));
        assert!(text.contains("\"toolName\":\"repo.delete\""));
        assert!(text.contains("\"requires_approval\":true"));
        assert!(text.contains("\"approval_description\":\"Delete docs\""));
    }

    #[test]
    fn rejects_missing_tools() {
        let out = compile(r#"{"result":{}}"#, &opts());
        assert_eq!(out.tools, Vec::<Value>::new());
        assert_eq!(out.diagnostics[0].code, "missing_tools");
    }
}
