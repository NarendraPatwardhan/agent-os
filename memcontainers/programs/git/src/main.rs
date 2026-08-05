//! Thin pure-mc `/bin/git` — reduced guest surface over the host git engine.
//!
//! # Two paths
//!
//! | Class | Transport | When |
//! |-------|-----------|------|
//! | **Local porcelain** | gitfs ctl at `/.git/mc/ctl` | Repo present: discover root by walking parents for `.git/mc/ctl` |
//! | **Remotes** | `host_call` name `"git"` (**CAP_NET**) | clone may run outside a repo; fetch/pull/push include the discovered gitfs mount |
//!
//! Local flow: write Request JSON → close write FD → open/read Response (never close-only).
//! Multi-path `add` / `rm` issue one ctl round-trip per path; `diff` packs path/paths in one request.
//!
//! # Surface (not full git-core)
//!
//! Local: `init`, `status`, `add`, `rm`, `commit`, `log`, `diff`, `show`, `rev-parse`,
//! `branch`, `checkout`/`switch`, `reset`, `tag`, `config`, `remote` (config only).
//! Remotes: `clone [--depth N] [--filter SPEC]`, `fetch`/`pull`/`push` [url].
//! Meta: `version`, `help`. Unknown commands fail closed.

#![no_std]
#![no_main]

use sysroot as rt;

rt::entry!(main);

const MAX_PATH: usize = 512;
const MAX_BODY: usize = 8192;
const MAX_RESP: usize = 16384;
const MAX_STREAM: usize = 16 * 1024 * 1024;
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
        print(b"agentos-git 0.1.0 (thin pure-mc; ctl + host-mediated remotes)\n");
        return 0;
    }
    if cmd == b"help" || cmd == b"--help" {
        eprint(
            b"usage: git <init|status|add|rm|commit|log|diff|show|rev-parse|branch|checkout|switch|reset|tag|config|remote|version|clone|fetch|pull|push>\n",
        );
        eprint(
            b"local porcelain via /.git/mc/ctl (needs repo); remotes via host_call git (CAP_NET; clone works outside a repo)\n",
        );
        eprint(
            b"diff [--cached|--staged] [path...]; clone [--depth N] [--filter SPEC] <url>; add -A/--all; branch -d; tag -d; reset --soft|--mixed|--hard\n",
        );
        return 0;
    }

    if cmd == b"clone" {
        let mut mount = [0u8; MAX_PATH];
        let mount_len = find_git_root(&mut mount).ok();
        return remote_host_call(cmd, &args[..argc], mount_len.map(|n| &mount[..n]));
    }
    if cmd == b"fetch" || cmd == b"pull" || cmd == b"push" {
        let mut mount = [0u8; MAX_PATH];
        let mount_len = match find_git_root(&mut mount) {
            Ok(n) => n,
            Err(_) => {
                eprint(b"git: not a git repository (remote mount cannot be selected)\n");
                return 128;
            }
        };
        return remote_host_call(cmd, &args[..argc], Some(&mount[..mount_len]));
    }

    let mut root = [0u8; MAX_PATH];
    let root_len = match find_git_root(&mut root) {
        Ok(n) => n,
        Err(_) => {
            eprint(b"git: not a git repository (or any parent up to mount root)\n");
            return 128;
        }
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

    // Multi-path / flag-heavy local ops: dedicated builders (engine takes one path per add/rm).
    if cmd == b"rm" {
        return run_rm(ctl, &args[..argc]);
    }
    if cmd == b"add" {
        return run_add(ctl, &args[..argc]);
    }
    if cmd == b"diff" {
        return run_diff(ctl, &args[..argc]);
    }

    let mut req = [0u8; MAX_BODY];
    let req_len = match build_request(cmd, &args[..argc], &mut req) {
        Ok(n) => n,
        Err(code) => return code,
    };
    ctl_roundtrip(ctl, &req[..req_len])
}

// ── Ctl / host_call I/O ──────────────────────────────────────────────────────

