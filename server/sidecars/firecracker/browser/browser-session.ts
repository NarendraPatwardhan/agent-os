import {
  BROWSER_KIND,
  BROWSER_MAX_PAGES,
  BROWSER_MAX_PAGE_ID_BYTES,
  BROWSER_MAX_SELECTOR_BYTES,
  BROWSER_MAX_TEXT_BYTES,
  BROWSER_MAX_TIMEOUT_SECONDS,
  BROWSER_MAX_URL_BYTES,
  BROWSER_MIN_TIMEOUT_SECONDS,
  BROWSER_VERSION,
  BROWSER_WAIT_COMMIT,
  BROWSER_WAIT_DOM_CONTENT_LOADED,
  BROWSER_WAIT_LOAD,
  BROWSER_WAIT_NETWORK_IDLE,
  decodeBrowserCreateOptions,
  encodeBrowserMetadata,
  type BrowserPage,
  type BrowserViewport,
} from "./browser.gen";
import { CdpClient } from "./cdp-client";
import {
  boundedInput,
  boundedOutput,
  defaultTimeout,
  edge,
  fault,
  remaining,
  setDefaultTimeout,
} from "./limits";
import {
  SIDECAR_ERROR_INVALID_REQUEST,
  SIDECAR_ERROR_LIMIT,
  SIDECAR_ERROR_NOT_FOUND,
  SIDECAR_ERROR_NOT_READY,
  SIDECAR_ERROR_PROVIDER_FAILED,
  SIDECAR_ERROR_TIMEOUT,
} from "./sidecar.gen";

let cdp: CdpClient | undefined;
let initialized = false;
export let viewport: BrowserViewport = { width: 1280, height: 720 };
const sessions = new Map<string, string>();

export function isInitialized(): boolean {
  return initialized;
}

export async function initialize(bytes: Uint8Array): Promise<Uint8Array> {
  if (initialized) throw fault(SIDECAR_ERROR_INVALID_REQUEST, "browser is already initialized");
  const options = decodeBrowserCreateOptions(bytes);
  if (!options.headless)
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, "this browser runner is headless");
  viewport = options.viewport ?? { width: 1280, height: 720 };
  edge("viewport width", viewport.width);
  edge("viewport height", viewport.height);
  if (
    !Number.isInteger(options.timeout_seconds) ||
    options.timeout_seconds < BROWSER_MIN_TIMEOUT_SECONDS ||
    options.timeout_seconds > BROWSER_MAX_TIMEOUT_SECONDS
  ) {
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, "browser timeout is outside the supported range");
  }
  setDefaultTimeout(options.timeout_seconds * 1_000);

  cdp ??= await connectCdp();
  const page = await freshPage(Math.min(defaultTimeout(), 15_000));
  initialized = true;
  return encodeBrowserMetadata({ headless: true, viewport, active_page_id: pageId(page.targetId) });
}

async function connectCdp(): Promise<CdpClient> {
  const deadline = Date.now() + 15_000;
  let failure: unknown;
  while (Date.now() < deadline) {
    try {
      const response = await fetch("http://127.0.0.1:9222/json/version", {
        signal: AbortSignal.timeout(Math.max(1, deadline - Date.now())),
      });
      if (!response.ok) throw new Error(`Chromium discovery returned ${response.status}`);
      const discovery = (await response.json()) as { webSocketDebuggerUrl?: unknown };
      if (typeof discovery.webSocketDebuggerUrl !== "string") {
        throw new Error("Chromium discovery omitted its WebSocket endpoint");
      }
      return await CdpClient.connect(discovery.webSocketDebuggerUrl, 2_000);
    } catch (error) {
      failure = error;
      await Bun.sleep(25);
    }
  }
  const detail = failure instanceof Error ? `: ${failure.message}` : "";
  throw fault(SIDECAR_ERROR_TIMEOUT, `Chromium did not expose CDP${detail}`);
}

interface TargetInfo {
  targetId: string;
  type: string;
  title: string;
  url: string;
}

export interface PageHandle {
  targetId: string;
  sessionId: string;
}

async function freshPage(timeoutMs: number): Promise<PageHandle> {
  const existingContexts = await requiredCdp().call<{ browserContextIds: string[] }>(
    "Target.getBrowserContexts",
    {},
    undefined,
    timeoutMs,
  );
  const context = await requiredCdp().call<{ browserContextId: string }>(
    "Target.createBrowserContext",
    {},
    undefined,
    timeoutMs,
  );
  const created = await requiredCdp().call<{ targetId: string }>(
    "Target.createTarget",
    { url: "about:blank", browserContextId: context.browserContextId },
    undefined,
    timeoutMs,
  );

  for (const browserContextId of existingContexts.browserContextIds) {
    await requiredCdp().call(
      "Target.disposeBrowserContext",
      { browserContextId },
      undefined,
      timeoutMs,
    );
  }
  for (const target of await pageTargets(timeoutMs)) {
    if (target.targetId === created.targetId) continue;
    await requiredCdp().call(
      "Target.closeTarget",
      { targetId: target.targetId },
      undefined,
      timeoutMs,
    );
  }
  return selectedPage(pageId(created.targetId), timeoutMs);
}

