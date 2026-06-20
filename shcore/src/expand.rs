//! Word expansion — the POSIX expansion pipeline.
//!
//! Applied in order: tilde → parameter / command / arithmetic expansion → field
//! splitting (on IFS) → pathname (glob) expansion → quote removal (quote removal
//! already happened during lexing, recorded in each fragment's quoting flags).
//!
//! The driver targets the [`ExpandCtx`] trait so it stays OS-agnostic: the executor
//! supplies variable lookup, command substitution, arithmetic, and directory listing.
//! The subtle invariant threaded through here is *quoting*: a quoted expansion is
//! pushed un-split with glob inactive, an unquoted one is split on IFS with glob
//! active — so `"$x"` is one field that never globs while `$x` splits and may glob.
//!
//! Errors (a `${x:?msg}` violation) propagate as [`ExpandError`] via `Result`, so a
//! caller can never forget to check them — there is no stateful error flag. Integrated
//! behaviour (real `$()`, real globbing) is validated by the e2e suite.

use alloc::string::{String, ToString};
use alloc::vec::Vec;

use crate::glob::expand_glob_masked;
use crate::word::{ParamOp, Word, WordPart};

/// An expansion failure carrying the message to report (e.g. from `${x:?msg}`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpandError(pub String);

type R<T> = Result<T, ExpandError>;

/// Everything expansion needs from the outside world.
pub trait ExpandCtx {
    /// Ordinary shell variable (None if unset).
    fn get(&mut self, name: &str) -> Option<String>;
    /// Set a shell variable (for `${x:=word}`).
    fn set(&mut self, name: &str, val: &str);
    /// Scalar special parameters: `?` `$` `!` `#` `-` and `0`..`9`.
    fn special(&mut self, name: &str) -> Option<String>;
    /// Positional parameters `$1 $2 …` (for `$@` / `$*`).
    fn positionals(&mut self) -> Vec<String>;
    /// Run a command string and return its stdout (trailing newlines stripped).
    fn command_subst(&mut self, raw: &str) -> String;
    /// Evaluate an arithmetic expression.
    fn arith(&mut self, expr: &str) -> i64;
    /// List a directory (for globbing); None if unreadable.
    fn list_dir(&mut self, path: &str) -> Option<Vec<String>>;
    /// Current working directory (for relative globs).
    fn cwd(&mut self) -> String;
    /// Current IFS (defaults to space/tab/newline when unset).
    fn ifs(&mut self) -> String;
    /// `$HOME` for tilde expansion.
    fn home(&mut self) -> Option<String>;
}

fn lookup(ctx: &mut dyn ExpandCtx, name: &str) -> Option<String> {
    if let Some(v) = ctx.special(name) {
        return Some(v);
    }
    ctx.get(name)
}

// ---------- field builder (handles $@ field-injection) ----------

struct FieldBuilder {
    fields: Vec<(Vec<char>, Vec<bool>)>, // (chars, glob-active mask)
    cur_c: Vec<char>,
    cur_a: Vec<bool>,
    started: bool,
}

impl FieldBuilder {
    fn new() -> Self {
        FieldBuilder {
            fields: Vec::new(),
            cur_c: Vec::new(),
            cur_a: Vec::new(),
            started: false,
        }
    }
    fn flush(&mut self) {
        if self.started {
            self.fields.push((
                core::mem::take(&mut self.cur_c),
                core::mem::take(&mut self.cur_a),
            ));
            self.started = false;
        }
    }
    /// Non-splittable text (literal or quoted expansion).
    fn push_unsplit(&mut self, s: &str, glob_active: bool) {
        for ch in s.chars() {
            self.cur_c.push(ch);
            self.cur_a.push(glob_active);
        }
        self.started = true;
    }
    /// Splittable text (unquoted expansion) — break on IFS.
    fn push_split(&mut self, s: &str, glob_active: bool, ifs: &[char]) {
        let mut i = 0;
        let cs: Vec<char> = s.chars().collect();
        while i < cs.len() {
            if ifs.contains(&cs[i]) {
                if self.started {
                    self.flush();
                }
                while i < cs.len() && ifs.contains(&cs[i]) {
                    i += 1;
                }
            } else {
                self.cur_c.push(cs[i]);
                self.cur_a.push(glob_active);
                self.started = true;
                i += 1;
            }
        }
    }
    fn finish(mut self) -> Vec<(Vec<char>, Vec<bool>)> {
        self.flush();
        self.fields
    }
}

