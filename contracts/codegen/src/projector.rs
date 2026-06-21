//! `projector` — reads one contract (`contracts/*.kdl`) and emits one target
//! language's binding to stdout (VISION §6.2). The single tool behind every
//! projection; `abi_library` invokes it once per (module, language) pair.
//!
//! Invocation:  projector --module <m> --lang <l> --contract <path.kdl>
//!   module = constants | mc | env | ctl | wire   (which boundary / schema)
//!   lang   = rust | zig | ts | md | asyncapi      (which projection)
//!
//! Design (why this shape — C1):
//!   - DETERMINISM (A7/B2): same inputs → byte-identical output. No clock, no env,
//!     file-order iteration. The drift gate (write_source_files + diff_test) only
//!     works if output is reproducible.
//!   - ONE PARSER, MANY EMITTERS: parse the .kdl into a tiny node model, then walk it
//!     per language. Adding a language is a new emitter, never a new parser.
//!   - HOST-COMPILABLE RUST: every boundary projects to Rust as a `macro_rules!`
//!     callback table (memcontainers' proven `mc_syscall_table!` pattern, generalized
//!     to all four boundaries) plus plain `const`s — never a concrete `extern` block.
//!     The kernel/host/sysroot supply the `$emit` that turns the table into their
//!     half, so the generated file carries NO wasm-only attributes and validates by a
//!     normal host build (B2: no hand-written ABI on either side).
//!   - DEPENDENCY-LIGHT: no external crates, so the projector needs no crate_universe
//!     and stays cheap on the build's critical path.

use std::collections::BTreeMap;
use std::process::ExitCode;

// ===========================================================================
// KDL model + reader (a minimal subset tailored to contracts/*.kdl)
// ===========================================================================

#[derive(Debug, Clone)]
enum Val {
    Int(i64),
    Str(String),
}

impl Val {
    fn as_int(&self) -> i64 {
        match self {
            Val::Int(i) => *i,
            Val::Str(s) => s.parse().unwrap_or(0),
        }
    }
    fn as_str(&self) -> &str {
        match self {
            Val::Str(s) => s,
            Val::Int(_) => "",
        }
    }
}

#[derive(Debug, Clone)]
struct Node {
    name: String,
    args: Vec<Val>,
    props: BTreeMap<String, Val>,
    children: Vec<Node>,
}

