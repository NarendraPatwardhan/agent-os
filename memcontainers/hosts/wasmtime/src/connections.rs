//! Host-side connection registry and HTTP credential injection.
//!
//! Guests may name a connection with `X-MC-Connection: integration.owner.name`, but they never see the
//! secret. The host removes that marker at the egress boundary and applies the configured credential
//! to the outbound request blob.

use std::collections::HashMap;

const CONNECTION_HEADER: &str = "X-MC-Connection";

/// Derive a connection's credential-egress origins from the curated registry when the embedder omitted
/// them, so a connection is just `{ref, auth}` (the wasmtime/Elixir-host peer of the JS
/// `deriveConnectionOrigins`). The registry (`mc_parse::registry`) is the single source for both hosts;
/// curated `servers` (our constant) are used first, then an `endpoint`'s origin. Curated data only —
/// never a live spec — so a tampered upstream cannot redirect the credential. Returns empty when the
/// integration is not curated, which leaves the splice failing closed (never widened).
pub fn derive_connection_origins(reference: &str) -> Vec<String> {
    let integration = reference.split('.').next().unwrap_or("");
    if integration.is_empty() {
        return Vec::new();
    }
    for id in [
        integration.to_string(),
        format!("{integration}-rest"),
        format!("{integration}-openapi"),
    ] {
        let Some(entry) = mc_parse::registry::find(&id) else {
            continue;
        };
        if !entry.servers.is_empty() {
            return entry.servers.iter().map(|s| s.to_string()).collect();
        }
        if let Some(endpoint) = entry.endpoint {
            if let Some(origin) = origin_of(endpoint) {
                return vec![origin];
            }
        }
        return Vec::new();
    }
    Vec::new()
}

/// `scheme://host[:port]` of an absolute URL — the egress origin. Matches `new URL(x).origin` for the
/// `http`/`https` endpoints the registry carries (no path, no trailing slash).
fn origin_of(url: &str) -> Option<String> {
    let scheme_end = url.find("://")?;
    let after = &url[scheme_end + 3..];
    let host_end = after.find('/').unwrap_or(after.len());
    if host_end == 0 {
        return None;
    }
    Some(format!("{}://{}", &url[..scheme_end], &after[..host_end]))
}

