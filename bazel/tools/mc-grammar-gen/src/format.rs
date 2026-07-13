//! Canonical pretty-printer for the AgentOS grammar surface language.

use mc_parser_ast::{
    Associativity, Comment, Declaration, Expr, ExprKind, Module, ModuleKind, Semantic, Span,
};

const WIDTH: usize = 100;

#[derive(Clone)]
struct Line {
    anchor: usize,
    text: String,
}

struct Printer {
    lines: Vec<Line>,
}

impl Printer {
    fn line(&mut self, span: &Span, text: impl Into<String>) {
        self.lines.push(Line {
            anchor: span.line,
            text: text.into(),
        });
    }

    fn blank(&mut self) {
        if self.lines.last().is_some_and(|line| !line.text.is_empty()) {
            self.lines.push(Line {
                anchor: 0,
                text: String::new(),
            });
        }
    }

    fn semantic(&mut self, semantic: &Semantic) {
        let roles = if semantic.roles.is_empty() {
            String::new()
        } else {
            let roles = semantic
                .roles
                .iter()
                .map(|(canonical, concrete)| {
                    if canonical == concrete {
                        canonical.clone()
                    } else {
                        format!("{canonical}={concrete}")
                    }
                })
                .collect::<Vec<_>>()
                .join(", ");
            format!("({roles})")
        };
        self.line(&semantic.span, format!("  => {}{roles}", semantic.kind));
        if !semantic.traits.is_empty() {
            self.line(
                &semantic.span,
                format!("     derives {}", semantic.traits.join(", ")),
            );
        }
    }

    fn assignment(&mut self, span: &Span, prefix: &str, expression: &Expr) {
        let rendered = render(expression, 0);
        if prefix.len() + rendered.len() <= WIDTH {
            self.line(span, format!("{prefix}{rendered}"));
        } else if let ExprKind::Choice(alternatives) = &expression.kind {
            self.line(span, prefix.trim_end());
            for alternative in alternatives {
                self.wrapped(alternative, "  | ", "    ");
            }
        } else if let ExprKind::Sequence(members) = &expression.kind {
            self.line(span, prefix.trim_end());
            self.wrap_members(members, "  ", "  ");
        } else {
            self.line(span, format!("{prefix}{rendered}"));
        }
    }

    fn wrapped(&mut self, expression: &Expr, first: &str, continuation: &str) {
        if let ExprKind::Sequence(members) = &expression.kind {
            let rendered = render(expression, 0);
            if first.len() + rendered.len() > WIDTH {
                self.wrap_members(members, first, continuation);
                return;
            }
        }
        self.line(
            &expression.span,
            format!("{first}{}", render(expression, 0)),
        );
    }

    fn wrap_members(&mut self, members: &[Expr], first: &str, continuation: &str) {
        let mut prefix = first;
        let mut text = String::from(prefix);
        let mut anchor = members.first().map_or(0, |member| member.span.line);
        for member in members {
            let rendered = render(member, 2);
            let separator = usize::from(text.len() > prefix.len());
            if text.len() + separator + rendered.len() > WIDTH && text.len() > prefix.len() {
                self.lines.push(Line { anchor, text });
                prefix = continuation;
                text = String::from(prefix);
                anchor = member.span.line;
            }
            if text.len() > prefix.len() {
                text.push(' ');
            }
            text.push_str(&rendered);
        }
        self.lines.push(Line { anchor, text });
    }

