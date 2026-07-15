//! Owned parser-stack E2E: generated Rust tables + C runtime + Zig service + generated binary Luau
//! codec, all inside the real kernel. These tests deliberately cross every boundary in one call.
use crate::*;

#[test]
fn syntax_luau_parses_queries_and_edits_transactionally() {
    let mut s = boot_loom();
    s.host.write_file(
        "/tmp/syntax-e2e.luau",
        br#"local syntax = require("syntax")
local hash = require("hash")
local languages = syntax.languages()
print(languages[1].name, languages[2].name)
local source = "local function greet(name: string) return name end"
local doc = syntax.open("luau", source)
print(doc:root().concrete_kind, doc:root().semantic_kind, #doc:diagnostics())
local query = syntax.compile_query("luau", "(local_function_declaration name: (identifier) @name)")
local capture = doc:captures(query, { include_text = true })()
print(capture.name, capture.text)
local changed = doc:edit({ { start_byte = 15, old_end_byte = 20, replacement = "hello" } })
print(changed.revision, doc:text())
local rewritten = doc:rewrite({
  validation = "no_new_errors",
  edits = { { start_byte = 42, old_end_byte = 46, expected_sha256 = hash.sha256("name", { raw = true }), replacement = "\"ok\"" } },
})
print(rewritten.revision, doc:text())
query:close()
doc:close()
"#,
    )
    .expect("write syntax e2e script");
    let out = s.run_for_output_heavy("luau /tmp/syntax-e2e.luau");
    assert!(out.contains("lua\tluau\r\n"), "language registry:\n{out}");
    assert!(
        out.contains("source_file\t1\t0\r\n"),
        "concrete/semantic root and diagnostics:\n{out}"
    );
    assert!(
        out.contains("name\tgreet\r\n"),
        "concrete query capture:\n{out}"
    );
    assert!(
        out.contains("local function hello"),
        "incremental edit:\n{out}"
    );
    assert!(out.contains("return \"ok\" end"), "guarded rewrite:\n{out}");
}

#[test]
fn syntax_service_is_lazy_and_survives_stale_handles() {
    let mut s = boot_loom();
    assert_eq!(
        s.run_for_output("ls /svc | grep '^syntax$' || echo cold"),
        "cold\r\n"
    );
    s.host
        .write_file(
            "/tmp/stale.luau",
            br#"local syntax = require("syntax")
local doc = syntax.open("lua", "return 1")
local old = doc:root()
doc:edit({ { start_byte = 7, old_end_byte = 8, replacement = "2" } })
local ok, err = pcall(function() return doc:node(old.handle) end)
print(ok, string.find(tostring(err), "stale_handle") ~= nil)
doc:close()
"#,
        )
        .expect("write stale handle script");
    assert_eq!(
        s.run_for_output_heavy("luau /tmp/stale.luau"),
        "false\ttrue\r\n"
    );
    assert_eq!(s.run_for_output("ls /svc | grep '^syntax$'"), "syntax\r\n");
    assert_eq!(
        s.run_for_output("syntax languages"),
        "lua\t5.4.0\r\nluau\t0.725.0\r\n"
    );
}
