// @generated from contracts/browser.kdl by //contracts/codegen:projector — do not edit.
export const PROTOCOL_VERSION = 1 as const;
export const BROWSER_KIND = "browser" as const;
export const BROWSER_CONTRACT_DIGEST = "sha256:467c154dc423f6db81ceabce046c3044e2ca7dd780b4fbb3eb3e26fa29f83fca" as const;
export const BROWSER_RUNNER_PROFILE = "browser" as const;
export const BROWSER_VERSION = 1 as const;
export const BROWSER_DEFAULT_TIMEOUT_SECONDS = 300 as const;
export const BROWSER_MIN_TIMEOUT_SECONDS = 10 as const;
export const BROWSER_MAX_TIMEOUT_SECONDS = 300 as const;
export const BROWSER_DEFAULT_VIEWPORT_WIDTH = 1280 as const;
export const BROWSER_DEFAULT_VIEWPORT_HEIGHT = 720 as const;
export const BROWSER_MIN_VIEWPORT_EDGE = 320 as const;
export const BROWSER_MAX_VIEWPORT_EDGE = 4096 as const;
export const BROWSER_MAX_URL_BYTES = 16384 as const;
export const BROWSER_MAX_PAGE_ID_BYTES = 96 as const;
export const BROWSER_MAX_SELECTOR_BYTES = 4096 as const;
export const BROWSER_MAX_TEXT_BYTES = 1048576 as const;
export const BROWSER_MAX_TYPE_DELAY_MS = 1000 as const;
export const BROWSER_MAX_PAGES = 32 as const;
export const BROWSER_MAX_SCREENSHOT_EDGE = 16384 as const;
export const BROWSER_MAX_SCREENSHOT_PIXELS = 16777216 as const;
export const BROWSER_WAIT_LOAD = 1 as const;
export const BROWSER_WAIT_DOM_CONTENT_LOADED = 2 as const;
export const BROWSER_WAIT_NETWORK_IDLE = 3 as const;
export const BROWSER_WAIT_COMMIT = 4 as const;
export const BROWSER_OP_PAGES_LIST = "pages.list" as const;
export const BROWSER_OP_PAGES_GOTO = "pages.goto" as const;
export const BROWSER_OP_PAGES_TITLE = "pages.title" as const;
export const BROWSER_OP_PAGES_TEXT = "pages.text" as const;
export const BROWSER_OP_PAGES_CLICK = "pages.click" as const;
export const BROWSER_OP_PAGES_FILL = "pages.fill" as const;
export const BROWSER_OP_COMPUTER_SCREENSHOT = "computer.screenshot" as const;
export const BROWSER_OP_COMPUTER_CLICK = "computer.click" as const;
export const BROWSER_OP_COMPUTER_TYPE = "computer.type" as const;
export const BROWSER_OP_COMPUTER_KEY = "computer.key" as const;
export const BROWSER_OP_COMPUTER_SCROLL = "computer.scroll" as const;


const CTL_TEXT_ENCODER = new TextEncoder();
const CTL_TEXT_DECODER = new TextDecoder("utf-8", { fatal: true });

