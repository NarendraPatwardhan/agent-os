//! Recursive-descent parser: token stream → AST.
//!
//! Implements the POSIX shell grammar — lists, and-or, pipelines, simple and compound
//! commands, functions, redirections, here-docs. Reserved words are recognized only in
//! *command position* and only on a bare single-literal word, so `echo if`, `"if"`,
//! and `x=if` all stay plain words (see [`word_keyword`]). That position-sensitivity is
//! exactly why the lexer does not classify keywords — only the grammar knows position.

use alloc::boxed::Box;
use alloc::string::{String, ToString};
use alloc::vec;
use alloc::vec::Vec;

use crate::ast::*;
use crate::token::{tokenize, LexError, Operator, Token};
use crate::word::{Word, WordPart};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// More input would complete the parse (open quote/compound/here-doc).
    Incomplete(String),
    /// Hard syntax error.
    Syntax(String),
}

impl From<LexError> for ParseError {
    fn from(e: LexError) -> Self {
        match e {
            LexError::Incomplete(m) => ParseError::Incomplete(m),
            LexError::Syntax(m) => ParseError::Syntax(m),
        }
    }
}

/// Parse a complete program (a script body or one interactive line group).
pub fn parse(src: &str) -> Result<Script, ParseError> {
    let toks = tokenize(src)?;
    let mut p = Parser { toks, pos: 0 };
    let list = p.parse_list()?;
    p.skip_newlines();
    if !p.at_eof() {
        return Err(p.syntax("unexpected token"));
    }
    Ok(Script { list })
}

struct Parser {
    toks: Vec<Token>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> &Token {
        self.toks.get(self.pos).unwrap_or(&Token::Eof)
    }
    fn peek_at(&self, n: usize) -> &Token {
        self.toks.get(self.pos + n).unwrap_or(&Token::Eof)
    }
    fn bump(&mut self) -> Token {
        let t = self.toks.get(self.pos).cloned().unwrap_or(Token::Eof);
        if self.pos < self.toks.len() {
            self.pos += 1;
        }
        t
    }
    fn at_eof(&self) -> bool {
        matches!(self.peek(), Token::Eof)
    }
    /// An error at EOF is reported as `Incomplete` (an interactive driver can read
    /// more); anywhere else it is a hard `Syntax` error.
    fn syntax(&self, msg: &str) -> ParseError {
        if self.at_eof() {
            ParseError::Incomplete(msg.to_string())
        } else {
            ParseError::Syntax(msg.to_string())
        }
    }
    fn skip_newlines(&mut self) {
        while matches!(self.peek(), Token::Newline) {
            self.bump();
        }
    }

