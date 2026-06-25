//! `test EXPR` / `[ EXPR ]` — evaluate a conditional expression; exit 0 (true), 1 (false), or
//! 2 (usage error).
//!
//! HAND-WRITTEN applet (SYSTEMS.md): the evaluator is transcribed from memcontainers'
//! `programs::test`, with file tests over raw `mc` (`rt::stat` + the `Stat` permission
//! predicates). Its CLI is UNUSUAL — the operands are an *expression*, not flags: primaries
//! (`-z`, `-f`, `=`, `-eq`, …), the `!` negation, the `-a`/`-o` connectives, and `( … )`
//! grouping, parsed by a recursive-descent grammar (`or → and → factor`, `-a` binding tighter
//! than `-o`). So clap is used ONLY to render `--help` (the operator surface is documented in
//! `command()`'s `.about`/`.after_help`); the expression itself is consumed positionally and
//! evaluated by hand — clap never interprets `-z`/`-n`/etc. as options.
//!
//! Core-set `/bin` twin of the shell's `test`/`[` builtin, for non-shell spawners
//! (`find -exec test`, `xargs`). `[` is this same applet invoked as `[`; it requires a trailing
//! `]`. Only `test --help`/`test -h` AS THE FIRST argument prints help — `test -h FILE` is
//! evaluated as the `-h`... (n.b. `-h` is not a supported file test, so `test -h FILE` is the
//! two-argument string-then-string form) — matching GNU, which takes the expression literally.
//!
//! Supported primaries — file: `-e -f -d -r -w -x -s`; string: `-z -n`, `STR1 = STR2`
//! (`==` accepted), `STR1 != STR2`; integer: `-eq -ne -lt -le -gt -ge`; file age: `F1 -nt F2`,
//! `F1 -ot F2`. Operators: `! EXPR`, `EXPR1 -a EXPR2`, `EXPR1 -o EXPR2`, `( EXPR )`.
//!
//! Deviations from POSIX/GNU test:
//!   - The symlink test `-L` (and `-h` as a file test), `-O`/`-G`/`-N`, `-t`, the `-ef` binary
//!     primary, and the `-b`/`-c`/`-p`/`-S`/`-k`/`-u`/`-g`/`-G` special-file tests are NOT
//!     supported.
//!   - `-r`/`-w`/`-x` reflect the owner triad (single-subject VM).
//!
//! Exit status: `0` EXPR is true; `1` EXPR is false; `2` a usage or syntax error.
//!
//! Ported from memcontainers' `programs::test`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

fn num(s: &[u8]) -> Result<i64, ()> {
    if s.is_empty() {
        return Err(());
    }
    let (neg, d) = if s[0] == b'-' { (true, &s[1..]) } else { (false, s) };
    if d.is_empty() {
        return Err(());
    }
    let mut v: i64 = 0;
    for &c in d {
        if !c.is_ascii_digit() {
            return Err(());
        }
        v = v
            .checked_mul(10)
            .ok_or(())?
            .checked_add((c - b'0') as i64)
            .ok_or(())?;
    }
    Ok(if neg { -v } else { v })
}

fn stat_of(path: &[u8]) -> Option<rt::Stat> {
    core::str::from_utf8(path).ok().and_then(|p| rt::stat(p).ok())
}

fn is_binop(op: &[u8]) -> bool {
    matches!(
        op,
        b"=" | b"=="
            | b"!="
            | b"-eq"
            | b"-ne"
            | b"-lt"
            | b"-le"
            | b"-gt"
            | b"-ge"
            | b"-nt"
            | b"-ot"
    )
}

fn is_unop(op: &[u8]) -> bool {
    matches!(
        op,
        b"-z" | b"-n" | b"-e" | b"-f" | b"-d" | b"-s" | b"-r" | b"-w" | b"-x"
    )
}

