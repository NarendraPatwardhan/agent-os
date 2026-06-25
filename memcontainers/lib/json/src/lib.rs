//! `json` — a lightweight, pure `no_std + alloc` alternative to `serde_json`
//! (parse + serialize) shared across agent-os Rust components: the kernel reads
//! `/etc/services.json` to
//! activate resident services, and userspace tools (`invoke`) can parse tool-call
//! results instead of only hand-building request bodies. No syscalls, no `std`, no
//! external deps — the caller supplies the heap (`alloc`); under `--test` the crate
//! links `std` so the unit tests run natively (`#![cfg_attr(not(test), no_std)]`).
//!
//! Tolerant recursive-descent parser (collapses numbers to `f64`, keeps object keys
//! in insertion order — small, no hashing). Ported from memcontainers' `agentcore`
//! JSON core, with a full `Json → String` serializer added.

#![cfg_attr(not(test), no_std)]

extern crate alloc;

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

// ===========================================================================
// JSON value + parser
// ===========================================================================

/// A parsed JSON value. Numbers collapse to `f64`; objects keep insertion order in
/// a `Vec` (small, no hashing in `no_std`).
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JsonError {
    /// Malformed JSON (unexpected byte / EOF).
    Parse,
    /// Well-formed JSON whose shape isn't what the caller expected.
    Shape,
}

impl Json {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }
    pub fn as_arr(&self) -> Option<&[Json]> {
        match self {
            Json::Arr(a) => Some(a.as_slice()),
            _ => None,
        }
    }
    pub fn as_obj(&self) -> Option<&[(String, Json)]> {
        match self {
            Json::Obj(o) => Some(o.as_slice()),
            _ => None,
        }
    }
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }
    /// A finite, non-negative number as `u64` (for byte/fuel budgets). `f64` is
    /// exact for integers up to 2^53, far above any realistic budget.
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Json::Num(n) if n.is_finite() && *n >= 0.0 => Some(*n as u64),
            _ => None,
        }
    }
    /// Look up a key in an object (linear scan; objects are small).
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(pairs) => pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
}

