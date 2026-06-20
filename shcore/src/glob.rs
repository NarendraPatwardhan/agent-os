//! Pathname expansion (globbing).
//!
//! [`glob_full`] is the `*`/`?`/`[...]` matcher; [`expand_glob`] walks a path field
//! segment-by-segment against a directory lister. The lister is a closure, so this
//! module stays OS-free and unit-testable — the executor passes one over
//! `ShellOs::readdir`.
//!
//! The `_masked` variants carry a parallel `active: &[bool]` that marks which pattern
//! characters came from an *unquoted* source. A glob metacharacter is special only
//! when active, which is exactly what lets `"*".c` stay literal while an unquoted `$x`
//! that expands to `*` still globs. Field splitting and quoting decisions are made by
//! `expand.rs`; this module only honors the mask it is handed.

use alloc::string::{String, ToString};
use alloc::vec::Vec;

/// Full-string glob match supporting `*` (any run), `?` (one char), and
/// `[...]` / `[!...]` character classes with `a-z` ranges.
pub fn glob_full(pat: &[char], s: &[char]) -> bool {
    glob_rec(pat, 0, s, 0)
}

fn glob_rec(p: &[char], mut pi: usize, s: &[char], mut si: usize) -> bool {
    // Iterative with backtracking for `*`; recursion only for `[...]` is avoided.
    let mut star: Option<(usize, usize)> = None; // (pattern pos after *, string pos)
    while si < s.len() {
        if pi < p.len() && p[pi] == '*' {
            pi += 1;
            star = Some((pi, si));
            continue;
        }
        if pi < p.len() && matches_one(p, pi, s[si]) {
            let consumed = class_len(p, pi);
            pi += consumed;
            si += 1;
            continue;
        }
        if let Some((sp, ss)) = star {
            pi = sp;
            si = ss + 1;
            star = Some((sp, ss + 1));
            continue;
        }
        return false;
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

/// Does the pattern element at `pi` match char `ch`? Handles literal, `?`, and
/// `[...]`. (Call `class_len` to advance past the element.)
fn matches_one(p: &[char], pi: usize, ch: char) -> bool {
    match p[pi] {
        '?' => true,
        '[' => {
            if let Some((set_matches, _len)) = parse_class(p, pi, ch) {
                set_matches
            } else {
                ch == '[' // malformed class ⇒ literal '['
            }
        }
        c => c == ch,
    }
}

fn class_len(p: &[char], pi: usize) -> usize {
    match p[pi] {
        '[' => {
            if let Some((_m, len)) = parse_class(p, pi, '\0') {
                len
            } else {
                1
            }
        }
        _ => 1,
    }
}

/// Parse a `[...]` class starting at `pi`. Returns `(matches ch, element length)`
/// or `None` if malformed (no closing `]`).
fn parse_class(p: &[char], pi: usize, ch: char) -> Option<(bool, usize)> {
    debug_assert_eq!(p[pi], '[');
    let mut i = pi + 1;
    let negate = i < p.len() && (p[i] == '!' || p[i] == '^');
    if negate {
        i += 1;
    }
    let mut matched = false;
    let mut first = true;
    while i < p.len() {
        // A `]` as the very first class char is literal.
        if p[i] == ']' && !first {
            let len = i + 1 - pi;
            return Some((matched ^ negate, len));
        }
        first = false;
        // range a-z
        if i + 2 < p.len() && p[i + 1] == '-' && p[i + 2] != ']' {
            if ch >= p[i] && ch <= p[i + 2] {
                matched = true;
            }
            i += 3;
            continue;
        }
        if p[i] == ch {
            matched = true;
        }
        i += 1;
    }
    None // unterminated class
}

/// True if `field` (an unquoted word) contains glob metacharacters.
pub fn has_meta(field: &str) -> bool {
    field.chars().any(|c| c == '*' || c == '?' || c == '[')
}

// ---------- masked variants (quoting-aware) ----------
//
// A glob metacharacter is only special when it came from an UNQUOTED source.
// `active[i]` marks pattern char `i` as glob-active; an inactive `*`/`?`/`[`
// matches itself literally. This is what lets `"*".c` stay literal while an
// unquoted `$x` expanding to `*` still globs.

/// Masked full-string glob match.
pub fn glob_full_masked(p: &[char], active: &[bool], s: &[char]) -> bool {
    let mut star: Option<(usize, usize)> = None;
    let (mut pi, mut si) = (0usize, 0usize);
    while si < s.len() {
        if pi < p.len() && active[pi] && p[pi] == '*' {
            pi += 1;
            star = Some((pi, si));
            continue;
        }
        if pi < p.len() && matches_one_masked(p, active, pi, s[si]) {
            pi += class_len_masked(p, active, pi);
            si += 1;
            continue;
        }
        if let Some((sp, ss)) = star {
            pi = sp;
            si = ss + 1;
            star = Some((sp, ss + 1));
            continue;
        }
        return false;
    }
    while pi < p.len() && active[pi] && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

fn matches_one_masked(p: &[char], active: &[bool], pi: usize, ch: char) -> bool {
    if !active[pi] {
        return p[pi] == ch;
    }
    match p[pi] {
        '?' => true,
        '[' => match parse_class(p, pi, ch) {
            Some((m, _)) => m,
            None => ch == '[',
        },
        c => c == ch,
    }
}

fn class_len_masked(p: &[char], active: &[bool], pi: usize) -> usize {
    if active[pi] && p[pi] == '[' {
        if let Some((_m, len)) = parse_class(p, pi, '\0') {
            return len;
        }
    }
    1
}

fn has_active_meta(chars: &[char], active: &[bool]) -> bool {
    chars
        .iter()
        .zip(active)
        .any(|(c, a)| *a && (*c == '*' || *c == '?' || *c == '['))
}

/// Masked pathname expansion. `chars`/`active` describe one field (post field
/// splitting); only active metacharacters glob. Result paths keep the field's
/// relative/absolute form (a relative pattern yields relative names), while
/// directories are resolved against `cwd` for listing. Returns matches sorted,
/// or the literal field if there are none (POSIX default).
pub fn expand_glob_masked(
    chars: &[char],
    active: &[bool],
    cwd: &str,
    list: &mut dyn FnMut(&str) -> Option<Vec<String>>,
) -> Vec<String> {
    let literal: String = chars.iter().collect();
    if !has_active_meta(chars, active) {
        return alloc::vec![literal];
    }
    let absolute = chars.first() == Some(&'/');
    // Split into segments on '/', carrying the mask along.
    let mut segs: Vec<(Vec<char>, Vec<bool>)> = Vec::new();
    let mut cur_c: Vec<char> = Vec::new();
    let mut cur_a: Vec<bool> = Vec::new();
    for (idx, ch) in chars.iter().enumerate() {
        if *ch == '/' {
            if !cur_c.is_empty() {
                segs.push((core::mem::take(&mut cur_c), core::mem::take(&mut cur_a)));
            }
        } else {
            cur_c.push(*ch);
            cur_a.push(active[idx]);
        }
    }
    if !cur_c.is_empty() {
        segs.push((cur_c, cur_a));
    }

    // Each candidate is (display_path, fs_path). Display keeps the written form
    // (relative names for relative patterns); fs is resolved against cwd so the
    // lister always sees a concrete directory.
    let display0 = if absolute {
        String::from("/")
    } else {
        String::new()
    };
    let fs0 = if absolute {
        String::from("/")
    } else {
        cwd.to_string()
    };
    let mut bases: Vec<(String, String)> = alloc::vec![(display0, fs0)];

    for (seg_c, seg_a) in &segs {
        let seg_str: String = seg_c.iter().collect();
        let mut next: Vec<(String, String)> = Vec::new();
        if has_active_meta(seg_c, seg_a) {
            for (disp, fs) in &bases {
                if let Some(entries) = list(fs) {
                    for e in entries {
                        let pat_dot = seg_c.first() == Some(&'.');
                        if e.starts_with('.') && !pat_dot {
                            continue;
                        }
                        let ec: Vec<char> = e.chars().collect();
                        if glob_full_masked(seg_c, seg_a, &ec) {
                            next.push((join_disp(disp, &e), join_seg(fs, &e)));
                        }
                    }
                }
            }
        } else {
            for (disp, fs) in &bases {
                next.push((join_disp(disp, &seg_str), join_seg(fs, &seg_str)));
            }
        }
        bases = next;
    }
    if bases.is_empty() {
        alloc::vec![literal]
    } else {
        let mut out: Vec<String> = bases.into_iter().map(|(d, _)| d).collect();
        out.sort();
        out
    }
}

/// Join for the display path, where an empty base means "relative to cwd".
fn join_disp(base: &str, name: &str) -> String {
    if base.is_empty() {
        name.to_string()
    } else if base == "/" {
        alloc::format!("/{name}")
    } else if base.ends_with('/') {
        alloc::format!("{base}{name}")
    } else {
        alloc::format!("{base}/{name}")
    }
}

fn join_seg(base: &str, name: &str) -> String {
    if base == "/" {
        alloc::format!("/{name}")
    } else if base.ends_with('/') {
        alloc::format!("{base}{name}")
    } else {
        alloc::format!("{base}/{name}")
    }
}

/// Expand a path field against the filesystem (all metacharacters active —
/// callers needing quote-awareness use `expand_glob_masked`). Result paths keep
/// the field's relative/absolute form. If nothing matches, returns the field
/// unchanged (POSIX default, no `nullglob`).
pub fn expand_glob(
    field: &str,
    cwd: &str,
    list: &mut dyn FnMut(&str) -> Option<Vec<String>>,
) -> Vec<String> {
    let chars: Vec<char> = field.chars().collect();
    let active: Vec<bool> = alloc::vec![true; chars.len()];
    expand_glob_masked(&chars, &active, cwd, list)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g(p: &str, s: &str) -> bool {
        glob_full(
            &p.chars().collect::<Vec<_>>(),
            &s.chars().collect::<Vec<_>>(),
        )
    }

    #[test]
    fn star_question_literal() {
        assert!(g("*.txt", "a.txt"));
        assert!(!g("*.txt", "a.md"));
        assert!(g("a?c", "abc"));
        assert!(!g("a?c", "ac"));
        assert!(g("*", "anything"));
        assert!(g("foo", "foo"));
        assert!(!g("foo", "foobar"));
        assert!(g("foo*", "foobar"));
        assert!(g("a*b*c", "axxbyyc"));
    }

    #[test]
    fn char_classes() {
        assert!(g("[abc]", "b"));
        assert!(!g("[abc]", "d"));
        assert!(g("[a-z]", "m"));
        assert!(!g("[a-z]", "M"));
        assert!(g("[!0-9]", "x"));
        assert!(!g("[!0-9]", "5"));
        assert!(g("file[0-9].log", "file3.log"));
    }

    #[test]
    fn masked_metachar_is_literal_when_inactive() {
        // An inactive (quoted) '*' matches only a literal '*'.
        let p: Vec<char> = "*.c".chars().collect();
        let inactive = alloc::vec![false, false, false];
        assert!(glob_full_masked(
            &p,
            &inactive,
            &"*.c".chars().collect::<Vec<_>>()
        ));
        assert!(!glob_full_masked(
            &p,
            &inactive,
            &"a.c".chars().collect::<Vec<_>>()
        ));
        // Active '*' globs.
        let active = alloc::vec![true, false, false];
        assert!(glob_full_masked(
            &p,
            &active,
            &"a.c".chars().collect::<Vec<_>>()
        ));
    }
}
