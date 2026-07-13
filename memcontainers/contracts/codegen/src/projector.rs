//! `projector` — reads one contract (`contracts/*.kdl`) and emits one target
//! language's binding to stdout (SYSTEMS.md). The single tool behind every
//! projection; `abi_library` invokes it once per (module, language) pair.
//!
//! Invocation:  projector --module <m> --lang <l> --contract <path.kdl>
//!   module = constants | mc | env | ctl | wire   (which boundary / schema)
//!   lang   = rust | zig | ts | elixir | md | asyncapi | openapi      (which projection)
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

use std::collections::{BTreeMap, BTreeSet, HashMap};
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
                while i < b.len()
                    && (b[i].is_ascii_digit() || b[i] == b'x' || b[i].is_ascii_hexdigit())
                {
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
    let comment = format!(
        "// {line} from contracts/{contract} by //contracts/codegen:projector — do not edit.\n"
    );
    match lang {
        "asyncapi" | "openapi" | "elixir" => {
            format!(
                "# {line} from contracts/{contract} by //contracts/codegen:projector — do not edit.\n"
            )
        }
        "luau" => format!(
            "-- {line} from contracts/{contract} by //contracts/codegen:projector — do not edit.\n"
        ),
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
        "elixir" => o.push_str(&format!("\n  # {text}\n")),
        "luau" => o.push_str(&format!("\n-- {text}\n")),
        _ => o.push_str(&format!("\n// {text}\n")),
    };
    let const_values: HashMap<String, i64> = nodes
        .iter()
        .filter(|n| n.name != "tier-caps")
        .flat_map(|n| {
            n.children
                .iter()
                .map(|c| (c.name.clone(), c.args.first().map(Val::as_int).unwrap_or(0)))
        })
        .collect();

    if lang == "elixir" {
        o.push_str(&format!("defmodule {} do\n", elixir_module_name(contract)));
    } else if lang == "luau" {
        o.push_str("local M = {}\n");
    }

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
                    "elixir" => {
                        let version = (major << 16) | minor;
                        o.push_str(&format!(
                            "  def sys_abi_major, do: {major}\n  def sys_abi_minor, do: {minor}\n  def abi_version, do: {version}\n"
                        ))
                    }
                    "luau" => o.push_str(&format!(
                        "M.SYS_ABI_MAJOR = {major}\nM.SYS_ABI_MINOR = {minor}\nM.abi_version = function() return M.SYS_ABI_MAJOR * 65536 + M.SYS_ABI_MINOR end\n"
                    )),
                    _ => {}
                }
            }
            "wire-version" => {
                let v = n
                    .arg_str(0)
                    .parse::<i64>()
                    .unwrap_or_else(|_| n.args.first().map(Val::as_int).unwrap_or(0));
                match lang {
                    "rust" => o.push_str(&format!("pub const WIRE_VERSION: u32 = {v};\n")),
                    "zig" => o.push_str(&format!("pub const WIRE_VERSION: u32 = {v};\n")),
                    "ts" => o.push_str(&format!("export const WIRE_VERSION = {v};\n")),
                    "elixir" => o.push_str(&format!("  def wire_version, do: {v}\n")),
                    "luau" => o.push_str(&format!("M.WIRE_VERSION = {v}\n")),
                    _ => {}
                }
            }
            // tier → capability ceiling: each child is `TIER_X "CAP_A CAP_B …"`; emit a
            // resolver that ORs the named cap bits (the CAP_* consts emitted above), so the
            // kernel's Tier::caps() derives from this one place and both kernels agree.
            "tier-caps" => {
                comment(
                    &mut o,
                    "tier → capability ceiling — the kernel's Tier::caps() consumes this (single source)",
                );
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
                        o.push_str(
                            "pub fn tier_caps(tier: i32) u8 {\n    return switch (tier) {\n",
                        );
                        for (name, expr) in &arms {
                            o.push_str(&format!("        {name} => {expr},\n"));
                        }
                        o.push_str("        else => 0,\n    };\n}\n");
                    }
                    "ts" => {
                        o.push_str(
                            "export function tierCaps(tier: number): number {\n  switch (tier) {\n",
                        );
                        for (name, expr) in &arms {
                            o.push_str(&format!("    case {name}: return {expr};\n"));
                        }
                        o.push_str("    default: return 0;\n  }\n}\n");
                    }
                    "elixir" => {
                        o.push_str("  def tier_caps(tier) do\n    case tier do\n");
                        for (name, expr) in &arms {
                            let tier = const_values.get(name).copied().unwrap_or(0);
                            let caps = expr
                                .split('|')
                                .map(str::trim)
                                .filter(|s| !s.is_empty())
                                .map(|cap| const_values.get(cap).copied().unwrap_or(0))
                                .fold(0, |acc, v| acc | v);
                            o.push_str(&format!("      {tier} -> {caps}\n"));
                        }
                        o.push_str("      _ -> 0\n    end\n  end\n");
                    }
                    "luau" => {
                        o.push_str("M.tier_caps = function(tier)\n");
                        for (name, expr) in &arms {
                            let lua_expr = expr
                                .split('|')
                                .map(str::trim)
                                .filter(|s| !s.is_empty())
                                .map(|s| format!("M.{s}"))
                                .collect::<Vec<_>>()
                                .join(" + ");
                            let lua_expr = if lua_expr.is_empty() {
                                "0".to_string()
                            } else {
                                lua_expr
                            };
                            o.push_str(&format!(
                                "  if tier == M.{name} then return {lua_expr} end\n"
                            ));
                        }
                        o.push_str("  return 0\nend\n");
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
                comment(
                    &mut o,
                    "the argv[1] marker the kernel passes to spawn a binary in SERVICE mode (SYSTEMS.md)",
                );
                match lang {
                    "rust" => o.push_str(&format!("pub const {cname}: &str = \"{value}\";\n")),
                    "zig" => o.push_str(&format!("pub const {cname}: []const u8 = \"{value}\";\n")),
                    "ts" => o.push_str(&format!("export const {cname} = \"{value}\";\n")),
                    "elixir" => o.push_str(&format!(
                        "  def {}, do: \"{value}\"\n",
                        elixir_fun_name(&cname)
                    )),
                    "luau" => o.push_str(&format!("M.{cname} = \"{value}\"\n")),
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
                        "elixir" => {
                            o.push_str(&format!("  def {}, do: {v}\n", elixir_fun_name(name)))
                        }
                        "luau" => o.push_str(&format!("M.{name} = {v}\n")),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    if lang == "elixir" {
        o.push_str("end\n");
    } else if lang == "luau" {
        o.push_str("return M\n");
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

#[derive(Clone)]
struct MessageField {
    name: String,
    ty: String,
    optional: bool,
}

#[derive(Clone)]
struct Message {
    name: String,
    id: u16,
    version: u8,
    fields: Vec<MessageField>,
    doc: String,
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
                .map(|a| {
                    (
                        a.arg_str(0).to_string(),
                        a.prop_str("type").unwrap_or("i32").to_string(),
                    )
                })
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

fn collect_codec_messages(nodes: &[Node]) -> Vec<Message> {
    nodes
        .iter()
        .filter(|n| n.name == "message" && n.children.iter().any(|c| c.name == "field"))
        .map(|n| Message {
            name: n.arg_str(0).to_string(),
            id: n.props.get("id").map(Val::as_int).unwrap_or(0) as u16,
            version: n.props.get("version").map(Val::as_int).unwrap_or(1) as u8,
            fields: n
                .children_named("field")
                .map(|f| MessageField {
                    name: f.arg_str(0).to_string(),
                    ty: f.prop_str("type").unwrap_or("bytes").to_string(),
                    optional: prop_bool(f, "opt", false),
                })
                .collect(),
            doc: n.doc(),
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
            c.next()
                .map(|f| f.to_uppercase().collect::<String>() + c.as_str())
                .unwrap_or_default()
        })
        .collect()
}

fn screaming_snake(s: &str) -> String {
    let mut out = String::new();
    let mut prev_lower = false;
    for c in s.chars() {
        if c == '-' || c == ' ' {
            if !out.ends_with('_') {
                out.push('_');
            }
            prev_lower = false;
        } else if c == '_' {
            if !out.ends_with('_') {
                out.push('_');
            }
            prev_lower = false;
        } else if c.is_ascii_uppercase() {
            if prev_lower && !out.ends_with('_') {
                out.push('_');
            }
            out.push(c);
            prev_lower = false;
        } else {
            out.push(c.to_ascii_uppercase());
            prev_lower = c.is_ascii_lowercase() || c.is_ascii_digit();
        }
    }
    out
}

fn list_inner(ty: &str) -> Option<&str> {
    let ty = ty.trim();
    ty.strip_prefix("list<")
        .and_then(|rest| rest.strip_suffix('>'))
        .map(str::trim)
        .filter(|inner| !inner.is_empty())
}

fn rust_type(ty: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("Vec<{}>", rust_type(inner));
    }
    match ty {
        "u32" => "u32".to_string(),
        "i32" => "i32".to_string(),
        "i64" => "i64".to_string(),
        "bool" => "bool".to_string(),
        "str" => "String".to_string(),
        "bytes" => "Vec<u8>".to_string(),
        "strmap" => "BTreeMap<String, String>".to_string(),
        _ => ty.to_string(),
    }
}

fn ts_type(ty: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("{}[]", ts_type(inner));
    }
    match ty {
        "u32" | "i32" | "i64" => "number".to_string(),
        "bool" => "boolean".to_string(),
        "str" => "string".to_string(),
        "bytes" => "Uint8Array".to_string(),
        "strmap" => "Record<string, string>".to_string(),
        _ => ty.to_string(),
    }
}

fn zig_type(ty: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("[]const {}", zig_type(inner));
    }
    match ty {
        "u32" => "u32".to_string(),
        "i32" => "i32".to_string(),
        "i64" => "i64".to_string(),
        "bool" => "bool".to_string(),
        "str" | "bytes" => "[]const u8".to_string(),
        "strmap" => "[]const StringPair".to_string(),
        _ => ty.to_string(),
    }
}

fn zig_ident(name: &str) -> String {
    match name {
        "error" | "align" | "allowzero" | "and" | "anytype" | "asm" | "async" | "await"
        | "break" | "catch" | "comptime" | "const" | "continue" | "defer" | "else" | "enum"
        | "errdefer" | "export" | "extern" | "fn" | "for" | "if" | "inline" | "linksection"
        | "noalias" | "noinline" | "nosuspend" | "opaque" | "or" | "orelse" | "packed" | "pub"
        | "resume" | "return" | "struct" | "suspend" | "switch" | "test" | "threadlocal"
        | "try" | "union" | "unreachable" | "usingnamespace" | "var" | "volatile" | "while" => {
            format!("@\"{name}\"")
        }
        _ => name.to_string(),
    }
}

fn zig_local(name: &str) -> String {
    if zig_ident(name) == name {
        name.to_string()
    } else {
        format!("{name}_value")
    }
}

fn elixir_fun_name(s: &str) -> String {
    let mut out = String::new();
    let mut prev_lower = false;
    for c in s.chars() {
        if c == '-' || c == ' ' || c == '_' {
            if !out.ends_with('_') {
                out.push('_');
            }
            prev_lower = false;
        } else if c.is_ascii_uppercase() {
            if prev_lower && !out.ends_with('_') {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
            prev_lower = false;
        } else {
            out.push(c.to_ascii_lowercase());
            prev_lower = c.is_ascii_lowercase() || c.is_ascii_digit();
        }
    }
    out
}

fn elixir_module_name(contract: &str) -> String {
    let stem = contract.strip_suffix(".kdl").unwrap_or(contract);
    let module = match stem {
        "llb" => "LLB".to_string(),
        _ => to_variant(stem),
    };
    format!("AgentOS.Contracts.{module}")
}

fn elixir_encode_expr(ty: &str, expr: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!(
            "put_message_list({expr}, &encode_{}/1)",
            elixir_fun_name(inner)
        );
    }
    match ty {
        "u32" => format!("put_u32({expr})"),
        "i32" => format!("put_i32({expr})"),
        "i64" => format!("put_i64({expr})"),
        "bool" => format!("put_bool({expr})"),
        "str" => format!("put_str({expr})"),
        "bytes" => format!("put_bytes({expr})"),
        "strmap" => format!("put_strmap({expr})"),
        _ => format!("put_bytes(encode_{}({expr}))", elixir_fun_name(ty)),
    }
}

fn elixir_decode_expr(ty: &str, rest: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!(
            "read_message_list({rest}, &decode_{}/1)",
            elixir_fun_name(inner)
        );
    }
    match ty {
        "u32" => format!("read_u32({rest})"),
        "i32" => format!("read_i32({rest})"),
        "i64" => format!("read_i64({rest})"),
        "bool" => format!("read_bool({rest})"),
        "str" => format!("read_str({rest})"),
        "bytes" => format!("read_bytes({rest})"),
        "strmap" => format!("read_strmap({rest})"),
        _ => format!("read_message({rest}, &decode_{}/1)", elixir_fun_name(ty)),
    }
}

