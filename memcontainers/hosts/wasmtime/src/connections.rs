//! Host-side connection registry and HTTP credential injection.
//!
//! Guests may name a connection with `X-MC-Connection: integration.owner.name`, but they never see the
//! secret. The host removes that marker at the egress boundary and applies the configured credential
//! to the outbound request blob.

use std::collections::HashMap;

const CONNECTION_HEADER: &str = "X-MC-Connection";

#[derive(Debug, Clone, Default)]
pub struct ConnectionRegistry {
    entries: HashMap<String, ConnectionCredential>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionCredential {
    None,
    Bearer { token: String },
    Header { name: String, value: String },
    Query { name: String, value: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionError {
    InvalidReference,
    InvalidHeader,
    InvalidSecret,
    DuplicateConnection,
    UnknownConnection,
    DuplicateMarker,
    MalformedRequest,
    HeaderAlreadyPresent,
}

impl ConnectionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert(
        &mut self,
        reference: impl Into<String>,
        credential: ConnectionCredential,
    ) -> Result<(), ConnectionError> {
        let reference = reference.into();
        validate_reference(&reference)?;
        credential.validate()?;
        if self.entries.contains_key(&reference) {
            return Err(ConnectionError::DuplicateConnection);
        }
        self.entries.insert(reference, credential);
        Ok(())
    }

    pub fn with_bearer(
        mut self,
        reference: impl Into<String>,
        token: impl Into<String>,
    ) -> Result<Self, ConnectionError> {
        self.insert(
            reference,
            ConnectionCredential::Bearer {
                token: token.into(),
            },
        )?;
        Ok(self)
    }

    pub fn inject_http_request(&self, req: &[u8]) -> Result<Vec<u8>, ConnectionError> {
        let Some((head, body)) = split_head_body(req) else {
            return Err(ConnectionError::MalformedRequest);
        };
        let head = std::str::from_utf8(head).map_err(|_| ConnectionError::MalformedRequest)?;
        let mut lines = head.split('\n');
        let first = lines.next().ok_or(ConnectionError::MalformedRequest)?;
        let (method, url) = first
            .split_once(' ')
            .ok_or(ConnectionError::MalformedRequest)?;
        if method.is_empty() || url.is_empty() {
            return Err(ConnectionError::MalformedRequest);
        }

        let mut marker = None::<String>;
        let mut headers = Vec::<(String, String)>::new();
        for line in lines {
            if line.is_empty() {
                continue;
            }
            let (name, value) = line
                .split_once(':')
                .ok_or(ConnectionError::MalformedRequest)?;
            let name = name.trim().to_string();
            let value = value.trim().to_string();
            if name.eq_ignore_ascii_case(CONNECTION_HEADER) {
                if marker.replace(value).is_some() {
                    return Err(ConnectionError::DuplicateMarker);
                }
            } else {
                headers.push((name, value));
            }
        }

        let Some(reference) = marker else {
            return Ok(req.to_vec());
        };
        validate_reference(&reference)?;
        let credential = self
            .entries
            .get(&reference)
            .ok_or(ConnectionError::UnknownConnection)?;
        match credential {
            ConnectionCredential::None => {}
            ConnectionCredential::Bearer { token } => {
                add_header(&mut headers, "Authorization", &format!("Bearer {token}"))?;
            }
            ConnectionCredential::Header { name, value } => {
                add_header(&mut headers, name, value)?;
            }
            ConnectionCredential::Query { name, value } => {
                let url = append_query(url, name, value);
                return Ok(serialize_request(method, &url, &headers, body));
            }
        }
        Ok(serialize_request(method, url, &headers, body))
    }
}

impl ConnectionCredential {
    fn validate(&self) -> Result<(), ConnectionError> {
        match self {
            ConnectionCredential::None => Ok(()),
            ConnectionCredential::Bearer { token } => validate_secret(token),
            ConnectionCredential::Header { name, value } => {
                validate_header_name(name)?;
                validate_secret(value)
            }
            ConnectionCredential::Query { name, value } => {
                validate_query_name(name)?;
                validate_secret(value)
            }
        }
    }
}

fn split_head_body(req: &[u8]) -> Option<(&[u8], &[u8])> {
    let sep = req.windows(2).position(|w| w == b"\n\n")?;
    Some((&req[..sep], req.get(sep + 2..).unwrap_or(&[])))
}

fn validate_reference(reference: &str) -> Result<(), ConnectionError> {
    let mut parts = reference.split('.');
    let integration = parts.next().ok_or(ConnectionError::InvalidReference)?;
    let owner = parts.next().ok_or(ConnectionError::InvalidReference)?;
    let name = parts.next().ok_or(ConnectionError::InvalidReference)?;
    if parts.next().is_some()
        || !safe_segment(integration)
        || !matches!(owner, "org" | "user")
        || !safe_segment(name)
    {
        return Err(ConnectionError::InvalidReference);
    }
    Ok(())
}

fn safe_segment(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| matches!(b, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'_' | b'-'))
}

fn validate_header_name(name: &str) -> Result<(), ConnectionError> {
    if name.is_empty()
        || !name.bytes().all(|b| {
            matches!(
                b,
                b'!' | b'#'
                    | b'$'
                    | b'%'
                    | b'&'
                    | b'\''
                    | b'*'
                    | b'+'
                    | b'-'
                    | b'.'
                    | b'^'
                    | b'_'
                    | b'`'
                    | b'|'
                    | b'~'
                    | b'0'..=b'9'
                    | b'A'..=b'Z'
                    | b'a'..=b'z'
            )
        })
    {
        return Err(ConnectionError::InvalidHeader);
    }
    Ok(())
}

fn validate_query_name(name: &str) -> Result<(), ConnectionError> {
    if name.is_empty() || has_control(name) {
        return Err(ConnectionError::InvalidHeader);
    }
    Ok(())
}

fn validate_secret(value: &str) -> Result<(), ConnectionError> {
    if value.is_empty() || has_control(value) {
        return Err(ConnectionError::InvalidSecret);
    }
    Ok(())
}

fn has_control(value: &str) -> bool {
    value.bytes().any(|b| b < 0x20 || b == 0x7f)
}

fn add_header(
    headers: &mut Vec<(String, String)>,
    name: &str,
    value: &str,
) -> Result<(), ConnectionError> {
    validate_header_name(name)?;
    validate_secret(value)?;
    if headers.iter().any(|(k, _)| k.eq_ignore_ascii_case(name)) {
        return Err(ConnectionError::HeaderAlreadyPresent);
    }
    headers.push((name.to_string(), value.to_string()));
    Ok(())
}

fn serialize_request(
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: &[u8],
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(method.as_bytes());
    out.push(b' ');
    out.extend_from_slice(url.as_bytes());
    out.push(b'\n');
    for (name, value) in headers {
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(b": ");
        out.extend_from_slice(value.as_bytes());
        out.push(b'\n');
    }
    out.push(b'\n');
    out.extend_from_slice(body);
    out
}

fn append_query(url: &str, name: &str, value: &str) -> String {
    let (base, fragment) = match url.find('#') {
        Some(i) => (&url[..i], &url[i..]),
        None => (url, ""),
    };
    let sep = if base.contains('?') {
        if base.ends_with('?') || base.ends_with('&') {
            ""
        } else {
            "&"
        }
    } else {
        "?"
    };
    format!(
        "{}{}{}={}{}",
        base,
        sep,
        encode_component(name),
        encode_component(value),
        fragment
    )
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
