//! GraphQL introspection → tool-catalog normalization.
//!
//! The compiler consumes a standard introspection JSON result and emits one service-backed tool per
//! root field: `query.<field>` or `mutation.<field>`. Calls keep the pre-built operation document in
//! the catalog binding and supply only JSON variables at runtime. Mutations keep descriptive
//! destructive metadata; the host egress boundary enforces approval before credentials are spliced.

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
struct RootField {
    operation_type: &'static str,
    name: String,
    description: String,
    args: Vec<FieldArg>,
}

#[derive(Debug, Clone)]
struct FieldArg {
    name: String,
    description: String,
    type_ref: Value,
}

pub const INTROSPECTION_QUERY: &str = r#"query AgentOSGraphQLIntrospection {
  __schema {
    queryType { name }
    mutationType { name }
    types {
      kind
      name
      fields {
        name
        description
        args {
          name
          description
          type { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }
        }
      }
    }
  }
}"#;

pub fn compile(source: &str, opts: &CompileOptions) -> CompileOutput {
    let mut diagnostics = Vec::new();
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
    let Some(schema) = root
        .get("data")
        .and_then(|data| data.get("__schema"))
        .or_else(|| root.get("__schema"))
    else {
        return CompileOutput {
            tools: Vec::new(),
            diagnostics: vec![Diagnostic::error(
                "missing_schema",
                "GraphQL introspection result has no __schema object",
                None,
            )],
        };
    };

    let mut fields = Vec::new();
    collect_root_fields(schema, "query", "queryType", &mut fields, &mut diagnostics);
    collect_root_fields(
        schema,
        "mutation",
        "mutationType",
        &mut fields,
        &mut diagnostics,
    );
    fields.retain(|field| {
        let path = format!("/{}/{}", field.operation_type, field.name);
        let typed_name = format!("{}.{}", field.operation_type, field.name);
        opts.filter
            .matches_parts(&path, &[field.operation_type, typed_name.as_str()])
    });
    fields.sort_by(|a, b| {
        tool_address(opts, a)
            .cmp(&tool_address(opts, b))
            .then_with(|| a.name.cmp(&b.name))
    });

    let tools = fields
        .into_iter()
        .map(|field| catalog_record(opts, &field))
        .collect();
    CompileOutput { tools, diagnostics }
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
        return Err("GraphQL compile requires endpoint");
    }
    Ok(())
}

