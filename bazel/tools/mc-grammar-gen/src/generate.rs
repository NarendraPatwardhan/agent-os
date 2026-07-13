//! Hermetic adapter from AgentOS grammar sources to the pinned Tree-sitter generator core.

use mc_parser_dsl::parse;
use mc_parser_elaborate::elaborate;
use mc_parser_ir::{GrammarIr, SemanticMapping};
use mc_tree_sitter_backend::grammar_json;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use syntax_rust::{GRAMMAR_IR_VERSION, SEMANTIC_KINDS, VOCABULARY_VERSION};
use tree_sitter_generate::ABI_VERSION_MAX;

pub struct Outputs {
    pub ir: PathBuf,
    pub grammar_json: PathBuf,
    pub semantics: PathBuf,
    pub diagnostics: PathBuf,
}

pub struct Options {
    pub root: PathBuf,
    pub modules: Vec<(String, PathBuf)>,
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

fn projected_vocabulary() -> Vocabulary {
    let mut out = Vocabulary {
        version: VOCABULARY_VERSION,
        grammar_ir_version: GRAMMAR_IR_VERSION,
        ..Vocabulary::default()
    };
    for spec in SEMANTIC_KINDS {
        let mut kind = SemanticKind {
            id: spec.id,
            ..SemanticKind::default()
        };
        for role in spec.roles {
            kind.roles.insert(role.name.into(), role.required);
            out.roles.insert(role.name.into(), role.id);
        }
        for semantic_trait in spec.traits {
            kind.traits.insert(semantic_trait.name.into());
            out.traits
                .insert(semantic_trait.name.into(), semantic_trait.id);
        }
        out.kinds.insert(spec.name.into(), kind);
    }
    out
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
pub fn run(options: Options) -> Result<(), String> {
    let root_source = fs::read_to_string(&options.root)
        .map_err(|e| format!("{}: {e}", options.root.display()))?;
    let root = parse(&root_source, &options.root.to_string_lossy()).map_err(|e| e.to_string())?;
    let mut modules = Vec::new();
    for (name, path) in &options.modules {
        let source = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        modules.push((
            name.clone(),
            parse(&source, &path.to_string_lossy()).map_err(|e| e.to_string())?,
        ));
    }
    let vocabulary = projected_vocabulary();
    let mut grammar = elaborate(root, modules)?;
    grammar.ir_version = vocabulary.grammar_ir_version;
    let semantic = semantic_json(&grammar.semantic, &vocabulary, &grammar)?;
    let ir_value = serde_json::to_value(&grammar).map_err(|e| e.to_string())?;
    let grammar_value = grammar_json(&grammar);
    write_json(&options.outputs.ir, &ir_value)?;
    write_json(&options.outputs.grammar_json, &grammar_value)?;
    write_json(&options.outputs.semantics, &semantic)?;
    write_json(&options.outputs.diagnostics, &json!({"diagnostics": []}))?;
    Ok(())
}
