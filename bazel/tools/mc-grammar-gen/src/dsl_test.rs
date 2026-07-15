use mc_parser_dsl::parse;
use mc_parser_elaborate::elaborate;
use mc_parser_format::format;
use mc_parser_ir::{Associativity, Rule};
use mc_tree_sitter_backend::grammar_json;

#[test]
fn elaborates_ebnf_modules_slots_semantics_and_operators() {
    let family = parse(
        r#"
family demo.core "1"

fragment separated(item, separator) = (item (separator item)*)?
skip whitespace
token whitespace = /\s+/
token identifier = /[a-z]+/
slot annotation
open expression = identifier
item = name:identifier annotation?

infix binary_expression over expression
  => operator(left, right)
  left 1: "+" | "-"
  right 2: "^"
"#,
        "demo-core.grammar",
    )
    .unwrap();

    let root = parse(
        r#"
grammar demo "1.2.3"
use demo.core
start document

extend expression = binary_expression
fill annotation = ":" identifier
document = body:separated(item, ",")
  => module(body)
     derives scope
"#,
        "demo.grammar",
    )
    .unwrap();

    let grammar = elaborate(root, vec![("demo.core".into(), family)]).unwrap();
    assert_eq!(grammar.start, "document");
    assert!(grammar
        .semantic
        .iter()
        .any(|mapping| { mapping.concrete == "document" && mapping.semantic == "module" }));
    assert!(matches!(grammar.rules["identifier"], Rule::Token(_)));
    let Rule::Choice(rows) = &grammar.rules["binary_expression"] else {
        panic!("operator rows")
    };
    assert!(matches!(
        rows[0],
        Rule::Precedence {
            associativity: Associativity::Left,
            ..
        }
    ));
    assert_eq!(grammar_json(&grammar)["name"], "demo");
}

#[test]
fn rejects_recursive_fragments() {
    let family = parse(
        r#"
family bad "1"
fragment loop(item) = loop(item)
root = loop("x")
"#,
        "bad.grammar",
    )
    .unwrap();
    let root = parse("grammar demo \"1\"\nuse bad\nstart root\n", "demo.grammar").unwrap();
    let error = elaborate(root, vec![("bad".into(), family)]).unwrap_err();
    assert!(error.contains("recursive fragment"), "{error}");
}

#[test]
fn rejects_semantic_roles_without_concrete_fields() {
    let root = parse(
        r#"
grammar demo "1"
start document
document = identifier
  => module(body)
token identifier = /[a-z]+/
"#,
        "demo.grammar",
    )
    .unwrap();
    let error = elaborate(root, Vec::new()).unwrap_err();
    assert!(error.contains("missing field body"), "{error}");
}

fn compile(source: &str) -> Result<mc_parser_ir::GrammarIr, String> {
    let root = parse(source, "test.grammar").map_err(|error| error.to_string())?;
    elaborate(root, Vec::new())
}

#[test]
fn rejects_extending_closed_productions() {
    let error =
        compile("grammar demo \"1\"\nstart root\nroot = item\nitem = \"x\"\nextend item = \"y\"\n")
            .unwrap_err();
    assert!(error.contains("item is not open"), "{error}");
}

#[test]
fn rejects_unfilled_slots_in_required_positions() {
    let error =
        compile("grammar demo \"1\"\nstart root\nslot annotation\nroot = \"x\" annotation\n")
            .unwrap_err();
    assert!(error.contains("resolves to an unavailable slot"), "{error}");
}

#[test]
fn permits_unfilled_slots_in_optional_positions() {
    let grammar =
        compile("grammar demo \"1\"\nstart root\nslot annotation\nroot = \"x\" annotation?\n")
            .unwrap();
    assert!(matches!(grammar.rules["root"], Rule::Literal(_)));
}

#[test]
fn rejects_nullable_repetition() {
    let error = compile("grammar demo \"1\"\nstart root\nroot = (\"x\"?)*\n").unwrap_err();
    assert!(error.contains("repeats a nullable expression"), "{error}");
}

#[test]
fn rejects_symbols_inside_tokens_before_tree_sitter() {
    let error =
        compile("grammar demo \"1\"\nstart root\ntoken letter = /[a-z]/\ntoken root = letter+\n")
            .unwrap_err();
    assert!(
        error.contains("lexical rules must contain only literals and patterns"),
        "{error}"
    );
}

#[test]
fn rejects_invalid_backend_names_in_the_frontend() {
    let error = parse(
        "grammar demo \"1\"\nstart root\nbad-name = \"x\"\nroot = bad-name\n",
        "test.grammar",
    )
    .unwrap_err();
    assert!(
        error.to_string().contains("must be a C identifier"),
        "{error}"
    );
}

#[test]
fn rejects_undefined_skip_symbols() {
    let error =
        compile("grammar demo \"1\"\nstart root\nskip missing\nroot = \"x\"\n").unwrap_err();
    assert!(
        error.contains("skip expression references undefined"),
        "{error}"
    );
}

#[test]
fn formatter_is_idempotent_and_preserves_comments() {
    let source = r#"// language comment
grammar demo "1"
use demo.core
start document

// rule comment
document=body:item* // inline comment
  =>module(body)
     derives scope
"#;
    let module = parse(source, "format.grammar").unwrap();
    let formatted = format(&module);
    assert!(formatted.contains("// language comment"));
    assert!(formatted.contains("// rule comment"));
    assert!(formatted.contains("// inline comment"));
    let reparsed = parse(&formatted, "format.grammar").unwrap();
    assert_eq!(format(&reparsed), formatted);
}