#[derive(Debug, Clone, Default)]
pub struct ConnectionRegistry {
    entries: HashMap<String, ConnectionEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ConnectionEntry {
    credential: ConnectionCredential,
    origins: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedRequest {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedConnectionRequest {
    pub connection: String,
    pub method: String,
    pub url: String,
    pub origin: String,
    pub body: Vec<u8>,
    pub policy_address: String,
    parsed: ParsedRequest,
    entry: ConnectionEntry,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreparedHttpRequest {
    Unmarked(Vec<u8>),
    Connection(PreparedConnectionRequest),
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
    InvalidOrigin,
    InvalidSecret,
    MissingOrigin,
    DuplicateConnection,
    UnknownConnection,
    OriginNotAllowed,
    DuplicateMarker,
    MalformedRequest,
    HeaderAlreadyPresent,
}

impl ConnectionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert<I, S>(
        &mut self,
        reference: impl Into<String>,
        credential: ConnectionCredential,
        origins: I,
    ) -> Result<(), ConnectionError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let reference = reference.into();
        validate_reference(&reference)?;
        credential.validate()?;
        let origins = normalize_origins(origins)?;
        if self.entries.contains_key(&reference) {
            return Err(ConnectionError::DuplicateConnection);
        }
        self.entries.insert(
            reference,
            ConnectionEntry {
                credential,
                origins,
            },
        );
        Ok(())
    }

    pub fn with_bearer<I, S>(
        mut self,
        reference: impl Into<String>,
        token: impl Into<String>,
        origins: I,
    ) -> Result<Self, ConnectionError>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.insert(
            reference,
            ConnectionCredential::Bearer {
                token: token.into(),
            },
            origins,
        )?;
        Ok(self)
    }

    /// The egress facet of a connection — its credential + allowed origins — for a reference. This is the
    /// single source of a connection's credential: the catalog/discovery path reads it from here (it is
    /// not duplicated onto the inject-time `CatalogConnection`), so a live discovery authenticates with the
    /// same secret the runtime splice uses, and can origin-check against the same allowlist.
    pub fn egress(&self, reference: &str) -> Option<(ConnectionCredential, Vec<String>)> {
        self.entries
            .get(reference)
            .map(|entry| (entry.credential.clone(), entry.origins.clone()))
    }

    pub fn inject_http_request(&self, req: &[u8]) -> Result<Vec<u8>, ConnectionError> {
        match self.prepare_http_request(req)? {
            PreparedHttpRequest::Unmarked(req) => Ok(req),
            PreparedHttpRequest::Connection(req) => req.inject(),
        }
    }

    pub fn prepare_http_request(&self, req: &[u8]) -> Result<PreparedHttpRequest, ConnectionError> {
        let parsed = parse_blob(req)?;
        let mut marker = None::<String>;
        for (name, value) in &parsed.headers {
            if name.eq_ignore_ascii_case(CONNECTION_HEADER)
                && marker.replace(value.clone()).is_some()
            {
                return Err(ConnectionError::DuplicateMarker);
            }
        }
        let Some(reference) = marker else {
            return Ok(PreparedHttpRequest::Unmarked(req.to_vec()));
        };
        validate_reference(&reference)?;
        let entry = self
            .entries
            .get(&reference)
            .ok_or(ConnectionError::UnknownConnection)?;
        let origin = request_origin(&parsed.url)?;
        // A connection marker authorizes egress ONLY to the connection's declared origins. Empty origins
        // authorize nothing (fail-closed) — a public (auth:none) tool must still name where it may reach,
        // and an unrestricted egress belongs on the ordinary network path, not behind a connection marker.
        // (Previously auth:none + empty origins slipped past this check, an unrestricted marked channel.)
        // `origin_allowed` is the same primitive live discovery uses, so the splice and discovery agree.
        if !origin_allowed(&entry.origins, &parsed.url) {
            return Err(ConnectionError::OriginNotAllowed);
        }
        Ok(PreparedHttpRequest::Connection(PreparedConnectionRequest {
            connection: reference.clone(),
            method: parsed.method.clone(),
            url: parsed.url.clone(),
            origin,
            body: parsed.body.clone(),
            policy_address: format!("{reference}.*"),
            parsed,
            entry: entry.clone(),
        }))
    }
}

impl PreparedConnectionRequest {
    pub fn inject(&self) -> Result<Vec<u8>, ConnectionError> {
        let mut headers = self
            .parsed
            .headers
            .iter()
            .filter(|(name, _)| !name.eq_ignore_ascii_case(CONNECTION_HEADER))
            .cloned()
            .collect::<Vec<_>>();
        match &self.entry.credential {
            ConnectionCredential::None => {}
            ConnectionCredential::Bearer { token } => {
                add_header(&mut headers, "Authorization", &format!("Bearer {token}"))?;
            }
            ConnectionCredential::Header { name, value } => {
                add_header(&mut headers, name, value)?;
            }
            ConnectionCredential::Query { name, value } => {
                let url = append_query(&self.parsed.url, name, value);
                return Ok(serialize_request(
                    &self.parsed.method,
                    &url,
                    &headers,
                    &self.parsed.body,
                ));
            }
        }
        Ok(serialize_request(
            &self.parsed.method,
            &self.parsed.url,
            &headers,
            &self.parsed.body,
        ))
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

fn normalize_origins<I, S>(origins: I) -> Result<Vec<String>, ConnectionError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut out = Vec::new();
    for raw in origins {
        let origin = normalize_allowed_origin(&raw.into())?;
        if !out.contains(&origin) {
            out.push(origin);
        }
    }
    // Every connection authorizes egress only to its declared origins, so an empty set is invalid (the
    // connection could never egress) — reject it up front rather than silently fail-closed at the splice.
    // This holds for auth:none too: an unrestricted public fetch belongs on the ordinary network path.
    if out.is_empty() {
        return Err(ConnectionError::MissingOrigin);
    }
    Ok(out)
}

fn split_head_body(req: &[u8]) -> Option<(&[u8], &[u8])> {
    let sep = req.windows(2).position(|w| w == b"\n\n")?;
    Some((&req[..sep], req.get(sep + 2..).unwrap_or(&[])))
}

fn parse_blob(req: &[u8]) -> Result<ParsedRequest, ConnectionError> {
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

    let mut headers = Vec::<(String, String)>::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let (name, value) = line
            .split_once(':')
            .ok_or(ConnectionError::MalformedRequest)?;
        headers.push((name.trim().to_string(), value.trim().to_string()));
    }