fn collect_root_fields(
    schema: &Value,
    operation_type: &'static str,
    type_key: &str,
    out: &mut Vec<RootField>,
    diagnostics: &mut Vec<Diagnostic>,
) {
    let Some(type_name) = schema
        .get(type_key)
        .and_then(|t| t.get("name"))
        .and_then(Value::as_str)
    else {
        return;
    };
    let Some(root_type) = schema
        .get("types")
        .and_then(Value::as_array)
        .and_then(|types| {
            types
                .iter()
                .find(|ty| ty.get("name").and_then(Value::as_str) == Some(type_name))
        })
    else {
        diagnostics.push(Diagnostic::warn(
            "missing_root_type",
            format!("GraphQL root type `{type_name}` was not present in introspection types"),
            Some(operation_type.to_string()),
        ));
        return;
    };
    let Some(fields) = root_type.get("fields").and_then(Value::as_array) else {
        return;
    };
    for field in fields {
        let Some(name) = field.get("name").and_then(Value::as_str) else {
            continue;
        };
        let args = field
            .get("args")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|arg| {
                        Some(FieldArg {
                            name: arg.get("name")?.as_str()?.to_string(),
                            description: arg
                                .get("description")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                            type_ref: arg.get("type")?.clone(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.push(RootField {
            operation_type,
            name: name.to_string(),
            description: field
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            args,
        });
    }
}

fn catalog_record(opts: &CompileOptions, field: &RootField) -> Value {
    let document = operation_document(field);
    let operation_name = operation_name(field);
    let mut annotations = Map::new();
    annotations.insert("adapter".to_string(), Value::String("graphql".to_string()));
    annotations.insert(
        "operationType".to_string(),
        Value::String(field.operation_type.to_string()),
    );
    annotations.insert("field".to_string(), Value::String(field.name.clone()));
    if field.operation_type == "mutation" {
        annotations.insert("requires_approval".to_string(), Value::Bool(true));
        annotations.insert(
            "approval_description".to_string(),
            Value::String(format!("mutation {}", field.name)),
        );
    }

    let mut record = Map::new();
    record.insert(
        "address".to_string(),
        Value::String(tool_address(opts, field)),
    );
    record.insert(
        "description".to_string(),
        Value::String(if field.description.is_empty() {
            format!("GraphQL {} {}", field.operation_type, field.name)
        } else {
            field.description.clone()
        }),
    );
    let schema = input_schema(&field.args);
    if !schema
        .get("properties")
        .and_then(Value::as_object)
        .map(Map::is_empty)
        .unwrap_or(true)
    {
        record.insert("input_schema".to_string(), schema);
    }
    record.insert("annotations".to_string(), Value::Object(annotations));
    let mut request = Map::new();
    request.insert("endpoint".to_string(), Value::String(opts.endpoint.clone()));
    request.insert("document".to_string(), Value::String(document));
    request.insert("operationName".to_string(), Value::String(operation_name));
    record.insert(
        "binding".to_string(),
        json!({
            "type": "service",
            "service": "adapters",
            "op": "invoke",
            "adapter": "graphql",
            "args": "json",
            "request": Value::Object(request)
        }),
    );
    Value::Object(record)
}

fn input_schema(args: &[FieldArg]) -> Value {
    let mut props = Map::new();
    let mut required = Vec::new();
    for arg in args {
        props.insert(arg.name.clone(), json_schema_for_type(&arg.type_ref));
        if !arg.description.is_empty() {
            if let Some(obj) = props.get_mut(&arg.name).and_then(Value::as_object_mut) {
                obj.insert(
                    "description".to_string(),
                    Value::String(arg.description.clone()),
                );
            }
        }
        if type_kind(&arg.type_ref) == Some("NON_NULL") {
            required.push(Value::String(arg.name.clone()));
        }
    }
    let mut root = Map::new();
    root.insert("type".to_string(), Value::String("object".to_string()));
    root.insert("additionalProperties".to_string(), Value::Bool(false));
    root.insert("properties".to_string(), Value::Object(props));
    if !required.is_empty() {
        root.insert("required".to_string(), Value::Array(required));
    }
    Value::Object(root)
}

fn json_schema_for_type(type_ref: &Value) -> Value {
    let nullable = if type_kind(type_ref) == Some("NON_NULL") {
        type_ref.get("ofType").unwrap_or(type_ref)
    } else {
        type_ref
    };
    match type_kind(nullable).unwrap_or("") {
        "LIST" => json!({
            "type": "array",
            "items": nullable
                .get("ofType")
                .map(json_schema_for_type)
                .unwrap_or_else(|| json!({})),
        }),
        "SCALAR" => match nullable.get("name").and_then(Value::as_str).unwrap_or("") {
            "Int" => json!({"type":"integer"}),
            "Float" => json!({"type":"number"}),
            "Boolean" => json!({"type":"boolean"}),
            "ID" | "String" => json!({"type":"string"}),
            _ => json!({}),
        },
        "ENUM" => json!({"type":"string"}),
        "INPUT_OBJECT" => json!({"type":"object"}),
        _ => json!({}),
    }
}

fn operation_document(field: &RootField) -> String {
    let op_name = operation_name(field);
    let vars: Vec<String> = field
        .args
        .iter()
        .filter_map(|arg| Some(format!("${}: {}", arg.name, graphql_type(&arg.type_ref)?)))
        .collect();
    let call_args: Vec<String> = field
        .args
        .iter()
        .map(|arg| format!("{}: ${}", arg.name, arg.name))
        .collect();
    let vars = if vars.is_empty() {
        String::new()
    } else {
        format!("({})", vars.join(", "))
    };
    let call_args = if call_args.is_empty() {
        String::new()
    } else {
        format!("({})", call_args.join(", "))
    };
    format!(
        "{} {}{} {{ {}{} }}",
        field.operation_type, op_name, vars, field.name, call_args
    )
}

fn operation_name(field: &RootField) -> String {
    format!(
        "{}_{}",
        field.operation_type,
        sanitize_graphql_name(&field.name)
    )
}

fn graphql_type(type_ref: &Value) -> Option<String> {
    match type_kind(type_ref)? {
        "NON_NULL" => Some(format!("{}!", graphql_type(type_ref.get("ofType")?)?)),
        "LIST" => Some(format!("[{}]", graphql_type(type_ref.get("ofType")?)?)),
        _ => type_ref
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string),
    }
}

fn type_kind(type_ref: &Value) -> Option<&str> {
    type_ref.get("kind").and_then(Value::as_str)
}

fn tool_address(opts: &CompileOptions, field: &RootField) -> String {
    format!(
        "{}.{}.{}.{}",
        opts.integration,
        opts.owner,
        opts.connection,
        tool_tail(field)
    )
}

fn tool_tail(field: &RootField) -> String {
    format!(
        "{}.{}",
        field.operation_type,
        sanitize_segment_or(&field.name, "field")
    )
}

fn sanitize_graphql_name(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() || out.as_bytes()[0].is_ascii_digit() {
        out.insert(0, '_');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts() -> CompileOptions {
        CompileOptions {
            integration: "gql".to_string(),
            owner: "org".to_string(),
            connection: "main".to_string(),
            auth: "none".to_string(),
            endpoint: "https://example.test/graphql".to_string(),
            filter: OperationFilter::default(),
        }
    }

    #[test]
    fn emits_query_and_mutation_tools() {
        let source = r#"{"data":{"__schema":{
          "queryType":{"name":"Query"},
          "mutationType":{"name":"Mutation"},
          "types":[
            {"kind":"OBJECT","name":"Query","fields":[
              {"name":"viewer","description":"Viewer by id","args":[
                {"name":"id","description":"User id","type":{"kind":"NON_NULL","ofType":{"kind":"SCALAR","name":"ID"}}}
              ]}
            ]},
            {"kind":"OBJECT","name":"Mutation","fields":[
              {"name":"updateName","description":"Update name","args":[
                {"name":"name","type":{"kind":"SCALAR","name":"String"}}
              ]}
            ]}
          ]}}}"#;
        let out = compile(source, &opts());
        assert_eq!(out.diagnostics, Vec::new());
        assert_eq!(out.tools.len(), 2);
        let text = serde_json::to_string(&out.tools).unwrap();
        assert!(text.contains("\"address\":\"gql.org.main.mutation.updateName\""));
        assert!(text.contains("\"requires_approval\":true"));
        assert!(text.contains("query_viewer"));
        assert!(text.contains("$id: ID!"));
    }

    #[test]
    fn rejects_missing_schema() {
        let out = compile("{}", &opts());
        assert_eq!(out.tools, Vec::<Value>::new());
        assert_eq!(out.diagnostics[0].code, "missing_schema");
    }
}
