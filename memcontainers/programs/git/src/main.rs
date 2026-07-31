//! Thin pure-mc `/bin/git` (GIT.md PR6) — local porcelain via ctl; remotes via host_call.
//!
//! Local cmds discover gitfs root by walking parents for `.git/mc/ctl`, then:
//!   write Request JSON → open/read Response (never close-only).
//! Remote cmds (`clone`/`fetch`/`pull`/`push`) skip root discovery and use
//! `host_call` name `git` (CAP_NET; PR10b) — clone works outside a repo.

#![no_std]
#![no_main]

use sysroot as rt;

rt::entry!(main);

const MAX_PATH: usize = 512;
const MAX_BODY: usize = 8192;
const MAX_RESP: usize = 16384;
const MAX_ARGV: usize = 4096;
const MAX_ARGS: usize = 16;

fn main() -> i32 {
    let mut abuf = [0u8; MAX_ARGV];
    let an = rt::args_into(&mut abuf);
    let mut args: [&[u8]; MAX_ARGS] = [&[]; MAX_ARGS];
    let mut argc = 0usize;
    for part in abuf[..an].split(|&b| b == 0) {
        if part.is_empty() {
            continue;
        }
        if argc >= MAX_ARGS {
            break;
        }
        args[argc] = part;
        argc += 1;
    }
    if argc < 2 {
        eprint(b"usage: git <command> [args]\n");
        return 2;
    }
    let cmd = args[1];

    if cmd == b"version" || cmd == b"--version" {
        print(b"agentos-git 0.1.0 (thin pure-mc; local ctl only)\n");
        return 0;
    }
    if cmd == b"help" || cmd == b"--help" {
        eprint(b"usage: git <init|status|add|commit|log|rev-parse|branch|checkout|version|clone|fetch|pull|push>\n");
        eprint(b"local porcelain via /.git/mc/ctl (needs repo); remotes via host_call git (CAP_NET; clone works outside a repo)\n");
        return 0;
    }

    // Remotes must not require an existing gitfs root (clone has none yet;
    // fetch/pull/push may be invoked before discovery and use host_call).
    if cmd == b"clone" || cmd == b"fetch" || cmd == b"pull" || cmd == b"push" {
        return remote_host_call(cmd, &args[..argc]);
    }

    let mut root = [0u8; MAX_PATH];
    let root_len = match find_git_root(&mut root) {
        Ok(n) => n,
        Err(_) => {
            eprint(b"git: not a git repository (or any parent up to mount root)\n");
            return 128;
        }
    };

    let mut req = [0u8; MAX_BODY];
    let req_len = match build_request(cmd, &args[..argc], &mut req) {
        Ok(n) => n,
        Err(code) => return code,
    };

    let mut ctl_path = [0u8; MAX_PATH];
    let ctl_len = match join_path(&root[..root_len], b".git/mc/ctl", &mut ctl_path) {
        Ok(n) => n,
        Err(_) => {
            eprint(b"git: path too long\n");
            return 1;
        }
    };
    let ctl = match core::str::from_utf8(&ctl_path[..ctl_len]) {
        Ok(s) => s,
        Err(_) => {
            eprint(b"git: bad ctl path\n");
            return 1;
        }
    };

    let flags = rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC;
    let fd = match rt::open(ctl, flags) {
        Ok(f) => f,
        Err(_) => {
            eprint(b"git: cannot open ctl for write\n");
            return 1;
        }
    };
    if rt::write_all(fd, &req[..req_len]).is_err() {
        rt::close(fd);
        eprint(b"git: ctl write failed\n");
        return 1;
    }
    rt::close(fd);

    let fd = match rt::open(ctl, rt::O_READ) {
        Ok(f) => f,
        Err(_) => {
            eprint(b"git: cannot open ctl for read\n");
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
                    break;
                }
            }
            Err(_) => {
                rt::close(fd);
                eprint(b"git: ctl read failed\n");
                return 1;
            }
        }
    }
    rt::close(fd);

    emit_response(&resp[..total])
}

