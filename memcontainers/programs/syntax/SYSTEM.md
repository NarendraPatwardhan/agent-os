# Syntax platform

`syntax` is AgentOS's owned structural parsing stack. Grammar generation is a host build action;
parsing and edits happen inside the guest through one lazy resident service.

## Boundaries

The source of truth is split deliberately:

- `contracts/syntax.kdl` owns protocol messages and the versioned semantic vocabulary. The contract
  projector generates Rust, Zig, and Luau codecs/constants; consumers do not copy wire IDs.
- `bazel/tools/mc-grammar-gen` owns the `.grammar` frontend, typed Grammar IR, validation, and the
  narrow adapter into the pinned Tree-sitter Rust generator.
- `grammars/` contains AgentOS-authored grammars. Shared family modules are explicit inputs to
  `mc_grammar`; generated C, schemas, semantics, diagnostics, and manifests remain Bazel outputs.
- `third_party/tree-sitter` is the pinned MIT-licensed generator/runtime dependency. Its JavaScript
  frontend, CLI product surface, and community grammars are not used.
- `glue/` links the generic C runtime, generated parsers, and external scanner behind Zig service
  lifecycle and resource policy. `/lib/luau/syntax.luau` is the typed guest client.

The lossless concrete syntax tree remains language-specific. `semantics.json` projects concrete
nodes and fields onto the shared vocabulary; semantic identity is never inferred from coincidental
node spelling.

## Build and runtime flow

```text
syntax.kdl -> contract projector -> generated Zig/Luau/Rust wire APIs
*.grammar  -> mc-grammar-gen     -> parser.c + node-types + semantics + manifest
parser.c + Tree-sitter C runtime + scanner -> /bin/syntax
/bin/syntax + syntax.luau + generated metadata -> loom image
```

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

- `//bazel/tools/mc-grammar-gen:dsl_test` covers frontend parsing and canonical IR.
- `//memcontainers/contracts:syntax_sync_tests` prevents checked-in projection drift.
- Lua and Luau grammar targets prove family-module reuse and generator determinism.
- `//memcontainers/tests/e2e:core --test_arg=syntax` crosses the real kernel, lazy service,
  generated Luau codec, C runtime, Zig glue, queries, incremental edits, guarded rewrites, and stale
  handles.

Generated parser sources are implementation artifacts, never the public API. Changing the protocol or
semantic IDs starts in `syntax.kdl`; changing a grammar starts in `.grammar`; changing the Tree-sitter
fork boundary requires updating its pin, patch, checksum, license audit, and this document.
