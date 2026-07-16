import {
  BROWSER_CONTRACT_DIGEST,
  BROWSER_DEFAULT_TIMEOUT_SECONDS,
  BROWSER_DEFAULT_VIEWPORT_HEIGHT,
  BROWSER_DEFAULT_VIEWPORT_WIDTH,
  BROWSER_KIND,
  BROWSER_MAX_PAGE_ID_BYTES,
  BROWSER_MAX_SELECTOR_BYTES,
  BROWSER_MAX_TEXT_BYTES,
  BROWSER_MAX_TIMEOUT_SECONDS,
  BROWSER_MAX_TYPE_DELAY_MS,
  BROWSER_MAX_URL_BYTES,
  BROWSER_MAX_VIEWPORT_EDGE,
  BROWSER_MIN_TIMEOUT_SECONDS,
  BROWSER_MIN_VIEWPORT_EDGE,
  BROWSER_OP_COMPUTER_CLICK,
  BROWSER_OP_COMPUTER_KEY,
  BROWSER_OP_COMPUTER_SCREENSHOT,
  BROWSER_OP_COMPUTER_SCROLL,
  BROWSER_OP_COMPUTER_TYPE,
  BROWSER_OP_PAGES_CLICK,
  BROWSER_OP_PAGES_FILL,
  BROWSER_OP_PAGES_GOTO,
  BROWSER_OP_PAGES_LIST,
  BROWSER_OP_PAGES_TEXT,
  BROWSER_OP_PAGES_TITLE,
  BROWSER_VERSION,
  BROWSER_WAIT_COMMIT,
  BROWSER_WAIT_DOM_CONTENT_LOADED,
  BROWSER_WAIT_LOAD,
  BROWSER_WAIT_NETWORK_IDLE,
  decodeBrowserBytes,
  decodeBrowserMetadata,
  decodeBrowserPage,
  decodeBrowserPages,
  decodeBrowserString,
  encodeBrowserCreateOptions,
  encodeBrowserFillRequest,
  encodeBrowserGotoRequest,
  encodeBrowserKeyRequest,
  encodeBrowserLocatorRequest,
  encodeBrowserPageTarget,
  encodeBrowserPointRequest,
  encodeBrowserScreenshotRequest,
  encodeBrowserScrollRequest,
  encodeBrowserTypeRequest,
  type BrowserPage,
  type BrowserViewport,
} from "@mc/contracts/browser";
import {
  SIDECAR_MAX_INSTANCES_PER_GRANT,
  SIDECAR_MAX_OPERATION_TIMEOUT_MS,
} from "@mc/contracts/sidecar";
import type {
  SidecarBackend,
  SidecarGrantDescriptor,
  SidecarInstance,
  SidecarInvokeRequest,
} from "./sidecars.js";
import { GUEST_LAYER } from "./sidecars.js";

const textEncoder = new TextEncoder();

export type BrowserWaitUntil = "load" | "domcontentloaded" | "networkidle" | "commit";

export interface BrowserOptions {
  /** Embedded-only route to a configured sidecar host. Remote VMs reject this field. */
  host?: string;
  /** Guest control: provide browserctl.tar bytes to an embedded VM, or `true` when a remote AgentOS
   * server should install its configured copy. Omit or use `false` for host-only control. */
  guest?: boolean | Uint8Array;
  maxInstances?: number;
}

export interface BrowserCreateOptions {
  grant?: string;
  headless?: boolean;
  timeoutSeconds?: number;
  viewport?: BrowserViewport;
  signal?: AbortSignal;
}

export interface BrowserSession {
  id: string;
  grant: string;
  status: "starting" | "ready" | "suspended" | "failed" | "closing";
  createdAt: string;
  expiresAt: string;
  headless: boolean;
  viewport: BrowserViewport;
  activePageId: string;
}

export interface BrowserPageOptions {
  pageId?: string;
  signal?: AbortSignal;
}

export interface BrowserLocatorOptions extends BrowserPageOptions {
  selector: string;
}

export interface BrowserScreenshotOptions extends BrowserPageOptions {
  fullPage?: boolean;
}

export interface BrowserPoint extends BrowserPageOptions {
  x: number;
  y: number;
}

export interface BrowserTypeOptions extends BrowserPageOptions {
  text: string;
  delayMs?: number;
}

export interface BrowserKeyOptions extends BrowserPageOptions {
  key: string;
}

export interface BrowserScrollOptions extends BrowserPageOptions {
  deltaX?: number;
  deltaY?: number;
}