export class WireError extends Error { constructor(message: string) { super(message); this.name = "WireError"; } }
interface CtlCursor { bytes: Uint8Array; off: number }
function ctlNeed(cursor: CtlCursor, len: number): Uint8Array { const end = cursor.off + len; if (end > cursor.bytes.length) throw new WireError("truncated frame"); const out = cursor.bytes.subarray(cursor.off, end); cursor.off = end; return out; }
function ctlPutU8(out: number[], v: number): void { out.push(v & 0xff); }
function ctlPutU16(out: number[], v: number): void { out.push(v & 0xff, (v >>> 8) & 0xff); }
function ctlPutU32(out: number[], v: number): void { out.push(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff); }
function ctlPutI32(out: number[], v: number): void { ctlPutU32(out, v >>> 0); }
function ctlPutI64(out: number[], v: number): void { let x = BigInt(Math.trunc(v)); for (let i = 0; i < 8; i++) { out.push(Number((x >> BigInt(i * 8)) & 0xffn)); } }
function ctlPutBool(out: number[], v: boolean): void { out.push(v ? 1 : 0); }
function ctlPutBytes(out: number[], v: Uint8Array): void { ctlPutU32(out, v.length); for (const b of v) out.push(b); }
function ctlPutStr(out: number[], v: string): void { ctlPutBytes(out, CTL_TEXT_ENCODER.encode(v)); }
function ctlPutStrMap(out: number[], v: Record<string, string>): void { const entries = Object.entries(v).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0); ctlPutU32(out, entries.length); for (const [k, val] of entries) { ctlPutStr(out, k); ctlPutStr(out, val); } }
function ctlPutMessageList<T>(out: number[], values: readonly T[], encode: (msg: T) => Uint8Array): void { ctlPutU32(out, values.length); for (const value of values) ctlPutBytes(out, encode(value)); }
function ctlReadU8(cursor: CtlCursor): number { return ctlNeed(cursor, 1)[0]!; }
function ctlReadU16(cursor: CtlCursor): number { const b = ctlNeed(cursor, 2); return b[0]! | (b[1]! << 8); }
function ctlReadU32(cursor: CtlCursor): number { const b = ctlNeed(cursor, 4); return (b[0]! | (b[1]! << 8) | (b[2]! << 16) | (b[3]! << 24)) >>> 0; }
function ctlReadI32(cursor: CtlCursor): number { return ctlReadU32(cursor) | 0; }
function ctlReadI64(cursor: CtlCursor): number { const b = ctlNeed(cursor, 8); let x = 0n; for (let i = 0; i < 8; i++) x |= BigInt(b[i]!) << BigInt(i * 8); if ((x & (1n << 63n)) !== 0n) x -= 1n << 64n; return Number(x); }
function ctlReadBool(cursor: CtlCursor): boolean { const v = ctlReadU8(cursor); if (v === 0) return false; if (v === 1) return true; throw new WireError("invalid bool"); }
function ctlReadBytes(cursor: CtlCursor): Uint8Array { const len = ctlReadU32(cursor); return ctlNeed(cursor, len).slice(); }
function ctlReadStr(cursor: CtlCursor): string { try { return CTL_TEXT_DECODER.decode(ctlReadBytes(cursor)); } catch { throw new WireError("invalid utf-8"); } }
function ctlReadStrMap(cursor: CtlCursor): Record<string, string> { const n = ctlReadU32(cursor); if (n > Math.floor((cursor.bytes.length - cursor.off) / 8)) throw new WireError("truncated frame"); const out: Record<string, string> = {}; let prev: string | null = null; for (let i = 0; i < n; i++) { const k = ctlReadStr(cursor); if (prev !== null && prev >= k) throw new WireError("non-canonical strmap"); out[k] = ctlReadStr(cursor); prev = k; } return out; }

function ctlReadMessageList<T>(cursor: CtlCursor, decode: (bytes: Uint8Array) => T): T[] { const n = ctlReadU32(cursor); if (n > Math.floor((cursor.bytes.length - cursor.off) / 4)) throw new WireError("truncated frame"); const out: T[] = []; for (let i = 0; i < n; i++) out.push(decode(ctlReadBytes(cursor))); return out; }

export interface BrowserViewport {
  width: number;
  height: number;
}
export const BROWSER_VIEWPORT_MSG_ID = 1;
export const BROWSER_VIEWPORT_VERSION = 1;
export function encodeBrowserViewport(msg: BrowserViewport): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_VIEWPORT_MSG_ID);
  ctlPutU8(out, BROWSER_VIEWPORT_VERSION);
  ctlPutU32(out, msg.width);
  ctlPutU32(out, msg.height);
  return Uint8Array.from(out);
}
export function decodeBrowserViewport(bytes: Uint8Array): BrowserViewport {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_VIEWPORT_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_VIEWPORT_VERSION) throw new WireError("unsupported message version");
  const width = ctlReadU32(wire);
  const height = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    width,
    height,
  };
}