fn unary(op: &[u8], x: &[u8]) -> Result<bool, ()> {
    Ok(match op {
        b"-z" => x.is_empty(),
        b"-n" => !x.is_empty(),
        b"-e" => stat_of(x).is_some(),
        b"-f" => stat_of(x).map(|s| !s.is_dir).unwrap_or(false),
        b"-d" => stat_of(x).map(|s| s.is_dir).unwrap_or(false),
        b"-s" => stat_of(x).map(|s| s.size > 0).unwrap_or(false),
        b"-r" => stat_of(x).map(|s| s.readable()).unwrap_or(false),
        b"-w" => stat_of(x).map(|s| s.writable()).unwrap_or(false),
        b"-x" => stat_of(x).map(|s| s.executable()).unwrap_or(false),
        _ => return Err(()),
    })
}

fn binary(x: &[u8], op: &[u8], y: &[u8]) -> Result<bool, ()> {
    Ok(match op {
        b"=" | b"==" => x == y,
        b"!=" => x != y,
        b"-eq" => num(x)? == num(y)?,
        b"-ne" => num(x)? != num(y)?,
        b"-lt" => num(x)? < num(y)?,
        b"-le" => num(x)? <= num(y)?,
        b"-gt" => num(x)? > num(y)?,
        b"-ge" => num(x)? >= num(y)?,
        // mtime comparison (GNU), with the "exists vs missing" tie-breaks.
        b"-nt" => match (stat_of(x).map(|s| s.mtime), stat_of(y).map(|s| s.mtime)) {
            (Some(a), Some(b)) => a > b,
            (Some(_), None) => true,
            _ => false,
        },
        b"-ot" => match (stat_of(x).map(|s| s.mtime), stat_of(y).map(|s| s.mtime)) {
            (Some(a), Some(b)) => a < b,
            (None, Some(_)) => true,
            _ => false,
        },
        _ => return Err(()),
    })
}

/// Recursive-descent over the token list. `or` → `and` → `factor`.
struct Parser<'a> {
    a: &'a [&'a [u8]],
    i: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a [u8]> {
        self.a.get(self.i).copied()
    }
    fn or(&mut self) -> Result<bool, ()> {
        let mut v = self.and()?;
        while self.peek() == Some(b"-o") {
            self.i += 1;
            let r = self.and()?;
            v = v || r;
        }
        Ok(v)
    }
    fn and(&mut self) -> Result<bool, ()> {
        let mut v = self.factor()?;
        while self.peek() == Some(b"-a") {
            self.i += 1;
            let r = self.factor()?;
            v = v && r;
        }
        Ok(v)
    }
    fn factor(&mut self) -> Result<bool, ()> {
        let tok = self.peek().ok_or(())?;
        if tok == b"!" {
            self.i += 1;
            return Ok(!self.factor()?);
        }
        if tok == b"(" {
            self.i += 1;
            let v = self.or()?;
            if self.peek() != Some(b")") {
                return Err(());
            }
            self.i += 1;
            return Ok(v);
        }
        let rem = self.a.len() - self.i;
        // A 3-token binary primary takes priority (so `-n = -n` compares strings).
        if rem >= 3 && is_binop(self.a[self.i + 1]) {
            let r = binary(self.a[self.i], self.a[self.i + 1], self.a[self.i + 2])?;
            self.i += 3;
            return Ok(r);
        }
        if rem >= 2 && is_unop(self.a[self.i]) {
            let r = unary(self.a[self.i], self.a[self.i + 1])?;
            self.i += 2;
            return Ok(r);
        }
        // A lone token: true iff non-empty.
        self.i += 1;
        Ok(!tok.is_empty())
    }
}

fn eval(a: &[&[u8]]) -> Result<bool, ()> {
    if a.is_empty() {
        return Ok(false);
    }
    // POSIX's one-argument form is a plain non-null string test, even when the
    // token looks like an operator (`test !`, `test -z`, `test '('`).
    if a.len() == 1 {
        return Ok(!a[0].is_empty());
    }
    let mut p = Parser { a, i: 0 };
    let v = p.or()?;
    if p.i != a.len() {
        return Err(()); // trailing tokens
    }
    Ok(v)
}

