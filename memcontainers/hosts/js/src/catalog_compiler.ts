import { readFileSync } from "node:fs";
import { join } from "node:path";

import type { ToolPolicyAction } from "./policy.js";

export interface CatalogBundle {
  entries: Map<string, Uint8Array>;
}

export interface RegistryGroup {
  filter?: {
    exact_paths?: string[];
    path_prefixes?: string[];
    tag_prefixes?: string[];
  };
}

export interface RegistryEntry {
  id: string;
  name: string;
  kind: "openapi" | "microsoft-graph" | "google-discovery" | "graphql" | "mcp-remote";
  url?: string;
  endpoint?: string;
  defaultGroups?: string[];
  groups?: Record<string, RegistryGroup>;
  /** Curated egress origins; the host derives a connection's allowlist from these when `origins` is
   *  omitted, so the embedder names only the capability + key. */
  servers?: string[];
}

type CompilerExports = {
  memory: WebAssembly.Memory;
  cc_alloc(len: number): number;
  cc_free(ptr: number, len: number): void;
  cc_registry_list(): bigint;
  cc_registry_resolve(idPtr: number, idLen: number): bigint;
  cc_compile(srcPtr: number, srcLen: number, optsPtr: number, optsLen: number): bigint;
  cc_bundle_schema_version(): number;
  cc_validate_address(ptr: number, len: number): bigint;
  cc_validate_policy(ptr: number, len: number): bigint;
  cc_policy_resolve(rulesPtr: number, rulesLen: number, addrPtr: number, addrLen: number): bigint;
};

const enc = (s: string): Uint8Array => new TextEncoder().encode(s);
const dec = (b: Uint8Array): string => new TextDecoder().decode(b);

let defaultCompiler: Promise<CatalogCompiler> | null = null;
const compilerByDigest = new Map<string, Promise<CatalogCompiler>>();

export async function defaultCatalogCompiler(wasmBytes?: Uint8Array): Promise<CatalogCompiler> {
  if (wasmBytes) {
    const digest = await sha256Hex(wasmBytes);
    let compiler = compilerByDigest.get(digest);
    if (!compiler) {
      const copy = wasmBytes.slice();
      compiler = CatalogCompiler.instantiateWithDigest(copy, digest);
      compilerByDigest.set(digest, compiler);
    }
    return compiler;
  }
  defaultCompiler ??= CatalogCompiler.instantiate(readDefaultCompilerWasm());
  return defaultCompiler;
}

export class CatalogCompiler {
  private constructor(
    private readonly exports: CompilerExports,
    readonly artifactDigest: string,
  ) {}

  static async instantiate(wasmBytes: Uint8Array): Promise<CatalogCompiler> {
    const artifactDigest = await sha256Hex(wasmBytes);
    return this.instantiateWithDigest(wasmBytes, artifactDigest);
  }

  static async instantiateWithDigest(
    wasmBytes: Uint8Array,
    artifactDigest: string,
  ): Promise<CatalogCompiler> {
    const mod = await WebAssembly.compile(wasmBytes);
    const imports = WebAssembly.Module.imports(mod);
    if (imports.length !== 0) {
      throw new Error(`catalog compiler must be pure wasm; imports=${JSON.stringify(imports)}`);
    }
    const instance = await WebAssembly.instantiate(mod, {});
    const exports = instance.exports as unknown as CompilerExports;
    for (const name of [
      "memory",
      "cc_alloc",
      "cc_free",
      "cc_registry_list",
      "cc_registry_resolve",
      "cc_compile",
      "cc_bundle_schema_version",
      "cc_validate_address",
      "cc_validate_policy",
      "cc_policy_resolve",
    ] as const) {
      if (!(name in exports)) throw new Error(`catalog compiler is missing ${name}`);
    }
    return new CatalogCompiler(exports, artifactDigest);
  }

  async registryList(): Promise<RegistryEntry[]> {
    const raw = await this.readReturn(this.exports.cc_registry_list());
    const parsed: unknown = JSON.parse(dec(raw));
    if (!Array.isArray(parsed)) throw new Error("catalog compiler registry.list returned a non-array");
    return parsed.map(registryEntry);
  }

  async registryResolve(id: string): Promise<RegistryEntry> {
    const idBytes = enc(id);
    const idPtr = this.write(idBytes);
    try {
      const raw = await this.readReturn(this.exports.cc_registry_resolve(idPtr, idBytes.length));
      const parsed: unknown = JSON.parse(dec(raw));
      if (isObject(parsed) && isObject(parsed.error)) {
        const message =
          typeof parsed.error.message === "string" ? parsed.error.message : `unknown integration ${id}`;
        throw new Error(message);
      }
      return registryEntry(parsed);
    } finally {
      this.exports.cc_free(idPtr, idBytes.length);
    }
  }

  async compile(source: Uint8Array, optsJson: Uint8Array): Promise<CatalogBundle> {
    const sourcePtr = this.write(source);
    const optsPtr = this.write(optsJson);
    try {
      const raw = await this.readReturn(
        this.exports.cc_compile(sourcePtr, source.length, optsPtr, optsJson.length),
      );
      const entries = decodeFramedBundle(raw);
      const error = entries.get("error.json");
      if (error) {
        const parsed: unknown = JSON.parse(dec(error));
        const message =
          isObject(parsed) && isObject(parsed.error) && typeof parsed.error.message === "string"
            ? parsed.error.message
            : "catalog compiler failed";
        throw new Error(message);
      }
      return { entries };
    } finally {
      this.exports.cc_free(sourcePtr, source.length);
      this.exports.cc_free(optsPtr, optsJson.length);
    }
  }

