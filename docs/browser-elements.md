# Browser elements

`@mc/elements` is a Lit custom-element integration layer over `@mc/core`. It provides artifact loading,
VM ownership and sharing, terminal rendering, and a code editor without requiring a React/Vue/Svelte
adapter.

## Setup

Importing the package registers all four elements. Include its stylesheet for light-DOM terminal and
editor presentation.

```js
import {
  defineElements,
  prefetchArtifacts,
  setArtifactSources,
} from "@mc/elements";
import "@mc/elements/styles.css";

setArtifactSources({
  kernel: "/mc/kernel.wasm",
  image: "/mc/loom.tar",
  images: {
    minimal: "/mc/minimal.tar",
    atlas: "/mc/atlas.tar",
  },
  catalogCompiler: "/mc/catalog-compiler.wasm",
});

prefetchArtifacts(undefined, "loom");
defineElements();
```

`defineElements()` is idempotent and is already called by the package import. It is exported for
explicit registration flows and is a no-op during SSR where `customElements` does not exist.

## Artifact helpers

### `setArtifactSources(options)`

Configures the page-global artifact registry before elements boot.

| Field | Meaning |
|---|---|
| `kernel` | Default kernel URL |
| `image` | Default image URL; updates `default` and `base:latest` aliases |
| `images` | Additional or overriding logical-name-to-URL map |
| `catalogCompiler` | Compiler URL for connections and runtime host-tool registration |

URLs are fetched once per URL and cached as promises. A failed fetch is removed from the cache so a
later request can retry.

### `prefetchArtifacts(kernel?, image?)`

Starts kernel and image downloads without booting a VM. It is fire-and-forget; boot observes the same
cached promises.

### `loadCatalogCompiler()`

Returns the memoized compiler-byte promise, or `null` when no compiler URL was registered. This is
useful with `defaultCatalogCompiler()` for an integration picker.

## VM resolution order

A VM-aware element resolves its VM in this order:

1. explicit JavaScript `.vm` property;
2. `VmHost` context from an ancestor `<mc-sandbox>`; or
3. standalone boot from its own attributes, if allowed.

This makes controlled application state, shared sandbox state, and one-tag demos use the same element.

## `<mc-sandbox>`

Owns one VM and provides a stable `VmHost` context to descendants. It renders its ordinary children
and an optional status slot, but no VM chrome.

```html
<mc-sandbox image="loom" show-status>
  <mc-terminal></mc-terminal>
</mc-sandbox>
```

### Attributes and properties

| Name | Shape | Default | Meaning |
|---|---|---|---|
| `runtime` | `local`, `browser`, `remote` | `browser` | Hosting runtime |
| `image` | logical name or URL | default image | Image source |
| `net` | boolean | false | Enable network |
| `endpoint` | string | none | Remote endpoint |
| `token` | string | none | Remote bearer token |
| `deterministic` | boolean | false | Repeatable clock/RNG |
| `kernel` | URL string | registered default | Kernel override |
| `show-status` | boolean | false | Render default status pill |
| `controlledVm` | JavaScript `Vm` property | none | Externally owned VM |

Controlled mode never closes the supplied VM. Set `controlledVm` before connection. The application
remains responsible for its lifetime.

### Read-only properties

| Property | Meaning |
|---|---|
| `vm` | Current VM, or `undefined` before boot |
| `vmHost` | Stable host/context object |

### Methods

| Method | Meaning |
|---|---|
| `snapshot()` | Capture current VM |
| `fork()` | Return an independent VM; sandbox keeps the original |
| `restore(bytes)` | Replace owned VM with restored state and rebind children |
| `reboot()` | Replace owned VM with a fresh boot from the same options |

Restore and reboot are rejected in controlled mode because the sandbox does not own the external
handle it would replace.

### Events

| Event | `detail` | Meaning |
|---|---|---|
| `mc-boot` | `{ vm }` | Initial VM is ready |
| `mc-error` | `{ error }` | Boot failed; error is display text |
| `mc-fork` | `{ vm }` | `fork()` returned a branch |
| `mc-vm-changed` | `{ vm }` | Restore or reboot swapped the provided VM |

Events bubble and cross shadow boundaries.

### Slots and reflected state

The default slot contains VM-aware children. The named `status` slot can replace the built-in status
pill. The host reflects `phase="booting|ready|error"` while connected.

## `<mc-terminal>`

An xterm terminal bound to `vm.shell()`. It may live inside a sandbox, receive `.vm`, or boot a
standalone VM.

```html
<mc-terminal
  image="loom"
  label="agent · browser"
  cursor="block"
  line-height="1.5"
></mc-terminal>
```

### Attributes and properties

