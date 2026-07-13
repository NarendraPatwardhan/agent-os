# Syntax platform

`syntax` is AgentOS's owned structural parsing stack. Grammar generation is a host build action;
parsing and edits happen inside the guest through one lazy resident service.

## Boundaries

The source of truth is split deliberately:

- `contracts/syntax.kdl` owns protocol messages and the versioned semantic vocabulary. The contract
  projector generates Rust, Zig, and Luau codecs/constants; consumers do not copy wire IDs.
- `bazel/tools/mc-grammar-gen` owns the spanned `.grammar` AST, module elaborator, normalized typed
  Grammar IR, canonical formatter, validation, and parser-pack generator. Its language reference is
  in that directory's `README.md`.
- `grammars/` contains AgentOS-authored grammars. Shared family modules are explicit inputs to
  `mc_grammar`. That rule projects only host IR; `mc_syntax_pack` consumes all selected languages in
  one action and owns generated C, schemas, native semantic tables, diagnostics, and manifests.
- `third_party/tree-sitter` is the pinned MIT-licensed generator/runtime dependency. Its JavaScript
  frontend, CLI product surface, and community grammars are not used. A narrow patch exposes typed
  prepared-parser tables and a renderer layout hook; the packer never scrapes generated C.
- `glue/` links the generic C runtime, generated parsers, and external scanner behind Zig service
  lifecycle and resource policy. `/lib/luau/syntax.luau` is the typed guest client.

The lossless concrete syntax tree remains language-specific. Host-side semantic IR projects concrete
nodes and fields onto the shared vocabulary; the packer compiles that projection into immutable Zig
tables indexed by Tree-sitter symbol and field IDs. Semantic identity is never inferred from
coincidental node spelling, and the guest neither ships nor parses semantic JSON.

## Build and runtime flow

```text
syntax.kdl -> contract projector -> generated Zig/Luau/Rust wire APIs
*.grammar  -> mc-grammar-gen     -> typed grammar JSON + semantic IR
all grammar IR -> mc-syntax-pack -> per-language parser C + shared tables + native registry
parser pack + Tree-sitter C runtime + scanner -> /bin/syntax
/bin/syntax + syntax.luau -> loom image
```

Each language remains an independent Tree-sitter automaton. The packer deterministically renumbers
implementation IDs, then interns only byte-identical action lists and small parse-table rows across
the finished automata. It does not merge grammar states or broaden either language. Parser manifests,
node schemas, and the sharing report remain host build outputs for provenance and inspection; they are
not runtime assets. Until the native registry projects Tree-sitter's public alias-symbol domain, the
packer rejects grammar aliases rather than emitting a semantic table that could misidentify them.

The service owns parser instances, source buffers, trees, queries, and document revisions in guest
linear memory. Handles are session-owned. Node handles are monotonic and never recycled within a
document, then invalidated by edits; document and query handles fail closed after close/session teardown.
Edits validate ranges and overlap before mutation, apply to a copied tree, incrementally reparse, and
commit atomically. Guarded rewrites additionally verify SHA-256 digests and a syntax-error policy.

Hard limits bound source/query sizes, open documents, traversal/query pages, guest memory, fuel, and
table entries. The service uses the `isolated` tier (read-only VFS access, no ambient authority) and is
lazily activated inside `loom`, so every programmable image has structural parsing while resident
memory and startup are paid only after first use.

## Verification

- `//bazel/tools/mc-grammar-gen:dsl_test` covers parsing, elaboration invariants, normalized IR, and
  formatter idempotence/comment preservation.
- `//memcontainers/programs/syntax/grammars:format_test` keeps every owned grammar canonical.
- `//memcontainers/contracts:syntax_sync_tests` prevents checked-in projection drift.
- Lua and Luau grammar targets prove family-module reuse and generator determinism.
- `//memcontainers/programs/syntax/glue:size_limit` holds the optimized service at its measured
  native-table/parser-pack ceiling.
- `//memcontainers/tests/e2e:core --test_arg=syntax` crosses the real kernel, lazy service,
  generated Luau codec, C runtime, Zig glue, queries, incremental edits, guarded rewrites, and stale
  handles.

Generated parser sources are implementation artifacts, never the public API. Changing the protocol or
semantic IDs starts in `syntax.kdl`; changing a grammar starts in `.grammar`; changing the Tree-sitter
fork boundary requires updating its pin, patch, checksum, license audit, and this document.
