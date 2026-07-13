//! Spanned surface syntax for the AgentOS grammar language.

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Span {
    pub source: String,
    pub start: usize,
    pub end: usize,
    pub line: usize,
    pub column: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModuleKind {
    Grammar,
    Family,
}

#[derive(Clone, Debug)]
pub struct Module {
    pub kind: ModuleKind,
    pub name: String,
    pub version: String,
    pub start: Option<String>,
    pub uses: Vec<String>,
    pub declarations: Vec<Declaration>,
    pub comments: Vec<Comment>,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct Comment {
    pub text: String,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Associativity {
    Plain,
    Left,
    Right,
}

#[derive(Clone, Debug)]
pub struct Expr {
    pub kind: ExprKind,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum ExprKind {
    Literal(String),
    Pattern {
        value: String,
        flags: String,
    },
    Symbol(String),
    Call {
        name: String,
        args: Vec<Expr>,
    },
    Choice(Vec<Expr>),
    Sequence(Vec<Expr>),
    Optional(Box<Expr>),
    Repeat(Box<Expr>),
    Repeat1(Box<Expr>),
    Field {
        name: String,
        content: Box<Expr>,
    },
    Precedence {
        associativity: Associativity,
        value: i32,
        content: Box<Expr>,
    },
}

#[derive(Clone, Debug, Default)]
pub struct Semantic {
    pub kind: String,
    /// canonical role -> concrete field
    pub roles: Vec<(String, String)>,
    pub traits: Vec<String>,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub struct OperatorRow {
    pub associativity: Associativity,
    pub precedence: i32,
    pub operators: Expr,
    pub span: Span,
}

#[derive(Clone, Debug)]
pub enum Declaration {
    Rule {
        name: String,
        expression: Expr,
        open: bool,
        token: bool,
        semantic: Option<Semantic>,
        span: Span,
    },
    Extend {
        name: String,
        expression: Expr,
        span: Span,
    },
    Slot {
        name: String,
        span: Span,
    },
    Fill {
        name: String,
        expression: Expr,
        span: Span,
    },
    Fragment {
        name: String,
        parameters: Vec<String>,
        expression: Expr,
        span: Span,
    },
    Skip {
        expression: Expr,
        span: Span,
    },
    Externals {
        names: Vec<String>,
        span: Span,
    },
    Word {
        name: String,
        span: Span,
    },
    Conflict {
        names: Vec<String>,
        span: Span,
    },
    Mapping {
        concrete: String,
        semantic: Semantic,
        span: Span,
    },
    OperatorTable {
        name: String,
        operand: String,
        prefix: bool,
        rows: Vec<OperatorRow>,
        semantic: Option<Semantic>,
        span: Span,
    },
}
