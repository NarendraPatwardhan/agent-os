// Where the browser boot fetches its bytes from, memoized so N terminals on a
// page share one download. The embedded backend needs the kernel wasm (~1.5 MB)
// and a rootfs tar (~18 MB); both are fetched by URL and cached per-URL, so
// switching images never re-downloads a blob it already holds.
//
// Defaults are root-relative (`kernel-coop.wasm`, `base.tar`) — what a dev server
// serves out of its public root. Point them elsewhere with `setArtifactSources`.

/** Logical image name → the URL actually fetched. `base.tar` is the one rootfs
 *  the built-in aliases resolve to. */
let imageRegistry: Record<string, string> = {
  default: "base.tar",
  "base:latest": "base.tar",
  base: "base.tar",
  posix: "base.tar",
  minimal: "base.tar",
};

let kernelUrl = "kernel-coop.wasm";

// Unset by default: a page that never registers host tools must not pay for (or
// require) the compiler wasm. Registering it makes runtime `vm.tool` work in-browser.
let catalogCompilerUrl: string | null = null;

/** Point the loader at where the kernel + image blobs live. Call once, before any
 *  element boots (e.g. in the app entry). */
export function setArtifactSources(opts: {
  /** URL of the cooperative kernel wasm. */
  kernel?: string;
  /** URL of the default rootfs tar (the `default` / `base:latest` image). */
  image?: string;
  /** Extra/overriding logical-name → URL mappings, merged over the defaults. */
  images?: Record<string, string>;
  /** URL of catalog-compiler.wasm — needed for host-tool registration (`vm.tool`). */
  catalogCompiler?: string;
}): void {
  if (opts.kernel) kernelUrl = opts.kernel;
  if (opts.image) {
    imageRegistry = { ...imageRegistry, default: opts.image, "base:latest": opts.image };
  }
  if (opts.images) imageRegistry = { ...imageRegistry, ...opts.images };
  if (opts.catalogCompiler) catalogCompilerUrl = opts.catalogCompiler;
}

/** Resolve the kernel URL (a per-element override wins). */
export function resolveKernelUrl(override?: string | null): string {
  return override && override.length > 0 ? override : kernelUrl;
}

/** Resolve an image ref — a logical name from the registry, else a direct URL/path. */
export function resolveImageUrl(ref?: string | null): string {
  if (!ref) return imageRegistry.default ?? "base.tar";
  return imageRegistry[ref] ?? ref;
}

const cache = new Map<string, Promise<Uint8Array>>();

function fetchBytes(url: string): Promise<Uint8Array> {
  const hit = cache.get(url);
  if (hit) return hit;
  const pending = fetch(url)
    .then((r) => {
      if (!r.ok) throw new Error(`failed to fetch ${url}: ${r.status} ${r.statusText}`);
      return r.arrayBuffer();
    })
    .then((b) => new Uint8Array(b))
    .catch((e) => {
      cache.delete(url); // drop the poisoned entry so a later attempt can retry
      throw e;
    });
  cache.set(url, pending);
  return pending;
}

/** Fetch the kernel wasm bytes (memoized). */
export function loadKernel(override?: string | null): Promise<Uint8Array> {
  return fetchBytes(resolveKernelUrl(override));
}

/** Fetch the rootfs bytes for an image ref (memoized). `null` → an empty in-memory
 *  fs, so there is nothing to fetch. */
export function loadImage(ref?: string | null): Promise<Uint8Array> | null {
  if (ref === null) return null;
  return fetchBytes(resolveImageUrl(ref));
}

/** Fetch catalog-compiler.wasm (memoized), or `null` when the page never registered
 *  one — then a VM boots fine but a runtime `vm.tool` will fail asking for it. */
export function loadCatalogCompiler(): Promise<Uint8Array> | null {
  if (!catalogCompilerUrl) return null;
  return fetchBytes(catalogCompilerUrl);
}

/** Pre-warm the shared download without booting a VM — call on first interaction
 *  so the bytes are ready by the time a terminal needs them. */
export function prefetchArtifacts(kernel?: string, image?: string): void {
  void loadKernel(kernel);
  void loadImage(image ?? undefined);
}