fn field_type_contains(ty: &str, needle: &str) -> bool {
    if ty == needle {
        return true;
    }
    list_inner(ty)
        .map(|inner| field_type_contains(inner, needle))
        .unwrap_or(false)
}

fn messages_use_type(messages: &[Message], needle: &str) -> bool {
    messages
        .iter()
        .any(|m| m.fields.iter().any(|f| field_type_contains(&f.ty, needle)))
}

fn is_builtin_elixir_type(ty: &str) -> bool {
    matches!(
        ty,
        "u32" | "i32" | "i64" | "bool" | "str" | "bytes" | "strmap"
    )
}

fn messages_use_list_type(messages: &[Message]) -> bool {
    messages
        .iter()
        .any(|m| m.fields.iter().any(|f| list_inner(&f.ty).is_some()))
}

fn messages_use_scalar_message_type(messages: &[Message]) -> bool {
    messages.iter().any(|m| {
        m.fields
            .iter()
            .any(|f| list_inner(&f.ty).is_none() && !is_builtin_elixir_type(&f.ty))
    })
}

fn emit_elixir_messages(messages: &[Message], contract: &str) -> String {
    if messages.is_empty() {
        return String::new();
    }

    let mut o = String::new();
    o.push_str(&format!("defmodule {} do\n", elixir_module_name(contract)));
    o.push_str("  @moduledoc false\n\n");
    let uses_i32 = messages_use_type(messages, "i32");
    let uses_message_list = messages_use_list_type(messages);
    let uses_scalar_message = messages_use_scalar_message_type(messages);
    o.push_str(
        r#"  defp field!(map, key) do
    case field(map, key, :__mc_missing__) do
      :__mc_missing__ -> raise KeyError, key: key, term: map
      value -> value
    end
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp read_header(bytes, expected_id, expected_version) do
    with {:ok, id, rest} <- read_u16(bytes),
         true <- id == expected_id || {:error, "wrong message id"},
         {:ok, version, rest} <- read_u8(rest),
         true <- version == expected_version || {:error, "unsupported message version"} do
      {:ok, rest}
    end
  end

  defp read_u8(<<value, rest::binary>>), do: {:ok, value, rest}
  defp read_u8(_bytes), do: {:error, "truncated frame"}
  defp read_u16(<<value::unsigned-little-16, rest::binary>>), do: {:ok, value, rest}
  defp read_u16(_bytes), do: {:error, "truncated frame"}
  defp read_u32(<<value::unsigned-little-32, rest::binary>>), do: {:ok, value, rest}
  defp read_u32(_bytes), do: {:error, "truncated frame"}
  defp read_i64(<<value::signed-little-64, rest::binary>>), do: {:ok, value, rest}
  defp read_i64(_bytes), do: {:error, "truncated frame"}

  defp read_bool(bytes) do
    case read_u8(bytes) do
      {:ok, 0, rest} -> {:ok, false, rest}
      {:ok, 1, rest} -> {:ok, true, rest}
      {:ok, _value, _rest} -> {:error, "invalid bool"}
      err -> err
    end
  end

  defp read_bytes(bytes) do
    with {:ok, len, rest} <- read_u32(bytes),
         true <- byte_size(rest) >= len || {:error, "truncated frame"} do
      <<out::binary-size(^len), rest::binary>> = rest
      {:ok, out, rest}
    end
  end

  defp read_str(bytes) do
    with {:ok, out, rest} <- read_bytes(bytes),
         true <- String.valid?(out) || {:error, "invalid utf-8"} do
      {:ok, out, rest}
    end
  end

  defp read_strmap(bytes) do
    with {:ok, n, rest} <- read_u32(bytes) do
      read_strmap_entries(n, rest, nil, %{})
    end
  end

  defp read_strmap_entries(0, rest, _prev, out), do: {:ok, out, rest}

  defp read_strmap_entries(n, bytes, prev, out) do
    with {:ok, key, rest} <- read_str(bytes),
         true <- is_nil(prev) or prev < key || {:error, "non-canonical strmap"},
         {:ok, value, rest} <- read_str(rest) do
      read_strmap_entries(n - 1, rest, key, Map.put(out, key, value))
    end
  end

  defp read_opt(bytes, fun) do
    case read_u8(bytes) do
      {:ok, 0, rest} -> {:ok, nil, rest}
      {:ok, 1, rest} -> fun.(rest)
      {:ok, _value, _rest} -> {:error, "invalid optional presence"}
      err -> err
    end
  end

  defp read_eof(<<>>), do: :ok
  defp read_eof(_rest), do: {:error, "trailing bytes"}

  defp put_u8(value), do: <<value::unsigned-little-8>>
  defp put_u16(value), do: <<value::unsigned-little-16>>
  defp put_u32(value), do: <<value::unsigned-little-32>>
  defp put_i64(value), do: <<value::signed-little-64>>
  defp put_bool(true), do: <<1>>
  defp put_bool(false), do: <<0>>
  defp put_bytes(bytes), do: [put_u32(byte_size(bytes)), bytes]
  defp put_str(value), do: put_bytes(value)

  defp put_strmap(map) do
    entries = map |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end) |> Enum.sort()
    [put_u32(length(entries)), Enum.map(entries, fn {k, v} -> [put_str(k), put_str(v)] end)]
  end

"#,
    );
    if uses_message_list {
        o.push_str(
            r#"  defp read_message_list(bytes, decoder) do
    with {:ok, n, rest} <- read_u32(bytes) do
      read_message_list_items(n, rest, decoder, [])
    end
  end

  defp read_message_list_items(0, rest, _decoder, acc), do: {:ok, Enum.reverse(acc), rest}

  defp read_message_list_items(n, bytes, decoder, acc) do
    with {:ok, item_bytes, rest} <- read_bytes(bytes),
         {:ok, item} <- decoder.(item_bytes) do
      read_message_list_items(n - 1, rest, decoder, [item | acc])
    end
  end

  defp put_message_list(values, encoder) do
    [put_u32(length(values)), Enum.map(values, fn value -> put_bytes(encoder.(value)) end)]
  end

"#,
        );
    }
    if uses_scalar_message {
        o.push_str(
            r#"  defp read_message(bytes, decoder) do
    with {:ok, item_bytes, rest} <- read_bytes(bytes),
         {:ok, item} <- decoder.(item_bytes) do
      {:ok, item, rest}
    end
  end

"#,
        );
    }
    if uses_i32 {
        o.push_str(
            r#"  defp read_i32(<<value::signed-little-32, rest::binary>>), do: {:ok, value, rest}
  defp read_i32(_bytes), do: {:error, "truncated frame"}
  defp put_i32(value), do: <<value::signed-little-32>>

"#,
        );
    }

    for m in messages {
        let fun = elixir_fun_name(&m.name);
        let const_prefix = screaming_snake(&m.name);
        o.push_str(&format!("  @{}_msg_id {}\n", fun, m.id));
        o.push_str(&format!("  @{}_version {}\n", fun, m.version));
        o.push_str(&format!(
            "\n  def encode_{}(msg) when is_map(msg) do\n",
            fun
        ));
        o.push_str("    IO.iodata_to_binary([\n");
        o.push_str(&format!("      put_u16(@{}_msg_id),\n", fun));
        o.push_str(&format!("      put_u8(@{}_version)", fun));
        for f in &m.fields {
            let key = format!(":{}", f.name);
            if f.optional {
                o.push_str(",\n      ");
                o.push_str(&format!(
                    "case field(msg, {key}) do\n        nil -> <<0>>\n        value -> [<<1>>, {}]\n      end",
                    elixir_encode_expr(&f.ty, "value")
                ));
            } else {
                o.push_str(",\n      ");
                o.push_str(&elixir_encode_expr(&f.ty, &format!("field!(msg, {key})")));
            }
        }
        o.push_str("\n    ])\n  end\n\n");

        o.push_str(&format!(
            "  def decode_{}(bytes) when is_binary(bytes) do\n",
            fun
        ));
        o.push_str(&format!(
            "    with {{:ok, rest}} <- read_header(bytes, @{}_msg_id, @{}_version)",
            fun, fun
        ));
        for f in &m.fields {
            if f.optional {
                o.push_str(&format!(
                    ",\n         {{:ok, {}, rest}} <- read_opt(rest, fn rest -> {} end)",
                    f.name,
                    elixir_decode_expr(&f.ty, "rest")
                ));
            } else {
                o.push_str(&format!(
                    ",\n         {{:ok, {}, rest}} <- {}",
                    f.name,
                    elixir_decode_expr(&f.ty, "rest")
                ));
            }
        }
        o.push_str(",\n         :ok <- read_eof(rest) do\n");
        o.push_str("      {:ok, %{\n");
        for f in &m.fields {
            o.push_str(&format!("        {}: {},\n", f.name, f.name));
        }
        o.push_str("      }}\n    end\n  end\n\n");

        o.push_str(&format!(
            "  def {}_msg_id, do: @{}_msg_id\n  def {}_version, do: @{}_version\n\n",
            fun, fun, fun, fun
        ));
        o.push_str(&format!("  # {const_prefix}\n"));
    }

    o.push_str("end\n");
    o
}

