# Tree-sitter integration boundary

AgentOS pins Tree-sitter commit `d11d18f746fdfd1826362c2531ce06808f386b02` through Bazel. The
archive contributes only the Rust generator core and generic C runtime. AgentOS does not execute
Tree-sitter's JavaScript DSL, load community grammars, or use its CLI/config/loader product surface.

`//bazel/tools/mc-grammar-gen` owns the declarative frontend and translates its typed IR to the
upstream grammar JSON boundary. `/bin/syntax` links generated parsers and the C runtime through Zig.
Any future source modifications belong in `patches/` and must keep the archive pin and MIT notice.
