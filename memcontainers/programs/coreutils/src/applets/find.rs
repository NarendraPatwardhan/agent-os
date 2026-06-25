//! `find [PATH...] [EXPRESSION]` — walk directory trees and act on matching files.
//!
//! HAND-WRITTEN applet (SYSTEMS.md): the logic is transcribed from memcontainers'
//! `programs::find`, the directory walk runs over the **facade** (`fsutil::list`/`join`/
//! `basename`) + raw `mc` (`use sysroot as rt`), and `-exec` spawns children via `rt::spawn`
//! / `rt::waitpid`. Help and the leading-PATH split go through **clap** (the expression tokens
//! themselves are consumed positionally — `find`'s grammar is not flag-shaped — so clap collects
//! everything after the paths into a trailing-var-arg list that this code tokenizes and parses
//! into an AST).
//!
//! Predicates: `-name`/`-iname`/`-path`/`-ipath` (shell glob `* ? [..]`, NOT regex — there is
//! no `regex` engine here), `-type f/d/l`, `-size [+-]N[ckMG]`, `-empty`, `-newer FILE`,
//! `-mtime [+-]N`, `-perm [-/]MODE`, `-true`/`-false`. Operators: `( )`, `!`/`-not`, `-a`/`-and`
//! (implicit), `-o`/`-or`. Actions: `-print` (default), `-print0`, `-exec CMD ;`, `-exec CMD +`,
//! `-delete`, `-prune`, `-quit`. Global options: `-maxdepth`/`-mindepth`/`-depth`.
//!
//! Deviations from POSIX/GNU find:
//!   - Patterns are shell globs, not regular expressions (no `-regex`/`-iregex`/`-regextype`).
//!   - `-ls`, `-printf`, `-ok`, `-user`/`-group`/`-uid`/`-gid`, `-links`, `-inum`, `-fstype`,
//!     `-follow`/`-L`/`-H`/`-P`, `-amin`/`-cmin`/`-mmin` are NOT supported.
//!   - Only ONE batched `-exec … +` clause is accumulated (one `+` accumulator).
//!   - `-mtime`/`-newer` need the wall clock (`CAP_AMBIENT`); a denied clock yields `now = 0`.
//!
//! Exit status: `0` all paths processed successfully; `1` an error (a path could not be read,
//! a `-delete`/`-exec` failed, the expression was invalid, …); `2` a clap usage error.
//!
//! Ported from memcontainers' `programs::find`.

use alloc::boxed::Box;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

// ---------------------------------------------------------------- glob match
/// Shell-style glob: `*` (any run), `?` (one char), `[abc]`/`[a-z]`/`[!..]`.
fn glob(pat: &[u8], s: &[u8]) -> bool {
    // Iterative backtracking matcher (no recursion blowup on `*`).
    let (mut p, mut c) = (0usize, 0usize);
    let (mut star_p, mut star_c): (Option<usize>, usize) = (None, 0);
    while c < s.len() {
        if p < pat.len() {
            match pat[p] {
                b'?' => {
                    p += 1;
                    c += 1;
                    continue;
                }
                b'*' => {
                    star_p = Some(p);
                    star_c = c;
                    p += 1;
                    continue;
                }
                b'[' => {
                    if let Some((matched, np)) = class_match(pat, p, s[c]) {
                        if matched {
                            p = np;
                            c += 1;
                            continue;
                        }
                    } else if pat[p] == s[c] {
                        // malformed class: treat '[' literally
                        p += 1;
                        c += 1;
                        continue;
                    }
                }
                ch => {
                    if ch == s[c] {
                        p += 1;
                        c += 1;
                        continue;
                    }
                }
            }
        }
        // mismatch → backtrack to the last '*' if any
        if let Some(sp) = star_p {
            p = sp + 1;
            star_c += 1;
            c = star_c;
        } else {
            return false;
        }
    }
    while p < pat.len() && pat[p] == b'*' {
        p += 1;
    }
    p == pat.len()
}