fn emit_rust_codec_field_put(o: &mut String, f: &MessageField, expr: &str) {
    if list_inner(&f.ty).is_some() {
        o.push_str(&format!(
            "        ctl_put_message_list(&mut out, {expr}, |v| v.encode());\n"
        ));
        return;
    }
    match f.ty.as_str() {
        "u32" => o.push_str(&format!("        ctl_put_u32(&mut out, {expr});\n")),
        "i32" => o.push_str(&format!("        ctl_put_i32(&mut out, {expr});\n")),
        "i64" => o.push_str(&format!("        ctl_put_i64(&mut out, {expr});\n")),
        "bool" => o.push_str(&format!("        ctl_put_bool(&mut out, {expr});\n")),
        "str" => o.push_str(&format!("        ctl_put_str(&mut out, {expr});\n")),
        "bytes" => o.push_str(&format!("        ctl_put_bytes(&mut out, {expr});\n")),
        "strmap" => o.push_str(&format!("        ctl_put_strmap(&mut out, {expr});\n")),
        _ => o.push_str(&format!(
            "        let frame = ({expr}).encode();\n        ctl_put_bytes(&mut out, &frame);\n"
        )),
    }
}

fn rust_encode_expr(f: &MessageField, base: &str, by_ref_match: bool) -> String {
    match f.ty.as_str() {
        "u32" | "i32" | "i64" | "bool" if by_ref_match => format!("*{base}"),
        "u32" | "i32" | "i64" | "bool" => base.to_string(),
        _ if by_ref_match => base.to_string(),
        _ => format!("&{base}"),
    }
}

fn rust_decode_expr(ty: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("ctl_read_message_list(bytes, &mut off, {inner}::decode)?");
    }
    match ty {
        "u32" => "ctl_read_u32(bytes, &mut off)?".to_string(),
        "i32" => "ctl_read_i32(bytes, &mut off)?".to_string(),
        "i64" => "ctl_read_i64(bytes, &mut off)?".to_string(),
        "bool" => "ctl_read_bool(bytes, &mut off)?".to_string(),
        "str" => "ctl_read_str(bytes, &mut off)?".to_string(),
        "bytes" => "ctl_read_bytes(bytes, &mut off)?".to_string(),
        "strmap" => "ctl_read_strmap(bytes, &mut off)?".to_string(),
        _ => format!("{ty}::decode(&ctl_read_bytes(bytes, &mut off)?)?"),
    }
}

fn emit_rust_messages(messages: &[Message]) -> String {
    if messages.is_empty() {
        return String::new();
    }
    let mut o = String::new();
    o.push_str("#![allow(dead_code)]\n\nextern crate alloc;\nuse alloc::collections::BTreeMap;\nuse alloc::string::String;\nuse alloc::vec::Vec;\n\n");
    o.push_str("#[derive(Clone, Copy, Debug, Eq, PartialEq)]\n");
    o.push_str("pub enum WireError { WrongMessage, UnsupportedVersion, Truncated, InvalidUtf8, NonCanonicalMap, InvalidPresence, TrailingBytes }\n\n");
    o.push_str(
        "fn ctl_put_u16(out: &mut Vec<u8>, v: u16) { out.extend_from_slice(&v.to_le_bytes()); }\n",
    );
    o.push_str(
        "fn ctl_put_u32(out: &mut Vec<u8>, v: u32) { out.extend_from_slice(&v.to_le_bytes()); }\n",
    );
    o.push_str(
        "fn ctl_put_i32(out: &mut Vec<u8>, v: i32) { out.extend_from_slice(&v.to_le_bytes()); }\n",
    );
    o.push_str(
        "fn ctl_put_i64(out: &mut Vec<u8>, v: i64) { out.extend_from_slice(&v.to_le_bytes()); }\n",
    );
    o.push_str(
        "fn ctl_put_bool(out: &mut Vec<u8>, v: bool) { out.push(if v { 1 } else { 0 }); }\n",
    );
    o.push_str("fn ctl_put_bytes(out: &mut Vec<u8>, v: &[u8]) { ctl_put_u32(out, v.len() as u32); out.extend_from_slice(v); }\n");
    o.push_str(
        "fn ctl_put_str(out: &mut Vec<u8>, v: &str) { ctl_put_bytes(out, v.as_bytes()); }\n",
    );
    o.push_str("fn ctl_put_strmap(out: &mut Vec<u8>, v: &BTreeMap<String, String>) { ctl_put_u32(out, v.len() as u32); for (k, val) in v { ctl_put_str(out, k); ctl_put_str(out, val); } }\n");
    o.push_str("fn ctl_put_message_list<T, F>(out: &mut Vec<u8>, values: &[T], mut encode: F) where F: FnMut(&T) -> Vec<u8> { ctl_put_u32(out, values.len() as u32); for value in values { let frame = encode(value); ctl_put_bytes(out, &frame); } }\n");
    o.push_str("fn ctl_need<'a>(bytes: &'a [u8], off: &mut usize, len: usize) -> Result<&'a [u8], WireError> { let end = off.checked_add(len).ok_or(WireError::Truncated)?; if end > bytes.len() { return Err(WireError::Truncated); } let out = &bytes[*off..end]; *off = end; Ok(out) }\n");
    o.push_str("fn ctl_read_u8(bytes: &[u8], off: &mut usize) -> Result<u8, WireError> { Ok(ctl_need(bytes, off, 1)?[0]) }\n");
    o.push_str("fn ctl_read_u16(bytes: &[u8], off: &mut usize) -> Result<u16, WireError> { let b = ctl_need(bytes, off, 2)?; Ok(u16::from_le_bytes([b[0], b[1]])) }\n");
    o.push_str("fn ctl_read_u32(bytes: &[u8], off: &mut usize) -> Result<u32, WireError> { let b = ctl_need(bytes, off, 4)?; Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]])) }\n");
    o.push_str("fn ctl_read_i32(bytes: &[u8], off: &mut usize) -> Result<i32, WireError> { let b = ctl_need(bytes, off, 4)?; Ok(i32::from_le_bytes([b[0], b[1], b[2], b[3]])) }\n");
    o.push_str("fn ctl_read_i64(bytes: &[u8], off: &mut usize) -> Result<i64, WireError> { let b = ctl_need(bytes, off, 8)?; Ok(i64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])) }\n");
    o.push_str("fn ctl_read_bool(bytes: &[u8], off: &mut usize) -> Result<bool, WireError> { match ctl_read_u8(bytes, off)? { 0 => Ok(false), 1 => Ok(true), _ => Err(WireError::InvalidPresence) } }\n");
    o.push_str("fn ctl_read_bytes(bytes: &[u8], off: &mut usize) -> Result<Vec<u8>, WireError> { let len = ctl_read_u32(bytes, off)? as usize; Ok(ctl_need(bytes, off, len)?.to_vec()) }\n");
    o.push_str("fn ctl_read_str(bytes: &[u8], off: &mut usize) -> Result<String, WireError> { String::from_utf8(ctl_read_bytes(bytes, off)?).map_err(|_| WireError::InvalidUtf8) }\n");
    o.push_str("fn ctl_read_strmap(bytes: &[u8], off: &mut usize) -> Result<BTreeMap<String, String>, WireError> { let n = ctl_read_u32(bytes, off)? as usize; let mut out = BTreeMap::new(); let mut prev: Option<String> = None; for _ in 0..n { let k = ctl_read_str(bytes, off)?; if prev.as_ref().map_or(false, |p| p >= &k) { return Err(WireError::NonCanonicalMap); } let v = ctl_read_str(bytes, off)?; prev = Some(k.clone()); out.insert(k, v); } Ok(out) }\n\n");
    o.push_str("fn ctl_read_message_list<T, F>(bytes: &[u8], off: &mut usize, mut decode: F) -> Result<Vec<T>, WireError> where F: FnMut(&[u8]) -> Result<T, WireError> { let n = ctl_read_u32(bytes, off)? as usize; let mut out = Vec::with_capacity(n); for _ in 0..n { let frame = ctl_read_bytes(bytes, off)?; out.push(decode(&frame)?); } Ok(out) }\n\n");

    for m in messages {
        let const_prefix = screaming_snake(&m.name);
        if !m.doc.is_empty() {
            o.push_str(&format!("/// {}\n", m.doc));
        }
        o.push_str("#[derive(Clone, Debug, Default, Eq, PartialEq)]\n");
        o.push_str(&format!("pub struct {} {{\n", m.name));
        for f in &m.fields {
            let ty = rust_type(&f.ty);
            if f.optional {
                o.push_str(&format!("    pub {}: Option<{}>,\n", f.name, ty));
            } else {
                o.push_str(&format!("    pub {}: {},\n", f.name, ty));
            }
        }
        o.push_str("}\n\n");
        o.push_str(&format!(
            "pub const {const_prefix}_MSG_ID: u16 = {};\n",
            m.id
        ));
        o.push_str(&format!(
            "pub const {const_prefix}_VERSION: u8 = {};\n",
            m.version
        ));
        o.push_str(&format!("impl {} {{\n", m.name));
        o.push_str("    pub fn encode(&self) -> Vec<u8> {\n");
        o.push_str("        let mut out = Vec::new();\n");
        o.push_str(&format!(
            "        ctl_put_u16(&mut out, {const_prefix}_MSG_ID);\n"
        ));
        o.push_str(&format!("        out.push({const_prefix}_VERSION);\n"));
        for f in &m.fields {
            if f.optional {
                o.push_str(&format!("        match &self.{} {{\n", f.name));
                o.push_str("            Some(v) => {\n                out.push(1);\n");
                emit_rust_codec_field_put(&mut o, f, &rust_encode_expr(f, "v", true));
                o.push_str("            }\n            None => out.push(0),\n        }\n");
            } else {
                emit_rust_codec_field_put(
                    &mut o,
                    f,
                    &rust_encode_expr(f, &format!("self.{}", f.name), false),
                );
            }
        }
        o.push_str("        out\n    }\n\n");
        o.push_str("    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {\n");
        o.push_str("        let mut off = 0usize;\n");
        o.push_str(&format!("        if ctl_read_u16(bytes, &mut off)? != {const_prefix}_MSG_ID {{ return Err(WireError::WrongMessage); }}\n"));
        o.push_str(&format!("        if ctl_read_u8(bytes, &mut off)? != {const_prefix}_VERSION {{ return Err(WireError::UnsupportedVersion); }}\n"));
        for f in &m.fields {
            if f.optional {
                o.push_str(&format!(
                    "        let {} = match ctl_read_u8(bytes, &mut off)? {{\n",
                    f.name
                ));
                o.push_str("            0 => None,\n            1 => Some(");
                o.push_str(&rust_decode_expr(&f.ty));
                o.push_str(
                    "),\n            _ => return Err(WireError::InvalidPresence),\n        };\n",
                );
            } else {
                o.push_str(&format!(
                    "        let {} = {};\n",
                    f.name,
                    rust_decode_expr(&f.ty)
                ));
            }
        }
        o.push_str("        if off != bytes.len() { return Err(WireError::TrailingBytes); }\n");
        o.push_str("        Ok(Self {\n");
        for f in &m.fields {
            o.push_str(&format!("            {},\n", f.name));
        }
        o.push_str("        })\n    }\n}\n\n");
    }
    o
}

