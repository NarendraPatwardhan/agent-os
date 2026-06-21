//! `invoke` — the host-tool bridge (§8 / API §11.2). Invokes a host-resident tool via
//! `mc_sys_host_call` and streams its result to stdout. Forms:
//!
//!   invoke <name> <json>          # explicit JSON args (e.g. '{"city":"London"}')
//!   invoke <kit> <cmd> [--flag v] # ergonomic flags → JSON
//!   invoke --list | --help        # list registered tools (from /etc/invoke-tools.json)
//!
//! The request blob is `name\0args`. The host routes it to the handler registered with `vm.tool()`
//! — embedded (in-process) or served (the callback crosses the WS). Flag values are type-inferred
//! (`true`/`false` → bool, numeric → number, else string); the host-side zod schema re-validates.
//! Runs at the inherited (full) tier, so it carries `CAP_NET`. A registered tool is also reachable
//! under its own name: a `/bin/<name>` symlink to `invoke` dispatches on argv[0]. Ported from
//! memcontainers' `mc-tool`.

#![no_std]
#![no_main]

use sysroot as rt;
rt::declare_tier!("full");

const MANIFEST: &str = "/etc/invoke-tools.json";

const HELP: &str = "\
invoke — invoke a host-registered tool from inside the VM

Usage: invoke <name> <json>          run tool <name> with a JSON argument object
       invoke <kit> <cmd> [--flag v]  ergonomic flags form (assembled into JSON)
       invoke --list                  list registered tools (from /etc/invoke-tools.json)
       invoke --help                  display this help and exit

Tools are registered on the host with `vm.tool()`; the result streams to stdout
and the host-side schema validates every call. In the flags form, values are
type-inferred: `true`/`false` -> bool, numeric -> number, anything else ->
string; a bare `--flag` is boolean true. invoke runs at the inherited (full)
tier, so it carries CAP_NET.

A registered tool is also reachable under its own name: a `/bin/<name>` symlink
to invoke dispatches on argv[0] (e.g. `weather '{\"city\":\"London\"}'`).

Notes:
  - `--help`/`-h` and `--list` are recognized only when invoked as `invoke`
    itself, not through a `/bin/<name>` alias.
  - Needs a registered tool manifest; without one, calls report
    \"host tools unavailable\".

Exit status:
  0  success
  1  no tools registered, or the host call failed
";

fn fail(msg: &str) -> ! {
    rt::eprint(msg);
    rt::exit(1);
}

/// A bounded byte sink — builds the request blob / JSON without an allocator.
struct Buf {
    data: [u8; 8192],
    len: usize,
}

impl Buf {
    fn new() -> Self {
        Buf { data: [0u8; 8192], len: 0 }
    }
    fn push(&mut self, b: u8) {
        if self.len < self.data.len() {
            self.data[self.len] = b;
            self.len += 1;
        }
    }
    fn extend(&mut self, s: &[u8]) {
        for &b in s {
            self.push(b);
        }
    }
    /// Append `s` as a JSON string body (no quotes), escaping `"` and `\`.
    fn extend_escaped(&mut self, s: &[u8]) {
        for &b in s {
            match b {
                b'"' | b'\\' => {
                    self.push(b'\\');
                    self.push(b);
                }
                b'\n' => self.extend(b"\\n"),
                b'\t' => self.extend(b"\\t"),
                b'\r' => self.extend(b"\\r"),
                _ => self.push(b),
            }
        }
    }
    fn as_slice(&self) -> &[u8] {
        &self.data[..self.len]
    }
}

/// Does `v` look like a JSON number (optional `-`, digits, optional fractional part)? Kept stricter
/// than "numeric-ish" because malformed JSON falls back to `{}` host-side, hiding the real input.
fn looks_numeric(v: &[u8]) -> bool {
    if v.is_empty() {
        return false;
    }
    let mut i = 0;
    if v[i] == b'-' {
        i += 1;
        if i == v.len() {
            return false;
        }
    }
    if v[i] == b'0' {
        i += 1;
    } else if v[i].is_ascii_digit() {
        while i < v.len() && v[i].is_ascii_digit() {
            i += 1;
        }
    } else {
        return false;
    }
    if i < v.len() && v[i] == b'.' {
        i += 1;
        let start = i;
        while i < v.len() && v[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return false;
        }
    }
    i == v.len()
}

/// Append a coerced flag value: `true`/`false` → bool, numeric → bare number, else a quoted string.
fn write_value(out: &mut Buf, v: &[u8]) {
    if v == b"true" || v == b"false" {
        out.extend(v);
    } else if looks_numeric(v) {
        out.extend(v);
    } else {
        out.push(b'"');
        out.extend_escaped(v);
        out.push(b'"');
    }
}

/// Stream a host-call result (an fd) to stdout.
fn stream(fd: i32) -> ! {
    let mut buf = [0u8; 4096];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => break,
            Ok(k) => {
                if rt::write_all(1, &buf[..k]).is_err() {
                    fail("invoke: write failed\n");
                }
            }
            Err(_) => fail("invoke: host call failed\n"),
        }
    }
    rt::exit(0);
}

