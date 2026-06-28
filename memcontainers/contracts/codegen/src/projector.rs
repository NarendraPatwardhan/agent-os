//! `projector` — reads one contract (`contracts/*.kdl`) and emits one target
//! language's binding to stdout (SYSTEMS.md). The single tool behind every
//! projection; `abi_library` invokes it once per (module, language) pair.
//!
//! Invocation:  projector --module <m> --lang <l> --contract <path.kdl>
//!   module = constants | mc | env | ctl | wire   (which boundary / schema)
//!   lang   = rust | zig | ts | md | asyncapi | openapi      (which projection)
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

use std::collections::{BTreeMap, BTreeSet};
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
        "asyncapi" | "openapi" => {
            format!("# {line} from contracts/{contract} by //contracts/codegen:projector — do not edit.\n")
        }
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
        "serve-op" | "mount-op" | "persist-op" => "u32",
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
                comment(&mut o, "tier → capability ceiling — the kernel's Tier::caps() consumes this (single source)");
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
            // A standalone STRING constant: `service-marker "--mc-serve"`. The only non-integer constant
            // — projected as a native string per language so the kernel↔guest SERVICE-mode marker has one
            // source instead of four hand-copied literals (codex #5).
            "service-marker" => {
                let cname = n.name.to_uppercase().replace('-', "_");
                let value = n.arg_str(0);
                comment(&mut o, "the argv[1] marker the kernel passes to spawn a binary in SERVICE mode (SYSTEMS.md)");
                match lang {
                    "rust" => o.push_str(&format!("pub const {cname}: &str = \"{value}\";\n")),
                    "zig" => o.push_str(&format!("pub const {cname}: []const u8 = \"{value}\";\n")),
                    "ts" => o.push_str(&format!("export const {cname} = \"{value}\";\n")),
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
    /// feature while the contract still describes the complete ABI. The first of the per-row
    /// metadata the contract carries; the `cap` floor now sits beside it, and a
    /// tracepoint annotation can slot in next.
    cfg: Option<String>,
    /// Optional `cap="CAP_A CAP_B …"` on a syscall row — the capability FLOOR: the
    /// caps any ONE of which a caller's tier must hold to invoke it (a write op lists both
    /// CAP_FS_WRITE and the /scratch-only CAP_SCRATCH). Projected (mc only) to the
    /// `SYSCALL_CAPS` matrix the attestation and /sys/abi read; the kernel's
    /// contextual refinements (open's O_WRITE, per-mount FS caps) sit on top.
    cap: Option<String>,
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
                cap: n.prop_str("cap").map(String::from),
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
            // Capability matrix (mc only): the syscalls that declare a `cap` floor, as
            // (symbol, &[cap-name]). Self-contained — a consumer resolves the names against
            // constants_rust::CAP_* (the kernel cap-gate, the attestation) or renders them
            // (/sys/abi). A syscall absent here requires no capability.
            if rows.iter().any(|r| r.cap.is_some()) {
                o.push_str("\npub const SYSCALL_CAPS: &[(&str, &[&str])] = &[\n");
                for r in rows {
                    if let Some(cap) = &r.cap {
                        let names = cap
                            .split_whitespace()
                            .map(|c| format!("\"{c}\""))
                            .collect::<Vec<_>>()
                            .join(", ");
                        o.push_str(&format!("    (\"{}\", &[{}]),\n", r.name, names));
                    }
                }
                o.push_str("];\n");
            }
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

#[derive(Clone)]
struct QueryParam {
    name: String,
    ty: String,
    required: bool,
}

#[derive(Clone)]
struct Route {
    method: String,
    path: String,
    req: Option<String>,
    res: Option<String>,
    upgrade: Option<String>,
    protocol: Option<String>,
    doc: String,
    queries: Vec<QueryParam>,
}

struct Field {
    name: String,
    ty: String,
    required: bool,
}

struct Schema {
    name: String,
    kind: String,
    doc: String,
    fields: Vec<Field>,
}

fn prop_bool(n: &Node, key: &str, default: bool) -> bool {
    match n.props.get(key) {
        Some(Val::Int(i)) => *i != 0,
        Some(Val::Str(s)) => matches!(s.as_str(), "1" | "true" | "yes"),
        None => default,
    }
}

fn collect_routes(nodes: &[Node]) -> Vec<Route> {
    nodes
        .iter()
        .filter(|n| n.name == "route")
        .map(|n| Route {
            method: n.arg_str(0).to_string(),
            path: n.arg_str(1).to_string(),
            req: n.prop_str("req").map(String::from),
            res: n.prop_str("res").map(String::from),
            upgrade: n.prop_str("upgrade").map(String::from),
            protocol: n.prop_str("protocol").map(String::from),
            doc: n.doc(),
            queries: n
                .children_named("query")
                .map(|q| QueryParam {
                    name: q.arg_str(0).to_string(),
                    ty: q.prop_str("type").unwrap_or("string").to_string(),
                    required: prop_bool(q, "required", false),
                })
                .collect(),
        })
        .collect()
}

fn collect_schemas(nodes: &[Node]) -> Vec<Schema> {
    nodes
        .iter()
        .filter(|n| n.name == "schema")
        .map(|n| Schema {
            name: n.arg_str(0).to_string(),
            kind: n.prop_str("kind").unwrap_or("json").to_string(),
            doc: n.doc(),
            fields: n
                .children_named("field")
                .map(|f| Field {
                    name: f.arg_str(0).to_string(),
                    ty: f.prop_str("type").unwrap_or("string").to_string(),
                    required: prop_bool(f, "required", false),
                })
                .collect(),
        })
        .collect()
}

fn yaml_quote(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn path_params(path: &str) -> Vec<String> {
    let mut params = Vec::new();
    let mut rest = path;
    while let Some(start) = rest.find('{') {
        rest = &rest[start + 1..];
        let Some(end) = rest.find('}') else {
            break;
        };
        let name = &rest[..end];
        if !params.iter().any(|p| p == name) {
            params.push(name.to_string());
        }
        rest = &rest[end + 1..];
    }
    params
}

fn operation_id(method: &str, path: &str) -> String {
    let raw = format!("{}_{}", method.to_ascii_lowercase(), path.trim_matches('/'));
    let mut out = String::new();
    let mut last_underscore = false;
    for c in raw.chars() {
        let mapped = if c.is_ascii_alphanumeric() { c } else { '_' };
        if mapped == '_' {
            if !last_underscore {
                out.push(mapped);
            }
            last_underscore = true;
        } else {
            out.push(mapped);
            last_underscore = false;
        }
    }
    out.trim_matches('_').to_string()
}

fn schema_kind<'a>(schemas: &'a BTreeMap<String, String>, name: &str) -> &'a str {
    schemas.get(name).map(String::as_str).unwrap_or("json")
}

fn media_type(name: &str, kind: &str) -> &'static str {
    match kind {
        "binary" if name == "LayerTar" => "application/x-tar",
        "binary" => "application/octet-stream",
        _ => "application/json",
    }
}

