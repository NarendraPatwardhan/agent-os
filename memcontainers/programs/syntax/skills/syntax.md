---
name: memcontainer-syntax
description: 'Parse, inspect, query, validate, and transactionally edit Lua or Luau source inside a memcontainer using require("syntax") or the syntax CLI. Use this skill whenever a task needs structural code search, concrete syntax trees, Tree-sitter queries, syntax diagnostics, byte-accurate source ranges, guarded rewrites, incremental edits, or reliable code transformations that should preserve or validate syntax.'
---

# Memcontainer Syntax

Use the `loom` image's owned syntax service for structural Lua and Luau work. Parser generation stays
on the host; inside the VM, `require("syntax")` talks to one lazy resident service containing the
generated Lua 5.4 and Luau parsers. The maintained implementation is
`memcontainers/programs/syntax/lib/syntax.luau`; the contract is
`memcontainers/contracts/syntax.kdl`, and proven end-to-end examples live in
`memcontainers/tests/e2e/src/syntax.rs`.

## Workflow

1. Confirm the installed language with `syntax.languages()` when the language is not already known.
2. Open the complete source with `syntax.open(language, source)` and inspect `doc.initial_diagnostics`
   or `doc:diagnostics()` before planning a transformation.
3. Use a concrete Tree-sitter query when the target shape is known. Traverse `doc:tree()` or
   `doc:children()` first when discovering a grammar's concrete node names.
4. Read the exact selected bytes with `doc:text(range)`. Never derive edit offsets from character
   counts or reconstructed text.
5. Prefer `doc:rewrite` for agent-planned changes: bind each replacement to the SHA-256 digest of the
   bytes inspected and select an explicit syntax-validation policy. Use `doc:edit` for ordinary editor
   changes where optimistic source verification is unnecessary.
6. Re-read diagnostics and the affected text after the transaction. Close query and document handles
   when the task is complete.

## Guarded Rewrite Pattern

This pattern finds a declaration structurally, verifies the bytes that were inspected, and commits one
syntax-checked transaction:

```luau
local syntax = require("syntax")
local hash = require("hash")

local source = "local function greet(name: string) return name end"
local doc = syntax.open("luau", source)
assert(#doc:diagnostics() == 0, "input contains syntax errors")

local query = syntax.compile_query(
  "luau",
  "(local_function_declaration name: (identifier) @name)"
)
local capture = assert(doc:captures(query, { include_text = true })(), "function name not found")
local old_text = assert(capture.text)

local result = doc:rewrite({
  revision = doc.revision,
  validation = "error_free",
  edits = {{
    start_byte = capture.node.range.start_byte,
    old_end_byte = capture.node.range.end_byte,
    expected_sha256 = hash.sha256(old_text, { raw = true }),
    replacement = "welcome",
  }},
})

assert(result.revision == doc.revision)
assert(#result.diagnostics == 0)
print(doc:text())

query:close()
doc:close()
```

`expected_sha256` must be the raw 32-byte digest, not its hexadecimal representation. A digest
mismatch rejects the entire transaction, as does a stale revision, overlapping range, invalid range,
or failed syntax policy. Source and tree advance together or neither changes.

## Parsing and Traversal

`syntax.open` returns a document with `revision`, `root_node`, `initial_diagnostics`, and methods for
the live service object:

- `doc:root()` returns the root `NodeSummary` captured at the current revision.
- `doc:tree({ max_depth, page_size })` iterates the tree in preorder. Paging is automatic.
- `doc:children(node, { named_only, page_size })` iterates direct children; `node` may be a summary or
  numeric handle.
- `doc:node(handle)` resolves a handle issued by the current tree revision.
- `doc:text()` returns the full source; `doc:text(node.range)` returns one exact source slice.
- `doc:diagnostics()` returns current parse diagnostics.

A node summary contains:

- `concrete_kind`: the language-specific Tree-sitter node name.
- `semantic_kind`: an optional stable common-vocabulary ID.
- `field_role`: an optional common role ID populated when the node is returned by `doc:children()`.
- `traits`: a list of common semantic trait records shaped as `{ id = ... }`.
- `range`: zero-based byte offsets plus zero-based row/byte-column points.
- `named`, `missing`, `error`, `child_count`, and a revision-scoped `handle`.

