//! Tokenizer: raw line(s) → a token stream for the recursive-descent parser.
//!
//! It reads shell words fragment by fragment (quotes, escapes, `$VAR`/`${…}`,
//! `$(…)`, backticks, and arithmetic `$(( … ))`) and emits the operators, newlines,
//! and IO_NUMBER tokens a real grammar needs.
//!
//! Two deliberate non-responsibilities, both load-bearing:
//!   - Reserved words (`if`/`then`/…/`{`/`}`/`!`/`function`) are NOT classified here.
//!     POSIX recognizes them only by grammar *position*, so the parser upgrades a
//!     bare single-literal [`Token::Word`] to a keyword when the position calls for
//!     it. That is also why `{`/`}` are ordinary word characters here, not operators.
//!   - Here-document bodies are collected as the raw lines that follow (never
//!     tokenized). An interactive driver tells "need another line" from a hard error
//!     by [`LexError::Incomplete`] vs [`LexError::Syntax`].

use alloc::string::{String, ToString};
use alloc::vec::Vec;

use crate::word::{ParamOp, Word, WordPart};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Token {
    Word(Word),
    Op(Operator),
    /// A digit run immediately preceding a redirection operator: the `2` in `2>f`.
    IoNumber(u32),
    /// A here-document: `<<DELIM` / `<<-DELIM` with its already-collected body.
    /// `expand` is false when the delimiter was quoted (`<<'EOF'`).
    Heredoc {
        strip: bool,
        body: String,
        expand: bool,
    },
    /// A significant newline (command terminator).
    Newline,
    Eof,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Operator {
    Pipe,      // |
    OrIf,      // ||
    AndIf,     // &&
    Semi,      // ;
    DSemi,     // ;;
    Amp,       // &
    Less,      // <
    Great,     // >
    DGreat,    // >>
    LessAnd,   // <&
    GreatAnd,  // >&
    LessGreat, // <>
    Clobber,   // >|
    LParen,    // (
    RParen,    // )
}

/// Tokenize `src` (which may span multiple physical lines). On an unterminated
/// quote / `$(` / `${`, returns `Err(LexError::Incomplete)` so an interactive
/// driver can read another line; other syntax problems are `Err(LexError::Syntax)`.
pub fn tokenize(src: &str) -> Result<Vec<Token>, LexError> {
    let c: Vec<char> = src.chars().collect();
    let mut i = 0usize;
    let mut out: Vec<Token> = Vec::new();
    // Here-docs awaiting their bodies: (token index in `out`, strip-tabs, delimiter).
    let mut pending: Vec<(usize, bool, String)> = Vec::new();
    while i < c.len() {
        let ch = c[i];
        // Inter-token blanks (NOT newline — newline is significant).
        if ch == ' ' || ch == '\t' {
            i += 1;
            continue;
        }
        // Line continuation: backslash-newline disappears.
        if ch == '\\' && i + 1 < c.len() && c[i + 1] == '\n' {
            i += 2;
            continue;
        }
        // Comment: `#` in command/blank position runs to end of line.
        if ch == '#' && at_word_boundary(&out, &c, i) {
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if ch == '\n' {
            out.push(Token::Newline);
            i += 1;
            // A newline ends the line that introduced any here-docs: their
            // bodies are the following raw lines (not tokenized).
            if !pending.is_empty() {
                i = collect_heredoc_bodies(&c, i, &mut out, &mut pending)?;
            }
            continue;
        }
        // Operators (maximal munch). `{`/`}` are NOT operators — they are word
        // characters that the parser may treat as reserved words.
        match ch {
            '|' => {
                if next_is(&c, i, '|') {
                    out.push(Token::Op(Operator::OrIf));
                    i += 2;
                } else {
                    out.push(Token::Op(Operator::Pipe));
                    i += 1;
                }
                continue;
            }
            '&' => {
                if next_is(&c, i, '&') {
                    out.push(Token::Op(Operator::AndIf));
                    i += 2;
                } else {
                    out.push(Token::Op(Operator::Amp));
                    i += 1;
                }
                continue;
            }
            ';' => {
                if next_is(&c, i, ';') {
                    out.push(Token::Op(Operator::DSemi));
                    i += 2;
                } else {
                    out.push(Token::Op(Operator::Semi));
                    i += 1;
                }
                continue;
            }
            '(' => {
                out.push(Token::Op(Operator::LParen));
                i += 1;
                continue;
            }
            ')' => {
                out.push(Token::Op(Operator::RParen));
                i += 1;
                continue;
            }
            '<' => {
                if next_is(&c, i, '<') {
                    let strip = i + 2 < c.len() && c[i + 2] == '-';
                    i += if strip { 3 } else { 2 };
                    // skip blanks before the delimiter word
                    while i < c.len() && (c[i] == ' ' || c[i] == '\t') {
                        i += 1;
                    }
                    let (delim, expand, ni) = read_heredoc_delim(&c, i)?;
                    i = ni;
                    pending.push((out.len(), strip, delim));
                    out.push(Token::Heredoc {
                        strip,
                        body: String::new(),
                        expand,
                    });
                } else if next_is(&c, i, '&') {
                    out.push(Token::Op(Operator::LessAnd));
                    i += 2;
                } else if next_is(&c, i, '>') {
                    out.push(Token::Op(Operator::LessGreat));
                    i += 2;
                } else {
                    out.push(Token::Op(Operator::Less));
                    i += 1;
                }
                continue;
            }
            '>' => {
                if next_is(&c, i, '>') {
                    out.push(Token::Op(Operator::DGreat));
                    i += 2;
                } else if next_is(&c, i, '&') {
                    out.push(Token::Op(Operator::GreatAnd));
                    i += 2;
                } else if next_is(&c, i, '|') {
                    out.push(Token::Op(Operator::Clobber));
                    i += 2;
                } else {
                    out.push(Token::Op(Operator::Great));
                    i += 1;
                }
                continue;
            }
            _ => {}
        }
        // IO_NUMBER: a run of digits immediately followed by < or > with no
        // intervening blank, e.g. `2>` / `10<`.
        if ch.is_ascii_digit() {
            let mut j = i;
            while j < c.len() && c[j].is_ascii_digit() {
                j += 1;
            }
            if j < c.len() && (c[j] == '<' || c[j] == '>') {
                let n: u32 = c[i..j].iter().collect::<String>().parse().unwrap_or(0);
                out.push(Token::IoNumber(n));
                i = j;
                continue;
            }
        }
        // Otherwise a word.
        let (w, ni) = read_word(&c, i)?;
        out.push(Token::Word(w));
        i = ni;
    }
    // EOF reached: any here-doc whose body never arrived needs more input.
    if !pending.is_empty() {
        // Treat trailing input with no newline as the final line: try to
        // collect from the current position (handles a body ending at EOF).
        let _ = collect_heredoc_bodies(&c, i, &mut out, &mut pending);
        if !pending.is_empty() {
            return Err(LexError::Incomplete("unterminated here-document".into()));
        }
    }
    out.push(Token::Eof);
    Ok(out)
}

/// Read a here-doc delimiter word starting at `start`. Quoting (`'EOF'`,
/// `"EOF"`, `\E`) disables body expansion. Returns (delimiter, expand, next).
fn read_heredoc_delim(c: &[char], start: usize) -> Result<(String, bool, usize), LexError> {
    let mut i = start;
    let mut delim = String::new();
    let mut expand = true;
    while i < c.len() {
        let ch = c[i];
        if ch == ' '
            || ch == '\t'
            || ch == '\n'
            || matches!(ch, '|' | '&' | ';' | '<' | '>' | '(' | ')')
        {
            break;
        }
        match ch {
            '\'' => {
                expand = false;
                i += 1;
                while i < c.len() && c[i] != '\'' {
                    delim.push(c[i]);
                    i += 1;
                }
                if i >= c.len() {
                    return Err(LexError::Incomplete(
                        "unterminated heredoc delimiter".into(),
                    ));
                }
                i += 1;
            }
            '"' => {
                expand = false;
                i += 1;
                while i < c.len() && c[i] != '"' {
                    delim.push(c[i]);
                    i += 1;
                }
                if i >= c.len() {
                    return Err(LexError::Incomplete(
                        "unterminated heredoc delimiter".into(),
                    ));
                }
                i += 1;
            }
            '\\' => {
                expand = false;
                i += 1;
                if i < c.len() {
                    delim.push(c[i]);
                    i += 1;
                }
            }
            _ => {
                delim.push(ch);
                i += 1;
            }
        }
    }
    if delim.is_empty() {
        return Err(LexError::Syntax("missing here-document delimiter".into()));
    }
    Ok((delim, expand, i))
}

/// Consume raw body lines for every pending here-doc, in order, filling each
/// `Token::Heredoc.body`. Returns the new char index past the consumed bodies.
fn collect_heredoc_bodies(
    c: &[char],
    mut i: usize,
    out: &mut [Token],
    pending: &mut Vec<(usize, bool, String)>,
) -> Result<usize, LexError> {
    for (idx, strip, delim) in core::mem::take(pending) {
        let mut body = String::new();
        loop {
            if i >= c.len() {
                // Re-arm so the caller reports Incomplete.
                pending.push((idx, strip, delim));
                return Ok(i);
            }
            // Read one physical line.
            let line_start = i;
            while i < c.len() && c[i] != '\n' {
                i += 1;
            }
            let raw: String = c[line_start..i].iter().collect();
            if i < c.len() {
                i += 1; // consume newline
            }
            let compare = if strip {
                raw.trim_start_matches('\t')
            } else {
                raw.as_str()
            };
            if compare == delim {
                break;
            }
            let content = if strip {
                raw.trim_start_matches('\t')
            } else {
                raw.as_str()
            };
            body.push_str(content);
            body.push('\n');
        }
        if let Some(Token::Heredoc { body: b, .. }) = out.get_mut(idx) {
            *b = body;
        }
    }
    Ok(i)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LexError {
    /// Recoverable: more input would complete the token (open quote/`$(`/`${`).
    Incomplete(String),
    /// Hard syntax error.
    Syntax(String),
}

fn next_is(c: &[char], i: usize, ch: char) -> bool {
    i + 1 < c.len() && c[i + 1] == ch
}

/// A `#` begins a comment only at the start of a token (after start, blank, or
/// an operator) — `a#b` keeps the `#` literal.
fn at_word_boundary(out: &[Token], c: &[char], i: usize) -> bool {
    if i == 0 {
        return true;
    }
    let prev = c[i - 1];
    if prev == ' ' || prev == '\t' || prev == '\n' {
        return true;
    }
    matches!(out.last(), Some(Token::Op(_)) | Some(Token::Newline) | None)
}

// ---------- word reading ----------
//
// A word is read fragment by fragment: literal runs flush into a `Lit` part, and
// each quote/`$`/backtick construct pushes its own typed part. The `from_quote`/
// `quoted` flags recorded here are what later let expansion apply IFS-splitting and
// globbing only to the unquoted fragments (see `word.rs`).

const WORD_STOP: &[char] = &[' ', '\t', '\n', '|', '&', ';', '<', '>', '(', ')'];

fn read_word(c: &[char], start: usize) -> Result<(Word, usize), LexError> {
    let mut parts: Word = Vec::new();
    let mut lit = String::new();
    let mut i = start;
    macro_rules! flush {
        () => {
            if !lit.is_empty() {
                parts.push(WordPart::Lit {
                    text: core::mem::take(&mut lit),
                    from_quote: false,
                });
            }
        };
    }
    while i < c.len() {
        let ch = c[i];
        if WORD_STOP.contains(&ch) {
            break;
        }
        match ch {
            '\'' => {
                flush!();
                let (s, ni) = read_squote(c, i + 1)?;
                parts.push(WordPart::Lit {
                    text: s,
                    from_quote: true,
                });
                i = ni;
            }
            '"' => {
                flush!();
                let (qp, ni) = read_dquote(c, i + 1)?;
                parts.extend(qp);
                i = ni;
            }
            '\\' => {
                i += 1;
                if i < c.len() {
                    // backslash-newline already handled by the caller's continuation
                    lit.push(c[i]);
                    i += 1;
                } else {
                    lit.push('\\');
                }
            }
            '$' => {
                let (p, ni) = read_dollar(c, i + 1, false)?;
                match p {
                    Some(part) => {
                        flush!();
                        parts.push(part);
                    }
                    None => lit.push('$'),
                }
                i = ni;
            }
            '`' => {
                flush!();
                let (raw, ni) = read_backtick(c, i + 1)?;
                parts.push(WordPart::Sub { raw, quoted: false });
                i = ni;
            }
            _ => {
                lit.push(ch);
                i += 1;
            }
        }
    }
    flush!();
    Ok((parts, i))
}

fn read_squote(c: &[char], start: usize) -> Result<(String, usize), LexError> {
    let mut s = String::new();
    let mut i = start;
    while i < c.len() {
        if c[i] == '\'' {
            return Ok((s, i + 1));
        }
        s.push(c[i]);
        i += 1;
    }
    Err(LexError::Incomplete(
        "unterminated single quote".to_string(),
    ))
}

fn read_dquote(c: &[char], start: usize) -> Result<(Vec<WordPart>, usize), LexError> {
    let mut parts: Vec<WordPart> = Vec::new();
    let mut lit = String::new();
    let mut i = start;
    macro_rules! flush {
        () => {
            if !lit.is_empty() {
                parts.push(WordPart::Lit {
                    text: core::mem::take(&mut lit),
                    from_quote: true,
                });
            }
        };
    }
    while i < c.len() {
        let ch = c[i];
        match ch {
            '"' => {
                flush!();
                return Ok((parts, i + 1));
            }
            '\\' => {
                i += 1;
                if i < c.len() {
                    let n = c[i];
                    if n == '"' || n == '\\' || n == '$' || n == '`' || n == '\n' {
                        if n != '\n' {
                            lit.push(n);
                        }
                    } else {
                        lit.push('\\');
                        lit.push(n);
                    }
                    i += 1;
                } else {
                    lit.push('\\');
                }
            }
            '$' => {
                let (p, ni) = read_dollar(c, i + 1, true)?;
                match p {
                    Some(part) => {
                        flush!();
                        parts.push(part);
                    }
                    None => lit.push('$'),
                }
                i = ni;
            }
            '`' => {
                flush!();
                let (raw, ni) = read_backtick(c, i + 1)?;
                parts.push(WordPart::Sub { raw, quoted: true });
                i = ni;
            }
            _ => {
                lit.push(ch);
                i += 1;
            }
        }
    }
    Err(LexError::Incomplete(
        "unterminated double quote".to_string(),
    ))
}

fn read_backtick(c: &[char], start: usize) -> Result<(String, usize), LexError> {
    let mut s = String::new();
    let mut i = start;
    while i < c.len() {
        let ch = c[i];
        match ch {
            '`' => return Ok((s, i + 1)),
            '\\' => {
                i += 1;
                if i < c.len() {
                    let n = c[i];
                    if n == '`' || n == '\\' || n == '$' {
                        s.push(n);
                    } else {
                        s.push('\\');
                        s.push(n);
                    }
                    i += 1;
                } else {
                    s.push('\\');
                }
            }
            _ => {
                s.push(ch);
                i += 1;
            }
        }
    }
    Err(LexError::Incomplete("unterminated backquote".to_string()))
}

/// Parse what follows a `$` (at index `start`). `None` ⇒ a literal `$`.
fn read_dollar(
    c: &[char],
    start: usize,
    quoted: bool,
) -> Result<(Option<WordPart>, usize), LexError> {
    if start >= c.len() {
        return Ok((None, start));
    }
    let ch = c[start];
    match ch {
        '(' => {
            // `$((` ⇒ arithmetic; `$(` ⇒ command substitution.
            if start + 1 < c.len() && c[start + 1] == '(' {
                // scan_to_matching from the second '(' balances the outer pair;
                // the returned inner is "( expr )" — strip the outer parens.
                let (inner, ni) = scan_to_matching(c, start + 1, '(', ')')
                    .ok_or_else(|| LexError::Incomplete("unterminated $((".to_string()))?;
                let chars: Vec<char> = inner.chars().collect();
                let expr = if chars.first() == Some(&'(') && chars.last() == Some(&')') {
                    chars[1..chars.len() - 1].iter().collect()
                } else {
                    inner
                };
                return Ok((Some(WordPart::Arith { raw: expr, quoted }), ni));
            }
            let (raw, ni) = scan_to_matching(c, start + 1, '(', ')')
                .ok_or_else(|| LexError::Incomplete("unterminated $(".to_string()))?;
            Ok((Some(WordPart::Sub { raw, quoted }), ni))
        }
        '{' => {
            let (inner, ni) = scan_to_matching(c, start + 1, '{', '}')
                .ok_or_else(|| LexError::Incomplete("unterminated ${".to_string()))?;
            let part = parse_param(&inner.chars().collect::<Vec<_>>(), quoted)?;
            Ok((Some(part), ni))
        }
        // Special parameters: $? $$ $! $# $@ $* $- and $0..$9.
        '?' | '$' | '!' | '#' | '@' | '*' | '-' => Ok((
            Some(WordPart::Var {
                name: ch.to_string(),
                op: ParamOp::Get,
                quoted,
            }),
            start + 1,
        )),
        _ if ch == '_' || ch.is_ascii_alphabetic() => {
            let (name, ni) = read_name(c, start);
            Ok((
                Some(WordPart::Var {
                    name,
                    op: ParamOp::Get,
                    quoted,
                }),
                ni,
            ))
        }
        _ if ch.is_ascii_digit() => {
            // Positional ${0..9}: a single digit unless braced. Bare `$12` is $1
            // then literal `2` in POSIX, but we read the full run for ${...};
            // here (unbraced) take a single digit per POSIX.
            Ok((
                Some(WordPart::Var {
                    name: ch.to_string(),
                    op: ParamOp::Get,
                    quoted,
                }),
                start + 1,
            ))
        }
        _ => Ok((None, start)),
    }
}

fn read_name(c: &[char], start: usize) -> (String, usize) {
    let mut i = start;
    let mut s = String::new();
    while i < c.len() && (c[i] == '_' || c[i].is_ascii_alphanumeric()) {
        s.push(c[i]);
        i += 1;
    }
    (s, i)
}

/// Parse the interior of a `${ … }` (without the braces).
fn parse_param(inner: &[char], quoted: bool) -> Result<WordPart, LexError> {
    if inner.is_empty() {
        return Ok(WordPart::Var {
            name: String::new(),
            op: ParamOp::Get,
            quoted,
        });
    }
    // ${#NAME} — length (only when a name follows; else ${#} = positional count).
    if inner[0] == '#' && inner.len() > 1 {
        let (name, ni) = read_name(inner, 1);
        if !name.is_empty() && ni == inner.len() {
            return Ok(WordPart::Var {
                name,
                op: ParamOp::Length,
                quoted,
            });
        }
    }
    // Special single-char names that take no operator.
    if inner.len() == 1 && matches!(inner[0], '?' | '$' | '!' | '#' | '@' | '*' | '-') {
        return Ok(WordPart::Var {
            name: inner[0].to_string(),
            op: ParamOp::Get,
            quoted,
        });
    }
    // Name is either a run of name-chars or a single digit (positional).
    let (name, rest_at) = if inner[0].is_ascii_digit() {
        let mut j = 0;
        while j < inner.len() && inner[j].is_ascii_digit() {
            j += 1;
        }
        (inner[..j].iter().collect::<String>(), j)
    } else {
        read_name(inner, 0)
    };
    let rest = &inner[rest_at..];
    let op = parse_op(rest, quoted)?;
    Ok(WordPart::Var { name, op, quoted })
}

fn parse_op(rest: &[char], quoted: bool) -> Result<ParamOp, LexError> {
    if rest.is_empty() {
        return Ok(ParamOp::Get);
    }
    let starts = |p: &[char]| rest.len() >= p.len() && rest[..p.len()] == *p;
    let word = |from: usize| -> Result<Word, LexError> { lex_param_word(&rest[from..], quoted) };
    // Colon-prefixed forms first.
    if starts(&[':', '-']) {
        return Ok(ParamOp::Default {
            colon: true,
            word: word(2)?,
        });
    }
    if starts(&[':', '=']) {
        return Ok(ParamOp::Assign {
            colon: true,
            word: word(2)?,
        });
    }
    if starts(&[':', '+']) {
        return Ok(ParamOp::Alt {
            colon: true,
            word: word(2)?,
        });
    }
    if starts(&[':', '?']) {
        return Ok(ParamOp::Error {
            colon: true,
            word: word(2)?,
        });
    }
    match rest[0] {
        '-' => Ok(ParamOp::Default {
            colon: false,
            word: word(1)?,
        }),
        '=' => Ok(ParamOp::Assign {
            colon: false,
            word: word(1)?,
        }),
        '+' => Ok(ParamOp::Alt {
            colon: false,
            word: word(1)?,
        }),
        '?' => Ok(ParamOp::Error {
            colon: false,
            word: word(1)?,
        }),
        '#' => {
            if starts(&['#', '#']) {
                Ok(ParamOp::TrimPrefix {
                    longest: true,
                    pat: word(2)?,
                })
            } else {
                Ok(ParamOp::TrimPrefix {
                    longest: false,
                    pat: word(1)?,
                })
            }
        }
        '%' => {
            if starts(&['%', '%']) {
                Ok(ParamOp::TrimSuffix {
                    longest: true,
                    pat: word(2)?,
                })
            } else {
                Ok(ParamOp::TrimSuffix {
                    longest: false,
                    pat: word(1)?,
                })
            }
        }
        _ => Ok(ParamOp::Get),
    }
}

/// Lex a `${...}` operator-argument word (after `:-`, `#`, etc.).
fn lex_param_word(s: &[char], quoted: bool) -> Result<Word, LexError> {
    let mut parts: Word = Vec::new();
    let mut lit = String::new();
    let mut i = 0usize;
    macro_rules! flush {
        () => {
            if !lit.is_empty() {
                parts.push(WordPart::Lit {
                    text: core::mem::take(&mut lit),
                    from_quote: quoted,
                });
            }
        };
    }
    while i < s.len() {
        let ch = s[i];
        match ch {
            '\'' => {
                flush!();
                let (t, ni) = read_squote(s, i + 1)?;
                parts.push(WordPart::Lit {
                    text: t,
                    from_quote: true,
                });
                i = ni;
            }
            '"' => {
                flush!();
                let (qp, ni) = read_dquote(s, i + 1)?;
                parts.extend(qp);
                i = ni;
            }
            '\\' => {
                i += 1;
                if i < s.len() {
                    lit.push(s[i]);
                    i += 1;
                } else {
                    lit.push('\\');
                }
            }
            '$' => {
                let (p, ni) = read_dollar(s, i + 1, quoted)?;
                match p {
                    Some(part) => {
                        flush!();
                        parts.push(part);
                    }
                    None => lit.push('$'),
                }
                i = ni;
            }
            '`' => {
                flush!();
                let (raw, ni) = read_backtick(s, i + 1)?;
                parts.push(WordPart::Sub { raw, quoted });
                i = ni;
            }
            _ => {
                lit.push(ch);
                i += 1;
            }
        }
    }
    flush!();
    Ok(parts)
}

/// Scan from `start` (just past an opener) to the matching `close`, tracking
/// nesting and skipping quotes/escapes/nested `$( … )`/backticks. Returns the
/// inner text and the index just past the closer, or `None` if unterminated.
fn scan_to_matching(c: &[char], start: usize, open: char, close: char) -> Option<(String, usize)> {
    let mut depth = 1usize;
    let mut out = String::new();
    let mut i = start;
    while i < c.len() {
        let ch = c[i];
        if ch == '\\' {
            out.push(ch);
            i += 1;
            if i < c.len() {
                out.push(c[i]);
                i += 1;
            }
            continue;
        }
        if ch == '\'' {
            out.push(ch);
            i += 1;
            while i < c.len() && c[i] != '\'' {
                out.push(c[i]);
                i += 1;
            }
            if i < c.len() {
                out.push('\'');
                i += 1;
            }
            continue;
        }
        if ch == '"' {
            out.push(ch);
            i += 1;
            while i < c.len() && c[i] != '"' {
                if c[i] == '\\' {
                    out.push(c[i]);
                    i += 1;
                    if i < c.len() {
                        out.push(c[i]);
                        i += 1;
                    }
                } else {
                    out.push(c[i]);
                    i += 1;
                }
            }
            if i < c.len() {
                out.push('"');
                i += 1;
            }
            continue;
        }
        if ch == '`' {
            out.push(ch);
            i += 1;
            while i < c.len() && c[i] != '`' {
                if c[i] == '\\' {
                    out.push(c[i]);
                    i += 1;
                    if i < c.len() {
                        out.push(c[i]);
                        i += 1;
                    }
                } else {
                    out.push(c[i]);
                    i += 1;
                }
            }
            if i < c.len() {
                out.push('`');
                i += 1;
            }
            continue;
        }
        if ch == '$' && i + 1 < c.len() && c[i + 1] == '(' {
            out.push('$');
            out.push('(');
            i += 2;
            let (inner, ni) = scan_to_matching(c, i, '(', ')')?;
            out.push_str(&inner);
            out.push(')');
            i = ni;
            continue;
        }
        if ch == open {
            depth += 1;
            out.push(ch);
            i += 1;
            continue;
        }
        if ch == close {
            depth -= 1;
            if depth == 0 {
                return Some((out, i + 1));
            }
            out.push(ch);
            i += 1;
            continue;
        }
        out.push(ch);
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toks(s: &str) -> Vec<Token> {
        tokenize(s).expect("tokenize")
    }

    #[test]
    fn operators_and_words() {
        let t = toks("echo hi | wc -l && true");
        assert!(matches!(t[0], Token::Word(_)));
        assert!(t.contains(&Token::Op(Operator::Pipe)));
        assert!(t.contains(&Token::Op(Operator::AndIf)));
        assert_eq!(*t.last().unwrap(), Token::Eof);
    }

    #[test]
    fn redirs_and_io_number() {
        let t = toks("cmd 2>err >>out <in");
        assert!(t.contains(&Token::IoNumber(2)));
        assert!(t.contains(&Token::Op(Operator::DGreat)));
        assert!(t.contains(&Token::Op(Operator::Great)));
        assert!(t.contains(&Token::Op(Operator::Less)));
    }

    #[test]
    fn dup_op() {
        let t = toks("a 2>&1 | b");
        assert!(t.contains(&Token::Op(Operator::GreatAnd)));
        assert!(t.contains(&Token::IoNumber(2)));
        assert!(t.contains(&Token::Op(Operator::Pipe)));
    }

    #[test]
    fn heredoc_collects_body() {
        let t = toks("cat <<EOF\nhello\nworld\nEOF\necho done");
        let hd = t.iter().find_map(|x| match x {
            Token::Heredoc { body, expand, .. } => Some((body.clone(), *expand)),
            _ => None,
        });
        assert_eq!(hd, Some(("hello\nworld\n".to_string(), true)));
        // `echo done` after the body is still tokenized as a command.
        let words: Vec<_> = t.iter().filter(|x| matches!(x, Token::Word(_))).collect();
        assert_eq!(words.len(), 3); // cat, echo, done
    }

    #[test]
    fn heredoc_quoted_delim_no_expand() {
        let t = toks("cat <<'EOF'\n$x\nEOF\n");
        let hd = t.iter().find_map(|x| match x {
            Token::Heredoc { body, expand, .. } => Some((body.clone(), *expand)),
            _ => None,
        });
        assert_eq!(hd, Some(("$x\n".to_string(), false)));
    }

    #[test]
    fn heredoc_strip_tabs() {
        let t = toks("cat <<-EOF\n\t\tindented\n\tEOF\n");
        let hd = t.iter().find_map(|x| match x {
            Token::Heredoc { body, .. } => Some(body.clone()),
            _ => None,
        });
        assert_eq!(hd, Some("indented\n".to_string()));
    }

    #[test]
    fn heredoc_unterminated_is_incomplete() {
        assert!(matches!(
            tokenize("cat <<EOF\nbody\n"),
            Err(LexError::Incomplete(_))
        ));
    }

    #[test]
    fn newlines_and_parens() {
        let t = toks("(a)\nb");
        assert_eq!(t[0], Token::Op(Operator::LParen));
        assert!(t.contains(&Token::Op(Operator::RParen)));
        assert!(t.contains(&Token::Newline));
    }

    #[test]
    fn arithmetic_vs_cmdsub() {
        let t = toks("echo $((1 + 2))");
        match &t[1] {
            Token::Word(w) => {
                assert!(matches!(&w[0], WordPart::Arith { raw, .. } if raw.trim() == "1 + 2"))
            }
            _ => panic!("expected arith word, got {:?}", t[1]),
        }
        let t = toks("echo $(echo x)");
        match &t[1] {
            Token::Word(w) => {
                assert!(matches!(&w[0], WordPart::Sub { raw, .. } if raw == "echo x"))
            }
            _ => panic!("expected sub word"),
        }
    }

    #[test]
    fn comment_to_eol() {
        let t = toks("echo hi # a comment\necho bye");
        // The comment is dropped; a newline separates the two echos.
        assert!(t.contains(&Token::Newline));
        let words: Vec<_> = t.iter().filter(|x| matches!(x, Token::Word(_))).collect();
        assert_eq!(words.len(), 4); // echo, hi, echo, bye
    }

    #[test]
    fn special_params() {
        let t = toks("echo $? $# $@ $1");
        if let Token::Word(w) = &t[1] {
            assert!(matches!(&w[0], WordPart::Var { name, .. } if name == "?"));
        }
    }

    #[test]
    fn incomplete_quote_is_recoverable() {
        assert!(matches!(
            tokenize("echo \"oops"),
            Err(LexError::Incomplete(_))
        ));
        assert!(matches!(
            tokenize("echo $(oops"),
            Err(LexError::Incomplete(_))
        ));
    }
}
