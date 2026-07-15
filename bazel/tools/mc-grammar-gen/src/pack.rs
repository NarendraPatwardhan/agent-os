//! Multi-language Tree-sitter packer. Each automaton is built independently; this module only
//! renumbers internal implementation IDs and interns byte-identical immutable table payloads.

use rustc_hash::FxHashMap;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter_generate::grammars::{LexicalGrammar, SyntaxGrammar, VariableType};
use tree_sitter_generate::render::SharedParseLayout;
use tree_sitter_generate::rules::{Symbol, SymbolType};
use tree_sitter_generate::tables::{
    GotoAction, ParseAction, ParseState, ParseTableEntry, ProductionInfo,
};
use tree_sitter_generate::{
    prepare_parser_for_grammar, render_prepared_parser, Diagnostic, PreparedParser,
};

const ABI_VERSION: u32 = tree_sitter_generate::ABI_VERSION_MAX as u32;
const NONE_SEMANTIC: u32 = u32::MAX;
const SHARED_SMALL_TABLE: &str = "mc_syntax_small_parse_table";
const SHARED_ACTIONS: &str = "mc_syntax_parse_actions";

#[derive(Clone)]
pub struct LanguageInput {
    pub name: String,
    pub version: String,
    pub grammar: PathBuf,
    pub semantics: PathBuf,
    pub parser_out: PathBuf,
    pub node_types_out: PathBuf,
    pub manifest_out: PathBuf,
}

pub struct PackOptions {
    pub languages: Vec<LanguageInput>,
    pub tables_c: PathBuf,
    pub registry_zig: PathBuf,
    pub report: PathBuf,
}

