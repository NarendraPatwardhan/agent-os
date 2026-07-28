//! Process-global `WebAssembly.Module` cache keyed by kernel content digest (PERF-011).
//!
//! Same shape as the Wasmtime host's compiled-module cache and the catalog-compiler
//! digest map: compile once per artifact bytes, `instantiate` per VM. Modules are
//! immutable and safe to share across concurrent instantiations.
//!
//! Entries are **refcounted**: each successful {@link getCompiledKernelModule} retains;
//! {@link releaseCompiledKernelModule} on VM teardown drops. When refs hit zero the
//! entry is removed so memory can be reclaimed.

type CacheEntry = {
  module: Promise<WebAssembly.Module>;
  refs: number;
};

const moduleByDigest = new Map<string, CacheEntry>();

function digestHex(digest: Uint8Array): string {
  let hex = "";
  for (const b of digest) hex += b.toString(16).padStart(2, "0");
  return hex;
}

/**
 * Return a compiled {@link WebAssembly.Module} for these kernel bytes and
 * **retain** one reference (pair with {@link releaseCompiledKernelModule} on close).
 *
 * `kernelDigest` must be the SHA-256 of `wasm` (32 bytes).
 * A failed compile is removed from the map so a later attempt can retry.
 */
export async function getCompiledKernelModule(
  wasm: Uint8Array,
  kernelDigest: Uint8Array,
): Promise<WebAssembly.Module> {
  const key = digestHex(kernelDigest);
  let entry = moduleByDigest.get(key);
  if (!entry) {
    const bytes = wasm.slice();
    let pending: Promise<WebAssembly.Module>;
    const compile = WebAssembly.compile(bytes as BufferSource);
    pending = compile.catch((error: unknown) => {
      if (moduleByDigest.get(key)?.module === pending) moduleByDigest.delete(key);
      throw error;
    });
    entry = { module: pending, refs: 0 };
    moduleByDigest.set(key, entry);
  }
  entry.refs += 1;
  try {
    return await entry.module;
  } catch (error) {
    entry.refs -= 1;
    if (entry.refs <= 0) moduleByDigest.delete(key);
    throw error;
  }
}

/**
 * Drop one retain from {@link getCompiledKernelModule}. When the last reference
 * is released the cached Module promise is discarded.
 */
export function releaseCompiledKernelModule(kernelDigest: Uint8Array): void {
  const key = digestHex(kernelDigest);
  const entry = moduleByDigest.get(key);
  if (!entry) return;
  entry.refs -= 1;
  if (entry.refs <= 0) moduleByDigest.delete(key);
}

/** @internal Test helper: drop all cached modules (does not abort in-flight compiles). */
export function clearCompiledKernelModules(): void {
  moduleByDigest.clear();
}

/** @internal Test helper: number of distinct kernel digests currently cached. */
export function compiledKernelModuleCount(): number {
  return moduleByDigest.size;
}

/** @internal Test helper: retain count for a digest, or 0. */
export function compiledKernelModuleRefs(kernelDigest: Uint8Array): number {
  return moduleByDigest.get(digestHex(kernelDigest))?.refs ?? 0;
}