impl Node {
    fn arg_str(&self, i: usize) -> &str {
        self.args.get(i).map(Val::as_str).unwrap_or("")
    }
    fn prop_str(&self, k: &str) -> Option<&str> {
        self.props.get(k).map(Val::as_str)
    }
    fn child(&self, name: &str) -> Option<&Node> {
        self.children.iter().find(|c| c.name == name)
    }
    fn children_named<'a>(&'a self, name: &'static str) -> impl Iterator<Item = &'a Node> {
        self.children.iter().filter(move |c| c.name == name)
    }
    /// `ret` appears two ways in the contracts: a property (`ret="noreturn"`, syscalls)
    /// or a child node (`ret "i32"`, bridge/control). Read both.
    fn ret_type(&self) -> Option<String> {
        if let Some(v) = self.prop_str("ret") {
            return Some(v.to_string());
        }
        self.child("ret").map(|c| c.arg_str(0).to_string())
    }
    fn doc(&self) -> String {
        sanitize(self.child("doc").map(|c| c.arg_str(0)).unwrap_or(""))
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Ident(String),
    Str(String),
    Int(i64),
    LBrace,
    RBrace,
    Eq,
    Semi,
    Newline,
}

/// Tokenize the KDL subset. Handles `//` and `/* */` comments, `"..."` strings with
/// backslash escapes, decimal/hex/negative integers, and `-` inside identifiers.
fn tokenize(src: &str) -> Vec<Tok> {
    let b = src.as_bytes();
    let mut i = 0;
    let mut out = Vec::new();
    let is_ident_start = |c: u8| c.is_ascii_alphabetic() || c == b'_';
    let is_ident_cont = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c == b'-';
    while i < b.len() {
        let c = b[i];
        match c {
            b' ' | b'\t' | b'\r' => i += 1,
            b'\n' => {
                out.push(Tok::Newline);
                i += 1;
            }
            b'{' => {
                out.push(Tok::LBrace);
                i += 1;
            }
            b'}' => {
                out.push(Tok::RBrace);
                i += 1;
            }
            b'=' => {
                out.push(Tok::Eq);
                i += 1;
            }
            b';' => {
                out.push(Tok::Semi);
                i += 1;
            }
            b'/' if i + 1 < b.len() && b[i + 1] == b'/' => {
                while i < b.len() && b[i] != b'\n' {
                    i += 1;
                }
            }
            b'/' if i + 1 < b.len() && b[i + 1] == b'*' => {
                i += 2;
                while i + 1 < b.len() && !(b[i] == b'*' && b[i + 1] == b'/') {
                    i += 1;
                }
                i += 2;
            }
            b'"' => {
                i += 1;
                let mut s = String::new();
                while i < b.len() && b[i] != b'"' {
                    if b[i] == b'\\' && i + 1 < b.len() {
                        // Escape: keep it textual (we emit docs into comments). Map the
                        // common ones; pass anything else through as the literal char.
                        let e = b[i + 1];
                        s.push(match e {
                            b'n' => '\n',
                            b't' => '\t',
                            b'r' => '\r',
                            _ => e as char,
                        });
                        i += 2;
                    } else {
                        s.push(b[i] as char);
                        i += 1;
                    }
                }
                i += 1; // closing quote
                out.push(Tok::Str(s));
            }
            b'-' if i + 1 < b.len() && b[i + 1].is_ascii_digit() => {
                let start = i;
                i += 1;
                while i < b.len() && (b[i].is_ascii_digit() || b[i] == b'x' || b[i].is_ascii_hexdigit()) {
                    i += 1;
                }
                out.push(Tok::Int(parse_int(&src[start..i])));
            }
            _ if c.is_ascii_digit() => {
                let start = i;
                if c == b'0' && i + 1 < b.len() && b[i + 1] == b'x' {
                    i += 2;
                    while i < b.len() && b[i].is_ascii_hexdigit() {
                        i += 1;
                    }
                } else {
                    while i < b.len() && b[i].is_ascii_digit() {
                        i += 1;
                    }
                }
                out.push(Tok::Int(parse_int(&src[start..i])));
            }
            _ if is_ident_start(c) => {
                let start = i;
                while i < b.len() && is_ident_cont(b[i]) {
                    i += 1;
                }
                out.push(Tok::Ident(src[start..i].to_string()));
            }
            _ => i += 1, // skip anything unexpected
        }
    }
    out
}

fn parse_int(s: &str) -> i64 {
    let s = s.trim();
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        i64::from_str_radix(hex, 16).unwrap_or(0)
    } else {
        s.parse().unwrap_or(0)
    }
}

/// Recursive-descent parse into top-level nodes.
fn parse(toks: &[Tok]) -> Vec<Node> {
    let mut p = 0;
    parse_nodes(toks, &mut p, false)
}

fn parse_nodes(toks: &[Tok], p: &mut usize, in_block: bool) -> Vec<Node> {
    let mut nodes = Vec::new();
    while *p < toks.len() {
        match &toks[*p] {
            Tok::Newline | Tok::Semi => {
                *p += 1;
            }
            Tok::RBrace => {
                if in_block {
                    return nodes;
                }
                *p += 1;
            }
            Tok::Ident(name) => {
                let name = name.clone();
                *p += 1;
                nodes.push(parse_node_body(toks, p, name));
            }
            _ => {
                *p += 1;
            }
        }
    }
    nodes
}

fn parse_node_body(toks: &[Tok], p: &mut usize, name: String) -> Node {
    let mut node = Node {
        name,
        args: Vec::new(),
        props: BTreeMap::new(),
        children: Vec::new(),
    };
    while *p < toks.len() {
        match &toks[*p] {
            Tok::Str(s) => {
                node.args.push(Val::Str(s.clone()));
                *p += 1;
            }
            Tok::Int(n) => {
                node.args.push(Val::Int(*n));
                *p += 1;
            }
            Tok::Ident(key) => {
                // A property `key=value`, or (never, in our files) a bare-ident arg.
                let key = key.clone();
                *p += 1;
                if *p < toks.len() && toks[*p] == Tok::Eq {
                    *p += 1;
                    let v = match toks.get(*p) {
                        Some(Tok::Str(s)) => Val::Str(s.clone()),
                        Some(Tok::Int(n)) => Val::Int(*n),
                        _ => Val::Str(String::new()),
                    };
                    *p += 1;
                    node.props.insert(key, v);
                } else {
                    node.args.push(Val::Str(key));
                }
            }
            Tok::LBrace => {
                *p += 1;
                node.children = parse_nodes(toks, p, true);
                if *p < toks.len() && toks[*p] == Tok::RBrace {
                    *p += 1;
                }
                break; // children close the node
            }
            Tok::Semi | Tok::Newline | Tok::RBrace => break,
            Tok::Eq => {
                *p += 1;
            }
        }
    }
    node
}

