//! Thin pure-mc `/bin/git` — reduced guest surface over the host Git engine.
//!
//! Every command uses the `host_call` name `"git"`. The guest owns argv parsing and
//! output presentation; the host owns repository selection, Git state, and network effects.
//!
//! # Surface (not full git-core)
//!
//! Local: `init`, `status`, `add`, `rm`, `commit`, `log`, `diff`, `show`, `rev-parse`,
//! `branch`, `checkout`/`switch`, `reset`, `tag`, `config`, `remote` (config only),
//! `check-ignore`, and `submodule list|status`.
//! Remotes: `clone`, `fetch`, and `pull` accept `--depth`; push requires an explicit refspec;
//! `submodule update` is host-mediated.
//! Meta: `version`, `help`. Unknown commands fail closed.

#![no_std]
#![no_main]

use sysroot as rt;

mod argv;
use argv::{
    build_local_request, build_remote_request, copy_bytes, fmt_branch_delete, fmt_config_get,
    fmt_config_set, fmt_op_name, fmt_op_path, fmt_op_rev, fmt_remote_add, fmt_remote_remove,
    fmt_reset, fmt_tag_delete, push, push_escaped,
};

rt::entry!(main);

const MAX_BODY: usize = 8192;
const MAX_RESP: usize = 16384;
const MAX_ARGV: usize = 4096;
const MAX_ARGS: usize = 16;

fn main() -> i32 {
    let mut abuf = [0u8; MAX_ARGV];
    let an = rt::args_into(&mut abuf);
    if an >= MAX_ARGV {
        eprint(b"git: argument bytes exceed 4095-byte limit\n");
        return 2;
    }
    let mut args: [&[u8]; MAX_ARGS] = [&[]; MAX_ARGS];
    let mut argc = 0usize;
    let mut too_many_args = false;
    for part in abuf[..an].split(|&b| b == 0) {
        if part.is_empty() {
            continue;
        }
        if argc >= MAX_ARGS {
            too_many_args = true;
            break;
        }
        args[argc] = part;
        argc += 1;
    }
    if too_many_args {
        eprint(b"git: too many arguments (maximum 15 after argv[0])\n");
        return 2;
    }
    if argc < 2 {
        eprint(b"usage: git <command> [args]\n");
        return 2;
    }
    let cmd = args[1];

    if cmd == b"version" || cmd == b"--version" {
        print(b"agentos-git 0.1.0 (thin pure-mc; host-mediated Git)\n");
        return 0;
    }
    if cmd == b"help" || cmd == b"--help" {
        eprint(
            b"usage: git <init|status|add|rm|commit|log|diff|show|rev-parse|branch|checkout|switch|reset|tag|config|remote|check-ignore|submodule|version|clone|fetch|pull|push>\n",
        );
        eprint(b"all commands use host_call git; clone works outside a repository\n");
        eprint(
            b"diff --cached|--staged; clone [--depth N] <url>; push <url> <source:destination>; submodule <list|status|update> [path]\n",
        );
        return 0;
    }

    if cmd == b"clone" || cmd == b"fetch" || cmd == b"pull" || cmd == b"push" {
        let mut req = [0u8; MAX_BODY];
        let req_len = match build_remote_request(cmd, &args[..argc], &mut req) {
            Ok(n) => n,
            Err(code) => {
                if cmd == b"push" {
                    eprint(b"usage: git push <url> <source:destination>\n");
                } else if cmd == b"clone" {
                    eprint(b"usage: git clone [--depth N] <url>\n");
                } else {
                    eprint(b"git: unsupported remote option\n");
                }
                return code;
            }
        };
        return host_git_call(&req[..req_len]);
    }

    // Multi-path / flag-heavy local ops: dedicated builders (engine takes one path per add/rm).
    if cmd == b"rm" {
        return run_rm(&args[..argc]);
    }
    if cmd == b"add" {
        return run_add(&args[..argc]);
    }
    if cmd == b"diff" {
        return run_diff(&args[..argc]);
    }

    let mut req = [0u8; MAX_BODY];
    let req_len = match build_request(cmd, &args[..argc], &mut req) {
        Ok(n) => n,
        Err(code) => return code,
    };
    host_git_call(&req[..req_len])
}