fn emit_ts_codec_field_put(o: &mut String, f: &MessageField, expr: &str) {
    if let Some(inner) = list_inner(&f.ty) {
        o.push_str(&format!(
            "  ctlPutMessageList(out, {expr}, encode{});\n",
            inner
        ));
        return;
    }
    match f.ty.as_str() {
        "u32" => o.push_str(&format!("  ctlPutU32(out, {expr});\n")),
        "i32" => o.push_str(&format!("  ctlPutI32(out, {expr});\n")),
        "i64" => o.push_str(&format!("  ctlPutI64(out, {expr});\n")),
        "bool" => o.push_str(&format!("  ctlPutBool(out, {expr});\n")),
        "str" => o.push_str(&format!("  ctlPutStr(out, {expr});\n")),
        "bytes" => o.push_str(&format!("  ctlPutBytes(out, {expr});\n")),
        "strmap" => o.push_str(&format!("  ctlPutStrMap(out, {expr});\n")),
        _ => o.push_str(&format!("  ctlPutBytes(out, encode{}({expr}));\n", f.ty)),
    }
}

fn ts_decode_expr(ty: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("ctlReadMessageList(cursor, decode{inner})");
    }
    match ty {
        "u32" => "ctlReadU32(cursor)".to_string(),
        "i32" => "ctlReadI32(cursor)".to_string(),
        "i64" => "ctlReadI64(cursor)".to_string(),
        "bool" => "ctlReadBool(cursor)".to_string(),
        "str" => "ctlReadStr(cursor)".to_string(),
        "bytes" => "ctlReadBytes(cursor)".to_string(),
        "strmap" => "ctlReadStrMap(cursor)".to_string(),
        _ => format!("decode{ty}(ctlReadBytes(cursor))"),
    }
}

fn emit_ts_messages(messages: &[Message]) -> String {
    if messages.is_empty() {
        return String::new();
    }
    let mut o = String::new();
    o.push_str("\nconst CTL_TEXT_ENCODER = new TextEncoder();\n");
    o.push_str("const CTL_TEXT_DECODER = new TextDecoder(\"utf-8\", { fatal: true });\n\n");
    o.push_str("export class WireError extends Error { constructor(message: string) { super(message); this.name = \"WireError\"; } }\n");
    o.push_str("interface CtlCursor { bytes: Uint8Array; off: number }\n");
    o.push_str("function ctlNeed(cursor: CtlCursor, len: number): Uint8Array { const end = cursor.off + len; if (end > cursor.bytes.length) throw new WireError(\"truncated frame\"); const out = cursor.bytes.subarray(cursor.off, end); cursor.off = end; return out; }\n");
    o.push_str("function ctlPutU8(out: number[], v: number): void { out.push(v & 0xff); }\n");
    o.push_str("function ctlPutU16(out: number[], v: number): void { out.push(v & 0xff, (v >>> 8) & 0xff); }\n");
    o.push_str("function ctlPutU32(out: number[], v: number): void { out.push(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff); }\n");
    o.push_str("function ctlPutI32(out: number[], v: number): void { ctlPutU32(out, v >>> 0); }\n");
    o.push_str("function ctlPutI64(out: number[], v: number): void { let x = BigInt(Math.trunc(v)); for (let i = 0; i < 8; i++) { out.push(Number((x >> BigInt(i * 8)) & 0xffn)); } }\n");
    o.push_str("function ctlPutBool(out: number[], v: boolean): void { out.push(v ? 1 : 0); }\n");
    o.push_str("function ctlPutBytes(out: number[], v: Uint8Array): void { ctlPutU32(out, v.length); for (const b of v) out.push(b); }\n");
    o.push_str("function ctlPutStr(out: number[], v: string): void { ctlPutBytes(out, CTL_TEXT_ENCODER.encode(v)); }\n");
    o.push_str("function ctlPutStrMap(out: number[], v: Record<string, string>): void { const entries = Object.entries(v).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0); ctlPutU32(out, entries.length); for (const [k, val] of entries) { ctlPutStr(out, k); ctlPutStr(out, val); } }\n");
    o.push_str("function ctlPutMessageList<T>(out: number[], values: readonly T[], encode: (msg: T) => Uint8Array): void { ctlPutU32(out, values.length); for (const value of values) ctlPutBytes(out, encode(value)); }\n");
    o.push_str(
        "function ctlReadU8(cursor: CtlCursor): number { return ctlNeed(cursor, 1)[0]!; }\n",
    );
    o.push_str("function ctlReadU16(cursor: CtlCursor): number { const b = ctlNeed(cursor, 2); return b[0]! | (b[1]! << 8); }\n");
    o.push_str("function ctlReadU32(cursor: CtlCursor): number { const b = ctlNeed(cursor, 4); return (b[0]! | (b[1]! << 8) | (b[2]! << 16) | (b[3]! << 24)) >>> 0; }\n");
    o.push_str(
        "function ctlReadI32(cursor: CtlCursor): number { return ctlReadU32(cursor) | 0; }\n",
    );
    o.push_str("function ctlReadI64(cursor: CtlCursor): number { const b = ctlNeed(cursor, 8); let x = 0n; for (let i = 0; i < 8; i++) x |= BigInt(b[i]!) << BigInt(i * 8); if ((x & (1n << 63n)) !== 0n) x -= 1n << 64n; return Number(x); }\n");
    o.push_str("function ctlReadBool(cursor: CtlCursor): boolean { const v = ctlReadU8(cursor); if (v === 0) return false; if (v === 1) return true; throw new WireError(\"invalid bool\"); }\n");
    o.push_str("function ctlReadBytes(cursor: CtlCursor): Uint8Array { const len = ctlReadU32(cursor); return ctlNeed(cursor, len).slice(); }\n");
    o.push_str("function ctlReadStr(cursor: CtlCursor): string { try { return CTL_TEXT_DECODER.decode(ctlReadBytes(cursor)); } catch { throw new WireError(\"invalid utf-8\"); } }\n");
    o.push_str("function ctlReadStrMap(cursor: CtlCursor): Record<string, string> { const n = ctlReadU32(cursor); const out: Record<string, string> = {}; let prev: string | null = null; for (let i = 0; i < n; i++) { const k = ctlReadStr(cursor); if (prev !== null && prev >= k) throw new WireError(\"non-canonical strmap\"); out[k] = ctlReadStr(cursor); prev = k; } return out; }\n\n");
    o.push_str("function ctlReadMessageList<T>(cursor: CtlCursor, decode: (bytes: Uint8Array) => T): T[] { const n = ctlReadU32(cursor); const out: T[] = []; for (let i = 0; i < n; i++) out.push(decode(ctlReadBytes(cursor))); return out; }\n\n");

    for m in messages {
        let const_prefix = screaming_snake(&m.name);
        if !m.doc.is_empty() {
            o.push_str(&format!("// {}\n", m.doc));
        }
        o.push_str(&format!("export interface {} {{\n", m.name));
        for f in &m.fields {
            let opt = if f.optional { "?" } else { "" };
            let nil = if f.optional { " | null" } else { "" };
            o.push_str(&format!(
                "  {}{}: {}{};\n",
                f.name,
                opt,
                ts_type(&f.ty),
                nil
            ));
        }
        o.push_str("}\n");
        o.push_str(&format!("export const {const_prefix}_MSG_ID = {};\n", m.id));
        o.push_str(&format!(
            "export const {const_prefix}_VERSION = {};\n",
            m.version
        ));
        o.push_str(&format!(
            "export function encode{}(msg: {}): Uint8Array {{\n",
            m.name, m.name
        ));
        o.push_str("  const out: number[] = [];\n");
        o.push_str(&format!("  ctlPutU16(out, {const_prefix}_MSG_ID);\n"));
        o.push_str(&format!("  ctlPutU8(out, {const_prefix}_VERSION);\n"));
        for f in &m.fields {
            if f.optional {
                o.push_str(&format!(
                    "  if (msg.{} === undefined || msg.{} === null) {{\n",
                    f.name, f.name
                ));
                o.push_str("    ctlPutU8(out, 0);\n  } else {\n    ctlPutU8(out, 1);\n");
                emit_ts_codec_field_put(&mut o, f, &format!("msg.{}", f.name));
                o.push_str("  }\n");
            } else {
                emit_ts_codec_field_put(&mut o, f, &format!("msg.{}", f.name));
            }
        }
        o.push_str("  return Uint8Array.from(out);\n}\n");
        o.push_str(&format!(
            "export function decode{}(bytes: Uint8Array): {} {{\n",
            m.name, m.name
        ));
        o.push_str("  const cursor: CtlCursor = { bytes, off: 0 };\n");
        o.push_str(&format!("  if (ctlReadU16(cursor) !== {const_prefix}_MSG_ID) throw new WireError(\"wrong message id\");\n"));
        o.push_str(&format!("  if (ctlReadU8(cursor) !== {const_prefix}_VERSION) throw new WireError(\"unsupported message version\");\n"));
        for f in &m.fields {
            if f.optional {
                o.push_str(&format!(
                    "  let {}: {} | undefined;\n",
                    f.name,
                    ts_type(&f.ty)
                ));
                o.push_str(&format!("  switch (ctlReadU8(cursor)) {{\n    case 0: {} = undefined; break;\n    case 1: {} = {}; break;\n    default: throw new WireError(\"invalid optional presence\");\n  }}\n", f.name, f.name, ts_decode_expr(&f.ty)));
            } else {
                o.push_str(&format!(
                    "  const {} = {};\n",
                    f.name,
                    ts_decode_expr(&f.ty)
                ));
            }
        }
        o.push_str("  if (cursor.off !== bytes.length) throw new WireError(\"trailing bytes\");\n");
        o.push_str("  return {\n");
        for f in &m.fields {
            o.push_str(&format!("    {},\n", f.name));
        }
        o.push_str("  };\n}\n\n");
    }
    o
}

fn luau_encode_expr(ty: &str, expr: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("put_list({expr}, M.encode_{inner})");
    }
    match ty {
        "u32" => format!("put_u32({expr})"),
        "i32" => format!("put_i32({expr})"),
        "i64" => format!("put_i64({expr})"),
        "bool" => format!("put_bool({expr})"),
        "str" | "bytes" => format!("put_bytes({expr})"),
        "strmap" => format!("put_strmap({expr})"),
        _ => format!("put_bytes(M.encode_{ty}({expr}))"),
    }
}

fn luau_decode_expr(ty: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("read_list(bytes, off, M.decode_{inner})");
    }
    match ty {
        "u32" => "read_u32(bytes, off)".to_string(),
        "i32" => "read_i32(bytes, off)".to_string(),
        "i64" => "read_i64(bytes, off)".to_string(),
        "bool" => "read_bool(bytes, off)".to_string(),
        "str" | "bytes" => "read_bytes(bytes, off)".to_string(),
        "strmap" => "read_strmap(bytes, off)".to_string(),
        _ => format!("read_message(bytes, off, M.decode_{ty})"),
    }
}

