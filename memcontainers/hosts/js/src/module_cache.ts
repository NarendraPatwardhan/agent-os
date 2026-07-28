//! Process-global `WebAssembly.Module` cache keyed by kernel content digest (PERF-011).
//!
//! Same shape as the Wasmtime host's compiled-module cache and the catalog-compiler
//! digest map: compile once per artifact bytes, `instantiate` per VM. Modules are
//! immutable and safe to share across concurrent instantiations.

const moduleByDigest = new Map<string, Promise<WebAssembly.Module>>();

function digestHex(digest: Uint8Array): string {
  let hex = "";
  for (const b of digest) hex += b.toString(16).padStart(2, "0");
  return hex;
}

/**
 * Return a compiled {@link WebAssembly.Module} for these kernel bytes.
 * `kernelDigest` must be the SHA-256 of `wasm` (32 bytes), matching the host's
 * snapshot kernel digest.
 *
 * A failed compile is removed from the map so a later attempt can retry.
 */
export async function getCompiledKernelModule(
  wasm: Uint8Array,
  kernelDigest: Uint8Array,
): Promise<WebAssembly.Module> {
  const key = digestHex(kernelDigest);
  let pending = moduleByDigest.get(key);
  if (!pending) {
    // Own a stable copy: callers may reuse or mutate their buffer after build starts.
    const bytes = wasm.slice();
    const compile = WebAssembly.compile(bytes as BufferSource);
    pending = compile.catch((error: unknown) => {
      // Do not poison the cache with a rejected promise for this digest.
      if (moduleByDigest.get(key) === pending) moduleByDigest.delete(key);
      throw error;
    });
    moduleByDigest.set(key, pending);
  }
  return pending;
}

/** Test helper: drop all cached modules (does not abort in-flight compiles). */
export function clearCompiledKernelModules(): void {
  moduleByDigest.clear();
}

/** Test helper: number of distinct kernel digests currently cached. */
export function compiledKernelModuleCount(): number {
  return moduleByDigest.size;
}