// ===========================================================================
// Shared emit helpers
// ===========================================================================

/// Collapse whitespace and strip control chars so a doc fits on one comment line.
fn sanitize(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn banner(lang: &str, contract: &str) -> String {
    let line = "@generated";
    let comment =
        format!("// {line} from contracts/{contract} by //contracts/codegen:projector — do not edit.\n");
    match lang {
        "asyncapi" => format!("# {line} from contracts/{contract} by //contracts/codegen:projector — do not edit.\n"),
        // Rust projections are `no_std`: just consts/macros, usable by the no_std kernel
        // AND std hosts. Without this a std dependency would drag std's lang items
        // (panic_impl) into the kernel cdylib and collide with its `#[panic_handler]`.
        "rust" => format!("{comment}#![no_std]\n"),
        _ => comment,
    }
}

/// Rust/Zig integer type for a constants group (faithful to memcontainers types).
fn const_ty(group: &str) -> &'static str {
    match group {
        "capability" => "u8", // the policy bitset packs into one byte (eight bits)
        "serve-op" | "mount-op" => "u32",
        "wire-version" => "u32",
        "abi-version" => "i64",
        _ => "i32",
    }
}

fn ts_num(v: i64) -> String {
    v.to_string()
}

// ===========================================================================
// Module emitters
// ===========================================================================

