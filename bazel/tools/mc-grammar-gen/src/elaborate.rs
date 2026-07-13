//! Module composition, name resolution, fragment expansion, and normalization.

use mc_parser_ast::{
    Associativity as AstAssociativity, Declaration, Expr, ExprKind, Module, ModuleKind, Semantic,
    Span as AstSpan,
};
use mc_parser_ir::{Associativity, GrammarIr, Precedence, Rule, SemanticMapping, Span};
use std::collections::{BTreeMap, BTreeSet};

const MAX_EXPANSION_DEPTH: usize = 64;

#[derive(Clone)]
struct Fragment {
    parameters: Vec<String>,
    expression: Expr,
    span: AstSpan,
}

#[derive(Clone)]
struct PendingRule {
    expression: Expr,
    open: bool,
    token: bool,
    semantic: Option<Semantic>,
    span: AstSpan,
}

struct State {
    fragments: BTreeMap<String, Fragment>,
    rules: BTreeMap<String, PendingRule>,
    slots: BTreeMap<String, Option<Expr>>,
    extras: Vec<Expr>,
    externals: BTreeSet<String>,
    conflicts: Vec<Vec<String>>,
    mappings: Vec<(String, Semantic)>,
    word: Option<String>,
}

impl State {
    fn new() -> Self {
        Self {
            fragments: BTreeMap::new(),
            rules: BTreeMap::new(),
            slots: BTreeMap::new(),
            extras: Vec::new(),
            externals: BTreeSet::new(),
            conflicts: Vec::new(),
            mappings: Vec::new(),
            word: None,
        }
    }
    fn error(span: &AstSpan, message: impl AsRef<str>) -> String {
        format!(
            "{}:{}:{}: {}",
            span.source,
            span.line,
            span.column,
            message.as_ref()
        )
    }
    fn collect_fragments(&mut self, module: &Module) -> Result<(), String> {
        for declaration in &module.declarations {
            if let Declaration::Fragment {
                name,
                parameters,
                expression,
                span,
            } = declaration
            {
                let unique: BTreeSet<_> = parameters.iter().collect();
                if unique.len() != parameters.len() {
                    return Err(Self::error(
                        span,
                        format!("fragment {name} has duplicate parameters"),
                    ));
                }
                if self
                    .fragments
                    .insert(
                        name.clone(),
                        Fragment {
                            parameters: parameters.clone(),
                            expression: expression.clone(),
                            span: span.clone(),
                        },
                    )
                    .is_some()
                {
                    return Err(Self::error(span, format!("duplicate fragment {name}")));
                }
            }
        }
        Ok(())
    }
    fn apply(&mut self, module: &Module) -> Result<(), String> {
        for declaration in &module.declarations {
            match declaration {
                Declaration::Fragment { .. } => {}
                Declaration::Rule {
                    name,
                    expression,
                    open,
                    token,
                    semantic,
                    span,
                } => {
                    if self.slots.contains_key(name) || self.rules.contains_key(name) {
                        return Err(Self::error(span, format!("duplicate production {name}")));
                    }
                    if semantic.is_some()
                        && self.mappings.iter().any(|(concrete, _)| concrete == name)
                    {
                        return Err(Self::error(
                            span,
                            format!("duplicate semantic mapping for {name}"),
                        ));
                    }
                    self.rules.insert(
                        name.clone(),
                        PendingRule {
                            expression: expression.clone(),
                            open: *open,
                            token: *token,
                            semantic: semantic.clone(),
                            span: span.clone(),
                        },
                    );
                }
                Declaration::Extend {
                    name,
                    expression,
                    span,
                } => {
                    let Some(rule) = self.rules.get_mut(name) else {
                        return Err(Self::error(
                            span,
                            format!("cannot extend unknown production {name}"),
                        ));
                    };
                    if !rule.open {
                        return Err(Self::error(span, format!("production {name} is not open")));
                    }
                    let old = rule.expression.clone();
                    rule.expression = Expr {
                        kind: ExprKind::Choice(vec![old, expression.clone()]),
                        span: rule.span.clone(),
                    };
                }
                Declaration::Slot { name, span } => {
                    if self.rules.contains_key(name)
                        || self.slots.insert(name.clone(), None).is_some()
                    {
                        return Err(Self::error(span, format!("duplicate slot {name}")));
                    }
                }
                Declaration::Fill {
                    name,
                    expression,
                    span,
                } => {
                    let Some(slot) = self.slots.get_mut(name) else {
                        return Err(Self::error(
                            span,
                            format!("cannot fill unknown slot {name}"),
                        ));
                    };
                    if slot.replace(expression.clone()).is_some() {
                        return Err(Self::error(span, format!("slot {name} is already filled")));
                    }
                }
                Declaration::Skip { expression, .. } => self.extras.push(expression.clone()),
                Declaration::Externals { names, span } => {
                    for name in names {
                        if !self.externals.insert(name.clone()) {
                            return Err(Self::error(span, format!("duplicate external {name}")));
                        }
                    }
                }
                Declaration::Word { name, span } => {
                    if self.word.replace(name.clone()).is_some() {
                        return Err(Self::error(span, "duplicate word declaration"));
                    }
                }
                Declaration::Conflict { names, .. } => self.conflicts.push(names.clone()),
                Declaration::Mapping {
                    concrete, semantic, ..
                } => {
                    if self
                        .mappings
                        .iter()
                        .any(|(existing, _)| existing == concrete)
                        || self
                            .rules
                            .get(concrete)
                            .is_some_and(|rule| rule.semantic.is_some())
                    {
                        return Err(Self::error(
                            &semantic.span,
                            format!("duplicate semantic mapping for {concrete}"),
                        ));
                    }
                    self.mappings.push((concrete.clone(), semantic.clone()));
                }
                Declaration::OperatorTable {
                    name,
                    operand,
                    prefix,
                    rows,
                    semantic,
                    span,
                } => {
                    if self.rules.contains_key(name) || self.slots.contains_key(name) {
                        return Err(Self::error(span, format!("duplicate production {name}")));
                    }
                    if semantic.is_some()
                        && self.mappings.iter().any(|(concrete, _)| concrete == name)
                    {
                        return Err(Self::error(
                            span,
                            format!("duplicate semantic mapping for {name}"),
                        ));
                    }
                    let mut alternatives = Vec::new();
                    for row in rows {
                        let operator = Expr {
                            kind: ExprKind::Field {
                                name: "operator".into(),
                                content: Box::new(row.operators.clone()),
                            },
                            span: row.span.clone(),
                        };
                        let mut sequence = Vec::new();
                        if *prefix {
                            sequence.push(operator);
                            sequence.push(field("argument", symbol(operand, &row.span), &row.span));
                        } else {
                            sequence.push(field("left", symbol(operand, &row.span), &row.span));
                            sequence.push(operator);
                            sequence.push(field("right", symbol(operand, &row.span), &row.span));
                        }
                        alternatives.push(Expr {
                            kind: ExprKind::Precedence {
                                associativity: row.associativity,
                                value: row.precedence,
                                content: Box::new(Expr {
                                    kind: ExprKind::Sequence(sequence),
                                    span: row.span.clone(),
                                }),
                            },
                            span: row.span.clone(),
                        });
                    }
                    self.rules.insert(
                        name.clone(),
                        PendingRule {
                            expression: Expr {
                                kind: ExprKind::Choice(alternatives),
                                span: span.clone(),
                            },
                            open: false,
                            token: false,
                            semantic: semantic.clone(),
                            span: span.clone(),
                        },
                    );
                }
            }
        }
        Ok(())
    }
}

