#!/usr/bin/env bash
set -euo pipefail

# --- begin runfiles.bash initialization v3 ---
f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null ||
  source "$0.runfiles/$f" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null ||
  {
    echo >&2 "cannot find Bazel runfiles library"
    exit 1
  }
unset f
# --- end runfiles.bash initialization v3 ---

# Bazel may launch this wrapper without exporting RUNFILES_DIR. Preserve this
# command's runfiles tree for nested tool adapters, whose own output path does
# not have a sibling runfiles directory.
if [[ -z "${RUNFILES_DIR:-}" && -d "$0.runfiles" ]]; then
  export RUNFILES_DIR="$0.runfiles"
fi

mode="${1:?missing mode}"
tool="$(rlocation "${2:?missing tool}")"
language="${3:?missing language}"

workspace="${BUILD_WORKING_DIRECTORY:-${BUILD_WORKSPACE_DIRECTORY:-}}"
if [[ -z "$workspace" ]]; then
  echo >&2 "formatter must run through bazel run"
  exit 1
fi
cd "$workspace"

case "$language" in
oxc) patterns=('*.js' '*.mjs' '*.cjs' '*.jsx' '*.ts' '*.mts' '*.cts' '*.tsx' '*.json' '*.jsonc' '*.css' '*.scss' '*.less' '*.html' '*.md' '*.toml' '*.yaml' '*.yml') ;;
zig) patterns=('*.zig') ;;
elixir) patterns=('*.ex' '*.exs') ;;
luau) patterns=('*.luau') ;;
grammar) patterns=('*.grammar') ;;
*)
  echo >&2 "unknown formatter language: $language"
  exit 1
  ;;
esac

mapfile -d '' candidates < <(
  {
    # `git ls-files --cached --modified` is a union: `--cached` selects every
    # tracked file. Keep the formatter change-scoped by asking Git for tracked
    # paths changed from HEAD (staged or unstaged), plus untracked paths.
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
      git diff --name-only -z --diff-filter=ACMR HEAD -- \
        "${patterns[@]}" "${patterns[@]/#/*/}"
    else
      git ls-files -z --cached -- \
        "${patterns[@]}" "${patterns[@]/#/*/}"
    fi
    git ls-files -z --other --exclude-standard -- \
      "${patterns[@]}" "${patterns[@]/#/*/}"
  }
)

files=()
declare -A seen=()
for file in "${candidates[@]}"; do
  [[ -f "$file" ]] || continue
  [[ -z "${seen[$file]+x}" ]] || continue
  seen["$file"]=1
  attrs="$(git check-attr rules-lint-ignored linguist-generated gitlab-generated -- "$file")"
  if grep -Eq ': (set|true)$' <<<"$attrs"; then
    continue
  fi
  files+=("$file")
done

if ((${#files[@]} == 0)); then
  exit 0
fi

case "$language" in
oxc)
  if [[ "$mode" == check ]]; then
    exec "$tool" --check "${files[@]}"
  fi
  exec "$tool" --write "${files[@]}"
  ;;
zig)
  if [[ "$mode" == check ]]; then
    exec "$tool" --check "${files[@]}"
  fi
  exec "$tool" "${files[@]}"
  ;;
elixir)
  exec "$tool" "$mode" "${files[@]}"
  ;;
luau)
  args=(--config-path stylua.toml --respect-ignores --verify)
  if [[ "$mode" == check ]]; then
    args+=(--check --output-format summary)
  fi
  exec "$tool" "${args[@]}" "${files[@]}"
  ;;
grammar)
  if [[ "$mode" == check ]]; then
    exec "$tool" --check "${files[@]}"
  fi
  exec "$tool" "${files[@]}"
  ;;
esac
