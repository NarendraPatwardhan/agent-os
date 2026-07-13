//! Bootstrap parser for the declarative `.grammar` language. It is intentionally handwritten:
//! parser generation must never depend on an already-generated parser or a guest image.

use mc_parser_ir::{GRAMMAR_IR_VERSION, GrammarIr, Precedence, Rule, SemanticMapping, Span};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

const MAX_SOURCE_BYTES: usize = 4 * 1024 * 1024;
const MAX_RULES: usize = 8192;
const MAX_TEMPLATES: usize = 1024;
const MAX_EXPANSION_DEPTH: usize = 64;

#[derive(Clone, Debug, PartialEq)]
enum TokenKind {
    Ident(String),
    String(String),
    Number(i32),
    LBrace,
    RBrace,
    LParen,
    RParen,
    Comma,
    Eq,
    Semi,
    Pipe,
    Question,
    Star,
    Plus,
    Arrow,
    Eof,
}

#[derive(Clone, Debug)]
struct Token {
    kind: TokenKind,
    start: usize,
    end: usize,
    line: usize,
    column: usize,
}

#[derive(Clone, Debug)]
pub struct DslError {
    pub source: String,
    pub line: usize,
    pub column: usize,
    pub message: String,
}

impl fmt::Display for DslError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}:{}: {}",
            self.source, self.line, self.column, self.message
        )
    }
}
impl std::error::Error for DslError {}

struct Lexer<'a> {
    source: &'a str,
    name: &'a str,
    at: usize,
    line: usize,
    column: usize,
}

impl<'a> Lexer<'a> {
    fn new(source: &'a str, name: &'a str) -> Self {
        Self {
            source,
            name,
            at: 0,
            line: 1,
            column: 1,
        }
    }
    fn err(&self, message: impl Into<String>) -> DslError {
        DslError {
            source: self.name.into(),
            line: self.line,
            column: self.column,
            message: message.into(),
        }
    }
    fn peek(&self) -> Option<char> {
        self.source[self.at..].chars().next()
    }
    fn bump(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.at += c.len_utf8();
        if c == '\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        Some(c)
    }
    fn skip(&mut self) {
        loop {
            while self.peek().is_some_and(char::is_whitespace) {
                self.bump();
            }
            if self.source[self.at..].starts_with("//") || self.peek() == Some('#') {
                while self.peek().is_some_and(|c| c != '\n') {
                    self.bump();
                }
                continue;
            }
            break;
        }
    }
    fn token(&mut self) -> Result<Token, DslError> {
        self.skip();
        let (start, line, column) = (self.at, self.line, self.column);
        let Some(c) = self.bump() else {
            return Ok(Token {
                kind: TokenKind::Eof,
                start,
                end: start,
                line,
                column,
            });
        };
        let kind = match c {
            '{' => TokenKind::LBrace,
            '}' => TokenKind::RBrace,
            '(' => TokenKind::LParen,
            ')' => TokenKind::RParen,
            ',' => TokenKind::Comma,
            '=' => TokenKind::Eq,
            ';' => TokenKind::Semi,
            '|' => TokenKind::Pipe,
            '?' => TokenKind::Question,
            '*' => TokenKind::Star,
            '+' => TokenKind::Plus,
            '-' if self.peek() == Some('>') => {
                self.bump();
                TokenKind::Arrow
            }
            '"' => {
                let mut out = String::new();
                loop {
                    match self.bump().ok_or_else(|| self.err("unterminated string"))? {
                        '"' => break,
                        '\\' => match self.bump().ok_or_else(|| self.err("unterminated escape"))? {
                            'n' => out.push('\n'),
                            'r' => out.push('\r'),
                            't' => out.push('\t'),
                            '"' => out.push('"'),
                            '\\' => out.push('\\'),
                            other => return Err(self.err(format!("unsupported escape \\{other}"))),
                        },
                        other => out.push(other),
                    }
                }
                TokenKind::String(out)
            }
            c if c.is_ascii_digit()
                || (c == '-' && self.peek().is_some_and(|n| n.is_ascii_digit())) =>
            {
                let mut s = String::from(c);
                while self.peek().is_some_and(|n| n.is_ascii_digit()) {
                    s.push(self.bump().unwrap());
                }
                TokenKind::Number(s.parse().map_err(|_| self.err("integer is outside i32"))?)
            }
            c if is_ident_start(c) => {
                let mut s = String::from(c);
                while self.peek().is_some_and(is_ident_continue) {
                    s.push(self.bump().unwrap());
                }
                TokenKind::Ident(s)
            }
            other => return Err(self.err(format!("unexpected character {other:?}"))),
        };
        Ok(Token {
            kind,
            start,
            end: self.at,
            line,
            column,
        })
    }
}

