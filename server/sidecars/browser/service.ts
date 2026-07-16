import { Buffer } from "node:buffer";
import { readSync, writeSync } from "node:fs";
import {
  BROWSER_CONTRACT_DIGEST,
  BROWSER_KIND,
  BROWSER_MAX_PAGES,
  BROWSER_MAX_PAGE_ID_BYTES,
  BROWSER_MAX_SCREENSHOT_EDGE,
  BROWSER_MAX_SCREENSHOT_PIXELS,
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
  WireError as BrowserWireError,
  decodeBrowserCreateOptions,
  decodeBrowserFillRequest,
  decodeBrowserGotoRequest,
  decodeBrowserKeyRequest,
  decodeBrowserLocatorRequest,
  decodeBrowserPageTarget,
  decodeBrowserPointRequest,
  decodeBrowserScreenshotRequest,
  decodeBrowserScrollRequest,
  decodeBrowserTypeRequest,
  encodeBrowserBytes,
  encodeBrowserMetadata,
  encodeBrowserPage,
  encodeBrowserPages,
  encodeBrowserString,
  type BrowserPage,
  type BrowserViewport,
} from "./browser.gen";
import {
  PROTOCOL_VERSION,
  RUNNER_INIT_OPERATION,
  RUNNER_PREPARE_SNAPSHOT_OPERATION,
  RUNNER_MAX_FRAME_BYTES,
  decodeRunnerRequest,
  encodeRunnerHello,
  encodeRunnerResponse,
  type RunnerRequest,
} from "./runner.gen";
import {
  SIDECAR_ERROR_CONTRACT_MISMATCH,
  SIDECAR_ERROR_INVALID_REQUEST,
  SIDECAR_ERROR_LIMIT,
  SIDECAR_ERROR_NOT_FOUND,
  SIDECAR_ERROR_NOT_READY,
  SIDECAR_ERROR_PROVIDER_FAILED,
  SIDECAR_ERROR_TIMEOUT,
  SIDECAR_MAX_OPERATION_TIMEOUT_MS,
  SIDECAR_MAX_RESULT_BYTES,
} from "./sidecar.gen";

const encoder = new TextEncoder();
const maxCdpMessageBytes = Math.ceil((SIDECAR_MAX_RESULT_BYTES * 4) / 3) + 65_536;
const faultCodes: ReadonlySet<string> = new Set([
  SIDECAR_ERROR_CONTRACT_MISMATCH,
  SIDECAR_ERROR_INVALID_REQUEST,
  SIDECAR_ERROR_LIMIT,
  SIDECAR_ERROR_NOT_FOUND,
  SIDECAR_ERROR_NOT_READY,
  SIDECAR_ERROR_PROVIDER_FAILED,
  SIDECAR_ERROR_TIMEOUT,
]);
let cdp: CdpClient | undefined;
let initialized = false;
let viewport: BrowserViewport = { width: 1280, height: 720 };
let defaultTimeoutMs = 300_000;
let operationDeadline: number | undefined;
const sessions = new Map<string, string>();

async function serve(): Promise<never> {
  const hello = encodeRunnerHello({
    protocol_version: PROTOCOL_VERSION,
    agent: "agentos-browser",
    kind: BROWSER_KIND,
    version: BROWSER_VERSION,
    contract_digest: BROWSER_CONTRACT_DIGEST,
  });
  writeFrame(hello);

  while (true) {
    let request: RunnerRequest;
    try {
      request = decodeRunnerRequest(readFrame());
    } catch {
      process.exit(0);
    }

    operationDeadline = Date.now() + timeout(request);
    try {
      if (request.kind !== BROWSER_KIND) throw fault(SIDECAR_ERROR_CONTRACT_MISMATCH, "wrong kind");
      const prepareSnapshot = request.operation === RUNNER_PREPARE_SNAPSHOT_OPERATION;
      const body = await dispatch(request);
      remaining(operationDeadline);
      writeFrame(encodeRunnerResponse({ request_id: request.request_id, ok: true, body }));
      if (prepareSnapshot) process.exit(0);
    } catch (error) {
      const value = normalizeFault(error);
      writeFrame(
        encodeRunnerResponse({
          request_id: request.request_id,
          ok: false,
          body: new Uint8Array(),
          error_code: value.code,
          error_message: value.message,
        }),
      );
    } finally {
      operationDeadline = undefined;
    }
  }
}

