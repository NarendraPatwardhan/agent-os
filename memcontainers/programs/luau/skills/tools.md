---
name: memcontainer-tools
description: 'Discover, describe, and call host-backed tools from Luau through require("tools"), the /svc/tools broker, catalog addresses, and result envelopes.'
---

# Memcontainer Tools

Use Luau's embedded `tools` module for host-backed APIs. It talks to `/svc/tools`, so discovery stays warm inside the VM and calls return structured envelopes.

```lua
local tools = require("tools")

local page = tools.search("create github issue", { limit = 8 })
local rec = tools.describe(page.items[1].address)
local res = tools.call(rec.address, { repo = "acme/web", title = "Bug" })
```

The dotted sugar calls the same broker:

```lua
local res = tools.github.org.main.createIssue({ repo = "acme/web", title = "Bug" })
if res.ok then
	print(res.data.number)
else
	error(res.err.message)
end
```

Addresses have the form `<integration>.<owner>.<connection>.<tool>`, where owner is `org` or `user`. Prefer `tools.search` then `tools.describe` before writing a call, because schemas are intentionally disclosed on demand.

`tools.call` returns `{ ok = true, data = ... }` or `{ ok = false, err = { code = ..., message = ... } }`. Branch on `ok`; do not parse stdout.

Large or binary results come back as a `ToolFile` table:

```lua
local res = tools.call(rec.address, args)
if res.ok and type(res.data) == "table" and res.data._tag == "ToolFile" then
	print(res.data.path, res.data.byteLength, res.data.sha256)
end
```

The `path` is a normal guest file, usually under `/tmp/tools/results`. Use `tools.save(address, args, "/tmp/out.bin")` when the output path is known ahead of time. Remove individual files with normal filesystem commands; `tools.gc()` clears broker-managed files under `/tmp/tools/results`.