fn is_ident_start(c: char) -> bool {
    c == '_' || c.is_ascii_alphabetic()
}
fn is_ident_continue(c: char) -> bool {
    is_ident_start(c) || c.is_ascii_digit() || matches!(c, '-' | '.' | '/')
}

#[derive(Clone, Debug)]
enum Expr {
    String(String),
    Symbol(String),
    Number(i32),
    Call(String, Vec<Expr>),
    Choice(Vec<Expr>),
    Optional(Box<Expr>),
    Repeat(Box<Expr>),
    Repeat1(Box<Expr>),
}
#[derive(Clone)]
struct Template {
    params: Vec<String>,
    body: Expr,
}
enum Mutation {
    Replace(String, Expr),
    Extend(String, Expr),
    Remove(String),
}

struct Parser {
    name: String,
    tokens: Vec<Token>,
    at: usize,
    grammar: GrammarIr,
    raw_rules: BTreeMap<String, Expr>,
    templates: BTreeMap<String, Template>,
    mutations: Vec<Mutation>,
}

impl Parser {
    fn token(&self) -> &Token {
        &self.tokens[self.at]
    }
    fn bump(&mut self) -> Token {
        let t = self.tokens[self.at].clone();
        if t.kind != TokenKind::Eof {
            self.at += 1;
        }
        t
    }
    fn err(&self, message: impl Into<String>) -> DslError {
        let t = self.token();
        DslError {
            source: self.name.clone(),
            line: t.line,
            column: t.column,
            message: message.into(),
        }
    }
    fn eat(&mut self, kind: &TokenKind) -> bool {
        if &self.token().kind == kind {
            self.bump();
            true
        } else {
            false
        }
    }
    fn expect(&mut self, kind: &TokenKind) -> Result<(), DslError> {
        if self.eat(kind) {
            Ok(())
        } else {
            Err(self.err(format!("expected {kind:?}, found {:?}", self.token().kind)))
        }
    }
    fn ident(&mut self) -> Result<String, DslError> {
        match self.bump().kind {
            TokenKind::Ident(v) | TokenKind::String(v) => Ok(v),
            other => Err(self.err(format!("expected name, found {other:?}"))),
        }
    }
    fn optional_semi(&mut self) {
        self.eat(&TokenKind::Semi);
    }