/// Print the tool manifest (`/etc/invoke-tools.json`), or a hint if none is seeded.
fn print_manifest() -> ! {
    match rt::open(MANIFEST, rt::O_READ) {
        Ok(fd) => stream(fd),
        Err(_) => fail("invoke: no tools registered (no /etc/invoke-tools.json)\n"),
    }
}

/// The final path component of `p` (everything after the last `/`).
fn basename(p: &[u8]) -> &[u8] {
    match p.iter().rposition(|&c| c == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

fn main() {
    let mut argbuf = [0u8; 8192];
    let n = rt::args_into(&mut argbuf);

    // argv[0] basename. Under an alias — a `/bin/<tool>` symlink to invoke (busybox-style, like
    // mcbox) — that basename IS the leading tool/kit name, and argv[1..] are its args. Invoked as
    // `invoke`, behave as before.
    let nul0 = argbuf[..n].iter().position(|&b| b == 0);
    let arg0 = match nul0 {
        Some(i) => &argbuf[..i],
        None => &argbuf[..n],
    };
    let alias = basename(arg0);
    let aliased = alias != b"invoke";

    // The argv[1..] blob: everything after argv[0]'s NUL (empty for a bare call).
    let start = match nul0 {
        Some(i) => i + 1,
        None => n,
    };
    let rest = &argbuf[start..n];

    // Tokenize argv[1..] (NUL-separated) for analysis.
    let mut toks: [&[u8]; 64] = [b""; 64];
    let mut ntok = 0usize;
    for part in rest.split(|&b| b == 0) {
        if part.is_empty() {
            continue;
        }
        if ntok < toks.len() {
            toks[ntok] = part;
            ntok += 1;
        }
    }
    let toks = &toks[..ntok];

    if !aliased {
        // `invoke …`: argv[1..] carries the name, so it must be present.
        if toks.is_empty() {
            fail("invoke: usage: invoke <name> <json> | <kit> <cmd> [--flag value] | --list\n");
        }
        // `--help`/`-h` → this tool's own help; `--list` → the registered tools.
        if toks[0] == b"--help" || toks[0] == b"-h" {
            rt::emit_help(HELP);
        }
        if toks[0] == b"--list" {
            print_manifest();
        }
    }
    // Aliased with no args (`weather` bare) is valid: name = alias, args = none.

    // Only the `--flag` form needs rewriting. Everything else — explicit JSON, a bare positional, or
    // no args — passes the argv[1..] blob through (the host splits on the first NUL into name +
    // args); under an alias we prepend `alias\0` as the name.
    let Some(fidx) = toks.iter().position(|t| t.starts_with(b"--")) else {
        let result = if aliased {
            let mut req = Buf::new();
            req.extend(alias);
            req.push(0); // name\0args
            req.extend(rest);
            rt::host_call(req.as_slice())
        } else {
            rt::host_call(rest)
        };
        match result {
            Ok(fd) => stream(fd),
            Err(_) => fail("invoke: host tools unavailable\n"),
        }
    };
    if !aliased && fidx == 0 {
        fail("invoke: missing tool name before flags\n");
    }

    // Flags form: name = [alias?] + the tokens before the first `--flag` (joined by space); args = a
    // JSON object built from `--flag value` / `--flag=value` / `--bool`.
    let mut req = Buf::new();
    let mut name_empty = true;
    if aliased {
        req.extend(alias);
        name_empty = false;
    }
    for t in toks[..fidx].iter() {
        if !name_empty {
            req.push(b' ');
        }
        name_empty = false;
        req.extend(t);
    }
    req.push(0); // name\0args
    req.push(b'{');
    let mut first = true;
    let mut i = fidx;
    while i < toks.len() {
        let tok = toks[i];
        if !tok.starts_with(b"--") {
            i += 1;
            continue;
        }
        let key_eq = &tok[2..];
        let (key, inline) = match key_eq.iter().position(|&b| b == b'=') {
            Some(p) => (&key_eq[..p], Some(&key_eq[p + 1..])),
            None => (key_eq, None),
        };
        if key.is_empty() {
            i += 1;
            continue;
        }
        if !first {
            req.push(b',');
        }
        first = false;
        req.push(b'"');
        req.extend_escaped(key);
        req.push(b'"');
        req.push(b':');
        if let Some(v) = inline {
            write_value(&mut req, v);
        } else if i + 1 < toks.len() && !toks[i + 1].starts_with(b"--") {
            write_value(&mut req, toks[i + 1]);
            i += 1;
        } else {
            req.extend(b"true"); // a valueless --flag is a boolean true
        }
        i += 1;
    }
    req.push(b'}');

    match rt::host_call(req.as_slice()) {
        Ok(fd) => stream(fd),
        Err(_) => fail("invoke: host tools unavailable\n"),
    }
}

rt::entry!(main);