/// Match a `[...]` class at `pat[start]` against byte `ch`; returns
/// `(matched, index after ']')`, or `None` if the class is malformed.
fn class_match(pat: &[u8], start: usize, ch: u8) -> Option<(bool, usize)> {
    let mut i = start + 1;
    let negate = i < pat.len() && (pat[i] == b'!' || pat[i] == b'^');
    if negate {
        i += 1;
    }
    let mut matched = false;
    let mut first = true;
    while i < pat.len() && (pat[i] != b']' || first) {
        first = false;
        if i + 2 < pat.len() && pat[i + 1] == b'-' && pat[i + 2] != b']' {
            if pat[i] <= ch && ch <= pat[i + 2] {
                matched = true;
            }
            i += 3;
        } else {
            if pat[i] == ch {
                matched = true;
            }
            i += 1;
        }
    }
    if i >= pat.len() {
        return None; // no closing ']'
    }
    Some((matched ^ negate, i + 1))
}

// ---------------------------------------------------------------- expression
enum Pred {
    Name(Vec<u8>, bool), // glob, ignore-case (matched on basename)
    Path(Vec<u8>, bool), // glob, ignore-case (matched on full path)
    Type(u8),            // b'f' / b'd' / b'l'
    Size(u64, u8, bool), // size/count, cmp (b'+'/b'-'/b'='), bare value is 512-byte blocks
    Empty,
    Newer(i64),     // reference mtime (ms)
    Mtime(i64, u8), // days, cmp
    Perm(u16, u8),  // mode bits, kind (b'='exact / b'-'all / b'/'any)
    Bool(bool),
}

enum Act {
    Print,
    Print0,
    Delete,
    Quit,
    Prune,
    Exec(Vec<Vec<u8>>, bool), // argv template (with {} placeholders), batched(+)
}

enum Ast {
    Pred(Pred),
    Act(Act),
    Not(Box<Ast>),
    And(Box<Ast>, Box<Ast>),
    Or(Box<Ast>, Box<Ast>),
}

/// A token in the expression (global options are pulled out before this).
enum Tok {
    LParen,
    RParen,
    Not,
    And,
    Or,
    Node(Ast),
}

struct Walk {
    rc: i32,
    quit: bool,
    pruned: bool,
    depth_first: bool,
    mindepth: usize,
    maxdepth: usize,
    has_action: bool,
    now: i64,
    // Single `-exec … +` accumulator (one batched clause supported).
    plus_cmd: Option<Vec<Vec<u8>>>,
    plus_paths: Vec<String>,
}

struct Entry<'a> {
    path: &'a str,
    name: &'a [u8],
    st: rt::Stat,
}

fn lc(b: &[u8]) -> Vec<u8> {
    b.iter().map(|c| c.to_ascii_lowercase()).collect()
}

fn eval(ast: &Ast, e: &Entry, w: &mut Walk) -> bool {
    match ast {
        Ast::Not(x) => !eval(x, e, w),
        Ast::And(a, b) => eval(a, e, w) && eval(b, e, w),
        Ast::Or(a, b) => eval(a, e, w) || eval(b, e, w),
        Ast::Pred(p) => eval_pred(p, e, w),
        Ast::Act(a) => eval_act(a, e, w),
    }
}