// ── host_call I/O ────────────────────────────────────────────────────────────

fn host_git_call(body: &[u8]) -> i32 {
    // Wire: "git\0" + JSON Request
    let mut req = [0u8; MAX_BODY + 8];
    req[0] = b'g';
    req[1] = b'i';
    req[2] = b't';
    req[3] = 0;
    if 4 + body.len() > req.len() {
        eprint(b"git: request too large\n");
        return 1;
    }
    req[4..4 + body.len()].copy_from_slice(body);
    let fd = match rt::host_call(&req[..4 + body.len()]) {
        Ok(f) => f,
        Err(_) => {
            eprint(b"git: host_call git failed\n");
            return 1;
        }
    };
    let mut resp = [0u8; MAX_RESP];
    let mut total = 0usize;
    loop {
        match rt::read(fd, &mut resp[total..]) {
            Ok(0) => break,
            Ok(n) => {
                total += n;
                if total >= MAX_RESP {
                    let _ = rt::close(fd);
                    eprint(b"git: host_call response exceeds envelope limit\n");
                    return 1;
                }
            }
            Err(_) => {
                let _ = rt::close(fd);
                eprint(b"git: host_call read failed\n");
                return 1;
            }
        }
    }
    let _ = rt::close(fd);
    emit_response(&resp[..total])
}

fn emit_response(body: &[u8]) -> i32 {
    let code = parse_code(body).unwrap_or(1);
    // Unescaped output is always ≤ escaped length (\uXXXX shrinks); reuse MAX_RESP.
    let mut buf = [0u8; MAX_RESP];
    if let Some(s) = parse_string_field(body, b"stdout") {
        match json_unescape(s, &mut buf) {
            Ok(n) => print(&buf[..n]),
            Err(_) => print(s),
        }
    }
    if let Some(s) = parse_string_field(body, b"stderr") {
        match json_unescape(s, &mut buf) {
            Ok(n) => eprint(&buf[..n]),
            Err(_) => eprint(s),
        }
    }
    if code == 0 {
        0
    } else if code == 2 {
        2
    } else {
        1
    }
}

// ── Remote request builders ──────────────────────────────────────────────────

// ── Local multi-path / flag commands ─────────────────────────────────────────

/// `git diff --cached|--staged` returns the engine's bounded staged-change summary.
fn run_diff(args: &[&[u8]]) -> i32 {
    let mut req = [0u8; MAX_BODY];
    let n = match build_local_request(b"diff", args, &mut req) {
        Ok(n) => n,
        Err(code) => {
            eprint(b"usage: git diff --cached|--staged\n");
            return code;
        }
    };
    host_git_call(&req[..n])
}

/// `git rm <path…>` → one `{"op":"rm","args":{"path":"…"}}` per path.
fn run_rm(args: &[&[u8]]) -> i32 {
    let argc = args.len();
    if argc < 3 {
        eprint(b"usage: git rm <path...>\n");
        return 2;
    }
    let mut last = 0i32;
    for i in 2..argc {
        let p = args[i];
        if p.first() == Some(&b'-') {
            eprint(b"git: rm: flags not supported (path only)\n");
            return 2;
        }
        let mut req = [0u8; MAX_BODY];
        let n = match fmt_op_path(b"rm", p, &mut req) {
            Ok(n) => n,
            Err(code) => return code,
        };
        last = host_git_call(&req[..n]);
        if last != 0 {
            return last;
        }
    }
    last
}

