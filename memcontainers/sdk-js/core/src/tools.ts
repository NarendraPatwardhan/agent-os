// Tool builders: zod-typed sugar over `vm.tool()`. `tool()` defines one
// host-resident tool (zod input → validated args + a JSON-Schema the LLM/agent
// can introspect); `kit()` groups several under one name.
//
// These normalize to `ToolDefinition`s registered via the existing single-name `vm.tool()` /
// `mc_host_call` path. The full `mc-tool <kit> <cmd> --flags` CLI routing and the served (WS) tool
// callback land with mc-server.

import { z } from "zod";
import type { JsonSchema, ToolContext, ToolDefinition } from "./types.js";

/** A single tool with an optional zod-typed input. */
export interface ToolSpec<S extends z.ZodType = z.ZodType> {
  /** Tool name. Optional inside a {@link kit} (the key provides it). */
  name?: string;
  description?: string;
  /** zod schema for the input args — validated before `run`, and emitted as
   *  JSON-Schema for LLM/agent introspection. */
  input?: S;
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
    description: spec.description,
    input: schema ? toJsonSchema(schema) : undefined,
    run: (rawArgs: Record<string, unknown>, ctx: ToolContext) => {
      const args = schema ? (schema.parse(rawArgs) as z.infer<S>) : (rawArgs as z.infer<S>);
      return spec.run(args, ctx);
    },
  };
}

/** The `/etc/mc-tools.json` manifest the guest `mc-tool` reads for `--list`/
 *  `--help`: `{ "<name>": { description?, input?: <JSON-Schema> } }`. */
export function toolManifestJson(defs: ToolDefinition[]): string {
  const out: Record<string, { description?: string; input?: JsonSchema }> = {};
  for (const d of defs) out[d.name] = { description: d.description, input: d.input };
  return JSON.stringify(out);
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

/** Group several tools under one kit name. Each subtool is registered as
 *  `<kit> <cmd>` (the agent invokes `mc-tool <kit> <cmd> ...`). Returns the
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
