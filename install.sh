#!/usr/bin/env bash
set -euo pipefail

REPO="NarendraPatwardhan/agent-os"
DEFAULT_DIR="agent-os"

MODE="${AGENTOS_MODE:-}"
IMAGE="${AGENTOS_IMAGE:-}"
INSTALL_DIR="${AGENTOS_DIR:-$DEFAULT_DIR}"
VERSION="${AGENTOS_VERSION:-}"
TMP_FILES=""

cleanup() {
  for f in $TMP_FILES; do
    rm -f "$f"
  done
}
trap cleanup EXIT

die() {
  printf 'agent-os install: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: install.sh [--mode agentic|embedded] [--image minimal|posix|loom|atlas|paper] [--dir DIR] [--version TAG]

Downloads the runtime files needed to run AgentOS from GitHub releases:
  mc-core.mjs, kernel.wasm, catalog-compiler.wasm, and one image tar.

Modes:
  agentic   for Claude, Codex, opencode, and other coding agents; includes a skill file
  embedded  for products and apps; runtime artifacts only

Environment overrides:
  AGENTOS_MODE=agentic|embedded
  AGENTOS_IMAGE=minimal|posix|loom|atlas|paper
  AGENTOS_DIR=./agent-os
  AGENTOS_VERSION=v0.1.0
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

normalize_mode() {
  case "$1" in
    1|a|agent|agentic|claude|codex|opencode) printf 'agentic' ;;
    2|e|embed|embedded|product|products) printf 'embedded' ;;
    *) die "unknown mode '$1' (expected agentic or embedded)" ;;
  esac
}

normalize_image() {
  case "$1" in
    minimal|posix|loom|atlas|paper) printf '%s.tar' "$1" ;;
    minimal.tar|posix.tar|loom.tar|atlas.tar|paper.tar) printf '%s' "$1" ;;
    *) die "unknown image '$1' (expected minimal, posix, loom, atlas, or paper)" ;;
  esac
}

prompt_mode() {
  if [ -n "$MODE" ]; then
    normalize_mode "$MODE"
    return
  fi

  local answer=""
  if [ -r /dev/tty ]; then
    {
      printf '\nAgentOS install mode:\n'
      printf '  1) agentic  - Claude/Codex/opencode; includes the AgentOS skill file\n'
      printf '  2) embedded - products/apps; runtime artifacts only\n'
      printf 'Choose mode [1]: '
    } >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
  fi

  if [ -z "$answer" ]; then
    answer="1"
  fi
  normalize_mode "$answer"
}

select_image() {
  local mode="$1"
  if [ -n "$IMAGE" ]; then
    normalize_image "$IMAGE"
    return
  fi

  if [ "$mode" = "agentic" ]; then
    printf 'loom.tar'
  else
    printf 'posix.tar'
  fi
}

download_base() {
  if [ -n "$VERSION" ]; then
    printf 'https://github.com/%s/releases/download/%s' "$REPO" "$VERSION"
  else
    printf 'https://github.com/%s/releases/latest/download' "$REPO"
  fi
}

release_page() {
  if [ -n "$VERSION" ]; then
    printf 'https://github.com/%s/releases/tag/%s' "$REPO" "$VERSION"
  else
    printf 'https://github.com/%s/releases/latest' "$REPO"
  fi
}

download_asset() {
  local base="$1"
  local asset="$2"
  local dest="$3"
  local url="${base}/${asset}"
  local tmp="${dest}.tmp.$$"
  TMP_FILES="${TMP_FILES} ${tmp}"

  printf 'Downloading %s\n' "$asset"
  curl -fL --retry 3 --retry-delay 1 --connect-timeout 20 -o "$tmp" "$url"
  test -s "$tmp" || die "downloaded empty asset: $asset"
  mv "$tmp" "$dest"
}