    Ok(ParsedRequest {
        method: method.to_string(),
        url: url.to_string(),
        headers,
        body: body.to_vec(),
    })
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

fn normalize_allowed_origin(value: &str) -> Result<String, ConnectionError> {
    let origin = parse_origin(value)?;
    if !matches!(origin.suffix, "" | "/") {
        return Err(ConnectionError::InvalidOrigin);
    }
    Ok(origin.value)
}

fn request_origin(value: &str) -> Result<String, ConnectionError> {
    Ok(parse_origin(value)?.value)
}

/// Canonical origin authorization — the single definition of "this URL may receive this connection's
/// credential," shared by the egress splice and live discovery (`catalog.rs`). Both `url` and every
/// `allowed` origin are normalized through `parse_origin` (scheme/host lowercased, default port folded), so
/// a non-canonical allowed origin (`:443`, an uppercase host) still matches and the two paths can never
/// diverge. A malformed or non-`http(s)` `url` is not allowed (fail closed).
pub fn origin_allowed(allowed: &[String], url: &str) -> bool {
    let Ok(origin) = request_origin(url) else {
        return false;
    };
    allowed
        .iter()
        .any(|candidate| request_origin(candidate).map(|c| c == origin).unwrap_or(false))
}

struct ParsedOrigin<'a> {
    value: String,
    suffix: &'a str,
}

fn parse_origin(value: &str) -> Result<ParsedOrigin<'_>, ConnectionError> {
    if value.is_empty() || has_control(value) || value.bytes().any(|b| b.is_ascii_whitespace()) {
        return Err(ConnectionError::InvalidOrigin);
    }
    let (scheme_raw, rest) = value
        .split_once("://")
        .ok_or(ConnectionError::InvalidOrigin)?;
    let scheme = scheme_raw.to_ascii_lowercase();
    if !matches!(scheme.as_str(), "http" | "https") {
        return Err(ConnectionError::InvalidOrigin);
    }
    let authority_end = rest
        .find(|c| matches!(c, '/' | '?' | '#'))
        .unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let suffix = &rest[authority_end..];
    let authority = normalize_authority(authority, &scheme)?;
    Ok(ParsedOrigin {
        value: format!("{scheme}://{authority}"),
        suffix,
    })
}

fn normalize_authority(authority: &str, scheme: &str) -> Result<String, ConnectionError> {
    if authority.is_empty()
        || authority.contains('@')
        || has_control(authority)
        || authority.bytes().any(|b| b.is_ascii_whitespace())
    {
        return Err(ConnectionError::InvalidOrigin);
    }

    let (host, port) = if authority.starts_with('[') {
        let close = authority.find(']').ok_or(ConnectionError::InvalidOrigin)?;
        let host = &authority[..=close];
        let rest = &authority[close + 1..];
        let port = match rest.strip_prefix(':') {
            Some(port) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => {
                Some(port)
            }
            Some(_) => return Err(ConnectionError::InvalidOrigin),
            None if rest.is_empty() => None,
            None => return Err(ConnectionError::InvalidOrigin),
        };
        (host.to_ascii_lowercase(), port)
    } else {
        if authority.contains('[') || authority.contains(']') || authority.matches(':').count() > 1
        {
            return Err(ConnectionError::InvalidOrigin);
        }
        let (host, port) = match authority.rsplit_once(':') {
            Some((host, port)) => {
                if host.is_empty() || port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()) {
                    return Err(ConnectionError::InvalidOrigin);
                }
                (host, Some(port))
            }
            None => (authority, None),
        };
        if host.is_empty() {
            return Err(ConnectionError::InvalidOrigin);
        }
        (host.to_ascii_lowercase(), port)
    };

    match port {
        Some("80") if scheme == "http" => Ok(host),
        Some("443") if scheme == "https" => Ok(host),
        Some(port) => Ok(format!("{host}:{port}")),
        None => Ok(host),
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connection_requires_at_least_one_origin() {
        let mut reg = ConnectionRegistry::new();
        // auth:none with no origins is rejected — previously allowed, which let a connection marker be an
        // unrestricted egress channel that bypassed the network allowlist (S1).
        assert!(matches!(
            reg.insert("public.org.main", ConnectionCredential::None, Vec::<String>::new()),
            Err(ConnectionError::MissingOrigin)
        ));
        // a secret-bearing connection with no origins is rejected (unchanged by S1).
        assert!(matches!(
            reg.insert(
                "github.org.main",
                ConnectionCredential::Bearer { token: "t".to_string() },
                Vec::<String>::new(),
            ),
            Err(ConnectionError::MissingOrigin)
        ));
        // with an explicit origin both kinds insert fine.
        assert!(reg
            .insert(
                "public.org.main",
                ConnectionCredential::None,
                ["https://api.example.com".to_string()],
            )
            .is_ok());
    }

    #[test]
    fn origin_allowed_authorizes_by_normalized_origin() {
        // A non-canonical allowed origin (explicit default port, uppercase host) still authorizes the same
        // host, because both sides normalize through parse_origin — the same decision the splice makes.
        let allowed = vec!["https://API.Example.com:443".to_string()];
        assert!(origin_allowed(&allowed, "https://api.example.com/graphql"));
        assert!(origin_allowed(&allowed, "https://api.example.com"));
        // A different host, a different scheme, a path-suffixed lookalike, and a malformed URL are refused.
        assert!(!origin_allowed(&allowed, "https://api.example.com.evil.test/graphql"));
        assert!(!origin_allowed(&allowed, "http://api.example.com/graphql"));
        assert!(!origin_allowed(&allowed, "https://evil.test/graphql"));
        assert!(!origin_allowed(&allowed, "not-a-url"));
        // Empty allowlist authorizes nothing (fail closed).
        assert!(!origin_allowed(&[], "https://api.example.com/graphql"));
    }
}
