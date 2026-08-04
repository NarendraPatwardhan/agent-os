use luau_aot_ledger::{canonical_json, canonical_policy_hash, extract, validate_policy};
use serde_json::{json, Value};

#[test]
fn extracts_the_bazel_pinned_header() {
    let runfiles = runfiles::Runfiles::create().expect("runfiles unavailable");
    let relative = "+_repo_rules+luau/CodeGen/include/Luau/IrData.h";
    let path = runfiles
        .rlocation(relative)
        .unwrap_or_else(|| panic!("{relative} not found in runfiles"));
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("reading {}: {error}", path.display()));
    let got = extract(&source).expect("extract pinned IrData.h");
    assert_eq!(got.commands.members.len(), 216);
    assert_eq!(got.operand_kinds.members.len(), 10);
    assert_eq!(got.block_kinds.members.len(), 6);
    assert_eq!(got.commands.members.first().unwrap().name, "NOP");
    assert_eq!(
        got.commands.members.last().unwrap().name,
        "JUMP_CMP_PROTOID"
    );
    assert_eq!(
        got.source_sha256,
        "765f9188e07a3886c29b5bb146241286d1f95c801a8907aa03147df524e7c399"
    );
}

#[test]
fn validates_the_checked_policy_against_the_pinned_header() {
    let runfiles = runfiles::Runfiles::create().expect("runfiles unavailable");
    let header = runfiles
        .rlocation("+_repo_rules+luau/CodeGen/include/Luau/IrData.h")
        .expect("pinned IrData.h not found in runfiles");
    let policy = runfiles
        .rlocation("_main/memcontainers/programs/luau/aot/maps/luau_aot_ir_coverage.json")
        .expect("checked IR coverage policy not found in runfiles");
    let source = std::fs::read_to_string(&header)
        .unwrap_or_else(|error| panic!("reading {}: {error}", header.display()));
    let policy_json = std::fs::read_to_string(&policy)
        .unwrap_or_else(|error| panic!("reading {}: {error}", policy.display()));
    validate_policy(&extract(&source).unwrap(), &policy_json).unwrap();
}

const VALID: &str = r#"
#pragma once
#include "Luau/Bytecode.h"
// unrelated declaration
enum class IrCmd /* comment */ : uint8_t {
    NOP, // line comment
    LOAD_TAG,
};
enum class IrOpKind : uint32_t
{
    None,
    /* split formatting */ Undef,
};
enum class IrBlockKind : uint8_t { Bytecode, Dead, };
"#;

#[test]
fn extracts_exact_enums_and_stable_json() {
    let got = extract(VALID).unwrap();
    assert_eq!(got.commands.members[1].name, "LOAD_TAG");
    assert_eq!(got.commands.members[1].value, 1);
    assert_eq!(got.operand_kinds.members.len(), 2);
    assert_eq!(got.block_kinds.members.len(), 2);
    let json = canonical_json(&got).unwrap();
    assert!(json.ends_with('\n'));
    assert_eq!(json, canonical_json(&extract(VALID).unwrap()).unwrap());
    assert_eq!(got.source_sha256.len(), 64);
}

#[test]
fn validates_exact_policy_independent_of_row_order() {
    let got = extract(VALID).unwrap();
    let mut policy = policy_for(&got);
    policy["commands"].as_array_mut().unwrap().reverse();
    policy["operand_kinds"].as_array_mut().unwrap().reverse();
    policy["block_kinds"].as_array_mut().unwrap().reverse();
    rehash(&mut policy);
    validate_policy(&got, &policy.to_string()).unwrap();
}

#[test]
fn rejects_policy_key_and_value_drift() {
    let got = extract(VALID).unwrap();
    let mut missing = policy_for(&got);
    missing["commands"].as_array_mut().unwrap().pop();
    rehash(&mut missing);
    assert!(validate_policy(&got, &missing.to_string())
        .unwrap_err()
        .contains("missing=[\"LOAD_TAG\"]"));
    let mut wrong = policy_for(&got);
    wrong["commands"][1]["value"] = json!(7);
    rehash(&mut wrong);
    assert!(validate_policy(&got, &wrong.to_string())
        .unwrap_err()
        .contains("wrong_values"));
}

