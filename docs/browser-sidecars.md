# Browser sidecars

A browser sidecar is a leased Chromium instance attached to one AgentOS VM. It is separate from the
`browser` runtime: the runtime says where the AgentOS WebAssembly kernel runs, while a browser sidecar
is an external resource controlled through `vm.browsers`. A VM in any runtime can use the same typed
API when its host has a browser-sidecar provider.

Browser capabilities depend on infrastructure outside the portable AgentOS VM. They are available
through the hosted AgentOS platform, or from a self-hosted AgentOS server configured with the browser
runner and a browser-capable sidecar provider. Selecting the `browser` runtime alone does not
provision Chromium: that runtime runs the AgentOS kernel in the page, while the sidecar provider owns
the external browser session.

Import `browser()` alongside `mc` and declare a named grant when creating the VM:

```js
import { browser, mc } from "@mc/core";

const vm = await mc.create({
  runtime: "remote",
  endpoint,
  token,
  sidecars: {
    web: browser({ guest: true, maxInstances: 2 }),
  },
});

const session = await vm.browsers.create({
  grant: "web",
  viewport: { width: 1440, height: 900 },
});

try {
  const page = await vm.browsers.pages.goto(session.id, {
    url: "https://example.com",
    waitUntil: "load",
  });
  console.log(await vm.browsers.pages.title(session.id, { pageId: page.id }));
} finally {
  await vm.browsers.delete(session.id);
  await vm.close();
}
```

The sidecar ID is scoped to the owning VM. It is not a provider endpoint, a credential, or a globally
addressable browser identifier.

## `browser(options)`

`browser()` returns a contract-bound sidecar grant descriptor. It allocates nothing by itself.

Guest browser control is one released layer, `browserctl.tar`, carrying `/bin/browser`,
`require("browser")`, its generated wire module, and `/skills/browser.md`. An embedded caller passes
those bytes as `guest`; a remote caller passes `true` and the served AgentOS host installs its configured
copy. With the default `false`, browser control remains available through `vm.browsers` without adding
guest files.

| Option         | Default | Meaning                                                                    |
| -------------- | ------- | -------------------------------------------------------------------------- |
| `host`         | none    | Private host alias for an embedded VM; forbidden on a remote VM            |
| `guest`        | `false` | Embedded `browserctl.tar` bytes, or `true` for a server-owned remote layer |
| `maxInstances` | `1`     | Maximum live browser instances under this grant                            |

For an embedded `local` VM, connect the descriptor to a private sidecar host:

```js
import { browser, mc, remoteSidecars } from "@mc/core";

const browserctl = new Uint8Array(await (await fetch("/mc/browserctl.tar")).arrayBuffer());

const vm = await mc.create({
  runtime: "local",
  sidecarHosts: {
    cloud: remoteSidecars({ endpoint, token }),
  },
  sidecars: {
    web: browser({ host: "cloud", guest: browserctl }),
  },
});
```

An AgentOS VM embedded in a browser page cannot start Firecracker itself, so it also uses a private
remote sidecar host. A `remote` AgentOS VM omits both `host` and `sidecarHosts`, uses `guest: true`, and
lets its served host choose placement and install `browserctl.tar`. Host aliases, tokens, and embedded
layer attachments never enter the portable grant or snapshots.

## `vm.browsers`

Every `Vm` has one `VmBrowsers` facade. A grant is still required before `create()` can succeed.

| Method             | Result                      | Meaning                                 |
| ------------------ | --------------------------- | --------------------------------------- |
| `create(options?)` | `Promise<BrowserSession>`   | Allocate and initialize one browser     |
| `retrieve(id)`     | `Promise<BrowserSession>`   | Refresh current state and metadata      |
| `list()`           | `Promise<BrowserSession[]>` | List browser instances owned by this VM |
| `delete(id)`       | `Promise<void>`             | Idempotently destroy an instance        |

`create()` accepts:

