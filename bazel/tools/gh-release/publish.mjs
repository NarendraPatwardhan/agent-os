// publish.mjs — cut an AgentOS GitHub release over the REST API (no `gh` CLI).
//
// GitHub's documented flow is two REST calls + N uploads:
//   GET    api.github.com/repos/{repo}/releases/tags/{tag}            -> existing release, or 404
//   POST   api.github.com/repos/{repo}/releases                       -> {id, upload_url, html_url}
//   POST   uploads.github.com/.../releases/{id}/assets?name=<file>    -> per asset (octet-stream body)
// The leading GET makes a re-run IDEMPOTENT: an existing release is reused (its notes re-synced, its
// same-named assets REPLACED via delete-then-upload) instead of failing with 422 "already_exists".
//
// Alongside the graph assets it uploads a generated SHA256SUMS — `sha256sum -c`-compatible, hashed
// over the EXACT bytes uploaded (the tool reads each asset once to hash, once to upload), so the
// release is verifiable. The hashes are reproducible because the tars/wasm are deterministic.
//
// Release NOTES are mandatory: pass --notes or --notes-file. We never let GitHub auto-generate them.
//
// Inputs from the gh_release macro (defs.bzl):
//   MC_RELEASE_REPO    "owner/repo"
//   MC_RELEASE_ASSETS  JSON {assetName: rlocationpath}; each path is joined onto RUNFILES_DIR — the
//                      same runfiles resolution hosts/js parity_test uses, so the bytes uploaded are
//                      exactly the data-deps Bazel built.
// Auth: GITHUB_TOKEN (or GH_TOKEN) env, or --token-file <path>. Not needed for --dry-run.
//
// Runs under the pinned rules_js node (22) via js_binary: global fetch + bundled TLS/CA roots, zero
// npm deps.

import { readFileSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { isAbsolute, join } from "node:path";

const API = "https://api.github.com";
const UA = "agent-os-release";
const API_VERSION = "2022-11-28";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function die(msg) {
  console.error(`publish: ${msg}`);
  process.exit(1);
}

function printHelp() {
  console.error(`usage: bazel run //bazel/tools/gh-release:publish -- --tag <tag> (--notes <t> | --notes-file <p>) [options]

  --tag <tag>          (required) git tag for the release, e.g. v0.3.0
  --notes <text>       (required, or --notes-file) release body text
  --notes-file <path>  (required, or --notes) release body read from a file
  --name <name>        release title (default: the tag)
  --target <commitish> commit/branch the tag points at (default: GitHub repo default branch)
  --draft              create as a draft (not published)
  --prerelease         mark as a pre-release
  --repo <owner/repo>  override MC_RELEASE_REPO
  --token-file <path>  read the token from a file instead of GITHUB_TOKEN
  --dry-run            resolve + validate assets/notes and exit; make no GitHub calls
  -h, --help           this message

Notes are mandatory — GitHub auto-generated release notes are never used.`);
}

function parseArgs(argv) {
  const opts = { draft: false, prerelease: false, dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      const v = argv[++i];
      if (v === undefined) die(`${a} needs a value`);
      return v;
    };
    switch (a) {
      case "--tag": opts.tag = val(); break;
      case "--name": opts.name = val(); break;
      case "--target": opts.target = val(); break;
      case "--notes": opts.notes = val(); break;
      case "--notes-file": opts.notesFile = val(); break;
      case "--draft": opts.draft = true; break;
      case "--prerelease": opts.prerelease = true; break;
      case "--repo": opts.repo = val(); break;
      case "--token-file": opts.tokenFile = val(); break;
      case "--dry-run": opts.dryRun = true; break;
      case "-h":
      case "--help": printHelp(); process.exit(0);
      default: die(`unknown argument ${JSON.stringify(a)} (try --help)`);
    }
  }
  if (!opts.tag) die("missing required --tag <tag> (try --help)");
  return opts;
}

