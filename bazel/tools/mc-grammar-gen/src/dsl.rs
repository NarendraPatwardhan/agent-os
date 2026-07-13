//! Bootstrap parser for the AgentOS grammar language.
//!
//! It is intentionally handwritten: parser generation must not depend on an already-generated
//! parser. The surface language is EBNF-like and lowers to a spanned AST; module composition and
//! backend lowering happen in later compiler stages.

use mc_parser_ast::{
    Associativity, Comment, Declaration, Expr, ExprKind, Module, ModuleKind, OperatorRow, Semantic,
    Span,
};
use std::fmt;

const MAX_SOURCE_BYTES: usize = 4 * 1024 * 1024;
const MAX_DECLARATIONS: usize = 8192;

#[derive(Clone, Debug, PartialEq)]
enum TokenKind {
    Ident(String),
    String(String),
    Regex(String, String),
    Number(i32),
    LParen,
    RParen,
    Comma,
    Eq,
    Colon,
    Pipe,
    Question,
    Star,
    Plus,
    FatArrow,
    Newline,
    Eof,
}

#[derive(Clone, Debug)]
struct Token {
    kind: TokenKind,
    span: Span,
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
    comments: Vec<Comment>,
}

impl<'a> Lexer<'a> {
    fn new(source: &'a str, name: &'a str) -> Self {
        Self {
            source,
            name,
            at: 0,
            line: 1,
            column: 1,
            comments: Vec::new(),
        }
    }
    fn error(&self, message: impl Into<String>) -> DslError {
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
    fn starts_with(&self, value: &str) -> bool {
        self.source[self.at..].starts_with(value)
    }
    fn bump(&mut self) -> Option<char> {
        let value = self.peek()?;
        self.at += value.len_utf8();
        if value == '\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        Some(value)
    }
    fn span(&self, start: usize, line: usize, column: usize) -> Span {
        Span {
            source: self.name.into(),
            start,
            end: self.at,
            line,
            column,
        }
    }
    fn skip_horizontal(&mut self) {
        loop {
            while self.peek().is_some_and(|c| matches!(c, ' ' | '\t' | '\r')) {
                self.bump();
            }
            if self.starts_with("//") || self.peek() == Some('#') {
                let (start, line, column) = (self.at, self.line, self.column);
                while self.peek().is_some_and(|c| c != '\n') {
                    self.bump();
                }
                self.comments.push(Comment {
                    text: self.source[start..self.at].trim_end().into(),
                    span: self.span(start, line, column),
                });
                continue;
            }
            break;
        }
    }
    fn token(&mut self) -> Result<Token, DslError> {
        self.skip_horizontal();
        let (start, line, column) = (self.at, self.line, self.column);
        let Some(value) = self.bump() else {
            return Ok(Token {
                kind: TokenKind::Eof,
                span: self.span(start, line, column),
            });
        };
        let kind = match value {
            '\n' => TokenKind::Newline,
            '(' => TokenKind::LParen,
            ')' => TokenKind::RParen,
            ',' => TokenKind::Comma,
            ':' => TokenKind::Colon,
            '|' => TokenKind::Pipe,
            '?' => TokenKind::Question,
            '*' => TokenKind::Star,
            '+' => TokenKind::Plus,
            '=' if self.peek() == Some('>') => {
                self.bump();
                TokenKind::FatArrow
            }
            '=' => TokenKind::Eq,
            '"' => TokenKind::String(self.string()?),
            '/' => {
                let mut pattern = String::new();
                let mut escaped = false;
                loop {
                    let c = self
                        .bump()
                        .ok_or_else(|| self.error("unterminated regex literal"))?;
                    if c == '\n' {
                        return Err(self.error("regex literal cannot cross a newline"));
                    }
                    if c == '/' && !escaped {
                        break;
                    }
                    escaped = c == '\\' && !escaped;
                    if c != '\\' {
                        escaped = false;
                    }
                    pattern.push(c);
                }
                let mut flags = String::new();
                while self.peek().is_some_and(|c| c.is_ascii_alphabetic()) {
                    flags.push(self.bump().unwrap());
                }
                TokenKind::Regex(pattern, flags)
            }
            c if c.is_ascii_digit()
                || (c == '-' && self.peek().is_some_and(|next| next.is_ascii_digit())) =>
            {
                let mut number = String::from(c);
                while self.peek().is_some_and(|next| next.is_ascii_digit()) {
                    number.push(self.bump().unwrap());
                }
                TokenKind::Number(
                    number
                        .parse()
                        .map_err(|_| self.error("integer is outside i32"))?,
                )
            }
            c if is_ident_start(c) => {
                let mut ident = String::from(c);
                while self.peek().is_some_and(is_ident_continue) {
                    ident.push(self.bump().unwrap());
                }
                TokenKind::Ident(ident)
            }
            other => return Err(self.error(format!("unexpected character {other:?}"))),
        };
        Ok(Token {
            kind,
            span: self.span(start, line, column),
        })
    }
    fn string(&mut self) -> Result<String, DslError> {
        let mut out = String::new();
        loop {
            match self
                .bump()
                .ok_or_else(|| self.error("unterminated string"))?
            {
                '"' => return Ok(out),
                '\n' => return Err(self.error("string cannot cross a newline")),
                '\\' => match self
                    .bump()
                    .ok_or_else(|| self.error("unterminated escape"))?
                {
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    other => return Err(self.error(format!("unsupported escape \\{other}"))),
                },
                other => out.push(other),
            }
        }
    }
}

fn is_ident_start(value: char) -> bool {
    value == '_' || value.is_ascii_alphabetic()
}
fn is_ident_continue(value: char) -> bool {
    is_ident_start(value) || value.is_ascii_digit() || matches!(value, '-' | '.' | '/')
}

struct Parser {
    source_name: String,
    tokens: Vec<Token>,
    comments: Vec<Comment>,
    at: usize,
}

impl Parser {
    fn token(&self) -> &Token {
        &self.tokens[self.at]
    }
    fn peek_kind(&self, offset: usize) -> Option<&TokenKind> {
        self.tokens.get(self.at + offset).map(|token| &token.kind)
    }
    fn bump(&mut self) -> Token {
        let token = self.tokens[self.at].clone();
        if token.kind != TokenKind::Eof {
            self.at += 1;
        }
        token
    }
    fn error(&self, message: impl Into<String>) -> DslError {
        DslError {
            source: self.source_name.clone(),
            line: self.token().span.line,
            column: self.token().span.column,
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
    fn expect(&mut self, kind: &TokenKind) -> Result<Token, DslError> {
        if &self.token().kind == kind {
            Ok(self.bump())
        } else {
            Err(self.error(format!("expected {kind:?}, found {:?}", self.token().kind)))
        }
    }
    fn ident(&mut self) -> Result<(String, Span), DslError> {
        let token = self.bump();
        match token.kind {
            TokenKind::Ident(value) => Ok((value, token.span)),
            other => Err(DslError {
                source: self.source_name.clone(),
                line: token.span.line,
                column: token.span.column,
                message: format!("expected name, found {other:?}"),
            }),
        }
    }
    fn production_name(&mut self) -> Result<(String, Span), DslError> {
        let (name, span) = self.ident()?;
        if !name
            .chars()
            .all(|value| value == '_' || value.is_ascii_alphanumeric())
        {
            return Err(DslError {
                source: self.source_name.clone(),
                line: span.line,
                column: span.column,
                message: format!("production name {name:?} must be a C identifier"),
            });
        }
        Ok((name, span))
    }
    fn string_or_ident(&mut self) -> Result<String, DslError> {
        let token = self.bump();
        match token.kind {
            TokenKind::Ident(value) | TokenKind::String(value) => Ok(value),
            other => Err(self.error(format!("expected name or string, found {other:?}"))),
        }
    }
    fn number(&mut self) -> Result<i32, DslError> {
        let token = self.bump();
        match token.kind {
            TokenKind::Number(value) => Ok(value),
            other => Err(self.error(format!("expected precedence integer, found {other:?}"))),
        }
    }
    fn skip_newlines(&mut self) {
        while self.eat(&TokenKind::Newline) {}
    }
    fn line_end(&mut self) -> Result<(), DslError> {
        match self.token().kind {
            TokenKind::Newline | TokenKind::Eof => Ok(()),
            _ => Err(self.error("expected end of declaration")),
        }
    }
    fn continuation_index(&self, base_column: usize) -> Option<usize> {
        if self.token().kind != TokenKind::Newline {
            return None;
        }
        let mut index = self.at;
        while self
            .tokens
            .get(index)
            .is_some_and(|token| token.kind == TokenKind::Newline)
        {
            index += 1;
        }
        let next = self.tokens.get(index)?;
        (next.kind != TokenKind::Eof && next.span.column > base_column).then_some(index)
    }
    fn parse(mut self) -> Result<Module, DslError> {
        self.skip_newlines();
        let header = self.bump();
        let kind = match header.kind {
            TokenKind::Ident(value) if value == "grammar" => ModuleKind::Grammar,
            TokenKind::Ident(value) if value == "family" => ModuleKind::Family,
            _ => return Err(self.error("file must begin with `grammar` or `family`")),
        };
        let (name, name_span) = self.ident()?;
        if kind == ModuleKind::Grammar
            && !name
                .chars()
                .all(|value| value == '_' || value.is_ascii_alphanumeric())
        {
            return Err(DslError {
                source: self.source_name.clone(),
                line: name_span.line,
                column: name_span.column,
                message: format!("grammar name {name:?} must be a C identifier"),
            });
        }
        let version = if matches!(
            self.token().kind,
            TokenKind::String(_) | TokenKind::Ident(_)
        ) {
            self.string_or_ident()?
        } else {
            String::new()
        };
        self.line_end()?;
        self.skip_newlines();

        let mut module = Module {
            kind,
            name,
            version,
            start: None,
            uses: Vec::new(),
            declarations: Vec::new(),
            comments: std::mem::take(&mut self.comments),
            span: header.span,
        };
        while self.token().kind != TokenKind::Eof {
            if module.declarations.len() > MAX_DECLARATIONS {
                return Err(self.error(format!("declaration limit exceeded ({MAX_DECLARATIONS})")));
            }
            self.declaration(&mut module)?;
            self.skip_newlines();
        }
        if module.kind == ModuleKind::Grammar && module.start.is_none() {
            return Err(self.error("grammar is missing a start declaration"));
        }
        Ok(module)
    }

    fn declaration(&mut self, module: &mut Module) -> Result<(), DslError> {
        let (head, span) = self.ident()?;
        let base_column = span.column;
        match head.as_str() {
            "use" => {
                module.uses.push(self.string_or_ident()?);
                self.line_end()
            }
            "start" => {
                if module.start.replace(self.production_name()?.0).is_some() {
                    return Err(self.error("duplicate start declaration"));
                }
                self.line_end()
            }
            "fragment" => self.fragment(span, module),
            "token" => self.rule(span, module, false, true),
            "open" => self.rule(span, module, true, false),
            "extend" => self.extend(span, module),
            "slot" => {
                let (name, _) = self.production_name()?;
                module.declarations.push(Declaration::Slot { name, span });
                self.line_end()
            }
            "fill" => {
                let (name, _) = self.production_name()?;
                self.expect(&TokenKind::Eq)?;
                let expression = self.expression(base_column)?;
                module.declarations.push(Declaration::Fill {
                    name,
                    expression,
                    span,
                });
                self.line_end()
            }
            "skip" => {
                let expression = self.expression(base_column)?;
                module
                    .declarations
                    .push(Declaration::Skip { expression, span });
                self.line_end()
            }
            "external" => {
                let names = self.names_to_line_end()?;
                module
                    .declarations
                    .push(Declaration::Externals { names, span });
                Ok(())
            }
            "word" => {
                let name = self.production_name()?.0;
                module.declarations.push(Declaration::Word { name, span });
                self.line_end()
            }
            "conflict" => {
                let names = self.names_to_line_end()?;
                if names.len() < 2 {
                    return Err(self.error("conflict requires at least two productions"));
                }
                module
                    .declarations
                    .push(Declaration::Conflict { names, span });
                Ok(())
            }
            "map" => {
                let concrete = self.production_name()?.0;
                let arrow = self.expect(&TokenKind::FatArrow)?;
                let kind = self.ident()?.0;
                module.declarations.push(Declaration::Mapping {
                    concrete,
                    semantic: Semantic {
                        kind,
                        roles: Vec::new(),
                        traits: Vec::new(),
                        span: arrow.span,
                    },
                    span,
                });
                self.line_end()
            }
            "infix" | "prefix" => self.operator_table(span, module, head == "prefix"),
            _ => {
                if !head
                    .chars()
                    .all(|value| value == '_' || value.is_ascii_alphanumeric())
                {
                    return Err(DslError {
                        source: self.source_name.clone(),
                        line: span.line,
                        column: span.column,
                        message: format!("production name {head:?} must be a C identifier"),
                    });
                }
                self.named_rule(head, span, module, false, false)
            }
        }
    }

    fn names_to_line_end(&mut self) -> Result<Vec<String>, DslError> {
        let mut names = Vec::new();
        while !matches!(self.token().kind, TokenKind::Newline | TokenKind::Eof) {
            if self.eat(&TokenKind::Comma) || self.eat(&TokenKind::Pipe) {
                continue;
            }
            names.push(self.production_name()?.0);
        }
        if names.is_empty() {
            return Err(self.error("expected at least one name"));
        }
        Ok(names)
    }

    fn fragment(&mut self, span: Span, module: &mut Module) -> Result<(), DslError> {
        let name = self.production_name()?.0;
        self.expect(&TokenKind::LParen)?;
        let mut parameters = Vec::new();
        if !self.eat(&TokenKind::RParen) {
            loop {
                parameters.push(self.production_name()?.0);
                if self.eat(&TokenKind::RParen) {
                    break;
                }
                self.expect(&TokenKind::Comma)?;
            }
        }
        self.expect(&TokenKind::Eq)?;
        let expression = self.expression(span.column)?;
        module.declarations.push(Declaration::Fragment {
            name,
            parameters,
            expression,
            span,
        });
        self.line_end()
    }

    fn rule(
        &mut self,
        span: Span,
        module: &mut Module,
        open: bool,
        token: bool,
    ) -> Result<(), DslError> {
        let name = self.production_name()?.0;
        self.named_rule(name, span, module, open, token)
    }

    fn named_rule(
        &mut self,
        name: String,
        span: Span,
        module: &mut Module,
        open: bool,
        token: bool,
    ) -> Result<(), DslError> {
        self.expect(&TokenKind::Eq)?;
        let expression = self.expression(span.column)?;
        let semantic = self.semantic(span.column)?;
        module.declarations.push(Declaration::Rule {
            name,
            expression,
            open,
            token,
            semantic,
            span,
        });
        self.line_end()
    }

    fn extend(&mut self, span: Span, module: &mut Module) -> Result<(), DslError> {
        let name = self.production_name()?.0;
        self.expect(&TokenKind::Eq)?;
        let expression = self.expression(span.column)?;
        module.declarations.push(Declaration::Extend {
            name,
            expression,
            span,
        });
        self.line_end()
    }

    fn operator_table(
        &mut self,
        span: Span,
        module: &mut Module,
        prefix: bool,
    ) -> Result<(), DslError> {
        let name = self.production_name()?.0;
        let over = self.ident()?.0;
        if over != "over" {
            return Err(self.error("operator table expects `over <operand>`"));
        }
        let operand = self.production_name()?.0;
        let semantic = self.semantic(span.column)?;
        self.line_end()?;
        let mut rows = Vec::new();
        while let Some(index) = self.continuation_index(span.column) {
            self.at = index;
            let row_span = self.token().span.clone();
            let associativity = match self.ident()?.0.as_str() {
                "left" if !prefix => Associativity::Left,
                "right" => Associativity::Right,
                "plain" => Associativity::Plain,
                "left" => return Err(self.error("prefix operators cannot be left-associative")),
                other => return Err(self.error(format!("unknown associativity {other}"))),
            };
            let precedence = self.number()?;
            self.eat(&TokenKind::Colon);
            let operators = self.expression(row_span.column)?;
            rows.push(OperatorRow {
                associativity,
                precedence,
                operators,
                span: row_span,
            });
            self.line_end()?;
        }
        if rows.is_empty() {
            return Err(self.error("operator table requires at least one row"));
        }
        module.declarations.push(Declaration::OperatorTable {
            name,
            operand,
            prefix,
            rows,
            semantic,
            span,
        });
        Ok(())
    }

    fn semantic(&mut self, base_column: usize) -> Result<Option<Semantic>, DslError> {
        let continuation = self.continuation_index(base_column);
        if self.token().kind != TokenKind::FatArrow
            && !continuation.is_some_and(|index| self.tokens[index].kind == TokenKind::FatArrow)
        {
            return Ok(None);
        }
        if let Some(index) = continuation {
            self.at = index;
        }
        let arrow = self.expect(&TokenKind::FatArrow)?;
        let kind = self.ident()?.0;
        let mut roles = Vec::new();
        if self.eat(&TokenKind::LParen) {
            if !self.eat(&TokenKind::RParen) {
                loop {
                    let canonical = self.ident()?.0;
                    let concrete = if self.eat(&TokenKind::Eq) {
                        self.ident()?.0
                    } else {
                        canonical.clone()
                    };
                    roles.push((canonical, concrete));
                    if self.eat(&TokenKind::RParen) {
                        break;
                    }
                    self.expect(&TokenKind::Comma)?;
                }
            }
        }
        let mut traits = Vec::new();
        let continuation = self.continuation_index(base_column);
        if matches!(&self.token().kind, TokenKind::Ident(value) if value == "derives")
            || continuation.is_some_and(|index| matches!(&self.tokens[index].kind, TokenKind::Ident(value) if value == "derives"))
        {
            if let Some(index) = continuation {
                self.at = index;
            }
            self.ident()?;
            while !matches!(self.token().kind, TokenKind::Newline | TokenKind::Eof) {
                if self.eat(&TokenKind::Comma) {
                    continue;
                }
                traits.push(self.ident()?.0);
            }
        }
        Ok(Some(Semantic {
            kind,
            roles,
            traits,
            span: arrow.span,
        }))
    }

    fn expression(&mut self, base_column: usize) -> Result<Expr, DslError> {
        self.choice(base_column)
    }

    fn choice(&mut self, base_column: usize) -> Result<Expr, DslError> {
        if let Some(index) = self.continuation_index(base_column) {
            self.at = index;
        }
        self.eat(&TokenKind::Pipe);
        let first = self.sequence(base_column)?;
        let span = first.span.clone();
        let mut alternatives = vec![first];
        loop {
            if self.eat(&TokenKind::Pipe) {
                alternatives.push(self.sequence(base_column)?);
                continue;
            }
            let Some(index) = self.continuation_index(base_column) else {
                break;
            };
            if self.tokens[index].kind != TokenKind::Pipe {
                break;
            }
            self.at = index + 1;
            alternatives.push(self.sequence(base_column)?);
        }
        Ok(if alternatives.len() == 1 {
            alternatives.pop().unwrap()
        } else {
            Expr {
                kind: ExprKind::Choice(alternatives),
                span,
            }
        })
    }

    fn sequence(&mut self, base_column: usize) -> Result<Expr, DslError> {
        let precedence = self.precedence_prefix();
        let mut members = Vec::new();
        loop {
            if !self.can_start_primary() {
                let Some(index) = self.continuation_index(base_column) else {
                    break;
                };
                if matches!(
                    self.tokens[index].kind,
                    TokenKind::Pipe | TokenKind::FatArrow
                ) || matches!(&self.tokens[index].kind, TokenKind::Ident(value) if value == "derives")
                    || !can_start(&self.tokens[index].kind)
                {
                    break;
                }
                self.at = index;
            }
            members.push(self.postfix()?);
        }
        if members.is_empty() {
            return Err(self.error("expected grammar expression"));
        }
        let span = members[0].span.clone();
        let content = if members.len() == 1 {
            members.pop().unwrap()
        } else {
            Expr {
                kind: ExprKind::Sequence(members),
                span: span.clone(),
            }
        };
        Ok(
            if let Some((associativity, value, outer_span)) = precedence {
                Expr {
                    kind: ExprKind::Precedence {
                        associativity,
                        value,
                        content: Box::new(content),
                    },
                    span: outer_span,
                }
            } else {
                content
            },
        )
    }

    fn precedence_prefix(&mut self) -> Option<(Associativity, i32, Span)> {
        let TokenKind::Ident(name) = self.token().kind.clone() else {
            return None;
        };
        let associativity = match name.as_str() {
            "left" => Associativity::Left,
            "right" => Associativity::Right,
            "plain" => Associativity::Plain,
            _ => return None,
        };
        if !matches!(self.peek_kind(1), Some(TokenKind::Number(_)))
            || self.peek_kind(2) != Some(&TokenKind::Colon)
        {
            return None;
        }
        let span = self.bump().span;
        let value = self.number().unwrap();
        self.expect(&TokenKind::Colon).unwrap();
        Some((associativity, value, span))
    }

    fn can_start_primary(&self) -> bool {
        can_start(&self.token().kind)
            && !matches!(&self.token().kind, TokenKind::Ident(value) if value == "derives")
    }

    fn postfix(&mut self) -> Result<Expr, DslError> {
        let mut expression = self.primary()?;
        loop {
            expression = if self.eat(&TokenKind::Question) {
                let span = expression.span.clone();
                Expr {
                    kind: ExprKind::Optional(Box::new(expression)),
                    span,
                }
            } else if self.eat(&TokenKind::Star) {
                let span = expression.span.clone();
                Expr {
                    kind: ExprKind::Repeat(Box::new(expression)),
                    span,
                }
            } else if self.eat(&TokenKind::Plus) {
                let span = expression.span.clone();
                Expr {
                    kind: ExprKind::Repeat1(Box::new(expression)),
                    span,
                }
            } else {
                break;
            };
        }
        Ok(expression)
    }

    fn primary(&mut self) -> Result<Expr, DslError> {
        let token = self.bump();
        match token.kind {
            TokenKind::String(value) => Ok(Expr {
                kind: ExprKind::Literal(value),
                span: token.span,
            }),
            TokenKind::Regex(value, flags) => Ok(Expr {
                kind: ExprKind::Pattern { value, flags },
                span: token.span,
            }),
            TokenKind::Ident(name) => {
                if !name
                    .chars()
                    .all(|value| value == '_' || value.is_ascii_alphanumeric())
                {
                    return Err(DslError {
                        source: self.source_name.clone(),
                        line: token.span.line,
                        column: token.span.column,
                        message: format!("production name {name:?} must be a C identifier"),
                    });
                }
                if self.eat(&TokenKind::Colon) {
                    let content = self.postfix()?;
                    return Ok(Expr {
                        kind: ExprKind::Field {
                            name,
                            content: Box::new(content),
                        },
                        span: token.span,
                    });
                }
                // Fragment application is lexical (`name(`). Whitespace before `(` means ordinary
                // EBNF sequence: a symbol followed by a grouped expression.
                if self.token().kind != TokenKind::LParen
                    || token.span.end != self.token().span.start
                {
                    return Ok(Expr {
                        kind: ExprKind::Symbol(name),
                        span: token.span,
                    });
                }
                self.bump();
                let mut args = Vec::new();
                self.skip_newlines();
                if !self.eat(&TokenKind::RParen) {
                    loop {
                        args.push(self.expression(0)?);
                        self.skip_newlines();
                        if self.eat(&TokenKind::RParen) {
                            break;
                        }
                        self.expect(&TokenKind::Comma)?;
                        self.skip_newlines();
                    }
                }
                Ok(Expr {
                    kind: ExprKind::Call { name, args },
                    span: token.span,
                })
            }
            TokenKind::LParen => {
                self.skip_newlines();
                let expression = self.expression(0)?;
                self.skip_newlines();
                self.expect(&TokenKind::RParen)?;
                Ok(expression)
            }
            other => Err(self.error(format!("expected grammar expression, found {other:?}"))),
        }
    }
}

fn can_start(kind: &TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::Ident(_) | TokenKind::String(_) | TokenKind::Regex(_, _) | TokenKind::LParen
    )
}

pub fn parse(source: &str, source_name: &str) -> Result<Module, DslError> {
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
        source_name: source_name.into(),
        tokens,
        comments: lexer.comments,
        at: 0,
    }
    .parse()
}