Use the generated constants rather than copying semantic numbers:

```luau
local syntax = require("syntax")
local wire = require("syntax_wire")
local doc = syntax.open("lua", "return 1")

for node in doc:tree() do
  if node.semantic_kind == wire.SEMANTIC_KIND_RETURN then
    print("return statement", node.range.start_byte, node.range.end_byte)
  end
end

doc:close()
```

Concrete trees remain language-specific and lossless. Semantic IDs are annotations for shared
vocabulary, not a replacement AST.

## Concrete Queries

Compile a query once and reuse it across documents and revisions of the same language:

```luau
local syntax = require("syntax")
local query = syntax.compile_query("lua", "(function_call) @call")
local doc = syntax.open("lua", "print('hello')")

for capture in doc:captures(query, {
  include_text = true,
  page_size = 64,
  -- range = optional_range,
}) do
  print(capture.name, capture.text, capture.node.concrete_kind)
end

query:close()
doc:close()
```

Queries use concrete Tree-sitter node and field names from the selected grammar. When a query fails,
inspect `doc:tree({ max_depth = ... })` to learn the actual concrete shape instead of guessing names.
Semantic query compilation is not currently available; passing `{ view = "semantic" }` to
`syntax.compile_query` is rejected.

## Editing Rules

`doc:edit(edits)` and `doc:rewrite(plan)` accept one or more replacements. Every range in a transaction
refers to the same pre-edit source. The service sorts ranges, rejects overlap, applies them atomically,
increments `doc.revision`, updates `doc:root()`, and returns changed ranges plus diagnostics.

```luau
local result = doc:edit({
  { start_byte = 6, old_end_byte = 9, replacement = "total" },
  { start_byte = 14, old_end_byte = 15, replacement = "42" },
})
```

Choose the rewrite policy deliberately:

- `"error_free"`: reject the candidate if its resulting tree contains any syntax error.
- `"no_new_errors"` (default): reject a new error when the old tree was error-free.
- `"allow"`: accept the resulting tree even if it contains syntax errors.

After any successful edit, all previously issued node handles are stale. Capture ranges or query again;
do not retain nodes across revisions. Query handles remain reusable for the same language.

## CLI

Use the CLI for quick inspection and CI-style syntax checks; use the Luau module for paging and edits.

```sh
syntax languages
syntax parse luau /tmp/source.luau
syntax check luau /tmp/source.luau
syntax query luau /tmp/source.luau '(local_function_declaration name: (identifier) @name)'
```

`syntax check` exits nonzero when parse diagnostics are present. `syntax parse` prints only the root
kind and byte range, while `syntax query` prints capture names and text from its first bounded page.

## Validation

For a task-level transformation, validate the actual candidate source:

- Use `"error_free"` guarded rewrites when clean syntax is required.
- Assert the returned diagnostics policy and inspect `doc:text()` after committing.
- Run `/bin/luau --check file.luau` as an additional Luau type/syntax check when appropriate; the
  structural parser is not a type checker.

For repository changes to the parser stack, run:

```sh
bazel test //bazel/tools/mc-grammar-gen:dsl_test
bazel test //memcontainers/programs/syntax/grammars:format_test
bazel test //memcontainers/tests/e2e:core --test_arg=syntax
```

## Boundaries

- Installed languages are currently Lua 5.4 and Luau. Do not assume community Tree-sitter grammars are
  present.
- Ranges and columns are UTF-8 byte coordinates, not Unicode code-point indices.
- Source is limited to 768 KiB, query source to 64 KiB, and traversal/query results are paged and
  bounded. A session may hold at most 16 open documents.
- Diagnostics report parser errors and missing nodes; they do not provide type checking, linting,
  formatting, name resolution, or semantic refactoring.
- Edits replace source ranges; there is no mutable AST API or source pretty-printer.
- Documents and queries are session-owned service handles. Closed handles and pre-edit node handles
  fail closed rather than being recycled.
