//! Versioned, frontend-neutral grammar IR. The DSL produces this shape; the Tree-sitter adapter is
//! the only code that knows upstream's grammar.json schema.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

pub const GRAMMAR_IR_VERSION: u32 = 1;

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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum Rule {
    Blank,
    String(String),
    Pattern {
        value: String,
        flags: String,
    },
    Symbol(String),
    Choice(Vec<Rule>),
    Seq(Vec<Rule>),
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
    Prec {
        value: Precedence,
        content: Box<Rule>,
    },
    PrecLeft {
        value: Precedence,
        content: Box<Rule>,
    },
    PrecRight {
        value: Precedence,
        content: Box<Rule>,
    },
    PrecDynamic {
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

impl Rule {
    pub fn to_tree_sitter_json(&self) -> Value {
        match self {
            Self::Blank => json!({"type": "BLANK"}),
            Self::String(value) => json!({"type": "STRING", "value": value}),
            Self::Pattern { value, flags } => {
                json!({"type": "PATTERN", "value": value, "flags": flags})
            }
            Self::Symbol(name) => json!({"type": "SYMBOL", "name": name}),
            Self::Choice(members) => {
                json!({"type": "CHOICE", "members": members.iter().map(Self::to_tree_sitter_json).collect::<Vec<_>>() })
            }
            Self::Seq(members) => {
                json!({"type": "SEQ", "members": members.iter().map(Self::to_tree_sitter_json).collect::<Vec<_>>() })
            }
            Self::Repeat(content) => {
                json!({"type": "REPEAT", "content": content.to_tree_sitter_json()})
            }
            Self::Repeat1(content) => {
                json!({"type": "REPEAT1", "content": content.to_tree_sitter_json()})
            }
            Self::Field { name, content } => {
                json!({"type": "FIELD", "name": name, "content": content.to_tree_sitter_json()})
            }
            Self::Alias {
                value,
                named,
                content,
            } => {
                json!({"type": "ALIAS", "value": value, "named": named, "content": content.to_tree_sitter_json()})
            }
            Self::Prec { value, content } => metadata_json("PREC", value, content),
            Self::PrecLeft { value, content } => metadata_json("PREC_LEFT", value, content),
            Self::PrecRight { value, content } => metadata_json("PREC_RIGHT", value, content),
            Self::PrecDynamic { value, content } => {
                json!({"type": "PREC_DYNAMIC", "value": value, "content": content.to_tree_sitter_json()})
            }
            Self::Token(content) => {
                json!({"type": "TOKEN", "content": content.to_tree_sitter_json()})
            }
            Self::ImmediateToken(content) => {
                json!({"type": "IMMEDIATE_TOKEN", "content": content.to_tree_sitter_json()})
            }
            Self::Reserved { context, content } => {
                json!({"type": "RESERVED", "context_name": context, "content": content.to_tree_sitter_json()})
            }
        }
    }
}

fn metadata_json(kind: &str, value: &Precedence, content: &Rule) -> Value {
    let value = match value {
        Precedence::Integer(v) => json!(v),
        Precedence::Named(v) => json!(v),
    };
    json!({"type": kind, "value": value, "content": content.to_tree_sitter_json()})
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
    pub imports: Vec<String>,
    pub dialects: Vec<String>,
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
            ir_version: GRAMMAR_IR_VERSION,
            name,
            ..Self::default()
        }
    }

    pub fn to_tree_sitter_json(&self) -> Value {
        let mut rules = Map::new();
        if let Some(rule) = self.rules.get(&self.start) {
            rules.insert(self.start.clone(), rule.to_tree_sitter_json());
        }
        for (name, rule) in &self.rules {
            if name == &self.start {
                continue;
            }
            rules.insert(name.clone(), rule.to_tree_sitter_json());
        }
        json!({
            "name": self.name,
            "rules": rules,
            "precedences": self.precedences.iter().map(|row| row.iter().map(Rule::to_tree_sitter_json).collect::<Vec<_>>()).collect::<Vec<_>>(),
            "conflicts": self.conflicts,
            "externals": self.externals.iter().map(Rule::to_tree_sitter_json).collect::<Vec<_>>(),
            "extras": self.extras.iter().map(Rule::to_tree_sitter_json).collect::<Vec<_>>(),
            "inline": self.inline,
            "supertypes": self.supertypes,
            "word": self.word,
            "reserved": {},
        })
    }
}