/// PR10b: remote argv → `mc_sys_host_call` name `git` + Request JSON (CAP_NET).
fn remote_host_call(cmd: &[u8], args: &[&[u8]]) -> i32 {
    let mut body = [0u8; MAX_BODY];
    let body_len = match build_remote_request(cmd, args, &mut body) {
        Ok(n) => n,
        Err(code) => return code,
    };
    // req = "git\0" + JSON
    let mut req = [0u8; MAX_BODY + 8];
    req[0] = b'g';
    req[1] = b'i';
    req[2] = b't';
    req[3] = 0;
    if 4 + body_len > req.len() {
        eprint(b"git: remote request too large\n");
        return 1;
    }
    req[4..4 + body_len].copy_from_slice(&body[..body_len]);
    let fd = match rt::host_call(&req[..4 + body_len]) {
        Ok(f) => f,
        Err(_) => {
            eprint(b"git: host_call git failed (need CAP_NET + MapHostCall git)\n");
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
                    break;
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
    if let Some(s) = parse_string_field(body, b"stdout") {
        print(s);
    }
    if let Some(s) = parse_string_field(body, b"stderr") {
        eprint(s);
    }
    if code == 0 {
        0
    } else if code == 2 {
        2
    } else {
        1
    }
}

fn build_remote_request(cmd: &[u8], args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if cmd == b"fetch" || cmd == b"pull" {
        if argc >= 3 {
            return fmt_op_url(cmd, args[2], out);
        }
        return copy_bytes(b"{\"op\":\"fetch\",\"args\":{}}", out);
    }
    if cmd == b"push" {
        if argc >= 3 {
            return fmt_op_url(b"push", args[2], out);
        }
        return copy_bytes(b"{\"op\":\"push\",\"args\":{}}", out);
    }
    if cmd == b"clone" {
        if argc < 3 {
            eprint(b"usage: git clone <url>\n");
            return Err(2);
        }
        return fmt_op_url(b"clone", args[2], out);
    }
    Err(2)
}

fn fmt_op_url(op: &[u8], url: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{\"url\":\"")?;
    i = push_escaped(out, i, url)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn build_request(cmd: &[u8], args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if cmd == b"init" {
        return copy_bytes(b"{\"op\":\"init\"}", out);
    }
    if cmd == b"status" {
        return copy_bytes(b"{\"op\":\"status\",\"args\":{\"short\":false}}", out);
    }
    if cmd == b"log" {
        return copy_bytes(b"{\"op\":\"log\",\"args\":{\"max_count\":32}}", out);
    }
    if cmd == b"branch" && argc == 2 {
        return copy_bytes(b"{\"op\":\"branch\"}", out);
    }
    if cmd == b"branch" && argc >= 3 {
        return fmt_op_name(b"branch", args[2], out);
    }
    if cmd == b"add" && argc >= 3 {
        return fmt_op_path(b"add", args[2], out);
    }
    if cmd == b"commit" {
        if argc < 4 || args[2] != b"-m" {
            eprint(b"usage: git commit -m <message>\n");
            return Err(2);
        }
        return fmt_commit(args[3], out);
    }
    if cmd == b"checkout" && argc >= 3 {
        return fmt_op_name(b"checkout", args[2], out);
    }
    if cmd == b"rev-parse" {
        let rev = if argc >= 3 { args[2] } else { b"HEAD" };
        return fmt_rev_parse(rev, out);
    }
    // Remotes are handled in main before find_git_root / build_request.
    eprint(b"git: unknown or unsupported command\n");
    Err(2)
}

fn fmt_op_path(op: &[u8], path: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{\"path\":\"")?;
    i = push_escaped(out, i, path)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_op_name(op: &[u8], name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{\"name\":\"")?;
    i = push_escaped(out, i, name)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_commit(msg: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"commit\",\"args\":{\"message\":\"")?;
    i = push_escaped(out, i, msg)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_rev_parse(rev: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"rev-parse\",\"args\":{\"rev\":\"")?;
    i = push_escaped(out, i, rev)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn find_git_root(out: &mut [u8]) -> Result<usize, i32> {
    let mut cwd = [0u8; MAX_PATH];
    let mut n = rt::getcwd(&mut cwd).map_err(|_| 1i32)?;
    if n > 0 && cwd[n - 1] == 0 {
        n -= 1;
    }
    loop {
        let mut probe = [0u8; MAX_PATH];
        let pn = join_path(&cwd[..n], b".git/mc/ctl", &mut probe)?;
        let path = core::str::from_utf8(&probe[..pn]).map_err(|_| 1i32)?;
        if rt::stat(path).is_ok() {
            if n > out.len() {
                return Err(1);
            }
            out[..n].copy_from_slice(&cwd[..n]);
            return Ok(n);
        }
        if n <= 1 {
            return Err(1);
        }
        while n > 1 && cwd[n - 1] != b'/' {
            n -= 1;
        }
        if n > 1 {
            n -= 1;
        }
        if n == 0 {
            cwd[0] = b'/';
            n = 1;
        }
    }
}

fn join_path(root: &[u8], rel: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let need = root.len() + 1 + rel.len();
    if need > out.len() {
        return Err(1);
    }
    out[..root.len()].copy_from_slice(root);
    let mut i = root.len();
    if i == 0 || out[i - 1] != b'/' {
        out[i] = b'/';
        i += 1;
    }
    out[i..i + rel.len()].copy_from_slice(rel);
    Ok(i + rel.len())
}

fn copy_bytes(src: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    if src.len() > out.len() {
        return Err(1);
    }
    out[..src.len()].copy_from_slice(src);
    Ok(src.len())
}

fn push(out: &mut [u8], i: usize, s: &[u8]) -> Result<usize, i32> {
    if i + s.len() > out.len() {
        return Err(1);
    }
    out[i..i + s.len()].copy_from_slice(s);
    Ok(i + s.len())
}

fn push_escaped(out: &mut [u8], mut i: usize, s: &[u8]) -> Result<usize, i32> {
    for &c in s {
        if c == b'\\' || c == b'"' {
            i = push(out, i, b"\\")?;
        }
        if c == b'\n' {
            i = push(out, i, b"\\n")?;
            continue;
        }
        if i >= out.len() {
            return Err(1);
        }
        out[i] = c;
        i += 1;
    }
    Ok(i)
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
        v = v * 10 + (body[p] - b'0') as i32;
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