/// `git add -A|--all` or `git add <path…>` (not both in one invocation).
fn run_add(args: &[&[u8]]) -> i32 {
    let argc = args.len();
    if argc < 3 {
        eprint(b"usage: git add (-A|--all|<path...>)\n");
        return 2;
    }
    // Single all=true when any arg is -A / --all; paths and --all are mutually exclusive.
    let mut all = false;
    let mut path_count = 0usize;
    for i in 2..argc {
        if args[i] == b"-A" || args[i] == b"--all" {
            all = true;
        } else if args[i].first() == Some(&b'-') {
            eprint(b"git: add: unsupported flag\n");
            return 2;
        } else {
            path_count += 1;
        }
    }
    if all {
        if path_count > 0 {
            eprint(b"usage: git add (-A|--all)  OR  git add <path...>\n");
            return 2;
        }
        return host_git_call(b"{\"op\":\"add\",\"args\":{\"all\":true}}");
    }
    if path_count == 0 {
        eprint(b"usage: git add (-A|--all|<path...>)\n");
        return 2;
    }
    let mut last = 0i32;
    for i in 2..argc {
        let p = args[i];
        if p == b"-A" || p == b"--all" {
            continue;
        }
        let mut req = [0u8; MAX_BODY];
        let n = match fmt_op_path(b"add", p, &mut req) {
            Ok(n) => n,
            Err(code) => return code,
        };
        last = host_git_call(&req[..n]);
        if last != 0 {
            return last;
        }
    }
    last
}

// ── Local single-request builders ────────────────────────────────────────────

fn build_request(cmd: &[u8], args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    if cmd == b"init"
        || cmd == b"status"
        || cmd == b"log"
        || cmd == b"commit"
        || cmd == b"checkout"
        || cmd == b"switch"
        || cmd == b"rev-parse"
    {
        return match build_local_request(cmd, args, out) {
            Ok(n) => Ok(n),
            Err(code) => {
                if cmd == b"init" {
                    eprint(b"usage: git init\n");
                } else if cmd == b"status" {
                    eprint(b"usage: git status\n");
                } else if cmd == b"log" {
                    eprint(b"usage: git log\n");
                } else if cmd == b"commit" {
                    eprint(b"usage: git commit -m <message>\n");
                } else if cmd == b"checkout" || cmd == b"switch" {
                    eprint(b"usage: git checkout|switch <name>\n");
                } else if cmd == b"rev-parse" {
                    eprint(b"usage: git rev-parse [rev]\n");
                }
                Err(code)
            }
        };
    }
    let argc = args.len();
    // diff is handled in main (path / --cached flags).
    if cmd == b"show" {
        if argc > 3 {
            eprint(b"usage: git show [rev]\n");
            return Err(2);
        }
        let rev = if argc >= 3 { args[2] } else { b"HEAD" };
        if argc >= 3 && args[2].first() == Some(&b'-') {
            eprint(b"usage: git show [rev]\n");
            return Err(2);
        }
        return fmt_op_rev(b"show", rev, out);
    }
    if cmd == b"reset" {
        return build_reset(args, out);
    }
    if cmd == b"tag" {
        return build_tag(args, out);
    }
    if cmd == b"config" {
        return build_config(args, out);
    }
    if cmd == b"remote" {
        return build_remote_cfg(args, out);
    }
    if cmd == b"check-ignore" {
        if argc != 3 || args[2].first() == Some(&b'-') {
            eprint(b"usage: git check-ignore <path>\n");
            return Err(2);
        }
        return fmt_op_path(b"check-ignore", args[2], out);
    }
    if cmd == b"submodule" {
        return build_submodule(args, out);
    }
    if cmd == b"branch" {
        return build_branch(args, out);
    }
    // Remotes and multi-path add/rm are handled in main before build_request.
    eprint(b"git: unknown or unsupported command\n");
    Err(2)
}

