fn runfile(path: &str) -> String {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

fn block_after(src: &str, needle: &str) -> String {
    let start = src
        .find(needle)
        .unwrap_or_else(|| panic!("missing block header {needle:?}"));
    let open = src[start..]
        .find('{')
        .map(|i| start + i)
        .unwrap_or_else(|| panic!("missing block open for {needle:?}"));
    let mut depth = 0i32;
    for (idx, ch) in src[open..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return src[open + 1..open + idx].to_string();
                }
            }
            _ => {}
        }
    }
    panic!("unterminated block {needle:?}");
}

fn message_fields(block: &str) -> Vec<String> {
    block
        .lines()
        .filter_map(|line| {
            let line = line.trim_start();
            let rest = line.strip_prefix("field \"")?;
            Some(rest.split('"').next().unwrap_or("").to_string())
        })
        .collect()
}

fn component_block(openapi: &str, name: &str) -> String {
    let header = format!("    \"{name}\":\n");
    let start = openapi
        .find(&header)
        .unwrap_or_else(|| panic!("missing OpenAPI component {name}"));
    let rest = &openapi[start + header.len()..];
    let end = rest
        .find("\n    \"")
        .unwrap_or(rest.len());
    rest[..end].to_string()
}

#[test]
fn exec_rest_schema_is_a_projection_of_exec_request() {
    let control = runfile("_main/memcontainers/contracts/control.kdl");
    let wire = runfile("_main/memcontainers/contracts/wire.kdl");
    let openapi = runfile("_main/memcontainers/contracts/gen/wire.gen.openapi.yaml");

    let exec_request = block_after(&control, "message \"ExecRequest\"");
    let exec_request_fields = message_fields(&exec_request);
    assert_eq!(exec_request_fields, ["cmd", "cwd", "env", "stdin"]);

    let exec_schema = block_after(&wire, "schema \"Exec\"");
    assert!(
        wire.contains("schema \"Exec\" kind=\"json\" source=\"control.kdl\" from-message=\"ExecRequest\""),
        "Exec schema must derive from ExecRequest, not a hand-kept duplicate"
    );
    for field in &exec_request_fields {
        assert!(
            !exec_schema.contains(&format!("field \"{field}\"")),
            "Exec schema must not locally redeclare source field {field}"
        );
    }
    assert!(
        exec_schema.contains("project \"stdin\" from=\"stdin\" type=\"string\" encoding=\"utf8\"")
            && exec_schema
                .contains("project \"stdinBase64\" from=\"stdin\" type=\"string\" encoding=\"base64\""),
        "stdin text/base64 REST projections must stay explicit"
    );

    let exec_component = component_block(&openapi, "Exec");
    for field in &exec_request_fields {
        assert!(
            exec_component.contains(&format!("x-agentos-source-field: \"{field}\"")),
            "OpenAPI Exec component lost source marker for {field}"
        );
    }
    assert!(
        exec_component.contains("x-agentos-encoding: \"utf8\"")
            && exec_component.contains("x-agentos-encoding: \"base64\""),
        "OpenAPI Exec component lost stdin encoding markers"
    );
}