export interface BrowserCreateOptions {
  headless: boolean;
  timeout_seconds: number;
  viewport?: BrowserViewport | null;
}
export const BROWSER_CREATE_OPTIONS_MSG_ID = 2;
export const BROWSER_CREATE_OPTIONS_VERSION = 1;
export function encodeBrowserCreateOptions(msg: BrowserCreateOptions): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_CREATE_OPTIONS_MSG_ID);
  ctlPutU8(out, BROWSER_CREATE_OPTIONS_VERSION);
  ctlPutBool(out, msg.headless);
  ctlPutU32(out, msg.timeout_seconds);
  if (msg.viewport === undefined || msg.viewport === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutBytes(out, encodeBrowserViewport(msg.viewport));
  }
  return Uint8Array.from(out);
}
export function decodeBrowserCreateOptions(bytes: Uint8Array): BrowserCreateOptions {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_CREATE_OPTIONS_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_CREATE_OPTIONS_VERSION) throw new WireError("unsupported message version");
  const headless = ctlReadBool(wire);
  const timeout_seconds = ctlReadU32(wire);
  let viewport: BrowserViewport | undefined;
  switch (ctlReadU8(wire)) {
    case 0: viewport = undefined; break;
    case 1: viewport = decodeBrowserViewport(ctlReadBytes(wire)); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    headless,
    timeout_seconds,
    viewport,
  };
}

export interface BrowserMetadata {
  headless: boolean;
  viewport: BrowserViewport;
  active_page_id: string;
}
export const BROWSER_METADATA_MSG_ID = 3;
export const BROWSER_METADATA_VERSION = 1;
export function encodeBrowserMetadata(msg: BrowserMetadata): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_METADATA_MSG_ID);
  ctlPutU8(out, BROWSER_METADATA_VERSION);
  ctlPutBool(out, msg.headless);
  ctlPutBytes(out, encodeBrowserViewport(msg.viewport));
  ctlPutStr(out, msg.active_page_id);
  return Uint8Array.from(out);
}
export function decodeBrowserMetadata(bytes: Uint8Array): BrowserMetadata {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_METADATA_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_METADATA_VERSION) throw new WireError("unsupported message version");
  const headless = ctlReadBool(wire);
  const viewport = decodeBrowserViewport(ctlReadBytes(wire));
  const active_page_id = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    headless,
    viewport,
    active_page_id,
  };
}

export interface BrowserPage {
  id: string;
  url: string;
  title: string;
}
export const BROWSER_PAGE_MSG_ID = 4;
export const BROWSER_PAGE_VERSION = 1;
export function encodeBrowserPage(msg: BrowserPage): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_PAGE_MSG_ID);
  ctlPutU8(out, BROWSER_PAGE_VERSION);
  ctlPutStr(out, msg.id);
  ctlPutStr(out, msg.url);
  ctlPutStr(out, msg.title);
  return Uint8Array.from(out);
}
export function decodeBrowserPage(bytes: Uint8Array): BrowserPage {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_PAGE_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_PAGE_VERSION) throw new WireError("unsupported message version");
  const id = ctlReadStr(wire);
  const url = ctlReadStr(wire);
  const title = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    id,
    url,
    title,
  };
}

export interface BrowserPages {
  items: BrowserPage[];
}
export const BROWSER_PAGES_MSG_ID = 5;
export const BROWSER_PAGES_VERSION = 1;
export function encodeBrowserPages(msg: BrowserPages): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_PAGES_MSG_ID);
  ctlPutU8(out, BROWSER_PAGES_VERSION);
  ctlPutMessageList(out, msg.items, encodeBrowserPage);
  return Uint8Array.from(out);
}
export function decodeBrowserPages(bytes: Uint8Array): BrowserPages {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_PAGES_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_PAGES_VERSION) throw new WireError("unsupported message version");
  const items = ctlReadMessageList(wire, decodeBrowserPage);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    items,
  };
}

