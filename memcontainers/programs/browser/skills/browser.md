---
name: agent-os-browser
description: 'Automate a browser sidecar from inside AgentOS using require("browser") or /bin/browser. Use this skill whenever a task needs to navigate web pages, inspect page text or titles, click or fill elements, type keys, scroll, capture screenshots, or manage a browser session from a guest VM. Prefer the Luau browser module for multi-step automation and the CLI for shell-visible one-shot operations.'
---

# AgentOS Browser

Use the typed `browser` module for browser automation from Luau. It controls a leased Chromium
sidecar through the AgentOS host; Chromium does not run inside the WebAssembly VM. Browser
capabilities require either the hosted AgentOS platform or a self-hosted AgentOS server configured
with the browser runner and provider.

The VM must have a named browser grant with guest access enabled. The examples below use the grant
name `web`. A missing, detached, or exhausted grant fails as a browser error rather than falling back
to ambient browser access.

## Workflow

1. Load the module and select the declared grant with `browser.use("web")`.
2. Create a browser session. Keep its `id`; every page and computer operation is scoped to it.
3. Navigate and inspect before interacting. Prefer CSS-selector operations for stable document
   targets and coordinate operations only when the visual surface is the target.
4. Save screenshots or extracted results in the guest filesystem when they are deliverables.
5. Always delete the session when finished. The host also reclaims it when the VM closes or its lease
   expires, but explicit cleanup releases the external resource promptly.

## Luau Pattern

```luau
local browser = require("browser")
local web = browser.use("web")

local session = web.create({
	viewport = { width = 1440, height = 900 },
	timeoutSeconds = 120,
})

local ok, result = pcall(function()
	local page = web.pages.goto(session.id, {
		url = "https://example.com",
		waitUntil = "load",
	})

	print(web.pages.title(session.id, { pageId = page.id }))
	print(web.pages.text(session.id, { pageId = page.id, selector = "h1" }))

	local png = web.computer.screenshot(session.id, {
		pageId = page.id,
		fullPage = true,
	})
	assert(sys.fs.write("/tmp/example.png", png))
	return page
end)

web.delete(session.id)
assert(ok, result)
```

`web.create()` currently creates a headless browser. Its default viewport is 1280 by 720 and its
default timeout is 300 seconds. Pass `headless = false` only when a future contract explicitly
supports it; browser v1 rejects it.

## Page Operations

Page methods accept a session id followed by an options table. `pageId` is optional; omit it to use
the session's active page.

- `web.pages.list(id)` returns the session's pages as `{ id, url, title }` records.
- `web.pages.goto(id, { url, pageId?, waitUntil? })` navigates and returns the resulting page.
  `waitUntil` is `"load"`, `"domcontentloaded"`, `"networkidle"`, or `"commit"`.
- `web.pages.title(id, { pageId? })` returns the page title.
- `web.pages.text(id, { pageId?, selector })` returns the matched element's text content.
- `web.pages.click(id, { pageId?, selector })` scrolls a visible matched element into view and
  clicks its center.
- `web.pages.fill(id, { pageId?, selector, value })` replaces the value of a matched input,
  textarea, or select and dispatches input and change events.

Selectors are CSS selectors evaluated with `document.querySelector`. Prefer stable ids, names, and
semantic data attributes over brittle positional selectors. A missing, invalid, non-visible, or
non-fillable target is an error; do not treat it as a successful no-op.

## Computer Operations

Use coordinate and keyboard operations for canvas applications, terminal surfaces, or interactions
that do not expose a stable DOM target:

- `web.computer.screenshot(id, { pageId?, fullPage? })` returns PNG bytes.
- `web.computer.click(id, { pageId?, x, y })` clicks viewport coordinates.
- `web.computer.type(id, { pageId?, text, delayMs? })` types into the focused target.
- `web.computer.key(id, { pageId?, key })` sends a key such as `"Enter"`, `"Tab"`, or
  `"Control+L"`.
- `web.computer.scroll(id, { pageId?, deltaX?, deltaY? })` scrolls the page.

Take a fresh screenshot after coordinate-driven changes when visual state matters. Coordinates are
relative to the configured viewport and become stale after layout changes, navigation, or scrolling.

## CLI

Use `/bin/browser` for quick shell-visible calls. Every command takes the grant first and emits JSON.
Pass operation input as one JSON argument.

```sh
browser web create '{"viewport":{"width":1280,"height":720}}'
browser web list
browser web pages goto '{"id":"br_123","url":"https://example.com","waitUntil":"load"}'
browser web pages title '{"id":"br_123"}'
browser web pages text '{"id":"br_123","selector":"h1"}'
browser web computer screenshot '{"id":"br_123","fullPage":true,"output":"/tmp/page.png"}'
browser web delete '{"id":"br_123"}'
```

The CLI screenshot operation writes PNG bytes to `output` and returns its path and byte count. The
Luau API returns those bytes directly. Prefer Luau for a sequence that must retain ids, branch on
results, guarantee cleanup, or compose browser output with other in-VM libraries.

## Validation

Validate the observed page state rather than assuming navigation or input succeeded:

- Read the title or a stable selector after navigation.
- Re-read the affected field or nearby status text after an interaction when the page exposes it.
- Check that a screenshot begins with the PNG signature and that a saved file is nonempty.
- Delete the session in both success and failure paths.

For AgentOS browser implementation changes, run the Bazel browser contract, SDK, server, and real
Firecracker browser-sidecar gates. A unit test of request encoding alone does not prove Chromium
boot, navigation, relay, and cleanup.

## Boundaries

- Browser sessions are external leased resources. They are not part of VM memory or filesystem
  snapshots, and a fork does not silently share a live session.
- Guest code sees grant and session identifiers, never provider endpoints, credentials, Firecracker
  controls, or the Chrome DevTools transport.
- Browser v1 is headless and does not provide arbitrary JavaScript evaluation, downloads, uploads,
  tabs creation, cookies, network interception, or accessibility-tree queries.
- `pages.text`, `pages.click`, and `pages.fill` use one CSS selector match. They are not a general
  Playwright locator language.
- Page text, URLs, selectors, screenshots, viewport dimensions, session counts, and operation times
  are contract-bounded. Split large tasks instead of relying on unbounded responses.
- Browser-side network access follows the sidecar provider's policy and is separate from the guest
  VM's `sys.net` capability.
