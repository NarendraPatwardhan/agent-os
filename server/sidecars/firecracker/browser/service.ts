import { Buffer } from "node:buffer";
import {
  BROWSER_CONTRACT_DIGEST,
  BROWSER_KIND,
  BROWSER_MAX_SCREENSHOT_EDGE,
  BROWSER_MAX_SCREENSHOT_PIXELS,
  BROWSER_MAX_SELECTOR_BYTES,
  BROWSER_MAX_TEXT_BYTES,
  BROWSER_MAX_TYPE_DELAY_MS,
  BROWSER_MAX_URL_BYTES,
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
  encodeBrowserPage,
  encodeBrowserPages,
  encodeBrowserString,
} from "./browser.gen";
import {
  describePage,
  evaluate,
  initialize,
  isInitialized,
  listPages,
  locatorPoint,
  locatorResult,
  mouseClick,
  navigate,
  pressKey,
  requiredCdp,
  selectedPage,
  viewport,
  type LayoutMetrics,
  type LocatorResult,
} from "./browser-session";
import { readFrame, writeFrame } from "./framing";
import {
  beginOperation,
  boundedInput,
  boundedOutput,
  endOperation,
  fault,
  normalizeFault,
  remaining,
  timeout,
} from "./limits";
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
  SIDECAR_ERROR_NOT_READY,
  SIDECAR_ERROR_TIMEOUT,
} from "./sidecar.gen";

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

    const deadline = beginOperation(request);
    try {
      if (request.kind !== BROWSER_KIND) throw fault(SIDECAR_ERROR_CONTRACT_MISMATCH, "wrong kind");
      const prepareSnapshot = request.operation === RUNNER_PREPARE_SNAPSHOT_OPERATION;
      const body = await dispatch(request);
      remaining(deadline);
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
      endOperation();
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
  if (!isInitialized()) throw fault(SIDECAR_ERROR_NOT_READY, "browser has not been initialized");

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
        const metrics = await requiredCdp().call<LayoutMetrics>(
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
      const capture = await requiredCdp().call<{ data: string }>(
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
        await requiredCdp().call(
          "Input.insertText",
          { text: input.text },
          page.sessionId,
          timeout(request),
        );
        return new Uint8Array();
      }
      const deadline = Date.now() + timeout(request);
      for (const character of input.text) {
        await requiredCdp().call(
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
      await requiredCdp().call(
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

await serve();
