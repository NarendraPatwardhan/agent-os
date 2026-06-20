//! POSIX arithmetic expansion `$(( … ))`.
//!
//! A pure integer (i64) evaluator with C-like precedence (precedence-climbing).
//! OS-free: variable reads and writes go through an [`ArithEnv`] the caller supplies,
//! so the evaluator is trivially unit-testable and the executor wires it to the shell
//! variable map. Integer semantics are wrapping (two's-complement), matching the shell.
//!
//! The single-trait env (rather than two `FnMut` closures over the same map) is what
//! lets the executor implement `get`/`set` with one ordinary borrow — no raw pointers,
//! no `unsafe`.

use alloc::string::{String, ToString};
use alloc::vec::Vec;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArithError(pub String);

/// Variable access for the arithmetic evaluator. `get` returns 0 for an unset or
/// non-numeric name; `set` writes back (for `=`, `+=`, …, `++`, `--`).
pub trait ArithEnv {
    fn get(&mut self, name: &str) -> i64;
    fn set(&mut self, name: &str, val: i64);
}

/// Evaluate `expr` against `env`.
pub fn eval(expr: &str, env: &mut dyn ArithEnv) -> Result<i64, ArithError> {
    let toks = lex(expr)?;
    let mut p = Parser { toks, pos: 0, env };
    let v = p.expr(0)?;
    p.expect_eof()?;
    Ok(v)
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Num(i64),
    Name(String),
    Op(&'static str),
    LParen,
    RParen,
}

fn lex(s: &str) -> Result<Vec<Tok>, ArithError> {
    let c: Vec<char> = s.chars().collect();
    let mut i = 0;
    let mut out = Vec::new();
    while i < c.len() {
        let ch = c[i];
        if ch.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if ch.is_ascii_digit() {
            // decimal, 0x.. hex, 0.. octal
            let start = i;
            if ch == '0' && i + 1 < c.len() && (c[i + 1] == 'x' || c[i + 1] == 'X') {
                i += 2;
                while i < c.len() && c[i].is_ascii_hexdigit() {
                    i += 1;
                }
                let hex: String = c[start + 2..i].iter().collect();
                let v = i64::from_str_radix(&hex, 16).map_err(|_| ArithError("bad hex".into()))?;
                out.push(Tok::Num(v));
                continue;
            }
            while i < c.len() && c[i].is_ascii_digit() {
                i += 1;
            }
            let dec: String = c[start..i].iter().collect();
            let v: i64 = dec.parse().map_err(|_| ArithError("bad number".into()))?;
            out.push(Tok::Num(v));
            continue;
        }
        if ch == '_' || ch.is_ascii_alphabetic() {
            let start = i;
            while i < c.len() && (c[i] == '_' || c[i].is_ascii_alphanumeric()) {
                i += 1;
            }
            out.push(Tok::Name(c[start..i].iter().collect()));
            continue;
        }
        if ch == '(' {
            out.push(Tok::LParen);
            i += 1;
            continue;
        }
        if ch == ')' {
            out.push(Tok::RParen);
            i += 1;
            continue;
        }
        // multi-char operators (maximal munch)
        let two: String = c[i..(i + 2).min(c.len())].iter().collect();
        let three: String = c[i..(i + 3).min(c.len())].iter().collect();
        const OPS3: &[&str] = &["<<=", ">>="];
        const OPS2: &[&str] = &[
            "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=",
            "%=", "&=", "|=", "^=",
        ];
        if let Some(op) = OPS3.iter().find(|o| **o == three) {
            out.push(Tok::Op(op));
            i += 3;
            continue;
        }
        if let Some(op) = OPS2.iter().find(|o| **o == two) {
            out.push(Tok::Op(op));
            i += 2;
            continue;
        }
        const OPS1: &[&str] = &[
            "+", "-", "*", "/", "%", "<", ">", "=", "!", "~", "&", "|", "^", "?", ":", ",",
        ];
        let one: String = ch.to_string();
        if let Some(op) = OPS1.iter().find(|o| **o == one) {
            out.push(Tok::Op(op));
            i += 1;
            continue;
        }
        return Err(ArithError(alloc::format!("unexpected char '{ch}'")));
    }
    Ok(out)
}

struct Parser<'a> {
    toks: Vec<Tok>,
    pos: usize,
    env: &'a mut dyn ArithEnv,
}