async function pageTargets(timeoutMs = defaultTimeout()): Promise<TargetInfo[]> {
  const result = await requiredCdp().call<{ targetInfos: TargetInfo[] }>(
    "Target.getTargets",
    {},
    undefined,
    timeoutMs,
  );
  const pages = result.targetInfos.filter((target) => target.type === "page");
  if (pages.length > BROWSER_MAX_PAGES)
    throw fault(SIDECAR_ERROR_LIMIT, "browser page limit exceeded");
  const live = new Set(pages.map((page) => page.targetId));
  for (const targetId of sessions.keys()) if (!live.has(targetId)) sessions.delete(targetId);
  return pages;
}

export async function listPages(): Promise<BrowserPage[]> {
  return Promise.all((await pageTargets()).map((target) => describePage(target.targetId, target)));
}

export async function describePage(targetId: string, known?: TargetInfo): Promise<BrowserPage> {
  const target =
    known ?? (await pageTargets()).find((candidate) => candidate.targetId === targetId);
  if (!target) throw fault(SIDECAR_ERROR_NOT_FOUND, `page ${pageId(targetId)} was not found`);
  return {
    id: pageId(target.targetId),
    url: boundedOutput("url", target.url, BROWSER_MAX_URL_BYTES),
    title: boundedOutput("title", target.title, BROWSER_MAX_TEXT_BYTES),
  };
}

export async function selectedPage(
  id: string | null | undefined,
  timeoutMs: number,
): Promise<PageHandle> {
  if (id !== null && id !== undefined) boundedInput("page id", id, BROWSER_MAX_PAGE_ID_BYTES);
  const pages = await pageTargets(timeoutMs);
  const target = id === undefined ? pages[0] : pages.find((page) => pageId(page.targetId) === id);
  if (!target)
    throw fault(
      SIDECAR_ERROR_NOT_FOUND,
      id === undefined ? "browser has no page" : `page ${id} was not found`,
    );

  let sessionId = sessions.get(target.targetId);
  if (!sessionId) {
    const attached = await requiredCdp().call<{ sessionId: string }>(
      "Target.attachToTarget",
      { targetId: target.targetId, flatten: true },
      undefined,
      timeoutMs,
    );
    sessionId = attached.sessionId;
    sessions.set(target.targetId, sessionId);
    await requiredCdp().call("Page.enable", {}, sessionId, timeoutMs);
    await requiredCdp().call(
      "Page.setLifecycleEventsEnabled",
      { enabled: true },
      sessionId,
      timeoutMs,
    );
  }
  await requiredCdp().call(
    "Emulation.setDeviceMetricsOverride",
    { width: viewport.width, height: viewport.height, deviceScaleFactor: 1, mobile: false },
    sessionId,
    timeoutMs,
  );
  return { targetId: target.targetId, sessionId };
}

function pageId(targetId: string): string {
  return `pg_${targetId}`;
}

export async function navigate(
  page: PageHandle,
  url: string,
  wait: number,
  timeoutMs: number,
): Promise<void> {
  if (wait === BROWSER_WAIT_COMMIT) {
    const result = await requiredCdp().call<{ errorText?: string }>(
      "Page.navigate",
      { url },
      page.sessionId,
      timeoutMs,
    );
    if (result.errorText) throw fault(SIDECAR_ERROR_PROVIDER_FAILED, result.errorText);
    return;
  }

  const lifecycleName =
    wait === BROWSER_WAIT_LOAD
      ? "load"
      : wait === BROWSER_WAIT_DOM_CONTENT_LOADED
        ? "DOMContentLoaded"
        : wait === BROWSER_WAIT_NETWORK_IDLE
          ? "networkIdle"
          : undefined;
  if (!lifecycleName)
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, "invalid navigation wait condition");

  let loaderId: string | undefined;
  const observedLoaders = new Set<string>();
  const waiter = requiredCdp().waitFor(
    "Page.lifecycleEvent",
    page.sessionId,
    (params) => {
      if (params.name !== lifecycleName || typeof params.loaderId !== "string") return false;
      if (loaderId === undefined) {
        observedLoaders.add(params.loaderId);
        return false;
      }
      return params.loaderId === loaderId;
    },
    timeoutMs,
  );
  try {
    const result = await requiredCdp().call<{ errorText?: string; loaderId?: string }>(
      "Page.navigate",
      { url },
      page.sessionId,
      timeoutMs,
    );
    if (result.errorText) throw fault(SIDECAR_ERROR_PROVIDER_FAILED, result.errorText);
    loaderId = result.loaderId;
    if (loaderId !== undefined && !observedLoaders.has(loaderId)) await waiter.promise;
  } finally {
    waiter.cancel();
  }
}

interface RuntimeResult<T> {
  result: { value?: T; subtype?: string; description?: string };
  exceptionDetails?: { text?: string; exception?: { description?: string } };
}

