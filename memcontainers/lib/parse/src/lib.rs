//! Shared parsers for adapter-backed tool generation.
//!
//! This crate owns the expensive, format-specific normalization work for `/svc/adapters`: OpenAPI
//! first, then Microsoft Graph and Google discovery, then GraphQL behind the same service contract. It is
//! intentionally `std + serde`; these formats are schema-heavy data languages, not kernel substrate.

pub mod google;
pub mod microsoft;
pub mod openapi;
pub mod registry;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Diagnostic {
    pub severity: String,
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub operation: Option<String>,
}

impl Diagnostic {
    pub fn warn(code: &str, message: impl Into<String>, operation: Option<String>) -> Self {
        Self {
            severity: "warning".to_string(),
            code: code.to_string(),
            message: message.into(),
            operation,
        }
    }

    pub fn error(code: &str, message: impl Into<String>, operation: Option<String>) -> Self {
        Self {
            severity: "error".to_string(),
            code: code.to_string(),
            message: message.into(),
            operation,
        }
    }
}