fn eval_pred(p: &Pred, e: &Entry, w: &Walk) -> bool {
    match p {
        Pred::Name(g, ic) => {
            if *ic {
                glob(&lc(g), &lc(e.name))
            } else {
                glob(g, e.name)
            }
        }
        Pred::Path(g, ic) => {
            let path = e.path.as_bytes();
            if *ic {
                glob(&lc(g), &lc(path))
            } else {
                glob(g, path)
            }
        }
        Pred::Type(t) => match t {
            b'f' => !e.st.is_dir && !e.st.is_symlink,
            b'd' => e.st.is_dir,
            b'l' => e.st.is_symlink,
            _ => false,
        },
        Pred::Size(n, cmp, blocks) => {
            let v = if *blocks {
                e.st.size.saturating_add(511) / 512
            } else {
                e.st.size
            };
            cmp_ord(v, *n, *cmp)
        }
        Pred::Empty => {
            if e.st.is_dir {
                fsutil::list(e.path).map(|v| v.is_empty()).unwrap_or(false)
            } else {
                e.st.size == 0
            }
        }
        Pred::Newer(ref_ms) => e.st.mtime > *ref_ms,
        Pred::Mtime(days, cmp) => {
            let age = (w.now - e.st.mtime).max(0) / 86_400_000;
            cmp_ord(age as u64, *days as u64, *cmp)
        }
        Pred::Perm(mode, kind) => {
            let m = e.st.mode & 0o777;
            match kind {
                b'=' => m == *mode,
                b'-' => (m & *mode) == *mode, // all listed bits set
                b'/' => (m & *mode) != 0,     // any listed bit set
                _ => false,
            }
        }
        Pred::Bool(b) => *b,
    }
}

fn cmp_ord(v: u64, n: u64, cmp: u8) -> bool {
    match cmp {
        b'+' => v > n,
        b'-' => v < n,
        _ => v == n,
    }
}

fn eval_act(a: &Act, e: &Entry, w: &mut Walk) -> bool {
    match a {
        Act::Print => {
            let _ = rt::write_all(rt::STDOUT, e.path.as_bytes());
            let _ = rt::write_all(rt::STDOUT, b"\n");
            true
        }
        Act::Print0 => {
            let _ = rt::write_all(rt::STDOUT, e.path.as_bytes());
            let _ = rt::write_all(rt::STDOUT, b"\0");
            true
        }
        Act::Delete => {
            // Depth-first traversal (forced when -delete is present) means a
            // directory's children are already gone by the time we get here.
            if rt::unlink(e.path).is_err() {
                eprintln!("find: {}: cannot delete", e.path);
                w.rc = 1;
                false
            } else {
                true
            }
        }
        Act::Quit => {
            w.quit = true;
            true
        }
        Act::Prune => {
            if e.st.is_dir {
                w.pruned = true;
            }
            true
        }
        Act::Exec(tmpl, plus) => {
            if *plus {
                if w.plus_cmd.is_none() {
                    w.plus_cmd = Some(tmpl.clone());
                }
                w.plus_paths.push(e.path.to_string());
                true
            } else {
                run_exec(tmpl, Some(e.path), w)
            }
        }
    }
}

/// Build argv (replacing each lone `{}` with `subst`, or appending `extra` paths
/// for the batched form), spawn, and wait. Returns whether the child exited 0.
fn run_exec(tmpl: &[Vec<u8>], subst: Option<&str>, w: &mut Walk) -> bool {
    let mut blob: Vec<u8> = Vec::new();
    let push = |arg: &[u8], blob: &mut Vec<u8>, first: &mut bool| {
        if !*first {
            blob.push(0);
        }
        *first = false;
        blob.extend_from_slice(arg);
    };
    let mut first = true;
    for arg in tmpl {
        if arg == b"{}" {
            if let Some(s) = subst {
                push(s.as_bytes(), &mut blob, &mut first);
            }
        } else {
            push(arg, &mut blob, &mut first);
        }
    }
    match rt::spawn(&blob, rt::STDIN, rt::STDOUT, rt::STDERR) {
        Ok(pid) => loop {
            match rt::waitpid(pid as i32) {
                Ok(status) => {
                    if status != 0 {
                        w.rc = 1;
                    }
                    return status == 0;
                }
                Err(rt::EINTR) => continue,
                Err(_) => {
                    w.rc = 1;
                    return false;
                }
            }
        },
        Err(_) => {
            eprintln!("find: -exec: cannot run command");
            w.rc = 1;
            false
        }
    }
}