| Name | Default | Meaning |
|---|---|---|
| `cols`, `rows` | auto-fit | Fixed terminal grid dimensions |
| `cursor` | `bar` | `bar`, `block`, or `underline` |
| `line-height` | xterm default | Line-height multiplier |
| `language` | `sh` | Dedicated `sh` or `luau` shell |
| `replay-history` | true | Replay shell history on attach |
| `net` | false | Standalone VM network |
| `runtime` | `browser` | Standalone runtime |
| `image`, `endpoint`, `token`, `kernel` | none/default | Standalone boot inputs |
| `deterministic` | false | Standalone deterministic mode |
| `label` | browser-live caption | Title-bar text |
| `working` | false | Reflected working indicator |
| `manual` | false | Wait for explicit VM; never standalone-boot |
| `vm` | none | Explicit JavaScript VM property |

### Methods and properties

| Member | Meaning |
|---|---|
| `attach(vm)` | Bind an externally supplied VM |
| `send(data)` | Write string/bytes to shell input |
| `focus()` | Focus xterm |
| `fit()` | Refit to element dimensions |
| `ensureColumns(count)` | Widen backing grid and permit horizontal scrolling |
| `terminal` | Underlying xterm instance for advanced use |

### Events

| Event | `detail` |
|---|---|
| `mc-ready` | `{ vm }` |
| `mc-data` | user-input `Uint8Array` |
| `mc-output` | `{ bytes, text }` |
| `mc-exit` | none |

`mc-data` describes terminal user input. Calling `send()` writes to the shell but does not synthesize a
user event.

## `<mc-xterm>`

Presentational byte terminal with no VM knowledge.

```js
const term = document.querySelector("mc-xterm");
term.addEventListener("mc-data", (event) => transport.send(event.detail));
transport.onmessage = (bytes) => term.write(bytes);
```

Attributes: `cols`, `rows`, and `cursor`. Methods: `write`, `reset`, `clear`, `fit`, and `focus`.
`terminal` exposes the underlying xterm object. Writes before mount are buffered. `mc-data` contains
user-input bytes.

## `<mc-editor>`

CodeMirror editor primitive. It is VM-agnostic: it edits source and emits run intent; it does not load
or save a guest path.

```html
<mc-editor language="javascript" line-wrapping>
  const result = await vm.exec("date");
  console.log(result.stdout);
</mc-editor>
```

There is no `path` attribute. Applications bind files through JavaScript using `vm.fs.readText()` and
`vm.fs.write()`.

### Attributes and properties

| Name | Default | Meaning |
|---|---|---|
| `language` | `javascript` | `javascript`, `typescript`, or `plain` editor grammar |
| `value` | empty/seed text | Two-way source string |
| `read-only` | false | Disable edits and caret |
| `line-wrapping` | false | Soft-wrap lines |
| `auto-focus` | false | Focus after mount |
| `extensions` | none | JavaScript-only CodeMirror extension list set before render |

The editor lazily imports CodeMirror. Changing language/read-only/wrapping reconfigures it without
discarding document or undo history.

### Methods, properties, and events

| Member | Meaning |
|---|---|
| `source` | Current editor text |
| `run()` | Emit `mc-run` |
| `focus()` | Focus CodeMirror |
| `input` | Standard bubbling change event |
| `mc-run` | Bubbling event with `{ source }`; also emitted by Mod-Enter |

## `VmHost`

`makeVmHost(bootOptions)` starts booting immediately and returns a stable lifecycle object:

| Member | Meaning |
|---|---|
| `vm`, `shell` | Current resources, initially undefined |
| `ready` | First-boot promise |
| `createOpts` | Resolved byte-based options after load |
| `subscribe(callback)` | Observe VM swaps; returns unsubscribe |
| `snapshot`, `fork` | Act on current VM |
| `restore`, `reboot` | Swap owned VM and notify subscribers |
| `close` | Dispose owned VM |

`resolveCreateOptions(bootOptions)` performs only artifact/runtime resolution and returns ordinary core
create options. It is useful when an application wants the element loader but owns `mc.create()` itself.

`vmHostContext` is the Lit context key used by custom integrations. `installContextRoot()` is an
internal compatibility hook and should not be called by application code.

## Styling

Import `@mc/elements/styles.css`. The light-DOM terminal/editor components are designed to accept host
design-system variables with `--mc-*` overrides taking precedence.

Important terminal variables include:

- `--mc-term-bg-override`
- `--mc-term-fg`
- `--mc-term-fg-subtle`
- `--mc-term-cursor`
- `--mc-term-pad`
- `--mc-scrollbar`
- `--mc-scrollbar-hover`

General fallbacks include `--mc-fg`, `--mc-fg-subtle`, `--mc-font-sans`, `--mc-font-mono`, and
`--mc-accent`. Size the element or its wrapper explicitly so xterm has a definite box to fit.
