//! Command-line parser: pipelines, redirection, sequence operators.
//!
//! Grammar (left-to-right, no precedence between ; && || &):
//!
//!   line     := stage (sep stage)* sep?
//!   sep      := ';' | '&&' | '||' | '&'
//!   stage    := command ('|' command)*
//!   command  := word+ (redirect)*
//!   redirect := '<' word | '>' word | '>>' word

use alloc::string::{String, ToString};
use alloc::vec::Vec;

/// One command in a pipeline.
#[derive(Debug, Clone)]
pub struct Command {
    pub cmd: String,
    pub args: Vec<String>,
    pub redirect_in: Option<String>,
    pub redirect_out: Option<(String, bool)>, // (path, append)
}

/// A `|`-connected pipeline of commands.
#[derive(Debug, Clone)]
pub struct Pipeline {
    pub commands: Vec<Command>,
}

/// Connector between stages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sep {
    /// `;` — run regardless of previous exit code.
    Then,
    /// `&&` — run only if previous exit code is 0.
    AndAnd,
    /// `||` — run only if previous exit code is non-zero.
    OrOr,
    /// `&` — spawn the previous stage in the background.
    Bg,
}

/// A sequence of pipelines joined by separators. The `Sep` paired with each
/// pipeline is the separator that **follows** it: `echo a && echo b` parses
/// as `[(echo a, AndAnd), (echo b, Then)]`.
#[derive(Debug, Clone)]
pub struct PipelineSeq {
    pub stages: Vec<(Pipeline, Sep)>,
}

/// Parse a line into a sequence of pipelines.
pub fn parse_line(line: &str) -> Option<PipelineSeq> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }

    let pieces = split_top_level(line);
    if pieces.is_empty() {
        return None;
    }

    let mut stages = Vec::new();
    for (text, sep) in pieces {
        let pipeline = parse_pipeline(&text)?;
        if pipeline.commands.is_empty() {
            continue;
        }
        stages.push((pipeline, sep));
    }

    if stages.is_empty() {
        return None;
    }
    Some(PipelineSeq { stages })
}

/// Split a line on top-level `;`, `&&`, `||`, `&`. Returns each segment
/// paired with the separator that followed it. A trailing segment without a
/// separator implicitly gets `Sep::Then`.
fn split_top_level(line: &str) -> Vec<(String, Sep)> {
    let bytes = line.as_bytes();
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut i = 0usize;
    while i < bytes.len() {
        let b = bytes[i];
        let (sep, sep_len): (Option<Sep>, usize) = match b {
            b';' => (Some(Sep::Then), 1),
            b'&' if i + 1 < bytes.len() && bytes[i + 1] == b'&' => (Some(Sep::AndAnd), 2),
            b'&' => (Some(Sep::Bg), 1),
            b'|' if i + 1 < bytes.len() && bytes[i + 1] == b'|' => (Some(Sep::OrOr), 2),
            _ => (None, 0),
        };
        if let Some(sep) = sep {
            let segment = line[start..i].trim().to_string();
            if !segment.is_empty() {
                out.push((segment, sep));
            }
            i += sep_len;
            start = i;
        } else {
            i += 1;
        }
    }
    let tail = line[start..].trim();
    if !tail.is_empty() {
        out.push((tail.to_string(), Sep::Then));
    }
    out
}

/// Parse a `|`-separated pipeline.
fn parse_pipeline(text: &str) -> Option<Pipeline> {
    let mut commands = Vec::new();
    for piece in text.split('|') {
        let piece = piece.trim();
        if piece.is_empty() {
            continue;
        }
        let cmd = parse_command(piece)?;
        commands.push(cmd);
    }
    if commands.is_empty() {
        return None;
    }
    Some(Pipeline { commands })
}

/// Parse a single command word with optional redirections.
///
/// Tokenize once and consume redirect tokens (`<`, `>`, `>>` plus their
/// argument) as we go. Earlier versions only saw `<` *or* `>` because they
/// split-and-replaced `remaining`, dropping any redirect that came after
/// the first one in the line. The token-walk below handles `cmd < in > out`
/// and `cmd > out < in` identically.
fn parse_command(line: &str) -> Option<Command> {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    if tokens.is_empty() {
        return None;
    }

    let mut redirect_in: Option<String> = None;
    let mut redirect_out: Option<(String, bool)> = None;
    let mut words: Vec<String> = Vec::new();

    let mut i = 0;
    while i < tokens.len() {
        let t = tokens[i];
        // `< file` / `> file` / `>> file` — value MUST be a whitespace-
        // separated token; the parser does not split glued forms like
        // `>foo` today. That matches the shell features we support.
        if t == "<" && i + 1 < tokens.len() {
            redirect_in = Some(String::from(tokens[i + 1]));
            i += 2;
            continue;
        }
        if t == ">>" && i + 1 < tokens.len() {
            redirect_out = Some((String::from(tokens[i + 1]), true));
            i += 2;
            continue;
        }
        if t == ">" && i + 1 < tokens.len() {
            redirect_out = Some((String::from(tokens[i + 1]), false));
            i += 2;
            continue;
        }
        // Glued forms: `>file`, `>>file`, `<file`.
        if let Some(rest) = t.strip_prefix(">>") {
            if !rest.is_empty() {
                redirect_out = Some((String::from(rest), true));
                i += 1;
                continue;
            }
        }
        if let Some(rest) = t.strip_prefix('>') {
            if !rest.is_empty() {
                redirect_out = Some((String::from(rest), false));
                i += 1;
                continue;
            }
        }
        if let Some(rest) = t.strip_prefix('<') {
            if !rest.is_empty() {
                redirect_in = Some(String::from(rest));
                i += 1;
                continue;
            }
        }
        words.push(String::from(t));
        i += 1;
    }

    if words.is_empty() {
        return None;
    }
    let cmd = words.remove(0);
    Some(Command {
        cmd,
        args: words,
        redirect_in,
        redirect_out,
    })
}
