//! The `test` / `[` conditional-expression evaluator.
//!
//! Shared by the `test`/`[` builtin (`exec.rs`) and the `/bin/test` tool
//! (`programs/`), so the operators, precedence, and arity rules live once (B2 in
//! spirit). File metadata is injected as a `stat` closure, so the grammar itself
//! stays OS-free and unit-testable; the builtin passes a closure over `ShellOs::stat`
//! and the `/bin` tool one over the raw syscall.
//!
//! Grammar: `or → and → factor`, with `!` negation, `( … )` grouping, and `-a`
//! binding tighter than `-o`. POSIX one-argument form is a plain non-null string test
//! even when the token looks like an operator.

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

use crate::os::FileStat;

/// File metadata source for the file-test primaries (`-e`/`-f`/`-d`/…). `None` ⇒ the
/// path does not exist or cannot be stat'd.
pub type Stat<'a> = dyn FnMut(&str) -> Option<FileStat> + 'a;

/// Evaluate a `test`/`[` invocation. `name` is `"test"` or `"["`; `args` is the
/// operands (for `[`, the trailing `]` is required and stripped here). Returns the
/// truth value, or an already-prefixed error message ready to print to stderr (exit 2).
pub fn eval(name: &str, args: &[String], stat: &mut Stat) -> Result<bool, String> {
    let mut a: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    if name == "[" {
        if a.last() == Some(&"]") {
            a.pop();
        } else {
            return Err("[: missing ']'".to_string());
        }
    }
    eval_expr(&a, stat).map_err(|m| format!("test: {m}"))
}

fn eval_expr(a: &[&str], stat: &mut Stat) -> Result<bool, String> {
    if a.is_empty() {
        return Ok(false);
    }
    // POSIX's one-argument form is a plain non-null string test, even when the token
    // looks like an operator (`test !`, `test -z`, `test '('`).
    if a.len() == 1 {
        return Ok(!a[0].is_empty());
    }
    let mut i = 0usize;
    let v = test_or(a, &mut i, stat)?;
    if i != a.len() {
        return Err("too many arguments".to_string());
    }
    Ok(v)
}

fn test_or(a: &[&str], i: &mut usize, stat: &mut Stat) -> Result<bool, String> {
    let mut v = test_and(a, i, stat)?;
    while a.get(*i) == Some(&"-o") {
        *i += 1;
        let r = test_and(a, i, stat)?;
        v = v || r;
    }
    Ok(v)
}

fn test_and(a: &[&str], i: &mut usize, stat: &mut Stat) -> Result<bool, String> {
    let mut v = test_factor(a, i, stat)?;
    while a.get(*i) == Some(&"-a") {
        *i += 1;
        let r = test_factor(a, i, stat)?;
        v = v && r;
    }
    Ok(v)
}

fn test_factor(a: &[&str], i: &mut usize, stat: &mut Stat) -> Result<bool, String> {
    let tok = *a.get(*i).ok_or_else(|| "missing argument".to_string())?;
    if tok == "!" {
        *i += 1;
        return Ok(!test_factor(a, i, stat)?);
    }
    if tok == "(" {
        *i += 1;
        let v = test_or(a, i, stat)?;
        if a.get(*i) != Some(&")") {
            return Err("missing ')'".to_string());
        }
        *i += 1;
        return Ok(v);
    }
    let rem = a.len() - *i;
    if rem >= 3 && is_binop(a[*i + 1]) {
        let r = test_binary(a[*i], a[*i + 1], a[*i + 2], stat)?;
        *i += 3;
        return Ok(r);
    }
    if rem >= 2 && is_unop(a[*i]) {
        let r = test_unary(a[*i], a[*i + 1], stat)?;
        *i += 2;
        return Ok(r);
    }
    *i += 1;
    Ok(!tok.is_empty())
}

fn test_unary(op: &str, x: &str, stat: &mut Stat) -> Result<bool, String> {
    Ok(match op {
        "-z" => x.is_empty(),
        "-n" => !x.is_empty(),
        "-e" => stat(x).is_some(),
        "-f" => stat(x).map(|s| !s.is_dir).unwrap_or(false),
        "-d" => stat(x).map(|s| s.is_dir).unwrap_or(false),
        "-s" => stat(x).map(|s| s.size > 0).unwrap_or(false),
        "-r" => stat(x).map(|s| s.readable()).unwrap_or(false),
        "-w" => stat(x).map(|s| s.writable()).unwrap_or(false),
        "-x" => stat(x).map(|s| s.executable()).unwrap_or(false),
        _ => return Err(format!("unknown unary operator {op}")),
    })
}