// Release notes are MANDATORY and must be non-empty. GitHub auto-generation is never an option.
function resolveNotes(opts) {
  let body;
  if (opts.notes !== undefined) {
    body = opts.notes;
  } else if (opts.notesFile !== undefined) {
    try {
      body = readFileSync(opts.notesFile, "utf8");
    } catch (e) {
      die(`--notes-file ${opts.notesFile}: ${e.message}`);
    }
  } else {
    die("release notes are required: pass --notes <text> or --notes-file <path> (notes are never auto-generated)");
  }
  if (body.trim() === "") {
    die("release notes are empty — provide real notes (notes are never auto-generated)");
  }
  return body;
}

function runfilesDir() {
  return process.env.RUNFILES_DIR ?? process.env.JS_BINARY__RUNFILES ?? null;
}

// {assetName: rlocationpath} from the macro → [{name, path, size}], each resolved against the
// runfiles tree and checked readable. A missing asset is a hard error (the data-dep didn't build).
function resolveAssets() {
  const raw = process.env.MC_RELEASE_ASSETS;
  if (!raw) die("MC_RELEASE_ASSETS not set — run via `bazel run //bazel/tools/gh-release:publish`, not node directly");
  const map = JSON.parse(raw);
  const rf = runfilesDir();
  const assets = [];
  for (const [name, rel] of Object.entries(map)) {
    let path = rel;
    if (!isAbsolute(rel)) {
      if (!rf) die(`RUNFILES_DIR unset; cannot resolve asset ${name} (${rel})`);
      path = join(rf, rel);
    }
    let size;
    try {
      size = statSync(path).size;
    } catch {
      die(`asset ${name} not found at ${path} (rlocationpath ${rel})`);
    }
    assets.push({ name, path, size });
  }
  if (assets.length === 0) die("no assets to publish");
  return assets;
}

// SHA256SUMS over the exact asset bytes, `sha256sum -c`-compatible ("<hex>  <name>\n"), sorted by
// name for a deterministic, stable file. Returned as a synthetic in-memory asset (it has no path).
function sha256SumsAsset(assets) {
  const lines = assets
    .slice()
    .sort((x, y) => (x.name < y.name ? -1 : x.name > y.name ? 1 : 0))
    .map((a) => `${createHash("sha256").update(readFileSync(a.path)).digest("hex")}  ${a.name}`);
  const bytes = Buffer.from(lines.join("\n") + "\n", "utf8");
  return { name: "SHA256SUMS", bytes, size: bytes.length };
}

function readToken(opts) {
  if (opts.tokenFile) return readFileSync(opts.tokenFile, "utf8").trim();
  const t = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  if (!t) die("no token: set GITHUB_TOKEN (or GH_TOKEN), or pass --token-file <path>");
  return t.trim();
}

// fetch with bounded retry: retry on a network error or a 5xx (transient), never on a 4xx (the
// request itself is wrong — surface it immediately).
async function ghFetch(url, { method = "GET", token, body, contentType, accept = "application/vnd.github+json" } = {}) {
  const headers = { Accept: accept, "User-Agent": UA, "X-GitHub-Api-Version": API_VERSION };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (contentType) headers["Content-Type"] = contentType;
  let lastErr;
  for (let attempt = 1; attempt <= 4; attempt++) {
    try {
      const res = await fetch(url, { method, headers, body });
      if (res.status < 500) return res;
      lastErr = new Error(`${method} ${url} -> ${res.status} ${res.statusText}`);
    } catch (e) {
      lastErr = e;
    }
    if (attempt < 4) await sleep(500 * 2 ** (attempt - 1));
  }
  throw lastErr;
}

async function errBody(res, ctx) {
  let detail = "";
  try {
    detail = JSON.stringify(await res.json());
  } catch {
    /* non-JSON error body */
  }
  return `${ctx}: ${res.status} ${res.statusText} ${detail}`;
}

async function findRelease(repo, tag, token) {
  const res = await ghFetch(`${API}/repos/${repo}/releases/tags/${encodeURIComponent(tag)}`, { token });
  if (res.status === 404) return null;
  if (!res.ok) die(await errBody(res, `look up release ${tag}`));
  return res.json();
}