/// Expand a word into zero or more fields, with field splitting and pathname
/// expansion applied. Used for command arguments.
pub fn expand_to_fields(word: &Word, ctx: &mut dyn ExpandCtx) -> R<Vec<String>> {
    let ifs_str = ctx.ifs();
    let ifs: Vec<char> = ifs_str.chars().collect();
    let mut b = FieldBuilder::new();
    let word = apply_tilde(word, ctx);

    for part in &word {
        match part {
            WordPart::Lit { text, from_quote } => b.push_unsplit(text, !from_quote),
            WordPart::Sub { raw, quoted } => {
                let out = ctx.command_subst(raw);
                if *quoted {
                    b.push_unsplit(&out, false);
                } else {
                    b.push_split(&out, true, &ifs);
                }
            }
            WordPart::Arith { raw, quoted } => {
                let v = ctx.arith(raw).to_string();
                if *quoted {
                    b.push_unsplit(&v, false);
                } else {
                    b.push_split(&v, true, &ifs);
                }
            }
            WordPart::Var { name, op, quoted } => {
                expand_var_into(&mut b, name, op, *quoted, ctx, &ifs)?;
            }
        }
    }

    let raw_fields = b.finish();
    // Pathname expansion per field.
    let cwd = ctx.cwd();
    let mut out: Vec<String> = Vec::new();
    for (chars, active) in raw_fields {
        let mut lister = |d: &str| ctx.list_dir(d);
        let matches = expand_glob_masked(&chars, &active, &cwd, &mut lister);
        out.extend(matches);
    }
    Ok(out)
}

/// Expand a word to a single string (no field splitting, no globbing). Used for
/// assignment values, redirect targets, `case` subjects, and `${…}` op words.
pub fn expand_to_string(word: &Word, ctx: &mut dyn ExpandCtx) -> R<String> {
    let word = apply_tilde(word, ctx);
    let mut s = String::new();
    for part in &word {
        match part {
            WordPart::Lit { text, .. } => s.push_str(text),
            WordPart::Sub { raw, .. } => s.push_str(&ctx.command_subst(raw)),
            WordPart::Arith { raw, .. } => s.push_str(&ctx.arith(raw).to_string()),
            WordPart::Var { name, op, .. } => s.push_str(&scalar_var(name, op, ctx)?),
        }
    }
    Ok(s)
}

/// Expand a redirect target to exactly one field (POSIX "ambiguous redirect").
/// Errors are flattened to a `String` so the redirection layer can report them
/// uniformly with its own file-open errors.
pub fn expand_redirect_target(word: &Word, ctx: &mut dyn ExpandCtx) -> Result<String, String> {
    let fields = expand_to_fields(word, ctx).map_err(|e| e.0)?;
    match fields.len() {
        1 => Ok(fields.into_iter().next().unwrap()),
        0 => Err("ambiguous redirect: empty".to_string()),
        _ => Err("ambiguous redirect: multiple files".to_string()),
    }
}

fn expand_var_into(
    b: &mut FieldBuilder,
    name: &str,
    op: &ParamOp,
    quoted: bool,
    ctx: &mut dyn ExpandCtx,
    ifs: &[char],
) -> R<()> {
    // $@ / $* — multi-field special handling.
    if matches!(name, "@" | "*") && matches!(op, ParamOp::Get) {
        let params = ctx.positionals();
        if name == "*" && quoted {
            // "$*" → single field, joined by first IFS char (space if empty).
            let sep = ifs.first().copied().unwrap_or(' ');
            let joined = params.join(&sep.to_string());
            b.push_unsplit(&joined, false);
            return Ok(());
        }
        // "$@" (quoted) → one field per param; $@/$* unquoted → split each.
        for (k, p) in params.iter().enumerate() {
            if k > 0 {
                b.flush();
            }
            if quoted {
                b.push_unsplit(p, false);
            } else {
                b.push_split(p, true, ifs);
            }
        }
        return Ok(());
    }
    // ${#@} / ${#*} → positional count.
    if matches!(op, ParamOp::Length) && matches!(name, "@" | "*") {
        let n = ctx.positionals().len();
        let s = n.to_string();
        if quoted {
            b.push_unsplit(&s, false);
        } else {
            b.push_split(&s, true, ifs);
        }
        return Ok(());
    }
    let val = scalar_var(name, op, ctx)?;
    if quoted {
        b.push_unsplit(&val, false);
    } else {
        b.push_split(&val, true, ifs);
    }
    Ok(())
}

