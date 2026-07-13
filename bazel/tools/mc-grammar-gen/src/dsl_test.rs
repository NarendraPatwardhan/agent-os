use mc_parser_dsl::parse;
use mc_parser_ir::Rule;

#[test]
fn parses_templates_precedence_and_vocabulary() {
    let src = r#"
language demo
version "1.2.3"
template separated(item, separator) = optional(seq(item, repeat(seq(separator, item))))
start document
extras { pattern("\\s+") }
rule document = field(body, separated(identifier, ","))
token identifier = pattern("[A-Za-z_][A-Za-z0-9_]*")
vocabulary document -> module { role body = body; trait scope; }
"#;
    let grammar = parse(src, "demo.grammar").unwrap();
    assert_eq!(grammar.start, "document");
    assert!(matches!(grammar.rules["identifier"], Rule::Token(_)));
    assert_eq!(grammar.semantic[0].semantic, "module");
    assert_eq!(grammar.to_tree_sitter_json()["name"], "demo");
}

#[test]
fn rejects_recursive_templates() {
    let src = "language x\ntemplate loop(x) = loop(x)\nstart root\nrule root = loop(\"x\")\n";
    assert!(
        parse(src, "recursive.grammar")
            .unwrap_err()
            .to_string()
            .contains("recursive template")
    );
}