fn emit_constants(lang: &str, nodes: &[Node], contract: &str) -> String {
    let mut o = banner(lang, contract);
    let comment = |o: &mut String, text: &str| match lang {
        _ => o.push_str(&format!("\n// {text}\n")),
    };
    for n in nodes {
        match n.name.as_str() {
            "abi-version" => {
                let major = n.props.get("major").map(Val::as_int).unwrap_or(0);
                let minor = n.props.get("minor").map(Val::as_int).unwrap_or(0);
                comment(&mut o, "syscall ABI version: (major << 16) | minor");
                match lang {
                    "rust" => o.push_str(&format!(
                        "pub const SYS_ABI_MAJOR: i64 = {major};\npub const SYS_ABI_MINOR: i64 = {minor};\npub const fn abi_version() -> i64 {{ (SYS_ABI_MAJOR << 16) | SYS_ABI_MINOR }}\n"
                    )),
                    "zig" => o.push_str(&format!(
                        "pub const SYS_ABI_MAJOR: i64 = {major};\npub const SYS_ABI_MINOR: i64 = {minor};\npub fn abi_version() i64 {{ return (SYS_ABI_MAJOR << 16) | SYS_ABI_MINOR; }}\n"
                    )),
                    "ts" => o.push_str(&format!(
                        "export const SYS_ABI_MAJOR = {major};\nexport const SYS_ABI_MINOR = {minor};\nexport function abiVersion(): number {{ return (SYS_ABI_MAJOR << 16) | SYS_ABI_MINOR; }}\n"
                    )),
                    _ => {}
                }
            }
            "wire-version" => {
                let v = n.arg_str(0).parse::<i64>().unwrap_or_else(|_| n.args.first().map(Val::as_int).unwrap_or(0));
                match lang {
                    "rust" => o.push_str(&format!("pub const WIRE_VERSION: u32 = {v};\n")),
                    "zig" => o.push_str(&format!("pub const WIRE_VERSION: u32 = {v};\n")),
                    "ts" => o.push_str(&format!("export const WIRE_VERSION = {v};\n")),
                    _ => {}
                }
            }
            // tier → capability ceiling: each child is `TIER_X "CAP_A CAP_B …"`; emit a
            // resolver that ORs the named cap bits (the CAP_* consts emitted above), so the
            // kernel's Tier::caps() derives from this one place and both kernels agree.
            "tier-caps" => {
                comment(&mut o, "tier → capability ceiling — the kernel's Tier::caps() consumes this (single source, §16 / §15.4)");
                let arms: Vec<(String, String)> = n
                    .children
                    .iter()
                    .map(|c| {
                        let names = c.arg_str(0);
                        let expr = if names.trim().is_empty() {
                            "0".to_string()
                        } else {
                            names.split_whitespace().collect::<Vec<_>>().join(" | ")
                        };
                        (c.name.clone(), expr)
                    })
                    .collect();
                match lang {
                    "rust" => {
                        // `tier` is matched against the TIER_* consts, which are emitted i32
                        // (const_ty's default) — so the scrutinee is i32, not i64, else the
                        // match arms type-mismatch (E0308).
                        o.push_str("pub const fn tier_caps(tier: i32) -> u8 {\n    match tier {\n");
                        for (name, expr) in &arms {
                            o.push_str(&format!("        {name} => {expr},\n"));
                        }
                        o.push_str("        _ => 0,\n    }\n}\n");
                    }
                    "zig" => {
                        // Match the Rust projection: TIER_* consts are i32, so is the param.
                        o.push_str("pub fn tier_caps(tier: i32) u8 {\n    return switch (tier) {\n");
                        for (name, expr) in &arms {
                            o.push_str(&format!("        {name} => {expr},\n"));
                        }
                        o.push_str("        else => 0,\n    };\n}\n");
                    }
                    "ts" => {
                        o.push_str("export function tierCaps(tier: number): number {\n  switch (tier) {\n");
                        for (name, expr) in &arms {
                            o.push_str(&format!("    case {name}: return {expr};\n"));
                        }
                        o.push_str("    default: return 0;\n  }\n}\n");
                    }
                    _ => {}
                }
            }
            // grouping nodes: errno, tier, open-flags, seek, waitpid, poll, signal, serve-op, mount-op
            g if !n.children.is_empty() => {
                let ty = const_ty(g);
                comment(&mut o, g);
                for c in &n.children {
                    let name = &c.name;
                    let v = c.args.first().map(Val::as_int).unwrap_or(0);
                    match lang {
                        "rust" => o.push_str(&format!("pub const {name}: {ty} = {v};\n")),
                        "zig" => o.push_str(&format!("pub const {name}: {ty} = {v};\n")),
                        "ts" => o.push_str(&format!("export const {name} = {};\n", ts_num(v))),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    o
}

/// A row of a "table" boundary (syscall / import / export): name + typed args + ret.
struct Row {
    name: String,
    variant: String,
    args: Vec<(String, String)>, // (name, type)
    ret: String,
    doc: String,
    /// Optional `cfg="<feature>"` on the row — projected as a Rust `#[cfg(feature=…)]`
    /// the consumer's `$emit` applies to its generated item, so a build flavor's
    /// exports/handlers (e.g. the threads-only control exports) generate ONLY under that
    /// feature while the contract still describes the complete ABI. This is the first of
    /// the per-row metadata the contract carries; capability (§15.4) and tracepoint
    /// (§15.3) annotations slot in beside it next, while the contract is still soft.
    cfg: Option<String>,
}

fn collect_rows(nodes: &[Node], node_name: &str) -> Vec<Row> {
    nodes
        .iter()
        .filter(|n| n.name == node_name)
        .map(|n| {
            let name = n.arg_str(0).to_string();
            let variant = n
                .prop_str("variant")
                .map(|s| s.to_string())
                .unwrap_or_else(|| to_variant(&name));
            let args = n
                .children_named("arg")
                .map(|a| (a.arg_str(0).to_string(), a.prop_str("type").unwrap_or("i32").to_string()))
                .collect();
            Row {
                name,
                variant,
                args,
                ret: n.ret_type().unwrap_or_else(|| "i32".to_string()),
                doc: n.doc(),
                cfg: n.prop_str("cfg").map(String::from),
            }
        })
        .collect()
}

/// Fallback PascalCase variant from a symbol (e.g. mc_stdout_write → StdoutWrite),
/// used for the bridge/control boundaries which don't carry an explicit `variant`.
fn to_variant(sym: &str) -> String {
    let stem = sym
        .strip_prefix("mc_sys_")
        .or_else(|| sym.strip_prefix("mc_ctl_"))
        .or_else(|| sym.strip_prefix("mc_"))
        .unwrap_or(sym);
    stem.split('_')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let mut c = p.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect()
}

/// Emit a table boundary (mc / env / ctl) for one language. `macro_name` is the Rust
/// callback macro; `names_const` is the `&[&str]` symbol array.
fn emit_table(lang: &str, contract: &str, rows: &[Row], macro_name: &str, names_const: &str, table_const: &str) -> String {
    let mut o = banner(lang, contract);
    match lang {
        "rust" => {
            o.push_str(&format!("\npub const {names_const}: &[&str] = &[\n"));
            for r in rows {
                o.push_str(&format!("    \"{}\",\n", r.name));
            }
            o.push_str("];\n\n");
            o.push_str("/// The canonical table. A consumer hands its own `$emit!` callback (the kernel's\n");
            o.push_str("/// dispatch, the sysroot's extern block, the host's import table) and cannot drift.\n");
            o.push_str("#[macro_export]\n");
            o.push_str(&format!("macro_rules! {macro_name} {{\n    ($emit:path) => {{ $emit! {{\n"));
            for r in rows {
                let args = r
                    .args
                    .iter()
                    .map(|(n, t)| format!("{n}: {t}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                // Per-row metadata → a Rust attribute the consumer's `$emit` applies to
                // its generated item (only rows that carry the property change, so the
                // mc/env macros are untouched).
                let attr = match &r.cfg {
                    Some(f) => format!("#[cfg(feature = \"{f}\")] "),
                    None => String::new(),
                };
                o.push_str(&format!(
                    "        {}{} => {} ({}) [{}];\n",
                    attr, r.name, r.variant, args, r.ret
                ));
            }
            o.push_str("    } };\n}\n");
        }
        "zig" => {
            o.push_str("\npub const Arg = struct { name: []const u8, ty: []const u8 };\n");
            o.push_str("pub const Desc = struct { name: []const u8, variant: []const u8, args: []const Arg, ret: []const u8 };\n\n");
            o.push_str(&format!("pub const {table_const} = [_]Desc{{\n"));
            for r in rows {
                let args = r
                    .args
                    .iter()
                    .map(|(n, t)| format!(".{{ .name = \"{n}\", .ty = \"{t}\" }}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                o.push_str(&format!(
                    "    .{{ .name = \"{}\", .variant = \"{}\", .args = &.{{ {} }}, .ret = \"{}\" }},\n",
                    r.name, r.variant, args, r.ret
                ));
            }
            o.push_str("};\n");
        }
        "ts" => {
            o.push_str(&format!("\nexport const {names_const} = [\n"));
            for r in rows {
                o.push_str(&format!("  \"{}\",\n", r.name));
            }
            o.push_str("] as const;\n\n");
            o.push_str(&format!("export const {table_const} = [\n"));
            for r in rows {
                let args = r
                    .args
                    .iter()
                    .map(|(n, t)| format!("{{ name: \"{n}\", type: \"{t}\" }}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                o.push_str(&format!(
                    "  {{ name: \"{}\", variant: \"{}\", args: [{}], ret: \"{}\" }},\n",
                    r.name, r.variant, args, r.ret
                ));
            }
            o.push_str("] as const;\n");
        }
        "md" => {
            o = format!("<!-- {} -->\n", banner("md", contract).trim_start_matches("// "));
            o.push_str(&format!("\n# `{}` — generated reference\n\n", macro_name));
            o.push_str("| # | symbol | variant | args | ret | doc |\n|---|---|---|---|---|---|\n");
            for (i, r) in rows.iter().enumerate() {
                let args = r
                    .args
                    .iter()
                    .map(|(n, t)| format!("{n}: {t}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                o.push_str(&format!(
                    "| {} | `{}` | {} | {} | {} | {} |\n",
                    i + 1,
                    r.name,
                    r.variant,
                    args,
                    r.ret,
                    r.doc
                ));
            }
        }
        _ => {}
    }
    o
}

fn emit_wire(lang: &str, nodes: &[Node], contract: &str) -> String {
    let version = nodes.iter().find(|n| n.name == "version").map(|n| n.args.first().map(Val::as_int).unwrap_or(0)).unwrap_or(0);
    let header_len = nodes.iter().find(|n| n.name == "header-len").map(|n| n.args.first().map(Val::as_int).unwrap_or(0)).unwrap_or(0);
    let msgs: Vec<&Node> = nodes.iter().filter(|n| n.name == "message").collect();
    let mut o = banner(lang, contract);
    match lang {
        "rust" => {
            o.push_str(&format!("\npub const WIRE_VERSION: u32 = {version};\npub const HEADER_LEN: usize = {header_len};\n\n"));
            for m in &msgs {
                let tag = m.props.get("tag").map(Val::as_int).unwrap_or(0);
                o.push_str(&format!("pub const {}: u8 = 0x{:02x};\n", m.arg_str(0), tag));
            }
            o.push_str("\npub struct WireMessage { pub name: &'static str, pub tag: u8, pub dir: &'static str, pub body: &'static str }\n");
            o.push_str("pub const MESSAGES: &[WireMessage] = &[\n");
            for m in &msgs {
                let tag = m.props.get("tag").map(Val::as_int).unwrap_or(0);
                o.push_str(&format!(
                    "    WireMessage {{ name: \"{}\", tag: 0x{:02x}, dir: \"{}\", body: \"{}\" }},\n",
                    m.arg_str(0), tag, m.prop_str("dir").unwrap_or(""), m.prop_str("body").unwrap_or("")
                ));
            }
            o.push_str("];\n");
        }
        "ts" => {
            o.push_str(&format!("\nexport const WIRE_VERSION = {version};\nexport const HEADER_LEN = {header_len};\n\n"));
            for m in &msgs {
                let tag = m.props.get("tag").map(Val::as_int).unwrap_or(0);
                o.push_str(&format!("export const {} = 0x{:02x};\n", m.arg_str(0), tag));
            }
            o.push_str("\nexport const MESSAGES = [\n");
            for m in &msgs {
                let tag = m.props.get("tag").map(Val::as_int).unwrap_or(0);
                o.push_str(&format!(
                    "  {{ name: \"{}\", tag: 0x{:02x}, dir: \"{}\", body: \"{}\" }},\n",
                    m.arg_str(0), tag, m.prop_str("dir").unwrap_or(""), m.prop_str("body").unwrap_or("")
                ));
            }
            o.push_str("] as const;\n");
        }
        "asyncapi" => {
            o = banner("asyncapi", contract);
            o.push_str("asyncapi: 3.0.0\n");
            o.push_str("info:\n  title: mc wire protocol\n");
            o.push_str(&format!("  version: \"{version}\"\n"));
            o.push_str("channels:\n  vm:\n    messages:\n");
            for m in &msgs {
                o.push_str(&format!("      {}:\n", m.arg_str(0)));
                o.push_str(&format!("        x-tag: {}\n", m.props.get("tag").map(Val::as_int).unwrap_or(0)));
                o.push_str(&format!("        x-direction: \"{}\"\n", m.prop_str("dir").unwrap_or("")));
                o.push_str(&format!("        x-body: \"{}\"\n", m.prop_str("body").unwrap_or("")));
                o.push_str(&format!("        summary: \"{}\"\n", m.doc()));
            }
        }
        _ => {}
    }
    o
}

// ===========================================================================
// main
// ===========================================================================

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let (mut lang, mut module, mut contract) = (None, None, None);
    let mut i = 1;
    while i + 1 < args.len() {
        match args[i].as_str() {
            "--lang" => lang = Some(args[i + 1].clone()),
            "--module" => module = Some(args[i + 1].clone()),
            "--contract" => contract = Some(args[i + 1].clone()),
            _ => {}
        }
        i += 2;
    }
    let (Some(lang), Some(module), Some(contract)) = (lang, module, contract) else {
        eprintln!("usage: projector --module <constants|mc|env|ctl|wire> --lang <rust|zig|ts|md|asyncapi> --contract <path.kdl>");
        return ExitCode::FAILURE;
    };

    let src = match std::fs::read_to_string(&contract) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("projector: cannot read {contract}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let file = std::path::Path::new(&contract)
        .file_name()
        .map(|f| f.to_string_lossy().into_owned())
        .unwrap_or_else(|| contract.clone());
    let nodes = parse(&tokenize(&src));

    let out = match module.as_str() {
        "constants" => emit_constants(&lang, &nodes, &file),
        "mc" => emit_table(&lang, &file, &collect_rows(&nodes, "syscall"), "mc_syscall_table", "SYSCALL_NAMES", "SYSCALLS"),
        "env" => emit_table(&lang, &file, &collect_rows(&nodes, "import"), "mc_bridge_table", "BRIDGE_IMPORTS", "IMPORTS"),
        "ctl" => emit_table(&lang, &file, &collect_rows(&nodes, "export"), "mc_control_table", "CONTROL_EXPORTS", "EXPORTS"),
        "wire" => emit_wire(&lang, &nodes, &file),
        other => {
            eprintln!("projector: unknown module {other}");
            return ExitCode::FAILURE;
        }
    };

    print!("{out}");
    ExitCode::SUCCESS
}