fn emit_openapi_schema_for_type(out: &mut String, ty: &str, indent: usize, schema_names: &BTreeSet<String>) {
    let pad = " ".repeat(indent);
    if let Some(inner) = ty.strip_suffix("[]") {
        out.push_str(&format!("{pad}type: array\n"));
        out.push_str(&format!("{pad}items:\n"));
        emit_openapi_schema_for_type(out, inner, indent + 2, schema_names);
        return;
    }

    if schema_names.contains(ty) {
        out.push_str(&format!("{pad}$ref: \"#/components/schemas/{ty}\"\n"));
        return;
    }

    match ty {
        "bool" => out.push_str(&format!("{pad}type: boolean\n")),
        "u32" | "i32" => {
            out.push_str(&format!("{pad}type: integer\n"));
            out.push_str(&format!("{pad}format: int32\n"));
        }
        "u64" | "i64" => {
            out.push_str(&format!("{pad}type: integer\n"));
            out.push_str(&format!("{pad}format: int64\n"));
        }
        "StringMap" => {
            out.push_str(&format!("{pad}type: object\n"));
            out.push_str(&format!("{pad}additionalProperties:\n"));
            out.push_str(&format!("{pad}  type: string\n"));
        }
        "object" => out.push_str(&format!("{pad}type: object\n")),
        "string" => out.push_str(&format!("{pad}type: string\n")),
        alias => {
            out.push_str(&format!("{pad}type: string\n"));
            out.push_str(&format!("{pad}x-agentos-type: {}\n", yaml_quote(alias)));
        }
    }
}

fn emit_content(
    out: &mut String,
    schema_name: &str,
    indent: usize,
    schema_names: &BTreeSet<String>,
    schema_kinds: &BTreeMap<String, String>,
) {
    let pad = " ".repeat(indent);
    let kind = schema_kind(schema_kinds, schema_name);
    out.push_str(&format!("{pad}content:\n"));
    out.push_str(&format!("{pad}  {}:\n", media_type(schema_name, kind)));
    out.push_str(&format!("{pad}    schema:\n"));
    emit_openapi_schema_for_type(out, schema_name, indent + 6, schema_names);
}

fn emit_parameters(out: &mut String, route: &Route, schema_names: &BTreeSet<String>) {
    let params = path_params(&route.path);
    if params.is_empty() && route.queries.is_empty() {
        return;
    }
    out.push_str("      parameters:\n");
    for param in params {
        out.push_str(&format!("        - name: {}\n", yaml_quote(&param)));
        out.push_str("          in: path\n");
        out.push_str("          required: true\n");
        out.push_str("          schema:\n");
        emit_openapi_schema_for_type(out, "string", 12, schema_names);
    }
    for query in &route.queries {
        out.push_str(&format!("        - name: {}\n", yaml_quote(&query.name)));
        out.push_str("          in: query\n");
        out.push_str(&format!("          required: {}\n", if query.required { "true" } else { "false" }));
        out.push_str("          schema:\n");
        emit_openapi_schema_for_type(out, &query.ty, 12, schema_names);
    }
}

