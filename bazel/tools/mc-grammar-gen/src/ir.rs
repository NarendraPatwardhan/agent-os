//! Versioned, backend-neutral normalized grammar IR.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct Span {
    pub source: String,
    pub start: usize,
    pub end: usize,
    pub line: usize,
    pub column: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Precedence {
    Integer(i32),
    Named(String),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Associativity {
    Plain,
    Left,
    Right,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Rule {
    Empty,
    Literal(String),
    Pattern {
        value: String,
        flags: String,
    },
    Symbol(String),
    Choice(Vec<Rule>),
    Sequence(Vec<Rule>),
    Repeat(Box<Rule>),
    Repeat1(Box<Rule>),
    Field {
        name: String,
        content: Box<Rule>,
    },
    Alias {
        value: String,
        named: bool,
        content: Box<Rule>,
    },
    Precedence {
        associativity: Associativity,
        value: Precedence,
        content: Box<Rule>,
    },
    DynamicPrecedence {
        value: i32,
        content: Box<Rule>,
    },
    Token(Box<Rule>),
    ImmediateToken(Box<Rule>),
    Reserved {
        context: String,
        content: Box<Rule>,
    },
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct SemanticMapping {
    pub concrete: String,
    pub semantic: String,
    pub roles: BTreeMap<String, String>,
    pub traits: Vec<String>,
    pub span: Span,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct GrammarIr {
    pub ir_version: u32,
    pub name: String,
    pub version: String,
    pub start: String,
    pub rules: BTreeMap<String, Rule>,
    pub extras: Vec<Rule>,
    pub externals: Vec<Rule>,
    pub inline: Vec<String>,
    pub supertypes: Vec<String>,
    pub word: Option<String>,
    pub conflicts: Vec<Vec<String>>,
    pub precedences: Vec<Vec<Rule>>,
    pub semantic: Vec<SemanticMapping>,
}

impl GrammarIr {
    pub fn new(name: String) -> Self {
        Self {
            name,
            ..Self::default()
        }
    }
}
