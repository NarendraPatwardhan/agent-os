//! Hermetic adapter from AgentOS grammar sources to the pinned Tree-sitter generator core.

use mc_parser_dsl::parse;
use mc_parser_elaborate::elaborate;
use mc_parser_ir::{GrammarIr, SemanticMapping};
use mc_tree_sitter_backend::grammar_json;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter_generate::{ABI_VERSION_MAX, Diagnostic, OptLevel, generate_parser_in_directory};

pub struct Outputs {
    pub ir: PathBuf,
    pub grammar_json: PathBuf,
    pub parser_c: PathBuf,
    pub node_types: PathBuf,
    pub semantics: PathBuf,
    pub semantics_c: PathBuf,
    pub diagnostics: PathBuf,
    pub manifest: PathBuf,
}

pub struct Options {
    pub root: PathBuf,
    pub modules: Vec<(String, PathBuf)>,
    pub vocabulary: PathBuf,
    pub outputs: Outputs,
}

#[derive(Default)]
struct SemanticKind {
    id: u32,
    roles: BTreeMap<String, bool>,
    traits: std::collections::BTreeSet<String>,
}

#[derive(Default)]
struct Vocabulary {
    version: u32,
    grammar_ir_version: u32,
    kinds: BTreeMap<String, SemanticKind>,
    roles: BTreeMap<String, u32>,
    traits: BTreeMap<String, u32>,
}

fn read_vocabulary(path: &Path) -> Result<Vocabulary, String> {
    let source = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut out = Vocabulary::default();
    for (line_no, raw) in source.lines().enumerate() {
        let line = raw.split("//").next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("vocabulary-version ") {
            out.version = rest.trim().parse().map_err(|_| {
                format!(
                    "{}:{}: invalid vocabulary version",
                    path.display(),
                    line_no + 1
                )
            })?;
            continue;
        }
        if let Some(rest) = line.strip_prefix("grammar-ir-version ") {
            out.grammar_ir_version = rest.trim().parse().map_err(|_| {
                format!(
                    "{}:{}: invalid grammar IR version",
                    path.display(),
                    line_no + 1
                )
            })?;
            continue;
        }
        if let Some(rest) = line.strip_prefix("semantic-kind ") {
            let (name, props) = quoted_declaration(path, line_no + 1, rest)?;
            let id = declaration_id(path, line_no + 1, props)?;
            let mut kind = SemanticKind {
                id,
                ..SemanticKind::default()
            };
            let body = props
                .split_once('{')
                .map_or("", |(_, body)| body.trim_end_matches('}'));
            for item in body
                .split(';')
                .map(str::trim)
                .filter(|item| !item.is_empty())
            {
                if let Some(rest) = item.strip_prefix("role ") {
                    let (role, props) = quoted_declaration(path, line_no + 1, rest)?;
                    let required = props
                        .split_whitespace()
                        .find_map(|property| property.strip_prefix("required="))
                        .unwrap_or("0");
                    let required = match required {
                        "0" => false,
                        "1" => true,
                        _ => {
                            return Err(format!(
                                "{}:{}: invalid required flag",
                                path.display(),
                                line_no + 1
                            ));
                        }
                    };
                    if kind.roles.insert(role, required).is_some() {
                        return Err(format!(
                            "{}:{}: duplicate semantic kind role",
                            path.display(),
                            line_no + 1
                        ));
                    }
                } else if let Some(rest) = item.strip_prefix("trait ") {
                    let (name, _) = quoted_declaration(path, line_no + 1, rest)?;
                    if !kind.traits.insert(name) {
                        return Err(format!(
                            "{}:{}: duplicate semantic kind trait",
                            path.display(),
                            line_no + 1
                        ));
                    }
                }
            }
            if out.kinds.insert(name.clone(), kind).is_some() {
                return Err(format!(
                    "{}:{}: duplicate semantic name {name}",
                    path.display(),
                    line_no + 1
                ));
            }
            continue;
        }
        for (prefix, map) in [
            ("semantic-role ", &mut out.roles),
            ("semantic-trait ", &mut out.traits),
        ] {
            if let Some(rest) = line.strip_prefix(prefix) {
                let (name, props) = quoted_declaration(path, line_no + 1, rest)?;
                let id = declaration_id(path, line_no + 1, props)?;
                if map.insert(name.clone(), id).is_some() {
                    return Err(format!(
                        "{}:{}: duplicate semantic name {name}",
                        path.display(),
                        line_no + 1
                    ));
                }
                break;
            }
        }
    }
    if out.version == 0 {
        return Err(format!("{}: missing vocabulary-version", path.display()));
    }
    if out.grammar_ir_version == 0 {
        return Err(format!("{}: missing grammar-ir-version", path.display()));
    }
    Ok(out)
}