fn symbol(name: &str, span: &AstSpan) -> Expr {
    Expr {
        kind: ExprKind::Symbol(name.into()),
        span: span.clone(),
    }
}
fn field(name: &str, content: Expr, span: &AstSpan) -> Expr {
    Expr {
        kind: ExprKind::Field {
            name: name.into(),
            content: Box::new(content),
        },
        span: span.clone(),
    }
}

enum Lowered {
    Rule(Rule),
    Missing,
}

struct Lowerer<'a> {
    state: &'a State,
}

impl Lowerer<'_> {
    fn expression(
        &self,
        expression: &Expr,
        environment: &BTreeMap<String, Expr>,
        stack: &mut Vec<String>,
        depth: usize,
    ) -> Result<Lowered, String> {
        if depth > MAX_EXPANSION_DEPTH {
            return Err(State::error(
                &expression.span,
                format!(
                    "fragment expansion exceeds {MAX_EXPANSION_DEPTH}: {}",
                    stack.join(" -> ")
                ),
            ));
        }
        let next = depth + 1;
        match &expression.kind {
            ExprKind::Literal(value) => Ok(Lowered::Rule(Rule::Literal(value.clone()))),
            ExprKind::Pattern { value, flags } => Ok(Lowered::Rule(Rule::Pattern {
                value: value.clone(),
                flags: flags.clone(),
            })),
            ExprKind::Symbol(name) => {
                if let Some(bound) = environment.get(name) {
                    // Evaluate an argument in the caller environment, not through the parameter
                    // binding itself (`separated(item, ",")` must leave `item` as a production).
                    let bound = bound.clone();
                    let mut caller = environment.clone();
                    caller.remove(name);
                    return self.expression(&bound, &caller, stack, next);
                }
                if let Some(slot) = self.state.slots.get(name) {
                    return match slot {
                        Some(value) => self.expression(value, environment, stack, next),
                        None => Ok(Lowered::Missing),
                    };
                }
                Ok(Lowered::Rule(Rule::Symbol(name.clone())))
            }
            ExprKind::Call { name, args } => {
                let fragment = self.state.fragments.get(name).ok_or_else(|| {
                    State::error(&expression.span, format!("unknown fragment {name}"))
                })?;
                if fragment.parameters.len() != args.len() {
                    return Err(State::error(
                        &expression.span,
                        format!(
                            "fragment {name} expects {} arguments, got {}",
                            fragment.parameters.len(),
                            args.len()
                        ),
                    ));
                }
                if stack.iter().any(|entry| entry == name) {
                    return Err(State::error(
                        &fragment.span,
                        format!("recursive fragment: {} -> {name}", stack.join(" -> ")),
                    ));
                }
                let mut child = environment.clone();
                for (parameter, argument) in fragment.parameters.iter().zip(args) {
                    child.insert(parameter.clone(), argument.clone());
                }
                stack.push(name.clone());
                let result = self.expression(&fragment.expression, &child, stack, next);
                stack.pop();
                result
            }
            ExprKind::Choice(values) => {
                let mut rules = Vec::new();
                for value in values {
                    match self.expression(value, environment, stack, next)? {
                        Lowered::Missing => {}
                        Lowered::Rule(Rule::Choice(nested)) => rules.extend(nested),
                        Lowered::Rule(rule) => rules.push(rule),
                    }
                }
                Ok(match rules.len() {
                    0 => Lowered::Missing,
                    1 => Lowered::Rule(rules.pop().unwrap()),
                    _ => Lowered::Rule(Rule::Choice(rules)),
                })
            }
            ExprKind::Sequence(values) => {
                let mut rules = Vec::new();
                for value in values {
                    match self.expression(value, environment, stack, next)? {
                        Lowered::Missing => return Ok(Lowered::Missing),
                        Lowered::Rule(Rule::Empty) => {}
                        Lowered::Rule(Rule::Sequence(nested)) => rules.extend(nested),
                        Lowered::Rule(rule) => rules.push(rule),
                    }
                }
                Ok(match rules.len() {
                    0 => Lowered::Rule(Rule::Empty),
                    1 => Lowered::Rule(rules.pop().unwrap()),
                    _ => Lowered::Rule(Rule::Sequence(rules)),
                })
            }
            ExprKind::Optional(value) => {
                Ok(match self.expression(value, environment, stack, next)? {
                    Lowered::Missing => Lowered::Rule(Rule::Empty),
                    Lowered::Rule(rule) => Lowered::Rule(Rule::Choice(vec![rule, Rule::Empty])),
                })
            }
            ExprKind::Repeat(value) => {
                Ok(match self.expression(value, environment, stack, next)? {
                    Lowered::Missing => Lowered::Rule(Rule::Empty),
                    Lowered::Rule(rule) => Lowered::Rule(Rule::Repeat(Box::new(rule))),
                })
            }
            ExprKind::Repeat1(value) => {
                Ok(match self.expression(value, environment, stack, next)? {
                    Lowered::Missing => Lowered::Missing,
                    Lowered::Rule(rule) => Lowered::Rule(Rule::Repeat1(Box::new(rule))),
                })
            }
            ExprKind::Field { name, content } => {
                Ok(match self.expression(content, environment, stack, next)? {
                    Lowered::Missing => Lowered::Missing,
                    Lowered::Rule(rule) => Lowered::Rule(Rule::Field {
                        name: name.clone(),
                        content: Box::new(rule),
                    }),
                })
            }
            ExprKind::Precedence {
                associativity,
                value,
                content,
            } => Ok(match self.expression(content, environment, stack, next)? {
                Lowered::Missing => Lowered::Missing,
                Lowered::Rule(rule) => Lowered::Rule(Rule::Precedence {
                    associativity: match associativity {
                        AstAssociativity::Plain => Associativity::Plain,
                        AstAssociativity::Left => Associativity::Left,
                        AstAssociativity::Right => Associativity::Right,
                    },
                    value: Precedence::Integer(*value),
                    content: Box::new(rule),
                }),
            }),
        }
    }
}