/// Compute the string value of a scalar parameter expansion.
fn scalar_var(name: &str, op: &ParamOp, ctx: &mut dyn ExpandCtx) -> R<String> {
    let base = lookup(ctx, name);
    Ok(match op {
        ParamOp::Get => base.unwrap_or_default(),
        ParamOp::Length => base.unwrap_or_default().chars().count().to_string(),
        ParamOp::Default { colon, word } => {
            if is_unset_or_null(&base, *colon) {
                expand_to_string(word, ctx)?
            } else {
                base.unwrap_or_default()
            }
        }
        ParamOp::Assign { colon, word } => {
            if is_unset_or_null(&base, *colon) {
                let v = expand_to_string(word, ctx)?;
                if assignable(name) {
                    ctx.set(name, &v);
                }
                v
            } else {
                base.unwrap_or_default()
            }
        }
        ParamOp::Alt { colon, word } => {
            if is_unset_or_null(&base, *colon) {
                String::new()
            } else {
                expand_to_string(word, ctx)?
            }
        }
        ParamOp::Error { colon, word } => {
            if is_unset_or_null(&base, *colon) {
                let msg = expand_to_string(word, ctx)?;
                return Err(ExpandError(if msg.is_empty() {
                    alloc::format!("{name}: parameter null or not set")
                } else {
                    alloc::format!("{name}: {msg}")
                }));
            } else {
                base.unwrap_or_default()
            }
        }
        ParamOp::TrimPrefix { longest, pat } => {
            let p = expand_to_string(pat, ctx)?;
            trim_prefix(&base.unwrap_or_default(), &p, *longest)
        }
        ParamOp::TrimSuffix { longest, pat } => {
            let p = expand_to_string(pat, ctx)?;
            trim_suffix(&base.unwrap_or_default(), &p, *longest)
        }
    })
}

fn is_unset_or_null(base: &Option<String>, colon: bool) -> bool {
    match base {
        None => true,
        Some(v) => colon && v.is_empty(),
    }
}

fn assignable(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with(|c: char| c.is_ascii_digit())
        && name.chars().all(|c| c == '_' || c.is_ascii_alphanumeric())
}

/// Leading unquoted `~` / `~/...` → $HOME. (`~user` left literal: no passwd db.)
fn apply_tilde(word: &Word, ctx: &mut dyn ExpandCtx) -> Word {
    if let Some(WordPart::Lit {
        text,
        from_quote: false,
    }) = word.first()
    {
        if text.starts_with('~') && (text.len() == 1 || text.as_bytes()[1] == b'/') {
            if let Some(home) = ctx.home() {
                let mut new = word.clone();
                let rest = &text[1..];
                new[0] = WordPart::Lit {
                    text: alloc::format!("{home}{rest}"),
                    from_quote: false,
                };
                return new;
            }
        }
    }
    word.clone()
}

// ---------- pattern trimming (uses glob matcher) ----------

fn trim_prefix(value: &str, pat: &str, longest: bool) -> String {
    if pat.is_empty() {
        return value.to_string();
    }
    let s: Vec<char> = value.chars().collect();
    let p: Vec<char> = pat.chars().collect();
    let mut best: Option<usize> = None;
    for i in 0..=s.len() {
        if crate::glob::glob_full(&p, &s[..i]) {
            best = Some(i);
            if !longest {
                break;
            }
        }
    }
    match best {
        Some(i) => s[i..].iter().collect(),
        None => value.to_string(),
    }
}

fn trim_suffix(value: &str, pat: &str, longest: bool) -> String {
    if pat.is_empty() {
        return value.to_string();
    }
    let s: Vec<char> = value.chars().collect();
    let p: Vec<char> = pat.chars().collect();
    let mut best: Option<usize> = None;
    for j in 0..=s.len() {
        if crate::glob::glob_full(&p, &s[s.len() - j..]) {
            best = Some(j);
            if !longest {
                break;
            }
        }
    }
    match best {
        Some(j) => s[..s.len() - j].iter().collect(),
        None => value.to_string(),
    }
}