  bundleSchemaVersion(): number {
    return this.exports.cc_bundle_schema_version();
  }

  /** Validate a tool-policy rule set (owner/action + connection-granular patterns) via the single-source
   *  toolcore engine; throws on the first invalid rule. The wasmtime host enforces the identical check. */
  async validatePolicy(rulesJson: string): Promise<void> {
    const bytes = enc(rulesJson);
    const ptr = this.write(bytes);
    try {
      const res: unknown = JSON.parse(dec(await this.readReturn(this.exports.cc_validate_policy(ptr, bytes.length))));
      if (isObject(res) && isObject(res.error)) {
        throw new Error(
          typeof res.error.message === "string" ? `invalid tool policy: ${res.error.message}` : "invalid tool policy",
        );
      }
    } finally {
      this.exports.cc_free(ptr, bytes.length);
    }
  }

  /** Resolve a (pre-validated) policy rule set against a connection address → the action or null, via
   *  the single-source toolcore engine. */
  async policyResolve(rulesJson: string, address: string): Promise<ToolPolicyAction | null> {
    const rules = enc(rulesJson);
    const addr = enc(address);
    const rulesPtr = this.write(rules);
    const addrPtr = this.write(addr);
    try {
      const res: unknown = JSON.parse(
        dec(await this.readReturn(this.exports.cc_policy_resolve(rulesPtr, rules.length, addrPtr, addr.length))),
      );
      const action = isObject(res) ? res.action : null;
      return action === "approve" || action === "require_approval" || action === "block" ? action : null;
    } finally {
      this.exports.cc_free(rulesPtr, rules.length);
      this.exports.cc_free(addrPtr, addr.length);
    }
  }

  private write(bytes: Uint8Array): number {
    const ptr = this.exports.cc_alloc(bytes.length);
    new Uint8Array(this.exports.memory.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  }

  private async readReturn(pair: bigint): Promise<Uint8Array> {
    const [ptr, len] = unpackReturn(pair);
    const bytes = new Uint8Array(this.exports.memory.buffer, ptr, len).slice();
    this.exports.cc_free(ptr, len);
    return bytes;
  }
}

function readDefaultCompilerWasm(): Uint8Array {
  const rel = process.env.MC_CATALOG_COMPILER_WASM;
  if (!rel) {
    throw new Error(
      "catalog-compiler.wasm not available: set MC_CATALOG_COMPILER_WASM to the built artifact path, " +
        "or pass mc.create({ catalogCompiler: <Uint8Array> }).",
    );
  }
  const path = rel.startsWith("/") || !process.env.RUNFILES_DIR ? rel : join(process.env.RUNFILES_DIR, rel);
  return new Uint8Array(readFileSync(path));
}

function unpackReturn(pair: bigint): [number, number] {
  const raw = BigInt.asUintN(64, pair);
  return [Number(raw & 0xffff_ffffn), Number(raw >> 32n)];
}

function decodeFramedBundle(bytes: Uint8Array): Map<string, Uint8Array> {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let pos = 0;
  const readU32 = (): number => {
    if (pos + 4 > bytes.length) throw new Error("catalog compiler returned a truncated bundle frame");
    const n = dv.getUint32(pos, true);
    pos += 4;
    return n;
  };
  const count = readU32();
  const out = new Map<string, Uint8Array>();
  for (let i = 0; i < count; i++) {
    const pathLen = readU32();
    const byteLen = readU32();
    if (pos + pathLen + byteLen > bytes.length) {
      throw new Error("catalog compiler returned a malformed bundle frame");
    }
    const path = dec(bytes.subarray(pos, pos + pathLen));
    pos += pathLen;
    out.set(path, bytes.subarray(pos, pos + byteLen).slice());
    pos += byteLen;
  }
  if (pos !== bytes.length) throw new Error("catalog compiler returned a bundle frame with trailing bytes");
  return out;
}

function registryEntry(value: unknown): RegistryEntry {
  if (!isObject(value) || typeof value.id !== "string" || typeof value.name !== "string") {
    throw new Error("catalog compiler returned a malformed registry entry");
  }
  if (
    value.kind !== "openapi" &&
    value.kind !== "microsoft-graph" &&
    value.kind !== "google-discovery" &&
    value.kind !== "graphql" &&
    value.kind !== "mcp-remote"
  ) {
    throw new Error(`catalog compiler returned unsupported registry kind ${String(value.kind)}`);
  }
  return {
    id: value.id,
    name: value.name,
    kind: value.kind,
    ...(typeof value.url === "string" ? { url: value.url } : {}),
    ...(typeof value.endpoint === "string" ? { endpoint: value.endpoint } : {}),
    ...(Array.isArray(value.defaultGroups)
      ? { defaultGroups: value.defaultGroups.filter((v): v is string => typeof v === "string") }
      : {}),
    ...(isObject(value.groups) ? { groups: value.groups as Record<string, RegistryGroup> } : {}),
    ...(Array.isArray(value.servers)
      ? { servers: value.servers.filter((v): v is string => typeof v === "string") }
      : {}),
  };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}
