//! `invoke` — the host-tool bridge (§8 / API §11.2). Invokes a host-resident tool via
//! `mc_sys_host_call` and streams its result to stdout. Forms:
//!
//!   invoke <name> <json>          # explicit JSON args (e.g. '{"city":"London"}')
//!   invoke <kit> <cmd> [--flag v] # ergonomic flags → JSON
//!   invoke --list | --help        # list registered tools (from /etc/invoke-tools.json)
//!
//! The request blob is `name\0args`. The host routes it to the handler registered with `vm.tool()`
//! — embedded (in-process) or served (the callback crosses the WS). For the flags form, the args
//! object is assembled with the real `//lib/json:serde` crate (`Json::Obj` → `to_string`), not a
//! hand-rolled writer — so escaping is correct for every byte (a `\0` in a value becomes `\0`
//! instead of corrupting the `name\0args` split) and integer flags stay integers on the wire. Flag
//! values are type-inferred (`true`/`false` → bool, a strict number → number, else string); the
//! host-side zod schema re-validates. Runs at the inherited (full) tier, so it carries `CAP_NET`. A
//! registered tool is also reachable under its own name: a `/bin/<name>` symlink to `invoke`
//! dispatches on argv[0]. Ported from memcontainers' `mc-tool`.

#![no_std]
#![no_main]

extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;

use json::Json;
use sysroot as rt;

// invoke's tier (full — it carries CAP_NET to reach host tools) is declared in the BUILD (mc_rust_program).

// Allocator — talc, the SAME wasm linear-memory allocator the kernel uses (A8: all state in linear
// memory). `WasmDynamicTalc` grows the wasm heap on demand, so there is no fixed arena to size or
// overflow — uniform with the kernel rather than a bespoke bump. `invoke` needs a heap only to assemble
// the request object with `json` (the old hand-rolled path used an 8 KiB stack buffer).
#[global_allocator]
static ALLOCATOR: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

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

/// Does `v` look like a JSON number (optional `-`, digits, optional fractional part)? Kept stricter
/// than "numeric-ish" — no exponent, no `inf`/`nan` — so a typo like `1e` or `12x` stays a string
/// rather than silently changing type (and the host-side schema can reject it as the wrong shape).
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

/// Coerce a flag value to a JSON value: `true`/`false` → bool, a strict number → number, else a
/// string (UTF-8, lossily — argv is UTF-8 in practice; the json serializer escapes the rest).
fn coerce(v: &[u8]) -> Json {
    if v == b"true" {
        return Json::Bool(true);
    }
    if v == b"false" {
        return Json::Bool(false);
    }
    if looks_numeric(v) {
        if let Ok(s) = core::str::from_utf8(v) {
            if let Ok(n) = s.parse::<f64>() {
                return Json::Num(n);
            }
        }
    }
    Json::Str(String::from_utf8_lossy(v).into_owned())
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

    // Tokenize argv[1..] (NUL-separated). With a real allocator there's no fixed token cap.
    let toks: Vec<&[u8]> = rest.split(|&b| b == 0).filter(|p| !p.is_empty()).collect();

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
            let mut req = Vec::with_capacity(alias.len() + 1 + rest.len());
            req.extend_from_slice(alias);
            req.push(0); // name\0args
            req.extend_from_slice(rest);
            rt::host_call(&req)
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
    // JSON object built from `--flag value` / `--flag=value` / `--bool`, serialized by //lib/json.
    let mut name: Vec<u8> = Vec::new();
    if aliased {
        name.extend_from_slice(alias);
    }
    for t in &toks[..fidx] {
        if !name.is_empty() {
            name.push(b' ');
        }
        name.extend_from_slice(t);
    }

    let mut pairs: Vec<(String, Json)> = Vec::new();
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
        let value = if let Some(v) = inline {
            coerce(v)
        } else if i + 1 < toks.len() && !toks[i + 1].starts_with(b"--") {
            i += 1;
            coerce(toks[i])
        } else {
            Json::Bool(true) // a valueless --flag is a boolean true
        };
        pairs.push((String::from_utf8_lossy(key).into_owned(), value));
        i += 1;
    }

    let args = json::to_string(&Json::Obj(pairs));
    let mut req: Vec<u8> = Vec::with_capacity(name.len() + 1 + args.len());
    req.extend_from_slice(&name);
    req.push(0); // name\0args
    req.extend_from_slice(args.as_bytes());

    match rt::host_call(&req) {
        Ok(fd) => stream(fd),
        Err(_) => fail("invoke: host tools unavailable\n"),
    }
}

rt::entry!(main);