fn ir_span(span: &AstSpan) -> Span {
    Span {
        source: span.source.clone(),
        start: span.start,
        end: span.end,
        line: span.line,
        column: span.column,
    }
}

fn validate_semantic(semantic: &Semantic) -> Result<(), String> {
    let roles: BTreeSet<_> = semantic.roles.iter().map(|(name, _)| name).collect();
    if roles.len() != semantic.roles.len() {
        return Err(State::error(
            &semantic.span,
            "semantic mapping contains a duplicate role",
        ));
    }
    let traits: BTreeSet<_> = semantic.traits.iter().collect();
    if traits.len() != semantic.traits.len() {
        return Err(State::error(
            &semantic.span,
            "semantic mapping contains a duplicate trait",
        ));
    }
    Ok(())
}

fn fields(rule: &Rule, output: &mut BTreeSet<String>) {
    match rule {
        Rule::Field { name, content } => {
            output.insert(name.clone());
            fields(content, output);
        }
        Rule::Choice(values) | Rule::Sequence(values) => {
            for value in values {
                fields(value, output);
            }
        }
        Rule::Repeat(value)
        | Rule::Repeat1(value)
        | Rule::Token(value)
        | Rule::ImmediateToken(value)
        | Rule::Precedence { content: value, .. }
        | Rule::DynamicPrecedence { content: value, .. }
        | Rule::Reserved { content: value, .. }
        | Rule::Alias { content: value, .. } => fields(value, output),
        _ => {}
    }
}