    // ---- keyword helpers ----
    fn peek_keyword(&self) -> Option<&'static str> {
        match self.peek() {
            Token::Word(w) => word_keyword(w),
            _ => None,
        }
    }
    fn at_keyword(&self, kw: &str) -> bool {
        self.peek_keyword() == Some(kw)
    }
    fn expect_keyword(&mut self, kw: &'static str) -> Result<(), ParseError> {
        if self.at_keyword(kw) {
            self.bump();
            Ok(())
        } else {
            Err(self.syntax(kw))
        }
    }

    /// A list ends at EOF, `)`, `;;`, or a continuation/closing reserved word.
    fn at_list_end(&self) -> bool {
        if matches!(
            self.peek(),
            Token::Eof | Token::Op(Operator::RParen) | Token::Op(Operator::DSemi)
        ) {
            return true;
        }
        matches!(
            self.peek_keyword(),
            Some("then" | "elif" | "else" | "fi" | "do" | "done" | "esac" | "}")
        )
    }

    // ==================================================================
    //  list := and_or ( (';' | '&' | '\n') and_or )*
    // ==================================================================
    fn parse_list(&mut self) -> Result<List, ParseError> {
        let mut items = Vec::new();
        loop {
            self.skip_newlines();
            if self.at_list_end() {
                break;
            }
            let and_or = self.parse_and_or()?;
            let mut sep = ListSep::Seq;
            let mut had_sep = false;
            match self.peek() {
                Token::Op(Operator::Amp) => {
                    self.bump();
                    sep = ListSep::Async;
                    had_sep = true;
                }
                Token::Op(Operator::Semi) => {
                    self.bump();
                    had_sep = true;
                }
                Token::Newline => {
                    self.bump();
                    had_sep = true;
                }
                _ => {}
            }
            items.push(ListItem { and_or, sep });
            if !had_sep {
                break;
            }
        }
        Ok(List { items })
    }

    fn parse_and_or(&mut self) -> Result<AndOr, ParseError> {
        let first = self.parse_pipeline()?;
        let mut rest = Vec::new();
        loop {
            let op = match self.peek() {
                Token::Op(Operator::AndIf) => AndOrOp::And,
                Token::Op(Operator::OrIf) => AndOrOp::Or,
                _ => break,
            };
            self.bump();
            self.skip_newlines();
            let p = self.parse_pipeline()?;
            rest.push((op, p));
        }
        Ok(AndOr { first, rest })
    }

    fn parse_pipeline(&mut self) -> Result<Pipeline, ParseError> {
        let mut bang = false;
        if self.at_keyword("!") {
            self.bump();
            bang = true;
        }
        let mut cmds = vec![self.parse_command()?];
        loop {
            if matches!(self.peek(), Token::Op(Operator::Pipe)) {
                self.bump();
                self.skip_newlines();
                cmds.push(self.parse_command()?);
            } else {
                break;
            }
        }
        Ok(Pipeline { bang, cmds })
    }

    // ==================================================================
    //  command := function_def | compound redirect* | simple_command
    // ==================================================================
    fn parse_command(&mut self) -> Result<Command, ParseError> {
        // function: `name ( )` or `function name`
        if self.is_function_def() {
            return self.parse_function_def();
        }
        // compound by leading reserved word / paren
        if let Some(kw) = self.peek_keyword() {
            let compound = match kw {
                "if" => self.parse_if()?,
                "for" => self.parse_for()?,
                "while" => self.parse_while(false)?,
                "until" => self.parse_while(true)?,
                "case" => self.parse_case()?,
                "{" => self.parse_brace_group()?,
                _ => return self.parse_simple_command(),
            };
            let redirs = self.parse_redirect_list()?;
            return Ok(Command::Compound {
                kind: compound,
                redirs,
            });
        }
        if matches!(self.peek(), Token::Op(Operator::LParen)) {
            let compound = self.parse_subshell()?;
            let redirs = self.parse_redirect_list()?;
            return Ok(Command::Compound {
                kind: compound,
                redirs,
            });
        }
        self.parse_simple_command()
    }

    fn is_function_def(&self) -> bool {
        // `name ( )`
        if let Token::Word(w) = self.peek() {
            if word_name(w).is_some()
                && matches!(self.peek_at(1), Token::Op(Operator::LParen))
                && matches!(self.peek_at(2), Token::Op(Operator::RParen))
            {
                return true;
            }
        }
        // `function name`
        self.at_keyword("function")
    }

    fn parse_function_def(&mut self) -> Result<Command, ParseError> {
        let name = if self.at_keyword("function") {
            self.bump();
            let n = self
                .take_name()
                .ok_or_else(|| self.syntax("function name"))?;
            // optional ()
            if matches!(self.peek(), Token::Op(Operator::LParen)) {
                self.bump();
                if !matches!(self.bump(), Token::Op(Operator::RParen)) {
                    return Err(self.syntax("expected ')'"));
                }
            }
            n
        } else {
            let n = self
                .take_name()
                .ok_or_else(|| self.syntax("function name"))?;
            self.bump(); // (
            self.bump(); // )
            n
        };
        self.skip_newlines();
        let body = self.parse_command()?;
        match &body {
            Command::Compound { .. } => {}
            _ => return Err(self.syntax("function body must be a compound command")),
        }
        Ok(Command::Function {
            name,
            body: Box::new(body),
        })
    }

    fn parse_simple_command(&mut self) -> Result<Command, ParseError> {
        let mut cmd = SimpleCommand::default();
        // leading assignments (only before any word)
        loop {
            let is_assign = matches!(self.peek(), Token::Word(w) if cmd.words.is_empty() && word_assignment(w).is_some());
            if !is_assign {
                break;
            }
            if let Token::Word(w) = self.bump() {
                let (name, value) = word_assignment(&w).expect("checked");
                cmd.assigns.push(Assign { name, value });
            }
        }
        // words and redirects, interleaved
        loop {
            match self.peek() {
                Token::Word(_) => {
                    if let Token::Word(w) = self.bump() {
                        cmd.words.push(w);
                    }
                }
                Token::IoNumber(_)
                | Token::Heredoc { .. }
                | Token::Op(Operator::Less)
                | Token::Op(Operator::Great)
                | Token::Op(Operator::DGreat)
                | Token::Op(Operator::LessGreat)
                | Token::Op(Operator::Clobber)
                | Token::Op(Operator::LessAnd)
                | Token::Op(Operator::GreatAnd) => {
                    cmd.redirs.push(self.parse_redirect()?);
                }
                _ => break,
            }
        }
        if cmd.assigns.is_empty() && cmd.words.is_empty() && cmd.redirs.is_empty() {
            return Err(self.syntax("expected a command"));
        }
        Ok(Command::Simple(cmd))
    }

    // ---- redirects ----
    fn parse_redirect_list(&mut self) -> Result<Vec<Redirect>, ParseError> {
        let mut v = Vec::new();
        loop {
            match self.peek() {
                Token::IoNumber(_)
                | Token::Heredoc { .. }
                | Token::Op(Operator::Less)
                | Token::Op(Operator::Great)
                | Token::Op(Operator::DGreat)
                | Token::Op(Operator::LessGreat)
                | Token::Op(Operator::Clobber)
                | Token::Op(Operator::LessAnd)
                | Token::Op(Operator::GreatAnd) => {
                    v.push(self.parse_redirect()?);
                }
                _ => break,
            }
        }
        Ok(v)
    }

    fn parse_redirect(&mut self) -> Result<Redirect, ParseError> {
        let io_number = if let Token::IoNumber(n) = self.peek() {
            let n = *n;
            self.bump();
            Some(n)
        } else {
            None
        };
        match self.bump() {
            Token::Op(Operator::Less) => Ok(Redirect {
                io_number,
                op: RedirOp::Read,
                target: RedirTarget::Word(self.expect_word()?),
            }),
            Token::Op(Operator::Great) => Ok(Redirect {
                io_number,
                op: RedirOp::Write,
                target: RedirTarget::Word(self.expect_word()?),
            }),
            Token::Op(Operator::DGreat) => Ok(Redirect {
                io_number,
                op: RedirOp::Append,
                target: RedirTarget::Word(self.expect_word()?),
            }),
            Token::Op(Operator::LessGreat) => Ok(Redirect {
                io_number,
                op: RedirOp::ReadWrite,
                target: RedirTarget::Word(self.expect_word()?),
            }),
            Token::Op(Operator::Clobber) => Ok(Redirect {
                io_number,
                op: RedirOp::Clobber,
                target: RedirTarget::Word(self.expect_word()?),
            }),
            Token::Op(Operator::LessAnd) => Ok(Redirect {
                io_number,
                op: RedirOp::DupIn,
                target: self.dup_target()?,
            }),
            Token::Op(Operator::GreatAnd) => Ok(Redirect {
                io_number,
                op: RedirOp::DupOut,
                target: self.dup_target()?,
            }),
            Token::Heredoc { body, expand, .. } => Ok(Redirect {
                io_number,
                op: RedirOp::Heredoc,
                target: RedirTarget::Here { body, expand },
            }),
            _ => Err(self.syntax("expected a redirection operator")),
        }
    }

    fn dup_target(&mut self) -> Result<RedirTarget, ParseError> {
        let w = self.expect_word()?;
        // The dup target must be a single literal: a number or `-`.
        if let [WordPart::Lit { text, .. }] = w.as_slice() {
            if text == "-" {
                return Ok(RedirTarget::Dup(DupSpec::Close));
            }
            if let Ok(n) = text.parse::<u32>() {
                return Ok(RedirTarget::Dup(DupSpec::Number(n)));
            }
        }
        Err(ParseError::Syntax("bad fd-duplication target".into()))
    }

    fn expect_word(&mut self) -> Result<Word, ParseError> {
        match self.peek() {
            Token::Word(_) => {
                if let Token::Word(w) = self.bump() {
                    Ok(w)
                } else {
                    unreachable!()
                }
            }
            _ => Err(self.syntax("expected a word")),
        }
    }

    fn take_name(&mut self) -> Option<String> {
        if let Token::Word(w) = self.peek() {
            if let Some(n) = word_name(w) {
                self.bump();
                return Some(n);
            }
        }
        None
    }

    // ---- compounds ----
    fn parse_if(&mut self) -> Result<Compound, ParseError> {
        self.expect_keyword("if")?;
        let mut arms = Vec::new();
        let cond = self.parse_list()?;
        self.expect_keyword("then")?;
        let body = self.parse_list()?;
        arms.push((cond, body));
        while self.at_keyword("elif") {
            self.bump();
            let c = self.parse_list()?;
            self.expect_keyword("then")?;
            let b = self.parse_list()?;
            arms.push((c, b));
        }
        let else_body = if self.at_keyword("else") {
            self.bump();
            Some(self.parse_list()?)
        } else {
            None
        };
        self.expect_keyword("fi")?;
        Ok(Compound::If(IfClause { arms, else_body }))
    }

    fn parse_for(&mut self) -> Result<Compound, ParseError> {
        self.expect_keyword("for")?;
        let var = self
            .take_name()
            .ok_or_else(|| self.syntax("for: variable name"))?;
        self.skip_newlines();
        let words = if self.at_keyword("in") {
            self.bump();
            let mut ws = Vec::new();
            while let Token::Word(_) = self.peek() {
                if let Token::Word(w) = self.bump() {
                    ws.push(w);
                }
            }
            Some(ws)
        } else {
            None
        };
        // optional sequential separator before `do`
        self.consume_seq_separators();
        self.expect_keyword("do")?;
        let body = self.parse_list()?;
        self.expect_keyword("done")?;
        Ok(Compound::For(ForClause { var, words, body }))
    }

    fn parse_while(&mut self, until: bool) -> Result<Compound, ParseError> {
        self.expect_keyword(if until { "until" } else { "while" })?;
        let cond = self.parse_list()?;
        self.expect_keyword("do")?;
        let body = self.parse_list()?;
        self.expect_keyword("done")?;
        if until {
            Ok(Compound::Until { cond, body })
        } else {
            Ok(Compound::While { cond, body })
        }
    }

    fn parse_case(&mut self) -> Result<Compound, ParseError> {
        self.expect_keyword("case")?;
        let subject = self.expect_word()?;
        self.skip_newlines();
        self.expect_keyword("in")?;
        self.skip_newlines();
        let mut items = Vec::new();
        loop {
            if self.at_keyword("esac") {
                break;
            }
            if matches!(self.peek(), Token::Op(Operator::LParen)) {
                self.bump();
            }
            let mut patterns = vec![self.expect_word()?];
            while matches!(self.peek(), Token::Op(Operator::Pipe)) {
                self.bump();
                patterns.push(self.expect_word()?);
            }
            if !matches!(self.bump(), Token::Op(Operator::RParen)) {
                return Err(self.syntax("expected ')' in case pattern"));
            }
            self.skip_newlines();
            let body = self.parse_list()?;
            items.push(CaseItem { patterns, body });
            if matches!(self.peek(), Token::Op(Operator::DSemi)) {
                self.bump();
                self.skip_newlines();
            } else {
                break;
            }
        }
        self.expect_keyword("esac")?;
        Ok(Compound::Case(CaseClause { subject, items }))
    }

    fn parse_brace_group(&mut self) -> Result<Compound, ParseError> {
        self.expect_keyword("{")?;
        let list = self.parse_list()?;
        self.expect_keyword("}")?;
        Ok(Compound::BraceGroup(list))
    }

    fn parse_subshell(&mut self) -> Result<Compound, ParseError> {
        if !matches!(self.bump(), Token::Op(Operator::LParen)) {
            return Err(self.syntax("expected '('"));
        }
        let list = self.parse_list()?;
        if !matches!(self.bump(), Token::Op(Operator::RParen)) {
            return Err(self.syntax("expected ')'"));
        }
        Ok(Compound::Subshell(list))
    }

    fn consume_seq_separators(&mut self) {
        loop {
            match self.peek() {
                Token::Op(Operator::Semi) | Token::Newline => {
                    self.bump();
                }
                _ => break,
            }
        }
    }
}