/// Flush the batched `-exec … +` accumulator: run the command once over all the
/// collected paths.
fn flush_plus(w: &mut Walk) {
    let Some(tmpl) = w.plus_cmd.take() else {
        return;
    };
    if w.plus_paths.is_empty() {
        return;
    }
    let mut blob: Vec<u8> = Vec::new();
    let mut first = true;
    let push = |arg: &[u8], blob: &mut Vec<u8>, first: &mut bool| {
        if !*first {
            blob.push(0);
        }
        *first = false;
        blob.extend_from_slice(arg);
    };
    for arg in &tmpl {
        if arg == b"{}" {
            for p in &w.plus_paths {
                push(p.as_bytes(), &mut blob, &mut first);
            }
        } else {
            push(arg, &mut blob, &mut first);
        }
    }
    match rt::spawn(&blob, rt::STDIN, rt::STDOUT, rt::STDERR) {
        Ok(pid) => loop {
            match rt::waitpid(pid as i32) {
                Ok(status) => {
                    if status != 0 {
                        w.rc = 1;
                    }
                    break;
                }
                Err(rt::EINTR) => continue,
                Err(_) => {
                    w.rc = 1;
                    break;
                }
            }
        },
        Err(_) => w.rc = 1,
    }
}

// ---------------------------------------------------------------- traversal
fn walk(path: &str, depth: usize, ast: &Ast, w: &mut Walk) {
    if w.quit {
        return;
    }
    let st = match rt::lstat(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("find: {}: {}", path, rt::strerror(e));
            w.rc = 1;
            return;
        }
    };
    let name = fsutil::basename(path).as_bytes();

    let visit = |w: &mut Walk| {
        if depth < w.mindepth {
            return;
        }
        let e = Entry { path, name, st };
        w.pruned = false;
        let matched = eval(ast, &e, w);
        if matched && !w.has_action {
            let _ = rt::write_all(rt::STDOUT, path.as_bytes());
            let _ = rt::write_all(rt::STDOUT, b"\n");
        }
    };

    // Pre-order: evaluate self, then (unless pruned) descend.
    if !w.depth_first {
        visit(w);
    }
    if st.is_dir && depth < w.maxdepth && !(w.pruned && !w.depth_first) {
        if let Ok(mut names) = fsutil::list(path) {
            names.sort();
            for n in names {
                if w.quit {
                    break;
                }
                let child = fsutil::join(path, &n);
                walk(&child, depth + 1, ast, w);
            }
        }
    }
    // Post-order (-depth / -delete): descend first, then evaluate self.
    if w.depth_first && !w.quit {
        visit(w);
    }
}

/// The clap command — `find`'s help surface and the leading-PATH / trailing-EXPRESSION split.
/// The expression itself is consumed positionally (its grammar is operators, not flags), so the
/// `EXPRESSION` arg is a trailing var-arg the body tokenizes; the `.about`/`.after_help` document
/// the full predicate/operator/action surface.
fn command() -> Command {
    Command::new("find")
        .about("Search a directory hierarchy for files matching an expression.")
        .override_usage("find [PATH]... [EXPRESSION]")
        .after_help(
            "With no PATH, find searches \".\"; with no action, matches are printed.\n\
             \n\
             Global options:\n  \
             -maxdepth N    descend at most N directory levels\n  \
             -mindepth N    do not apply tests/actions at levels less than N\n  \
             -depth         process a directory's contents before the directory itself\n\
             \n\
             Predicates:\n  \
             -name GLOB     basename matches shell GLOB (* ? [..])\n  \
             -iname GLOB    like -name, case-insensitive\n  \
             -path GLOB     full path matches GLOB (-wholename is a synonym)\n  \
             -ipath GLOB    like -path, case-insensitive (-iwholename is a synonym)\n  \
             -type [fdl]    regular file (f), directory (d), or symlink (l)\n  \
             -size [+-]N[ckMG]  size N (bare = 512-byte blocks; c/k/M/G = bytes)\n  \
             -empty         file is an empty regular file or empty directory\n  \
             -newer FILE    file was modified more recently than FILE\n  \
             -mtime [+-]N   file was modified N*24 hours ago\n  \
             -perm [-/]MODE permission bits (exact, -all-of, or /any-of), octal MODE\n  \
             -true          always true\n  \
             -false         always false\n\
             \n\
             Operators (highest precedence first):\n  \
             ( EXPR )       grouping\n  \
             ! EXPR         negation (-not is a synonym)\n  \
             EXPR EXPR      implicit AND (-a / -and is a synonym)\n  \
             EXPR -o EXPR   OR (-or is a synonym)\n\
             \n\
             Actions:\n  \
             -print         print the path (default action), newline-terminated\n  \
             -print0        print the path, NUL-terminated\n  \
             -exec CMD ;    run CMD on each match ({} is replaced by the path)\n  \
             -exec CMD +    run CMD once with all matching paths appended\n  \
             -delete        delete the file (implies -depth)\n  \
             -prune         do not descend into this directory\n  \
             -quit          stop the whole search immediately\n\
             \n\
             Patterns are shell globs, not regular expressions (no -regex). Not supported:\n\
             -ls, -printf, -ok, -user/-group/-uid/-gid, -links, -inum, -fstype, -follow/-L/-H/-P.",
        )
        // The whole PATH...+EXPRESSION tail; clap just collects raw tokens, the body parses them.
        // `allow_hyphen_values` keeps `-name`, `-type`, `!`, etc. as operands rather than flags.
        .arg(
            Arg::new("ARGS")
                .action(ArgAction::Append)
                .num_args(0..)
                .allow_hyphen_values(true)
                .trailing_var_arg(true)
                .help("[PATH]... followed by the find EXPRESSION (predicates, operators, actions)"),
        )
}