fn references(rule: &Rule, output: &mut BTreeSet<String>) {
    match rule {
        Rule::Symbol(name) => {
            output.insert(name.clone());
        }
        Rule::Choice(values) | Rule::Sequence(values) => {
            for value in values {
                references(value, output);
            }
        }
        Rule::Repeat(value)
        | Rule::Repeat1(value)
        | Rule::Token(value)
        | Rule::ImmediateToken(value)
        | Rule::Field { content: value, .. }
        | Rule::Precedence { content: value, .. }
        | Rule::DynamicPrecedence { content: value, .. }
        | Rule::Reserved { content: value, .. }
        | Rule::Alias { content: value, .. } => references(value, output),
        _ => {}
    }
}

fn nullable(rule: &Rule, rules: &BTreeMap<String, Rule>, visiting: &mut BTreeSet<String>) -> bool {
    match rule {
        Rule::Empty => true,
        Rule::Choice(values) => values.iter().any(|value| nullable(value, rules, visiting)),
        Rule::Sequence(values) => values.iter().all(|value| nullable(value, rules, visiting)),
        Rule::Repeat(_) => true,
        Rule::Repeat1(value)
        | Rule::Token(value)
        | Rule::ImmediateToken(value)
        | Rule::Field { content: value, .. }
        | Rule::Precedence { content: value, .. }
        | Rule::DynamicPrecedence { content: value, .. }
        | Rule::Reserved { content: value, .. }
        | Rule::Alias { content: value, .. } => nullable(value, rules, visiting),
        Rule::Symbol(name) => {
            if !visiting.insert(name.clone()) {
                return false;
            }
            let result = rules
                .get(name)
                .is_some_and(|rule| nullable(rule, rules, visiting));
            visiting.remove(name);
            result
        }
        Rule::Literal(value) => value.is_empty(),
        Rule::Pattern { value, .. } => value.is_empty(),
    }
}