/// Parse a complete JSON document. Leading/trailing whitespace is allowed;
/// trailing non-whitespace is an error (so a truncated document is caught).
pub fn parse(input: &str) -> Result<Json, JsonError> {
    let mut p = Parser {
        bytes: input.as_bytes(),
        pos: 0,
    };
    p.skip_ws();
    let v = p.value()?;
    p.skip_ws();
    if p.pos != p.bytes.len() {
        return Err(JsonError::Parse);
    }
    Ok(v)
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while let Some(b) = self.peek() {
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn value(&mut self) -> Result<Json, JsonError> {
        match self.peek().ok_or(JsonError::Parse)? {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => self.string().map(Json::Str),
            b't' | b'f' => self.boolean(),
            b'n' => self.null(),
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err(JsonError::Parse),
        }
    }

    fn literal(&mut self, lit: &[u8]) -> Result<(), JsonError> {
        if self.bytes[self.pos..].starts_with(lit) {
            self.pos += lit.len();
            Ok(())
        } else {
            Err(JsonError::Parse)
        }
    }

    fn null(&mut self) -> Result<Json, JsonError> {
        self.literal(b"null")?;
        Ok(Json::Null)
    }

    fn boolean(&mut self) -> Result<Json, JsonError> {
        if self.peek() == Some(b't') {
            self.literal(b"true")?;
            Ok(Json::Bool(true))
        } else {
            self.literal(b"false")?;
            Ok(Json::Bool(false))
        }
    }

    fn number(&mut self) -> Result<Json, JsonError> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while let Some(b) = self.peek() {
            if b.is_ascii_digit() || b == b'.' || b == b'e' || b == b'E' || b == b'+' || b == b'-' {
                self.pos += 1;
            } else {
                break;
            }
        }
        let s = core::str::from_utf8(&self.bytes[start..self.pos]).map_err(|_| JsonError::Parse)?;
        s.parse::<f64>()
            .map(Json::Num)
            .map_err(|_| JsonError::Parse)
    }

    /// Parse a JSON string (assumes the opening quote is at `pos`).
    fn string(&mut self) -> Result<String, JsonError> {
        debug_assert_eq!(self.peek(), Some(b'"'));
        self.pos += 1; // opening quote
        let mut out = String::new();
        loop {
            let b = self.peek().ok_or(JsonError::Parse)?;
            self.pos += 1;
            match b {
                b'"' => return Ok(out),
                b'\\' => {
                    let e = self.peek().ok_or(JsonError::Parse)?;
                    self.pos += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{08}'),
                        b'f' => out.push('\u{0c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode_escape()?),
                        _ => return Err(JsonError::Parse),
                    }
                }
                // A bare control byte is technically invalid JSON, but be tolerant —
                // pass the raw UTF-8 through (rejected below if not valid UTF-8).
                _ => {
                    let lead = b;
                    let extra = match lead {
                        0x00..=0x7f => 0,
                        0xc0..=0xdf => 1,
                        0xe0..=0xef => 2,
                        0xf0..=0xf7 => 3,
                        _ => return Err(JsonError::Parse),
                    };
                    let s = self.pos - 1;
                    self.pos += extra;
                    if self.pos > self.bytes.len() {
                        return Err(JsonError::Parse);
                    }
                    let chunk = core::str::from_utf8(&self.bytes[s..self.pos])
                        .map_err(|_| JsonError::Parse)?;
                    out.push_str(chunk);
                }
            }
        }
    }

    /// A `\uXXXX` escape (with surrogate-pair support), the `\u` already consumed.
    fn unicode_escape(&mut self) -> Result<char, JsonError> {
        let hi = self.hex4()?;
        let cp = if (0xd800..=0xdbff).contains(&hi) {
            // High surrogate — expect a following `\uXXXX` low surrogate.
            if self.peek() != Some(b'\\') {
                return Err(JsonError::Parse);
            }
            self.pos += 1;
            if self.peek() != Some(b'u') {
                return Err(JsonError::Parse);
            }
            self.pos += 1;
            let lo = self.hex4()?;
            if !(0xdc00..=0xdfff).contains(&lo) {
                return Err(JsonError::Parse);
            }
            0x10000 + (((hi - 0xd800) as u32) << 10) + (lo - 0xdc00) as u32
        } else {
            hi as u32
        };
        char::from_u32(cp).ok_or(JsonError::Parse)
    }

    fn hex4(&mut self) -> Result<u16, JsonError> {
        let mut v: u16 = 0;
        for _ in 0..4 {
            let b = self.peek().ok_or(JsonError::Parse)?;
            self.pos += 1;
            let d = match b {
                b'0'..=b'9' => b - b'0',
                b'a'..=b'f' => b - b'a' + 10,
                b'A'..=b'F' => b - b'A' + 10,
                _ => return Err(JsonError::Parse),
            };
            v = (v << 4) | d as u16;
        }
        Ok(v)
    }

    fn array(&mut self) -> Result<Json, JsonError> {
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Arr(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Arr(items));
                }
                _ => return Err(JsonError::Parse),
            }
        }
    }

    fn object(&mut self) -> Result<Json, JsonError> {
        self.pos += 1; // '{'
        let mut pairs = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Obj(pairs));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(JsonError::Parse);
            }
            let key = self.string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(JsonError::Parse);
            }
            self.pos += 1;
            self.skip_ws();
            let val = self.value()?;
            pairs.push((key, val));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Json::Obj(pairs));
                }
                _ => return Err(JsonError::Parse),
            }
        }
    }
}

// ===========================================================================
// JSON serialization
// ===========================================================================

/// Serialize a `Json` value to a compact (no-whitespace) JSON string.
pub fn to_string(v: &Json) -> String {
    let mut out = String::new();
    write_value(&mut out, v);
    out
}

fn write_value(out: &mut String, v: &Json) {
    match v {
        Json::Null => out.push_str("null"),
        Json::Bool(true) => out.push_str("true"),
        Json::Bool(false) => out.push_str("false"),
        Json::Num(n) => push_number(out, *n),
        Json::Str(s) => push_json_string(out, s),
        Json::Arr(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(out, item);
            }
            out.push(']');
        }
        Json::Obj(pairs) => {
            out.push('{');
            for (i, (k, val)) in pairs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                push_json_string(out, k);
                out.push(':');
                write_value(out, val);
            }
            out.push('}');
        }
    }
}