/// `find [PATH...] [EXPRESSION]`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    // The raw argv tail as byte slices (find operands and expression tokens are byte-oriented).
    let raw: Vec<Vec<u8>> = m
        .get_many::<String>("ARGS")
        .map(|v| v.map(|s| s.as_bytes().to_vec()).collect())
        .unwrap_or_default();
    let args: Vec<&[u8]> = raw.iter().map(|v| v.as_slice()).collect();

    // 1. Leading paths: args until the first one that begins the expression
    //    (`-`, `(`, `!`).
    let mut i = 0;
    let mut paths: Vec<String> = Vec::new();
    while i < args.len() {
        let a = args[i];
        if a.first() == Some(&b'-') || a == b"(" || a == b"!" {
            break;
        }
        paths.push(String::from_utf8_lossy(a).into_owned());
        i += 1;
    }
    if paths.is_empty() {
        paths.push(".".to_string());
    }

    // 2. Pull out global options, tokenize the rest.
    let mut depth_first = false;
    let mut mindepth = 0usize;
    let mut maxdepth = usize::MAX;
    let mut has_action = false;
    let mut toks: Vec<Tok> = Vec::new();

    while i < args.len() {
        let a = args[i];
        // Fetch the next argument or report a usage error (exit 2).
        macro_rules! next {
            () => {{
                i += 1;
                match args.get(i) {
                    Some(v) => *v,
                    None => {
                        eprintln!("find: {}: missing argument", String::from_utf8_lossy(a));
                        return 2;
                    }
                }
            }};
        }
        match a {
            b"(" => toks.push(Tok::LParen),
            b")" => toks.push(Tok::RParen),
            b"!" | b"-not" => toks.push(Tok::Not),
            b"-a" | b"-and" => toks.push(Tok::And),
            b"-o" | b"-or" => toks.push(Tok::Or),
            b"-depth" => depth_first = true,
            b"-maxdepth" => maxdepth = parse_usize(next!()),
            b"-mindepth" => mindepth = parse_usize(next!()),
            b"-name" => toks.push(Tok::Node(Ast::Pred(Pred::Name(next!().to_vec(), false)))),
            b"-iname" => toks.push(Tok::Node(Ast::Pred(Pred::Name(next!().to_vec(), true)))),
            b"-path" | b"-wholename" => {
                toks.push(Tok::Node(Ast::Pred(Pred::Path(next!().to_vec(), false))))
            }
            b"-ipath" | b"-iwholename" => {
                toks.push(Tok::Node(Ast::Pred(Pred::Path(next!().to_vec(), true))))
            }
            b"-type" => {
                let t = next!();
                toks.push(Tok::Node(Ast::Pred(Pred::Type(*t.first().unwrap_or(&b'f')))));
            }
            b"-size" => {
                let (n, cmp, blocks) = parse_size(next!());
                toks.push(Tok::Node(Ast::Pred(Pred::Size(n, cmp, blocks))));
            }
            b"-empty" => toks.push(Tok::Node(Ast::Pred(Pred::Empty))),
            b"-newer" => {
                let fb = next!();
                let f = String::from_utf8_lossy(fb).into_owned();
                let ms = match rt::lstat(&f) {
                    Ok(s) => s.mtime,
                    Err(e) => {
                        eprintln!("find: {}: {}", String::from_utf8_lossy(fb), rt::strerror(e));
                        return 1;
                    }
                };
                toks.push(Tok::Node(Ast::Pred(Pred::Newer(ms))));
            }
            b"-mtime" => {
                let (n, cmp) = parse_count(next!());
                toks.push(Tok::Node(Ast::Pred(Pred::Mtime(n as i64, cmp))));
            }
            b"-perm" => {
                let (mode, kind) = parse_perm(next!());
                toks.push(Tok::Node(Ast::Pred(Pred::Perm(mode, kind))));
            }
            b"-true" => toks.push(Tok::Node(Ast::Pred(Pred::Bool(true)))),
            b"-false" => toks.push(Tok::Node(Ast::Pred(Pred::Bool(false)))),
            b"-print" => {
                has_action = true;
                toks.push(Tok::Node(Ast::Act(Act::Print)));
            }
            b"-print0" => {
                has_action = true;
                toks.push(Tok::Node(Ast::Act(Act::Print0)));
            }
            b"-delete" => {
                has_action = true;
                depth_first = true; // -delete implies -depth
                toks.push(Tok::Node(Ast::Act(Act::Delete)));
            }
            b"-quit" => toks.push(Tok::Node(Ast::Act(Act::Quit))),
            b"-prune" => toks.push(Tok::Node(Ast::Act(Act::Prune))),
            b"-exec" => {
                has_action = true;
                let mut cmd: Vec<Vec<u8>> = Vec::new();
                let plus;
                loop {
                    i += 1;
                    match args.get(i) {
                        Some(t) if *t == b";" => {
                            plus = false;
                            break;
                        }
                        Some(t) if *t == b"+" => {
                            plus = true;
                            break;
                        }
                        Some(t) => cmd.push(t.to_vec()),
                        None => {
                            eprintln!("find: -exec: missing terminating ; or +");
                            return 2;
                        }
                    }
                }
                toks.push(Tok::Node(Ast::Act(Act::Exec(cmd, plus))));
            }
            _ => {
                eprintln!("find: {}: unknown predicate", String::from_utf8_lossy(a));
                return 2;
            }
        }
        i += 1;
    }

    // 3. Parse tokens into an AST (precedence: or < and < not < primary).
    let ast = if toks.is_empty() {
        Ast::Pred(Pred::Bool(true))
    } else {
        let mut pos = 0;
        match parse_or(&mut toks, &mut pos) {
            Some(a) if pos == toks.len() => a,
            _ => {
                eprintln!("find: invalid expression");
                return 2;
            }
        }
    };

    let mut w = Walk {
        rc: 0,
        quit: false,
        pruned: false,
        depth_first,
        mindepth,
        maxdepth,
        has_action,
        now: rt::time_realtime().unwrap_or(0),
        plus_cmd: None,
        plus_paths: Vec::new(),
    };

    for p in &paths {
        if w.quit {
            break;
        }
        walk(p, 0, &ast, &mut w);
    }
    flush_plus(&mut w);
    w.rc
}