fn quoted_declaration<'a>(
    path: &Path,
    line: usize,
    source: &'a str,
) -> Result<(String, &'a str), String> {
    let Some(after_quote) = source.strip_prefix('"') else {
        return Err(format!(
            "{}:{line}: expected quoted semantic name",
            path.display()
        ));
    };
    let Some(end) = after_quote.find('"') else {
        return Err(format!(
            "{}:{line}: unterminated semantic name",
            path.display()
        ));
    };
    Ok((after_quote[..end].into(), &after_quote[end + 1..]))
}

fn declaration_id(path: &Path, line: usize, properties: &str) -> Result<u32, String> {
    let id = properties
        .split_whitespace()
        .find_map(|property| property.strip_prefix("id="))
        .ok_or_else(|| format!("{}:{line}: semantic declaration needs id", path.display()))?;
    id.trim_end_matches([';', '{'])
        .parse()
        .map_err(|_| format!("{}:{line}: invalid semantic id", path.display()))
}

fn semantic_json(
    mappings: &[SemanticMapping],
    vocabulary: &Vocabulary,
    grammar: &GrammarIr,
) -> Result<Value, String> {
    let mut rows = Vec::new();
    for mapping in mappings {
        let kind = vocabulary.kinds.get(&mapping.semantic).ok_or_else(|| {
            format!(
                "{}:{}:{}: unknown semantic kind {}",
                mapping.span.source, mapping.span.line, mapping.span.column, mapping.semantic
            )
        })?;
        let mut roles = serde_json::Map::new();
        for (canonical, concrete) in &mapping.roles {
            if !kind.roles.contains_key(canonical) {
                return Err(format!(
                    "{}:{}:{}: semantic kind {} does not define role {canonical}",
                    mapping.span.source, mapping.span.line, mapping.span.column, mapping.semantic
                ));
            }
            let id = vocabulary.roles.get(canonical).ok_or_else(|| {
                format!(
                    "{}:{}:{}: unknown semantic role {canonical}",
                    mapping.span.source, mapping.span.line, mapping.span.column
                )
            })?;
            roles.insert(canonical.clone(), json!({"id": id, "concrete": concrete}));
        }
        for (role, required) in &kind.roles {
            if *required && !mapping.roles.contains_key(role) {
                return Err(format!(
                    "{}:{}:{}: semantic kind {} requires role {role}",
                    mapping.span.source, mapping.span.line, mapping.span.column, mapping.semantic
                ));
            }
        }
        let mut traits = Vec::new();
        for name in &mapping.traits {
            if !kind.traits.contains(name) {
                return Err(format!(
                    "{}:{}:{}: semantic kind {} does not define trait {name}",
                    mapping.span.source, mapping.span.line, mapping.span.column, mapping.semantic
                ));
            }
            let id = vocabulary.traits.get(name).ok_or_else(|| {
                format!(
                    "{}:{}:{}: unknown semantic trait {name}",
                    mapping.span.source, mapping.span.line, mapping.span.column
                )
            })?;
            traits.push(json!({"id": id, "name": name}));
        }
        rows.push(json!({"concrete": mapping.concrete, "semantic": mapping.semantic, "semantic_id": kind.id, "roles": roles, "traits": traits}));
    }
    rows.sort_by(|a, b| a["concrete"].as_str().cmp(&b["concrete"].as_str()));
    Ok(json!({
        "language": grammar.name,
        "language_version": grammar.version,
        "grammar_version": grammar.version,
        "grammar_ir_version": grammar.ir_version,
        "vocabulary_version": vocabulary.version,
        "tree_sitter_abi": ABI_VERSION_MAX,
        "mappings": rows
    }))
}

fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let mut bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub fn run(options: Options) -> Result<(), String> {
    let root_source = fs::read_to_string(&options.root)
        .map_err(|e| format!("{}: {e}", options.root.display()))?;
    let root = parse(&root_source, &options.root.to_string_lossy()).map_err(|e| e.to_string())?;
    let mut modules = Vec::new();
    let mut input_digests = BTreeMap::new();
    input_digests.insert(
        options.root.to_string_lossy().to_string(),
        digest(root_source.as_bytes()),
    );
    for (name, path) in &options.modules {
        let source = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        input_digests.insert(name.clone(), digest(source.as_bytes()));
        modules.push((
            name.clone(),
            parse(&source, &path.to_string_lossy()).map_err(|e| e.to_string())?,
        ));
    }
    let vocabulary = read_vocabulary(&options.vocabulary)?;
    let mut grammar = elaborate(root, modules)?;
    grammar.ir_version = vocabulary.grammar_ir_version;
    let semantic = semantic_json(&grammar.semantic, &vocabulary, &grammar)?;
    let ir_value = serde_json::to_value(&grammar).map_err(|e| e.to_string())?;
    let grammar_value = grammar_json(&grammar);
    write_json(&options.outputs.ir, &ir_value)?;
    write_json(&options.outputs.grammar_json, &grammar_value)?;
    write_json(&options.outputs.semantics, &semantic)?;
    let semantic_bytes = fs::read(&options.outputs.semantics).map_err(|e| e.to_string())?;
    let c_bytes = semantic_bytes
        .iter()
        .map(|byte| byte.to_string())
        .collect::<Vec<_>>()
        .join(",");
    let semantic_symbol = grammar.name.replace('-', "_");
    fs::write(&options.outputs.semantics_c, format!(
        "/* @generated by mc-grammar-gen; do not edit. */\n#include <stdint.h>\nstatic const uint8_t mc_syntax_{semantic_symbol}_semantics_bytes[] = {{{c_bytes}}};\nconst uint8_t *mc_syntax_{semantic_symbol}_semantics(uint32_t *len) {{ *len = (uint32_t)sizeof(mc_syntax_{semantic_symbol}_semantics_bytes); return mc_syntax_{semantic_symbol}_semantics_bytes; }}\n"
    )).map_err(|e| format!("{}: {e}", options.outputs.semantics_c.display()))?;

    let output_identity = digest(options.outputs.parser_c.to_string_lossy().as_bytes());
    let temp = std::env::temp_dir().join(format!(
        "mc-grammar-gen-{}-{}-{}",
        std::process::id(),
        grammar.name,
        &output_identity[..16]
    ));
    if temp.exists() {
        fs::remove_dir_all(&temp).map_err(|e| e.to_string())?;
    }
    fs::create_dir_all(temp.join("src")).map_err(|e| e.to_string())?;
    fs::write(
        temp.join("package.json"),
        format!(
            "{{\"version\":\"{}\"}}\n",
            if grammar.version.is_empty() {
                "0.0.0"
            } else {
                &grammar.version
            }
        ),
    )
    .map_err(|e| e.to_string())?;
    fs::copy(&options.outputs.grammar_json, temp.join("src/grammar.json"))
        .map_err(|e| e.to_string())?;
    let mut diagnostics: Vec<Diagnostic> = Vec::new();
    let result = generate_parser_in_directory(
        &temp,
        Some(temp.join("generated")),
        Some(temp.join("src/grammar.json")),
        ABI_VERSION_MAX,
        None,
        None,
        true,
        OptLevel::default(),
        &mut diagnostics,
    )
    .map_err(|e| e.to_string());
    if let Err(error) = result {
        let _ = fs::remove_dir_all(&temp);
        return Err(error);
    }
    for (from, to) in [
        ("parser.c", &options.outputs.parser_c),
        ("node-types.json", &options.outputs.node_types),
    ] {
        if let Some(parent) = to.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        fs::copy(temp.join("generated").join(from), to).map_err(|e| format!("copy {from}: {e}"))?;
    }
    let diagnostic_strings = diagnostics
        .iter()
        .map(|d| format!("{d:?}"))
        .collect::<Vec<_>>();
    write_json(
        &options.outputs.diagnostics,
        &json!({"diagnostics":diagnostic_strings}),
    )?;
    let parser_bytes = fs::read(&options.outputs.parser_c).map_err(|e| e.to_string())?;
    let node_bytes = fs::read(&options.outputs.node_types).map_err(|e| e.to_string())?;
    write_json(
        &options.outputs.manifest,
        &json!({
            "schema":1,"language":grammar.name,"language_version":grammar.version,"grammar_ir_version":grammar.ir_version,
            "vocabulary_version":vocabulary.version,"tree_sitter_commit":"d11d18f746fdfd1826362c2531ce06808f386b02",
            "tree_sitter_abi":ABI_VERSION_MAX,"inputs":input_digests,
            "outputs":{"parser.c":digest(&parser_bytes),"node-types.json":digest(&node_bytes),"semantics.json":digest(&serde_json::to_vec(&semantic).unwrap())}
        }),
    )?;
    fs::remove_dir_all(&temp).map_err(|e| e.to_string())?;
    Ok(())
}