fn policy_for(extraction: &luau_aot_ledger::Extraction) -> Value {
    let commands: Vec<_> = extraction
        .commands
        .members
        .iter()
        .map(|member| {
            json!({
                "command": member.name,
                "value": member.value,
                "class": "direct",
                "wasm_features": [],
                "runtime_symbols": [],
                "may_allocate": false,
                "may_raise": false,
                "may_call_luau": false,
                "safepoint": false,
                "rejoins": false,
                "oracle": "test oracle",
                "tests": [],
                "status": "unimplemented"
            })
        })
        .collect();
    let kind_rows = |members: &[luau_aot_ledger::Member]| -> Vec<Value> {
        members
            .iter()
            .map(|member| {
                json!({
                    "kind": member.name,
                    "value": member.value,
                    "treatment": "test treatment",
                    "status": "unimplemented"
                })
            })
            .collect()
    };
    let mut policy = json!({
        "schema_version": 1,
        "generator_version": "luau-aot-ledger-v1",
        "pin": "luau-0.725+agentos-patches",
        "input_sha256": extraction.source_sha256,
        "commands": commands,
        "operand_kinds": kind_rows(&extraction.operand_kinds.members),
        "block_kinds": kind_rows(&extraction.block_kinds.members),
        "canonical_hash": "0000000000000000000000000000000000000000000000000000000000000000"
    });
    policy["canonical_hash"] = json!(canonical_policy_hash(&policy).unwrap());
    policy
}

fn rehash(policy: &mut Value) {
    policy["canonical_hash"] = json!(canonical_policy_hash(policy).unwrap());
}

fn rejected(replacement: &str) -> String {
    extract(&VALID.replace("NOP,", replacement)).unwrap_err()
}

#[test]
fn rejects_explicit_values_aliases_directives_and_duplicates() {
    assert!(rejected("NOP = 0,").contains("explicit values"));
    assert!(rejected("NOP, COPY = NOP,").contains("explicit values"));
    assert!(rejected("NOP,\n#define X Y\n").contains("preprocessor"));
    assert!(rejected("NOP, NOP,").contains("duplicate"));
}

#[test]
fn rejects_wrong_types_and_malformed_rows() {
    assert!(
        extract(&VALID.replace("IrCmd /* comment */ : uint8_t", "IrCmd : uint32_t"))
            .unwrap_err()
            .contains("expected underlying type uint8_t")
    );
    assert!(rejected("NOP LOAD_TAG,").contains("malformed enum row"));
    assert!(extract(
        &VALID
            .replace("LOAD_TAG,", "LOAD_TAG,")
            .replace("};\nenum class IrOpKind", "\nenum class IrOpKind")
    )
    .unwrap_err()
    .contains("malformed enum row"));
}

#[test]
fn rejects_unterminated_comments_and_unknown_policy_fields() {
    assert!(extract("/* never closed")
        .unwrap_err()
        .contains("unterminated block comment"));
    let got = extract(VALID).unwrap();
    let mut policy = policy_for(&got);
    policy["fallback"] = json!("unknown");
    rehash(&mut policy);
    assert!(validate_policy(&got, &policy.to_string())
        .unwrap_err()
        .contains("unknown field"));
}

#[test]
fn rejects_missing_effect_metadata_and_unknown_classes() {
    let got = extract(VALID).unwrap();
    let mut missing = policy_for(&got);
    missing["commands"][0]
        .as_object_mut()
        .unwrap()
        .remove("safepoint");
    rehash(&mut missing);
    assert!(validate_policy(&got, &missing.to_string())
        .unwrap_err()
        .contains("missing required field safepoint"));

    let mut bad_class = policy_for(&got);
    bad_class["commands"][0]["class"] = json!("guessed");
    rehash(&mut bad_class);
    assert!(validate_policy(&got, &bad_class.to_string())
        .unwrap_err()
        .contains("unknown lowering class guessed"));
}