export interface BrowserPageTarget {
  page_id?: string | null;
}
export const BROWSER_PAGE_TARGET_MSG_ID = 6;
export const BROWSER_PAGE_TARGET_VERSION = 1;
export function encodeBrowserPageTarget(msg: BrowserPageTarget): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_PAGE_TARGET_MSG_ID);
  ctlPutU8(out, BROWSER_PAGE_TARGET_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  return Uint8Array.from(out);
}
export function decodeBrowserPageTarget(bytes: Uint8Array): BrowserPageTarget {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_PAGE_TARGET_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_PAGE_TARGET_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
  };
}

export interface BrowserGotoRequest {
  page_id?: string | null;
  url: string;
  wait_until: number;
}
export const BROWSER_GOTO_REQUEST_MSG_ID = 7;
export const BROWSER_GOTO_REQUEST_VERSION = 1;
export function encodeBrowserGotoRequest(msg: BrowserGotoRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_GOTO_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_GOTO_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutStr(out, msg.url);
  ctlPutU32(out, msg.wait_until);
  return Uint8Array.from(out);
}
export function decodeBrowserGotoRequest(bytes: Uint8Array): BrowserGotoRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_GOTO_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_GOTO_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const url = ctlReadStr(wire);
  const wait_until = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    url,
    wait_until,
  };
}

export interface BrowserLocatorRequest {
  page_id?: string | null;
  selector: string;
}
export const BROWSER_LOCATOR_REQUEST_MSG_ID = 8;
export const BROWSER_LOCATOR_REQUEST_VERSION = 1;
export function encodeBrowserLocatorRequest(msg: BrowserLocatorRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_LOCATOR_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_LOCATOR_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutStr(out, msg.selector);
  return Uint8Array.from(out);
}
export function decodeBrowserLocatorRequest(bytes: Uint8Array): BrowserLocatorRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_LOCATOR_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_LOCATOR_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const selector = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    selector,
  };
}

export interface BrowserFillRequest {
  page_id?: string | null;
  selector: string;
  value: string;
}
export const BROWSER_FILL_REQUEST_MSG_ID = 9;
export const BROWSER_FILL_REQUEST_VERSION = 1;
export function encodeBrowserFillRequest(msg: BrowserFillRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_FILL_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_FILL_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutStr(out, msg.selector);
  ctlPutStr(out, msg.value);
  return Uint8Array.from(out);
}
export function decodeBrowserFillRequest(bytes: Uint8Array): BrowserFillRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_FILL_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_FILL_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const selector = ctlReadStr(wire);
  const value = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    selector,
    value,
  };
}

export interface BrowserPointRequest {
  page_id?: string | null;
  x: number;
  y: number;
}
export const BROWSER_POINT_REQUEST_MSG_ID = 10;
export const BROWSER_POINT_REQUEST_VERSION = 1;
export function encodeBrowserPointRequest(msg: BrowserPointRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_POINT_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_POINT_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutU32(out, msg.x);
  ctlPutU32(out, msg.y);
  return Uint8Array.from(out);
}
export function decodeBrowserPointRequest(bytes: Uint8Array): BrowserPointRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_POINT_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_POINT_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const x = ctlReadU32(wire);
  const y = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    x,
    y,
  };
}

export interface BrowserTypeRequest {
  page_id?: string | null;
  text: string;
  delay_ms: number;
}
export const BROWSER_TYPE_REQUEST_MSG_ID = 11;
export const BROWSER_TYPE_REQUEST_VERSION = 1;
export function encodeBrowserTypeRequest(msg: BrowserTypeRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_TYPE_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_TYPE_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutStr(out, msg.text);
  ctlPutU32(out, msg.delay_ms);
  return Uint8Array.from(out);
}
export function decodeBrowserTypeRequest(bytes: Uint8Array): BrowserTypeRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_TYPE_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_TYPE_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const text = ctlReadStr(wire);
  const delay_ms = ctlReadU32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    text,
    delay_ms,
  };
}

export interface BrowserKeyRequest {
  page_id?: string | null;
  key: string;
}
export const BROWSER_KEY_REQUEST_MSG_ID = 12;
export const BROWSER_KEY_REQUEST_VERSION = 1;
export function encodeBrowserKeyRequest(msg: BrowserKeyRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_KEY_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_KEY_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutStr(out, msg.key);
  return Uint8Array.from(out);
}
export function decodeBrowserKeyRequest(bytes: Uint8Array): BrowserKeyRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_KEY_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_KEY_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const key = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    key,
  };
}