write_agent_skill() {
  local root="$1"
  local skill_dir="${root}/skills/agent-os"
  local skill_file="${skill_dir}/SKILL.md"
  mkdir -p "$skill_dir"
  cat >"$skill_file" <<'SKILL_EOF'
---
name: agent-os
description: Drive AgentOS — a WebAssembly-native VM/computer for agents — from a coding agent (Claude, Codex, opencode) or an embedded JS product via the @mc/core SDK in mc-core.mjs. Trigger when asked to boot or use AgentOS, run shell or Luau inside the sandbox, give the VM host-backed tools or capabilities, read or write VM files, snapshot/fork VM state, or embed AgentOS in Bun, Node, or the browser.
---

# AgentOS — host SDK

AgentOS is a WebAssembly computer you drive from the host through the `mc` API exported by
`mc-core.mjs` (the `@mc/core` bundle). It is the agent's own working machine, not a generic
command runner. Use the release artifacts installed alongside this file — `mc-core.mjs`,
`kernel.wasm`, one image `.tar`, and `catalog-compiler.wasm` (needed only when a VM uses connections)
— and rebuild from source only when changing AgentOS itself.

## Images

One image tar boots the VM. Pick the smallest that carries the tools the task needs; if a
command is missing, switch to a richer image rather than emulating it on the host.

- `loom` — POSIX coreutils + Luau + the office stack (docx/xlsx/pptx). Default for agentic work.
- `posix` — shell + file tools, no Luau. Good for embedded automation.
- `atlas` — adds SQLite + vector search, for data workflows.
- `paper` — document and PDF generation.
- `minimal` — smallest shell-only base, for custom harnesses.

## Boot a VM

Node 22+/Bun read the artifacts from disk; a browser passes the bytes it fetched.

```js
import { mc } from "./agent-os/mc-core.mjs";
import { readFileSync } from "node:fs";

const kernel = new Uint8Array(readFileSync("./agent-os/kernel.wasm"));
const image  = new Uint8Array(readFileSync("./agent-os/loom.tar"));

const vm = await mc.create({ kernel, image, deterministic: true });
try {
  // …work…
} finally {
  await vm.close(); // always close in finally
}
```

`deterministic: true` pins the clock and RNG for reproducible runs. In the browser pass
`runtime: "browser"` with `kernel`/`image` as `Uint8Array` (no Node fs).

## Run work

- `vm.exec(cmd, { cwd?, env?, stdin? })` → `{ stdout, stderr, exitCode, stdoutBytes, stderrBytes }`.
  Branch on `exitCode`; read `stderr` on failure. `cmd` is a real shell line — pipes, `$(…)`,
  and redirection all work.
- `vm.luau(src, args?)` → the same `ExecResult`; requires a Luau image (`loom`). Use it for
  multi-step agent programs instead of chaining shell.
- `vm.fs` — the operator file view: `read` · `readText` · `write` · `ls` · `stat` · `mkdir` ·
  `rm` · `chmod` · `symlink` · `readlink`. Stage inputs before `exec`, read artifacts back after;
  never scrape a file out of stdout when it exists on disk.
- `vm.shell({ language: "sh" | "luau" })` — an interactive byte stream (what a live terminal uses).

```js
await vm.fs.write("/work/in.txt", "hello\n");
const r = await vm.exec("wc -l < /work/in.txt");
if (r.exitCode !== 0) throw new Error(r.stderr);
console.log(r.stdout.trim());
```

## Give the VM capabilities

Nothing ambient exists — no network, secrets, mounts, or host tools — until you add it via the SDK.

- Host tools: `vm.tool(def)` (build defs with `tool()` / `kit()`). The agent inside calls them
  through `/svc/tools` and the Luau `tools` battery; the handler runs host-side. Register before
  asking the VM to use them.
- Capability sugar: `mc.use("github.issues", token, { kernel, image, catalogCompiler })` derives the
  connection and tool selector and turns on network in one call.
- Connections (OpenAPI/GraphQL specs → tool catalogs, via `mc.use` or `connections`) compile with
  catalog-compiler.wasm — pass its bytes as
  `catalogCompiler: new Uint8Array(readFileSync("./agent-os/catalog-compiler.wasm"))`. A plain VM
  (exec/luau/fs) never needs it.
- Network / mounts: `mc.create({ net: true, permissions: { network: "allow" }, mounts: [...] })`.

## Live agent sessions

`vm.session(agentType?)` / `vm.luauSession()` → `{ id, prompt(text) → SessionEvent[], on(cb) }`.
`prompt` runs a Luau agent program and streams framed JSON events; subscribe with `on`. Prefer a
session over one-shot `exec` for an interactive agent loop.

## Persist & resume

- `vm.snapshot()` → `Uint8Array` whole-VM memory image; `mc.restore(bytes, opts)` resumes it warm.
- `vm.commit().asLayer()` → `{ digest, tar }` content-addressed layer; stack it under
  `mc.create({ image })`.

Only snapshot/commit when the caller needs resumable state, and say what you are preserving.

## Slash commands

If the agent framework supports them, keep each simple — load the artifacts, boot one VM,
do the work, return concrete outputs (exit code + stdout + stderr), then close:

- `/agentos-exec $ARGUMENTS` — run `$ARGUMENTS` with `vm.exec`.
- `/agentos-luau $ARGUMENTS` — run `$ARGUMENTS` as Luau with `vm.luau` (requires `loom`).
- `/agentos-files $ARGUMENTS` — read/write/inspect VM files through `vm.fs`.
- `/agentos-tool $ARGUMENTS` — register a host tool with `vm.tool` and exercise it.
- `/agentos-snapshot` — `vm.snapshot()` or `vm.commit().asLayer()`, after saying what state is saved.

## Rules

- Close the VM in `finally`.
- Do not claim success from `exitCode === 0` alone when the deliverable is a file — read it back
  and validate it.
- Add capabilities explicitly; a denied one surfaces as an in-VM error (e.g. `EPERM`), never a
  host crash.
SKILL_EOF
  printf '%s\n' "$skill_file"
}