/** Declare one browser grant. The host is a private embedded route, never a provider endpoint sent
 * over the remote AgentOS API. */
export function browser(options: BrowserOptions = {}): SidecarGrantDescriptor {
  const maxInstances = options.maxInstances ?? 1;
  integerInRange("maxInstances", maxInstances, 1, SIDECAR_MAX_INSTANCES_PER_GRANT);
  if (options.host !== undefined) required("host", options.host);
  if (
    options.guest !== undefined &&
    typeof options.guest !== "boolean" &&
    !(options.guest instanceof Uint8Array)
  ) {
    throw new TypeError("guest must be a boolean or Uint8Array");
  }
  if (options.guest instanceof Uint8Array && options.guest.length === 0) {
    throw new TypeError("guest layer must not be empty");
  }
  const guest = options.guest === true || options.guest instanceof Uint8Array;
  return {
    contract: {
      kind: BROWSER_KIND,
      version: BROWSER_VERSION,
      digest: BROWSER_CONTRACT_DIGEST,
    },
    grant: {
      kind: BROWSER_KIND,
      version: BROWSER_VERSION,
      contractDigest: BROWSER_CONTRACT_DIGEST,
      guest,
      maxInstances,
      fork: "omit",
      config: new Uint8Array(),
    },
    ...(options.host === undefined ? {} : { host: options.host }),
    ...(options.guest === true
      ? { [GUEST_LAYER]: true as const }
      : options.guest instanceof Uint8Array
        ? { [GUEST_LAYER]: options.guest.slice() }
        : {}),
  };
}

/** Typed browser resources for one VM. Instances are plain values and every operation is authorized
 * against the backend's current generation instead of trusting a client-side handle cache. */
export class VmBrowsers {
  readonly pages: VmBrowserPages;
  readonly computer: VmBrowserComputer;

  /** @internal */
  constructor(private readonly backend: SidecarBackend) {
    this.pages = new VmBrowserPages(backend);
    this.computer = new VmBrowserComputer(backend);
  }

  async create(options: BrowserCreateOptions = {}): Promise<BrowserSession> {
    if (options.headless !== undefined && typeof options.headless !== "boolean") {
      throw new TypeError("headless must be a boolean");
    }
    if (options.headless === false) {
      throw new TypeError("browser v1 supports headless sessions only");
    }
    if (options.grant !== undefined) required("grant", options.grant);
    const timeoutSeconds = options.timeoutSeconds ?? BROWSER_DEFAULT_TIMEOUT_SECONDS;
    integerInRange(
      "timeoutSeconds",
      timeoutSeconds,
      BROWSER_MIN_TIMEOUT_SECONDS,
      BROWSER_MAX_TIMEOUT_SECONDS,
    );
    const viewport = options.viewport ?? {
      width: BROWSER_DEFAULT_VIEWPORT_WIDTH,
      height: BROWSER_DEFAULT_VIEWPORT_HEIGHT,
    };
    validateViewport(viewport);
    return sessionFromInstance(
      await this.backend.create({
        grant: options.grant ?? "web",
        kind: BROWSER_KIND,
        body: encodeBrowserCreateOptions({
          headless: true,
          timeout_seconds: timeoutSeconds,
          viewport,
        }),
        idempotencyKey: operationId("browser-create"),
        timeoutMs: timeoutSeconds * 1_000,
        signal: options.signal,
      }),
    );
  }

  async retrieve(id: string): Promise<BrowserSession> {
    return sessionFromInstance(await this.backend.retrieve(required("id", id)));
  }

  async list(): Promise<BrowserSession[]> {
    return Promise.all((await this.backend.list(BROWSER_KIND)).map(sessionFromInstance));
  }

  delete(id: string): Promise<void> {
    return this.backend.delete(required("id", id));
  }
}

export class VmBrowserPages {
  /** @internal */
  constructor(private readonly backend: SidecarBackend) {}

  async list(browserId: string, options: { signal?: AbortSignal } = {}): Promise<BrowserPage[]> {
    return decodeBrowserPages(
      await invoke(
        this.backend,
        browserId,
        BROWSER_OP_PAGES_LIST,
        new Uint8Array(),
        options.signal,
      ),
    ).items.map(pageFromResult);
  }