| Option           | Default      | Meaning                                                     |
| ---------------- | ------------ | ----------------------------------------------------------- |
| `grant`          | `"web"`      | Grant name from `sidecars`                                  |
| `headless`       | `true`       | Browser v1 is headless-only                                 |
| `timeoutSeconds` | `300`        | Session operation ceiling, from 10 through 300 seconds      |
| `viewport`       | `1280 × 720` | Width and height; each edge is from 320 through 4096 pixels |
| `signal`         | none         | Cancels the create request                                  |

A `BrowserSession` is a plain value with `id`, `grant`, `status`, `createdAt`, `expiresAt`,
`headless`, `viewport`, and `activePageId`. Retrieve it again when current lifecycle state matters;
the value is not a live client object.

## `vm.browsers.pages`

`VmBrowserPages` operates on a browser ID. Methods that accept `pageId` use the active page when it is
omitted.

| Method                       | Result                   | Meaning                                     |
| ---------------------------- | ------------------------ | ------------------------------------------- |
| `list(browserId, options?)`  | `Promise<BrowserPage[]>` | List current page targets                   |
| `goto(browserId, options)`   | `Promise<BrowserPage>`   | Navigate a page and wait for a lifecycle    |
| `title(browserId, options?)` | `Promise<string>`        | Read `document.title`                       |
| `text(browserId, options)`   | `Promise<string>`        | Read a selector's text content              |
| `click(browserId, options)`  | `Promise<void>`          | Scroll a selector into view and click it    |
| `fill(browserId, options)`   | `Promise<void>`          | Replace an input, textarea, or select value |

`goto()` requires `url`. Its `waitUntil` value may be `"load"`, `"domcontentloaded"`,
`"networkidle"`, or `"commit"`. Locator operations require `selector`; `fill()` additionally requires
`value`, which may be empty. Every options object accepts `signal`.

A `BrowserPage` contains `id`, `url`, and `title`. Page IDs are opaque and valid only for their owning
browser instance. Browser v1 blocks page-created popups; refresh `list()` rather than deriving or
persisting target IDs across instances.

## `vm.browsers.computer`

`VmBrowserComputer` provides bounded input and capture operations:

| Method                            | Result                | Meaning                                      |
| --------------------------------- | --------------------- | -------------------------------------------- |
| `screenshot(browserId, options?)` | `Promise<Uint8Array>` | Capture a viewport or full page as PNG       |
| `click(browserId, options)`       | `Promise<void>`       | Click viewport coordinates                   |
| `type(browserId, options)`        | `Promise<void>`       | Insert text into the focused element         |
| `key(browserId, options)`         | `Promise<void>`       | Send a key or modifier chord                 |
| `scroll(browserId, options)`      | `Promise<void>`       | Dispatch horizontal and vertical wheel input |

All methods accept an optional `pageId` and `signal`. `screenshot()` accepts `fullPage`; full-page
captures fail when their dimensions or encoded result exceed the contract limit. `type()` accepts
`delayMs` from 0 through 1000. Keys include characters, navigation keys such as `Enter` and
`ArrowDown`, and chords such as `Control+A`. Coordinates must fall within the configured viewport.

## Lifecycle, network, and snapshots

Browser operations re-resolve the instance generation before invoking it, so a stale client-side value
cannot address a replacement resource. Timeouts, cancellation, invalid selectors, contract mismatch,
and provider failure surface as `SidecarError` through the generic sidecar boundary.

The reference Firecracker browser profile permits public IPv4 web egress and blocks host, loopback,
link-local, private, carrier-grade NAT, documentation, multicast, and reserved ranges. It exposes no
provider control socket or credential to Chromium. Proxy, credential, and custom destination policy are
provider concerns and are not browser-v1 client fields.

Full and incremental AgentOS snapshots do not contain Chromium memory. The current browser fork policy
is `omit`: `vm.fork()` succeeds, the child retains its portable grant, no browser instance is shared, and
the child reports a `sidecar_fork_omitted` warning. Delete browsers explicitly when finished; `vm.close()`
also initiates best-effort cleanup and the provider lease is the crash backstop.

For the byte-level lifecycle API and host connectors, see [Sidecars](./sidecars.md).