/// Write a tokenized Request to ctl, read its dedicated Response, and emit it.
fn ctl_roundtrip(ctl: &str, req: &[u8]) -> i32 {
    let mut token = [0u8; 32];
    let token_len = make_client_token(&mut token);
    let mut tagged = [0u8; MAX_BODY + 192];
    let tagged_len = match inject_client_token(req, &token[..token_len], &mut tagged) {
        Ok(n) => n,
        Err(_) => {
            eprint(b"git: ctl request too large\n");
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
    if rt::write_all(fd, &tagged[..tagged_len]).is_err() {
        rt::close(fd);
        eprint(b"git: ctl write failed\n");
        return 1;
    }
    rt::close(fd);

    let mut response_path = [0u8; MAX_PATH + 64];
    let response_len =
        match response_path_for_ctl(ctl.as_bytes(), &token[..token_len], &mut response_path) {
            Ok(n) => n,
            Err(_) => {
                eprint(b"git: response path too long\n");
                return 1;
            }
        };
    let response_path_str = match core::str::from_utf8(&response_path[..response_len]) {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let fd = match rt::open(response_path_str, rt::O_READ) {
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
                    rt::close(fd);
                    eprint(b"git: ctl response exceeds envelope limit\n");
                    return 1;
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

    emit_ctl_response(&resp[..total], ctl, &token[..token_len])
}

/// Remote argv → `mc_sys_host_call` name `git` + Request JSON body (needs CAP_NET).
fn remote_host_call(cmd: &[u8], args: &[&[u8]], mount: Option<&[u8]>) -> i32 {
    let mut body = [0u8; MAX_BODY];
    let body_len = match build_remote_request(cmd, args, mount, &mut body) {
        Ok(n) => n,
        Err(code) => return code,
    };
    // Wire: "git\0" + JSON Request
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

fn emit_ctl_response(body: &[u8], ctl: &str, token: &[u8]) -> i32 {
    if find_sub(body, b"\"truncated\":true").is_none() {
        return emit_response(body);
    }
    let code = parse_code(body).unwrap_or(1);
    let mut decoded = [0u8; MAX_PATH];
    let stream = match parse_string_field(body, b"stream_path") {
        Some(raw) => match json_unescape(raw, &mut decoded) {
            Ok(n) => &decoded[..n],
            Err(_) => {
                eprint(b"git: invalid stdout stream path\n");
                return 1;
            }
        },
        None => {
            eprint(b"git: truncated response missing stdout stream\n");
            return 1;
        }
    };
    let mut expected = [0u8; 192];
    let mut expected_len = match push(&mut expected, 0, b".git/mc/out/") {
        Ok(n) => n,
        Err(_) => return 1,
    };
    expected_len = match push(&mut expected, expected_len, token) {
        Ok(n) => n,
        Err(_) => return 1,
    };
    if stream != &expected[..expected_len] {
        eprint(b"git: stdout stream path does not match request token\n");
        return 1;
    }
    let suffix = b".git/mc/ctl";
    let ctlb = ctl.as_bytes();
    if ctlb.len() < suffix.len() || &ctlb[ctlb.len() - suffix.len()..] != suffix {
        eprint(b"git: invalid ctl path\n");
        return 1;
    }
    let root = &ctlb[..ctlb.len() - suffix.len()];
    let mut full = [0u8; MAX_PATH + 64];
    let n = match join_path(root, stream, &mut full) {
        Ok(n) => n,
        Err(_) => return 1,
    };
    let path = match core::str::from_utf8(&full[..n]) {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let fd = match rt::open(path, rt::O_READ) {
        Ok(fd) => fd,
        Err(_) => {
            eprint(b"git: cannot open complete stdout stream\n");
            return 1;
        }
    };
    let mut chunk = [0u8; 4096];
    let mut streamed = 0usize;
    loop {
        match rt::read(fd, &mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if streamed > MAX_STREAM - n {
                    rt::close(fd);
                    eprint(b"git: stdout stream exceeds 16 MiB limit\n");
                    return 1;
                }
                streamed += n;
                print(&chunk[..n]);
            }
            Err(_) => {
                rt::close(fd);
                eprint(b"git: stdout stream read failed\n");
                return 1;
            }
        }
    }
    rt::close(fd);
    let mut err = [0u8; MAX_RESP];
    if let Some(s) = parse_string_field(body, b"stderr") {
        match json_unescape(s, &mut err) {
            Ok(n) => eprint(&err[..n]),
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

// ── Remote request builders (host_call) ──────────────────────────────────────

fn build_remote_request(
    cmd: &[u8],
    args: &[&[u8]],
    mount: Option<&[u8]>,
    out: &mut [u8],
) -> Result<usize, i32> {
    let argc = args.len();
    if cmd == b"fetch" || cmd == b"pull" {
        if argc > 3 {
            eprint(b"usage: git fetch|pull [url]\n");
            return Err(2);
        }
        return fmt_remote(
            cmd,
            if argc == 3 { Some(args[2]) } else { None },
            mount,
            out,
        );
    }
    if cmd == b"push" {
        if argc > 3 {
            eprint(b"usage: git push [url]\n");
            return Err(2);
        }
        return fmt_remote(
            b"push",
            if argc == 3 { Some(args[2]) } else { None },
            mount,
            out,
        );
    }
    if cmd == b"clone" {
        return build_clone(args, mount, out);
    }
    Err(2)
}

/// `git clone [--depth N] [--filter SPEC] <url>`
fn build_clone(args: &[&[u8]], mount: Option<&[u8]>, out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    let mut depth: Option<&[u8]> = None;
    let mut filter: Option<&[u8]> = None;
    let mut url: Option<&[u8]> = None;
    let mut i = 2usize;
    while i < argc {
        let a = args[i];
        if a == b"--depth" {
            if i + 1 >= argc {
                eprint(b"usage: git clone [--depth N] [--filter SPEC] <url>\n");
                return Err(2);
            }
            depth = Some(args[i + 1]);
            i += 2;
            continue;
        }
        if a == b"--filter" {
            if i + 1 >= argc {
                eprint(b"usage: git clone [--depth N] [--filter SPEC] <url>\n");
                return Err(2);
            }
            filter = Some(args[i + 1]);
            i += 2;
            continue;
        }
        if a.first() == Some(&b'-') {
            eprint(b"usage: git clone [--depth N] [--filter SPEC] <url>\n");
            return Err(2);
        }
        if url.is_some() {
            eprint(b"usage: git clone [--depth N] [--filter SPEC] <url>\n");
            return Err(2);
        }
        url = Some(a);
        i += 1;
    }
    let url = match url {
        Some(u) if !u.is_empty() => u,
        _ => {
            eprint(b"usage: git clone [--depth N] [--filter SPEC] <url>\n");
            return Err(2);
        }
    };
    fmt_clone(url, depth, filter, mount, out)
}

fn fmt_remote(
    op: &[u8],
    url: Option<&[u8]>,
    mount: Option<&[u8]>,
    out: &mut [u8],
) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{")?;
    let mut comma = false;
    if let Some(url) = url {
        i = push(out, i, b"\"url\":\"")?;
        i = push_escaped(out, i, url)?;
        i = push(out, i, b"\"")?;
        comma = true;
    }
    if let Some(mount) = mount {
        if comma {
            i = push(out, i, b",")?;
        }
        i = push(out, i, b"\"mount\":\"")?;
        i = push_escaped(out, i, mount)?;
        i = push(out, i, b"\"")?;
    }
    i = push(out, i, b"}}")?;
    Ok(i)
}

fn fmt_clone(
    url: &[u8],
    depth: Option<&[u8]>,
    filter: Option<&[u8]>,
    mount: Option<&[u8]>,
    out: &mut [u8],
) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"clone\",\"args\":{\"url\":\"")?;
    i = push_escaped(out, i, url)?;
    i = push(out, i, b"\"")?;
    if let Some(d) = depth {
        // depth is a JSON number (digits only).
        for &b in d {
            if !(b'0'..=b'9').contains(&b) {
                eprint(b"git: clone --depth must be a non-negative integer\n");
                return Err(2);
            }
        }
        if d.is_empty() {
            eprint(b"git: clone --depth must be a non-negative integer\n");
            return Err(2);
        }
        i = push(out, i, b",\"depth\":")?;
        i = push(out, i, d)?;
    }
    if let Some(f) = filter {
        i = push(out, i, b",\"filter\":\"")?;
        i = push_escaped(out, i, f)?;
        i = push(out, i, b"\"")?;
    }
    if let Some(mount) = mount {
        i = push(out, i, b",\"mount\":\"")?;
        i = push_escaped(out, i, mount)?;
        i = push(out, i, b"\"")?;
    }
    i = push(out, i, b"}}")?;
    Ok(i)
}

// ── Local multi-path / flag commands (ctl) ───────────────────────────────────

/// `git diff [--cached|--staged] [path…]` → one ctl Request (`path` or `paths[]`).
fn run_diff(ctl: &str, args: &[&[u8]]) -> i32 {
    let mut req = [0u8; MAX_BODY];
    let n = match build_diff(args, &mut req) {
        Ok(n) => n,
        Err(code) => return code,
    };
    ctl_roundtrip(ctl, &req[..n])
}

fn build_diff(args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    let mut cached = false;
    let mut paths: [&[u8]; MAX_ARGS] = [&[]; MAX_ARGS];
    let mut npaths = 0usize;
    let mut i = 2usize;
    while i < argc {
        let a = args[i];
        if a == b"--cached" || a == b"--staged" {
            cached = true;
            i += 1;
            continue;
        }
        if a.first() == Some(&b'-') {
            eprint(b"usage: git diff [--cached|--staged] [path...]\n");
            return Err(2);
        }
        if npaths >= MAX_ARGS {
            eprint(b"git: too many paths\n");
            return Err(2);
        }
        paths[npaths] = a;
        npaths += 1;
        i += 1;
    }
    fmt_diff(cached, &paths[..npaths], out)
}

fn fmt_diff(cached: bool, paths: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"diff\",\"args\":{")?;
    let mut need_comma = false;
    if cached {
        i = push(out, i, b"\"cached\":true")?;
        need_comma = true;
    }
    if paths.len() == 1 {
        if need_comma {
            i = push(out, i, b",")?;
        }
        i = push(out, i, b"\"path\":\"")?;
        i = push_escaped(out, i, paths[0])?;
        i = push(out, i, b"\"")?;
    } else if paths.len() > 1 {
        if need_comma {
            i = push(out, i, b",")?;
        }
        i = push(out, i, b"\"paths\":[")?;
        for (pi, p) in paths.iter().enumerate() {
            if pi > 0 {
                i = push(out, i, b",")?;
            }
            i = push(out, i, b"\"")?;
            i = push_escaped(out, i, p)?;
            i = push(out, i, b"\"")?;
        }
        i = push(out, i, b"]")?;
    }
    i = push(out, i, b"}}")?;
    Ok(i)
}

/// `git rm <path…>` → one `{"op":"rm","args":{"path":"…"}}` per path.
fn run_rm(ctl: &str, args: &[&[u8]]) -> i32 {
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
        last = ctl_roundtrip(ctl, &req[..n]);
        if last != 0 {
            return last;
        }
    }
    last
}

/// `git add -A|--all` or `git add <path…>` (not both in one invocation).
fn run_add(ctl: &str, args: &[&[u8]]) -> i32 {
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
        return ctl_roundtrip(ctl, b"{\"op\":\"add\",\"args\":{\"all\":true}}");
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
        last = ctl_roundtrip(ctl, &req[..n]);
        if last != 0 {
            return last;
        }
    }
    last
}

// ── Local single-request builders (ctl) ──────────────────────────────────────

fn build_request(cmd: &[u8], args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if cmd == b"init" {
        if argc != 2 {
            eprint(b"usage: git init\n");
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"init\"}", out);
    }
    if cmd == b"status" {
        if argc != 2 {
            eprint(b"usage: git status\n");
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"status\",\"args\":{\"short\":false}}", out);
    }
    if cmd == b"log" {
        if argc != 2 {
            eprint(b"usage: git log\n");
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"log\",\"args\":{\"max_count\":32}}", out);
    }
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
    if cmd == b"branch" {
        return build_branch(args, out);
    }
    if cmd == b"commit" {
        if argc != 4 || args[2] != b"-m" {
            eprint(b"usage: git commit -m <message>\n");
            return Err(2);
        }
        return fmt_commit(args[3], out);
    }
    if cmd == b"checkout" || cmd == b"switch" {
        if argc != 3 {
            eprint(b"usage: git checkout|switch <name>\n");
            return Err(2);
        }
        if args[2].first() == Some(&b'-') {
            eprint(b"usage: git checkout|switch <name>\n");
            return Err(2);
        }
        // Engine accepts both op names; emit the verb the user typed.
        return fmt_op_name(cmd, args[2], out);
    }
    if cmd == b"rev-parse" {
        if argc > 3 {
            eprint(b"usage: git rev-parse [rev]\n");
            return Err(2);
        }
        let rev = if argc >= 3 { args[2] } else { b"HEAD" };
        return fmt_rev_parse(rev, out);
    }
    // Remotes and multi-path add/rm are handled in main before build_request.
    eprint(b"git: unknown or unsupported command\n");
    Err(2)
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

// ── Format helpers (JSON Request fragments) ──────────────────────────────────

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

fn fmt_op_rev(op: &[u8], rev: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{\"rev\":\"")?;
    i = push_escaped(out, i, rev)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_reset(mode: &[u8], rev: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"reset\",\"args\":{\"mode\":\"")?;
    i = push_escaped(out, i, mode)?;
    i = push(out, i, b"\",\"rev\":\"")?;
    i = push_escaped(out, i, rev)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_tag_delete(name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"tag\",\"args\":{\"name\":\"")?;
    i = push_escaped(out, i, name)?;
    i = push(out, i, b"\",\"delete\":true}}")?;
    Ok(i)
}

fn fmt_branch_delete(name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"branch\",\"args\":{\"name\":\"")?;
    i = push_escaped(out, i, name)?;
    i = push(out, i, b"\",\"delete\":true}}")?;
    Ok(i)
}

fn fmt_config_get(key: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(
        out,
        i,
        b"{\"op\":\"config\",\"args\":{\"action\":\"get\",\"key\":\"",
    )?;
    i = push_escaped(out, i, key)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_config_set(key: &[u8], value: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(
        out,
        i,
        b"{\"op\":\"config\",\"args\":{\"action\":\"set\",\"key\":\"",
    )?;
    i = push_escaped(out, i, key)?;
    i = push(out, i, b"\",\"value\":\"")?;
    i = push_escaped(out, i, value)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_remote_add(name: &[u8], url: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(
        out,
        i,
        b"{\"op\":\"remote\",\"args\":{\"action\":\"add\",\"name\":\"",
    )?;
    i = push_escaped(out, i, name)?;
    i = push(out, i, b"\",\"url\":\"")?;
    i = push_escaped(out, i, url)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

fn fmt_remote_remove(name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(
        out,
        i,
        b"{\"op\":\"remote\",\"args\":{\"action\":\"remove\",\"name\":\"",
    )?;
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

// ── Path discovery ───────────────────────────────────────────────────────────

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

// ── Byte / JSON helpers + Response parse ─────────────────────────────────────

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
        match c {
            b'"' => {
                i = push(out, i, b"\\\"")?;
                continue;
            }
            b'\\' => {
                i = push(out, i, b"\\\\")?;
                continue;
            }
            b'\n' => {
                i = push(out, i, b"\\n")?;
                continue;
            }
            b'\r' => {
                i = push(out, i, b"\\r")?;
                continue;
            }
            b'\t' => {
                i = push(out, i, b"\\t")?;
                continue;
            }
            0x08 => {
                i = push(out, i, b"\\b")?;
                continue;
            }
            0x0c => {
                i = push(out, i, b"\\f")?;
                continue;
            }
            0x00..=0x1f => {
                const HEX: &[u8; 16] = b"0123456789abcdef";
                let esc = [
                    b'\\',
                    b'u',
                    b'0',
                    b'0',
                    HEX[(c >> 4) as usize],
                    HEX[(c & 15) as usize],
                ];
                i = push(out, i, &esc)?;
                continue;
            }
            _ => {}
        }
        if i >= out.len() {
            return Err(1);
        }
        out[i] = c;
        i += 1;
    }
    Ok(i)
}

fn make_client_token(out: &mut [u8]) -> usize {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let pid = rt::getpid();
    if out.len() < 9 {
        return 0;
    }
    out[0] = b'p';
    for n in 0..8 {
        let shift = (7 - n) * 4;
        out[1 + n] = HEX[((pid >> shift) & 0xf) as usize];
    }
    9
}

fn inject_client_token(req: &[u8], token: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    if req.is_empty() || token.is_empty() || *req.last().unwrap_or(&0) != b'}' {
        return Err(1);
    }
    let token_field = b"\"client_token\":\"";
    let mut i;
    if req.len() >= 3 && &req[req.len() - 2..] == b"}}" {
        i = push(out, 0, &req[..req.len() - 2])?;
        if req[req.len() - 3] != b'{' {
            i = push(out, i, b",")?;
        }
        i = push(out, i, token_field)?;
        i = push(out, i, token)?;
        i = push(out, i, b"\"}}")?;
    } else {
        i = push(out, 0, &req[..req.len() - 1])?;
        i = push(out, i, b",\"args\":{")?;
        i = push(out, i, token_field)?;
        i = push(out, i, token)?;
        i = push(out, i, b"\"}}")?;
    }
    Ok(i)
}

fn response_path_for_ctl(ctl: &[u8], token: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    if ctl.len() < 3 || &ctl[ctl.len() - 3..] != b"ctl" {
        return Err(1);
    }
    let mut i = push(out, 0, &ctl[..ctl.len() - 3])?;
    i = push(out, i, b"responses/")?;
    i = push(out, i, token)?;
    Ok(i)
}

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