fn build_submodule(args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    if args.len() < 3 || args.len() > 4 {
        eprint(b"usage: git submodule <list|status|update> [path]\n");
        return Err(2);
    }
    let action = args[2];
    if action != b"list" && action != b"status" && action != b"update" {
        eprint(b"usage: git submodule <list|status|update> [path]\n");
        return Err(2);
    }
    if action != b"update" && args.len() == 4 {
        eprint(b"git: submodule path is only valid for update\n");
        return Err(2);
    }
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"submodule\",\"args\":{\"action\":\"")?;
    i = push(out, i, action)?;
    i = push(out, i, b"\"")?;
    if args.len() == 4 {
        if args[3].is_empty() || args[3].first() == Some(&b'-') {
            eprint(b"git: invalid submodule path\n");
            return Err(2);
        }
        i = push(out, i, b",\"path\":\"")?;
        i = push_escaped(out, i, args[3])?;
        i = push(out, i, b"\"")?;
    }
    i = push(out, i, b"}}")?;
    Ok(i)
}

fn build_reset(args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    let mut mode: &[u8] = b"mixed";
    let mut rev: &[u8] = b"HEAD";
    let mut i = 2usize;
    while i < argc {
        let a = args[i];
        if a == b"--soft" {
            mode = b"soft";
        } else if a == b"--mixed" {
            mode = b"mixed";
        } else if a == b"--hard" {
            mode = b"hard";
        } else if a.first() == Some(&b'-') {
            eprint(b"usage: git reset [--soft|--mixed|--hard] [rev]\n");
            return Err(2);
        } else {
            rev = a;
            if i + 1 < argc {
                eprint(b"usage: git reset [--soft|--mixed|--hard] [rev]\n");
                return Err(2);
            }
            break;
        }
        i += 1;
    }
    fmt_reset(mode, rev, out)
}

fn build_tag(args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if argc < 3 {
        eprint(b"usage: git tag [-d] <name>\n");
        return Err(2);
    }
    let mut del = false;
    let mut name: Option<&[u8]> = None;
    for i in 2..argc {
        let a = args[i];
        if a == b"-d" || a == b"--delete" {
            del = true;
        } else if a.first() == Some(&b'-') {
            eprint(b"usage: git tag [-d] <name>\n");
            return Err(2);
        } else if name.is_none() {
            name = Some(a);
        } else {
            eprint(b"usage: git tag [-d] <name>\n");
            return Err(2);
        }
    }
    let name = match name {
        Some(n) => n,
        None => {
            eprint(b"usage: git tag [-d] <name>\n");
            return Err(2);
        }
    };
    if del {
        fmt_tag_delete(name, out)
    } else {
        fmt_op_name(b"tag", name, out)
    }
}

fn build_config(args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if argc < 3 {
        eprint(b"usage: git config (--list|-l|<key> [value])\n");
        return Err(2);
    }
    if args[2] == b"--list" || args[2] == b"-l" {
        if argc > 3 {
            eprint(b"usage: git config --list\n");
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"config\",\"args\":{\"action\":\"list\"}}", out);
    }
    if args[2].first() == Some(&b'-') {
        eprint(b"usage: git config (--list|-l|<key> [value])\n");
        return Err(2);
    }
    let key = args[2];
    if argc == 3 {
        return fmt_config_get(key, out);
    }
    if argc == 4 {
        return fmt_config_set(key, args[3], out);
    }
    eprint(b"usage: git config (--list|-l|<key> [value])\n");
    Err(2)
}

/// Local remote *config* ops (list/add/remove URL) — not network remotes.
fn build_remote_cfg(args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if argc == 2 {
        return copy_bytes(b"{\"op\":\"remote\",\"args\":{\"action\":\"list\"}}", out);
    }
    let sub = args[2];
    if sub == b"add" {
        if argc != 5 {
            eprint(b"usage: git remote add <name> <url>\n");
            return Err(2);
        }
        return fmt_remote_add(args[3], args[4], out);
    }
    if sub == b"remove" || sub == b"rm" {
        if argc != 4 {
            eprint(b"usage: git remote remove <name>\n");
            return Err(2);
        }
        return fmt_remote_remove(args[3], out);
    }
    if sub == b"-v" || sub == b"--verbose" {
        if argc != 3 {
            eprint(b"usage: git remote -v\n");
            return Err(2);
        }
        // List is already name\turl; -v maps to the same list action.
        return copy_bytes(b"{\"op\":\"remote\",\"args\":{\"action\":\"list\"}}", out);
    }
    eprint(b"usage: git remote [add <name> <url>|remove <name>]\n");
    Err(2)
}

