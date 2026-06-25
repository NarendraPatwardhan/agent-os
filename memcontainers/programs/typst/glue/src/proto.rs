//! The typst-svc wire protocol: a JSON request and a length-framed binary response.
//!
//! A request is small JSON. A response is `[u32 LE header_len][header JSON][body…]`: the header
//! carries `ok` + structured diagnostics (binary-safe — diagnostic text may contain newlines and the
//! PDF body is binary), and the body is the PDF bytes (empty on a compile error). Transport status 0 =
//! the call completed (read `ok`); a nonzero transport status (EIO) means the service died mid-stream.

use serde::{Deserialize, Serialize};

/// The protocol version, echoed in every request; the service rejects a mismatch.
pub const PROTO_VERSION: u32 = 1;

/// A request to the typst service. Exactly one of `source` (inline `.typ` text) or `main` (an absolute
/// VFS path to a `.typ`) must be set. `root` (the import/image resolution root) defaults to `main`'s
/// parent, or `/` for inline.
#[derive(Deserialize)]
pub struct Request {
    pub v: u32,
    pub op: String,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub main: Option<String>,
    #[serde(default)]
    pub root: Option<String>,
}

/// One compile diagnostic (a typst error or warning), with its source location resolved where possible.
#[derive(Serialize, Deserialize)]
pub struct Diagnostic {
    pub severity: String, // "error" | "warning"
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub col: Option<usize>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hints: Vec<String>,
}

/// The response header (the JSON before the binary body). `ok=false` ⇒ a compile error, no body.
#[derive(Serialize, Deserialize)]
pub struct Header {
    pub ok: bool,
    pub diagnostics: Vec<Diagnostic>,
}

impl Header {
    /// A failed header with a single synthetic error and no source location (bad request, missing
    /// fonts, etc. — failures that have no typst span).
    pub fn fail(message: &str) -> Header {
        Header {
            ok: false,
            diagnostics: vec![Diagnostic {
                severity: "error".to_string(),
                message: message.to_string(),
                file: None,
                line: None,
                col: None,
                hints: Vec::new(),
            }],
        }
    }
}

/// Build a response frame: `[u32 LE header_len][header JSON][body…]`.
pub fn frame(header: &Header, body: &[u8]) -> Vec<u8> {
    let hjson = serde_json::to_vec(header)
        .unwrap_or_else(|_| br#"{"ok":false,"diagnostics":[]}"#.to_vec());
    let mut out = Vec::with_capacity(4 + hjson.len() + body.len());
    out.extend_from_slice(&(hjson.len() as u32).to_le_bytes());
    out.extend_from_slice(&hjson);
    out.extend_from_slice(body);
    out
}

/// Split a received frame back into `(header, body)`. `None` if it is short or the header is not valid
/// JSON. Used by the CLI client (the Luau library does the same decode in Lua).
pub fn unframe(data: &[u8]) -> Option<(Header, &[u8])> {
    if data.len() < 4 {
        return None;
    }
    let hlen = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let hjson = data.get(4..4 + hlen)?;
    let body = &data[4 + hlen..];
    let header: Header = serde_json::from_slice(hjson).ok()?;
    Some((header, body))
}