// ---------- word/keyword classification ----------

/// A bare single-literal word matching a reserved spelling, else `None`.
fn word_keyword(w: &Word) -> Option<&'static str> {
    if w.len() != 1 {
        return None;
    }
    if let WordPart::Lit {
        text,
        from_quote: false,
    } = &w[0]
    {
        return match text.as_str() {
            "if" => Some("if"),
            "then" => Some("then"),
            "elif" => Some("elif"),
            "else" => Some("else"),
            "fi" => Some("fi"),
            "for" => Some("for"),
            "in" => Some("in"),
            "while" => Some("while"),
            "until" => Some("until"),
            "do" => Some("do"),
            "done" => Some("done"),
            "case" => Some("case"),
            "esac" => Some("esac"),
            "function" => Some("function"),
            "{" => Some("{"),
            "}" => Some("}"),
            "!" => Some("!"),
            _ => None,
        };
    }
    None
}

/// A bare single-literal word that is a valid name (function/for variable).
fn word_name(w: &Word) -> Option<String> {
    if w.len() != 1 {
        return None;
    }
    if let WordPart::Lit {
        text,
        from_quote: false,
    } = &w[0]
    {
        if is_name(text) {
            return Some(text.clone());
        }
    }
    None
}

fn is_name(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c == '_' || c.is_ascii_alphabetic() => {}
        _ => return false,
    }
    chars.all(|c| c == '_' || c.is_ascii_alphanumeric())
}

