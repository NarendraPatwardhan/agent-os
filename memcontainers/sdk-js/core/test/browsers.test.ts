import assert from "node:assert/strict";
import {
  BROWSER_CONTRACT_DIGEST,
  BROWSER_KIND,
  BROWSER_OP_PAGES_GOTO,
  BROWSER_OP_PAGES_TITLE,
  BROWSER_VERSION,
  decodeBrowserCreateOptions,
  decodeBrowserGotoRequest,
  encodeBrowserMetadata,
  encodeBrowserPage,
  encodeBrowserString,
} from "@mc/contracts/browser";
import { VmBrowsers, browser } from "../src/browsers.js";
import { embeddedGuestLayers } from "../src/guest-layers.js";
import { GUEST_LAYER, portableSidecarGrants } from "../src/sidecars.js";
import type {
  SidecarBackend,
  SidecarCapability,
  SidecarCreateRequest,
  SidecarGrantDescriptor,
  SidecarInstance,
  SidecarInvokeRequest,
} from "../src/sidecars.js";

class BrowserBackend implements SidecarBackend {
  creates: SidecarCreateRequest[] = [];
  invokes: SidecarInvokeRequest[] = [];
  descriptors = new Map<string, SidecarGrantDescriptor>();
  instances = new Map<string, SidecarInstance>();

  async capabilities(): Promise<SidecarCapability[]> {
    return [];
  }
  async enable(name: string, descriptor: SidecarGrantDescriptor): Promise<void> {
    this.descriptors.set(name, descriptor);
  }
  async disable(name: string): Promise<void> {
    this.descriptors.delete(name);
  }
  async create(request: SidecarCreateRequest): Promise<SidecarInstance> {
    this.creates.push(request);
    const options = decodeBrowserCreateOptions(request.body);
    const instance: SidecarInstance = {
      id: "sc_browser_0001",
      grant: request.grant,
      kind: request.kind,
      generation: 7,
      state: "ready",
      createdAtMs: 1_000,
      expiresAtMs: 61_000,
      metadata: encodeBrowserMetadata({
        headless: options.headless,
        viewport: options.viewport!,
        active_page_id: "pg_1",
      }),
    };
    this.instances.set(instance.id, instance);
    return instance;
  }
  async retrieve(id: string): Promise<SidecarInstance> {
    return this.instances.get(id)!;
  }
  async list(kind?: string): Promise<SidecarInstance[]> {
    return [...this.instances.values()].filter((instance) => !kind || instance.kind === kind);
  }
  async invoke(request: SidecarInvokeRequest): Promise<Uint8Array> {
    this.invokes.push(request);
    if (request.operation === BROWSER_OP_PAGES_GOTO) {
      const input = decodeBrowserGotoRequest(request.body);
      return encodeBrowserPage({ id: input.page_id ?? "pg_1", url: input.url, title: "Example" });
    }
    if (request.operation === BROWSER_OP_PAGES_TITLE) {
      return encodeBrowserString({ value: "Example" });
    }
    return new Uint8Array();
  }
  async delete(id: string): Promise<void> {
    this.instances.delete(id);
  }
  async close(): Promise<void> {}
}

async function main(): Promise<void> {
  const browserctl = new Uint8Array([1, 2, 3]);
  const descriptor = browser({ host: "cloud", guest: browserctl, maxInstances: 2 });
  assert.deepEqual(descriptor.contract, {
    kind: BROWSER_KIND,
    version: BROWSER_VERSION,
    digest: BROWSER_CONTRACT_DIGEST,
  });
  assert.equal(descriptor.host, "cloud");
  assert.equal(descriptor.grant.guest, true);
  assert.deepEqual(descriptor[GUEST_LAYER], browserctl);
  assert.notEqual(descriptor[GUEST_LAYER], browserctl);
  browserctl[0] = 9;
  assert.deepEqual(descriptor[GUEST_LAYER], new Uint8Array([1, 2, 3]));
  assert.equal(browser({ guest: true })[GUEST_LAYER], true);
  assert.equal(browser()[GUEST_LAYER], undefined);
  assert.equal(browser().grant.guest, false);
  assert.throws(() => browser({ guest: new Uint8Array() }), /must not be empty/u);
  assert.equal(
    embeddedGuestLayers({
      first: browser({ host: "cloud", guest: new Uint8Array([1, 2, 3]) }),
      second: browser({ host: "cloud", guest: new Uint8Array([1, 2, 3]) }),
    }).length,
    1,
  );
  assert.throws(
    () =>
      embeddedGuestLayers({
        first: browser({ host: "cloud", guest: new Uint8Array([1]) }),
        second: browser({ host: "cloud", guest: new Uint8Array([2]) }),
      }),
    /provide different guest layers/u,
  );
  assert.equal(portableSidecarGrants({ web: browser({ guest: true }) })[0]?.guest, true);
  assert.throws(
    () => portableSidecarGrants({ web: browser({ guest: new Uint8Array([1]) }) }),
    /must delegate its guest layer to the server/u,
  );
  assert.equal(descriptor.grant.fork, "omit");

  const backend = new BrowserBackend();
  const browsers = new VmBrowsers(backend);
  const session = await browsers.create({
    grant: "web",
    viewport: { width: 1440, height: 900 },
  });
  assert.equal(session.id, "sc_browser_0001");
  assert.equal(session.activePageId, "pg_1");
  assert.deepEqual(session.viewport, { width: 1440, height: 900 });
  assert.equal(backend.creates[0]?.kind, BROWSER_KIND);

  const page = await browsers.pages.goto(session.id, {
    pageId: "pg_1",
    url: "https://example.com",
    waitUntil: "domcontentloaded",
  });
  assert.equal(page.title, "Example");
  assert.equal(await browsers.pages.title(session.id), "Example");
  assert.equal(backend.invokes[0]?.generation, 7);

  const stored = backend.instances.get(session.id)!;
  const metadata = stored.metadata;
  stored.metadata = encodeBrowserMetadata({
    headless: false,
    viewport: { width: 1440, height: 900 },
    active_page_id: "pg_1",
  });
  await assert.rejects(browsers.retrieve(session.id), /invalid metadata/);
  stored.metadata = metadata;

  await browsers.delete(session.id);
  assert.deepEqual(await browsers.list(), []);
  await assert.rejects(browsers.create({ timeoutSeconds: 1 }), /timeoutSeconds must be an integer/);
  await assert.rejects(browsers.create({ headless: false }), /headless sessions only/);
  await assert.rejects(
    browsers.computer.type("missing", { text: "x", delayMs: 1_001 }),
    /delayMs must be an integer/,
  );
  assert.throws(() => browser({ maxInstances: 0 }), /maxInstances must be an integer/);
}

await main();