    fn declaration(&mut self, declaration: &Declaration) {
        match declaration {
            Declaration::Rule {
                name,
                expression,
                open,
                token,
                semantic,
                span,
            } => {
                let modifier = if *open {
                    "open "
                } else if *token {
                    "token "
                } else {
                    ""
                };
                self.assignment(span, &format!("{modifier}{name} = "), expression);
                if let Some(semantic) = semantic {
                    self.semantic(semantic);
                }
            }
            Declaration::Extend {
                name,
                expression,
                span,
            } => {
                self.assignment(span, &format!("extend {name} = "), expression);
            }
            Declaration::Slot { name, span } => self.line(span, format!("slot {name}")),
            Declaration::Fill {
                name,
                expression,
                span,
            } => {
                self.assignment(span, &format!("fill {name} = "), expression);
            }
            Declaration::Fragment {
                name,
                parameters,
                expression,
                span,
            } => {
                self.assignment(
                    span,
                    &format!("fragment {name}({}) = ", parameters.join(", ")),
                    expression,
                );
            }
            Declaration::Skip { expression, span } => {
                self.assignment(span, "skip ", expression);
            }
            Declaration::Externals { names, span } => {
                self.line(span, format!("external {}", names.join(" | ")));
            }
            Declaration::Word { name, span } => self.line(span, format!("word {name}")),
            Declaration::Conflict { names, span } => {
                self.line(span, format!("conflict {}", names.join(" ")));
            }
            Declaration::Mapping {
                concrete,
                semantic,
                span,
            } => {
                self.line(span, format!("map {concrete} => {}", semantic.kind));
            }
            Declaration::OperatorTable {
                name,
                operand,
                prefix,
                rows,
                semantic,
                span,
            } => {
                let kind = if *prefix { "prefix" } else { "infix" };
                self.line(span, format!("{kind} {name} over {operand}"));
                if let Some(semantic) = semantic {
                    self.semantic(semantic);
                }
                let associativity_width = rows
                    .iter()
                    .map(|row| association(row.associativity).len())
                    .max()
                    .unwrap_or(0);
                let precedence_width = rows
                    .iter()
                    .map(|row| row.precedence.to_string().len())
                    .max()
                    .unwrap_or(0);
                for row in rows {
                    self.line(
                        &row.span,
                        format!(
                            "  {:associativity_width$} {:>precedence_width$}: {}",
                            association(row.associativity),
                            row.precedence,
                            render(&row.operators, 0),
                        ),
                    );
                }
            }
        }
    }
}

fn declaration_class(declaration: &Declaration) -> u8 {
    match declaration {
        Declaration::Fragment { .. } => 0,
        Declaration::Skip { .. } | Declaration::Externals { .. } | Declaration::Word { .. } => 1,
        Declaration::Rule { token: true, .. } => 2,
        Declaration::Slot { .. } | Declaration::Fill { .. } => 3,
        Declaration::Rule { .. }
        | Declaration::Extend { .. }
        | Declaration::OperatorTable { .. } => 4,
        Declaration::Mapping { .. } => 5,
        Declaration::Conflict { .. } => 6,
    }
}

fn declaration_is_spacious(declaration: &Declaration) -> bool {
    match declaration {
        Declaration::Rule {
            name,
            expression,
            open,
            token,
            semantic,
            ..
        } => {
            let modifier = if *open {
                5
            } else if *token {
                6
            } else {
                0
            };
            semantic.is_some() || modifier + name.len() + 3 + render(expression, 0).len() > WIDTH
        }
        Declaration::Extend {
            name, expression, ..
        } => 10 + name.len() + render(expression, 0).len() > WIDTH,
        Declaration::OperatorTable { .. } => true,
        _ => false,
    }
}

fn association(value: Associativity) -> &'static str {
    match value {
        Associativity::Plain => "plain",
        Associativity::Left => "left",
        Associativity::Right => "right",
    }
}

fn quote(value: &str) -> String {
    let mut output = String::from("\"");
    for character in value.chars() {
        match character {
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            '\"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            character => output.push(character),
        }
    }
    output.push('\"');
    output
}

fn precedence(expression: &Expr) -> u8 {
    match expression.kind {
        ExprKind::Precedence { .. } => 0,
        ExprKind::Choice(_) => 1,
        ExprKind::Sequence(_) => 2,
        ExprKind::Field { .. } => 3,
        ExprKind::Optional(_) | ExprKind::Repeat(_) | ExprKind::Repeat1(_) => 4,
        _ => 5,
    }
}