// Recursive-descent over the token Vec (consumed positionally).
fn parse_or(toks: &mut Vec<Tok>, pos: &mut usize) -> Option<Ast> {
    let mut left = parse_and(toks, pos)?;
    while matches!(toks.get(*pos), Some(Tok::Or)) {
        *pos += 1;
        let right = parse_and(toks, pos)?;
        left = Ast::Or(Box::new(left), Box::new(right));
    }
    Some(left)
}

fn parse_and(toks: &mut Vec<Tok>, pos: &mut usize) -> Option<Ast> {
    let mut left = parse_not(toks, pos)?;
    loop {
        match toks.get(*pos) {
            Some(Tok::And) => {
                *pos += 1;
                let right = parse_not(toks, pos)?;
                left = Ast::And(Box::new(left), Box::new(right));
            }
            // Implicit -and: another primary follows directly.
            Some(Tok::Not) | Some(Tok::LParen) | Some(Tok::Node(_)) => {
                let right = parse_not(toks, pos)?;
                left = Ast::And(Box::new(left), Box::new(right));
            }
            _ => break,
        }
    }
    Some(left)
}

fn parse_not(toks: &mut Vec<Tok>, pos: &mut usize) -> Option<Ast> {
    if matches!(toks.get(*pos), Some(Tok::Not)) {
        *pos += 1;
        return Some(Ast::Not(Box::new(parse_not(toks, pos)?)));
    }
    parse_primary(toks, pos)
}