    fn parse(mut self) -> Result<GrammarIr, DslError> {
        while self.token().kind != TokenKind::Eof {
            let keyword = self.ident()?;
            match keyword.as_str() {
                "language" | "module" => self.grammar.name = self.ident()?,
                "version" => self.grammar.version = self.ident()?,
                "start" | "top" => self.grammar.start = self.ident()?,
                "import" | "extends" => {
                    let value = self.ident()?;
                    self.grammar.imports.push(value);
                }
                "dialect" => {
                    let value = self.ident()?;
                    self.grammar.dialects.push(value);
                }
                "word" => self.grammar.word = Some(self.ident()?),
                "inline" => {
                    let values = self.name_set()?;
                    self.grammar.inline.extend(values);
                }
                "supertypes" => {
                    let values = self.name_set()?;
                    self.grammar.supertypes.extend(values);
                }
                "extras" => {
                    let values = self.expr_set()?;
                    self.grammar.extras.extend(self.eval_all(values)?);
                }
                "externals" => {
                    let values = self.name_set()?;
                    self.grammar
                        .externals
                        .extend(values.into_iter().map(Rule::Symbol));
                }
                "conflict" => {
                    let values = self.name_set()?;
                    self.grammar.conflicts.push(values);
                }
                "precedence" => {
                    let values = self.expr_set()?;
                    self.grammar.precedences.push(self.eval_all(values)?);
                }
                "template" => self.parse_template()?,
                "rule" | "token" => self.parse_rule(keyword == "token")?,
                "replace" | "extend" | "remove" => self.parse_mutation(&keyword)?,
                "vocabulary" => self.parse_vocabulary()?,
                other => return Err(self.err(format!("unknown declaration {other}"))),
            }
            self.optional_semi();
        }
        if self.grammar.name.is_empty() {
            return Err(self.err("missing language/module declaration"));
        }
        if self.raw_rules.len() > MAX_RULES {
            return Err(self.err(format!("rule limit exceeded ({MAX_RULES})")));
        }
        let raw = std::mem::take(&mut self.raw_rules);
        for (name, expr) in raw {
            let rule = self.eval(&expr, &BTreeMap::new(), &mut Vec::new(), 0)?;
            self.grammar.rules.insert(name, rule);
        }
        for mutation in std::mem::take(&mut self.mutations) {
            match mutation {
                Mutation::Remove(name) => {
                    if self.grammar.rules.remove(&name).is_none() {
                        return Err(self.err(format!("cannot remove unknown rule {name}")));
                    }
                }
                Mutation::Replace(name, expr) => {
                    if !self.grammar.rules.contains_key(&name) {
                        return Err(self.err(format!("cannot replace unknown rule {name}")));
                    }
                    let rule = self.eval(&expr, &BTreeMap::new(), &mut Vec::new(), 0)?;
                    self.grammar.rules.insert(name, rule);
                }
                Mutation::Extend(name, expr) => {
                    let Some(old) = self.grammar.rules.remove(&name) else {
                        return Err(self.err(format!("cannot extend unknown rule {name}")));
                    };
                    let add = self.eval(&expr, &BTreeMap::new(), &mut Vec::new(), 0)?;
                    let mut choices = match old {
                        Rule::Choice(v) => v,
                        other => vec![other],
                    };
                    choices.push(add);
                    self.grammar.rules.insert(name, Rule::Choice(choices));
                }
            }
        }
        if self.grammar.start.is_empty() {
            self.grammar.start = self
                .grammar
                .rules
                .keys()
                .next()
                .cloned()
                .unwrap_or_default();
        }
        if self.grammar.start.is_empty() || !self.grammar.rules.contains_key(&self.grammar.start) {
            return Err(self.err(format!(
                "start rule {:?} is not defined",
                self.grammar.start
            )));
        }
        Ok(self.grammar)
    }

