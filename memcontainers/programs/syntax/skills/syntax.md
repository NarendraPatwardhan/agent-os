# Structural code parsing

The `syntax` flavor provides Lua 5.4 and Luau parsers through one warm resident service.

```luau
local syntax = require("syntax")
local doc = syntax.open("luau", "local function greet(name: string) return name end")

for node in doc:tree({ view = "concrete" }) do
  print(node.concrete_kind, node.range.start_byte, node.range.end_byte)
end

local query = syntax.compile_query("luau", "(function_declaration name: (function_name) @name)")
for capture in doc:captures(query, { include_text = true }) do
  print(capture.name, capture.text)
end

query:close()
doc:close()
```

Ranges are zero-based byte offsets. `doc:edit` applies non-overlapping editor changes against the
current revision. `doc:rewrite` additionally requires a 32-byte SHA-256 digest of every replaced
range and can reject candidates that introduce syntax errors. An edit is transactional: source and
tree advance together or neither changes.