fn validate_repetitions(
    rule: &Rule,
    rules: &BTreeMap<String, Rule>,
    owner: &str,
) -> Result<(), String> {
    match rule {
        Rule::Repeat(value) | Rule::Repeat1(value) => {
            if nullable(value, rules, &mut BTreeSet::new()) {
                return Err(format!("production {owner} repeats a nullable expression"));
            }
            validate_repetitions(value, rules, owner)
        }
        Rule::Choice(values) | Rule::Sequence(values) => {
            for value in values {
                validate_repetitions(value, rules, owner)?;
            }
            Ok(())
        }
        Rule::Token(value)
        | Rule::ImmediateToken(value)
        | Rule::Field { content: value, .. }
        | Rule::Precedence { content: value, .. }
        | Rule::DynamicPrecedence { content: value, .. }
        | Rule::Reserved { content: value, .. }
        | Rule::Alias { content: value, .. } => validate_repetitions(value, rules, owner),
        _ => Ok(()),
    }
}

fn validate_lexical(rule: &Rule, owner: &str) -> Result<(), String> {
    match rule {
        Rule::Literal(_) | Rule::Pattern { .. } => Ok(()),
        Rule::Choice(values) | Rule::Sequence(values) => {
            for value in values {
                validate_lexical(value, owner)?;
            }
            Ok(())
        }
        Rule::Repeat(value)
        | Rule::Repeat1(value)
        | Rule::Precedence { content: value, .. }
        | Rule::DynamicPrecedence { content: value, .. } => validate_lexical(value, owner),
        Rule::Token(value) | Rule::ImmediateToken(value) => validate_lexical(value, owner),
        Rule::Empty => Err(format!("token production {owner} matches the empty string")),
        Rule::Symbol(name) => Err(format!(
            "token production {owner} references {name}; lexical rules must contain only literals and patterns"
        )),
        Rule::Field { .. } | Rule::Alias { .. } | Rule::Reserved { .. } => Err(format!(
            "token production {owner} contains syntax-only metadata"
        )),
    }
}

