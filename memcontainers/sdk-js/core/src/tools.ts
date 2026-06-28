// Tool builders: zod-typed sugar over `vm.tool()`. `tool()` defines one host-resident tool (zod input
// → validated args + JSON Schema); `kit()` groups several under one leading name. The SDK seeds the
// in-VM tool catalog, while the actual handler remains a host-call function keyed by `ToolDefinition.name`.

import { z } from "zod";
import type { JsonSchema, ToolContext, ToolDefinition } from "./types.js";

/** A single tool with an optional zod-typed input. */
export interface ToolSpec<S extends z.ZodType = z.ZodType> {
  /** Tool name. Optional inside a {@link kit} (the key provides it). */
  name?: string;
  /** Optional full catalog address. Defaults to `host.org.main.<normalized name>`. */
  address?: string;
  description?: string;
  /** zod schema for the input args — validated before `run`, and emitted as
   *  JSON-Schema for LLM/agent introspection. */
  input?: S;
  /** Optional JSON Schema for the result value. */
  output?: JsonSchema;
  /** Tool-plane safety/discovery annotations. */
  annotations?: Record<string, unknown>;
  run: (args: z.infer<S>, ctx: ToolContext) => Promise<unknown> | unknown;
}

function toJsonSchema(schema: z.ZodType): JsonSchema | undefined {
  const fn = (z as unknown as { toJSONSchema?: (s: z.ZodType) => unknown }).toJSONSchema;
  return typeof fn === "function" ? (fn(schema) as JsonSchema) : undefined;
}

/** Build a single host-resident tool definition. */
export function tool<S extends z.ZodType>(spec: ToolSpec<S>): ToolDefinition {
  const schema = spec.input;
  return {
    name: spec.name ?? "",
    address: spec.address,
    description: spec.description,
    input: schema ? toJsonSchema(schema) : undefined,
    output: spec.output,
    annotations: spec.annotations,
    run: (rawArgs: Record<string, unknown>, ctx: ToolContext) => {
      const args = schema ? (schema.parse(rawArgs) as z.infer<S>) : (rawArgs as z.infer<S>);
      return spec.run(args, ctx);
    },
  };
}

/** The `/etc/tools/catalog.json` catalog consumed by `/svc/tools`. */
export function toolCatalogJson(defs: ToolDefinition[]): string {
  const addresses = new Set<string>();
  const tools = defs.map((d) => {
    assertSafeToolBindingName(d.name);
    const address = d.address ?? defaultAddress(d.name);
    if (addresses.has(address)) {
      throw new Error(`duplicate tool catalog address '${address}'`);
    }
    addresses.add(address);
    const parts = address.split(".");
    return {
      address,
      integration: parts[0] ?? "host",
      owner: parts[1] ?? "org",
      connection: parts[2] ?? "main",
      tool: parts.slice(3).join("."),
      description: d.description,
      input_schema: d.input,
      output_schema: d.output,
      annotations: d.annotations ?? {},
      binding: { type: "host_call", name: d.name, args: "json" },
    };
  });
  return JSON.stringify({ tools });
}

/** Host-call tool bindings share one router with raw mount handlers. Tool bindings must stay in the
 *  plain UTF-8 tool namespace: non-empty, not a raw `/...` mount key, and no control/framing bytes. */
export function isSafeToolBindingName(name: string): boolean {
  return (
    name.length > 0 &&
    !name.startsWith("/") &&
    name.trim() === name &&
    !/[\u0000-\u001f\u007f]/u.test(name)
  );
}

export function assertSafeToolBindingName(name: string): void {
  if (!isSafeToolBindingName(name)) {
    throw new Error(
      `tool name '${name}' must be non-empty, must not start with '/', and must not contain control characters`,
    );
  }
}

/** Run a tool from a JSON args string and return its result as a string — the
 *  shared embedded/served handler body (`def.run` IS the served `call.respond`).
 *  Malformed JSON yields empty args; a non-string result is JSON-stringified. */
export async function runToolJson(
  def: ToolDefinition,
  argsJson: string,
  ctx: ToolContext,
): Promise<string> {
  let input: Record<string, unknown> = {};
  if (argsJson) {
    try {
      const parsed: unknown = JSON.parse(argsJson);
      if (parsed && typeof parsed === "object") input = parsed as Record<string, unknown>;
    } catch {
      // leave input empty on malformed JSON
    }
  }
  const result = await def.run(input, ctx);
  return typeof result === "string" ? result : JSON.stringify(result);
}

/** Group several tools under one kit name. Each subtool is registered as `<kit> <cmd>`. Returns the
 *  array of definitions — pass it to `vm.tool()` or `create({ tools })`. */
export function kit(spec: {
  name: string;
  description?: string;
  tools: Record<string, ToolDefinition>;
}): ToolDefinition[] {
  return Object.entries(spec.tools).map(([cmd, t]) => ({
    ...t,
    name: t.name || `${spec.name} ${cmd}`,
    description: t.description ?? spec.description,
  }));
}

function defaultAddress(name: string): string {
  const tail = name
    .split(/\s+/)
    .flatMap((part) => part.split(/[^A-Za-z0-9_-]+/))
    .map((part) => part.trim())
    .filter(Boolean)
    .join(".");
  return `host.org.main.${tail || "tool"}`;
}