async function dispatch(request: RunnerRequest): Promise<Uint8Array> {
  if (request.operation === RUNNER_INIT_OPERATION) return initialize(request.body);
  if (request.operation === RUNNER_PREPARE_SNAPSHOT_OPERATION) {
    if (request.body.length !== 0)
      throw fault(SIDECAR_ERROR_INVALID_REQUEST, "snapshot request must be empty");
    return new Uint8Array();
  }
  if (!cdp) throw fault(SIDECAR_ERROR_NOT_READY, "browser has not been initialized");

  switch (request.operation) {
    case BROWSER_OP_PAGES_LIST:
      return encodeBrowserPages({ items: await listPages() });
    case BROWSER_OP_PAGES_GOTO: {
      const input = decodeBrowserGotoRequest(request.body);
      boundedInput("url", input.url, BROWSER_MAX_URL_BYTES);
      const page = await selectedPage(input.page_id, timeout(request));
      await navigate(page, input.url, input.wait_until, timeout(request));
      return encodeBrowserPage(await describePage(page.targetId));
    }
    case BROWSER_OP_PAGES_TITLE: {
      const input = decodeBrowserPageTarget(request.body);
      const page = await selectedPage(input.page_id, timeout(request));
      const title = await evaluate<string>(page, "document.title", timeout(request));
      return encodeBrowserString({ value: boundedOutput("title", title, BROWSER_MAX_TEXT_BYTES) });
    }
    case BROWSER_OP_PAGES_TEXT: {
      const input = decodeBrowserLocatorRequest(request.body);
      boundedInput("selector", input.selector, BROWSER_MAX_SELECTOR_BYTES);
      const page = await selectedPage(input.page_id, timeout(request));
      const result = await evaluate<LocatorResult>(
        page,
        `(() => { try { const node = document.querySelector(${JSON.stringify(input.selector)}); return node ? { found: true, value: (node.textContent ?? "").slice(0, ${BROWSER_MAX_TEXT_BYTES + 1}) } : { found: false }; } catch (error) { return { found: false, error: String(error) }; } })()`,
        timeout(request),
      );
      locatorResult(result, input.selector);
      return encodeBrowserString({
        value: boundedOutput("text", result.value ?? "", BROWSER_MAX_TEXT_BYTES),
      });
    }
    case BROWSER_OP_PAGES_CLICK: {
      const input = decodeBrowserLocatorRequest(request.body);
      boundedInput("selector", input.selector, BROWSER_MAX_SELECTOR_BYTES);
      const page = await selectedPage(input.page_id, timeout(request));
      const point = await locatorPoint(page, input.selector, timeout(request));
      await mouseClick(page, point.x, point.y, timeout(request));
      return new Uint8Array();
    }
    case BROWSER_OP_PAGES_FILL: {
      const input = decodeBrowserFillRequest(request.body);
      boundedInput("selector", input.selector, BROWSER_MAX_SELECTOR_BYTES);
      boundedInput("value", input.value, BROWSER_MAX_TEXT_BYTES, true);
      const page = await selectedPage(input.page_id, timeout(request));
      const result = await evaluate<LocatorResult>(
        page,
        `(() => { try { const node = document.querySelector(${JSON.stringify(input.selector)}); if (!node) return { found: false }; if (!(node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement || node instanceof HTMLSelectElement)) return { found: false, error: "element is not fillable" }; node.focus(); node.value = ${JSON.stringify(input.value)}; node.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: ${JSON.stringify(input.value)} })); node.dispatchEvent(new Event("change", { bubbles: true })); return { found: true }; } catch (error) { return { found: false, error: String(error) }; } })()`,
        timeout(request),
      );
      locatorResult(result, input.selector);
      return new Uint8Array();
    }
    case BROWSER_OP_COMPUTER_SCREENSHOT: {
      const input = decodeBrowserScreenshotRequest(request.body);
      const page = await selectedPage(input.page_id, timeout(request));
      const params: Record<string, unknown> = { format: "png", captureBeyondViewport: true };
      if (input.full_page) {
        const metrics = await cdp.call<LayoutMetrics>(
          "Page.getLayoutMetrics",
          {},
          page.sessionId,
          timeout(request),
        );
        const { width, height } = metrics.cssContentSize;
        if (
          !Number.isFinite(width) ||
          !Number.isFinite(height) ||
          width <= 0 ||
          height <= 0 ||
          width > BROWSER_MAX_SCREENSHOT_EDGE ||
          height > BROWSER_MAX_SCREENSHOT_EDGE ||
          width * height > BROWSER_MAX_SCREENSHOT_PIXELS
        ) {
          throw fault(SIDECAR_ERROR_LIMIT, "page exceeds the full-page screenshot limit");
        }
        params.clip = {
          x: 0,
          y: 0,
          width,
          height,
          scale: 1,
        };
      }
      const capture = await cdp.call<{ data: string }>(
        "Page.captureScreenshot",
        params,
        page.sessionId,
        timeout(request),
      );
      const body = encodeBrowserBytes({
        value: new Uint8Array(Buffer.from(capture.data, "base64")),
      });
      if (body.length > RUNNER_MAX_FRAME_BYTES - 1_024) {
        throw fault(SIDECAR_ERROR_LIMIT, "screenshot exceeds the sidecar result limit");
      }
      return body;
    }
    case BROWSER_OP_COMPUTER_CLICK: {
      const input = decodeBrowserPointRequest(request.body);
      if (input.x >= viewport.width || input.y >= viewport.height) {
        throw fault(SIDECAR_ERROR_INVALID_REQUEST, "click point is outside the viewport");
      }
      const page = await selectedPage(input.page_id, timeout(request));
      await mouseClick(page, input.x, input.y, timeout(request));
      return new Uint8Array();
    }
    case BROWSER_OP_COMPUTER_TYPE: {
      const input = decodeBrowserTypeRequest(request.body);
      boundedInput("text", input.text, BROWSER_MAX_TEXT_BYTES, true);
      if (!Number.isInteger(input.delay_ms) || input.delay_ms > BROWSER_MAX_TYPE_DELAY_MS) {
        throw fault(SIDECAR_ERROR_INVALID_REQUEST, "typing delay is outside the supported range");
      }
      const page = await selectedPage(input.page_id, timeout(request));
      if (input.delay_ms === 0) {
        await cdp.call("Input.insertText", { text: input.text }, page.sessionId, timeout(request));
        return new Uint8Array();
      }
      const deadline = Date.now() + timeout(request);
      for (const character of input.text) {
        await cdp.call(
          "Input.insertText",
          { text: character },
          page.sessionId,
          remaining(deadline),
        );
        if (input.delay_ms > 0) {
          if (input.delay_ms >= remaining(deadline)) {
            throw fault(SIDECAR_ERROR_TIMEOUT, "browser operation timed out");
          }
          await Bun.sleep(input.delay_ms);
        }
      }
      return new Uint8Array();
    }
    case BROWSER_OP_COMPUTER_KEY: {
      const input = decodeBrowserKeyRequest(request.body);
      boundedInput("key", input.key, BROWSER_MAX_SELECTOR_BYTES);
      const page = await selectedPage(input.page_id, timeout(request));
      await pressKey(page, input.key, timeout(request));
      return new Uint8Array();
    }
    case BROWSER_OP_COMPUTER_SCROLL: {
      const input = decodeBrowserScrollRequest(request.body);
      const page = await selectedPage(input.page_id, timeout(request));
      await cdp.call(
        "Input.dispatchMouseEvent",
        {
          type: "mouseWheel",
          x: Math.floor(viewport.width / 2),
          y: Math.floor(viewport.height / 2),
          deltaX: input.delta_x,
          deltaY: input.delta_y,
        },
        page.sessionId,
        timeout(request),
      );
      return new Uint8Array();
    }
    default:
      throw fault(
        SIDECAR_ERROR_INVALID_REQUEST,
        `unsupported browser operation ${request.operation}`,
      );
  }
}