fn basename(p: &[u8]) -> &[u8] {
    match p.iter().rposition(|&c| c == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

/// The clap command — used ONLY to render `--help`; the expression operands are evaluated by
/// hand (so clap never interprets `-z`/`-n`/`!`/etc.). `disable_help_flag` + `allow_hyphen_values`
/// keep clap entirely out of the operand stream; this `Command` exists for the detailed
/// `.about`/`.after_help` operator reference.
fn command() -> Command {
    Command::new("test")
        .about("Evaluate a conditional expression; exit 0 (true), 1 (false), or 2 (usage error).")
        .override_usage("test EXPR\n       [ EXPR ]")
        .disable_help_flag(true)
        .after_help(
            "File tests:\n  \
             -e FILE     FILE exists\n  \
             -f FILE     FILE exists and is a regular file\n  \
             -d FILE     FILE exists and is a directory\n  \
             -r FILE     FILE exists and is readable\n  \
             -w FILE     FILE exists and is writable\n  \
             -x FILE     FILE exists and is executable\n  \
             -s FILE     FILE exists and has a size greater than zero\n\
             \n\
             String tests:\n  \
             -z STR      length of STR is zero\n  \
             -n STR      length of STR is non-zero\n  \
             STR1 = STR2     the strings are equal (== is also accepted)\n  \
             STR1 != STR2    the strings are not equal\n\
             \n\
             Integer tests (N1 OP N2):\n  \
             -eq equal   -ne not-equal   -lt <   -le <=   -gt >   -ge >=\n\
             \n\
             File age tests:\n  \
             F1 -nt F2   F1 is newer than F2 (by modification time)\n  \
             F1 -ot F2   F1 is older than F2 (by modification time)\n\
             \n\
             Operators:\n  \
             ! EXPR          true if EXPR is false\n  \
             EXPR1 -a EXPR2  logical AND (binds tighter than -o)\n  \
             EXPR1 -o EXPR2  logical OR\n  \
             ( EXPR )        grouping\n\
             \n\
             `[` is this same program invoked as `[`; it requires a trailing `]`. Not supported:\n\
             -L/-h, -O/-G/-N, -t, -ef, and the -b/-c/-p/-S/-k/-u/-g special-file tests.",
        )
        // A catch-all so a stray `--help` past the first token (handled manually) does not make
        // clap choke; the body never actually reads these.
        .arg(
            Arg::new("EXPR")
                .action(ArgAction::Append)
                .num_args(0..)
                .allow_hyphen_values(true)
                .help("the conditional expression (primaries, operators, and grouping)"),
        )
}

/// `test EXPR` / `[ EXPR ]`. Returns the exit status (0 true, 1 false, 2 usage error).
pub fn uumain(args: impl uucore::Args) -> i32 {
    // The full argv (argv[0] = the invocation name, "test" or "["). The expression must be taken
    // literally, so operands are NOT routed through clap's matcher; clap is only for --help.
    let raw: Vec<Vec<u8>> = args
        .map(|a| a.to_string_lossy().into_owned().into_bytes())
        .collect();

    let prog: &[u8] = raw.first().map(|v| v.as_slice()).unwrap_or(b"test");
    let mut parts: Vec<&[u8]> = raw.iter().skip(1).map(|v| v.as_slice()).collect();

    let invoked_as_bracket = basename(prog) == b"[";

    // Only `test --help`/`test -h` as the FIRST argument prints help (matching GNU, which takes
    // the rest of the expression literally). For `[`, GNU's `[` has no help flag, so this only
    // applies to `test`.
    if !invoked_as_bracket {
        if let Some(first) = parts.first() {
            if *first == b"--help" || *first == b"-h" {
                let mut cmd = command();
                print!("{}", cmd.render_help());
                return 0;
            }
        }
    }

    // `[` requires a closing `]`, which is then dropped from the expression.
    if invoked_as_bracket {
        if parts.last().map(|s| *s == b"]").unwrap_or(false) {
            parts.pop();
        } else {
            eprintln!("[: missing ']'");
            return 2;
        }
    }

    match eval(&parts) {
        Ok(true) => 0,
        Ok(false) => 1,
        Err(()) => {
            let name = if invoked_as_bracket { "[" } else { "test" };
            eprintln!("{name}: invalid expression");
            2
        }
    }
}