js_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

print_example() {
  local abs_dir="$1"
  local image_asset="$2"
  local mode="$3"
  local d
  d="$(js_string "$abs_dir")"

  printf '\nInstalled AgentOS %s assets in %s\n' "$mode" "$abs_dir"
  printf 'Four files: mc-core.mjs, kernel.wasm, catalog-compiler.wasm, %s   (more + checksums: %s)\n' \
    "$image_asset" "$(release_page)"
  if [ "$mode" = "agentic" ]; then
    printf 'Skill (how to drive AgentOS): %s/skills/agent-os/SKILL.md\n' "$abs_dir"
  fi

  cat <<EOF

Quickstart (Bun / Node 22+):

  import { mc } from "${d}/mc-core.mjs";
  import { readFileSync } from "node:fs";
  const vm = await mc.create({
    kernel: new Uint8Array(readFileSync("${d}/kernel.wasm")),
    image:  new Uint8Array(readFileSync("${d}/${image_asset}")),
    deterministic: true,
  });
  try { console.log((await vm.exec("echo hello from agent-os")).stdout); }
  finally { await vm.close(); }
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      shift
      [ "$#" -gt 0 ] || die "--mode needs a value"
      MODE="$1"
      ;;
    --image)
      shift
      [ "$#" -gt 0 ] || die "--image needs a value"
      IMAGE="$1"
      ;;
    --dir)
      shift
      [ "$#" -gt 0 ] || die "--dir needs a value"
      INSTALL_DIR="$1"
      ;;
    --version)
      shift
      [ "$#" -gt 0 ] || die "--version needs a value"
      VERSION="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

need curl

MODE="$(prompt_mode)"
IMAGE_ASSET="$(select_image "$MODE")"

mkdir -p "$INSTALL_DIR"
ABS_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
BASE_URL="$(download_base)"

printf 'AgentOS mode: %s\n' "$MODE"
printf 'Image: %s\n' "$IMAGE_ASSET"
printf 'Release: %s\n' "$(release_page)"
printf 'Target: %s\n\n' "$ABS_DIR"

download_asset "$BASE_URL" "mc-core.mjs" "${ABS_DIR}/mc-core.mjs"
download_asset "$BASE_URL" "kernel.wasm" "${ABS_DIR}/kernel.wasm"
download_asset "$BASE_URL" "catalog-compiler.wasm" "${ABS_DIR}/catalog-compiler.wasm"
download_asset "$BASE_URL" "$IMAGE_ASSET" "${ABS_DIR}/${IMAGE_ASSET}"

if [ "$MODE" = "agentic" ]; then
  write_agent_skill "$ABS_DIR" >/dev/null
fi

print_example "$ABS_DIR" "$IMAGE_ASSET" "$MODE"