  async goto(
    browserId: string,
    options: BrowserPageOptions & { url: string; waitUntil?: BrowserWaitUntil },
  ): Promise<BrowserPage> {
    bounded("url", options.url, BROWSER_MAX_URL_BYTES);
    return pageFromResult(
      decodeBrowserPage(
        await invoke(
          this.backend,
          browserId,
          BROWSER_OP_PAGES_GOTO,
          encodeBrowserGotoRequest({
            page_id: pageId(options.pageId),
            url: options.url,
            wait_until: waitUntil(options.waitUntil ?? "load"),
          }),
          options.signal,
        ),
      ),
    );
  }

  async title(browserId: string, options: BrowserPageOptions = {}): Promise<string> {
    return stringFromResult(
      decodeBrowserString(
        await invoke(
          this.backend,
          browserId,
          BROWSER_OP_PAGES_TITLE,
          encodeBrowserPageTarget({ page_id: pageId(options.pageId) }),
          options.signal,
        ),
      ),
    ).value;
  }

  async text(browserId: string, options: BrowserLocatorOptions): Promise<string> {
    return stringFromResult(
      decodeBrowserString(
        await invoke(
          this.backend,
          browserId,
          BROWSER_OP_PAGES_TEXT,
          encodeBrowserLocatorRequest(locator(options)),
          options.signal,
        ),
      ),
    ).value;
  }

  async click(browserId: string, options: BrowserLocatorOptions): Promise<void> {
    await invoke(
      this.backend,
      browserId,
      BROWSER_OP_PAGES_CLICK,
      encodeBrowserLocatorRequest(locator(options)),
      options.signal,
    );
  }

  async fill(browserId: string, options: BrowserLocatorOptions & { value: string }): Promise<void> {
    bounded("value", options.value, BROWSER_MAX_TEXT_BYTES, true);
    await invoke(
      this.backend,
      browserId,
      BROWSER_OP_PAGES_FILL,
      encodeBrowserFillRequest({ ...locator(options), value: options.value }),
      options.signal,
    );
  }
}

export class VmBrowserComputer {
  /** @internal */
  constructor(private readonly backend: SidecarBackend) {}

  async screenshot(browserId: string, options: BrowserScreenshotOptions = {}): Promise<Uint8Array> {
    if (options.fullPage !== undefined && typeof options.fullPage !== "boolean")
      throw new TypeError("fullPage must be a boolean");
    return decodeBrowserBytes(
      await invoke(
        this.backend,
        browserId,
        BROWSER_OP_COMPUTER_SCREENSHOT,
        encodeBrowserScreenshotRequest({
          page_id: pageId(options.pageId),
          full_page: options.fullPage ?? false,
        }),
        options.signal,
      ),
    ).value;
  }

  async click(browserId: string, options: BrowserPoint): Promise<void> {
    integerInRange("x", options.x, 0, BROWSER_MAX_VIEWPORT_EDGE - 1);
    integerInRange("y", options.y, 0, BROWSER_MAX_VIEWPORT_EDGE - 1);
    await invoke(
      this.backend,
      browserId,
      BROWSER_OP_COMPUTER_CLICK,
      encodeBrowserPointRequest({
        page_id: pageId(options.pageId),
        x: options.x,
        y: options.y,
      }),
      options.signal,
    );
  }

  async type(browserId: string, options: BrowserTypeOptions): Promise<void> {
    bounded("text", options.text, BROWSER_MAX_TEXT_BYTES, true);
    const delayMs = options.delayMs ?? 0;
    integerInRange("delayMs", delayMs, 0, BROWSER_MAX_TYPE_DELAY_MS);
    await invoke(
      this.backend,
      browserId,
      BROWSER_OP_COMPUTER_TYPE,
      encodeBrowserTypeRequest({
        page_id: pageId(options.pageId),
        text: options.text,
        delay_ms: delayMs,
      }),
      options.signal,
    );
  }

  async key(browserId: string, options: BrowserKeyOptions): Promise<void> {
    bounded("key", options.key, BROWSER_MAX_SELECTOR_BYTES);
    await invoke(
      this.backend,
      browserId,
      BROWSER_OP_COMPUTER_KEY,
      encodeBrowserKeyRequest({
        page_id: pageId(options.pageId),
        key: options.key,
      }),
      options.signal,
    );
  }

  async scroll(browserId: string, options: BrowserScrollOptions): Promise<void> {
    const deltaX = options.deltaX ?? 0;
    const deltaY = options.deltaY ?? 0;
    integerInRange("deltaX", deltaX, -2_147_483_648, 2_147_483_647);
    integerInRange("deltaY", deltaY, -2_147_483_648, 2_147_483_647);
    await invoke(
      this.backend,
      browserId,
      BROWSER_OP_COMPUTER_SCROLL,
      encodeBrowserScrollRequest({
        page_id: pageId(options.pageId),
        delta_x: deltaX,
        delta_y: deltaY,
      }),
      options.signal,
    );
  }
}

