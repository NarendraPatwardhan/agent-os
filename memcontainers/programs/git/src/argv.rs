//! Guest `/bin/git` JSON request encoding. Host-testable without the sysroot.

#![allow(dead_code)]

pub fn copy_bytes(src: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    if src.len() > out.len() {
        return Err(1);
    }
    out[..src.len()].copy_from_slice(src);
    Ok(src.len())
}

pub fn push(out: &mut [u8], i: usize, s: &[u8]) -> Result<usize, i32> {
    if i + s.len() > out.len() {
        return Err(1);
    }
    out[i..i + s.len()].copy_from_slice(s);
    Ok(i + s.len())
}

pub fn push_escaped(out: &mut [u8], mut i: usize, s: &[u8]) -> Result<usize, i32> {
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

pub fn valid_depth(value: &[u8]) -> bool {
    !value.is_empty() && value != b"0" && value.iter().all(|byte| byte.is_ascii_digit())
}

pub fn valid_refspec(value: &[u8]) -> bool {
    if !value.starts_with(b"refs/") {
        return false;
    }
    let mut colon = None;
    for (index, byte) in value.iter().enumerate() {
        if *byte == b':' {
            if colon.is_some() {
                return false;
            }
            colon = Some(index);
        }
    }
    match colon {
        Some(index) => {
            index > 0 && index + 1 < value.len() && value[index + 1..].starts_with(b"refs/")
        }
        None => false,
    }
}

pub fn fmt_remote(
    op: &[u8],
    url: Option<&[u8]>,
    depth: Option<&[u8]>,
    out: &mut [u8],
) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{")?;
    if let Some(url) = url {
        i = push(out, i, b"\"url\":\"")?;
        i = push_escaped(out, i, url)?;
        i = push(out, i, b"\"")?;
    }
    if let Some(depth) = depth {
        if url.is_some() {
            i = push(out, i, b",")?;
        }
        i = push(out, i, b"\"depth\":")?;
        i = push(out, i, depth)?;
    }
    i = push(out, i, b"}}")?;
    Ok(i)
}

pub fn fmt_push(url: &[u8], refspec: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"push\",\"args\":{\"url\":\"")?;
    i = push_escaped(out, i, url)?;
    i = push(out, i, b"\",\"refspecs\":[\"")?;
    i = push_escaped(out, i, refspec)?;
    i = push(out, i, b"\"]}}")?;
    Ok(i)
}

pub fn fmt_op_path(op: &[u8], path: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{\"path\":\"")?;
    i = push_escaped(out, i, path)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

pub fn fmt_op_name(op: &[u8], name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{\"name\":\"")?;
    i = push_escaped(out, i, name)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

pub fn fmt_op_rev(op: &[u8], rev: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"")?;
    i = push(out, i, op)?;
    i = push(out, i, b"\",\"args\":{\"rev\":\"")?;
    i = push_escaped(out, i, rev)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

pub fn fmt_reset(mode: &[u8], rev: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"reset\",\"args\":{\"mode\":\"")?;
    i = push_escaped(out, i, mode)?;
    i = push(out, i, b"\",\"rev\":\"")?;
    i = push_escaped(out, i, rev)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

pub fn fmt_tag_delete(name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"tag\",\"args\":{\"name\":\"")?;
    i = push_escaped(out, i, name)?;
    i = push(out, i, b"\",\"delete\":true}}")?;
    Ok(i)
}

pub fn fmt_branch_delete(name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"branch\",\"args\":{\"name\":\"")?;
    i = push_escaped(out, i, name)?;
    i = push(out, i, b"\",\"delete\":true}}")?;
    Ok(i)
}

pub fn fmt_config_get(key: &[u8], out: &mut [u8]) -> Result<usize, i32> {
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

pub fn fmt_config_set(key: &[u8], value: &[u8], out: &mut [u8]) -> Result<usize, i32> {
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

pub fn fmt_remote_add(name: &[u8], url: &[u8], out: &mut [u8]) -> Result<usize, i32> {
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

pub fn fmt_remote_remove(name: &[u8], out: &mut [u8]) -> Result<usize, i32> {
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

pub fn fmt_commit(msg: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"commit\",\"args\":{\"message\":\"")?;
    i = push_escaped(out, i, msg)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

pub fn fmt_rev_parse(rev: &[u8], out: &mut [u8]) -> Result<usize, i32> {
    let mut i = 0usize;
    i = push(out, i, b"{\"op\":\"rev-parse\",\"args\":{\"rev\":\"")?;
    i = push_escaped(out, i, rev)?;
    i = push(out, i, b"\"}}")?;
    Ok(i)
}

/// Parse `git clone|fetch|pull [--depth N] [url]` into the host_call JSON body.
pub fn build_depth_remote(
    op: &[u8],
    args: &[&[u8]],
    require_url: bool,
    out: &mut [u8],
) -> Result<usize, i32> {
    let mut url: Option<&[u8]> = None;
    let mut depth: Option<&[u8]> = None;
    let mut i = 2usize;
    while i < args.len() {
        let a = args[i];
        if a == b"--depth" {
            if depth.is_some() || i + 1 >= args.len() || !valid_depth(args[i + 1]) {
                return Err(2);
            }
            depth = Some(args[i + 1]);
            i += 2;
            continue;
        }
        if a.first() == Some(&b'-') {
            return Err(2);
        }
        if url.is_some() || a.is_empty() {
            return Err(2);
        }
        url = Some(a);
        i += 1;
    }
    if require_url && url.is_none() {
        return Err(2);
    }
    fmt_remote(op, url, depth, out)
}

/// Parse remote argv (`clone`/`fetch`/`pull`/`push`) into the host_call JSON body.
pub fn build_remote_request(cmd: &[u8], args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if cmd == b"fetch" || cmd == b"pull" {
        return build_depth_remote(cmd, args, false, out);
    }
    if cmd == b"push" {
        if argc != 4 || args[2].is_empty() || !valid_refspec(args[3]) {
            return Err(2);
        }
        return fmt_push(args[2], args[3], out);
    }
    if cmd == b"clone" {
        return build_depth_remote(cmd, args, true, out);
    }
    Err(2)
}

/// Parse local argv that is a single JSON request (not add/rm/diff loops).
pub fn build_local_request(cmd: &[u8], args: &[&[u8]], out: &mut [u8]) -> Result<usize, i32> {
    let argc = args.len();
    if cmd == b"init" {
        if argc != 2 {
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"init\"}", out);
    }
    if cmd == b"status" {
        if argc != 2 {
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"status\",\"args\":{\"short\":false}}", out);
    }
    if cmd == b"log" {
        if argc != 2 {
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"log\",\"args\":{\"max_count\":32}}", out);
    }
    if cmd == b"commit" {
        if argc != 4 || args[2] != b"-m" {
            return Err(2);
        }
        return fmt_commit(args[3], out);
    }
    if cmd == b"checkout" || cmd == b"switch" {
        if argc != 3 || args[2].first() == Some(&b'-') {
            return Err(2);
        }
        return fmt_op_name(cmd, args[2], out);
    }
    if cmd == b"rev-parse" {
        if argc > 3 {
            return Err(2);
        }
        let rev = if argc >= 3 { args[2] } else { b"HEAD" };
        return fmt_rev_parse(rev, out);
    }
    if cmd == b"diff" {
        if argc != 3 || (args[2] != b"--cached" && args[2] != b"--staged") {
            return Err(2);
        }
        return copy_bytes(b"{\"op\":\"diff\",\"args\":{\"cached\":true}}", out);
    }
    Err(2)
}
