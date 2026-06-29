use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::{json, Map, Value};

use crate::Diagnostic;

#[derive(Debug, Clone, Serialize)]
struct BundleIndex {
    generation: u64,
    tools: Vec<IndexTool>,
}

#[derive(Debug, Clone, Serialize)]
struct IndexTool {
    address: String,
    integration: String,
    description: String,
    sha: String,
}

pub fn sharded_bundle(
    integration: &str,
    generation: u64,
    tools: Vec<Value>,
    diagnostics: Vec<Diagnostic>,
) -> Result<Vec<u8>, BundleError> {
    Ok(frame_entries(bundle_entries(
        integration,
        generation,
        tools,
        diagnostics,
    )?))
}

pub fn bundle_entries(
    integration: &str,
    generation: u64,
    tools: Vec<Value>,
    diagnostics: Vec<Diagnostic>,
) -> Result<BTreeMap<String, Vec<u8>>, BundleError> {
    let mut index_tools = Vec::new();
    let mut entries = BTreeMap::<String, Vec<u8>>::new();
    for record in tools {
        let Some(obj) = record.as_object() else {
            return Err(BundleError::InvalidCatalog(
                "tool record was not an object".to_string(),
            ));
        };
        let address = obj
            .get("address")
            .and_then(Value::as_str)
            .ok_or_else(|| BundleError::InvalidCatalog("tool record missing address".to_string()))?
            .to_string();
        let description = obj
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let mut shard = Map::new();
        for key in ["input_schema", "output_schema", "annotations", "binding"] {
            if let Some(value) = obj.get(key) {
                shard.insert(key.to_string(), value.clone());
            }
        }
        let mut shard = Value::Object(shard);
        strip_connection_ref(&mut shard);
        let bytes = serde_json::to_vec(&shard).map_err(|e| BundleError::Encode(e.to_string()))?;
        let sha = pkgcore::sha256_hex(&bytes);
        entries
            .entry(format!("records/{sha}"))
            .or_insert_with(|| bytes.clone());
        index_tools.push(IndexTool {
            address,
            integration: integration.to_string(),
            description,
            sha,
        });
    }
    index_tools.sort_by(|a, b| a.address.cmp(&b.address));
    let index = BundleIndex {
        generation,
        tools: index_tools,
    };
    let index_bytes = serde_json::to_vec(&index).map_err(|e| BundleError::Encode(e.to_string()))?;
    let index_digest = pkgcore::sha256_hex(&index_bytes);
    entries.insert("index.json".to_string(), index_bytes);
    entries.insert(
        "index.sha256".to_string(),
        format!("{index_digest}\n").into_bytes(),
    );
    if !diagnostics.is_empty() {
        entries.insert(
            "diagnostics.json".to_string(),
            serde_json::to_vec(&diagnostics).map_err(|e| BundleError::Encode(e.to_string()))?,
        );
    }
    Ok(entries)
}

pub fn error_bundle(code: &str, message: String) -> Vec<u8> {
    let mut entries = BTreeMap::new();
    entries.insert(
        "error.json".to_string(),
        serde_json::to_vec(&json!({
            "error": {
                "code": code,
                "message": message,
            }
        }))
        .expect("error serializes"),
    );
    frame_entries(entries)
}

pub fn frame_entries(entries: BTreeMap<String, Vec<u8>>) -> Vec<u8> {
    let mut out = Vec::new();
    push_u32(&mut out, entries.len() as u32);
    for (path, bytes) in entries {
        push_u32(&mut out, path.len() as u32);
        push_u32(&mut out, bytes.len() as u32);
        out.extend_from_slice(path.as_bytes());
        out.extend_from_slice(&bytes);
    }
    out
}

fn strip_connection_ref(value: &mut Value) {
    match value {
        Value::Object(obj) => {
            obj.remove("connection_ref");
            for child in obj.values_mut() {
                strip_connection_ref(child);
            }
        }
        Value::Array(items) => {
            for item in items {
                strip_connection_ref(item);
            }
        }
        _ => {}
    }
}

fn push_u32(out: &mut Vec<u8>, n: u32) {
    out.extend_from_slice(&n.to_le_bytes());
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BundleError {
    InvalidCatalog(String),
    Encode(String),
}

impl BundleError {
    pub fn code(&self) -> &'static str {
        match self {
            BundleError::InvalidCatalog(_) => "invalid_catalog",
            BundleError::Encode(_) => "encode_failed",
        }
    }

    pub fn message(&self) -> String {
        match self {
            BundleError::InvalidCatalog(message) | BundleError::Encode(message) => message.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emits_complete_sharded_tree() {
        let entries = bundle_entries(
            "github",
            7,
            vec![json!({
                "address": "github.org.main.issues-create",
                "description": "Create an issue",
                "binding": {
                    "type": "service",
                    "service": "adapters",
                    "op": "invoke",
                    "adapter": "openapi",
                    "request": {
                        "method": "POST",
                        "connection_ref": {"auth": "bearer"}
                    }
                }
            })],
            Vec::new(),
        )
        .unwrap();
        let index = String::from_utf8(entries.get("index.json").unwrap().clone()).unwrap();
        assert!(index.contains("\"generation\":7"));
        let digest = String::from_utf8(entries.get("index.sha256").unwrap().clone()).unwrap();
        assert_eq!(digest.trim().len(), 64);
        let sha = serde_json::from_slice::<Value>(entries.get("index.json").unwrap()).unwrap()
            ["tools"][0]["sha"]
            .as_str()
            .unwrap()
            .to_string();
        let shard =
            String::from_utf8(entries.get(&format!("records/{sha}")).unwrap().clone()).unwrap();
        assert!(!shard.contains("connection_ref"));
        assert!(!shard.contains("\"address\""));
    }
}
