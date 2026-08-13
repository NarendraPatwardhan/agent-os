#!/usr/bin/env bash
set -euo pipefail

input="$1"
output="$2"
status_file="$3"
gitz_commit="$4"
gitz_integrity="$5"
contract_major="$6"
contract_minor="$7"
capabilities="$8"
build_mode="$9"
agent_os_commit="$(awk '$1 == "STABLE_AGENT_OS_COMMIT" { print $2 }' "$status_file")"
if [[ ! "$agent_os_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "AgentOS package provenance requires a clean 40-hex Git revision" >&2
  exit 1
fi
stage="${TMPDIR:-/tmp}/agent-os-package-manifest.$$"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage"
tar -xf "$input" -C "$stage"

manifest="$stage/agent_os/priv/package-manifest.json"
mkdir -p "$(dirname "$manifest")"
files="$stage/files.json"
git_engine_digest="$(sha256sum "$stage/agent_os/priv/git-engine" | cut -d ' ' -f1)"
kernel_digest="$(sha256sum "$stage/agent_os/priv/kernel/kernel.wasm" | cut -d ' ' -f1)"
find "$stage/agent_os" -type f ! -path "$manifest" -print0 \
  | sort -z \
  | while IFS= read -r -d '' file; do
      rel="${file#"$stage/agent_os/"}"
      digest="$(sha256sum "$file" | cut -d ' ' -f1)"
      printf '%s\t%s\n' "$rel" "$digest"
    done > "$files"

{
  printf '{\n  "schema": 1,\n  "agent_os_commit": "%s",\n' "$agent_os_commit"
  printf '  "gitz_commit": "%s",\n  "gitz_archive_integrity": "%s",\n' "$gitz_commit" "$gitz_integrity"
  printf '  "git_contract_major": %s,\n  "git_contract_minor": %s,\n  "git_capabilities": %s,\n' "$contract_major" "$contract_minor" "$capabilities"
  printf '  "build_mode": "%s",\n' "$build_mode"
  printf '  "artifacts": {"priv/git-engine": "%s", "priv/kernel/kernel.wasm": "%s"},\n' "$git_engine_digest" "$kernel_digest"
  printf '  "required_licenses": ["share/licenses/gitz/LICENSE"],\n  "files": {\n'
  first=1
  while IFS=$'\t' read -r path digest; do
    if [[ "$first" -eq 0 ]]; then printf ',\n'; fi
    first=0
    printf '    "%s": "%s"' "$path" "$digest"
  done < "$files"
  printf '\n  }\n}\n'
} > "$manifest"
rm "$files"

tar --sort=name --mtime='UTC 2000-01-01' --owner=0 --group=0 --numeric-owner \
  -cf "$output" -C "$stage" agent_os