/// Append `n` as a JSON number. Integer-valued finites print without a decimal
/// point (`5`, not `5.0`); non-finite (NaN/∞ — which JSON cannot express) becomes
/// `null`.
fn push_number(out: &mut String, n: f64) {
    if !n.is_finite() {
        out.push_str("null");
    } else if n == (n as i64) as f64 {
        out.push_str(&format!("{}", n as i64));
    } else {
        out.push_str(&format!("{n}"));
    }
}

/// Append `s` to `out` as a quoted, escaped JSON string.
pub fn push_json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                out.push_str("\\u00");
                let byte = c as u8;
                out.push(hex_digit(byte >> 4));
                out.push(hex_digit(byte & 0xf));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn hex_digit(n: u8) -> char {
    match n {
        0..=9 => (b'0' + n) as char,
        _ => (b'a' + (n - 10)) as char,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec;

    #[test]
    fn parses_primitives() {
        assert_eq!(parse("null").unwrap(), Json::Null);
        assert_eq!(parse(" true ").unwrap(), Json::Bool(true));
        assert_eq!(parse("false").unwrap(), Json::Bool(false));
        assert_eq!(parse("42").unwrap(), Json::Num(42.0));
        assert_eq!(parse("-1.5e3").unwrap(), Json::Num(-1500.0));
        assert_eq!(parse(r#""hi\nA""#).unwrap(), Json::Str("hi\nA".into()));
    }

    #[test]
    fn parses_nested_and_navigates() {
        let v = parse(r#"{"a":[1,2],"b":{"c":true},"s":"x"}"#).unwrap();
        assert_eq!(v.get("a").unwrap().as_arr().unwrap().len(), 2);
        assert_eq!(v.get("b").unwrap().get("c").unwrap().as_bool(), Some(true));
        assert_eq!(v.get("s").unwrap().as_str(), Some("x"));
        assert!(v.get("missing").is_none());
    }

    #[test]
    fn rejects_truncated_and_trailing() {
        assert_eq!(parse("{\"a\":1").unwrap_err(), JsonError::Parse);
        assert_eq!(parse("1 2").unwrap_err(), JsonError::Parse);
        assert_eq!(parse("").unwrap_err(), JsonError::Parse);
    }

    #[test]
    fn parses_a_service_manifest() {
        // The exact shape the kernel reads from /etc/services.json (SYSTEMS.md): name → { binary,
        // optional `eager` }. No tier/budget here — the binary's own mc_tier/mc_budget are the single
        // source of truth, so a manifest can never widen the privilege a binary declared it needs.
        let m = parse(
            r#"{
                "kv":     { "binary": "/bin/kv", "eager": true },
                "sqlite": { "binary": "/bin/sqlite" }
            }"#,
        )
        .unwrap();
        let kv = m.get("kv").unwrap();
        assert_eq!(kv.get("binary").unwrap().as_str(), Some("/bin/kv"));
        assert_eq!(kv.get("eager").unwrap().as_bool(), Some(true));
        let sqlite = m.get("sqlite").unwrap();
        assert_eq!(sqlite.get("binary").unwrap().as_str(), Some("/bin/sqlite"));
        assert_eq!(sqlite.get("eager"), None); // absent → lazy (the default)
        // The `as_u64` accessor stays covered (numeric config a tool might carry, e.g. a budget).
        assert_eq!(parse("134217728").unwrap().as_u64(), Some(134217728));
    }

    #[test]
    fn serializes_compactly_and_round_trips() {
        assert_eq!(to_string(&Json::Num(5.0)), "5"); // integer-valued → no ".0"
        assert_eq!(to_string(&Json::Num(2.5)), "2.5");
        assert_eq!(to_string(&Json::Str("a\"b".into())), r#""a\"b""#);
        let obj = Json::Obj(vec![
            ("n".into(), Json::Num(1.0)),
            ("a".into(), Json::Arr(vec![Json::Bool(true), Json::Null])),
        ]);
        assert_eq!(to_string(&obj), r#"{"n":1,"a":[true,null]}"#);
        // Round-trip a non-trivial document.
        let src = r#"{"x":[1,2.5,"s",null,false],"y":{"z":-3}}"#;
        assert_eq!(to_string(&parse(src).unwrap()), src);
    }
}