fn build_branch(args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if argc == 2 {
        return copy_bytes(b"{\"op\":\"branch\"}", out);
    }
    let mut del = false;
    let mut name: Option<&[u8]> = None;
    for i in 2..argc {
        let a = args[i];
        if a == b"-d" || a == b"-D" || a == b"--delete" {
            del = true;
        } else if a.first() == Some(&b'-') {
            eprint(b"usage: git branch [-d] [<name>]\n");
            return Err(2);
        } else if name.is_none() {
            name = Some(a);
        } else {
            eprint(b"usage: git branch [-d] [<name>]\n");
            return Err(2);
        }
    }
    match (del, name) {
        (true, Some(n)) => fmt_branch_delete(n, out),
        (true, None) => {
            eprint(b"usage: git branch -d <name>\n");
            Err(2)
        }
        (false, Some(n)) => fmt_op_name(b"branch", n, out),
        (false, None) => copy_bytes(b"{\"op\":\"branch\"}", out),
    }
}

// ── Byte / JSON helpers + Response parse ─────────────────────────────────────

/// Unescape a JSON string body (content between quotes) into `dst`.
/// Supports every JSON escape, including UTF-16 surrogate pairs.
fn json_unescape(src: &[u8], dst: &mut [u8]) -> Result<usize, ()> {
    let mut i = 0usize;
    let mut j = 0usize;
    while i < src.len() {
        if src[i] != b'\\' {
            if j >= dst.len() {
                return Err(());
            }
            dst[j] = src[i];
            j += 1;
            i += 1;
            continue;
        }
        i += 1;
        if i >= src.len() {
            return Err(());
        }
        let esc = src[i];
        i += 1;
        match esc {
            b'b' => {
                if j >= dst.len() {
                    return Err(());
                }
                dst[j] = 0x08;
                j += 1;
            }
            b'f' => {
                if j >= dst.len() {
                    return Err(());
                }
                dst[j] = 0x0c;
                j += 1;
            }
            b'n' => {
                if j >= dst.len() {
                    return Err(());
                }
                dst[j] = b'\n';
                j += 1;
            }
            b'r' => {
                if j >= dst.len() {
                    return Err(());
                }
                dst[j] = b'\r';
                j += 1;
            }
            b't' => {
                if j >= dst.len() {
                    return Err(());
                }
                dst[j] = b'\t';
                j += 1;
            }
            b'"' | b'\\' | b'/' => {
                if j >= dst.len() {
                    return Err(());
                }
                dst[j] = esc;
                j += 1;
            }
            b'u' => {
                if i + 4 > src.len() {
                    return Err(());
                }
                let mut cp = parse_hex_quad(&src[i..i + 4])?;
                i += 4;
                if (0xD800..=0xDBFF).contains(&cp) {
                    if i + 6 > src.len() || src[i] != b'\\' || src[i + 1] != b'u' {
                        return Err(());
                    }
                    let low = parse_hex_quad(&src[i + 2..i + 6])?;
                    if !(0xDC00..=0xDFFF).contains(&low) {
                        return Err(());
                    }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    i += 6;
                } else if (0xDC00..=0xDFFF).contains(&cp) {
                    return Err(());
                }
                j = utf8_encode(dst, j, cp)?;
            }
            _ => return Err(()),
        }
    }
    Ok(j)
}