fn render(expression: &Expr, parent: u8) -> String {
    let own = precedence(expression);
    let value = match &expression.kind {
        ExprKind::Literal(value) => quote(value),
        ExprKind::Pattern { value, flags } => format!("/{value}/{flags}"),
        ExprKind::Symbol(name) => name.clone(),
        ExprKind::Call { name, args } => format!(
            "{name}({})",
            args.iter()
                .map(|argument| render(argument, 0))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        ExprKind::Choice(values) => values
            .iter()
            .map(|value| render(value, 1))
            .collect::<Vec<_>>()
            .join(" | "),
        ExprKind::Sequence(values) => values
            .iter()
            .map(|value| render(value, 2))
            .collect::<Vec<_>>()
            .join(" "),
        ExprKind::Optional(value) => format!("{}?", render(value, 4)),
        ExprKind::Repeat(value) => format!("{}*", render(value, 4)),
        ExprKind::Repeat1(value) => format!("{}+", render(value, 4)),
        ExprKind::Field { name, content } => format!("{name}:{}", render(content, 4)),
        ExprKind::Precedence {
            associativity,
            value,
            content,
        } => {
            format!(
                "{} {value}: {}",
                association(*associativity),
                render(content, 0)
            )
        }
    };
    if own < parent {
        format!("({value})")
    } else {
        value
    }
}

fn insert_comments(lines: &mut Vec<Line>, comments: &[Comment]) {
    let mut comments = comments.to_vec();
    comments.sort_by_key(|comment| (comment.span.line, comment.span.column));
    for comment in comments {
        if let Some(index) = lines.iter().enumerate().find_map(|(index, line)| {
            (line.anchor == comment.span.line && !line.text.is_empty()).then_some(index)
        }) {
            lines[index].text.push_str("  ");
            lines[index].text.push_str(&comment.text);
            continue;
        }
        let index = lines
            .iter()
            .position(|line| line.anchor > comment.span.line)
            .unwrap_or(lines.len());
        let indentation = " ".repeat(comment.span.column.saturating_sub(1));
        lines.insert(
            index,
            Line {
                anchor: comment.span.line,
                text: format!("{indentation}{}", comment.text),
            },
        );
    }
}

pub fn format(module: &Module) -> String {
    let mut printer = Printer { lines: Vec::new() };
    let kind = match module.kind {
        ModuleKind::Grammar => "grammar",
        ModuleKind::Family => "family",
    };
    let version = if module.version.is_empty() {
        String::new()
    } else {
        format!(" {}", quote(&module.version))
    };
    printer.line(&module.span, format!("{kind} {}{version}", module.name));
    if !module.uses.is_empty() || module.start.is_some() {
        printer.blank();
        for name in &module.uses {
            printer.line(&module.span, format!("use {name}"));
        }
        if let Some(start) = &module.start {
            printer.line(&module.span, format!("start {start}"));
        }
    }
    let mut previous: Option<&Declaration> = None;
    for declaration in &module.declarations {
        let separate = previous.is_none_or(|previous| {
            declaration_class(previous) != declaration_class(declaration)
                || (declaration_class(declaration) == 4
                    && (declaration_is_spacious(previous) || declaration_is_spacious(declaration)))
        });
        if separate {
            printer.blank();
        }
        printer.declaration(declaration);
        previous = Some(declaration);
    }
    while printer
        .lines
        .last()
        .is_some_and(|line| line.text.is_empty())
    {
        printer.lines.pop();
    }
    insert_comments(&mut printer.lines, &module.comments);
    let mut output = printer
        .lines
        .into_iter()
        .map(|line| line.text)
        .collect::<Vec<_>>()
        .join("\n");
    output.push('\n');
    output
}
