//! The only layer that knows Tree-sitter's grammar.json schema.

use mc_parser_ir::{Associativity, GrammarIr, Precedence, Rule};
use serde_json::{Map, Value, json};

fn precedence_value(value: &Precedence) -> Value {
    match value {
        Precedence::Integer(value) => json!(value),
        Precedence::Named(value) => json!(value),
    }
}

fn rule(node: &Rule) -> Value {
    match node {
        Rule::Empty => json!({"type": "BLANK"}),
        Rule::Literal(value) => json!({"type": "STRING", "value": value}),
        Rule::Pattern { value, flags } => {
            json!({"type": "PATTERN", "value": value, "flags": flags})
        }
        Rule::Symbol(name) => json!({"type": "SYMBOL", "name": name}),
        Rule::Choice(members) => {
            json!({"type": "CHOICE", "members": members.iter().map(rule).collect::<Vec<_>>() })
        }
        Rule::Sequence(members) => {
            json!({"type": "SEQ", "members": members.iter().map(rule).collect::<Vec<_>>() })
        }
        Rule::Repeat(content) => json!({"type": "REPEAT", "content": rule(content)}),
        Rule::Repeat1(content) => json!({"type": "REPEAT1", "content": rule(content)}),
        Rule::Field { name, content } => {
            json!({"type": "FIELD", "name": name, "content": rule(content)})
        }
        Rule::Alias {
            value,
            named,
            content,
        } => json!({"type": "ALIAS", "value": value, "named": named, "content": rule(content)}),
        Rule::Precedence {
            associativity,
            value,
            content,
        } => {
            let kind = match associativity {
                Associativity::Plain => "PREC",
                Associativity::Left => "PREC_LEFT",
                Associativity::Right => "PREC_RIGHT",
            };
            json!({"type": kind, "value": precedence_value(value), "content": rule(content)})
        }
        Rule::DynamicPrecedence { value, content } => {
            json!({"type": "PREC_DYNAMIC", "value": value, "content": rule(content)})
        }
        Rule::Token(content) => json!({"type": "TOKEN", "content": rule(content)}),
        Rule::ImmediateToken(content) => {
            json!({"type": "IMMEDIATE_TOKEN", "content": rule(content)})
        }
        Rule::Reserved { context, content } => {
            json!({"type": "RESERVED", "context_name": context, "content": rule(content)})
        }
    }
}

pub fn grammar_json(grammar: &GrammarIr) -> Value {
    let mut rules = Map::new();
    if let Some(start) = grammar.rules.get(&grammar.start) {
        rules.insert(grammar.start.clone(), rule(start));
    }
    for (name, production) in &grammar.rules {
        if name != &grammar.start {
            rules.insert(name.clone(), rule(production));
        }
    }
    json!({
        "name": grammar.name,
        "rules": rules,
        "precedences": grammar.precedences.iter().map(|row| row.iter().map(rule).collect::<Vec<_>>()).collect::<Vec<_>>(),
        "conflicts": grammar.conflicts,
        "externals": grammar.externals.iter().map(rule).collect::<Vec<_>>(),
        "extras": grammar.extras.iter().map(rule).collect::<Vec<_>>(),
        "inline": grammar.inline,
        "supertypes": grammar.supertypes,
        "word": grammar.word,
        "reserved": {},
    })
}