async function createRelease(repo, opts, body, token) {
  const payload = {
    tag_name: opts.tag,
    name: opts.name ?? opts.tag,
    body, // mandatory, validated by resolveNotes; generate_release_notes is never sent
    draft: opts.draft,
    prerelease: opts.prerelease,
  };
  if (opts.target) payload.target_commitish = opts.target;

  const res = await ghFetch(`${API}/repos/${repo}/releases`, {
    method: "POST",
    token,
    contentType: "application/json",
    body: JSON.stringify(payload),
  });
  if (!res.ok) die(await errBody(res, `create release ${opts.tag}`));
  return res.json();
}

// Keep an existing release's notes authoritative on a re-run: the passed notes are the source of
// truth, so sync them onto the release rather than leaving whatever was there before.
async function updateReleaseBody(repo, releaseId, body, token) {
  const res = await ghFetch(`${API}/repos/${repo}/releases/${releaseId}`, {
    method: "PATCH",
    token,
    contentType: "application/json",
    body: JSON.stringify({ body }),
  });
  if (!res.ok) die(await errBody(res, `update release notes`));
  return res.json();
}

async function deleteAsset(repo, assetId, token) {
  const res = await ghFetch(`${API}/repos/${repo}/releases/assets/${assetId}`, { method: "DELETE", token });
  if (!res.ok && res.status !== 404) die(await errBody(res, `delete stale asset ${assetId}`));
}

async function uploadAsset(uploadUrlTemplate, asset, token) {
  // upload_url is a URI template "https://uploads.github.com/.../assets{?name,label}" — drop the {…}.
  const base = uploadUrlTemplate.split("{")[0];
  const url = `${base}?name=${encodeURIComponent(asset.name)}`;
  const body = asset.bytes ?? readFileSync(asset.path); // Buffer; fetch sets Content-Length from its length
  const res = await ghFetch(url, { method: "POST", token, contentType: "application/octet-stream", body });
  if (!res.ok) die(await errBody(res, `upload ${asset.name}`));
  return res.json();
}

function human(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(1)} KiB`;
  return `${(n / 1024 ** 2).toFixed(2)} MiB`;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const repo = opts.repo ?? process.env.MC_RELEASE_REPO;
  if (!repo) die("no repo: set MC_RELEASE_REPO (via the gh_release macro) or pass --repo owner/repo");
  const notes = resolveNotes(opts); // required — fails before any network/token work if missing or empty
  const assets = resolveAssets();
  const sums = sha256SumsAsset(assets);
  const uploads = [...assets, sums]; // SHA256SUMS rides alongside the graph assets

  console.error(`release: ${repo} @ ${opts.tag}  (${assets.length} assets + SHA256SUMS)`);
  for (const a of uploads) console.error(`  • ${a.name.padEnd(16)} ${human(a.size).padStart(10)}`);

  if (opts.dryRun) {
    console.error(`\n--- SHA256SUMS ---\n${sums.bytes.toString("utf8").trimEnd()}`);
    console.error(`\n--dry-run: ${assets.length} assets + SHA256SUMS resolved; notes present (${notes.trim().length} chars); no GitHub calls made.`);
    console.error(`would create release ${opts.tag}${opts.draft ? " (draft)" : ""} on ${repo}.`);
    return;
  }

  const token = readToken(opts);
  let release = await findRelease(repo, opts.tag, token);
  if (release) {
    console.error(`\nrelease ${opts.tag} exists (#${release.id}) — reusing; syncing notes, replacing same-named assets`);
    await updateReleaseBody(repo, release.id, notes, token);
  } else {
    release = await createRelease(repo, opts, notes, token);
    console.error(`\ncreated release ${opts.tag} (#${release.id})`);
  }

  const existing = new Map((release.assets ?? []).map((a) => [a.name, a.id]));
  for (const a of uploads) {
    if (existing.has(a.name)) {
      await deleteAsset(repo, existing.get(a.name), token);
    }
    const up = await uploadAsset(release.upload_url, a, token);
    console.error(`  uploaded ${a.name.padEnd(16)} ${human(a.size).padStart(10)}  ${up.browser_download_url}`);
  }

  console.error(`\n✓ ${release.html_url}`);
}

main().catch((e) => die(e?.stack || String(e)));