fn parse_primary(toks: &mut Vec<Tok>, pos: &mut usize) -> Option<Ast> {
    match toks.get(*pos) {
        Some(Tok::LParen) => {
            *pos += 1;
            let inner = parse_or(toks, pos)?;
            if !matches!(toks.get(*pos), Some(Tok::RParen)) {
                return None;
            }
            *pos += 1;
            Some(inner)
        }
        Some(Tok::Node(_)) => {
            // Take ownership of the node out of the token vec.
            let tok = core::mem::replace(&mut toks[*pos], Tok::And);
            *pos += 1;
            match tok {
                Tok::Node(a) => Some(a),
                _ => None,
            }
        }
        _ => None,
    }
}

fn parse_usize(b: &[u8]) -> usize {
    core::str::from_utf8(b)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Parse a `[+-]?N[suffix]` count for `-size`. Bare values are in 512-byte
/// blocks, matching POSIX/GNU find; suffixed values are byte counts.
fn parse_size(b: &[u8]) -> (u64, u8, bool) {
    let (cmp, rest) = match b.first() {
        Some(b'+') => (b'+', &b[1..]),
        Some(b'-') => (b'-', &b[1..]),
        _ => (b'=', b),
    };
    let (digits, suffix) = match rest.last() {
        Some(c) if !c.is_ascii_digit() => (&rest[..rest.len() - 1], *c),
        _ => (rest, b'b'),
    };
    let n: u64 = core::str::from_utf8(digits)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let (scaled, blocks) = match suffix {
        b'c' => (n, false),
        b'k' => (n * 1024, false),
        b'M' => (n * 1024 * 1024, false),
        b'G' => (n * 1024 * 1024 * 1024, false),
        _ => (n, true),
    };
    (scaled, cmp, blocks)
}

/// Parse a `[+-]?N` count for age-style predicates.
fn parse_count(b: &[u8]) -> (u64, u8) {
    let (cmp, rest) = match b.first() {
        Some(b'+') => (b'+', &b[1..]),
        Some(b'-') => (b'-', &b[1..]),
        _ => (b'=', b),
    };
    let n: u64 = core::str::from_utf8(rest)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    (n, cmp)
}

/// Parse a `-perm` argument: `MODE` (exact), `-MODE` (all bits), `/MODE` (any).
fn parse_perm(b: &[u8]) -> (u16, u8) {
    let (kind, rest) = match b.first() {
        Some(b'-') => (b'-', &b[1..]),
        Some(b'/') => (b'/', &b[1..]),
        _ => (b'=', b),
    };
    let mode = core::str::from_utf8(rest)
        .ok()
        .and_then(|s| u16::from_str_radix(s, 8).ok())
        .unwrap_or(0)
        & 0o777;
    (mode, kind)
}
