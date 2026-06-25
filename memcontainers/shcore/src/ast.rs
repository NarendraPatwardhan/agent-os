//! The shell grammar AST — produced by `parser.rs`, consumed by `exec.rs`.
//!
//! The shape follows the POSIX shell grammar's layering: a [`Script`] is a [`List`]
//! of and-or lists; each [`AndOr`] chains [`Pipeline`]s by `&&`/`||`; each pipeline
//! is a run of [`Command`]s joined by `|`. Compound commands (`if`/`for`/`while`/
//! `case`/groups) nest `List`s, so the whole grammar is mutually recursive through
//! `List`. Words are left *unexpanded* here (`Vec<WordPart>`); expansion happens at
//! exec time, because it depends on runtime state ($vars, $?, the filesystem).

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;

use crate::word::Word;

/// A parsed program (a whole script or one interactive line).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Script {
    pub list: List,
}

/// A sequence of and-or lists separated by `;`, `&`, or newlines.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct List {
    pub items: Vec<ListItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListItem {
    pub and_or: AndOr,
    /// The separator that FOLLOWS this item (`Seq` for `;`/newline, `Async` for `&`).
    pub sep: ListSep,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListSep {
    Seq,
    Async,
}

/// `pipeline (&& | ||) pipeline …` — left-associative, equal precedence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AndOr {
    pub first: Pipeline,
    pub rest: Vec<(AndOrOp, Pipeline)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AndOrOp {
    And,
    Or,
}

/// `! cmd | cmd | …`
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pipeline {
    pub bang: bool,
    pub cmds: Vec<Command>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Simple(SimpleCommand),
    Compound {
        kind: Compound,
        redirs: Vec<Redirect>,
    },
    /// `name() compound` — body is a `Command::Compound`.
    Function {
        name: String,
        body: Box<Command>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SimpleCommand {
    pub assigns: Vec<Assign>,
    pub words: Vec<Word>,
    pub redirs: Vec<Redirect>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Assign {
    pub name: String,
    pub value: Word,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Compound {
    BraceGroup(List),
    Subshell(List),
    If(IfClause),
    For(ForClause),
    While { cond: List, body: List },
    Until { cond: List, body: List },
    Case(CaseClause),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IfClause {
    /// (condition, body) for the `if` and each `elif`.
    pub arms: Vec<(List, List)>,
    pub else_body: Option<List>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ForClause {
    pub var: String,
    /// `None` ⇒ iterate over `"$@"`.
    pub words: Option<Vec<Word>>,
    pub body: List,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaseClause {
    pub subject: Word,
    pub items: Vec<CaseItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaseItem {
    pub patterns: Vec<Word>,
    pub body: List,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Redirect {
    /// Explicit fd (the `2` in `2>err`); `None` ⇒ default for the op.
    pub io_number: Option<u32>,
    pub op: RedirOp,
    pub target: RedirTarget,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RedirOp {
    Read,      // <
    Write,     // >
    Append,    // >>
    ReadWrite, // <>
    Clobber,   // >|
    Heredoc,   // << / <<-
    DupIn,     // <&
    DupOut,    // >&
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RedirTarget {
    /// A filename word (expanded at exec time).
    Word(Word),
    /// `2>&1` / `<&-`: duplicate or close an fd.
    Dup(DupSpec),
    /// Heredoc body (already collected). `expand` is false for a quoted delimiter.
    Here { body: String, expand: bool },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DupSpec {
    Number(u32),
    Close,
}