async function initialize(bytes: Uint8Array): Promise<Uint8Array> {
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
  defaultTimeoutMs = options.timeout_seconds * 1_000;

  cdp ??= await connectCdp();
  const page = await freshPage(Math.min(defaultTimeoutMs, 15_000));
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

interface PageHandle {
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

async function pageTargets(timeoutMs = defaultTimeoutMs): Promise<TargetInfo[]> {
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

async function listPages(): Promise<BrowserPage[]> {
  return Promise.all((await pageTargets()).map((target) => describePage(target.targetId, target)));
}

async function describePage(targetId: string, known?: TargetInfo): Promise<BrowserPage> {
  const target =
    known ?? (await pageTargets()).find((candidate) => candidate.targetId === targetId);
  if (!target) throw fault(SIDECAR_ERROR_NOT_FOUND, `page ${pageId(targetId)} was not found`);
  return {
    id: pageId(target.targetId),
    url: boundedOutput("url", target.url, BROWSER_MAX_URL_BYTES),
    title: boundedOutput("title", target.title, BROWSER_MAX_TEXT_BYTES),
  };
}

async function selectedPage(id: string | null | undefined, timeoutMs: number): Promise<PageHandle> {
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

async function navigate(
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

async function evaluate<T>(page: PageHandle, expression: string, timeoutMs: number): Promise<T> {
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

interface LocatorResult {
  found: boolean;
  value?: string;
  error?: string;
  x?: number;
  y?: number;
}

function locatorResult(result: LocatorResult, selector: string): void {
  if (result.error) throw fault(SIDECAR_ERROR_INVALID_REQUEST, result.error);
  if (!result.found)
    throw fault(SIDECAR_ERROR_NOT_FOUND, `selector ${selector} did not match an element`);
}

async function locatorPoint(
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

async function mouseClick(
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

async function pressKey(page: PageHandle, chord: string, timeoutMs: number): Promise<void> {
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

interface LayoutMetrics {
  cssContentSize: { width: number; height: number };
}

interface CdpPending {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface CdpWaiter {
  method: string;
  sessionId?: string;
  predicate: (params: Record<string, unknown>) => boolean;
  resolve: (params: Record<string, unknown>) => void;
  reject: (reason: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

class CdpClient {
  private nextId = 1;
  private readonly pending = new Map<number, CdpPending>();
  private readonly waiters = new Set<CdpWaiter>();
  private failure: unknown;

  private constructor(private readonly socket: WebSocket) {
    socket.onmessage = (event) => this.receive(String(event.data));
    socket.onclose = () => this.failAll(new Error("Chromium CDP connection closed"));
    socket.onerror = () => this.failAll(new Error("Chromium CDP connection failed"));
  }

  static async connect(url: string, timeoutMs: number): Promise<CdpClient> {
    const socket = new WebSocket(url);
    timeoutMs = boundedByOperation(timeoutMs);
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const finish = (error?: unknown) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (error === undefined) resolve();
        else {
          socket.close();
          reject(error);
        }
      };
      const timer = setTimeout(
        () => finish(fault(SIDECAR_ERROR_TIMEOUT, "Chromium CDP connection timed out")),
        timeoutMs,
      );
      socket.onopen = () => {
        finish();
      };
      socket.onerror = () => {
        finish(new Error("Chromium CDP connection failed"));
      };
    });
    return new CdpClient(socket);
  }

  call<T = Record<string, unknown>>(
    method: string,
    params: Record<string, unknown> = {},
    sessionId?: string,
    timeoutMs = defaultTimeoutMs,
  ): Promise<T> {
    if (this.failure !== undefined) return Promise.reject(this.failure);
    timeoutMs = boundedByOperation(timeoutMs);
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(fault(SIDECAR_ERROR_TIMEOUT, `${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject, timer });
      try {
        this.socket.send(
          JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }),
        );
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        this.failAll(error);
        this.socket.close();
        reject(error);
      }
    });
  }

  waitFor(
    method: string,
    sessionId: string | undefined,
    predicate: (params: Record<string, unknown>) => boolean,
    timeoutMs: number,
  ): { promise: Promise<Record<string, unknown>>; cancel: () => void } {
    if (this.failure !== undefined) throw this.failure;
    timeoutMs = boundedByOperation(timeoutMs);
    let waiter: CdpWaiter;
    const promise = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters.delete(waiter);
        reject(fault(SIDECAR_ERROR_TIMEOUT, `${method} timed out`));
      }, timeoutMs);
      waiter = { method, sessionId, predicate, resolve, reject, timer };
      this.waiters.add(waiter);
    });
    return {
      promise,
      cancel: () => {
        if (this.waiters.delete(waiter)) clearTimeout(waiter.timer);
      },
    };
  }

  private receive(raw: string): void {
    if (raw.length > maxCdpMessageBytes || encoder.encode(raw).length > maxCdpMessageBytes) {
      this.failAll(fault(SIDECAR_ERROR_LIMIT, "CDP message exceeds the browser runner limit"));
      this.socket.close();
      return;
    }
    let message: {
      id?: number;
      result?: unknown;
      error?: { message?: string };
      method?: string;
      params?: Record<string, unknown>;
      sessionId?: string;
    };
    try {
      message = JSON.parse(raw);
    } catch {
      this.failAll(new Error("Chromium sent malformed CDP JSON"));
      this.socket.close();
      return;
    }
    if (message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(message.error.message ?? "CDP command failed"));
      else pending.resolve(message.result ?? {});
      return;
    }
    if (!message.method) return;
    for (const waiter of [...this.waiters]) {
      if (waiter.method !== message.method || waiter.sessionId !== message.sessionId) continue;
      let matches = false;
      try {
        matches = waiter.predicate(message.params ?? {});
      } catch (error) {
        this.waiters.delete(waiter);
        clearTimeout(waiter.timer);
        waiter.reject(error);
        continue;
      }
      if (!matches) continue;
      this.waiters.delete(waiter);
      clearTimeout(waiter.timer);
      waiter.resolve(message.params ?? {});
    }
  }

  private failAll(error: unknown): void {
    this.failure ??= error;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    for (const waiter of this.waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.waiters.clear();
  }
}

function requiredCdp(): CdpClient {
  if (!cdp) throw fault(SIDECAR_ERROR_NOT_READY, "browser has not been initialized");
  return cdp;
}

function timeout(request: RunnerRequest): number {
  if (
    !Number.isSafeInteger(request.timeout_ms) ||
    request.timeout_ms < 1 ||
    request.timeout_ms > SIDECAR_MAX_OPERATION_TIMEOUT_MS
  ) {
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, "operation timeout is outside the supported range");
  }
  return Math.min(defaultTimeoutMs, request.timeout_ms);
}

function remaining(deadline: number): number {
  const value = deadline - Date.now();
  if (value <= 0) throw fault(SIDECAR_ERROR_TIMEOUT, "browser operation timed out");
  return value;
}

function boundedByOperation(timeoutMs: number): number {
  return operationDeadline === undefined
    ? timeoutMs
    : Math.min(timeoutMs, remaining(operationDeadline));
}

function edge(name: string, value: number): void {
  if (
    !Number.isInteger(value) ||
    value < BROWSER_MIN_VIEWPORT_EDGE ||
    value > BROWSER_MAX_VIEWPORT_EDGE
  ) {
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, `${name} is outside the supported range`);
  }
}

function boundedInput(name: string, value: string, maximum: number, allowEmpty = false): void {
  if ((!allowEmpty && value.length === 0) || encoder.encode(value).length > maximum) {
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, `${name} is empty or too large`);
  }
}

function boundedOutput(name: string, value: string, maximum: number): string {
  if (encoder.encode(value).length > maximum) {
    throw fault(SIDECAR_ERROR_PROVIDER_FAILED, `${name} exceeds the browser result limit`);
  }
  return value;
}

interface Fault {
  code: string;
  message: string;
}

function fault(code: string, message: string): Fault {
  return { code, message };
}

function normalizeFault(error: unknown): Fault {
  if (error instanceof BrowserWireError) {
    return fault(SIDECAR_ERROR_INVALID_REQUEST, "malformed browser request");
  }
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    "message" in error &&
    typeof error.code === "string" &&
    faultCodes.has(error.code) &&
    typeof error.message === "string"
  ) {
    return fault(error.code, error.message.slice(0, 1_024));
  }
  const message = error instanceof Error ? error.message : String(error);
  return fault(SIDECAR_ERROR_PROVIDER_FAILED, message.slice(0, 1_024));
}

function readFrame(): Uint8Array {
  const lengthBytes = readExact(4);
  const length = new DataView(lengthBytes.buffer, lengthBytes.byteOffset, 4).getUint32(0, false);
  if (length === 0 || length > RUNNER_MAX_FRAME_BYTES) throw new Error("invalid frame length");
  return readExact(length);
}

function writeFrame(frame: Uint8Array): void {
  if (frame.length === 0 || frame.length > RUNNER_MAX_FRAME_BYTES)
    throw new Error("invalid frame length");
  const prefix = new Uint8Array(4);
  new DataView(prefix.buffer).setUint32(0, frame.length, false);
  writeAll(prefix);
  writeAll(frame);
}

function readExact(length: number): Uint8Array {
  const out = new Uint8Array(length);
  let offset = 0;
  while (offset < length) {
    const count = readSync(0, out, offset, length - offset, null);
    if (count === 0) throw new Error("end of stream");
    offset += count;
  }
  return out;
}

function writeAll(bytes: Uint8Array): void {
  let offset = 0;
  while (offset < bytes.length) {
    const written = writeSync(1, bytes, offset, bytes.length - offset);
    if (written <= 0) throw new Error("runner stream stopped accepting writes");
    offset += written;
  }
}

await serve();