fn emit_openapi(nodes: &[Node], contract: &str) -> String {
    let version = nodes
        .iter()
        .find(|n| n.name == "version")
        .map(|n| n.args.first().map(Val::as_int).unwrap_or(0))
        .unwrap_or(0);
    let routes = collect_routes(nodes);
    let schemas = collect_schemas(nodes);
    let schema_names: BTreeSet<String> = schemas.iter().map(|s| s.name.clone()).collect();
    let schema_kinds: BTreeMap<String, String> = schemas.iter().map(|s| (s.name.clone(), s.kind.clone())).collect();
    let mut paths: Vec<String> = Vec::new();
    let mut grouped: BTreeMap<String, Vec<Route>> = BTreeMap::new();
    for route in routes {
        if !grouped.contains_key(&route.path) {
            paths.push(route.path.clone());
        }
        grouped.entry(route.path.clone()).or_default().push(route);
    }

    let mut out = banner("openapi", contract);
    out.push_str("openapi: 3.0.3\n");
    out.push_str("info:\n");
    out.push_str("  title: AgentOS REST API\n");
    out.push_str(&format!("  version: {}\n", yaml_quote(&version.to_string())));
    out.push_str("  description: \"Request/response API for AgentOS VM lifecycle, exec, filesystem, snapshots, layers, and mounts. Live terminal, relay, permissions, and streamed sessions use the typed WebSocket in asyncapi.yaml.\"\n");
    out.push_str("security:\n");
    out.push_str("  - bearerAuth: []\n");
    out.push_str("paths:\n");
    if paths.is_empty() {
        out.push_str("  {}\n");
    }
    for path in paths {
        out.push_str(&format!("  {}:\n", yaml_quote(&path)));
        for route in grouped.get(&path).into_iter().flatten() {
            let method = route.method.to_ascii_lowercase();
            out.push_str(&format!("    {method}:\n"));
            out.push_str(&format!("      operationId: {}\n", yaml_quote(&operation_id(&route.method, &route.path))));
            if !route.doc.is_empty() {
                out.push_str(&format!("      summary: {}\n", yaml_quote(&route.doc)));
            }
            if let Some(protocol) = &route.protocol {
                out.push_str(&format!("      x-agentos-protocol: {}\n", yaml_quote(protocol)));
            }
            if route.upgrade.as_deref() == Some("websocket") {
                out.push_str("      x-agentos-upgrade: websocket\n");
            }
            if path == "/healthz" {
                out.push_str("      security: []\n");
            }
            emit_parameters(&mut out, route, &schema_names);
            if let Some(req) = &route.req {
                out.push_str("      requestBody:\n");
                out.push_str("        required: true\n");
                emit_content(&mut out, req, 8, &schema_names, &schema_kinds);
            }
            out.push_str("      responses:\n");
            let status = if route.upgrade.as_deref() == Some("websocket") {
                "101"
            } else {
                "200"
            };
            out.push_str(&format!("        {status:?}:\n"));
            let description = if status == "101" { "Switching protocols" } else { "OK" };
            out.push_str(&format!("          description: {}\n", yaml_quote(description)));
            if status != "101" {
                if let Some(res) = &route.res {
                    emit_content(&mut out, res, 10, &schema_names, &schema_kinds);
                }
            }
        }
    }
    out.push_str("components:\n");
    out.push_str("  securitySchemes:\n");
    out.push_str("    bearerAuth:\n");
    out.push_str("      type: http\n");
    out.push_str("      scheme: bearer\n");
    out.push_str("  schemas:\n");
    for schema in &schemas {
        out.push_str(&format!("    {}:\n", yaml_quote(&schema.name)));
        if !schema.doc.is_empty() {
            out.push_str(&format!("      description: {}\n", yaml_quote(&schema.doc)));
        }
        match schema.kind.as_str() {
            "binary" => {
                out.push_str("      type: string\n");
                out.push_str("      format: binary\n");
            }
            "websocket" => {
                out.push_str("      type: string\n");
                out.push_str("      x-agentos-protocol: wire\n");
            }
            _ => {
                out.push_str("      type: object\n");
                let required = schema.fields.iter().filter(|f| f.required).collect::<Vec<_>>();
                if !required.is_empty() {
                    out.push_str("      required:\n");
                    for field in required {
                        out.push_str(&format!("        - {}\n", yaml_quote(&field.name)));
                    }
                }
                out.push_str("      properties:\n");
                if schema.fields.is_empty() {
                    out.push_str("        {}\n");
                }
                for field in &schema.fields {
                    out.push_str(&format!("        {}:\n", yaml_quote(&field.name)));
                    emit_openapi_schema_for_type(&mut out, &field.ty, 10, &schema_names);
                }
            }
        }
    }
    out
}

fn emit_wire(lang: &str, nodes: &[Node], contract: &str) -> String {
    if lang == "openapi" {
        return emit_openapi(nodes, contract);
    }
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
            o.push_str("info:\n  title: AgentOS wire protocol\n");
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
        eprintln!("usage: projector --module <constants|mc|env|ctl|wire> --lang <rust|zig|ts|md|asyncapi|openapi> --contract <path.kdl>");
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