impl Parser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.pos)
    }
    fn bump(&mut self) -> Option<Tok> {
        let t = self.toks.get(self.pos).cloned();
        if t.is_some() {
            self.pos += 1;
        }
        t
    }
    fn expect_eof(&self) -> Result<(), ArithError> {
        if self.pos == self.toks.len() {
            Ok(())
        } else {
            Err(ArithError("trailing tokens in expression".into()))
        }
    }

    /// Precedence-climbing. `min_bp` is the minimum binding power to consume.
    fn expr(&mut self, min_bp: u8) -> Result<i64, ArithError> {
        let mut lhs = self.unary()?;
        loop {
            let op = match self.peek() {
                Some(Tok::Op(o)) => *o,
                _ => break,
            };
            // assignment (right-assoc, lowest) handled separately
            if let Some((lbp, rbp)) = infix_bp(op) {
                if lbp < min_bp {
                    break;
                }
                self.bump();
                if op == "?" {
                    // ternary: cond ? a : b
                    let then_v = self.expr(0)?;
                    match self.bump() {
                        Some(Tok::Op(":")) => {}
                        _ => return Err(ArithError("expected ':' in ?:".into())),
                    }
                    let else_v = self.expr(rbp)?;
                    lhs = if lhs != 0 { then_v } else { else_v };
                    continue;
                }
                let rhs = self.expr(rbp)?;
                lhs = apply(op, lhs, rhs)?;
                continue;
            }
            break;
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> Result<i64, ArithError> {
        match self.peek().cloned() {
            Some(Tok::Op("+")) => {
                self.bump();
                self.unary()
            }
            Some(Tok::Op("-")) => {
                self.bump();
                Ok(-self.unary()?)
            }
            Some(Tok::Op("!")) => {
                self.bump();
                Ok((self.unary()? == 0) as i64)
            }
            Some(Tok::Op("~")) => {
                self.bump();
                Ok(!self.unary()?)
            }
            Some(Tok::Op("++")) | Some(Tok::Op("--")) => {
                let op = if let Some(Tok::Op(o)) = self.bump() {
                    o
                } else {
                    unreachable!()
                };
                // pre-inc/dec on a name
                if let Some(Tok::Name(n)) = self.peek().cloned() {
                    self.bump();
                    let cur = self.env.get(&n);
                    let nv = if op == "++" { cur + 1 } else { cur - 1 };
                    self.env.set(&n, nv);
                    Ok(nv)
                } else {
                    Err(ArithError("++/-- needs a variable".into()))
                }
            }
            _ => self.primary(),
        }
    }

    fn primary(&mut self) -> Result<i64, ArithError> {
        match self.bump() {
            Some(Tok::Num(n)) => Ok(n),
            Some(Tok::LParen) => {
                let v = self.expr(0)?;
                match self.bump() {
                    Some(Tok::RParen) => Ok(v),
                    _ => Err(ArithError("expected ')'".into())),
                }
            }
            Some(Tok::Name(n)) => {
                // assignment / compound-assignment / post inc-dec
                match self.peek().cloned() {
                    Some(Tok::Op("=")) => {
                        self.bump();
                        let v = self.expr(2)?; // assignment binds loosely, right-assoc
                        self.env.set(&n, v);
                        Ok(v)
                    }
                    Some(Tok::Op(op))
                        if matches!(
                            op,
                            "+=" | "-=" | "*=" | "/=" | "%=" | "<<=" | ">>=" | "&=" | "|=" | "^="
                        ) =>
                    {
                        self.bump();
                        let rhs = self.expr(2)?;
                        let cur = self.env.get(&n);
                        let base = &op[..op.len() - 1];
                        let v = apply(base, cur, rhs)?;
                        self.env.set(&n, v);
                        Ok(v)
                    }
                    Some(Tok::Op("++")) => {
                        self.bump();
                        let cur = self.env.get(&n);
                        self.env.set(&n, cur + 1);
                        Ok(cur)
                    }
                    Some(Tok::Op("--")) => {
                        self.bump();
                        let cur = self.env.get(&n);
                        self.env.set(&n, cur - 1);
                        Ok(cur)
                    }
                    _ => Ok(self.env.get(&n)),
                }
            }
            other => Err(ArithError(alloc::format!("unexpected token {other:?}"))),
        }
    }
}

/// Left/right binding powers for infix operators. Right-assoc ops use lbp==rbp+1.
fn infix_bp(op: &str) -> Option<(u8, u8)> {
    Some(match op {
        "," => (1, 2),
        "?" => (4, 3), // ternary, right-assoc
        "||" => (5, 6),
        "&&" => (7, 8),
        "|" => (9, 10),
        "^" => (11, 12),
        "&" => (13, 14),
        "==" | "!=" => (15, 16),
        "<" | "<=" | ">" | ">=" => (17, 18),
        "<<" | ">>" => (19, 20),
        "+" | "-" => (21, 22),
        "*" | "/" | "%" => (23, 24),
        _ => return None,
    })
}

fn apply(op: &str, a: i64, b: i64) -> Result<i64, ArithError> {
    Ok(match op {
        "," => b,
        "||" => ((a != 0) || (b != 0)) as i64,
        "&&" => ((a != 0) && (b != 0)) as i64,
        "|" => a | b,
        "^" => a ^ b,
        "&" => a & b,
        "==" => (a == b) as i64,
        "!=" => (a != b) as i64,
        "<" => (a < b) as i64,
        "<=" => (a <= b) as i64,
        ">" => (a > b) as i64,
        ">=" => (a >= b) as i64,
        "<<" => a.wrapping_shl(b as u32),
        ">>" => a.wrapping_shr(b as u32),
        "+" => a.wrapping_add(b),
        "-" => a.wrapping_sub(b),
        "*" => a.wrapping_mul(b),
        "/" => {
            if b == 0 {
                return Err(ArithError("division by zero".into()));
            }
            a.wrapping_div(b)
        }
        "%" => {
            if b == 0 {
                return Err(ArithError("division by zero".into()));
            }
            a.wrapping_rem(b)
        }
        _ => return Err(ArithError(alloc::format!("bad operator '{op}'"))),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::collections::BTreeMap;

    /// A simple in-memory env for tests.
    struct Vars(BTreeMap<String, i64>);
    impl ArithEnv for Vars {
        fn get(&mut self, name: &str) -> i64 {
            *self.0.get(name).unwrap_or(&0)
        }
        fn set(&mut self, name: &str, val: i64) {
            self.0.insert(name.to_string(), val);
        }
    }

    fn ev(s: &str) -> i64 {
        let mut env = Vars(BTreeMap::new());
        eval(s, &mut env).unwrap()
    }

    #[test]
    fn precedence_and_parens() {
        assert_eq!(ev("1 + 2 * 3"), 7);
        assert_eq!(ev("(1 + 2) * 3"), 9);
        assert_eq!(ev("2 * 3 % 4"), 2);
        assert_eq!(ev("10 - 2 - 3"), 5); // left-assoc
    }

    #[test]
    fn comparisons_logical_ternary() {
        assert_eq!(ev("1 < 2"), 1);
        assert_eq!(ev("2 <= 1"), 0);
        assert_eq!(ev("1 && 0"), 0);
        assert_eq!(ev("1 || 0"), 1);
        assert_eq!(ev("(5 > 3) ? 10 : 20"), 10);
        assert_eq!(ev("0 ? 10 : 20"), 20);
    }

    #[test]
    fn bitwise_shift_unary_hex() {
        assert_eq!(ev("1 << 4"), 16);
        assert_eq!(ev("0xff & 0x0f"), 15);
        assert_eq!(ev("~0"), -1);
        assert_eq!(ev("-5 + 3"), -2);
        assert_eq!(ev("!0"), 1);
    }

    #[test]
    fn variables_and_assignment() {
        let mut env = Vars(BTreeMap::new());
        env.0.insert("x".into(), 5);
        assert_eq!(eval("x * 2 + 1", &mut env).unwrap(), 11);
    }

    #[test]
    fn assignment_writes_back_through_env() {
        let mut env = Vars(BTreeMap::new());
        // One env handles both reads and writes — no aliasing gymnastics.
        assert_eq!(eval("y = 3 + 4", &mut env).unwrap(), 7);
        assert_eq!(env.0.get("y"), Some(&7));
        // Compound assignment and pre/post inc read-modify-write the same env.
        assert_eq!(eval("y += 3", &mut env).unwrap(), 10);
        assert_eq!(eval("++y", &mut env).unwrap(), 11);
        assert_eq!(eval("y++", &mut env).unwrap(), 11);
        assert_eq!(env.0.get("y"), Some(&12));
    }

    #[test]
    fn div_by_zero_errors() {
        let mut env = Vars(BTreeMap::new());
        assert!(eval("1 / 0", &mut env).is_err());
    }
}
