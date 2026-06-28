//! Shared normalization helpers for adapter-emitted catalog records.
//!
//! Adapter modules own their format-specific parsing, but catalog address grammar should not drift by
//! format. Keep segment sanitization, segment validation, and recursive normalization limits here so
//! new formats fail closed in the same way as the existing ones.

pub const MAX_NORMALIZATION_DEPTH: usize = 32;

pub fn depth_exceeded(depth: usize) -> bool {
    depth > MAX_NORMALIZATION_DEPTH
}

pub fn sanitize_segment(value: &str) -> String {
    let mut out = String::new();
    let mut last_sep = false;
    for b in value.bytes() {
        let c = match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'_' | b'-' => b as char,
            _ => {
                if last_sep {
                    continue;
                }
                last_sep = true;
                '-'
            }
        };
        if c != '-' {
            last_sep = false;
        }
        out.push(c);
    }
    out.trim_matches('-').to_string()
}

pub fn sanitize_segment_or(value: &str, fallback: &str) -> String {
    let clean = sanitize_segment(value);
    if clean.is_empty() {
        fallback.to_string()
    } else {
        clean
    }
}

pub fn valid_segment(value: &str) -> bool {
    !value.is_empty()
        && value
            .as_bytes()
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}