export interface BrowserScrollRequest {
  page_id?: string | null;
  delta_x: number;
  delta_y: number;
}
export const BROWSER_SCROLL_REQUEST_MSG_ID = 13;
export const BROWSER_SCROLL_REQUEST_VERSION = 1;
export function encodeBrowserScrollRequest(msg: BrowserScrollRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_SCROLL_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_SCROLL_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutI32(out, msg.delta_x);
  ctlPutI32(out, msg.delta_y);
  return Uint8Array.from(out);
}
export function decodeBrowserScrollRequest(bytes: Uint8Array): BrowserScrollRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_SCROLL_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_SCROLL_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const delta_x = ctlReadI32(wire);
  const delta_y = ctlReadI32(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    delta_x,
    delta_y,
  };
}

export interface BrowserScreenshotRequest {
  page_id?: string | null;
  full_page: boolean;
}
export const BROWSER_SCREENSHOT_REQUEST_MSG_ID = 14;
export const BROWSER_SCREENSHOT_REQUEST_VERSION = 1;
export function encodeBrowserScreenshotRequest(msg: BrowserScreenshotRequest): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_SCREENSHOT_REQUEST_MSG_ID);
  ctlPutU8(out, BROWSER_SCREENSHOT_REQUEST_VERSION);
  if (msg.page_id === undefined || msg.page_id === null) {
    ctlPutU8(out, 0);
  } else {
    ctlPutU8(out, 1);
  ctlPutStr(out, msg.page_id);
  }
  ctlPutBool(out, msg.full_page);
  return Uint8Array.from(out);
}
export function decodeBrowserScreenshotRequest(bytes: Uint8Array): BrowserScreenshotRequest {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_SCREENSHOT_REQUEST_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_SCREENSHOT_REQUEST_VERSION) throw new WireError("unsupported message version");
  let page_id: string | undefined;
  switch (ctlReadU8(wire)) {
    case 0: page_id = undefined; break;
    case 1: page_id = ctlReadStr(wire); break;
    default: throw new WireError("invalid optional presence");
  }
  const full_page = ctlReadBool(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    page_id,
    full_page,
  };
}

export interface BrowserString {
  value: string;
}
export const BROWSER_STRING_MSG_ID = 15;
export const BROWSER_STRING_VERSION = 1;
export function encodeBrowserString(msg: BrowserString): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_STRING_MSG_ID);
  ctlPutU8(out, BROWSER_STRING_VERSION);
  ctlPutStr(out, msg.value);
  return Uint8Array.from(out);
}
export function decodeBrowserString(bytes: Uint8Array): BrowserString {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_STRING_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_STRING_VERSION) throw new WireError("unsupported message version");
  const value = ctlReadStr(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    value,
  };
}

export interface BrowserBytes {
  value: Uint8Array;
}
export const BROWSER_BYTES_MSG_ID = 16;
export const BROWSER_BYTES_VERSION = 1;
export function encodeBrowserBytes(msg: BrowserBytes): Uint8Array {
  const out: number[] = [];
  ctlPutU16(out, BROWSER_BYTES_MSG_ID);
  ctlPutU8(out, BROWSER_BYTES_VERSION);
  ctlPutBytes(out, msg.value);
  return Uint8Array.from(out);
}
export function decodeBrowserBytes(bytes: Uint8Array): BrowserBytes {
  const wire: CtlCursor = { bytes, off: 0 };
  if (ctlReadU16(wire) !== BROWSER_BYTES_MSG_ID) throw new WireError("wrong message id");
  if (ctlReadU8(wire) !== BROWSER_BYTES_VERSION) throw new WireError("unsupported message version");
  const value = ctlReadBytes(wire);
  if (wire.off !== bytes.length) throw new WireError("trailing bytes");
  return {
    value,
  };
}