export async function evaluate<T>(
  page: PageHandle,
  expression: string,
  timeoutMs: number,
): Promise<T> {
  const response = await requiredCdp().call<RuntimeResult<T>>(
    "Runtime.evaluate",
    { expression, awaitPromise: true, returnByValue: true },
    page.sessionId,
    timeoutMs,
  );
  if (response.exceptionDetails) {
    throw fault(
      SIDECAR_ERROR_PROVIDER_FAILED,
      response.exceptionDetails.exception?.description ??
        response.exceptionDetails.text ??
        "browser evaluation failed",
    );
  }
  return response.result.value as T;
}

export interface LocatorResult {
  found: boolean;
  value?: string;
  error?: string;
  x?: number;
  y?: number;
}

export function locatorResult(result: LocatorResult, selector: string): void {
  if (result.error) throw fault(SIDECAR_ERROR_INVALID_REQUEST, result.error);
  if (!result.found)
    throw fault(SIDECAR_ERROR_NOT_FOUND, `selector ${selector} did not match an element`);
}

export async function locatorPoint(
  page: PageHandle,
  selector: string,
  timeoutMs: number,
): Promise<{ x: number; y: number }> {
  const result = await evaluate<LocatorResult>(
    page,
    `(() => { try { const node = document.querySelector(${JSON.stringify(selector)}); if (!node) return { found: false }; node.scrollIntoView({ block: "center", inline: "center" }); const rect = node.getBoundingClientRect(); if (rect.width <= 0 || rect.height <= 0) return { found: false, error: "element is not visible" }; return { found: true, x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 }; } catch (error) { return { found: false, error: String(error) }; } })()`,
    timeoutMs,
  );
  locatorResult(result, selector);
  if (
    !Number.isFinite(result.x) ||
    !Number.isFinite(result.y) ||
    result.x! < 0 ||
    result.y! < 0 ||
    result.x! >= viewport.width ||
    result.y! >= viewport.height
  ) {
    throw fault(SIDECAR_ERROR_PROVIDER_FAILED, "selector resolved outside the viewport");
  }
  return { x: result.x!, y: result.y! };
}

export async function mouseClick(
  page: PageHandle,
  x: number,
  y: number,
  timeoutMs: number,
): Promise<void> {
  await requiredCdp().call(
    "Input.dispatchMouseEvent",
    { type: "mousePressed", x, y, button: "left", clickCount: 1 },
    page.sessionId,
    timeoutMs,
  );
  await requiredCdp().call(
    "Input.dispatchMouseEvent",
    { type: "mouseReleased", x, y, button: "left", clickCount: 1 },
    page.sessionId,
    timeoutMs,
  );
}

const keyCodes: Record<string, number> = {
  Backspace: 8,
  Tab: 9,
  Enter: 13,
  Escape: 27,
  Space: 32,
  PageUp: 33,
  PageDown: 34,
  End: 35,
  Home: 36,
  ArrowLeft: 37,
  ArrowUp: 38,
  ArrowRight: 39,
  ArrowDown: 40,
  Delete: 46,
};

export async function pressKey(page: PageHandle, chord: string, timeoutMs: number): Promise<void> {
  const parts = chord.split("+");
  const key = parts.pop();
  if (!key) throw fault(SIDECAR_ERROR_INVALID_REQUEST, "key chord is empty");
  let modifiers = 0;
  for (const modifier of parts) {
    if (modifier === "Alt") modifiers |= 1;
    else if (modifier === "Control" || modifier === "Ctrl") modifiers |= 2;
    else if (modifier === "Meta" || modifier === "Command") modifiers |= 4;
    else if (modifier === "Shift") modifiers |= 8;
    else throw fault(SIDECAR_ERROR_INVALID_REQUEST, `unsupported key modifier ${modifier}`);
  }
  const code = keyCodes[key] ?? (key.length === 1 ? key.toUpperCase().charCodeAt(0) : undefined);
  if (code === undefined) throw fault(SIDECAR_ERROR_INVALID_REQUEST, `unsupported key ${key}`);
  const text = modifiers & 7 || key.length !== 1 ? undefined : key;
  const params = {
    key: key === "Space" ? " " : key,
    code: key,
    modifiers,
    windowsVirtualKeyCode: code,
    nativeVirtualKeyCode: code,
    text,
  };
  await requiredCdp().call(
    "Input.dispatchKeyEvent",
    { ...params, type: "keyDown" },
    page.sessionId,
    timeoutMs,
  );
  await requiredCdp().call(
    "Input.dispatchKeyEvent",
    { ...params, type: "keyUp", text: undefined },
    page.sessionId,
    timeoutMs,
  );
}

export interface LayoutMetrics {
  cssContentSize: { width: number; height: number };
}

export function requiredCdp(): CdpClient {
  if (!cdp) throw fault(SIDECAR_ERROR_NOT_READY, "browser has not been initialized");
  return cdp;
}