async function invoke(
  backend: SidecarBackend,
  id: string,
  operation: string,
  body: Uint8Array,
  signal?: AbortSignal,
): Promise<Uint8Array> {
  const instance = await backend.retrieve(required("browserId", id));
  if (instance.kind !== BROWSER_KIND) throw new TypeError(`${id} is not a browser`);
  const request: SidecarInvokeRequest = {
    id: instance.id,
    generation: instance.generation,
    grant: instance.grant,
    kind: BROWSER_KIND,
    operation,
    body,
    timeoutMs: SIDECAR_MAX_OPERATION_TIMEOUT_MS,
    signal,
  };
  return backend.invoke(request);
}

function sessionFromInstance(instance: SidecarInstance): BrowserSession {
  if (instance.kind !== BROWSER_KIND) throw new TypeError(`${instance.id} is not a browser`);
  const metadata = decodeBrowserMetadata(instance.metadata);
  if (!metadata.headless) throw new TypeError(`browser ${instance.id} returned invalid metadata`);
  validateViewport(metadata.viewport);
  bounded("activePageId", metadata.active_page_id, BROWSER_MAX_PAGE_ID_BYTES);
  if (instance.state === "closed" || instance.state === "detached") {
    throw new TypeError(`browser ${instance.id} is ${instance.state}`);
  }
  return {
    id: instance.id,
    grant: instance.grant,
    status: instance.state === "allocating" ? "starting" : instance.state,
    createdAt: new Date(instance.createdAtMs).toISOString(),
    expiresAt: new Date(instance.expiresAtMs).toISOString(),
    headless: metadata.headless,
    viewport: metadata.viewport,
    activePageId: metadata.active_page_id,
  };
}

function pageFromResult(page: BrowserPage): BrowserPage {
  bounded("page.id", page.id, BROWSER_MAX_PAGE_ID_BYTES);
  bounded("page.url", page.url, BROWSER_MAX_URL_BYTES, true);
  bounded("page.title", page.title, BROWSER_MAX_TEXT_BYTES, true);
  return page;
}

function stringFromResult(result: { value: string }): { value: string } {
  bounded("browser text", result.value, BROWSER_MAX_TEXT_BYTES, true);
  return result;
}

function locator(options: BrowserLocatorOptions): { page_id?: string; selector: string } {
  bounded("selector", options.selector, BROWSER_MAX_SELECTOR_BYTES);
  return {
    page_id: pageId(options.pageId),
    selector: options.selector,
  };
}

function validateViewport(viewport: BrowserViewport): void {
  integerInRange(
    "viewport.width",
    viewport.width,
    BROWSER_MIN_VIEWPORT_EDGE,
    BROWSER_MAX_VIEWPORT_EDGE,
  );
  integerInRange(
    "viewport.height",
    viewport.height,
    BROWSER_MIN_VIEWPORT_EDGE,
    BROWSER_MAX_VIEWPORT_EDGE,
  );
}

function waitUntil(value: BrowserWaitUntil): number {
  switch (value) {
    case "load":
      return BROWSER_WAIT_LOAD;
    case "domcontentloaded":
      return BROWSER_WAIT_DOM_CONTENT_LOADED;
    case "networkidle":
      return BROWSER_WAIT_NETWORK_IDLE;
    case "commit":
      return BROWSER_WAIT_COMMIT;
    default:
      throw new TypeError(`unsupported waitUntil value ${String(value)}`);
  }
}

function required(name: string, value: string): string {
  if (typeof value !== "string" || value.length === 0)
    throw new TypeError(`${name} must be a nonempty string`);
  return value;
}

function pageId(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  bounded("pageId", value, BROWSER_MAX_PAGE_ID_BYTES);
  return value;
}

function bounded(name: string, value: string, maxBytes: number, allowEmpty = false): void {
  if (typeof value !== "string") throw new TypeError(`${name} must be a string`);
  if (!allowEmpty) required(name, value);
  if (textEncoder.encode(value).length > maxBytes) {
    throw new RangeError(`${name} exceeds ${maxBytes} UTF-8 bytes`);
  }
}

function integerInRange(name: string, value: number, min: number, max: number): void {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new RangeError(`${name} must be an integer from ${min} through ${max}`);
  }
}

function operationId(prefix: string): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return `${prefix}-${[...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}