fn test_binary(x: &str, op: &str, y: &str, stat: &mut Stat) -> Result<bool, String> {
    Ok(match op {
        "=" | "==" => x == y,
        "!=" => x != y,
        "-eq" => num(x)? == num(y)?,
        "-ne" => num(x)? != num(y)?,
        "-lt" => num(x)? < num(y)?,
        "-le" => num(x)? <= num(y)?,
        "-gt" => num(x)? > num(y)?,
        "-ge" => num(x)? >= num(y)?,
        "-nt" => {
            let mx = stat(x).map(|s| s.mtime);
            let my = stat(y).map(|s| s.mtime);
            match (mx, my) {
                (Some(a), Some(b)) => a > b,
                (Some(_), None) => true,
                _ => false,
            }
        }
        "-ot" => {
            let mx = stat(x).map(|s| s.mtime);
            let my = stat(y).map(|s| s.mtime);
            match (mx, my) {
                (Some(a), Some(b)) => a < b,
                (None, Some(_)) => true,
                _ => false,
            }
        }
        _ => return Err(format!("unknown binary operator {op}")),
    })
}

fn num(s: &str) -> Result<i64, String> {
    s.trim()
        .parse::<i64>()
        .map_err(|_| format!("integer expected: {s}"))
}

/// `test` binary operators (keep identical to the `/bin/test` tool).
pub fn is_binop(op: &str) -> bool {
    matches!(
        op,
        "=" | "==" | "!=" | "-eq" | "-ne" | "-lt" | "-le" | "-gt" | "-ge" | "-nt" | "-ot"
    )
}

/// `test` unary operators (keep identical to the `/bin/test` tool).
pub fn is_unop(op: &str) -> bool {
    matches!(
        op,
        "-z" | "-n" | "-e" | "-f" | "-d" | "-s" | "-r" | "-w" | "-x"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec;

    // A fake filesystem: "f" is a 10-byte file, "d" is a directory, anything else
    // is absent. Permission bits are rwx for the owner.
    fn fake(path: &str) -> Option<FileStat> {
        match path {
            "f" => Some(FileStat { is_dir: false, size: 10, mode: 0o700, mtime: 100 }),
            "d" => Some(FileStat { is_dir: true, size: 0, mode: 0o700, mtime: 200 }),
            "empty" => Some(FileStat { is_dir: false, size: 0, mode: 0o000, mtime: 50 }),
            _ => None,
        }
    }

    fn ev(name: &str, args: &[&str]) -> Result<bool, String> {
        let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let mut st = fake;
        eval(name, &a, &mut st)
    }

    #[test]
    fn string_forms() {
        assert_eq!(ev("test", &["abc"]), Ok(true));
        assert_eq!(ev("test", &[""]), Ok(false));
        assert_eq!(ev("test", &["-z", ""]), Ok(true));
        assert_eq!(ev("test", &["-n", "x"]), Ok(true));
        assert_eq!(ev("test", &["a", "=", "a"]), Ok(true));
        assert_eq!(ev("test", &["a", "!=", "b"]), Ok(true));
    }

    #[test]
    fn integer_comparisons() {
        assert_eq!(ev("test", &["3", "-eq", "3"]), Ok(true));
        assert_eq!(ev("test", &["3", "-lt", "5"]), Ok(true));
        assert_eq!(ev("test", &["5", "-ge", "5"]), Ok(true));
        assert!(ev("test", &["x", "-eq", "3"]).is_err());
    }

    #[test]
    fn file_tests_via_stat() {
        assert_eq!(ev("test", &["-e", "f"]), Ok(true));
        assert_eq!(ev("test", &["-e", "nope"]), Ok(false));
        assert_eq!(ev("test", &["-f", "f"]), Ok(true));
        assert_eq!(ev("test", &["-d", "d"]), Ok(true));
        assert_eq!(ev("test", &["-d", "f"]), Ok(false));
        assert_eq!(ev("test", &["-s", "f"]), Ok(true));
        assert_eq!(ev("test", &["-s", "empty"]), Ok(false));
        assert_eq!(ev("test", &["f", "-nt", "d"]), Ok(false)); // f mtime 100 < d 200
        assert_eq!(ev("test", &["d", "-nt", "f"]), Ok(true));
    }

    #[test]
    fn connectives_negation_grouping() {
        assert_eq!(ev("test", &["a", "=", "a", "-a", "b", "=", "b"]), Ok(true));
        assert_eq!(ev("test", &["a", "=", "b", "-o", "c", "=", "c"]), Ok(true));
        assert_eq!(ev("test", &["!", "-z", "x"]), Ok(true));
        assert_eq!(ev("test", &["(", "a", "=", "a", ")"]), Ok(true));
    }

    #[test]
    fn bracket_requires_close_and_errors_prefix() {
        assert_eq!(ev("[", &["x", "]"]), Ok(true));
        assert_eq!(ev("[", &["x"]), Err("[: missing ']'".to_string()));
        assert_eq!(
            ev("test", &["a", "b", "c", "d"]),
            Err("test: too many arguments".to_string())
        );
        let _ = vec![0u8];
    }
}