struct Language {
    input: LanguageInput,
    parser: PreparedParser,
    semantics: Value,
    symbol_keys: BTreeMap<Symbol, SymbolKey>,
    symbol_ids: BTreeMap<Symbol, u16>,
    production_keys: Vec<String>,
    original_state_count: usize,
    original_symbol_count: usize,
    diagnostics: Vec<String>,
    large_state_count: usize,
    action_ids: FxHashMap<ParseTableEntry, usize>,
    small_offsets: Vec<usize>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct SymbolKey {
    token: bool,
    kind: u8,
    variable_kind: u8,
    name: String,
    occurrence: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
enum RenderedAction {
    Accept,
    Shift {
        state: u16,
        repetition: bool,
    },
    ShiftExtra,
    Recover,
    Reduce {
        symbol: u16,
        child_count: u16,
        dynamic_precedence: i32,
        production_id: u16,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct RenderedEntry {
    reusable: bool,
    actions: Vec<RenderedAction>,
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn write(path: &Path, bytes: impl AsRef<[u8]>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("{}: {error}", parent.display()))?;
    }
    fs::write(path, bytes).map_err(|error| format!("{}: {error}", path.display()))
}

fn version_tuple(version: &str) -> Option<(u8, u8, u8)> {
    let mut components = version.split('.');
    let major = components.next()?.parse().ok()?;
    let minor = components.next()?.parse().ok()?;
    let patch = components.next()?.split('-').next()?.parse().ok()?;
    Some((major, minor, patch))
}

fn variable_kind(kind: VariableType) -> u8 {
    match kind {
        VariableType::Hidden => 0,
        VariableType::Auxiliary => 1,
        VariableType::Anonymous => 2,
        VariableType::Named => 3,
    }
}

fn symbol_metadata(
    syntax: &SyntaxGrammar,
    lexical: &LexicalGrammar,
    symbol: Symbol,
) -> (String, u8) {
    match symbol.kind {
        SymbolType::End => ("end".into(), 0),
        SymbolType::EndOfNonTerminalExtra => ("end_of_nonterminal_extra".into(), 0),
        SymbolType::Terminal => {
            let variable = &lexical.variables[symbol.index];
            (variable.name.clone(), variable_kind(variable.kind))
        }
        SymbolType::NonTerminal => {
            let variable = &syntax.variables[symbol.index];
            (variable.name.clone(), variable_kind(variable.kind))
        }
        SymbolType::External => {
            let variable = &syntax.external_tokens[symbol.index];
            (variable.name.clone(), variable_kind(variable.kind))
        }
    }
}

fn is_token(syntax: &SyntaxGrammar, symbol: Symbol) -> bool {
    symbol.is_terminal()
        || symbol.is_eof()
        || (symbol.is_external()
            && syntax.external_tokens[symbol.index]
                .corresponding_internal_token
                .is_none())
}

fn symbol_keys(parser: &PreparedParser) -> BTreeMap<Symbol, SymbolKey> {
    let mut counts = BTreeMap::<(bool, u8, u8, String), usize>::new();
    let mut out = BTreeMap::new();
    for symbol in &parser.tables.parse_table.symbols {
        let (name, kind) =
            symbol_metadata(&parser.syntax_grammar, &parser.lexical_grammar, *symbol);
        let token = is_token(&parser.syntax_grammar, *symbol);
        let base = (token, symbol.kind as u8, kind, name.clone());
        let occurrence = *counts
            .entry(base)
            .and_modify(|count| *count += 1)
            .or_insert(0);
        out.insert(
            *symbol,
            SymbolKey {
                token,
                kind: symbol.kind as u8,
                variable_kind: kind,
                name,
                occurrence,
            },
        );
    }
    out
}

fn production_key(info: &ProductionInfo) -> String {
    format!("{:?}|{:?}", info.alias_sequence, info.field_map)
}

fn common_values<T: Ord + Clone>(sets: impl Iterator<Item = BTreeSet<T>>) -> BTreeSet<T> {
    let mut sets = sets;
    let Some(mut common) = sets.next() else {
        return BTreeSet::new();
    };
    for set in sets {
        common.retain(|value| set.contains(value));
    }
    common
}

fn reorder_symbols(languages: &mut [Language]) {
    let common = common_values(languages.iter().map(|language| {
        language
            .symbol_keys
            .values()
            .cloned()
            .collect::<BTreeSet<_>>()
    }));
    for language in languages {
        language
            .parser
            .tables
            .parse_table
            .symbols
            .sort_by_key(|symbol| {
                if symbol.is_eof() {
                    return (
                        0_u8,
                        SymbolKey {
                            token: true,
                            kind: 0,
                            variable_kind: 0,
                            name: String::new(),
                            occurrence: 0,
                        },
                    );
                }
                let key = language.symbol_keys[symbol].clone();
                let group = match (key.token, common.contains(&key)) {
                    (true, true) => 1,
                    (true, false) => 2,
                    (false, true) => 3,
                    (false, false) => 4,
                };
                (group, key)
            });
        language.symbol_ids.clear();
        let mut next = 0_u16;
        for symbol in &language.parser.tables.parse_table.symbols {
            if symbol.is_eof() {
                language.symbol_ids.insert(*symbol, 0);
            } else {
                next += 1;
                language.symbol_ids.insert(*symbol, next);
            }
        }
    }
}

fn reorder_productions(languages: &mut [Language]) -> Result<(), String> {
    let common = common_values(languages.iter().map(|language| {
        language
            .parser
            .tables
            .parse_table
            .production_infos
            .iter()
            .map(production_key)
            .collect::<BTreeSet<_>>()
    }));
    for language in languages {
        let old = std::mem::take(&mut language.parser.tables.parse_table.production_infos);
        let mut indexed = old
            .into_iter()
            .enumerate()
            .map(|(index, value)| (index, production_key(&value), value))
            .collect::<Vec<_>>();
        indexed.sort_by_key(|(_, key, _)| (!common.contains(key), key.clone()));
        let mut remap = vec![0_u16; indexed.len()];
        language.production_keys.clear();
        for (new, (old, key, _)) in indexed.iter().enumerate() {
            remap[*old] = u16::try_from(new).map_err(|_| "production ID overflow")?;
            language.production_keys.push(key.clone());
        }
        language.parser.tables.parse_table.production_infos =
            indexed.into_iter().map(|(_, _, value)| value).collect();
        for state in &mut language.parser.tables.parse_table.states {
            for entry in state.terminal_entries.values_mut() {
                for action in &mut entry.actions {
                    if let ParseAction::Reduce { production_id, .. } = action {
                        *production_id = remap[usize::from(*production_id)];
                    }
                }
            }
        }
    }
    Ok(())
}

fn state_signature(
    language: &Language,
    state_index: usize,
    state: &ParseState,
    classes: &[usize],
) -> String {
    let mut terminals = state.terminal_entries.iter().collect::<Vec<_>>();
    terminals.sort_by_key(|(symbol, _)| language.symbol_keys[*symbol].clone());
    let mut nonterminals = state.nonterminal_entries.iter().collect::<Vec<_>>();
    nonterminals.sort_by_key(|(symbol, _)| language.symbol_keys[*symbol].clone());
    let mut out = format!("C{};", classes[state_index]);
    for (symbol, entry) in terminals {
        out.push_str(&format!(
            "T{:?}:{}:",
            language.symbol_keys[symbol], entry.reusable
        ));
        for action in &entry.actions {
            match action {
                ParseAction::Accept => out.push_str("A;"),
                ParseAction::Shift {
                    state,
                    is_repetition,
                } => {
                    out.push_str(&format!("S{}:{};", classes[*state], is_repetition));
                }
                ParseAction::ShiftExtra => out.push_str("X;"),
                ParseAction::Recover => out.push_str("E;"),
                ParseAction::Reduce {
                    symbol,
                    child_count,
                    dynamic_precedence,
                    production_id,
                } => out.push_str(&format!(
                    "R{:?}:{child_count}:{dynamic_precedence}:{};",
                    language.symbol_keys[symbol],
                    language.production_keys[usize::from(*production_id)]
                )),
            }
        }
    }
    for (symbol, action) in nonterminals {
        match action {
            GotoAction::Goto(state) => out.push_str(&format!(
                "N{:?}:{};",
                language.symbol_keys[symbol], classes[*state]
            )),
            GotoAction::ShiftExtra => {
                out.push_str(&format!("NX{:?};", language.symbol_keys[symbol]));
            }
        }
    }
    out
}

fn original_large_count(language: &Language) -> usize {
    let threshold = std::cmp::min(64, language.parser.tables.parse_table.symbols.len() / 2);
    language
        .parser
        .tables
        .parse_table
        .states
        .iter()
        .enumerate()
        .take_while(|(index, state)| {
            *index <= 1
                || state.terminal_entries.len() + state.nonterminal_entries.len() > threshold
        })
        .count()
}

fn reorder_states(languages: &mut [Language]) -> Result<usize, String> {
    let mut classes = languages
        .iter()
        .map(|language| vec![0_usize; language.parser.tables.parse_table.states.len()])
        .collect::<Vec<_>>();
    let mut converged = false;
    for _ in 0..2048 {
        let mut signatures = BTreeSet::new();
        let all = languages
            .iter()
            .zip(&classes)
            .map(|(language, ids)| {
                language
                    .parser
                    .tables
                    .parse_table
                    .states
                    .iter()
                    .enumerate()
                    .map(|(index, state)| state_signature(language, index, state, ids))
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>();
        for language in &all {
            signatures.extend(language.iter().cloned());
        }
        let ids = signatures
            .into_iter()
            .enumerate()
            .map(|(id, signature)| (signature, id))
            .collect::<BTreeMap<_, _>>();
        let next = all
            .iter()
            .map(|language| {
                language
                    .iter()
                    .map(|signature| ids[signature])
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>();
        let old_count = classes
            .iter()
            .flatten()
            .copied()
            .collect::<BTreeSet<_>>()
            .len();
        let new_count = next
            .iter()
            .flatten()
            .copied()
            .collect::<BTreeSet<_>>()
            .len();
        classes = next;
        if new_count == old_count {
            converged = true;
            break;
        }
    }
    if !converged {
        return Err("parser-state partition refinement did not converge after 2048 rounds".into());
    }

    let large_counts = languages
        .iter()
        .map(original_large_count)
        .collect::<Vec<_>>();
    let common_large_count = *large_counts.iter().max().unwrap_or(&2);
    let mut by_class = BTreeMap::<usize, Vec<Vec<usize>>>::new();
    for (language_index, ids) in classes.iter().enumerate() {
        for (state, class) in ids.iter().enumerate().skip(2) {
            by_class
                .entry(*class)
                .or_insert_with(|| vec![Vec::new(); languages.len()])[language_index]
                .push(state);
        }
    }
    let common_classes = by_class
        .iter()
        .filter_map(|(class, states)| {
            if states.iter().all(|values| values.len() == 1)
                && states.iter().enumerate().all(|(language, values)| {
                    let state = &languages[language].parser.tables.parse_table.states[values[0]];
                    state.terminal_entries.len() + state.nonterminal_entries.len()
                        <= std::cmp::min(
                            64,
                            languages[language].parser.tables.parse_table.symbols.len() / 2,
                        )
                })
            {
                Some(*class)
            } else {
                None
            }
        })
        .collect::<Vec<_>>();
    let common_set = common_classes.iter().copied().collect::<BTreeSet<_>>();

    for language_index in 0..languages.len() {
        let state_count = languages[language_index]
            .parser
            .tables
            .parse_table
            .states
            .len();
        let mut large = (2..large_counts[language_index]).collect::<Vec<_>>();
        let mut promotion_candidates = (2..state_count)
            .filter(|state| {
                !large.contains(state) && !common_set.contains(&classes[language_index][*state])
            })
            .collect::<Vec<_>>();
        promotion_candidates.sort_by_key(|state| {
            let value = &languages[language_index].parser.tables.parse_table.states[*state];
            std::cmp::Reverse(value.terminal_entries.len() + value.nonterminal_entries.len())
        });
        while large.len() + 2 < common_large_count {
            if promotion_candidates.is_empty() {
                return Err(format!(
                    "{} cannot normalize its large-state prefix to {common_large_count} states",
                    languages[language_index].input.name,
                ));
            }
            large.push(promotion_candidates.remove(0));
        }
        large.sort_unstable();
        let mut order = vec![0, 1];
        order.extend(large);
        for class in &common_classes {
            order.push(by_class[class][language_index][0]);
        }
        let selected = order.iter().copied().collect::<BTreeSet<_>>();
        order.extend((2..state_count).filter(|state| !selected.contains(state)));
        let mut remap = vec![0_usize; state_count];
        for (new, old) in order.iter().enumerate() {
            remap[*old] = new;
        }
        let old_states =
            std::mem::take(&mut languages[language_index].parser.tables.parse_table.states);
        let mut slots = old_states.into_iter().map(Some).collect::<Vec<_>>();
        let mut states = Vec::with_capacity(state_count);
        for old in order {
            states.push(slots[old].take().expect("state permutation is unique"));
        }
        for (new, state) in states.iter_mut().enumerate() {
            state.id = new;
            state.update_referenced_states(|old, _| remap[old]);
        }
        languages[language_index].parser.tables.parse_table.states = states;
        languages[language_index].large_state_count = common_large_count;
    }
    Ok(common_classes.len())
}

fn rendered_entry(language: &Language, entry: &ParseTableEntry) -> Result<RenderedEntry, String> {
    let mut actions = Vec::with_capacity(entry.actions.len());
    for action in &entry.actions {
        actions.push(match action {
            ParseAction::Accept => RenderedAction::Accept,
            ParseAction::Shift {
                state,
                is_repetition,
            } => RenderedAction::Shift {
                state: u16::try_from(*state).map_err(|_| "state ID overflow")?,
                repetition: *is_repetition,
            },
            ParseAction::ShiftExtra => RenderedAction::ShiftExtra,
            ParseAction::Recover => RenderedAction::Recover,
            ParseAction::Reduce {
                symbol,
                child_count,
                dynamic_precedence,
                production_id,
            } => RenderedAction::Reduce {
                symbol: language.symbol_ids[symbol],
                child_count: *child_count,
                dynamic_precedence: *dynamic_precedence,
                production_id: *production_id,
            },
        });
    }
    Ok(RenderedEntry {
        reusable: entry.reusable,
        actions,
    })
}

fn intern_actions(languages: &mut [Language]) -> Result<Vec<(usize, RenderedEntry)>, String> {
    let default = RenderedEntry {
        reusable: false,
        actions: Vec::new(),
    };
    let mut offsets = BTreeMap::from([(default.clone(), 0_usize)]);
    let mut entries = vec![(0, default)];
    let mut next = 1_usize;
    for language_index in 0..languages.len() {
        let mut local = FxHashMap::default();
        let states = &languages[language_index].parser.tables.parse_table.states;
        for state in states {
            for entry in state.terminal_entries.values() {
                if local.contains_key(entry) {
                    continue;
                }
                let rendered = rendered_entry(&languages[language_index], entry)?;
                let offset = if let Some(offset) = offsets.get(&rendered) {
                    *offset
                } else {
                    let offset = next;
                    next += 1 + rendered.actions.len();
                    offsets.insert(rendered.clone(), offset);
                    entries.push((offset, rendered));
                    offset
                };
                local.insert(entry.clone(), offset);
            }
        }
        languages[language_index].action_ids = local;
    }
    if next >= usize::from(u16::MAX) {
        return Err(format!(
            "shared parse action pool has {next} entries; maximum is {}",
            u16::MAX
        ));
    }
    entries.sort_by_key(|(offset, _)| *offset);
    Ok(entries)
}

fn small_row(language: &Language, state: &ParseState) -> Vec<u16> {
    let mut groups = BTreeMap::<(u16, u8), Vec<u16>>::new();
    for (symbol, entry) in &state.terminal_entries {
        groups
            .entry((language.action_ids[entry] as u16, 1))
            .or_default()
            .push(language.symbol_ids[symbol]);
    }
    for (symbol, action) in &state.nonterminal_entries {
        let state = match action {
            GotoAction::Goto(state) => *state,
            GotoAction::ShiftExtra => state.id,
        };
        groups
            .entry((state as u16, 0))
            .or_default()
            .push(language.symbol_ids[symbol]);
    }
    let mut groups = groups.into_iter().collect::<Vec<_>>();
    for (_, symbols) in &mut groups {
        symbols.sort_unstable();
    }
    groups.sort_by_key(|((value, kind), symbols)| (symbols.len(), *kind, *value, symbols[0]));
    let mut row = vec![groups.len() as u16];
    for ((value, _), symbols) in groups {
        row.push(value);
        row.push(symbols.len() as u16);
        row.extend(symbols);
    }
    row
}

fn intern_small_rows(languages: &mut [Language]) -> Vec<u16> {
    let mut rows = BTreeMap::<Vec<u16>, usize>::new();
    let mut table = Vec::new();
    for language in languages {
        let mut offsets = Vec::new();
        for state in language
            .parser
            .tables
            .parse_table
            .states
            .iter()
            .skip(language.large_state_count)
        {
            let row = small_row(language, state);
            let offset = if let Some(offset) = rows.get(&row) {
                *offset
            } else {
                let offset = table.len();
                table.extend_from_slice(&row);
                rows.insert(row, offset);
                offset
            };
            offsets.push(offset);
        }
        language.small_offsets = offsets;
    }
    table
}

fn verify_shared_layout(
    languages: &[Language],
    actions: &[(usize, RenderedEntry)],
    small: &[u16],
) -> Result<(), String> {
    let action_pool = actions.iter().cloned().collect::<BTreeMap<_, _>>();
    for language in languages {
        for state in &language.parser.tables.parse_table.states {
            for entry in state.terminal_entries.values() {
                let offset = *language.action_ids.get(entry).ok_or_else(|| {
                    format!(
                        "{}: packed action map omitted a parser action",
                        language.input.name
                    )
                })?;
                let pooled = action_pool.get(&offset).ok_or_else(|| {
                    format!(
                        "{}: packed action offset {offset} is absent",
                        language.input.name
                    )
                })?;
                if pooled != &rendered_entry(language, entry)? {
                    return Err(format!(
                        "{}: packed action offset {offset} changes parser behavior",
                        language.input.name,
                    ));
                }
            }
        }
        let small_states = &language.parser.tables.parse_table.states[language.large_state_count..];
        if small_states.len() != language.small_offsets.len() {
            return Err(format!(
                "{}: packed small-state map has the wrong length",
                language.input.name
            ));
        }
        for (state, offset) in small_states.iter().zip(&language.small_offsets) {
            let row = small_row(language, state);
            let end = offset
                .checked_add(row.len())
                .ok_or("small-table offset overflow")?;
            if small.get(*offset..end) != Some(row.as_slice()) {
                return Err(format!(
                    "{}: packed small-table row at offset {offset} changes parser behavior",
                    language.input.name,
                ));
            }
        }
    }
    Ok(())
}

fn unpooled_action_words(language: &Language) -> Result<usize, String> {
    let mut entries = BTreeSet::new();
    for state in &language.parser.tables.parse_table.states {
        for entry in state.terminal_entries.values() {
            entries.insert(rendered_entry(language, entry)?);
        }
    }
    Ok(1 + entries
        .iter()
        .map(|entry| 1 + entry.actions.len())
        .sum::<usize>())
}

fn unpooled_small_words(language: &Language) -> usize {
    language
        .parser
        .tables
        .parse_table
        .states
        .iter()
        .skip(language.large_state_count)
        .map(|state| small_row(language, state).len())
        .sum()
}

fn render_shared_c(actions: &[(usize, RenderedEntry)], small: &[u16]) -> String {
    let mut out =
        String::from("/* @generated by mc-syntax-pack; do not edit. */\n#include \"parser.h\"\n\n");
    out.push_str(&format!("const uint16_t {SHARED_SMALL_TABLE}[] = {{\n"));
    for chunk in small.chunks(16) {
        out.push_str("  ");
        for word in chunk {
            out.push_str(&format!("{word},"));
        }
        out.push('\n');
    }
    out.push_str("};\n\n");
    out.push_str(&format!(
        "const TSParseActionEntry {SHARED_ACTIONS}[] = {{\n"
    ));
    for (offset, entry) in actions {
        out.push_str(&format!(
            "  [{offset}] = {{.entry = {{.count = {}, .reusable = {}}}}},",
            entry.actions.len(),
            entry.reusable
        ));
        for action in &entry.actions {
            let rendered = match action {
                RenderedAction::Accept => "ACCEPT_INPUT()".into(),
                RenderedAction::Shift {
                    state,
                    repetition: false,
                } => format!("SHIFT({state})"),
                RenderedAction::Shift {
                    state,
                    repetition: true,
                } => format!("SHIFT_REPEAT({state})"),
                RenderedAction::ShiftExtra => "SHIFT_EXTRA()".into(),
                RenderedAction::Recover => "RECOVER()".into(),
                RenderedAction::Reduce {
                    symbol,
                    child_count,
                    dynamic_precedence,
                    production_id,
                } => {
                    format!(
                        "REDUCE({symbol}, {child_count}, {dynamic_precedence}, {production_id})"
                    )
                }
            };
            out.push_str(&format!(" {rendered},"));
        }
        out.push('\n');
    }
    out.push_str("};\n");
    out
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct RoleValue {
    field_id: u16,
    semantic_id: u32,
}

#[derive(Clone)]
struct SemanticEntryValue {
    semantic_id: u32,
    traits: Vec<u32>,
    roles: Vec<RoleValue>,
}

fn semantic_entries(language: &Language) -> Result<Vec<SemanticEntryValue>, String> {
    let mut fields = BTreeSet::new();
    for info in &language.parser.tables.parse_table.production_infos {
        fields.extend(info.field_map.keys().cloned());
    }
    let field_ids = fields
        .into_iter()
        .enumerate()
        .map(|(index, name)| {
            u16::try_from(index + 1)
                .map(|id| (name, id))
                .map_err(|_| format!("{}: field ID overflow", language.input.name))
        })
        .collect::<Result<BTreeMap<_, _>, _>>()?;
    let mut mappings = BTreeMap::new();
    for mapping in language.semantics["mappings"]
        .as_array()
        .ok_or("semantics.mappings must be an array")?
    {
        let concrete = mapping["concrete"]
            .as_str()
            .ok_or("semantic concrete must be a string")?;
        let semantic_id = mapping["semantic_id"]
            .as_u64()
            .and_then(|id| u32::try_from(id).ok())
            .ok_or("semantic ID must be u32")?;
        let traits = mapping["traits"]
            .as_array()
            .ok_or("semantic traits must be an array")?
            .iter()
            .map(|value| {
                value["id"]
                    .as_u64()
                    .and_then(|id| u32::try_from(id).ok())
                    .ok_or("trait ID must be u32")
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut roles = mapping["roles"]
            .as_object()
            .ok_or("semantic roles must be an object")?
            .values()
            .map(|value| {
                let field = value["concrete"]
                    .as_str()
                    .ok_or("role field must be a string")?;
                Ok(RoleValue {
                    field_id: *field_ids.get(field).ok_or_else(|| {
                        format!(
                            "{}: semantic role field {field} is absent",
                            language.input.name
                        )
                    })?,
                    semantic_id: value["id"]
                        .as_u64()
                        .and_then(|id| u32::try_from(id).ok())
                        .ok_or("role ID must be u32")?,
                })
            })
            .collect::<Result<Vec<_>, String>>()?;
        roles.sort();
        if mappings
            .insert(
                concrete.to_string(),
                SemanticEntryValue {
                    semantic_id,
                    traits,
                    roles,
                },
            )
            .is_some()
        {
            return Err(format!(
                "{}: duplicate semantic mapping for {concrete}",
                language.input.name,
            ));
        }
    }
    let mut out = vec![
        SemanticEntryValue {
            semantic_id: NONE_SEMANTIC,
            traits: Vec::new(),
            roles: Vec::new()
        };
        language.parser.tables.parse_table.symbols.len()
    ];
    for (symbol, id) in &language.symbol_ids {
        let name = &language.symbol_keys[symbol].name;
        if let Some(value) = mappings.get(name) {
            out[usize::from(*id)] = value.clone();
        }
    }
    // Family modules may carry semantically annotated helper roots that become unreachable after
    // composition. Elaboration already proved the concrete production and fields exist; absence
    // from the minimized parser therefore means "not emitted", not a misspelled mapping.
    Ok(out)
}

fn validate_native_symbol_domain(parser: &PreparedParser, language: &str) -> Result<(), String> {
    let production_alias = parser
        .tables
        .parse_table
        .production_infos
        .iter()
        .any(|production| production.alias_sequence.iter().any(Option::is_some));
    if !parser.simple_aliases.is_empty() || production_alias {
        return Err(format!(
            "{language}: aliases require explicit public-symbol projection before they can enter the native semantic registry",
        ));
    }
    Ok(())
}

fn render_registry(languages: &[Language]) -> Result<String, String> {
    let mut trait_pool = Vec::<u32>::new();
    let mut trait_slices = BTreeMap::<Vec<u32>, usize>::new();
    let mut role_pool = Vec::<RoleValue>::new();
    let mut role_slices = BTreeMap::<Vec<RoleValue>, usize>::new();
    let mut rendered = Vec::new();
    for language in languages {
        let entries = semantic_entries(language)?;
        let mut values = Vec::new();
        for entry in entries {
            let trait_start = if let Some(offset) = trait_slices.get(&entry.traits) {
                *offset
            } else {
                let offset = trait_pool.len();
                trait_pool.extend_from_slice(&entry.traits);
                trait_slices.insert(entry.traits.clone(), offset);
                offset
            };
            let role_start = if let Some(offset) = role_slices.get(&entry.roles) {
                *offset
            } else {
                let offset = role_pool.len();
                role_pool.extend_from_slice(&entry.roles);
                role_slices.insert(entry.roles.clone(), offset);
                offset
            };
            values.push((
                entry.semantic_id,
                trait_start,
                entry.traits.len(),
                role_start,
                entry.roles.len(),
            ));
        }
        rendered.push(values);
    }
    let mut out = String::from(
        "// @generated by mc-syntax-pack; do not edit.\nconst std = @import(\"std\");\nconst wire = @import(\"syntax_zig\");\npub const NONE_SEMANTIC: u32 = std.math.maxInt(u32);\npub const Role = struct { field_id: u16, semantic_id: u32 };\npub const Entry = struct { semantic_id: u32, trait_start: u32, trait_count: u16, role_start: u32, role_count: u16 };\npub const Map = struct { language_version: []const u8, grammar_version: []const u8, grammar_ir_version: u32, vocabulary_version: u32, tree_sitter_abi: u32, entries: []const Entry };\npub const Descriptor = struct { name: []const u8, semantic: *const Map };\n",
    );
    out.push_str("pub const traits = [_]wire.SemanticTrait{\n");
    for id in trait_pool {
        out.push_str(&format!("    .{{ .id = {id} }},\n"));
    }
    out.push_str("};\npub const roles = [_]Role{\n");
    for role in role_pool {
        out.push_str(&format!(
            "    .{{ .field_id = {}, .semantic_id = {} }},\n",
            role.field_id, role.semantic_id
        ));
    }
    out.push_str("};\n");
    for (language, entries) in languages.iter().zip(&rendered) {
        out.push_str(&format!(
            "const {}_entries = [_]Entry{{\n",
            language.input.name
        ));
        for (semantic, trait_start, trait_count, role_start, role_count) in entries {
            out.push_str(&format!("    .{{ .semantic_id = {semantic}, .trait_start = {trait_start}, .trait_count = {trait_count}, .role_start = {role_start}, .role_count = {role_count} }},\n"));
        }
        let semantics = &language.semantics;
        out.push_str(&format!(
            "}};\nconst {0}_map = Map{{ .language_version = \"{1}\", .grammar_version = \"{2}\", .grammar_ir_version = {3}, .vocabulary_version = {4}, .tree_sitter_abi = {5}, .entries = &{0}_entries }};\npub extern fn tree_sitter_{0}() ?*const anyopaque;\n",
            language.input.name,
            semantics["language_version"].as_str().unwrap_or(&language.input.version),
            semantics["grammar_version"].as_str().unwrap_or(&language.input.version),
            semantics["grammar_ir_version"].as_u64().unwrap_or(0),
            semantics["vocabulary_version"].as_u64().unwrap_or(0),
            semantics["tree_sitter_abi"].as_u64().unwrap_or(0),
        ));
    }
    out.push_str("pub const descriptors = [_]Descriptor{\n");
    for language in languages {
        out.push_str(&format!(
            "    .{{ .name = \"{}\", .semantic = &{}_map }},\n",
            language.input.name, language.input.name
        ));
    }
    out.push_str(
        "};\npub fn language(comptime c: type, name: []const u8) ?*const c.TSLanguage {\n",
    );
    for language in languages {
        out.push_str(&format!(
            "    if (std.mem.eql(u8, name, \"{0}\")) return @ptrCast(tree_sitter_{0}());\n",
            language.input.name
        ));
    }
    out.push_str("    return null;\n}\npub fn descriptor(name: []const u8) ?*const Descriptor {\n    for (&descriptors) |*item| if (std.mem.eql(u8, item.name, name)) return item;\n    return null;\n}\npub fn entry(map: *const Map, symbol: u16) ?*const Entry {\n    if (symbol >= map.entries.len) return null;\n    const value = &map.entries[symbol];\n    return if (value.semantic_id == NONE_SEMANTIC) null else value;\n}\npub fn entryTraits(value: *const Entry) []const wire.SemanticTrait { return traits[value.trait_start..][0..value.trait_count]; }\npub fn entryRole(value: *const Entry, field_id: u16) ?u32 {\n    const values = roles[value.role_start..][0..value.role_count];\n    var low: usize = 0; var high: usize = values.len;\n    while (low < high) { const mid = low + (high - low) / 2; if (values[mid].field_id < field_id) low = mid + 1 else high = mid; }\n    return if (low < values.len and values[low].field_id == field_id) values[low].semantic_id else null;\n}\n");
    Ok(out)
}

pub fn run(mut options: PackOptions) -> Result<(), String> {
    options
        .languages
        .sort_by(|left, right| left.name.cmp(&right.name));
    if options.languages.is_empty() {
        return Err("syntax pack needs at least one language".into());
    }
    for pair in options.languages.windows(2) {
        if pair[0].name == pair[1].name {
            return Err(format!("duplicate syntax language {}", pair[0].name));
        }
    }
    let mut languages = Vec::new();
    for mut input in options.languages {
        let grammar_bytes = fs::read(&input.grammar)
            .map_err(|error| format!("{}: {error}", input.grammar.display()))?;
        let grammar = std::str::from_utf8(&grammar_bytes).map_err(|error| error.to_string())?;
        let semantics_bytes = fs::read(&input.semantics)
            .map_err(|error| format!("{}: {error}", input.semantics.display()))?;
        let semantics: Value =
            serde_json::from_slice(&semantics_bytes).map_err(|error| error.to_string())?;
        input.version = semantics["language_version"]
            .as_str()
            .ok_or_else(|| format!("{}: semantics omit language_version", input.name))?
            .into();
        if semantics["tree_sitter_abi"].as_u64() != Some(u64::from(ABI_VERSION)) {
            return Err(format!(
                "{}: semantics ABI does not match Tree-sitter ABI {ABI_VERSION}",
                input.name
            ));
        }
        let mut diagnostics = Vec::<Diagnostic>::new();
        let parser =
            prepare_parser_for_grammar(grammar, version_tuple(&input.version), &mut diagnostics)
                .map_err(|error| error.to_string())?;
        if parser.name != input.name {
            return Err(format!(
                "pack input {} generated parser {}",
                input.name, parser.name
            ));
        }
        validate_native_symbol_domain(&parser, &input.name)?;
        let keys = symbol_keys(&parser);
        let diagnostics = diagnostics
            .iter()
            .map(|diagnostic| format!("{diagnostic:?}"))
            .collect();
        languages.push(Language {
            original_state_count: parser.tables.parse_table.states.len(),
            original_symbol_count: parser.tables.parse_table.symbols.len(),
            input,
            parser,
            semantics,
            symbol_keys: keys,
            symbol_ids: BTreeMap::new(),
            production_keys: Vec::new(),
            diagnostics,
            large_state_count: 0,
            action_ids: FxHashMap::default(),
            small_offsets: Vec::new(),
        });
    }
    reorder_symbols(&mut languages);
    reorder_productions(&mut languages)?;
    let shared_state_classes = reorder_states(&mut languages)?;
    let actions = intern_actions(&mut languages)?;
    let unpooled_action_words = languages
        .iter()
        .map(unpooled_action_words)
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .sum::<usize>();
    let unpooled_small_words = languages.iter().map(unpooled_small_words).sum::<usize>();
    let small = intern_small_rows(&mut languages);
    verify_shared_layout(&languages, &actions, &small)?;
    let tables_c = render_shared_c(&actions, &small);
    write(&options.tables_c, &tables_c)?;
    let registry = render_registry(&languages)?;
    write(&options.registry_zig, &registry)?;
    let mut pack_hasher = Sha256::new();
    for language in &languages {
        pack_hasher.update(language.input.name.as_bytes());
        pack_hasher.update([0]);
        pack_hasher.update(fs::read(&language.input.grammar).map_err(|error| error.to_string())?);
        pack_hasher.update([0]);
        pack_hasher.update(fs::read(&language.input.semantics).map_err(|error| error.to_string())?);
        pack_hasher.update([0]);
    }
    let pack_identity = format!("{:x}", pack_hasher.finalize());
    let tables_digest = digest(tables_c.as_bytes());
    let registry_digest = digest(registry.as_bytes());
    let mut manifest_rows = Vec::new();
    for language in languages {
        let layout = SharedParseLayout {
            large_state_count: language.large_state_count,
            action_ids: language.action_ids,
            small_state_offsets: language.small_offsets.clone(),
            small_table_symbol: SHARED_SMALL_TABLE.into(),
            action_table_symbol: SHARED_ACTIONS.into(),
        };
        let node_types = format!("{}\n", language.parser.node_types_json);
        let parser_c =
            render_prepared_parser(language.parser, layout).map_err(|error| error.to_string())?;
        write(&language.input.parser_out, &parser_c)?;
        write(&language.input.node_types_out, &node_types)?;
        let manifest = json!({
            "schema": 2,
            "language": language.input.name,
            "language_version": language.input.version,
            "tree_sitter_commit": "d11d18f746fdfd1826362c2531ce06808f386b02",
            "tree_sitter_abi": ABI_VERSION,
            "pack_identity": pack_identity,
            "parser_model": {"states": language.original_state_count, "symbols": language.original_symbol_count},
            "diagnostics": language.diagnostics,
            "inputs": {
                "grammar.json": digest(&fs::read(&language.input.grammar).map_err(|error| error.to_string())?),
                "semantics.json": digest(&fs::read(&language.input.semantics).map_err(|error| error.to_string())?),
            },
            "outputs": {
                "parser.c": digest(parser_c.as_bytes()),
                "node-types.json": digest(node_types.as_bytes()),
                "shared_tables.c": tables_digest,
                "registry.zig": registry_digest,
            }
        });
        write(
            &language.input.manifest_out,
            format!("{}\n", serde_json::to_string_pretty(&manifest).unwrap()),
        )?;
        manifest_rows.push(manifest);
    }
    let report = json!({"schema":2,"pack_identity":pack_identity,"languages":manifest_rows,"shared_state_classes":shared_state_classes,"actions":{"unpooled_words":unpooled_action_words,"pooled_words":actions.iter().map(|(_, entry)| 1 + entry.actions.len()).sum::<usize>()},"small_parse_table":{"unpooled_words":unpooled_small_words,"pooled_words":small.len()}});
    write(
        &options.report,
        format!("{}\n", serde_json::to_string_pretty(&report).unwrap()),
    )?;
    Ok(())
}
