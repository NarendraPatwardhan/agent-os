import {
  BROWSER_MAX_VIEWPORT_EDGE,
  BROWSER_MIN_VIEWPORT_EDGE,
  WireError as BrowserWireError,
} from "./browser.gen";
import type { RunnerRequest } from "./runner.gen";
import {
  SIDECAR_ERROR_CONTRACT_MISMATCH,
  SIDECAR_ERROR_INVALID_REQUEST,
  SIDECAR_ERROR_LIMIT,
  SIDECAR_ERROR_NOT_FOUND,
  SIDECAR_ERROR_NOT_READY,
  SIDECAR_ERROR_PROVIDER_FAILED,
  SIDECAR_ERROR_TIMEOUT,
  SIDECAR_MAX_OPERATION_TIMEOUT_MS,
} from "./sidecar.gen";

const encoder = new TextEncoder();
const faultCodes: ReadonlySet<string> = new Set([
  SIDECAR_ERROR_CONTRACT_MISMATCH,
  SIDECAR_ERROR_INVALID_REQUEST,
  SIDECAR_ERROR_LIMIT,
  SIDECAR_ERROR_NOT_FOUND,
  SIDECAR_ERROR_NOT_READY,
  SIDECAR_ERROR_PROVIDER_FAILED,
  SIDECAR_ERROR_TIMEOUT,
]);

let configuredDefaultTimeoutMs = 300_000;
let operationDeadline: number | undefined;

export interface Fault {
  code: string;
  message: string;
}

export function defaultTimeout(): number {
  return configuredDefaultTimeoutMs;
}

export function setDefaultTimeout(timeoutMs: number): void {
  configuredDefaultTimeoutMs = timeoutMs;
}

export function beginOperation(request: RunnerRequest): number {
  operationDeadline = Date.now() + timeout(request);
  return operationDeadline;
}

export function endOperation(): void {
  operationDeadline = undefined;
}

export function timeout(request: RunnerRequest): number {
  if (
    !Number.isSafeInteger(request.timeout_ms) ||
    request.timeout_ms < 1 ||
    request.timeout_ms > SIDECAR_MAX_OPERATION_TIMEOUT_MS
  ) {
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, "operation timeout is outside the supported range");
  }
  return Math.min(configuredDefaultTimeoutMs, request.timeout_ms);
}

export function remaining(deadline: number): number {
  const value = deadline - Date.now();
  if (value <= 0) throw fault(SIDECAR_ERROR_TIMEOUT, "browser operation timed out");
  return value;
}

export function boundedByOperation(timeoutMs: number): number {
  return operationDeadline === undefined
    ? timeoutMs
    : Math.min(timeoutMs, remaining(operationDeadline));
}

export function edge(name: string, value: number): void {
  if (
    !Number.isInteger(value) ||
    value < BROWSER_MIN_VIEWPORT_EDGE ||
    value > BROWSER_MAX_VIEWPORT_EDGE
  ) {
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, `${name} is outside the supported range`);
  }
}

export function boundedInput(
  name: string,
  value: string,
  maximum: number,
  allowEmpty = false,
): void {
  if ((!allowEmpty && value.length === 0) || encoder.encode(value).length > maximum) {
    throw fault(SIDECAR_ERROR_INVALID_REQUEST, `${name} is empty or too large`);
  }
}

export function boundedOutput(name: string, value: string, maximum: number): string {
  if (encoder.encode(value).length > maximum) {
    throw fault(SIDECAR_ERROR_PROVIDER_FAILED, `${name} exceeds the browser result limit`);
  }
  return value;
}

export function fault(code: string, message: string): Fault {
  return { code, message };
}

export function normalizeFault(error: unknown): Fault {
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
