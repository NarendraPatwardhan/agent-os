import { setArtifactSources } from "@mc/elements";

type ArtifactRecord = {
  readonly url: string;
  readonly sha256: string;
};

type ArtifactManifest = {
  readonly schema: 1;
  readonly artifacts: {
    readonly kernel: ArtifactRecord;
    readonly catalogCompiler: ArtifactRecord;
  };
  readonly images: {
    readonly default: ArtifactRecord;
    readonly minimal: ArtifactRecord;
    readonly posix: ArtifactRecord;
    readonly loom: ArtifactRecord;
    readonly atlas: ArtifactRecord;
    readonly paper: ArtifactRecord;
  };
};

const SHA256 = /^[0-9a-f]{64}$/;

function versioned(record: ArtifactRecord): string {
  if (!record.url.startsWith("/mc/") || !SHA256.test(record.sha256)) {
    throw new Error("invalid browser artifact manifest record");
  }
  const url = new URL(record.url, window.location.origin);
  url.searchParams.set("sha256", record.sha256);
  return `${url.pathname}${url.search}`;
}

function manifestRequestUrl(): string {
  const url = new URL("/mc/artifacts.json", window.location.origin);
  // The manifest is tiny and mutable. A unique request reaches the current
  // deployment even when a CDN still holds the prior stable path; the large
  // blobs below retain durable, content-keyed cache URLs.
  url.searchParams.set("request", crypto.randomUUID());
  return `${url.pathname}${url.search}`;
}

export async function configureArtifactSources(): Promise<void> {
  const response = await fetch(manifestRequestUrl(), { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`failed to fetch browser artifact manifest: ${response.status}`);
  }
  const manifest = (await response.json()) as ArtifactManifest;
  if (manifest.schema !== 1) {
    throw new Error(`unsupported browser artifact manifest schema: ${String(manifest.schema)}`);
  }

  setArtifactSources({
    kernel: versioned(manifest.artifacts.kernel),
    image: versioned(manifest.images.default),
    images: {
      minimal: versioned(manifest.images.minimal),
      posix: versioned(manifest.images.posix),
      loom: versioned(manifest.images.loom),
      atlas: versioned(manifest.images.atlas),
      paper: versioned(manifest.images.paper),
    },
    catalogCompiler: versioned(manifest.artifacts.catalogCompiler),
  });
}