pub fn elaborate(root: Module, modules: Vec<(String, Module)>) -> Result<GrammarIr, String> {
    if root.kind != ModuleKind::Grammar {
        return Err(State::error(&root.span, "root file must declare a grammar"));
    }
    if root.version.is_empty() {
        return Err(State::error(
            &root.span,
            "grammar header requires a version",
        ));
    }
    let mut supplied = BTreeMap::new();
    for (name, module) in modules {
        if supplied.insert(name.clone(), module).is_some() {
            return Err(State::error(
                &root.span,
                format!("duplicate supplied family {name}"),
            ));
        }
    }
    let declared: BTreeSet<_> = root.uses.iter().cloned().collect();
    if declared.len() != root.uses.len() {
        return Err(State::error(&root.span, "duplicate use declaration"));
    }
    for name in &declared {
        if !supplied.contains_key(name) {
            return Err(State::error(
                &root.span,
                format!("used family {name} is not a declared Bazel input"),
            ));
        }
    }
    for name in supplied.keys() {
        if !declared.contains(name) {
            return Err(State::error(
                &root.span,
                format!("Bazel supplied family {name}, but the grammar does not use it"),
            ));
        }
    }
    let mut ordered = Vec::new();
    for name in &root.uses {
        let module = &supplied[name];
        if module.kind != ModuleKind::Family {
            return Err(State::error(
                &module.span,
                format!("used module {name} is not a family"),
            ));
        }
        if module.name != *name {
            return Err(State::error(
                &module.span,
                format!("family declares {}, but Bazel names it {name}", module.name),
            ));
        }
        if module.version.is_empty() {
            return Err(State::error(
                &module.span,
                format!("family {name} header requires a version"),
            ));
        }
        if module.start.is_some() || !module.uses.is_empty() {
            return Err(State::error(
                &module.span,
                format!(
                    "family {name} cannot declare start or use; composition order belongs to the root grammar"
                ),
            ));
        }
        ordered.push(module);
    }
    ordered.push(&root);

    let mut state = State::new();
    for module in &ordered {
        state.collect_fragments(module)?;
    }
    for module in &ordered {
        state.apply(module)?;
    }

    let mut grammar = GrammarIr::new(root.name.clone());
    grammar.version = root.version.clone();
    grammar.start = root.start.clone().unwrap();
    grammar.conflicts = state.conflicts.clone();
    grammar.word = state.word.clone();
    grammar.externals = state.externals.iter().cloned().map(Rule::Symbol).collect();

    let lowerer = Lowerer { state: &state };
    for (name, pending) in &state.rules {
        let lowered =
            lowerer.expression(&pending.expression, &BTreeMap::new(), &mut Vec::new(), 0)?;
        let Lowered::Rule(mut rule) = lowered else {
            return Err(State::error(
                &pending.span,
                format!("production {name} resolves to an unavailable slot"),
            ));
        };
        if pending.token {
            rule = Rule::Token(Box::new(rule));
        }
        if let Some(semantic) = &pending.semantic {
            validate_semantic(semantic)?;
            let mut available = BTreeSet::new();
            fields(&rule, &mut available);
            let mut roles = BTreeMap::new();
            for (canonical, concrete) in &semantic.roles {
                if !available.contains(concrete) {
                    return Err(State::error(
                        &semantic.span,
                        format!(
                            "semantic role {canonical} refers to missing field {concrete} in {name}"
                        ),
                    ));
                }
                roles.insert(canonical.clone(), concrete.clone());
            }
            grammar.semantic.push(SemanticMapping {
                concrete: name.clone(),
                semantic: semantic.kind.clone(),
                roles,
                traits: semantic.traits.clone(),
                span: ir_span(&semantic.span),
            });
        }
        grammar.rules.insert(name.clone(), rule);
    }
    for (name, expression) in &state.slots {
        let Some(expression) = expression else {
            continue;
        };
        let Lowered::Rule(rule) =
            lowerer.expression(expression, &BTreeMap::new(), &mut Vec::new(), 0)?
        else {
            return Err(format!(
                "filled slot {name} resolves to an unavailable slot"
            ));
        };
        grammar.rules.insert(name.clone(), rule);
    }
    for expression in &state.extras {
        let Lowered::Rule(rule) =
            lowerer.expression(expression, &BTreeMap::new(), &mut Vec::new(), 0)?
        else {
            return Err(State::error(
                &expression.span,
                "skip expression resolves to an unavailable slot",
            ));
        };
        match rule {
            Rule::Choice(rules) => grammar.extras.extend(rules),
            rule => grammar.extras.push(rule),
        }
    }
    for (concrete, semantic) in &state.mappings {
        validate_semantic(semantic)?;
        if !grammar.rules.contains_key(concrete) && !state.externals.contains(concrete) {
            return Err(State::error(
                &semantic.span,
                format!("semantic mapping refers to unknown production {concrete}"),
            ));
        }
        grammar.semantic.push(SemanticMapping {
            concrete: concrete.clone(),
            semantic: semantic.kind.clone(),
            roles: BTreeMap::new(),
            traits: semantic.traits.clone(),
            span: ir_span(&semantic.span),
        });
    }
    if !grammar.rules.contains_key(&grammar.start) {
        return Err(format!("start production {} is not defined", grammar.start));
    }
    let names: BTreeSet<_> = grammar
        .rules
        .keys()
        .chain(state.externals.iter())
        .cloned()
        .collect();
    for (owner, rule) in &grammar.rules {
        let mut refs = BTreeSet::new();
        references(rule, &mut refs);
        for name in refs {
            if !names.contains(&name) {
                return Err(format!(
                    "production {owner} references undefined production {name}"
                ));
            }
        }
        validate_repetitions(rule, &grammar.rules, owner)?;
        if matches!(rule, Rule::Token(_)) {
            validate_lexical(rule, owner)?;
        }
    }
    for extra in &grammar.extras {
        let mut refs = BTreeSet::new();
        references(extra, &mut refs);
        for name in refs {
            if !names.contains(&name) {
                return Err(format!(
                    "skip expression references undefined production {name}"
                ));
            }
        }
    }
    for conflict in &grammar.conflicts {
        for name in conflict {
            if !grammar.rules.contains_key(name) {
                return Err(format!("conflict references undefined production {name}"));
            }
        }
    }
    if let Some(word) = &grammar.word {
        if !grammar.rules.contains_key(word) {
            return Err(format!("word production {word} is not defined"));
        }
    }
    Ok(grammar)
}