/// If `w` is an assignment `NAME=value`, split it into (name, value-word).
/// The value word is the remainder of the first literal after `=` plus the
/// remaining word parts (so `x=a"b"$c` works).
fn word_assignment(w: &Word) -> Option<(String, Word)> {
    let first = w.first()?;
    let (text, from_quote) = match first {
        WordPart::Lit { text, from_quote } => (text, *from_quote),
        _ => return None,
    };
    if from_quote {
        return None;
    }
    let eq = text.find('=')?;
    let name = &text[..eq];
    if name.is_empty() || !is_name(name) {
        return None;
    }
    let rest = &text[eq + 1..];
    let mut value: Word = Vec::new();
    if !rest.is_empty() {
        value.push(WordPart::Lit {
            text: rest.to_string(),
            from_quote: false,
        });
    }
    value.extend(w.iter().skip(1).cloned());
    Some((name.to_string(), value))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lit(w: &Word) -> String {
        // join all literal parts (for simple assertions)
        let mut s = String::new();
        for p in w {
            match p {
                WordPart::Lit { text, .. } => s.push_str(text),
                WordPart::Var { name, .. } => {
                    s.push('$');
                    s.push_str(name);
                }
                WordPart::Sub { .. } => s.push_str("$(...)"),
                WordPart::Arith { .. } => s.push_str("$((...))"),
            }
        }
        s
    }

    fn one_simple(src: &str) -> SimpleCommand {
        let script = parse(src).expect("parse");
        assert_eq!(script.list.items.len(), 1);
        match &script.list.items[0].and_or.first.cmds[0] {
            Command::Simple(s) => s.clone(),
            other => panic!("expected simple, got {other:?}"),
        }
    }

    #[test]
    fn simple_words_and_assignments() {
        let s = one_simple("x=1 y=2 echo hello world");
        assert_eq!(s.assigns.len(), 2);
        assert_eq!(s.assigns[0].name, "x");
        assert_eq!(s.words.len(), 3);
        assert_eq!(lit(&s.words[0]), "echo");
    }

    #[test]
    fn pipeline_and_andor() {
        let script = parse("a | b && c || d").unwrap();
        let ao = &script.list.items[0].and_or;
        assert_eq!(ao.first.cmds.len(), 2); // a | b
        assert_eq!(ao.rest.len(), 2); // && c, || d
        assert_eq!(ao.rest[0].0, AndOrOp::And);
        assert_eq!(ao.rest[1].0, AndOrOp::Or);
    }

    #[test]
    fn bang_pipeline() {
        let script = parse("! grep x f").unwrap();
        assert!(script.list.items[0].and_or.first.bang);
    }

    #[test]
    fn redirects_with_io_number_and_dup() {
        let s = one_simple("echo hi >out 2>&1 <in");
        assert_eq!(s.redirs.len(), 3);
        assert_eq!(s.redirs[0].op, RedirOp::Write);
        assert_eq!(s.redirs[1].op, RedirOp::DupOut);
        assert_eq!(s.redirs[1].io_number, Some(2));
        assert_eq!(s.redirs[1].target, RedirTarget::Dup(DupSpec::Number(1)));
        assert_eq!(s.redirs[2].op, RedirOp::Read);
    }

    #[test]
    fn if_clause() {
        let script = parse("if true; then echo yes; else echo no; fi").unwrap();
        match &script.list.items[0].and_or.first.cmds[0] {
            Command::Compound {
                kind: Compound::If(i),
                ..
            } => {
                assert_eq!(i.arms.len(), 1);
                assert!(i.else_body.is_some());
            }
            other => panic!("expected if, got {other:?}"),
        }
    }

    #[test]
    fn if_elif_chain() {
        let script = parse("if a; then b; elif c; then d; elif e; then f; fi").unwrap();
        if let Command::Compound {
            kind: Compound::If(i),
            ..
        } = &script.list.items[0].and_or.first.cmds[0]
        {
            assert_eq!(i.arms.len(), 3);
            assert!(i.else_body.is_none());
        } else {
            panic!();
        }
    }

    #[test]
    fn for_loop() {
        let script = parse("for x in a b c; do echo $x; done").unwrap();
        if let Command::Compound {
            kind: Compound::For(f),
            ..
        } = &script.list.items[0].and_or.first.cmds[0]
        {
            assert_eq!(f.var, "x");
            assert_eq!(f.words.as_ref().unwrap().len(), 3);
        } else {
            panic!();
        }
    }

    #[test]
    fn while_loop() {
        let script = parse("while true; do echo hi; done").unwrap();
        assert!(matches!(
            &script.list.items[0].and_or.first.cmds[0],
            Command::Compound {
                kind: Compound::While { .. },
                ..
            }
        ));
    }

    #[test]
    fn case_clause() {
        let script = parse("case $x in a) echo A;; b|c) echo BC;; *) echo other;; esac").unwrap();
        if let Command::Compound {
            kind: Compound::Case(c),
            ..
        } = &script.list.items[0].and_or.first.cmds[0]
        {
            assert_eq!(c.items.len(), 3);
            assert_eq!(c.items[1].patterns.len(), 2);
        } else {
            panic!();
        }
    }

    #[test]
    fn brace_group_and_subshell() {
        let script = parse("{ echo a; echo b; }").unwrap();
        assert!(matches!(
            &script.list.items[0].and_or.first.cmds[0],
            Command::Compound {
                kind: Compound::BraceGroup(_),
                ..
            }
        ));
        let script = parse("(cd /tmp; ls)").unwrap();
        assert!(matches!(
            &script.list.items[0].and_or.first.cmds[0],
            Command::Compound {
                kind: Compound::Subshell(_),
                ..
            }
        ));
    }

    #[test]
    fn function_def() {
        let script = parse("greet() { echo hi; }").unwrap();
        match &script.list.items[0].and_or.first.cmds[0] {
            Command::Function { name, body } => {
                assert_eq!(name, "greet");
                assert!(matches!(**body, Command::Compound { .. }));
            }
            other => panic!("expected function, got {other:?}"),
        }
    }

    #[test]
    fn heredoc_redirect() {
        let s = one_simple("cat <<EOF\nline1\nline2\nEOF");
        assert_eq!(s.redirs.len(), 1);
        assert_eq!(s.redirs[0].op, RedirOp::Heredoc);
        assert_eq!(
            s.redirs[0].target,
            RedirTarget::Here {
                body: "line1\nline2\n".to_string(),
                expand: true
            }
        );
    }

    #[test]
    fn multiple_statements_and_sep() {
        let script = parse("echo a; echo b & echo c").unwrap();
        assert_eq!(script.list.items.len(), 3);
        assert_eq!(script.list.items[1].sep, ListSep::Async);
    }

    #[test]
    fn keyword_as_argument_is_word() {
        // `echo if` — `if` is an argument, not a keyword.
        let s = one_simple("echo if then");
        assert_eq!(s.words.len(), 3);
        assert_eq!(lit(&s.words[1]), "if");
    }

    #[test]
    fn incomplete_compound_reports_incomplete() {
        assert!(matches!(
            parse("if true; then echo hi"),
            Err(ParseError::Incomplete(_))
        ));
        assert!(matches!(
            parse("for x in a b"),
            Err(ParseError::Incomplete(_))
        ));
    }
}
