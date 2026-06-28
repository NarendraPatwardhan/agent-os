export interface BrowserVmArtifacts {
  kernel: Uint8Array;
  image: Uint8Array;
}

const KERNEL_URL = "/mc/kernel.wasm";
const IMAGE_URL = "/mc/image.tar";

let artifactsPromise: Promise<BrowserVmArtifacts> | undefined;

function abortError(): Error {
  return new Error("browser VM artifact load was aborted");
}

async function fetchBytes(url: string): Promise<Uint8Array> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`failed to load ${url}: HTTP ${response.status}`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

function loadSharedArtifacts(): Promise<BrowserVmArtifacts> {
  artifactsPromise ??= Promise.all([fetchBytes(KERNEL_URL), fetchBytes(IMAGE_URL)])
    .then(([kernel, image]) => ({ kernel, image }))
    .catch((error: unknown) => {
      artifactsPromise = undefined;
      throw error;
    });
  return artifactsPromise;
}

export async function loadBrowserVmArtifacts(signal?: AbortSignal): Promise<BrowserVmArtifacts> {
  if (signal?.aborted) throw abortError();
  const artifacts = await loadSharedArtifacts();
  if (signal?.aborted) throw abortError();
  return artifacts;
}