fn parse_hex_quad(src: &[u8]) -> Result<u32, ()> {
    if src.len() != 4 {
        return Err(());
    }
    let mut cp = 0u32;
    for &h in src {
        cp = (cp << 4)
            | match h {
                b'0'..=b'9' => (h - b'0') as u32,
                b'a'..=b'f' => (h - b'a' + 10) as u32,
                b'A'..=b'F' => (h - b'A' + 10) as u32,
                _ => return Err(()),
            };
    }
    Ok(cp)
}

/// Encode a Unicode scalar as UTF-8 into `dst` at `j`. Returns new index.
fn utf8_encode(dst: &mut [u8], j: usize, cp: u32) -> Result<usize, ()> {
    if cp < 0x80 {
        if j >= dst.len() {
            return Err(());
        }
        dst[j] = cp as u8;
        Ok(j + 1)
    } else if cp < 0x800 {
        if j + 2 > dst.len() {
            return Err(());
        }
        dst[j] = 0xC0 | ((cp >> 6) as u8);
        dst[j + 1] = 0x80 | ((cp & 0x3F) as u8);
        Ok(j + 2)
    } else if cp < 0x10000 {
        // Reject lone surrogates; treat rest of BMP as 3-byte UTF-8.
        if (0xD800..=0xDFFF).contains(&cp) {
            return Err(());
        }
        if j + 3 > dst.len() {
            return Err(());
        }
        dst[j] = 0xE0 | ((cp >> 12) as u8);
        dst[j + 1] = 0x80 | (((cp >> 6) & 0x3F) as u8);
        dst[j + 2] = 0x80 | ((cp & 0x3F) as u8);
        Ok(j + 3)
    } else if cp <= 0x10FFFF {
        if j + 4 > dst.len() {
            return Err(());
        }
        dst[j] = 0xF0 | ((cp >> 18) as u8);
        dst[j + 1] = 0x80 | (((cp >> 12) & 0x3F) as u8);
        dst[j + 2] = 0x80 | (((cp >> 6) & 0x3F) as u8);
        dst[j + 3] = 0x80 | ((cp & 0x3F) as u8);
        Ok(j + 4)
    } else {
        Err(())
    }
}

fn parse_code(body: &[u8]) -> Option<i32> {
    let key = b"\"code\":";
    let pos = find_sub(body, key)?;
    let mut p = pos + key.len();
    while p < body.len() && body[p] == b' ' {
        p += 1;
    }
    let mut v: i32 = 0;
    let mut any = false;
    while p < body.len() && body[p].is_ascii_digit() {
        any = true;
        v = v.checked_mul(10)?.checked_add((body[p] - b'0') as i32)?;
        p += 1;
    }
    if any {
        Some(v)
    } else {
        None
    }
}

fn parse_string_field<'a>(body: &'a [u8], name: &[u8]) -> Option<&'a [u8]> {
    let mut key = [0u8; 32];
    if name.len() + 3 > key.len() {
        return None;
    }
    key[0] = b'"';
    key[1..1 + name.len()].copy_from_slice(name);
    key[1 + name.len()] = b'"';
    key[2 + name.len()] = b':';
    let klen = 3 + name.len();
    let pos = find_sub(body, &key[..klen])?;
    let mut p = pos + klen;
    while p < body.len() && body[p] == b' ' {
        p += 1;
    }
    if p >= body.len() || body[p] != b'"' {
        return None;
    }
    p += 1;
    let start = p;
    while p < body.len() {
        if body[p] == b'\\' {
            p += 2;
            continue;
        }
        if body[p] == b'"' {
            return Some(&body[start..p]);
        }
        p += 1;
    }
    None
}

fn find_sub(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    for i in 0..=hay.len() - needle.len() {
        if &hay[i..i + needle.len()] == needle {
            return Some(i);
        }
    }
    None
}

fn print(s: &[u8]) {
    let _ = rt::write_all(1, s);
}
fn eprint(s: &[u8]) {
    let _ = rt::write_all(2, s);
}