/// Emit the resident-service client codec as ordinary Luau source. It deliberately uses only
/// string.byte/string.char/table.concat so the generated boundary works in AgentOS's bounded Luau
/// battery without host libraries or bit32. All integers exposed to syntax are <= u32 and therefore
/// exactly representable by Luau's number type.
fn emit_luau_messages(messages: &[Message]) -> String {
    if messages.is_empty() {
        return String::new();
    }
    let mut o = String::new();
    o.push_str(
        r#"local M = {}

local function byte(bytes, at)
  local v = string.byte(bytes, at)
  if v == nil then error("syntax wire: truncated frame", 3) end
  return v
end
local function put_u8(v) return string.char(v % 256) end
local function put_u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function put_u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function put_i32(v) if v < 0 then v = v + 4294967296 end return put_u32(v) end
local function put_i64(v)
  local lo = v % 4294967296
  local hi = math.floor(v / 4294967296)
  if hi < 0 then hi = hi + 4294967296 end
  return put_u32(lo) .. put_u32(hi)
end
local function put_bool(v) return put_u8(v and 1 or 0) end
local function put_bytes(v) return put_u32(#v) .. v end
local function put_strmap(values)
  local keys = {}
  for k in values do table.insert(keys, k) end
  table.sort(keys)
  local out = { put_u32(#keys) }
  for _, k in keys do table.insert(out, put_bytes(k)); table.insert(out, put_bytes(values[k])) end
  return table.concat(out)
end
local function put_list(values, encoder)
  local out = { put_u32(#values) }
  for _, value in values do table.insert(out, put_bytes(encoder(value))) end
  return table.concat(out)
end
local function need(bytes, off, n)
  if off + n - 1 > #bytes then error("syntax wire: truncated frame", 3) end
  return string.sub(bytes, off, off + n - 1), off + n
end
local function read_u8(bytes, off) return byte(bytes, off), off + 1 end
local function read_u16(bytes, off)
  return byte(bytes, off) + byte(bytes, off + 1) * 256, off + 2
end
local function read_u32(bytes, off)
  return byte(bytes, off) + byte(bytes, off + 1) * 256 + byte(bytes, off + 2) * 65536 + byte(bytes, off + 3) * 16777216, off + 4
end
local function read_i32(bytes, off)
  local v; v, off = read_u32(bytes, off)
  if v >= 2147483648 then v = v - 4294967296 end
  return v, off
end
local function read_i64(bytes, off)
  local lo, hi; lo, off = read_u32(bytes, off); hi, off = read_u32(bytes, off)
  local v = lo + hi * 4294967296
  if hi >= 2147483648 then v = v - 18446744073709551616 end
  return v, off
end
local function read_bool(bytes, off)
  local v; v, off = read_u8(bytes, off)
  if v ~= 0 and v ~= 1 then error("syntax wire: invalid bool", 3) end
  return v == 1, off
end
local function read_bytes(bytes, off)
  local n; n, off = read_u32(bytes, off)
  return need(bytes, off, n)
end
local function read_strmap(bytes, off)
  local n; n, off = read_u32(bytes, off)
  local out, prev = {}, nil
  for _ = 1, n do
    local k, v; k, off = read_bytes(bytes, off); v, off = read_bytes(bytes, off)
    if prev ~= nil and prev >= k then error("syntax wire: non-canonical map", 3) end
    out[k], prev = v, k
  end
  return out, off
end
local function read_message(bytes, off, decoder)
  local frame; frame, off = read_bytes(bytes, off)
  return decoder(frame), off
end
local function read_list(bytes, off, decoder)
  local n; n, off = read_u32(bytes, off)
  local out = {}
  for i = 1, n do out[i], off = read_message(bytes, off, decoder) end
  return out, off
end
local function header(bytes, expected)
  local id, off = read_u16(bytes, 1)
  local version
  version, off = read_u8(bytes, off)
  if id ~= expected then error("syntax wire: wrong message", 3) end
  if version ~= 1 then error("syntax wire: unsupported version", 3) end
  return off
end
local function finish(bytes, off)
  if off ~= #bytes + 1 then error("syntax wire: trailing bytes", 3) end
end

"#,
    );
    for m in messages {
        let prefix = screaming_snake(&m.name);
        o.push_str(&format!("M.{prefix}_MSG_ID = {}\n", m.id));
        o.push_str(&format!("M.{prefix}_VERSION = {}\n", m.version));
        o.push_str(&format!("function M.encode_{}(msg)\n  local out = {{ put_u16(M.{prefix}_MSG_ID), put_u8(M.{prefix}_VERSION)", m.name));
        for f in &m.fields {
            let expr = luau_encode_expr(&f.ty, &format!("msg.{}", f.name));
            if f.optional {
                o.push_str(&format!(
                    ", msg.{0} == nil and put_u8(0) or (put_u8(1) .. {expr})",
                    f.name
                ));
            } else {
                o.push_str(&format!(", {expr}"));
            }
        }
        o.push_str(" }\n  return table.concat(out)\nend\n");
        o.push_str(&format!("function M.decode_{}(bytes)\n  local off = header(bytes, M.{prefix}_MSG_ID)\n  local out = {{}}\n", m.name));
        for f in &m.fields {
            let expr = luau_decode_expr(&f.ty);
            if f.optional {
                o.push_str(&format!("  local has_{0}; has_{0}, off = read_u8(bytes, off)\n  if has_{0} == 1 then out.{0}, off = {expr} elseif has_{0} ~= 0 then error(\"syntax wire: invalid optional\", 2) end\n", f.name));
            } else {
                o.push_str(&format!("  out.{}, off = {expr}\n", f.name));
            }
        }
        o.push_str("  finish(bytes, off)\n  return out\nend\n\n");
    }
    o.push_str("return M\n");
    o
}

fn emit_zig_codec_field_put(o: &mut String, f: &MessageField, expr: &str) {
    if let Some(inner) = list_inner(&f.ty) {
        o.push_str(&format!(
            "        try ctlPutMessageList({}, &out, allocator, {expr});\n",
            inner
        ));
        return;
    }
    match f.ty.as_str() {
        "u32" => o.push_str(&format!("        try ctlPutU32(&out, allocator, {expr});\n")),
        "i32" => o.push_str(&format!("        try ctlPutI32(&out, allocator, {expr});\n")),
        "i64" => o.push_str(&format!("        try ctlPutI64(&out, allocator, {expr});\n")),
        "bool" => o.push_str(&format!("        try ctlPutBool(&out, allocator, {expr});\n")),
        "str" | "bytes" => o.push_str(&format!("        try ctlPutBytes(&out, allocator, {expr});\n")),
        "strmap" => o.push_str(&format!("        try ctlPutStrMap(&out, allocator, {expr});\n")),
        _ => o.push_str(&format!(
            "        {{\n            const frame = try {expr}.encode(allocator);\n            defer allocator.free(frame);\n            try ctlPutBytes(&out, allocator, frame);\n        }}\n"
        )),
    }
}

fn zig_decode_expr(ty: &str) -> String {
    if let Some(inner) = list_inner(ty) {
        return format!("try ctlReadMessageList({inner}, allocator, bytes, &off)");
    }
    match ty {
        "u32" => "try ctlReadU32(bytes, &off)".to_string(),
        "i32" => "try ctlReadI32(bytes, &off)".to_string(),
        "i64" => "try ctlReadI64(bytes, &off)".to_string(),
        "bool" => "try ctlReadBool(bytes, &off)".to_string(),
        "str" => "try ctlReadStr(bytes, &off)".to_string(),
        "bytes" => "try ctlReadBytes(bytes, &off)".to_string(),
        "strmap" => "try ctlReadStrMap(allocator, bytes, &off)".to_string(),
        _ => format!("try {ty}.decode(allocator, try ctlReadBytes(bytes, &off))"),
    }
}

fn emit_zig_messages(messages: &[Message]) -> String {
    if messages.is_empty() {
        return String::new();
    }
    let mut o = String::new();
    o.push_str("\nconst std = @import(\"std\");\n");
    o.push_str("pub const WireError = error{ WrongMessage, UnsupportedVersion, Truncated, InvalidUtf8, NonCanonicalMap, InvalidPresence, TrailingBytes };\n");
    o.push_str("pub const StringPair = struct { key: []const u8, value: []const u8 };\n\n");
    o.push_str("fn ctlPutU8(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u8) !void { try out.append(allocator, v); }\n");
    o.push_str("fn ctlPutU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void { try out.append(allocator, @as(u8, @truncate(v))); try out.append(allocator, @as(u8, @truncate(v >> 8))); }\n");
    o.push_str("fn ctlPutU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void { try out.append(allocator, @as(u8, @truncate(v))); try out.append(allocator, @as(u8, @truncate(v >> 8))); try out.append(allocator, @as(u8, @truncate(v >> 16))); try out.append(allocator, @as(u8, @truncate(v >> 24))); }\n");
    o.push_str("fn ctlPutU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void { var i: u6 = 0; while (i < 8) : (i += 1) try out.append(allocator, @as(u8, @truncate(v >> (i * 8)))); }\n");
    o.push_str("fn ctlPutI32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i32) !void { try ctlPutU32(out, allocator, @as(u32, @bitCast(v))); }\n");
    o.push_str("fn ctlPutI64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i64) !void { try ctlPutU64(out, allocator, @as(u64, @bitCast(v))); }\n");
    o.push_str("fn ctlPutBool(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: bool) !void { try ctlPutU8(out, allocator, if (v) 1 else 0); }\n");
    o.push_str("fn ctlPutBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: []const u8) !void { try ctlPutU32(out, allocator, @intCast(v.len)); try out.appendSlice(allocator, v); }\n");
    o.push_str("fn ctlPairLess(_: void, a: StringPair, b: StringPair) bool { return std.mem.lessThan(u8, a.key, b.key); }\n");
    o.push_str("fn ctlPutStrMap(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: []const StringPair) !void { const pairs = try allocator.dupe(StringPair, v); defer allocator.free(pairs); std.mem.sort(StringPair, pairs, {}, ctlPairLess); try ctlPutU32(out, allocator, @intCast(pairs.len)); var prev: ?[]const u8 = null; for (pairs) |p| { if (prev) |last| { if (std.mem.eql(u8, last, p.key)) return WireError.NonCanonicalMap; } try ctlPutBytes(out, allocator, p.key); try ctlPutBytes(out, allocator, p.value); prev = p.key; } }\n");
    o.push_str("fn ctlPutMessageList(comptime T: type, out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const T) !void { try ctlPutU32(out, allocator, @intCast(values.len)); for (values) |value| { const frame = try value.encode(allocator); defer allocator.free(frame); try ctlPutBytes(out, allocator, frame); } }\n");
    o.push_str("fn ctlNeed(bytes: []const u8, off: *usize, len: usize) WireError![]const u8 { const end = off.* + len; if (end < off.* or end > bytes.len) return WireError.Truncated; const out = bytes[off.*..end]; off.* = end; return out; }\n");
    o.push_str("fn ctlReadU8(bytes: []const u8, off: *usize) WireError!u8 { return (try ctlNeed(bytes, off, 1))[0]; }\n");
    o.push_str("fn ctlReadU16(bytes: []const u8, off: *usize) WireError!u16 { const b = try ctlNeed(bytes, off, 2); return @as(u16, b[0]) | (@as(u16, b[1]) << 8); }\n");
    o.push_str("fn ctlReadU32(bytes: []const u8, off: *usize) WireError!u32 { const b = try ctlNeed(bytes, off, 4); return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24); }\n");
    o.push_str("fn ctlReadU64(bytes: []const u8, off: *usize) WireError!u64 { const b = try ctlNeed(bytes, off, 8); var out: u64 = 0; var i: u6 = 0; while (i < 8) : (i += 1) out |= @as(u64, b[i]) << (i * 8); return out; }\n");
    o.push_str("fn ctlReadI32(bytes: []const u8, off: *usize) WireError!i32 { return @as(i32, @bitCast(try ctlReadU32(bytes, off))); }\n");
    o.push_str("fn ctlReadI64(bytes: []const u8, off: *usize) WireError!i64 { return @as(i64, @bitCast(try ctlReadU64(bytes, off))); }\n");
    o.push_str("fn ctlReadBool(bytes: []const u8, off: *usize) WireError!bool { return switch (try ctlReadU8(bytes, off)) { 0 => false, 1 => true, else => WireError.InvalidPresence }; }\n");
    o.push_str("fn ctlReadBytes(bytes: []const u8, off: *usize) WireError![]const u8 { const len = try ctlReadU32(bytes, off); return ctlNeed(bytes, off, @intCast(len)); }\n");
    o.push_str("fn ctlReadStr(bytes: []const u8, off: *usize) WireError![]const u8 { const out = try ctlReadBytes(bytes, off); _ = std.unicode.Utf8View.init(out) catch return WireError.InvalidUtf8; return out; }\n");
    o.push_str("fn ctlReadStrMap(allocator: std.mem.Allocator, bytes: []const u8, off: *usize) ![]const StringPair { const n = try ctlReadU32(bytes, off); var out = try allocator.alloc(StringPair, @intCast(n)); errdefer allocator.free(out); var prev: ?[]const u8 = null; var i: usize = 0; while (i < out.len) : (i += 1) { const k = try ctlReadStr(bytes, off); if (prev) |last| { if (!std.mem.lessThan(u8, last, k)) return WireError.NonCanonicalMap; } const v = try ctlReadStr(bytes, off); out[i] = .{ .key = k, .value = v }; prev = k; } return out; }\n\n");
    o.push_str("fn ctlReadMessageList(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8, off: *usize) ![]const T { const n = try ctlReadU32(bytes, off); var out = try allocator.alloc(T, @intCast(n)); errdefer allocator.free(out); var i: usize = 0; while (i < out.len) : (i += 1) out[i] = try T.decode(allocator, try ctlReadBytes(bytes, off)); return out; }\n\n");

    for m in messages {
        let const_prefix = screaming_snake(&m.name);
        if !m.doc.is_empty() {
            o.push_str(&format!("// {}\n", m.doc));
        }
        o.push_str(&format!(
            "pub const {const_prefix}_MSG_ID: u16 = {};\n",
            m.id
        ));
        o.push_str(&format!(
            "pub const {const_prefix}_VERSION: u8 = {};\n",
            m.version
        ));
        o.push_str(&format!("pub const {} = struct {{\n", m.name));
        for f in &m.fields {
            let ty = zig_type(&f.ty);
            let field = zig_ident(&f.name);
            if f.optional {
                o.push_str(&format!("    {field}: ?{} = null,\n", ty));
            } else {
                o.push_str(&format!("    {field}: {},\n", ty));
            }
        }
        o.push_str("\n    pub fn encode(self: @This(), allocator: std.mem.Allocator) ![]u8 {\n");
        o.push_str("        var out: std.ArrayList(u8) = .empty;\n        errdefer out.deinit(allocator);\n");
        o.push_str(&format!(
            "        try ctlPutU16(&out, allocator, {const_prefix}_MSG_ID);\n"
        ));
        o.push_str(&format!(
            "        try ctlPutU8(&out, allocator, {const_prefix}_VERSION);\n"
        ));
        for f in &m.fields {
            let field = zig_ident(&f.name);
            if f.optional {
                o.push_str(&format!(
                    "        if (self.{field}) |v| {{\n            try ctlPutU8(&out, allocator, 1);\n"
                ));
                emit_zig_codec_field_put(&mut o, f, "v");
                o.push_str(
                    "        } else {\n            try ctlPutU8(&out, allocator, 0);\n        }\n",
                );
            } else {
                emit_zig_codec_field_put(&mut o, f, &format!("self.{field}"));
            }
        }
        o.push_str("        return out.toOwnedSlice(allocator);\n    }\n\n");
        o.push_str(
            "    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !@This() {\n",
        );
        let decode_uses_allocator = m.fields.iter().any(|f| {
            list_inner(&f.ty).is_some()
                || f.ty == "strmap"
                || !matches!(
                    f.ty.as_str(),
                    "u32" | "i32" | "i64" | "bool" | "str" | "bytes"
                )
        });
        if !decode_uses_allocator {
            o.push_str("        _ = allocator;\n");
        }
        o.push_str("        var off: usize = 0;\n");
        o.push_str(&format!("        if ((try ctlReadU16(bytes, &off)) != {const_prefix}_MSG_ID) return WireError.WrongMessage;\n"));
        o.push_str(&format!("        if ((try ctlReadU8(bytes, &off)) != {const_prefix}_VERSION) return WireError.UnsupportedVersion;\n"));
        for f in &m.fields {
            let local = zig_local(&f.name);
            if f.optional {
                o.push_str(&format!("        const {local} = switch (try ctlReadU8(bytes, &off)) {{\n            0 => null,\n            1 => {},\n            else => return WireError.InvalidPresence,\n        }};\n", zig_decode_expr(&f.ty)));
            } else {
                o.push_str(&format!(
                    "        const {local} = {};\n",
                    zig_decode_expr(&f.ty)
                ));
            }
        }
        o.push_str("        if (off != bytes.len) return WireError.TrailingBytes;\n");
        o.push_str("        return .{\n");
        for f in &m.fields {
            o.push_str(&format!(
                "            .{} = {},\n",
                zig_ident(&f.name),
                zig_local(&f.name)
            ));
        }
        o.push_str("        };\n    }\n};\n\n");
    }
    o
}

fn zig_syscall_storage_ty(ty: &str) -> &str {
    match ty {
        "u32" => "u32",
        "i32" => "i32",
        other => panic!("unsupported Zig syscall storage type {other}"),
    }
}

fn zig_syscall_raw_arg(ty: &str, idx: usize) -> String {
    match ty {
        "u32" => format!("rawArgU32(sp, {idx})"),
        "i32" => format!("rawArgI32(sp, {idx})"),
        other => panic!("unsupported Zig raw syscall arg type {other}"),
    }
}

fn wasm3_type_char(ty: &str, is_ret: bool) -> char {
    match ty {
        "u32" | "i32" => 'i',
        "u64" | "i64" => 'I',
        "void" => 'v',
        // mc_sys_exit is noreturn in the syscall contract, but the wasm import
        // still type-checks as an i32-returning function.
        "noreturn" if is_ret => 'i',
        other => panic!("unsupported wasm3 ABI type {other}"),
    }
}

fn wasm3_signature(row: &Row) -> String {
    let ret = wasm3_type_char(&row.ret, true);
    let args = row
        .args
        .iter()
        .map(|(_, ty)| wasm3_type_char(ty, false))
        .collect::<String>();
    format!("{ret}({args})")
}

fn emit_zig_syscall_types(rows: &[Row]) -> String {
    let mut o = String::new();
    o.push_str("\npub const Syscall = enum {\n");
    for r in rows {
        o.push_str(&format!("    {},\n", r.variant));
    }
    o.push_str("};\n\n");

    for r in rows {
        o.push_str(&format!("pub const {}Args = struct {{\n", r.variant));
        for (name, ty) in &r.args {
            o.push_str(&format!("    {name}: {},\n", zig_syscall_storage_ty(ty),));
        }
        o.push_str("};\n\n");
    }

    o.push_str("pub const Pending = union(Syscall) {\n");
    for r in rows {
        o.push_str(&format!("    {}: {}Args,\n", r.variant, r.variant));
    }
    o.push_str("};\n\n");

    o.push_str(
        "inline fn rawArgU32(sp: [*]const u64, idx: usize) u32 {\n    return @truncate(sp[idx]);\n}\n\n",
    );
    o.push_str(
        "inline fn rawArgI32(sp: [*]const u64, idx: usize) i32 {\n    return @bitCast(rawArgU32(sp, idx));\n}\n\n",
    );
    o.push_str("pub fn pendingFromRaw(desc: *const Desc, sp: [*]const u64) ?Pending {\n");
    for (idx, r) in rows.iter().enumerate() {
        o.push_str(&format!(
            "    if (desc == &SYSCALLS[{idx}]) return Pending{{ .{} = .{{",
            r.variant
        ));
        if r.args.is_empty() {
            o.push_str(" } };\n");
            continue;
        }
        o.push('\n');
        for (i, (name, ty)) in r.args.iter().enumerate() {
            o.push_str(&format!(
                "        .{name} = {},\n",
                zig_syscall_raw_arg(ty, i + 1),
            ));
        }
        o.push_str("    } };\n");
    }
    o.push_str("    return null;\n}\n");
    o
}

/// Emit the callable guest-side `mc` import block: `pub extern "mc" fn mc_sys_<name>(...) i32;`
/// for every syscall. This is the Zig counterpart of the Rust `mc_syscall_table!` extern
/// expansion — the sysroot re-exports it so a Zig guest imports EXACTLY the kernel's served
/// surface (and only the subset it references; an unused extern is dropped by the linker, so no
/// spurious wasm import). Unlike the descriptor tables above these are CONCRETE decls, because
/// Zig comptime cannot synthesize `extern fn` signatures — which is exactly why a hand-kept
/// mc.zig + an mc-abi-gate used to be needed and are now gone. The kernel imports this same file
/// for the descriptor tables and never references the externs, so they never become a real
/// `mc` import there.
fn emit_zig_syscall_externs(rows: &[Row]) -> String {
    let mut o = String::new();
    o.push_str(
        "\n// The guest-side `mc` import block: every syscall the kernel serves, callable as\n\
         // `mc.mc_sys_<name>(...)`. wasm32 — pointer/length args are u32 offsets into the guest's\n\
         // own linear memory; each returns i32 (0 / negative errno).\n",
    );
    for r in rows {
        let args = r
            .args
            .iter()
            .map(|(n, t)| format!("{n}: {}", zig_extern_arg_ty(t)))
            .collect::<Vec<_>>()
            .join(", ");
        // The contract marks mc_sys_exit `noreturn`, but the kernel registers the wasm import as
        // (…)->i32 like every other syscall; declaring it `noreturn` here would change the import
        // TYPE and the kernel would reject the guest at spawn. So every extern returns i32 (an
        // exit call is simply unreachable at the call site).
        let note = if r.ret == "noreturn" {
            "  // contract: noreturn; the kernel serves it as (…)->i32"
        } else {
            assert_eq!(
                r.ret, "i32",
                "unsupported Zig extern ret type {} for {}",
                r.ret, r.name
            );
            ""
        };
        o.push_str(&format!(
            "pub extern \"mc\" fn {}({args}) i32;{note}\n",
            r.name
        ));
    }
    o
}

fn zig_extern_arg_ty(ty: &str) -> &str {
    match ty {
        "u32" => "u32",
        "i32" => "i32",
        other => panic!("unsupported Zig extern arg type {other}"),
    }
}

/// Emit a table boundary (mc / env / ctl) for one language. `macro_name` is the Rust
/// callback macro; `names_const` is the `&[&str]` symbol array.
fn emit_table(
    lang: &str,
    contract: &str,
    rows: &[Row],
    messages: &[Message],
    macro_name: &str,
    names_const: &str,
    table_const: &str,
) -> String {
    let mut o = banner(lang, contract);
    match lang {
        "rust" => {
            o.push_str(&emit_rust_messages(messages));
            o.push_str(&format!("\npub const {names_const}: &[&str] = &[\n"));
            for r in rows {
                o.push_str(&format!("    \"{}\",\n", r.name));
            }
            o.push_str("];\n\n");
            o.push_str("/// The canonical table. A consumer hands its own `$emit!` callback (the kernel's\n");
            o.push_str("/// dispatch, the sysroot's extern block, the host's import table) and cannot drift.\n");
            o.push_str("#[macro_export]\n");
            o.push_str(&format!(
                "macro_rules! {macro_name} {{\n    ($emit:path) => {{ $emit! {{\n"
            ));
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
            o.push_str(&emit_zig_messages(messages));
            o.push_str("\npub const Arg = struct { name: []const u8, ty: []const u8 };\n");
            if table_const == "SYSCALLS" {
                o.push_str("pub const Desc = struct { name: [:0]const u8, variant: []const u8, args: []const Arg, ret: []const u8, signature: [:0]const u8 };\n\n");
            } else {
                o.push_str("pub const Desc = struct { name: []const u8, variant: []const u8, args: []const Arg, ret: []const u8 };\n\n");
            }
            o.push_str(&format!("pub const {table_const} = [_]Desc{{\n"));
            for r in rows {
                let args = r
                    .args
                    .iter()
                    .map(|(n, t)| format!(".{{ .name = \"{n}\", .ty = \"{t}\" }}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                if table_const == "SYSCALLS" {
                    o.push_str(&format!(
                        "    .{{ .name = \"{}\", .variant = \"{}\", .args = &.{{ {} }}, .ret = \"{}\", .signature = \"{}\" }},\n",
                        r.name,
                        r.variant,
                        args,
                        r.ret,
                        wasm3_signature(r)
                    ));
                } else {
                    o.push_str(&format!(
                        "    .{{ .name = \"{}\", .variant = \"{}\", .args = &.{{ {} }}, .ret = \"{}\" }},\n",
                        r.name, r.variant, args, r.ret
                    ));
                }
            }
            o.push_str("};\n");
            if table_const == "SYSCALLS" {
                o.push_str(&emit_zig_syscall_types(rows));
                o.push_str(&emit_zig_syscall_externs(rows));
                // The guest-side pointer helper — the one bit of Zig `mc` ABI comfort that isn't
                // per-syscall. Emitted here (not hand-kept) so a guest `@import("mc")` is the WHOLE
                // generated boundary with nothing to maintain by hand (Zig 0.16 dropped
                // `usingnamespace`, so a re-export skin would have to list every decl).
                o.push_str(
                    "\n/// A Zig pointer as a wasm linear-memory address (the u32 the mc ABI takes).\n\
                     pub inline fn addr(p: anytype) u32 {\n    return @intCast(@intFromPtr(p));\n}\n",
                );
            }
        }
        "ts" => {
            o.push_str(&emit_ts_messages(messages));
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
        "elixir" => {
            o.push_str(&emit_elixir_messages(messages, contract));
        }
        "md" => {
            o = format!(
                "<!-- {} -->\n",
                banner("md", contract).trim_start_matches("// ")
            );
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

/// Emit a message-codec-only module. `llb.kdl` has no operation table; it is the portable
/// canonical data shape used by the build solver and the future server solver.
fn emit_codec_module(lang: &str, nodes: &[Node], contract: &str) -> String {
    let messages = collect_codec_messages(nodes);
    let mut o = banner(lang, contract);
    let vocabulary = emit_vocabulary_constants(lang, nodes);
    match lang {
        "rust" => {
            let messages = emit_rust_messages(&messages);
            let inner = "#![allow(dead_code)]\n\n";
            o.push_str(inner);
            o.push_str(&vocabulary);
            o.push_str(messages.strip_prefix(inner).unwrap_or(&messages));
        }
        "zig" => {
            o.push_str(&vocabulary);
            o.push_str(&emit_zig_messages(&messages));
        }
        "ts" => o.push_str(&emit_ts_messages(&messages)),
        "elixir" => o.push_str(&emit_elixir_messages(&messages, contract)),
        "luau" => {
            let body = emit_luau_messages(&messages);
            o.push_str(&body.replacen(
                "local M = {}\n",
                &format!("local M = {{}}\n{vocabulary}"),
                1,
            ));
        }
        _ => o.push_str(&format!("// codec projection is not defined for {lang}\n")),
    }
    o.truncate(o.trim_end().len());
    o.push('\n');
    o
}

fn emit_vocabulary_constants(lang: &str, nodes: &[Node]) -> String {
    let mut out = String::new();
    for node in nodes {
        let (prefix, is_version) = match node.name.as_str() {
            "protocol-version" => ("PROTOCOL_VERSION".to_string(), true),
            "vocabulary-version" => ("VOCABULARY_VERSION".to_string(), true),
            "grammar-ir-version" => ("GRAMMAR_IR_VERSION".to_string(), true),
            "semantic-kind" => (
                format!(
                    "SEMANTIC_KIND_{}",
                    node.arg_str(0).to_ascii_uppercase().replace('-', "_")
                ),
                false,
            ),
            "semantic-role" => (
                format!(
                    "SEMANTIC_ROLE_{}",
                    node.arg_str(0).to_ascii_uppercase().replace('-', "_")
                ),
                false,
            ),
            "semantic-trait" => (
                format!(
                    "SEMANTIC_TRAIT_{}",
                    node.arg_str(0).to_ascii_uppercase().replace('-', "_")
                ),
                false,
            ),
            _ => continue,
        };
        let value = if is_version {
            node.args.first().map(Val::as_int).unwrap_or(0)
        } else {
            node.props.get("id").map(Val::as_int).unwrap_or(0)
        };
        match lang {
            "rust" => out.push_str(&format!("pub const {prefix}: u32 = {value};\n")),
            "zig" => out.push_str(&format!("pub const {prefix}: u32 = {value};\n")),
            "luau" => out.push_str(&format!("M.{prefix} = {value}\n")),
            _ => {}
        }
    }
    if !out.is_empty() {
        if lang == "rust" {
            out.push_str(&emit_rust_vocabulary_descriptors(nodes));
        }
        out.push('\n');
    }
    out
}

fn rust_vocabulary_ident(value: &str) -> String {
    value.to_ascii_uppercase().replace('-', "_")
}

/// Host generators must consume the same parsed contract model as every runtime projection. The
/// constants above are sufficient for wire users; these compact descriptors additionally retain
/// the semantic constraints that `mc-grammar-gen` validates while elaborating an owned grammar.
fn emit_rust_vocabulary_descriptors(nodes: &[Node]) -> String {
    let roles = nodes
        .iter()
        .filter(|node| node.name == "semantic-role")
        .map(|node| {
            (
                node.arg_str(0),
                node.props.get("id").map(Val::as_int).unwrap_or(0),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let traits = nodes
        .iter()
        .filter(|node| node.name == "semantic-trait")
        .map(|node| {
            (
                node.arg_str(0),
                node.props.get("id").map(Val::as_int).unwrap_or(0),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let kinds = nodes
        .iter()
        .filter(|node| node.name == "semantic-kind")
        .collect::<Vec<_>>();
    if kinds.is_empty() {
        return String::new();
    }

    let mut out = String::from(
        "\n#[derive(Clone, Copy, Debug, Eq, PartialEq)]\n\
         pub struct SemanticRoleSpec { pub name: &'static str, pub id: u32, pub required: bool }\n\
         #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n\
         pub struct SemanticTraitSpec { pub name: &'static str, pub id: u32 }\n\
         #[derive(Clone, Copy, Debug, Eq, PartialEq)]\n\
         pub struct SemanticKindSpec {\n\
         \x20   pub name: &'static str,\n\
         \x20   pub id: u32,\n\
         \x20   pub roles: &'static [SemanticRoleSpec],\n\
         \x20   pub traits: &'static [SemanticTraitSpec],\n\
         }\n",
    );

    for kind in &kinds {
        let ident = rust_vocabulary_ident(kind.arg_str(0));
        out.push_str(&format!(
            "const SEMANTIC_KIND_{ident}_ROLES: &[SemanticRoleSpec] = &[\n"
        ));
        for role in kind.children_named("role") {
            let name = role.arg_str(0);
            let id = roles.get(name).copied().unwrap_or(0);
            let required = role.props.get("required").map(Val::as_int).unwrap_or(0) != 0;
            out.push_str(&format!(
                "    SemanticRoleSpec {{ name: \"{name}\", id: {id}, required: {required} }},\n"
            ));
        }
        out.push_str("];\n");
        out.push_str(&format!(
            "const SEMANTIC_KIND_{ident}_TRAITS: &[SemanticTraitSpec] = &[\n"
        ));
        for semantic_trait in kind.children_named("trait") {
            let name = semantic_trait.arg_str(0);
            let id = traits.get(name).copied().unwrap_or(0);
            out.push_str(&format!(
                "    SemanticTraitSpec {{ name: \"{name}\", id: {id} }},\n"
            ));
        }
        out.push_str("];\n");
    }

    out.push_str("pub const SEMANTIC_KINDS: &[SemanticKindSpec] = &[\n");
    for kind in &kinds {
        let name = kind.arg_str(0);
        let ident = rust_vocabulary_ident(name);
        let id = kind.props.get("id").map(Val::as_int).unwrap_or(0);
        out.push_str(&format!(
            "    SemanticKindSpec {{ name: \"{name}\", id: {id}, roles: SEMANTIC_KIND_{ident}_ROLES, traits: SEMANTIC_KIND_{ident}_TRAITS }},\n"
        ));
    }
    out.push_str("];\n");
    out
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

#[derive(Clone)]
struct Field {
    name: String,
    ty: String,
    required: bool,
    source: Option<String>,
    encoding: Option<String>,
}

#[derive(Clone)]
struct ProjectField {
    name: String,
    from: String,
    ty: Option<String>,
    required: Option<bool>,
    encoding: Option<String>,
}

struct Schema {
    name: String,
    kind: String,
    doc: String,
    source: Option<String>,
    from_message: Option<String>,
    projects: Vec<ProjectField>,
    fields: Vec<Field>,
}

fn prop_bool(n: &Node, key: &str, default: bool) -> bool {
    match n.props.get(key) {
        Some(Val::Int(i)) => *i != 0,
        Some(Val::Str(s)) => matches!(s.as_str(), "1" | "true" | "yes"),
        None => default,
    }
}

fn prop_bool_opt(n: &Node, key: &str) -> Option<bool> {
    n.props.get(key).map(|_| prop_bool(n, key, false))
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
            source: n.prop_str("source").map(String::from),
            from_message: n.prop_str("from-message").map(String::from),
            projects: n
                .children_named("project")
                .map(|p| ProjectField {
                    name: p.arg_str(0).to_string(),
                    from: p
                        .prop_str("from")
                        .map(String::from)
                        .unwrap_or_else(|| p.arg_str(0).to_string()),
                    ty: p.prop_str("type").map(String::from),
                    required: prop_bool_opt(p, "required"),
                    encoding: p.prop_str("encoding").map(String::from),
                })
                .collect(),
            fields: n
                .children_named("field")
                .map(|f| Field {
                    name: f.arg_str(0).to_string(),
                    ty: f.prop_str("type").unwrap_or("string").to_string(),
                    required: prop_bool(f, "required", false),
                    source: None,
                    encoding: None,
                })
                .collect(),
        })
        .collect()
}

fn message_field_schema_type(ty: &str) -> Option<String> {
    if let Some(inner) = ty.strip_prefix("list<").and_then(|s| s.strip_suffix('>')) {
        return Some(format!("{}[]", inner));
    }
    match ty {
        "str" => Some("string".to_string()),
        "strmap" => Some("StringMap".to_string()),
        // Binary message fields need an explicit JSON projection (`stdin` vs.
        // `stdinBase64`) instead of a default one-size-fits-all REST shape.
        "bytes" => None,
        "bool" | "u32" | "i32" | "u64" | "i64" => Some(ty.to_string()),
        other => Some(other.to_string()),
    }
}

fn schema_source_messages(nodes: &[Node], contract_path: &str, schemas: &[Schema]) -> Vec<Message> {
    let mut messages = collect_codec_messages(nodes);
    let mut seen_sources = BTreeSet::new();
    let contract_dir = std::path::Path::new(contract_path)
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."));

    for schema in schemas {
        let Some(source) = &schema.source else {
            continue;
        };
        if !seen_sources.insert(source.clone()) {
            continue;
        }
        let source_path = contract_dir.join(source);
        let src = std::fs::read_to_string(&source_path).unwrap_or_else(|e| {
            panic!(
                "projector: schema {} source {} could not be read: {e}",
                schema.name,
                source_path.display()
            )
        });
        messages.extend(collect_codec_messages(&parse(&tokenize(&src))));
    }

    messages
}

fn resolve_schema_fields(schema: &Schema, messages: &BTreeMap<String, Message>) -> Vec<Field> {
    let Some(message_name) = &schema.from_message else {
        return schema.fields.clone();
    };
    let message = messages.get(message_name).unwrap_or_else(|| {
        panic!(
            "schema {} derives from unknown message {}",
            schema.name, message_name
        )
    });

    let mut out = Vec::new();
    let mut used_projects = vec![false; schema.projects.len()];
    let mut seen_names = BTreeSet::new();

    for mf in &message.fields {
        let matching = schema
            .projects
            .iter()
            .enumerate()
            .filter(|(_, p)| p.from == mf.name)
            .collect::<Vec<_>>();

        if matching.is_empty() {
            if let Some(ty) = message_field_schema_type(&mf.ty) {
                if !seen_names.insert(mf.name.clone()) {
                    panic!("schema {} has duplicate field {}", schema.name, mf.name);
                }
                out.push(Field {
                    name: mf.name.clone(),
                    ty,
                    required: !mf.optional,
                    source: Some(mf.name.clone()),
                    encoding: None,
                });
            }
            continue;
        }

        for (idx, project) in matching {
            used_projects[idx] = true;
            let ty = project
                .ty
                .clone()
                .or_else(|| message_field_schema_type(&mf.ty))
                .unwrap_or_else(|| {
                    panic!(
                        "schema {} project {} from binary field {} must declare type",
                        schema.name, project.name, mf.name
                    )
                });
            if !seen_names.insert(project.name.clone()) {
                panic!(
                    "schema {} has duplicate field {}",
                    schema.name, project.name
                );
            }
            out.push(Field {
                name: project.name.clone(),
                ty,
                required: project.required.unwrap_or(!mf.optional),
                source: Some(mf.name.clone()),
                encoding: project.encoding.clone(),
            });
        }
    }

    for (idx, project) in schema.projects.iter().enumerate() {
        if !used_projects[idx] {
            panic!(
                "schema {} projects unknown source field {} from message {}",
                schema.name, project.from, message_name
            );
        }
    }

    for field in &schema.fields {
        if !seen_names.insert(field.name.clone()) {
            panic!(
                "schema {} locally redeclares projected field {}",
                schema.name, field.name
            );
        }
        out.push(field.clone());
    }

    out
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

fn emit_openapi_schema_for_type(
    out: &mut String,
    ty: &str,
    indent: usize,
    schema_names: &BTreeSet<String>,
) {
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
        out.push_str(&format!(
            "          required: {}\n",
            if query.required { "true" } else { "false" }
        ));
        out.push_str("          schema:\n");
        emit_openapi_schema_for_type(out, &query.ty, 12, schema_names);
    }
}

fn emit_openapi(nodes: &[Node], contract: &str, contract_path: &str) -> String {
    let version = nodes
        .iter()
        .find(|n| n.name == "version")
        .map(|n| n.args.first().map(Val::as_int).unwrap_or(0))
        .unwrap_or(0);
    let routes = collect_routes(nodes);
    let schemas = collect_schemas(nodes);
    let messages: BTreeMap<String, Message> =
        schema_source_messages(nodes, contract_path, &schemas)
            .into_iter()
            .map(|m| (m.name.clone(), m))
            .collect();
    let resolved_fields: BTreeMap<String, Vec<Field>> = schemas
        .iter()
        .map(|schema| {
            (
                schema.name.clone(),
                resolve_schema_fields(schema, &messages),
            )
        })
        .collect();
    let schema_names: BTreeSet<String> = schemas.iter().map(|s| s.name.clone()).collect();
    let schema_kinds: BTreeMap<String, String> = schemas
        .iter()
        .map(|s| (s.name.clone(), s.kind.clone()))
        .collect();
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
    out.push_str(&format!(
        "  version: {}\n",
        yaml_quote(&version.to_string())
    ));
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
            out.push_str(&format!(
                "      operationId: {}\n",
                yaml_quote(&operation_id(&route.method, &route.path))
            ));
            if !route.doc.is_empty() {
                out.push_str(&format!("      summary: {}\n", yaml_quote(&route.doc)));
            }
            if let Some(protocol) = &route.protocol {
                out.push_str(&format!(
                    "      x-agentos-protocol: {}\n",
                    yaml_quote(protocol)
                ));
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
            let description = if status == "101" {
                "Switching protocols"
            } else {
                "OK"
            };
            out.push_str(&format!(
                "          description: {}\n",
                yaml_quote(description)
            ));
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
        let fields = resolved_fields
            .get(&schema.name)
            .expect("schema fields resolved above");
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
                let required = fields.iter().filter(|f| f.required).collect::<Vec<_>>();
                if !required.is_empty() {
                    out.push_str("      required:\n");
                    for field in required {
                        out.push_str(&format!("        - {}\n", yaml_quote(&field.name)));
                    }
                }
                out.push_str("      properties:\n");
                if fields.is_empty() {
                    out.push_str("        {}\n");
                }
                for field in fields {
                    out.push_str(&format!("        {}:\n", yaml_quote(&field.name)));
                    emit_openapi_schema_for_type(&mut out, &field.ty, 10, &schema_names);
                    if let Some(source) = &field.source {
                        out.push_str(&format!(
                            "          x-agentos-source-field: {}\n",
                            yaml_quote(source)
                        ));
                    }
                    if let Some(encoding) = &field.encoding {
                        out.push_str(&format!(
                            "          x-agentos-encoding: {}\n",
                            yaml_quote(encoding)
                        ));
                    }
                }
            }
        }
    }
    out
}

fn emit_wire(lang: &str, nodes: &[Node], contract: &str, contract_path: &str) -> String {
    if lang == "openapi" {
        return emit_openapi(nodes, contract, contract_path);
    }
    let version = nodes
        .iter()
        .find(|n| n.name == "version")
        .map(|n| n.args.first().map(Val::as_int).unwrap_or(0))
        .unwrap_or(0);
    let header_len = nodes
        .iter()
        .find(|n| n.name == "header-len")
        .map(|n| n.args.first().map(Val::as_int).unwrap_or(0))
        .unwrap_or(0);
    let msgs: Vec<&Node> = nodes.iter().filter(|n| n.name == "message").collect();
    let mut o = banner(lang, contract);
    match lang {
        "rust" => {
            o.push_str(&format!("\npub const WIRE_VERSION: u32 = {version};\npub const HEADER_LEN: usize = {header_len};\n\n"));
            for m in &msgs {
                let tag = m.props.get("tag").map(Val::as_int).unwrap_or(0);
                o.push_str(&format!(
                    "pub const {}: u8 = 0x{:02x};\n",
                    m.arg_str(0),
                    tag
                ));
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
                    m.arg_str(0),
                    tag,
                    m.prop_str("dir").unwrap_or(""),
                    m.prop_str("body").unwrap_or("")
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
                o.push_str(&format!(
                    "        x-tag: {}\n",
                    m.props.get("tag").map(Val::as_int).unwrap_or(0)
                ));
                o.push_str(&format!(
                    "        x-direction: \"{}\"\n",
                    m.prop_str("dir").unwrap_or("")
                ));
                o.push_str(&format!(
                    "        x-body: \"{}\"\n",
                    m.prop_str("body").unwrap_or("")
                ));
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
        eprintln!(
            "usage: projector --module <constants|mc|env|ctl|wire|llb|syntax> --lang <rust|zig|ts|elixir|luau|md|asyncapi|openapi> --contract <path.kdl>"
        );
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
        "mc" => emit_table(
            &lang,
            &file,
            &collect_rows(&nodes, "syscall"),
            &collect_codec_messages(&nodes),
            "mc_syscall_table",
            "SYSCALL_NAMES",
            "SYSCALLS",
        ),
        "env" => emit_table(
            &lang,
            &file,
            &collect_rows(&nodes, "import"),
            &collect_codec_messages(&nodes),
            "mc_bridge_table",
            "BRIDGE_IMPORTS",
            "IMPORTS",
        ),
        "ctl" => emit_table(
            &lang,
            &file,
            &collect_rows(&nodes, "export"),
            &collect_codec_messages(&nodes),
            "mc_control_table",
            "CONTROL_EXPORTS",
            "EXPORTS",
        ),
        "wire" => emit_wire(&lang, &nodes, &file, &contract),
        "llb" => emit_codec_module(&lang, &nodes, &file),
        "syntax" => emit_codec_module(&lang, &nodes, &file),
        other => {
            eprintln!("projector: unknown module {other}");
            return ExitCode::FAILURE;
        }
    };

    print!("{out}");
    ExitCode::SUCCESS
}