    fn parse_rule(&mut self, token: bool) -> Result<(), DslError> {
        let name = self.ident()?;
        self.expect(&TokenKind::Eq)?;
        let mut expr = self.expr()?;
        if token {
            expr = Expr::Call("token".into(), vec![expr]);
        }
        if self.raw_rules.insert(name.clone(), expr).is_some() {
            return Err(self.err(format!("duplicate rule {name}")));
        }
        Ok(())
    }
    fn parse_template(&mut self) -> Result<(), DslError> {
        if self.templates.len() >= MAX_TEMPLATES {
            return Err(self.err(format!("template limit exceeded ({MAX_TEMPLATES})")));
        }
        let name = self.ident()?;
        self.expect(&TokenKind::LParen)?;
        let mut params = Vec::new();
        if !self.eat(&TokenKind::RParen) {
            loop {
                params.push(self.ident()?);
                if self.eat(&TokenKind::RParen) {
                    break;
                }
                self.expect(&TokenKind::Comma)?;
            }
        }
        let unique: BTreeSet<_> = params.iter().collect();
        if unique.len() != params.len() {
            return Err(self.err("duplicate template parameter"));
        }
        self.expect(&TokenKind::Eq)?;
        let body = self.expr()?;
        if self
            .templates
            .insert(name.clone(), Template { params, body })
            .is_some()
        {
            return Err(self.err(format!("duplicate template {name}")));
        }
        Ok(())
    }
    fn parse_mutation(&mut self, op: &str) -> Result<(), DslError> {
        self.eat(&TokenKind::Ident("rule".into()));
        let name = self.ident()?;
        match op {
            "remove" => self.mutations.push(Mutation::Remove(name)),
            "replace" | "extend" => {
                self.expect(&TokenKind::Eq)?;
                let expr = self.expr()?;
                self.mutations.push(if op == "replace" {
                    Mutation::Replace(name, expr)
                } else {
                    Mutation::Extend(name, expr)
                });
            }
            _ => unreachable!(),
        }
        Ok(())
    }
    fn parse_vocabulary(&mut self) -> Result<(), DslError> {
        let concrete = self.ident()?;
        self.expect(&TokenKind::Arrow)?;
        let semantic = self.ident()?;
        let token = self.token().clone();
        let mut roles = BTreeMap::new();
        let mut traits = Vec::new();
        if self.eat(&TokenKind::LBrace) {
            while !self.eat(&TokenKind::RBrace) {
                match self.ident()?.as_str() {
                    "role" => {
                        let canonical = self.ident()?;
                        self.expect(&TokenKind::Eq)?;
                        roles.insert(canonical, self.ident()?);
                    }
                    "trait" => traits.push(self.ident()?),
                    other => return Err(self.err(format!("unknown vocabulary property {other}"))),
                }
                self.optional_semi();
                self.eat(&TokenKind::Comma);
            }
        }
        self.grammar.semantic.push(SemanticMapping {
            concrete,
            semantic,
            roles,
            traits,
            span: Span {
                source: self.name.clone(),
                start: token.start,
                end: token.end,
                line: token.line,
                column: token.column,
            },
        });
        Ok(())
    }
    fn name_set(&mut self) -> Result<Vec<String>, DslError> {
        self.expect(&TokenKind::LBrace)?;
        let mut out = Vec::new();
        while !self.eat(&TokenKind::RBrace) {
            out.push(self.ident()?);
            if !self.eat(&TokenKind::Comma) {
                self.optional_semi();
            }
        }
        Ok(out)
    }
    fn expr_set(&mut self) -> Result<Vec<Expr>, DslError> {
        self.expect(&TokenKind::LBrace)?;
        let mut out = Vec::new();
        while !self.eat(&TokenKind::RBrace) {
            out.push(self.expr()?);
            if !self.eat(&TokenKind::Comma) {
                self.optional_semi();
            }
        }
        Ok(out)
    }
    fn expr(&mut self) -> Result<Expr, DslError> {
        let mut values = vec![self.postfix()?];
        while self.eat(&TokenKind::Pipe) {
            values.push(self.postfix()?);
        }
        Ok(if values.len() == 1 {
            values.pop().unwrap()
        } else {
            Expr::Choice(values)
        })
    }
    fn postfix(&mut self) -> Result<Expr, DslError> {
        let mut expr = self.primary()?;
        loop {
            expr = if self.eat(&TokenKind::Question) {
                Expr::Optional(Box::new(expr))
            } else if self.eat(&TokenKind::Star) {
                Expr::Repeat(Box::new(expr))
            } else if self.eat(&TokenKind::Plus) {
                Expr::Repeat1(Box::new(expr))
            } else {
                break;
            };
        }
        Ok(expr)
    }
    fn primary(&mut self) -> Result<Expr, DslError> {
        match self.bump().kind {
            TokenKind::String(v) => Ok(Expr::String(v)),
            TokenKind::Number(v) => Ok(Expr::Number(v)),
            TokenKind::Ident(name) => {
                if !self.eat(&TokenKind::LParen) {
                    return Ok(Expr::Symbol(name));
                }
                let mut args = Vec::new();
                if !self.eat(&TokenKind::RParen) {
                    loop {
                        args.push(self.expr()?);
                        if self.eat(&TokenKind::RParen) {
                            break;
                        }
                        self.expect(&TokenKind::Comma)?;
                    }
                }
                Ok(Expr::Call(name, args))
            }
            TokenKind::LParen => {
                let out = self.expr()?;
                self.expect(&TokenKind::RParen)?;
                Ok(out)
            }
            other => Err(self.err(format!("expected rule expression, found {other:?}"))),
        }
    }
    fn eval_all(&self, values: Vec<Expr>) -> Result<Vec<Rule>, DslError> {
        values
            .iter()
            .map(|v| self.eval(v, &BTreeMap::new(), &mut Vec::new(), 0))
            .collect()
    }
    fn eval(
        &self,
        expr: &Expr,
        env: &BTreeMap<String, Expr>,
        stack: &mut Vec<String>,
        depth: usize,
    ) -> Result<Rule, DslError> {
        if depth > MAX_EXPANSION_DEPTH {
            return Err(self.err(format!(
                "template expansion depth exceeds {MAX_EXPANSION_DEPTH}: {}",
                stack.join(" -> ")
            )));
        }
        match expr {
            Expr::String(v) => Ok(Rule::String(v.clone())),
            Expr::Number(_) => Err(self.err("integer is valid only as a precedence argument")),
            Expr::Symbol(v) => {
                if let Some(bound) = env.get(v) {
                    self.eval(bound, env, stack, depth + 1)
                } else {
                    Ok(Rule::Symbol(v.clone()))
                }
            }
            Expr::Choice(v) => Ok(Rule::Choice(
                v.iter()
                    .map(|e| self.eval(e, env, stack, depth))
                    .collect::<Result<_, _>>()?,
            )),
            Expr::Optional(v) => Ok(Rule::Choice(vec![
                self.eval(v, env, stack, depth)?,
                Rule::Blank,
            ])),
            Expr::Repeat(v) => Ok(Rule::Repeat(Box::new(self.eval(v, env, stack, depth)?))),
            Expr::Repeat1(v) => Ok(Rule::Repeat1(Box::new(self.eval(v, env, stack, depth)?))),
            Expr::Call(name, args) => self.eval_call(name, args, env, stack, depth),
        }
    }
    fn eval_call(
        &self,
        name: &str,
        args: &[Expr],
        env: &BTreeMap<String, Expr>,
        stack: &mut Vec<String>,
        depth: usize,
    ) -> Result<Rule, DslError> {
        let eval = |e: &Expr, stack: &mut Vec<String>| self.eval(e, env, stack, depth + 1);
        let one = |stack: &mut Vec<String>| -> Result<Rule, DslError> {
            if args.len() != 1 {
                return Err(self.err(format!("{name} expects one argument")));
            }
            eval(&args[0], stack)
        };
        let precedence = |e: &Expr| -> Result<Precedence, DslError> {
            match e {
                Expr::Number(v) => Ok(Precedence::Integer(*v)),
                Expr::String(v) | Expr::Symbol(v) => Ok(Precedence::Named(v.clone())),
                _ => Err(self.err("precedence must be an integer or name")),
            }
        };
        match name {
            "blank" => {
                if !args.is_empty() {
                    return Err(self.err("blank expects no arguments"));
                }
                Ok(Rule::Blank)
            }
            "seq" => Ok(Rule::Seq(
                args.iter()
                    .map(|e| eval(e, stack))
                    .collect::<Result<_, _>>()?,
            )),
            "choice" => Ok(Rule::Choice(
                args.iter()
                    .map(|e| eval(e, stack))
                    .collect::<Result<_, _>>()?,
            )),
            "repeat" => Ok(Rule::Repeat(Box::new(one(stack)?))),
            "repeat1" => Ok(Rule::Repeat1(Box::new(one(stack)?))),
            "optional" => Ok(Rule::Choice(vec![one(stack)?, Rule::Blank])),
            "token" => Ok(Rule::Token(Box::new(one(stack)?))),
            "immediate" => Ok(Rule::ImmediateToken(Box::new(one(stack)?))),
            "string" => match args {
                [Expr::String(v)] => Ok(Rule::String(v.clone())),
                _ => Err(self.err("string expects one string")),
            },
            "pattern" => match args {
                [Expr::String(v)] => Ok(Rule::Pattern {
                    value: v.clone(),
                    flags: String::new(),
                }),
                [Expr::String(v), Expr::String(flags)] => Ok(Rule::Pattern {
                    value: v.clone(),
                    flags: flags.clone(),
                }),
                _ => Err(self.err("pattern expects pattern and optional flags strings")),
            },
            "sym" => match args {
                [Expr::Symbol(v)] | [Expr::String(v)] => Ok(Rule::Symbol(v.clone())),
                _ => Err(self.err("sym expects one name")),
            },
            "field" => match args {
                [Expr::Symbol(v), content] | [Expr::String(v), content] => Ok(Rule::Field {
                    name: v.clone(),
                    content: Box::new(eval(content, stack)?),
                }),
                _ => Err(self.err("field expects name and content")),
            },
            "alias" => match args {
                [content, Expr::Symbol(v)] | [content, Expr::String(v)] => Ok(Rule::Alias {
                    value: v.clone(),
                    named: true,
                    content: Box::new(eval(content, stack)?),
                }),
                [content, Expr::Symbol(v), Expr::Symbol(named)]
                | [content, Expr::String(v), Expr::Symbol(named)] => Ok(Rule::Alias {
                    value: v.clone(),
                    named: named != "anonymous",
                    content: Box::new(eval(content, stack)?),
                }),
                _ => Err(self.err("alias expects content, name, and optional named|anonymous")),
            },
            "prec" | "left" | "right" => {
                if args.len() != 2 {
                    return Err(self.err(format!("{name} expects precedence and content")));
                }
                let p = precedence(&args[0])?;
                let c = Box::new(eval(&args[1], stack)?);
                Ok(match name {
                    "prec" => Rule::Prec {
                        value: p,
                        content: c,
                    },
                    "left" => Rule::PrecLeft {
                        value: p,
                        content: c,
                    },
                    _ => Rule::PrecRight {
                        value: p,
                        content: c,
                    },
                })
            }
            "dynamic" => match args {
                [Expr::Number(v), content] => Ok(Rule::PrecDynamic {
                    value: *v,
                    content: Box::new(eval(content, stack)?),
                }),
                _ => Err(self.err("dynamic expects integer and content")),
            },
            "reserved" => match args {
                [Expr::Symbol(v), content] | [Expr::String(v), content] => Ok(Rule::Reserved {
                    context: v.clone(),
                    content: Box::new(eval(content, stack)?),
                }),
                _ => Err(self.err("reserved expects context and content")),
            },
            template_name => {
                let template = self.templates.get(template_name).ok_or_else(|| {
                    self.err(format!("unknown rule combinator/template {template_name}"))
                })?;
                if template.params.len() != args.len() {
                    return Err(self.err(format!(
                        "template {template_name} expects {} arguments",
                        template.params.len()
                    )));
                }
                if stack.iter().any(|n| n == template_name) {
                    return Err(self.err(format!(
                        "recursive template: {} -> {template_name}",
                        stack.join(" -> ")
                    )));
                }
                let mut child = env.clone();
                for (p, a) in template.params.iter().zip(args) {
                    child.insert(p.clone(), a.clone());
                }
                stack.push(template_name.into());
                let out = self.eval(&template.body, &child, stack, depth + 1);
                stack.pop();
                out
            }
        }
    }
}

pub fn parse(source: &str, source_name: &str) -> Result<GrammarIr, DslError> {
    if source.len() > MAX_SOURCE_BYTES {
        return Err(DslError {
            source: source_name.into(),
            line: 1,
            column: 1,
            message: format!("source exceeds {MAX_SOURCE_BYTES} bytes"),
        });
    }
    let mut lexer = Lexer::new(source, source_name);
    let mut tokens = Vec::new();
    loop {
        let token = lexer.token()?;
        let eof = token.kind == TokenKind::Eof;
        tokens.push(token);
        if eof {
            break;
        }
    }
    Parser {
        name: source_name.into(),
        tokens,
        at: 0,
        grammar: GrammarIr {
            ir_version: GRAMMAR_IR_VERSION,
            ..GrammarIr::default()
        },
        raw_rules: BTreeMap::new(),
        templates: BTreeMap::new(),
        mutations: Vec::new(),
    }
    .parse()
}
